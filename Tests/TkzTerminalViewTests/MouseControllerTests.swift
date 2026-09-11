// MouseController, headless (M1.8 / TKZ-14).
//
// Two kinds of test live here, and the distinction matters:
//
//   * **pure policy** — the report-vs-select rule, the OSC 8 scheme allow-list, the AppKit button
//     numbering and the wheel row accumulator. No terminal, no view, no GPU.
//   * **routing against a real libghostty terminal** — `LiveTestTerminal` is not a stub: it owns a
//     `GhosttyTerminalHandle`, a `MouseEncoder` and a `SelectionController`, so tracking modes,
//     click-count granularity, held-button state and OSC 8 runs are the library's real answers.
//     It records the calls it receives so the routing decision is observable too.
//
// The one thing it fakes is `pasteText`: `ghostty_terminal_paste` needs a WRITE_PTY callback, and
// installing one needs the `raw` handle plus a C import that the test target does not have. The
// paste *flow* (reject → confirm sheet → retry with allowUnsafe) is what is asserted here;
// `PasteSupportTests` in TkzTerminalCoreTests covers the bytes.
//
// Every Metal test returns early when there is no GPU (Swift Testing has no skip).

import AppKit
import Metal
import Testing
import TkzTerminalCore
import TkzTerminalRender
@testable import TkzTerminalView

// MARK: - A real terminal behind the controller's port

@MainActor
final class LiveTestTerminal: MouseControllerTerminal {
    let handle: GhosttyTerminalHandle
    let encoder: MouseEncoder
    let selection: SelectionController
    let columns: UInt16

    // Recorded calls — what the routing decision actually did.
    private(set) var pressCalls: [(SurfacePoint, Double)] = []
    private(set) var dragCalls: [(SurfacePoint, Bool)] = []
    private(set) var releaseCalls: [SurfacePoint?] = []
    private(set) var tickCalls: [(SurfacePoint, Bool)] = []
    private(set) var resetCount = 0
    private(set) var geometryPushes: [TerminalPixelGeometry] = []
    private(set) var pasteCalls: [(String, Bool)] = []
    /// Outcomes `pasteText` hands back, consumed front to back; the last one repeats.
    var pasteOutcomes: [PasteOutcome] = [.written]

    init(cols: UInt16, rows: UInt16, geometry: TerminalPixelGeometry) throws {
        handle = try GhosttyTerminalHandle(cols: cols, rows: rows)
        columns = cols
        encoder = try MouseEncoder(geometry: geometry)
        selection = try SelectionController(
            terminal: handle, geometry: geometry, doubleClickInterval: 0.5)
    }

    /// Feed VT bytes (mode sets, text, OSC 8) straight to the terminal.
    func write(_ text: String) { handle.write(text) }

    // MARK: MouseControllerTerminal

    var isMouseTrackingEnabled: Bool { MouseEncoder.isTrackingEnabled(handle) }

    func setMousePixelGeometry(_ geometry: TerminalPixelGeometry) {
        geometryPushes.append(geometry)
        encoder.geometry = geometry
        selection.geometry = geometry
    }

    func encodeMouse(_ press: MousePress) throws -> [UInt8]? {
        try encoder.encode(press, terminal: handle)
    }

    func mouseWheel(rows: Int, at position: SurfacePoint, mods: TerminalModifiers) throws -> WheelOutcome {
        try encoder.wheel(rows: rows, at: position, mods: mods, terminal: handle)
    }

    func resetMouseEncoder() {
        resetCount += 1
        encoder.reset()
    }

    @discardableResult
    func selectionPress(at position: SurfacePoint, timestamp: Double) throws -> Bool {
        pressCalls.append((position, timestamp))
        return try selection.press(at: position, timestamp: timestamp)
    }

    @discardableResult
    func selectionDrag(to position: SurfacePoint, rectangle: Bool) throws -> Bool {
        dragCalls.append((position, rectangle))
        return try selection.drag(to: position, rectangle: rectangle)
    }

    func selectionRelease(at position: SurfacePoint?) throws {
        releaseCalls.append(position)
        try selection.release(at: position)
    }

    @discardableResult
    func selectionAutoscrollTick(at position: SurfacePoint, rectangle: Bool) throws -> Int {
        tickCalls.append((position, rectangle))
        return try selection.autoscrollTick(at: position, rectangle: rectangle)
    }

