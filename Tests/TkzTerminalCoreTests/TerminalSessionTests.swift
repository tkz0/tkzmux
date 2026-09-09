// TerminalSessionTests — the VT bridge (M1.3 / TKZ-9).
//
// These assert the *contract* the rest of the milestone is built on: the byte sequences Claude
// Code actually emits leave the terminal in the state we expect, query replies come back through
// the WRITE_PTY callback with exactly the bytes a program expects, effects turn into events, and a
// snapshot round-trip reproduces the screen.
import Foundation
import Testing
import GhosttyVt
@testable import TkzTerminalCore

/// Collects everything a session emitted. `write(ptyBytes:)` is synchronous and the stream is
/// unbounded, so finishing the stream after the writes makes collection deterministic.
private func drain(_ session: TerminalSession) async -> [TerminalEvent] {
    session.finishEvents()
    var events: [TerminalEvent] = []
    for await event in session.events { events.append(event) }
    return events
}

/// A session whose pty writes are captured into a buffer.
private final class PtySink: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    var data: Data { lock.withLock { bytes } }
    func reset() { lock.withLock { bytes.removeAll() } }
}

private func makeSession(cols: UInt16 = 80, rows: UInt16 = 24) throws -> (TerminalSession, PtySink) {
    let session = try TerminalSession(options: TerminalSessionOptions(cols: cols, rows: rows))
    let sink = PtySink()
    session.setOnWritePty { data in sink.append(data) }
    return (session, sink)
}

// MARK: - Acceptance: the state Claude Code leaves the terminal in

@Test func claudeCodeStartupSequenceLeavesExpectedState() throws {
    let (session, _) = try makeSession()
    // The mechanism, sequence by sequence. NOTE: this is *not* byte-for-byte what Claude Code
    // 2.1.263 emits — the recorded fixture shows it pushes `CSI > 5 u`, not `CSI > 1 u`, and also
    // sets 1004 and 2031. `claudeBootFixtureLeavesTheExpectedTerminalState` in RecordingTests is
    // the test that pins reality; this one pins that each individual sequence is honoured.
    session.write(ptyText: "\u{1b}[?1049h")   // alt screen + save cursor
    session.write(ptyText: "\u{1b}[?2004h")   // bracketed paste
    session.write(ptyText: "\u{1b}[>1u")      // kitty keyboard: disambiguate
    session.write(ptyText: "\u{1b}[?1000h")   // normal mouse tracking
    session.write(ptyText: "\u{1b}[?1006h")   // SGR mouse format

    #expect(session.mode(1049) == true)
    #expect(session.mode(2004) == true)
    #expect(session.mode(1000) == true)
    #expect(session.mode(1006) == true)
    #expect(session.kittyKeyboardFlags == 1)   // GHOSTTY_KITTY_KEY_DISAMBIGUATE
    #expect(session.mouseTrackingEnabled == true)
}

// MARK: - Acceptance: query replies, exact bytes, through WRITE_PTY

@Test func deviceAttributesReplyExactBytes() throws {
    let (session, sink) = try makeSession()
    session.write(ptyText: "\u{1b}[c")
    // libghostty answers DA1 itself; no DEVICE_ATTRIBUTES callback is installed.
    // VT220 (62) with ANSI color (22).
    #expect(sink.text == "\u{1b}[?62;22c")
}

@Test func kittyFlagsQueryReplyExactBytes() throws {
    let (session, sink) = try makeSession()
    session.write(ptyText: "\u{1b}[>1u")
    sink.reset()
    session.write(ptyText: "\u{1b}[?u")
    #expect(sink.text == "\u{1b}[?1u")
}

@Test func decrqm2026ReplyExactBytes() throws {
    let (session, sink) = try makeSession()
    session.write(ptyText: "\u{1b}[?2026$p")
    #expect(sink.text == "\u{1b}[?2026;2$y")   // reset

    sink.reset()
    session.write(ptyText: "\u{1b}[?2026h")
    session.write(ptyText: "\u{1b}[?2026$p")
    #expect(sink.text == "\u{1b}[?2026;1$y")   // set
}

@Test func xtversionReportsOurIdentity() throws {
    let (session, sink) = try makeSession()
    session.write(ptyText: "\u{1b}[>q")
    #expect(sink.text.contains("tkzmux"))
}

@Test func sizeReportAnswersCurrentGeometry() throws {
    let session = try TerminalSession(
        options: TerminalSessionOptions(cols: 120, rows: 40, cellWidthPx: 9, cellHeightPx: 20)
    )
    let sink = PtySink()
    session.setOnWritePty { sink.append($0) }
    session.write(ptyText: "\u{1b}[18t")           // XTWINOPS: text area size in characters
    #expect(sink.text == "\u{1b}[8;40;120t")

    sink.reset()
    try session.resize(cols: 100, rows: 30)
    session.write(ptyText: "\u{1b}[18t")
    #expect(sink.text == "\u{1b}[8;30;100t")
}

// MARK: - Events

