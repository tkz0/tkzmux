// RecordingTests — the `.tkzrec` container and replay (M1.3 / TKZ-9).
//
// The fixtures here are *synthetic*: they are built in code so replay is testable before the pty
// layer exists. `tkzmux-vtdump record` produces the same format from a real session.
import Foundation
import Testing
@testable import TkzTerminalCore

private func syntheticRecording(cols: UInt16 = 20, rows: UInt16 = 4) throws -> (Data, [RecordingFrame]) {
    let header = RecordingHeader(
        cols: cols, rows: rows,
        argv: ["/bin/zsh", "-zsh", "-l"],
        env: ["TERM": "xterm-ghostty", "TERM_PROGRAM": "ghostty", "COLORTERM": "truecolor"],
        startedAt: 1_757_000_000,
        note: "synthetic"
    )
    let frames: [RecordingFrame] = [
        .output(elapsedNanos: 0, bytes: Data("hello".utf8)),
        .output(elapsedNanos: 1_000_000, bytes: Data(" world\r\n".utf8)),
        .output(elapsedNanos: 2_500_000, bytes: Data("\u{1b}[1;32msecond line\u{1b}[0m".utf8)),
    ]
    return (try RecordingWriter(header: header).encodeAll(frames), frames)
}

@Test func recordingRoundTripsThroughTheWireFormat() throws {
    let (data, frames) = try syntheticRecording()
    let reader = try RecordingReader(data: data)

    #expect(reader.header.magic == "tkzrec")
    #expect(reader.header.version == 1)
    #expect(reader.header.cols == 20)
    #expect(reader.header.rows == 4)
    #expect(reader.header.argv == ["/bin/zsh", "-zsh", "-l"])
    #expect(reader.header.env["TERM"] == "xterm-ghostty")
    #expect(reader.frames == frames)
    #expect(reader.truncated == false)
    #expect(reader.outputByteCount == frames.reduce(0) { total, frame in
        if case .output(_, let bytes) = frame { return total + bytes.count }
        return total
    })
}

@Test func headerIsOneInspectableJSONLine() throws {
    let (data, _) = try syntheticRecording()
    let newline = try #require(data.firstIndex(of: 0x0A))
    let line = data[data.startIndex..<newline]
    let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    #expect(object["magic"] as? String == "tkzrec")
    #expect(object["cols"] as? Int == 20)
}

@Test func resizeFramesRoundTrip() throws {
    let header = RecordingHeader(cols: 80, rows: 24)
    let frames: [RecordingFrame] = [
        .output(elapsedNanos: 0, bytes: Data("x".utf8)),
        .resize(elapsedNanos: 10, cols: 100, rows: 30),
        .input(elapsedNanos: 20, bytes: Data("ls\r".utf8)),
    ]
    let data = try RecordingWriter(header: header).encodeAll(frames)
    #expect(try RecordingReader(data: data).frames == frames)
}

@Test func truncatedFinalFrameIsTolerated() throws {
    let (data, frames) = try syntheticRecording()
    // Simulate a recording killed mid-write: cut the file inside the last frame's payload.
    let cut = data.prefix(data.count - 4)
    let reader = try RecordingReader(data: Data(cut))
    #expect(reader.truncated == true)
    #expect(reader.frames == Array(frames.dropLast()))
}

@Test func aMissingOrForeignHeaderIsRejected() throws {
    #expect(throws: RecordingError.missingHeader) { try RecordingReader(data: Data("no newline".utf8)) }
    #expect(throws: RecordingError.self) { try RecordingReader(data: Data("not json\n".utf8)) }
    let foreign = Data(#"{"magic":"asciinema","version":1,"cols":80,"rows":24,"argv":[],"env":{},"startedAt":0}"#.utf8) + Data([0x0A])
    #expect(throws: RecordingError.badMagic("asciinema")) { try RecordingReader(data: foreign) }
}

// MARK: - Replay

@Test func replayReproducesTheExpectedPlainScreen() throws {
    let (data, _) = try syntheticRecording()
    let reader = try RecordingReader(data: data)
    let session = try TerminalSession(
        options: TerminalSessionOptions(cols: reader.header.cols, rows: reader.header.rows)
    )
    try reader.replay(into: session)
    #expect(try session.formatted() == "hello world\nsecond line")
}

@Test func replayAppliesResizeFrames() throws {
    let header = RecordingHeader(cols: 20, rows: 4)
    let frames: [RecordingFrame] = [
        .output(elapsedNanos: 0, bytes: Data("before\r\n".utf8)),
        .resize(elapsedNanos: 1, cols: 40, rows: 8),
        .output(elapsedNanos: 2, bytes: Data("after".utf8)),
    ]
    let data = try RecordingWriter(header: header).encodeAll(frames)
    let reader = try RecordingReader(data: data)
    let session = try TerminalSession(options: TerminalSessionOptions(cols: 20, rows: 4))
    try reader.replay(into: session)
    #expect(session.size == (40, 8))
    #expect(try session.formatted() == "before\nafter")
}

@Test func replayIsIdenticalThroughAFileOnDisk() throws {
    let (data, _) = try syntheticRecording()
    let url = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-recording-\(UUID().uuidString).tkzrec")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)

    let reader = try RecordingReader(contentsOf: url)
    let session = try TerminalSession(
        options: TerminalSessionOptions(cols: reader.header.cols, rows: reader.header.rows)
    )
    try reader.replay(into: session)
    #expect(try session.formatted() == "hello world\nsecond line")
}

@Test func replayOfClaudeStyleStartupLeavesTheExpectedModes() throws {
    // The same acceptance as TerminalSessionTests, but driven end to end through a recording.
    let header = RecordingHeader(cols: 120, rows: 40, argv: ["claude"], env: ["TERM": "xterm-ghostty"])
    let startup = "\u{1b}[?1049h\u{1b}[?2004h\u{1b}[>1u\u{1b}[?1000h\u{1b}[?1006h"
    let data = try RecordingWriter(header: header)
        .encodeAll([.output(elapsedNanos: 0, bytes: Data(startup.utf8))])
    let reader = try RecordingReader(data: data)
    let session = try TerminalSession(options: TerminalSessionOptions(cols: 120, rows: 40))
    try reader.replay(into: session)

    #expect(session.mode(1049) == true)
    #expect(session.mode(2004) == true)
    #expect(session.kittyKeyboardFlags == 1)
    #expect(session.mouseTrackingEnabled == true)
}

// MARK: - Fixture on disk

/// The one committed fixture is synthetic (generated by this ticket). `claude-boot.tkzrec` and the
/// golden screens arrive with `tkzmux-vtdump record`, which needs the pty layer.
@Test func syntheticFixtureReplaysToItsGoldenScreen() throws {
    let url = try #require(Bundle.module.url(forResource: "synthetic-basic", withExtension: "tkzrec", subdirectory: "Fixtures"))
    let reader = try RecordingReader(contentsOf: url)
    #expect(reader.header.env["TERM"] == "xterm-ghostty")
    #expect(reader.frames.count == 4)

    let session = try TerminalSession(
        options: TerminalSessionOptions(cols: reader.header.cols, rows: reader.header.rows)
    )
    try reader.replay(into: session)

    #expect(try session.formatted() == "hello world\nsecond line")
    #expect(session.title == "claude")
    #expect(session.mode(1049) == true)
    #expect(session.mode(2004) == true)
    #expect(session.kittyKeyboardFlags == 1)
    #expect(session.mouseTrackingEnabled == true)
}