    var selectionAutoscrollDirection: SelectionAutoscroll { selection.autoscrollDirection }
    var selectionClickCount: Int { selection.clickCount }
    var selectionBehaviors: SelectionBehaviors { selection.behaviors }

    func copySelectionText() -> String? { selection.copySelection() }
    func clearSelection() { selection.clearSelection() }

    @discardableResult
    func pasteText(_ text: String, allowUnsafe: Bool) throws -> PasteOutcome {
        pasteCalls.append((text, allowUnsafe))
        return pasteOutcomes.count > 1 ? pasteOutcomes.removeFirst() : (pasteOutcomes.first ?? .written)
    }

    func hyperlinkRun(at position: SurfacePoint) -> (uri: String, columns: ClosedRange<UInt16>, row: UInt32)? {
        guard let point = selection.gridPoint(at: position),
              let run = HyperlinkLookup.run(at: point, in: handle, columns: columns) else { return nil }
        return (run.uri, run.columns, point.y)
    }
}

// MARK: - Pure policy

@Suite("MouseController policy")
struct MouseControllerPolicyTests {
    @Test("reporting wins unless Shift forces a local selection")
    func routeTable() {
        #expect(terminalMouseRoute(trackingEnabled: true, shiftHeld: false) == .report)
        #expect(terminalMouseRoute(trackingEnabled: true, shiftHeld: true) == .select,
                "Shift is the universal override: select even while a program is tracking")
        #expect(terminalMouseRoute(trackingEnabled: false, shiftHeld: false) == .select)
        #expect(terminalMouseRoute(trackingEnabled: false, shiftHeld: true) == .select)
    }

    @Test("the OSC 8 opener is an allow-list, not a deny-list")
    func linkAllowList() {
        #expect(terminalLinkAction(for: "https://example.com") == .open(URL(string: "https://example.com")!))
        #expect(terminalLinkAction(for: "http://example.com/x?y=1")
            == .open(URL(string: "http://example.com/x?y=1")!))
        #expect(terminalLinkAction(for: "mailto:someone@example.com")
            == .open(URL(string: "mailto:someone@example.com")!))

        // A program controls this string entirely: everything else is refused outright.
        #expect(terminalLinkAction(for: "javascript:alert(1)") == .refuse)
        #expect(terminalLinkAction(for: "data:text/html,<script>x</script>") == .refuse)
        #expect(terminalLinkAction(for: "ssh://root@example.com") == .refuse)
        #expect(terminalLinkAction(for: "x-apple-something://do-a-thing") == .refuse)
        #expect(terminalLinkAction(for: "not a url at all") == .refuse)
        #expect(terminalLinkAction(for: "") == .refuse)
        #expect(terminalLinkAction(for: "http://") == .refuse, "a bare scheme is not a link")

        // `file:` is allowed but never *launched*: opening a program-supplied local path would run
        // it with its default handler. It is revealed in Finder instead.
        switch terminalLinkAction(for: "file:///etc/passwd") {
        case .reveal(let url): #expect(url.path == "/etc/passwd")
        default: Issue.record("file: URLs must resolve to .reveal, never .open")
        }
    }

    @Test("AppKit button numbers map to the terminal's non-sequential button numbering")
    func buttonNumbers() {
        #expect(terminalMouseButton(nsEventButtonNumber: 0) == .left)
        #expect(terminalMouseButton(nsEventButtonNumber: 1) == .right)
        #expect(terminalMouseButton(nsEventButtonNumber: 2) == .middle)
        // Back / forward are AppKit 3 / 4 but terminal buttons eight / nine.
        #expect(terminalMouseButton(nsEventButtonNumber: 3) == .eight)
        #expect(terminalMouseButton(nsEventButtonNumber: 4) == .nine)
        #expect(terminalMouseButton(nsEventButtonNumber: 7) == .four)
        #expect(terminalMouseButton(nsEventButtonNumber: 8) == .five)
        #expect(terminalMouseButton(nsEventButtonNumber: 99) == nil)
    }

    @Test("modifier flags map to the encoder's bits")
    func modifiers() {
        #expect(terminalModifiers(from: []) == [])
        #expect(terminalModifiers(from: [.shift, .command]) == [.shift, .command])
        #expect(terminalModifiers(from: [.control, .option]) == [.control, .option])
        #expect(terminalModifiers(from: [.function]) == [], "device-dependent bits are dropped")
    }
}

