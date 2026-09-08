// SessionInputSeamTests — the M1 integration acceptance: input actually reaches the pty.
//
// TKZ-13 (keys) and TKZ-14 (mouse) were both fully unit-tested against a bare
// `GhosttyTerminalHandle`, but neither could be exercised through a real `TerminalSession`, because
// the session exposed no way in. These tests drive the seam itself, against a **real** session —
// same lock, same callbacks, same `IOContext` — and pin down the one thing that is easy to get
// wrong and impossible to see from a unit test: *which* input leaves through the session's own pty
// sink and which is handed back to the caller.
//
//   * key bytes and mouse reports are **returned** and must NOT appear in the sink,
//   * paste bytes are **written** by libghostty and must appear in the sink exactly once.
//
// Getting that backwards would double every paste, which no amount of encoder testing would catch.
import Foundation
import GhosttyVt
import Synchronization
import Testing

@testable import TkzTerminalCore

// MARK: - Rig

/// Everything the session hands to `onWritePty`, i.e. everything that would reach the shell if this
/// were a live pty. `Sendable` because the sink is `@Sendable` and may be called from any thread.
private final class PtySink: Sendable {
    private let buffer = Mutex<[UInt8]>([])

    /// Install with `session.setOnWritePty(sink.write)`.
    var write: @Sendable (Data) -> Void {
        { data in self.buffer.withLock { $0.append(contentsOf: data) } }
    }

    var bytes: [UInt8] { buffer.withLock { $0 } }
    var text: String { String(decoding: bytes, as: UTF8.self) }
    func clear() { buffer.withLock { $0.removeAll() } }
}

/// 20×6 cells of 10×20 px, matching `SelectionControllerTests` so expected selections are readable.
private let cols: UInt16 = 20
private let rows: UInt16 = 6
private let cellWidth: UInt32 = 10
private let cellHeight: UInt32 = 20

private let geometry = TerminalPixelGeometry(
    screenWidth: UInt32(cols) * cellWidth,
    screenHeight: UInt32(rows) * cellHeight,
    cellWidth: cellWidth,
    cellHeight: cellHeight
)

/// The middle of a cell.
private func pixels(col: Int, row: Int) -> SurfacePoint {
    SurfacePoint(x: Double(col) * 10 + 5, y: Double(row) * 20 + 10)
}

/// The right-hand edge of a cell: libghostty includes the cell under a drag only past its
/// horizontal midpoint, so a drag that should *end on* a cell has to aim here.
private func dragEnd(col: Int, row: Int) -> SurfacePoint {
    SurfacePoint(x: Double(col) * 10 + 9, y: Double(row) * 20 + 10)
}

/// A real session with its pty sink captured.
private func makeSession() throws -> (TerminalSession, PtySink) {
    let session = try TerminalSession(
        options: TerminalSessionOptions(
            cols: cols, rows: rows, cellWidthPx: cellWidth, cellHeightPx: cellHeight),
        label: "tkzmux.tests.inputseam")
    let sink = PtySink()
    session.setOnWritePty(sink.write)
    session.setMousePixelGeometry(geometry)
    return (session, sink)
}

private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

/// The kitty flag set real Claude Code pushes: `CSI > 5 u` = DISAMBIGUATE + REPORT_ALTERNATES,
/// confirmed against `Fixtures/claude-boot.tkzrec` in `KeyEncoderTests`.
private let claudeCodeFlags = "\u{1b}[>5u"

// MARK: - Tests

@Suite struct SessionInputSeamTests {
    // MARK: Keyboard

    /// The acceptance nobody could make all milestone: a `KeyPress` becomes the right bytes when it
    /// goes through a live `TerminalSession`, both bare and under the flags Claude Code sets.
    @Test func encodeKeyProducesTheRealBytesThroughTheSession() throws {
        let (session, sink) = try makeSession()

        let enter = KeyPress(key: GHOSTTY_KEY_ENTER)
        let ctrlC = KeyPress(
            key: GHOSTTY_KEY_C, mods: [.control], text: "c", unshiftedCodepoint: 0x63)
        let shiftEnter = KeyPress(key: GHOSTTY_KEY_ENTER, mods: [.shift], consumedMods: [.shift])

        // Legacy: what a plain shell sees.
        #expect(try session.encodeKey(enter) == [0x0D])
        #expect(try session.encodeKey(ctrlC) == [0x03])

        // Claude Code's real flag set (`CSI > 5 u` = DISAMBIGUATE | REPORT_ALTERNATES).
        session.write(ptyText: claudeCodeFlags)
        #expect(session.kittyKeyboardFlags == 5)
        sink.clear()

        // Enter keeps its legacy byte — flags 5 has no REPORT_ALL, so the carve-out applies.
        #expect(try session.encodeKey(enter) == [0x0D])
        // Shift+Enter is the one Claude Code depends on.
        #expect(try session.encodeKey(shiftEnter) == bytes("\u{1b}[13;2u"))
        // DISAMBIGUATE *is* in the set, so Ctrl-C becomes the kitty form rather than 0x03.
        #expect(try session.encodeKey(ctrlC) == bytes("\u{1b}[99;5u"))

        // Encoding writes nothing: the view layer owns the transport for key bytes.
        #expect(sink.bytes.isEmpty)
    }