@Test func titleAndPwdBecomeEvents() async throws {
    let (session, _) = try makeSession()
    // Two titles in ONE write: proves the title/pwd values are read *inside* the callback, so a
    // burst of changes is not collapsed into whatever the terminal held when the write finished.
    session.write(ptyText: "\u{1b}]0;first\u{7}\u{1b}]0;second\u{7}")
    session.write(ptyText: "\u{1b}]7;file:///tmp/x\u{1b}\\")

    let events = await drain(session)
    #expect(events == [.title("first"), .title("second"), .pwd("file:///tmp/x")])
    #expect(session.title == "second")
    #expect(session.pwd == "file:///tmp/x")
}

@Test func bellNotificationAndProgressBecomeEvents() async throws {
    let (session, _) = try makeSession()
    session.write(ptyText: "\u{7}")
    session.write(ptyText: "\u{1b}]777;notify;Build;done\u{1b}\\")
    session.write(ptyText: "\u{1b}]9;4;1;42\u{1b}\\")
    session.write(ptyText: "\u{1b}]9;4;0\u{1b}\\")

    let events = await drain(session)
    #expect(events.contains(.bell))
    #expect(events.contains(.notification(title: "Build", body: "done")))
    #expect(events.contains(.progress(state: .set, value: 42)))
    #expect(events.contains(.progress(state: .remove, value: nil)))
}

@Test func osc52ClipboardWriteBecomesAnEvent() async throws {
    let (session, _) = try makeSession()
    let payload = Data("hello clipboard".utf8).base64EncodedString()
    session.write(ptyText: "\u{1b}]52;c;\(payload)\u{1b}\\")

    let events = await drain(session)
    #expect(events == [.clipboardWrite("hello clipboard")])
}

@Test func exitAndForegroundArePublishedByTheHost() async throws {
    let (session, _) = try makeSession()
    session.noteForeground(pgid: 4242, path: "/bin/zsh", cwd: "/tmp")
    session.noteExit(.exited(code: 0))

    let events = await drain(session)
    #expect(events == [.foreground(pgid: 4242, path: "/bin/zsh", cwd: "/tmp"), .exited(.exited(code: 0))])
}