@Suite("MouseController wheel accumulation")
@MainActor
struct MouseControllerWheelTests {
    /// One row is 32 device pixels; the view is at 2x, so one row is 16 points of scroll.
    private func rows(_ controller: MouseController, points: Double, ended: Bool = false) -> Int {
        controller.wheelRows(
            deltaY: points, hasPreciseDeltas: true, backingScale: 2, cellHeightPx: 32,
            gestureEnded: ended)
    }

    @Test("precise pixel deltas convert to whole rows through the backing scale")
    func pixelDeltas() {
        let controller = MouseController()
        // 16 points × 2 = 32 device px = exactly one row. Negative deltaY = viewport moves down.
        #expect(rows(controller, points: -16) == 1)
        #expect(rows(controller, points: 16) == -1, "a positive scrollingDeltaY scrolls up")
        #expect(rows(controller, points: -48) == 3)
    }

    @Test("sub-row deltas are carried, not rounded away")
    func remainderCarries() {
        let controller = MouseController()
        #expect(rows(controller, points: -4) == 0, "a quarter row is not yet a row")
        #expect(rows(controller, points: -4) == 0)
        #expect(rows(controller, points: -4) == 0)
        #expect(rows(controller, points: -4) == 1, "four quarter-rows are one row")
        #expect(controller.scrollRemainder == 0)
    }

    @Test("the end of a gesture drops the carried fraction")
    func endedResets() {
        let controller = MouseController()
        #expect(rows(controller, points: -8) == 0)
        #expect(controller.scrollRemainder != 0)
        #expect(rows(controller, points: 0, ended: true) == 0)
        #expect(controller.scrollRemainder == 0, "a new flick must start clean")
        // Half a row after the reset is still not a whole row: the old fraction is really gone.
        #expect(rows(controller, points: -8) == 0)
    }

    @Test("non-precise deltas are already lines")
    func lineDeltas() {
        let controller = MouseController()
        #expect(controller.wheelRows(deltaY: -3, hasPreciseDeltas: false, backingScale: 2,
                                     cellHeightPx: 32, gestureEnded: false) == 3)
    }
}

// MARK: - Routing against a real terminal

@Suite("MouseController routing", .serialized)
@MainActor
struct MouseControllerRoutingTests {
    /// A view, a controller and a real terminal wired together, plus a calibrated mapping from a
    /// target device pixel to the `locationInWindow` an `NSEvent` needs to land there.
    struct Rig {
        let view: TerminalMetalView
        let controller: MouseController
        let terminal: LiveTestTerminal
        let sent: SentBytes
        /// Device pixels → `locationInWindow`.
        let location: (Double, Double) -> NSPoint
        let cellWidth: Double
        let cellHeight: Double

        /// The window-space location of the centre of cell (`column`, `row`).
        func point(column: Int, row: Int) -> NSPoint {
            location((Double(column) + 0.5) * cellWidth, (Double(row) + 0.5) * cellHeight)
        }
    }

    /// Bytes the controller handed to `sendBytes`.
    final class SentBytes {
        var all: [UInt8] = []
        var text: String { String(decoding: all, as: UTF8.self) }
        func clear() { all.removeAll() }
    }

    private func makeRig(width: CGFloat = 800, height: CGFloat = 600) throws -> Rig? {
        guard MTLCreateSystemDefaultDevice() != nil else { return nil }
        let context = try TerminalRenderContext(scale: 2)
        let view = TerminalMetalView(
            renderContext: context, frame: NSRect(x: 0, y: 0, width: width, height: height))
        let controller = MouseController()
        let geometry = controller.pixelGeometry(of: view)
        let size = view.gridSizeForBounds()
        let terminal = try LiveTestTerminal(cols: size.cols, rows: size.rows, geometry: geometry)
        controller.terminalForView = { _ in terminal }

        let sent = SentBytes()
        controller.sendBytes = { sent.all += $0 }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("se.tkz.tkzmux.tests.mouse"))
        controller.openURL = { _ in }
        controller.attach(to: view)

        // Calibrate window-space → device pixels instead of assuming AppKit's flip behaviour for a
        // windowless view: measure two points and invert the (affine, axis-independent) mapping.
        let a = view.devicePixels(of: Self.event(.mouseMoved, at: NSPoint(x: 0, y: 0)))
        let b = view.devicePixels(of: Self.event(.mouseMoved, at: NSPoint(x: 100, y: 100)))
        let sx = (Double(b.x) - Double(a.x)) / 100
        let sy = (Double(b.y) - Double(a.y)) / 100
        let location: (Double, Double) -> NSPoint = { dx, dy in
            NSPoint(x: (dx - Double(a.x)) / sx, y: (dy - Double(a.y)) / sy)
        }