    /// The encoder re-reads the terminal's mode state on every call, so a mode change between two
    /// presses is picked up with no bookkeeping in the view layer.
    @Test func encodeKeyFollowsTheTerminalsCurrentModes() throws {
        let (session, _) = try makeSession()
        let up = KeyPress(key: GHOSTTY_KEY_ARROW_UP)
        #expect(try session.encodeKey(up) == bytes("\u{1b}[A"))
        session.write(ptyText: "\u{1b}[?1h")  // DECCKM
        #expect(try session.encodeKey(up) == bytes("\u{1b}OA"))
    }

    // MARK: Paste

    /// A multi-line paste into a bracketed-paste program: the framed bytes leave through the
    /// session's **own** sink, and exactly once. A caller that also wrote the returned value would
    /// double every paste — which is why `pasteText` returns an outcome and no bytes at all.
    @Test func pasteGoesOutThroughTheSessionsPtySinkExactlyOnce() throws {
        let (session, sink) = try makeSession()
        session.write(ptyText: "\u{1b}[?2004h")
        sink.clear()

        let outcome = try session.pasteText("line one\nline two", source: .clipboard, allowUnsafe: false)
        #expect(outcome == .written)
        #expect(sink.text == "\u{1b}[200~line one\nline two\u{1b}[201~")
        #expect(sink.text.components(separatedBy: "\u{1b}[200~").count - 1 == 1)
    }

    /// Without bracketed paste the same text is command injection: nothing is written until the
    /// caller confirms, and then it is written once.
    @Test func unsafePasteWritesNothingUntilItIsAllowed() throws {
        let (session, sink) = try makeSession()

        #expect(try session.pasteText("echo hi\nrm -rf /", source: .clipboard, allowUnsafe: false)
            == .rejectedUnsafe)
        #expect(sink.bytes.isEmpty)

