// RecordingTests — the `.tkzrec` container and replay (M1.3 / TKZ-9).
//
// Two kinds of fixture live here:
//   * synthetic ones built in code (and `Fixtures/synthetic-basic.tkzrec`), used to test the
//     container itself — they are named and described as synthetic;
//   * real recordings made with `tkzmux-vtdump record` (`zsh-ls-color`, `claude-boot`,
//     `claude-tool-run`), sanitized before committing — see `Fixtures/README.md`.
import Foundation
import Testing
import GhosttyVt
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

// MARK: - Real recorded fixtures
//
// Captured with `tkzmux-vtdump record` under the full `TerminalEnvironment` (TERM=xterm-ghostty,
// TERM_PROGRAM=ghostty, bundled TERMINFO) in a throwaway directory, then sanitized — see
// Fixtures/README.md for exactly what was scrubbed. `claude-boot` and `claude-tool-run` end with a
// SIGKILL while Claude Code is still running, so the fixture preserves the modes a live program
// leaves set instead of its teardown sequence.

private func fixture(_ name: String) throws -> RecordingReader {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "tkzrec", subdirectory: "Fixtures"))
    return try RecordingReader(contentsOf: url)
}

private func golden(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    let text = try String(contentsOf: url, encoding: .utf8)
    // The goldens are written with a trailing newline so they are ordinary text files.
    return text.hasSuffix("\n") ? String(text.dropLast()) : text
}

private func replayed(_ name: String) throws -> TerminalSession {
    let reader = try fixture(name)
    let session = try TerminalSession(
        options: TerminalSessionOptions(cols: reader.header.cols, rows: reader.header.rows)
    )
    try reader.replay(into: session)
    return session
}

@Test func claudeBootFixtureReplaysToItsGoldenScreen() throws {
    let session = try replayed("claude-boot")
    #expect(try session.formatted() == (try golden("claude-boot")))
}

/// The acceptance for the whole VT bridge: what a *real* Claude Code leaves the terminal in.
@Test func claudeBootFixtureLeavesTheExpectedTerminalState() throws {
    let session = try replayed("claude-boot")
    #expect(session.mode(1049) == true)   // alt screen
    #expect(session.mode(2004) == true)   // bracketed paste
    #expect(session.mode(1000) == true)   // mouse tracking
    #expect(session.mode(1006) == true)   // SGR mouse
    #expect(session.mode(1004) == true)   // focus events
    #expect(session.mouseTrackingEnabled == true)
    // Measured, not assumed: the recording contains `ESC [ > 5 u`, so Claude Code 2.1.263 pushes
    // DISAMBIGUATE | REPORT_ALL, not the `CSI > 1 u` / flags 1 the planning notes recorded. Key
    // encoding (TKZ-13) must be exercised against 5, because REPORT_ALL changes how every key —
    // Shift+Enter included — is encoded.
    #expect(session.kittyKeyboardFlags == 5)
    #expect(session.title == "✳ Claude Code")
}

@Test func claudeToolRunFixtureReplaysToItsGoldenScreen() throws {
    let session = try replayed("claude-tool-run")
    #expect(try session.formatted() == (try golden("claude-tool-run")))
    #expect(session.mode(1049) == true)
    #expect(session.kittyKeyboardFlags == 5)
    #expect(session.mouseTrackingEnabled == true)
    #expect(session.title == "✳ Echo hi")   // OSC 0/2 title tracking a running tool
}

@Test func zshLsColorFixtureReplaysToItsGoldenScreen() throws {
    let session = try replayed("zsh-ls-color")
    #expect(try session.formatted() == (try golden("zsh-ls-color")))
    // A plain shell touches none of the Claude Code machinery.
    #expect(session.mode(1049) == false)
    #expect(session.kittyKeyboardFlags == 0)
    #expect(session.mouseTrackingEnabled == false)
    // The colours really are in there: `ls --color` styles the symlink, the executable and the dir.
    let vt = try session.formatted(GHOSTTY_FORMATTER_FORMAT_VT)
    #expect(vt.contains("\u{1b}[38;5;5m"))   // magenta symlink
    #expect(vt.contains("\u{1b}[38;5;1m"))   // red executable
    #expect(vt.contains("\u{1b}[38;5;6m"))   // cyan directory
}

@Test func recordedFixturesCarryOnlyTheVtRelevantEnvironment() throws {
    for name in ["zsh-ls-color", "claude-boot", "claude-tool-run"] {
        let header = try fixture(name).header
        #expect(header.env["TERM"] == "xterm-ghostty")
        #expect(header.env["TERM_PROGRAM"] == "ghostty")
        // A recording must never carry the recording user's environment.
        #expect(Set(header.env.keys).isSubset(of: [
            "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM", "LANG",
        ]))
        #expect(header.argv.isEmpty == false)
    }
}
