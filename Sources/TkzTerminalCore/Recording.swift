// Recording.swift — the `.tkzrec` container: raw pty bytes + monotonic timestamps + a header.
//
// docs/design.md → *Testing without UI*. `tkzmux-vtdump record` tees everything a real
// `claude` session writes to the pty into one of these; `replay` feeds it back into a
// `TerminalSession` so the whole VT/render stack is testable headlessly and deterministically.
//
// ## Format (version 1)
//
//     <one line of JSON, UTF-8, terminated by 0x0A>       ← the header, `head -1 f | jq .`
//     <frame> <frame> …                                    ← binary, little-endian
//
//     frame := u8  kind
//              u64 elapsedNanos   (monotonic, since RecordingHeader.startedAt)
//              u32 length
//              u8[length] payload
//
//     kind 0 = output   payload = raw bytes read from the pty master (child → terminal)
//     kind 1 = resize   payload = u16 cols, u16 rows
//     kind 2 = input    payload = raw bytes written to the pty master (host → child)
//
// Design notes:
//   * The header is a whole JSON line so a recording is inspectable with standard tools and
//     can gain fields without a format bump (unknown keys are ignored on read).
//   * The `kind` byte means `record` can start emitting resize/input frames later without a
//     version bump; a reader that meets an unknown kind skips it by `length`.
//   * A truncated final frame is normal — a recording ends when the session is killed — so the
//     reader stops cleanly at the last complete frame instead of throwing.
import Foundation

/// The first line of a `.tkzrec` file.
public struct RecordingHeader: Codable, Hashable, Sendable {
    public static let currentMagic = "tkzrec"
    public static let currentVersion = 1

    public var magic: String
    public var version: Int
    public var cols: UInt16
    public var rows: UInt16
    /// The command that was recorded, e.g. `["/bin/zsh", "-zsh", "-l"]`.
    public var argv: [String]
    /// A *summary* of the child environment — the variables that change VT behaviour
    /// (`TERM`, `TERM_PROGRAM`, `COLORTERM`, …), never the whole environment (secrets).
    public var env: [String: String]
    /// Wall-clock start, seconds since 1970. Frame timestamps are monotonic offsets from here.
    public var startedAt: Double
    /// Free-form note (`"claude boot, account Private"`).
    public var note: String?

    public init(
        cols: UInt16,
        rows: UInt16,
        argv: [String] = [],
        env: [String: String] = [:],
        startedAt: Double = Date().timeIntervalSince1970,
        note: String? = nil
    ) {
        self.magic = Self.currentMagic
        self.version = Self.currentVersion
        self.cols = cols
        self.rows = rows
        self.argv = argv
        self.env = env
        self.startedAt = startedAt
        self.note = note
    }
}

/// One recorded event.
public enum RecordingFrame: Hashable, Sendable {
    case output(elapsedNanos: UInt64, bytes: Data)
    case resize(elapsedNanos: UInt64, cols: UInt16, rows: UInt16)
    case input(elapsedNanos: UInt64, bytes: Data)

    public var elapsedNanos: UInt64 {
        switch self {
        case .output(let t, _), .input(let t, _): return t
        case .resize(let t, _, _): return t
        }
    }

    /// The wire `kind` byte.
    var kind: UInt8 {
        switch self {
        case .output: return 0
        case .resize: return 1
        case .input: return 2
        }
    }

    var payload: Data {
        switch self {
        case .output(_, let bytes), .input(_, let bytes):
            return bytes
        case .resize(_, let cols, let rows):
            var out = Data(capacity: 4)
            out.appendLittleEndian(cols)
            out.appendLittleEndian(rows)
            return out
        }
    }
}

public enum RecordingError: Error, Equatable, Sendable {
    case missingHeader
    case headerNotJSON(String)
    case badMagic(String)
    case unsupportedVersion(Int)
}

// MARK: - Writing

/// Serialises frames into the `.tkzrec` wire format.
///
/// Streaming-friendly on purpose: `record` (a later ticket) creates one over the output file
/// and calls `append` from the pty read handler; nothing is buffered beyond the current frame.
public struct RecordingWriter: Sendable {
    public let header: RecordingHeader

    public init(header: RecordingHeader) {
        self.header = header
    }