        #expect(try session.pasteText("echo hi\nrm -rf /", source: .clipboard, allowUnsafe: true)
            == .written)
        // Outside a bracketed paste the newline becomes a carriage return.
        #expect(sink.text == "echo hi\rrm -rf /")
    }

    /// IME / dictation text uses `source: .text`. Measured here rather than assumed: the source
    /// only decides whether a *Kitty paste event* (mode 5522) may be produced — bracketing under
    /// mode 2004 still applies, and the bytes still leave through the session's own sink.
    @Test func textSourceStillGoesOutThroughTheSessionsSink() throws {
        let (session, sink) = try makeSession()

        #expect(try session.pasteText("にほんご", source: .text, allowUnsafe: false) == .written)
        #expect(sink.text == "にほんご")

        session.write(ptyText: "\u{1b}[?2004h")
        sink.clear()
        #expect(try session.pasteText("ok", source: .text, allowUnsafe: false) == .written)
        #expect(sink.text == "\u{1b}[200~ok\u{1b}[201~")
    }

    // MARK: Mouse

    /// SGR reporting through the session: the bytes come back to the caller, and the sink stays
    /// empty. The report itself is the same one `MouseEncoderTests` pins for cell (5, 2).
    @Test func mouseReportsAreReturnedNotWritten() throws {
        let (session, sink) = try makeSession()
        session.write(ptyText: "\u{1b}[?1000h\u{1b}[?1006h")
        sink.clear()
        #expect(session.isMouseTrackingEnabled)

        let press = MousePress(action: .press, button: .left, position: pixels(col: 5, row: 2))
        let down = try session.encodeMouse(press)
        #expect(down.map { String(decoding: $0, as: UTF8.self) } == "\u{1b}[<0;6;3M")

        let release = MousePress(action: .release, button: .left, position: pixels(col: 5, row: 2))
        let up = try session.encodeMouse(release)
        #expect(up.map { String(decoding: $0, as: UTF8.self) } == "\u{1b}[<0;6;3m")

        // The whole point: nothing reached the pty on its own.
        #expect(sink.bytes.isEmpty)
    }

    /// With tracking off the wheel scrolls the viewport instead and produces no bytes anywhere.
    @Test func wheelWithoutTrackingScrollsTheViewport() throws {
        let (session, sink) = try makeSession()
        for index in 0..<20 { session.write(ptyText: "line \(index)\r\n") }
        sink.clear()

        let outcome = try session.mouseWheel(rows: -3, at: pixels(col: 0, row: 0), mods: [])
        #expect(outcome == .scrolledViewport(rows: -3))
        #expect(sink.bytes.isEmpty)
    }

    // MARK: Selection

    /// Press, drag, release, copy — the whole gesture through the session's lock.
    @Test func selectionRoundTripsThroughTheSession() throws {
        let (session, sink) = try makeSession()
        session.write(ptyText: "hello world\r\nsecond line")
        sink.clear()

        #expect(try session.selectionPress(at: pixels(col: 0, row: 0), timestamp: 1) == false)
        #expect(try session.selectionDrag(to: dragEnd(col: 4, row: 0)) == true)
        try session.selectionRelease(at: dragEnd(col: 4, row: 0))

        #expect(session.copySelectionText() == "hello")
        #expect(session.selectionClickCount == 1)
        #expect(session.selectionAutoscrollDirection == .none)
        #expect(sink.bytes.isEmpty)

        session.clearSelection()
        #expect(session.copySelectionText() == nil)
    }

    /// A double click selects the word under the pointer, which is what proves the repeat interval
    /// actually reaches libghostty through `selectionDoubleClickInterval`.
    @Test func doubleClickSelectsAWord() throws {
        let (session, _) = try makeSession()
        session.selectionDoubleClickInterval = 0.5
        session.write(ptyText: "hello world")

        _ = try session.selectionPress(at: pixels(col: 7, row: 0), timestamp: 1)
        #expect(try session.selectionPress(at: pixels(col: 7, row: 0), timestamp: 1.1) == true)
        #expect(session.selectionClickCount == 2)
        #expect(session.copySelectionText() == "world")
    }

    /// OSC 8 through the seam: a surface point resolves to the run of cells sharing the URI.
    @Test func hyperlinkRunResolvesFromASurfacePoint() throws {
        let (session, _) = try makeSession()
        session.write(ptyText: "\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\ after")

        let run = session.hyperlinkRun(at: pixels(col: 1, row: 0))
        #expect(run?.uri == "https://example.com")
        #expect(run?.columns == 0...3)
        #expect(run?.row == 0)
        #expect(session.hyperlinkRun(at: pixels(col: 8, row: 0)) == nil)
    }

    // MARK: Restore

    /// The double-free / stale-handle trap. `restore(from:)` swaps the terminal handle, and
    /// `SelectionController` retains the handle it was built with — so all three input objects are
    /// rebuilt inside the restore. If they were not, this test would either read the discarded
    /// terminal (selection returns the wrong text, or nothing) or crash on the old handle's free.
    @Test func restoreRebuildsTheInputObjects() throws {
        let (session, sink) = try makeSession()
        session.write(ptyText: claudeCodeFlags)
        session.write(ptyText: "\u{1b}[?2004h")
        session.write(ptyText: "hello world\r\nsecond line")
        let snapshot = try session.snapshot()

        // Prove the *old* objects worked, then throw their terminal away.
        _ = try session.selectionPress(at: pixels(col: 0, row: 0), timestamp: 1)
        _ = try session.selectionDrag(to: dragEnd(col: 4, row: 0))
        #expect(session.copySelectionText() == "hello")

        try session.restore(from: snapshot)
        sink.clear()

        // Keys: the encoder is fresh and reads the restored terminal's modes.
        #expect(try session.encodeKey(KeyPress(key: GHOSTTY_KEY_ENTER)) == [0x0D])
        #expect(try session.encodeKey(
            KeyPress(key: GHOSTTY_KEY_ENTER, mods: [.shift], consumedMods: [.shift]))
            == bytes("\u{1b}[13;2u"))

        // Selection: a whole new gesture against the restored grid.
        #expect(try session.selectionPress(at: pixels(col: 6, row: 0), timestamp: 2) == false)
        #expect(try session.selectionDrag(to: dragEnd(col: 10, row: 0)) == true)
        try session.selectionRelease(at: dragEnd(col: 10, row: 0))
        #expect(session.copySelectionText() == "world")

        // Paste: WRITE_PTY was reinstalled on the new handle, so the sink still receives.
        #expect(sink.bytes.isEmpty)
        #expect(try session.pasteText("x\ny", source: .clipboard, allowUnsafe: false) == .written)
        #expect(sink.text == "\u{1b}[200~x\ny\u{1b}[201~")

        // And the mouse encoder kept the geometry the view pushed before the restore.
        session.write(ptyText: "\u{1b}[?1000h\u{1b}[?1006h")
        sink.clear()
        let report = try session.encodeMouse(
            MousePress(action: .press, button: .left, position: pixels(col: 5, row: 2)))
        #expect(report.map { String(decoding: $0, as: UTF8.self) } == "\u{1b}[<0;6;3M")
        #expect(sink.bytes.isEmpty)
    }
}