@Test func renderSignalFiresAfterIngestion() throws {
    let (session, _) = try makeSession()
    let counter = Counter()
    session.setRenderSignal { counter.increment() }
    session.write(ptyText: "hello")
    session.write(ptyText: " world")
    #expect(counter.value == 2)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

// MARK: - Screen content

@Test func plainFormatterRendersTheScreen() throws {
    let (session, _) = try makeSession(cols: 20, rows: 3)
    session.write(ptyText: "one\r\n\u{1b}[1;32mtwo\u{1b}[0m\r\nthree")
    #expect(try session.formatted() == "one\ntwo\nthree")
}

// MARK: - Acceptance: snapshot round-trip

@Test func snapshotRoundTripReproducesTheScreen() throws {
    let (session, _) = try makeSession(cols: 40, rows: 6)
    for line in 0..<200 { session.write(ptyText: "scrollback line \(line)\r\n") }
    session.write(ptyText: "\u{1b}[31mred tail\u{1b}[0m")

    let before = try session.formatted()
    let beforeVT = try session.formatted(GHOSTTY_FORMATTER_FORMAT_VT)
    let blob = try session.snapshot()
    #expect(!blob.isEmpty)

    try session.restore(from: blob)
    #expect(try session.formatted() == before)
    #expect(try session.formatted(GHOSTTY_FORMATTER_FORMAT_VT) == beforeVT)
    #expect(session.size == (40, 6))
}

@Test func restoredSessionStillAnswersQueries() throws {
    let (session, sink) = try makeSession(cols: 30, rows: 5)
    session.write(ptyText: "hello\r\n")
    let blob = try session.snapshot()
    try session.restore(from: blob)

    // The restored terminal is a *new* C object: options and callbacks must have been re-applied.
    sink.reset()
    session.write(ptyText: "\u{1b}[c")
    #expect(sink.text == "\u{1b}[?62;22c")
    sink.reset()
    session.write(ptyText: "\u{1b}[>q")
    #expect(sink.text.contains("tkzmux"))
}

// MARK: - DEC 2026 watchdog

@Test func watchdogRendersWhenModeIsNotSet() {
    var watchdog = SyncOutputWatchdog()
    let now = ContinuousClock.now
    #expect(watchdog.evaluate(modeActive: false, now: now) == .render)
    #expect(watchdog.isTracking == false)
}

@Test func watchdogSkipsFramesUntilTheTimeout() {
    var watchdog = SyncOutputWatchdog(timeout: .seconds(1))
    let start = ContinuousClock.now
    #expect(watchdog.evaluate(modeActive: true, now: start) == .skipFrame)
    #expect(watchdog.evaluate(modeActive: true, now: start.advanced(by: .milliseconds(500))) == .skipFrame)
    #expect(watchdog.evaluate(modeActive: true, now: start.advanced(by: .milliseconds(999))) == .skipFrame)
    #expect(watchdog.evaluate(modeActive: true, now: start.advanced(by: .seconds(1))) == .forceOffAndRender)
}

@Test func watchdogRestartsAfterTheModeClears() {
    var watchdog = SyncOutputWatchdog(timeout: .seconds(1))
    let start = ContinuousClock.now
    #expect(watchdog.evaluate(modeActive: true, now: start) == .skipFrame)
    #expect(watchdog.evaluate(modeActive: false, now: start.advanced(by: .milliseconds(10))) == .render)
    #expect(watchdog.evaluate(modeActive: true, now: start.advanced(by: .milliseconds(20))) == .skipFrame)
    #expect(watchdog.evaluate(modeActive: true, now: start.advanced(by: .milliseconds(900))) == .skipFrame)
}

@Test func sessionForcesMode2026OffAfterTheTimeout() throws {
    let (session, _) = try makeSession()
    let start = ContinuousClock.now

    #expect(session.syncOutputDecision(now: start) == .render)
    session.write(ptyText: "\u{1b}[?2026h")
    #expect(session.mode(2026) == true)
    #expect(session.syncOutputDecision(now: start) == .skipFrame)
    #expect(session.syncOutputDecision(now: start.advanced(by: .milliseconds(500))) == .skipFrame)
    #expect(session.mode(2026) == true)
    #expect(session.syncOutputDecision(now: start.advanced(by: .seconds(1))) == .forceOffAndRender)
    #expect(session.mode(2026) == false)
}

// MARK: - Scrollback configuration

@Test func scrollbackLimitIsAppliedFromOptions() throws {
    // The library default is only 10 000 bytes; the session must raise it (docs/design.md: 24 MiB).
    let session = try TerminalSession(options: TerminalSessionOptions(cols: 40, rows: 5))
    for line in 0..<3000 { session.write(ptyText: "line \(line)\r\n") }
    #expect(session.scrollbackRows > 2000)
}

// MARK: - Scroll metrics (TKZ-45)
//
// The scroll indicator's whole input. libghostty offers no change notification for scroll state, so
// these pin the numbers the view's geometry is derived from — and in particular that the alternate
// screen reports its own rows rather than the primary's scrollback.

/// Scrolls the viewport by `rows` (negative is up) — the same call `MouseEncoder.wheel` makes.
private func scrollViewport(_ session: TerminalSession, rows: Int) {
    session.withTerminal { terminal in
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = rows
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }
}

@Test func aFreshSessionHasNothingToScroll() throws {
    let (session, _) = try makeSession(cols: 40, rows: 10)
    let metrics = session.scrollMetrics
    #expect(metrics.total == 10)
    #expect(metrics.visible == 10)
    #expect(metrics.offset == 0)
    #expect(metrics.isAlternateScreen == false)
    // Everything fits, so the view draws no thumb at all.
    #expect(metrics.isScrollable == false)
    #expect(metrics.scrollableRows == 0)
}

@Test func scrollbackGrowsTheTotalAndPinsTheViewportToTheBottom() throws {
    let (session, _) = try makeSession(cols: 40, rows: 10)
    for line in 0..<200 { session.write(ptyText: "line \(line)\r\n") }

    let metrics = session.scrollMetrics
    #expect(metrics.total == 201)
    #expect(metrics.visible == 10)
    #expect(metrics.isScrollable)
    // Following the active area: the viewport sits at the very bottom of the scrollable area.
    #expect(metrics.offset == metrics.scrollableRows)
}

@Test func scrollingUpMovesTheOffsetAndNothingElse() throws {
    let (session, _) = try makeSession(cols: 40, rows: 10)
    for line in 0..<200 { session.write(ptyText: "line \(line)\r\n") }
    let before = session.scrollMetrics

    scrollViewport(session, rows: -10)

    let after = session.scrollMetrics
    #expect(after.offset == before.offset - 10)
    #expect(after.total == before.total)
    #expect(after.visible == before.visible)
}

/// Claude Code's TUI lives on the alternate screen, which has no scrollback — the acceptance
/// criterion is that it shows no thumb.
///
/// Note *why* it reports `total == visible`: it is describing the alternate screen's own rows, not
/// the primary's. Reading `ACTIVE_SCREEN` rather than inferring the screen from `total == len`
/// costs one O(1) get and removes the guess.
@Test func theAlternateScreenReportsItsOwnRowsAndIsFlaggedAsSuch() throws {
    let (session, _) = try makeSession(cols: 40, rows: 10)
    for line in 0..<200 { session.write(ptyText: "line \(line)\r\n") }
    scrollViewport(session, rows: -10)
    let primary = session.scrollMetrics

    session.write(ptyText: "\u{1b}[?1049h")
    let alternate = session.scrollMetrics
    #expect(alternate.isAlternateScreen)
    #expect(alternate.total == 10)
    #expect(alternate.visible == 10)
    #expect(alternate.isScrollable == false)

    // Leaving it restores the primary screen's position exactly, so the thumb comes back where the
    // user left it rather than snapped to the bottom.
    session.write(ptyText: "\u{1b}[?1049l")
    #expect(session.scrollMetrics == primary)
}