        return Rig(view: view, controller: controller, terminal: terminal, sent: sent,
                   location: location,
                   cellWidth: Double(geometry.cellWidth), cellHeight: Double(geometry.cellHeight))
    }

    private static func event(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        mods: NSEvent.ModifierFlags = [],
        timestamp: TimeInterval = 1,
        button: Int = 0,
        clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: mods, timestamp: timestamp,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
            .withButton(button)
    }

    // MARK: Report vs select

    @Test("tracking on and no Shift reports; the press reaches the pty, not the selection")
    func trackingReports() throws {
        guard let rig = try makeRig() else { return }
        rig.terminal.write("\u{1b}[?1000h\u{1b}[?1006h")  // normal tracking, SGR format
        #expect(rig.terminal.isMouseTrackingEnabled)

        let handled = rig.controller.handle(
            Self.event(.leftMouseDown, at: rig.point(column: 2, row: 1)), in: rig.view)

        #expect(handled)
        #expect(rig.controller.lastRoute == .report)
        #expect(rig.sent.text.hasPrefix("\u{1b}[<0;"), "an SGR press report: \(rig.sent.text.debugDescription)")
        #expect(rig.terminal.pressCalls.isEmpty, "a reported click must not also select")
        #expect(rig.controller.reportingButton == .left)
    }

    @Test("tracking on with Shift selects locally and sends nothing")
    func shiftForcesSelection() throws {
        guard let rig = try makeRig() else { return }
        rig.terminal.write("\u{1b}[?1000h\u{1b}[?1006h")

        _ = rig.controller.handle(
            Self.event(.leftMouseDown, at: rig.point(column: 2, row: 1), mods: [.shift]), in: rig.view)

        #expect(rig.controller.lastRoute == .select)
        #expect(rig.sent.all.isEmpty)
        #expect(rig.terminal.pressCalls.count == 1)
        #expect(rig.controller.isSelecting)
    }

    @Test("tracking off always selects")
    func trackingOffSelects() throws {
        guard let rig = try makeRig() else { return }
        #expect(rig.terminal.isMouseTrackingEnabled == false)

        _ = rig.controller.handle(
            Self.event(.leftMouseDown, at: rig.point(column: 2, row: 1)), in: rig.view)

        #expect(rig.controller.lastRoute == .select)
        #expect(rig.sent.all.isEmpty)
        #expect(rig.terminal.pressCalls.count == 1)
    }

    // MARK: Click granularity

    @Test("single / double / triple clicks are cell / word / line")
    func clickCounts() throws {
        guard let rig = try makeRig() else { return }
        #expect(rig.terminal.selectionBehaviors.singleClick == .cell)
        #expect(rig.terminal.selectionBehaviors.doubleClick == .word)
        #expect(rig.terminal.selectionBehaviors.tripleClick == .line)

        rig.terminal.write("alpha bravo charlie\r\n")
        let at = rig.point(column: 1, row: 0)  // inside "alpha"

        _ = rig.controller.handle(Self.event(.leftMouseDown, at: at, timestamp: 10), in: rig.view)
        #expect(rig.terminal.selectionClickCount == 1)
        #expect((rig.terminal.copySelectionText() ?? "").isEmpty,
                "a single click places the cursor, it does not select")
        _ = rig.controller.handle(Self.event(.leftMouseUp, at: at, timestamp: 10.01), in: rig.view)

        _ = rig.controller.handle(Self.event(.leftMouseDown, at: at, timestamp: 10.1), in: rig.view)
        #expect(rig.terminal.selectionClickCount == 2,
                "NSEvent.timestamp must reach the gesture or libghostty only ever sees single clicks")
        #expect(rig.terminal.copySelectionText() == "alpha")
        _ = rig.controller.handle(Self.event(.leftMouseUp, at: at, timestamp: 10.11), in: rig.view)

        _ = rig.controller.handle(Self.event(.leftMouseDown, at: at, timestamp: 10.2), in: rig.view)
        #expect(rig.terminal.selectionClickCount == 3)
        #expect(rig.terminal.copySelectionText() == "alpha bravo charlie")
    }

    @Test("Option makes the drag a rectangle")
    func optionRectangle() throws {
        guard let rig = try makeRig() else { return }
        rig.terminal.write("alpha bravo charlie\r\n")

        _ = rig.controller.handle(
            Self.event(.leftMouseDown, at: rig.point(column: 1, row: 0), mods: [.option]), in: rig.view)
        _ = rig.controller.handle(
            Self.event(.leftMouseDragged, at: rig.point(column: 9, row: 0), mods: [.option]), in: rig.view)

        #expect(rig.controller.isRectangleDrag)
        #expect(rig.terminal.dragCalls.last?.1 == true)

        // Without Option the same drag is a normal, line-following selection.
        _ = rig.controller.handle(
            Self.event(.leftMouseDragged, at: rig.point(column: 12, row: 0)), in: rig.view)
        #expect(rig.controller.isRectangleDrag == false)
        #expect(rig.terminal.dragCalls.last?.1 == false)
    }

    @Test("a selection drag keeps the display link awake for autoscroll, and lets it park again")
    func dragKeepsLinkAwake() throws {
        guard let rig = try makeRig() else { return }
        let at = rig.point(column: 1, row: 0)
        _ = rig.controller.handle(Self.event(.leftMouseDown, at: at), in: rig.view)
        #expect(rig.view.isDragging)
        _ = rig.controller.handle(Self.event(.leftMouseUp, at: at), in: rig.view)
        #expect(rig.view.isDragging == false)
        #expect(rig.terminal.releaseCalls.count == 1)
    }

    @Test("a drag past the top of the viewport starts the autoscroll timer and ticks scroll history")
    func autoscroll() throws {
        guard let rig = try makeRig() else { return }
        for index in 0..<200 { rig.terminal.write("line \(index)\r\n") }

        _ = rig.controller.handle(Self.event(.leftMouseDown, at: rig.point(column: 2, row: 6)), in: rig.view)
        // Drag above the top edge: AppKit keeps delivering to the mouseDown view with a location
        // outside it, which is exactly the autoscroll case.
        _ = rig.controller.handle(
            Self.event(.leftMouseDragged, at: rig.location(rig.cellWidth * 2, -200)), in: rig.view)

        #expect(rig.terminal.selectionAutoscrollDirection == .up)
        #expect(rig.controller.isAutoscrolling, "the view layer owns the timer, libghostty the policy")

        rig.controller.autoscrollTick(in: rig.view)
        #expect(rig.terminal.tickCalls.count == 1)
        #expect(rig.terminal.tickCalls[0].1 == false, "not a rectangle drag")

        _ = rig.controller.handle(Self.event(.leftMouseUp, at: rig.point(column: 2, row: 6)), in: rig.view)
        #expect(rig.controller.isAutoscrolling == false, "the release must park the timer")
    }

    // MARK: Held buttons

    @Test("a drag report carries the held button, and every press gets a release")
    func dragCarriesHeldButton() throws {
        guard let rig = try makeRig() else { return }
        rig.terminal.write("\u{1b}[?1002h\u{1b}[?1006h")  // button-event tracking

        _ = rig.controller.handle(
            Self.event(.leftMouseDown, at: rig.point(column: 2, row: 1)), in: rig.view)
        rig.sent.clear()
        _ = rig.controller.handle(
            Self.event(.leftMouseDragged, at: rig.point(column: 6, row: 3)), in: rig.view)
        #expect(rig.sent.text.hasPrefix("\u{1b}[<32;"),
                "mode 1002 drag = button 0 + 32 (motion): \(rig.sent.text.debugDescription)")

        // The release lands far outside the view; AppKit still routes it here, and it must encode.
        rig.sent.clear()
        _ = rig.controller.handle(
            Self.event(.leftMouseUp, at: NSPoint(x: -400, y: -400)), in: rig.view)
        #expect(rig.sent.text.hasSuffix("m"), "an SGR release: \(rig.sent.text.debugDescription)")
        #expect(rig.controller.pendingReportReleases.isEmpty)
        #expect(rig.controller.reportingButton == nil)
    }

    @Test("focus loss resets the encoder and drops the controller's held buttons")
    func focusLossResets() throws {
        guard let rig = try makeRig() else { return }
        rig.terminal.write("\u{1b}[?1002h\u{1b}[?1006h")

        _ = rig.controller.handle(
            Self.event(.leftMouseDown, at: rig.point(column: 2, row: 1)), in: rig.view)
        #expect(rig.controller.reportingButton == .left)
        #expect(rig.controller.pendingReportReleases == [.left])

        rig.controller.focusDidChange(false, in: rig.view)

        // `MouseEncoder.reset()` clears `heldButtons`, which is embedder state
        // (`setopt_from_terminal` never touches `OPT_ANY_BUTTON_PRESSED`) — the assertion on the
        // encoder's own set lives in `MouseEncoderTests`; here the guarantee is that focus loss
        // reaches it exactly once and that the controller stops treating a button as held.
        #expect(rig.terminal.resetCount == 1)
        #expect(rig.controller.reportingButton == nil)
        #expect(rig.controller.pendingReportReleases.isEmpty)

        // With no held button a later drag can no longer masquerade as a mouse report.
        rig.sent.clear()
        _ = rig.controller.handle(
            Self.event(.leftMouseDragged, at: rig.point(column: 6, row: 3)), in: rig.view)
        #expect(rig.sent.all.isEmpty, "a drag with nothing held must not report")
    }

    // MARK: Wheel

    @Test("with tracking on a wheel notch reports a press and no release")
    func wheelReportsPressOnly() throws {
        guard let rig = try makeRig() else { return }
        rig.terminal.write("\u{1b}[?1000h\u{1b}[?1006h")

        let outcome = try rig.terminal.mouseWheel(
            rows: -1, at: SurfacePoint(x: rig.cellWidth, y: rig.cellHeight), mods: [])
        guard case .report(let bytes) = outcome else {
            Issue.record("tracking is on, so the wheel must report: \(outcome)")
            return
        }
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("\u{1b}[<64;"), "button four (up): \(text.debugDescription)")
        #expect(text.hasSuffix("M"), "a notch is a press only, never a release")
    }

    @Test("with tracking off the wheel scrolls the viewport instead")
    func wheelScrollsViewport() throws {
        guard let rig = try makeRig() else { return }
        for index in 0..<200 { rig.terminal.write("line \(index)\r\n") }

        let outcome = try rig.terminal.mouseWheel(
            rows: -3, at: SurfacePoint(x: rig.cellWidth, y: rig.cellHeight), mods: [])
        #expect(outcome == .scrolledViewport(rows: -3))
    }

    // MARK: Clipboard

    @Test("copy puts the formatted selection on the pasteboard")
    func copyToPasteboard() throws {
        guard let rig = try makeRig() else { return }
        rig.terminal.write("alpha bravo charlie\r\n")
        let at = rig.point(column: 1, row: 0)
        _ = rig.controller.handle(Self.event(.leftMouseDown, at: at, timestamp: 20), in: rig.view)
        _ = rig.controller.handle(Self.event(.leftMouseUp, at: at, timestamp: 20.01), in: rig.view)
        _ = rig.controller.handle(Self.event(.leftMouseDown, at: at, timestamp: 20.1), in: rig.view)

        #expect(rig.controller.copySelection(in: rig.view))
        #expect(rig.controller.pasteboard.string(forType: .string) == "alpha")
    }

    /// A 1×1 PNG, the shape of a screenshot on the clipboard (image types, no string).
    private static func putImageOnly(_ pasteboard: NSPasteboard) {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    @Test("⌘V with an image and no text sends the Ctrl-V chord instead of pasting")
    func imageOnlyPasteSendsTheChord() throws {
        guard let rig = try makeRig() else { return }
        Self.putImageOnly(rig.controller.pasteboard)
        #expect(rig.controller.pasteboard.string(forType: .string) == nil)

        var chords = 0
        rig.controller.pasteClipboardImage = { _ in chords += 1; return true }

        #expect(rig.controller.pasteFromPasteboard(in: rig.view))
        #expect(chords == 1)
        #expect(rig.terminal.pasteCalls.isEmpty, "an image is never pasted as text")
    }

    @Test("⌘V with text and an image pastes the text — text wins")
    func textWinsOverImage() throws {
        guard let rig = try makeRig() else { return }
        Self.putImageOnly(rig.controller.pasteboard)
        // A spreadsheet or rich-text copy: an image representation next to the text.
        rig.controller.pasteboard.setString("A1\tB1", forType: .string)
        rig.terminal.pasteOutcomes = [.written]

        var chords = 0
        rig.controller.pasteClipboardImage = { _ in chords += 1; return true }

        #expect(rig.controller.pasteFromPasteboard(in: rig.view))
        #expect(chords == 0)
        #expect(rig.terminal.pasteCalls.map(\.0) == ["A1\tB1"])
    }

    @Test("⌘V with an empty pasteboard declines without sending a chord")
    func emptyPasteboardDeclines() throws {
        guard let rig = try makeRig() else { return }
        rig.controller.pasteboard.clearContents()

        var chords = 0
        rig.controller.pasteClipboardImage = { _ in chords += 1; return true }

        #expect(!rig.controller.pasteFromPasteboard(in: rig.view))
        #expect(chords == 0)
        #expect(rig.terminal.pasteCalls.isEmpty)
    }

    @Test("an image-only ⌘V declines when no chord sink is wired")
    func imageOnlyPasteDeclinesUnwired() throws {
        guard let rig = try makeRig() else { return }
        Self.putImageOnly(rig.controller.pasteboard)
        rig.controller.pasteClipboardImage = nil

        #expect(!rig.controller.pasteFromPasteboard(in: rig.view))
        #expect(rig.terminal.pasteCalls.isEmpty)
    }

    @Test("an unsafe paste is confirmed, then retried with allowUnsafe")
    func unsafePasteConfirmation() throws {
        guard let rig = try makeRig() else { return }
        rig.controller.pasteboard.clearContents()
        rig.controller.pasteboard.setString("rm -rf /\nyes\n", forType: .string)
        // libghostty rejects the first attempt knowing the terminal's own bracketed-paste state.
        rig.terminal.pasteOutcomes = [.rejectedUnsafe, .written]

        var asked: String?
        rig.controller.confirmUnsafePaste = { text, _, completion in
            asked = text
            completion(true)
        }
        #expect(rig.controller.pasteFromPasteboard(in: rig.view))

        #expect(asked == "rm -rf /\nyes\n")
        #expect(rig.terminal.pasteCalls.count == 2)
        #expect(rig.terminal.pasteCalls[0].1 == false, "the first attempt must not allow unsafe text")
        #expect(rig.terminal.pasteCalls[1].1 == true, "the confirmed retry does")
    }

    @Test("declining the confirmation writes nothing")
    func declinedPaste() throws {
        guard let rig = try makeRig() else { return }
        rig.controller.pasteboard.clearContents()
        rig.controller.pasteboard.setString("a\nb", forType: .string)
        rig.terminal.pasteOutcomes = [.rejectedUnsafe, .written]
        rig.controller.confirmUnsafePaste = { _, _, completion in completion(false) }

        _ = rig.controller.pasteFromPasteboard(in: rig.view)
        #expect(rig.terminal.pasteCalls.count == 1)
    }

    @Test("a safe paste never raises the sheet")
    func safePaste() throws {
        guard let rig = try makeRig() else { return }
        rig.controller.pasteboard.clearContents()
        rig.controller.pasteboard.setString("echo hi", forType: .string)
        rig.terminal.pasteOutcomes = [.written]
        var asked = false
        rig.controller.confirmUnsafePaste = { _, _, completion in
            asked = true
            completion(false)
        }

        #expect(rig.controller.pasteFromPasteboard(in: rig.view))
        #expect(asked == false)
        #expect(rig.terminal.pasteCalls.count == 1)
    }

    @Test("OSC 52 clipboard writes reach the pasteboard through the event stream")
    func osc52() throws {
        guard let rig = try makeRig() else { return }
        rig.controller.pasteboard.clearContents()
        rig.controller.handle(TerminalEvent.clipboardWrite("from the program"))
        #expect(rig.controller.pasteboard.string(forType: .string) == "from the program")
        // Reads are refused inside TerminalSession (DENIED); nothing here can leak the clipboard.
    }

    // MARK: OSC 8

    @Test("Command-hover underlines an OSC 8 run and Command-click opens it")
    func hyperlinks() throws {
        guard let rig = try makeRig() else { return }
        rig.terminal.write("\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\\r\n")

        let at = rig.point(column: 1, row: 0)  // inside "link"
        #expect(rig.controller.handle(Self.event(.mouseMoved, at: at, mods: [.command]), in: rig.view))
        #expect(rig.controller.hoveredLink == "https://example.com")
        #expect(rig.controller.linkUnderlineLayer != nil, "the hover draws an underline overlay")

        var opened: TerminalLinkAction?
        rig.controller.openURL = { opened = $0 }
        _ = rig.controller.handle(Self.event(.leftMouseDown, at: at, mods: [.command]), in: rig.view)
        #expect(opened == .open(URL(string: "https://example.com")!))
        #expect(rig.terminal.pressCalls.isEmpty, "a link click must not start a selection")

        // Moving off the link (still with Command) drops the underline.
        let away = rig.point(column: 40, row: 5)
        _ = rig.controller.handle(Self.event(.mouseMoved, at: away, mods: [.command]), in: rig.view)
        #expect(rig.controller.hoveredLink == nil)
    }

    @Test("a hostile scheme is refused rather than opened")
    func hostileLinkRefused() throws {
        guard let rig = try makeRig() else { return }
        rig.terminal.write("\u{1b}]8;;javascript:alert(1)\u{1b}\\click me\u{1b}]8;;\u{1b}\\\r\n")

        let at = rig.point(column: 2, row: 0)
        _ = rig.controller.handle(Self.event(.mouseMoved, at: at, mods: [.command]), in: rig.view)
        #expect(rig.controller.hoveredLink == nil, "a refused scheme must not even offer the hand cursor")

        var opened: TerminalLinkAction?
        rig.controller.openURL = { opened = $0 }
        _ = rig.controller.handle(Self.event(.leftMouseDown, at: at, mods: [.command]), in: rig.view)
        #expect(opened == .refuse, "a javascript: URI must never reach NSWorkspace")
    }

    // MARK: Tracking area and geometry

    @Test("the controller owns the tracking area")
    func trackingArea() throws {
        guard let rig = try makeRig() else { return }
        let area = try #require(rig.controller.installedTrackingArea)
        #expect(area.options.contains(.mouseMoved))
        #expect(area.options.contains(.mouseEnteredAndExited))
        #expect(area.options.contains(.inVisibleRect), "AppKit keeps the rect in sync on resize")
        #expect(area.options.contains(.activeAlways))
        #expect(rig.view.trackingAreas.contains(area))

        // The owner is this object, not the view, so the selectors AppKit sends must exist under
        // their ObjC names — an `NSObject` does not inherit `NSResponder`'s `mouseEntered:`.
        #expect(rig.controller.responds(to: NSSelectorFromString("mouseEntered:")))
        #expect(rig.controller.responds(to: NSSelectorFromString("mouseExited:")))
        #expect(rig.controller.responds(to: NSSelectorFromString("mouseMoved:")))

        rig.controller.detach()
        #expect(rig.view.trackingAreas.contains(area) == false)
    }

    @Test("geometry is pushed once, and again when the view resizes")
    func geometrySync() throws {
        guard let rig = try makeRig() else { return }
        let initial = rig.terminal.geometryPushes.count
        #expect(initial >= 1, "attach() pushes the starting geometry")

        _ = rig.controller.handle(Self.event(.mouseMoved, at: rig.point(column: 1, row: 1)), in: rig.view)
        #expect(rig.terminal.geometryPushes.count == initial, "an unchanged geometry is not re-pushed")

        rig.view.setFrameSize(NSSize(width: 1200, height: 900))
        _ = rig.controller.handle(Self.event(.mouseMoved, at: rig.point(column: 1, row: 1)), in: rig.view)
        #expect(rig.terminal.geometryPushes.count == initial + 1)
        #expect(rig.terminal.geometryPushes.last?.screenWidth == 2400, "800pt → 1200pt at 2x")
    }

    @Test("with no terminal nothing is consumed")
    func noTerminal() throws {
        guard let rig = try makeRig() else { return }
        rig.controller.terminalForView = { _ in nil }
        #expect(rig.controller.handle(
            Self.event(.leftMouseDown, at: rig.point(column: 1, row: 1)), in: rig.view) == false)
    }
}

// MARK: - Event helpers

extension NSEvent {
    /// `NSEvent.mouseEvent` has no button-number parameter: `buttonNumber` comes from the event
    /// *type* for left/right and from the CGEvent for `otherMouse*`. Tests that need a non-left
    /// button build the event through CoreGraphics instead.
    fileprivate func withButton(_ number: Int) -> NSEvent {
        guard number != 0, let cgEvent = cgEvent else { return self }
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
        return NSEvent(cgEvent: cgEvent) ?? self
    }
}
