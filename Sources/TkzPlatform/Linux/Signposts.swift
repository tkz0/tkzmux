// Signposts on Linux (WOR-304 S2): `TkzSignposter` with `OSSignposter`'s call shape.
//
// Off by default, and then each call is one relaxed atomic load. With `TKZMUX_TRACE=<file>` set
// when the first signposter is created, intervals and events are written to that file as Chrome
// trace JSON (the "JSON Object Format" of the Trace Event Format), which ui.perfetto.dev and
// chrome://tracing open. An interval is a nestable async pair (`ph` "b"/"e") keyed by category
// and signpost id, because begin and end may run on different threads; an event is an instant
// ("i"). Timestamps are `Clocks.monotonicNanos` (CLOCK_MONOTONIC) in microseconds.
//
// The file is valid JSON after every event: each write overwrites the closing `]}` with the event
// and a new `]}`, so a trace survives the process being killed.

#if os(Linux)
import Glibc
import Synchronization

/// Identifies one signpost interval, as `OSSignpostID` does.
public struct TkzSignpostID: Sendable, Hashable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The id for intervals that never overlap, `OSSignpostID.exclusive`'s value.
    public static let exclusive = TkzSignpostID(0xEEEE_B0B5_B2B2_EEEE)
}

/// What `beginInterval` returns and `endInterval` takes, as `OSSignpostIntervalState`.
public struct TkzSignpostIntervalState: Sendable {
    let id: TkzSignpostID
    /// Whether the begin was written; an end is written only if it was, so a trace never holds an
    /// unmatched end.
    let traced: Bool
}

/// The signposter every tkzmux module uses: a Chrome-trace writer on Linux, a no-op unless
/// `TKZMUX_TRACE` is set.
public struct TkzSignposter: Sendable {
    public let subsystem: String
    public let category: String
    /// The writer for tests; nil means the process-wide trace from `TKZMUX_TRACE`.
    private let writer: TraceWriter?

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        self.writer = nil
        TraceSession.start()
    }

    init(subsystem: String, category: String, writer: TraceWriter) {
        self.subsystem = subsystem
        self.category = category
        self.writer = writer
    }

    public func makeSignpostID() -> TkzSignpostID {
        TkzSignpostID(TraceSession.nextID.add(1, ordering: .relaxed).newValue)
    }

    public func beginInterval(_ name: StaticString, id: TkzSignpostID = .exclusive) -> TkzSignpostIntervalState {
        guard let writer = activeWriter else { return TkzSignpostIntervalState(id: id, traced: false) }
        writer.write(TraceEvent(name: "\(name)", category: category, phase: .begin, id: id))
        return TkzSignpostIntervalState(id: id, traced: true)
    }

    public func endInterval(_ name: StaticString, _ state: TkzSignpostIntervalState) {
        guard state.traced, let writer = activeWriter else { return }
        writer.write(TraceEvent(name: "\(name)", category: category, phase: .end, id: state.id))
    }

    public func emitEvent(_ name: StaticString, id: TkzSignpostID = .exclusive) {
        guard let writer = activeWriter else { return }
        writer.write(TraceEvent(name: "\(name)", category: category, phase: .instant, id: id))
    }

    private var activeWriter: TraceWriter? {
        if let writer { return writer }
        guard TraceSession.enabled.load(ordering: .relaxed) else { return nil }
        return TraceSession.writer
    }
}

/// The process-wide trace, opened from `TKZMUX_TRACE` by the first signposter.
enum TraceSession {
    /// True once the trace file is open. The only thing a disabled signpost reads.
    static let enabled = Atomic<Bool>(false)

    static let nextID = Atomic<UInt64>(0)

    static let writer: TraceWriter? = {
        guard let raw = getenv("TKZMUX_TRACE"), raw.pointee != 0,
              let writer = TraceWriter(path: String(cString: raw)) else { return nil }
        enabled.store(true, ordering: .relaxed)
        return writer
    }()