    /// The header line, including its trailing newline. Write this once, before any frame.
    public func headerLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(header)
        data.append(0x0A)
        return data
    }

    /// One frame in wire form.
    public func encode(_ frame: RecordingFrame) -> Data {
        let payload = frame.payload
        var out = Data(capacity: payload.count + 13)
        out.append(frame.kind)
        out.appendLittleEndian(frame.elapsedNanos)
        out.appendLittleEndian(UInt32(payload.count))
        out.append(payload)
        return out
    }

    /// A whole recording in memory. Used by tests and by `replay` round-trips.
    public func encodeAll(_ frames: [RecordingFrame]) throws -> Data {
        var out = try headerLine()
        for frame in frames { out.append(encode(frame)) }
        return out
    }

    /// Writes a complete recording to disk (atomically).
    public func write(_ frames: [RecordingFrame], to url: URL) throws {
        try encodeAll(frames).write(to: url, options: .atomic)
    }
}

// MARK: - Reading

/// Parses a `.tkzrec` file. Tolerates a truncated trailing frame (a killed recording).
public struct RecordingReader: Sendable {
    public let header: RecordingHeader
    public let frames: [RecordingFrame]
    /// True when the file ended mid-frame; the frames before it are still valid.
    public let truncated: Bool

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        guard let newline = data.firstIndex(of: 0x0A) else { throw RecordingError.missingHeader }
        let headerData = data[data.startIndex..<newline]
        let header: RecordingHeader
        do {
            header = try JSONDecoder().decode(RecordingHeader.self, from: headerData)
        } catch {
            throw RecordingError.headerNotJSON(String(decoding: headerData.prefix(120), as: UTF8.self))
        }
        guard header.magic == RecordingHeader.currentMagic else { throw RecordingError.badMagic(header.magic) }
        guard header.version == RecordingHeader.currentVersion else {
            throw RecordingError.unsupportedVersion(header.version)
        }
        self.header = header

        var frames: [RecordingFrame] = []
        var truncated = false
        var index = data.index(after: newline)
        while index < data.endIndex {
            guard data.distance(from: index, to: data.endIndex) >= 13 else { truncated = true; break }
            let kind = data[index]
            let elapsed = data.littleEndian(UInt64.self, at: data.index(index, offsetBy: 1))
            let length = Int(data.littleEndian(UInt32.self, at: data.index(index, offsetBy: 9)))
            let payloadStart = data.index(index, offsetBy: 13)
            guard data.distance(from: payloadStart, to: data.endIndex) >= length else { truncated = true; break }
            let payloadEnd = data.index(payloadStart, offsetBy: length)
            let payload = Data(data[payloadStart..<payloadEnd])
            switch kind {
            case 0:
                frames.append(.output(elapsedNanos: elapsed, bytes: payload))
            case 1:
                if payload.count >= 4 {
                    let cols = payload.littleEndian(UInt16.self, at: payload.startIndex)
                    let rows = payload.littleEndian(UInt16.self, at: payload.index(payload.startIndex, offsetBy: 2))
                    frames.append(.resize(elapsedNanos: elapsed, cols: cols, rows: rows))
                }
            case 2:
                frames.append(.input(elapsedNanos: elapsed, bytes: payload))
            default:
                break  // forward compatibility: unknown kinds are skipped by length
            }
            index = payloadEnd
        }
        self.frames = frames
        self.truncated = truncated
    }

    /// Total bytes of pty output in the recording.
    public var outputByteCount: Int {
        frames.reduce(0) { total, frame in
            if case .output(_, let bytes) = frame { return total + bytes.count }
            return total
        }
    }

    /// Feeds the recording into a session, in order, as fast as possible.
    ///
    /// Timestamps are carried for tooling but deliberately not honoured: replay must be
    /// deterministic and instant so it can be asserted in tests. `input` frames are skipped
    /// (they were produced by the host, and the terminal never sees them).
    public func replay(into session: TerminalSession) throws {
        for frame in frames {
            switch frame {
            case .output(_, let bytes):
                session.write(ptyBytes: bytes)
            case .resize(_, let cols, let rows):
                try session.resize(cols: cols, rows: rows)
            case .input:
                continue
            }
        }
    }
}

// MARK: - Little-endian helpers

extension Data {
    fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// Reads `T` at `index` without assuming alignment. The caller guarantees the bytes exist.
    fileprivate func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at index: Index) -> T {
        var value = T.zero
        Swift.withUnsafeMutableBytes(of: &value) { destination in
            for offset in 0..<MemoryLayout<T>.size {
                destination[offset] = self[self.index(index, offsetBy: offset)]
            }
        }
        return T(littleEndian: value)
    }
}