    /// Opens the trace if `TKZMUX_TRACE` is set; only the first call does any work.
    static func start() {
        _ = writer
    }
}

/// Caches each thread's kernel id for ``TraceWriter/currentThreadID()``.
private let traceThreadIDKey: pthread_key_t = {
    var key = pthread_key_t()
    pthread_key_create(&key, nil)
    return key
}()

/// One trace event.
struct TraceEvent: Equatable {
    enum Phase: String {
        case begin = "b"
        case end = "e"
        case instant = "i"
    }

    var name: String
    var category: String
    var phase: Phase
    var id: TkzSignpostID

    /// The event as one JSON object.
    func json(timestampNanos: UInt64, pid: Int32, tid: Int32) -> String {
        let micros = "\(timestampNanos / 1000).\(String(timestampNanos % 1000 + 1000).dropFirst())"
        var fields = [
            "\"name\":\(traceJSONString(name))",
            "\"cat\":\(traceJSONString(category))",
            "\"ph\":\"\(phase.rawValue)\"",
            "\"ts\":\(micros)",
            "\"pid\":\(pid)",
            "\"tid\":\(tid)",
        ]
        switch phase {
        case .begin, .end:
            fields.append("\"id\":\"0x\(String(id.rawValue, radix: 16))\"")
        case .instant:
            fields.append("\"s\":\"t\"")
        }
        return "{" + fields.joined(separator: ",") + "}"
    }
}

/// `text` as a JSON string literal.
func traceJSONString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case _ where scalar.value < 0x20:
            let hex = String(scalar.value, radix: 16)
            out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

/// Appends events to a Chrome trace JSON file, keeping it valid JSON after every write.
final class TraceWriter: Sendable {
    static let header = "{\"displayTimeUnit\":\"ms\",\"traceEvents\":[\n"
    static let trailer = "\n]}\n"

    private struct Cursor {
        /// Where the next write starts: just past the last event, over the trailer.
        var offset: Int64
        var events: Int
    }

    private let fd: Int32
    private let pid: Int32
    private let cursor: Mutex<Cursor>

    /// Creates or truncates the file at `path` and writes a process-name record. Nil if the file
    /// cannot be opened.
    init?(path: String) {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        self.fd = fd
        self.pid = getpid()
        let header = Array(Self.header.utf8)
        cursor = Mutex(Cursor(offset: Int64(header.count), events: 0))
        _ = header.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        append("{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":\(pid),\"args\":{\"name\":\"tkzmux\"}}")
    }

    deinit { close(fd) }

    func write(_ event: TraceEvent) {
        append(event.json(timestampNanos: Clocks.monotonicNanos, pid: pid, tid: currentThreadID()))
    }

    private func append(_ object: String) {
        cursor.withLock { cursor in
            let body = Array(((cursor.events == 0 ? "" : ",\n") + object).utf8)
            let bytes = body + Array(Self.trailer.utf8)
            let written = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(cursor.offset)) }
            guard written == bytes.count else { return }
            cursor.offset += Int64(body.count)
            cursor.events += 1
        }
    }

    /// The kernel thread id, so trace threads line up with `perf` and /proc. Glibc's `gettid()`
    /// is not importable, so it is read from /proc/thread-self once per thread and cached in a
    /// pthread key.
    func currentThreadID() -> Int32 {
        if let cached = pthread_getspecific(traceThreadIDKey) {
            return Int32(truncatingIfNeeded: Int(bitPattern: cached))
        }
        var link = [CChar](repeating: 0, count: 64)
        let count = readlink("/proc/thread-self", &link, link.count - 1)  // "<pid>/task/<tid>"
        let text = count > 0 ? String(decoding: link[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        guard let last = text.split(separator: "/").last, let tid = Int32(last) else { return 0 }
        pthread_setspecific(traceThreadIDKey, UnsafeRawPointer(bitPattern: Int(tid)))
        return tid
    }
}
#endif
