import Testing
@testable import TkzTerminalCore

/// 20×6 cells of 10×20 px — small enough that expected selections are readable.
private let geometry = TerminalPixelGeometry(
    screenWidth: 200,
    screenHeight: 120,
    cellWidth: 10,
    cellHeight: 20
)

private func pixels(col: Int, row: Int) -> SurfacePoint {
    // Aim at the middle of the cell so rounding is never the thing under test.
    SurfacePoint(x: Double(col) * 10 + 5, y: Double(row) * 20 + 10)
}

/// The right-hand edge of a cell. libghostty includes the cell under a drag only once the
/// pointer is past its midpoint (see `SelectionController.drag`), so a drag that should *end on*
/// this cell has to aim here, not at the middle.
private func dragEnd(col: Int, row: Int) -> SurfacePoint {
    SurfacePoint(x: Double(col) * 10 + 9, y: Double(row) * 20 + 10)
}

private func makeController(
    _ text: String,
    cols: UInt16 = 20,
    rows: UInt16 = 6
) throws -> (GhosttyTerminalHandle, SelectionController) {
    let terminal = try GhosttyTerminalHandle(cols: cols, rows: rows)
    terminal.write(text)
    let controller = try SelectionController(
        terminal: terminal,
        geometry: geometry,
        doubleClickInterval: 0.5
    )
    return (terminal, controller)
}

@Suite struct SelectionControllerTests {
    // MARK: - Drag

    /// Press at the first cell, drag across a span, release → the copied text is exactly the span.
    @Test func dragSelectsTheSpanUnderThePointer() throws {
        let (terminal, controller) = try makeController("hello world\r\nsecond line")
        _ = terminal

        #expect(try controller.press(at: pixels(col: 0, row: 0), timestamp: 1) == false)
        #expect(try controller.drag(to: dragEnd(col: 4, row: 0)) == true)
        try controller.release(at: pixels(col: 4, row: 0))

        #expect(controller.copySelection() == "hello")
        #expect(controller.hasDragged == true)
    }

    /// A drag onto the second row selects across the line break.
    @Test func dragAcrossRowsSelectsBothLines() throws {
        let (terminal, controller) = try makeController("hello world\r\nsecond line")
        _ = terminal

        try controller.press(at: pixels(col: 6, row: 0), timestamp: 1)
        try controller.drag(to: dragEnd(col: 5, row: 1))
        try controller.release(at: pixels(col: 5, row: 1))

        #expect(controller.copySelection() == "world\nsecond")
    }

    /// A plain single click produces no selection and clears any previous one.
    @Test func singleClickClearsTheSelection() throws {
        let (terminal, controller) = try makeController("hello world")
        _ = terminal

        try controller.press(at: pixels(col: 0, row: 0), timestamp: 1)
        try controller.drag(to: dragEnd(col: 4, row: 0))
        try controller.release(at: pixels(col: 4, row: 0))
        #expect(controller.copySelection() == "hello")

        try controller.press(at: pixels(col: 15, row: 3), timestamp: 5)
        #expect(controller.copySelection() == nil)
        #expect(controller.hasSelection == false)
    }

    // MARK: - Click count

    /// Two presses inside the double-click interval and distance select the word under them.
    @Test func doubleClickSelectsAWord() throws {
        let (terminal, controller) = try makeController("hello world")
        _ = terminal

        try controller.press(at: pixels(col: 7, row: 0), timestamp: 1)
        try controller.release(at: pixels(col: 7, row: 0))
        let produced = try controller.press(at: pixels(col: 7, row: 0), timestamp: 1.1)

        #expect(produced == true)
        #expect(controller.clickCount == 2)
        #expect(controller.copySelection() == "world")
    }

    /// A third press selects the whole line.
    @Test func tripleClickSelectsALine() throws {
        let (terminal, controller) = try makeController("hello world\r\nsecond line")
        _ = terminal

        try controller.press(at: pixels(col: 7, row: 0), timestamp: 1)
        try controller.release(at: pixels(col: 7, row: 0))
        try controller.press(at: pixels(col: 7, row: 0), timestamp: 1.1)
        try controller.release(at: pixels(col: 7, row: 0))
        let produced = try controller.press(at: pixels(col: 7, row: 0), timestamp: 1.2)

        #expect(produced == true)
        #expect(controller.clickCount == 3)
        #expect(controller.copySelection() == "hello world")
    }

    /// Past the interval the sequence restarts, so it is a single click again — no word selection.
    @Test func slowSecondClickIsNotADoubleClick() throws {
        let (terminal, controller) = try makeController("hello world")
        _ = terminal

        try controller.press(at: pixels(col: 7, row: 0), timestamp: 1)
        try controller.release(at: pixels(col: 7, row: 0))
        let produced = try controller.press(at: pixels(col: 7, row: 0), timestamp: 9)

        #expect(produced == false)
        #expect(controller.clickCount == 1)
        #expect(controller.copySelection() == nil)
    }

    // MARK: - Rectangle

    /// Option-drag selects a rectangle: the same columns on every row of the span.
    @Test func optionDragSelectsARectangle() throws {
        let (terminal, controller) = try makeController("abcdef\r\nghijkl\r\nmnopqr")
        _ = terminal

        try controller.press(at: pixels(col: 1, row: 0), timestamp: 1)
        try controller.drag(to: dragEnd(col: 2, row: 2), rectangle: true)
        try controller.release(at: pixels(col: 2, row: 2))

        #expect(controller.copySelection() == "bc\nhi\nno")
    }

    /// The same drag without Option runs through the line ends instead.
    @Test func linearDragIsNotRectangular() throws {
        let (terminal, controller) = try makeController("abcdef\r\nghijkl\r\nmnopqr")
        _ = terminal

        try controller.press(at: pixels(col: 1, row: 0), timestamp: 1)
        try controller.drag(to: dragEnd(col: 2, row: 2))
        try controller.release(at: pixels(col: 2, row: 2))

        #expect(controller.copySelection() == "bcdef\nghijkl\nmno")
    }

    // MARK: - Coordinate mapping

    @Test func pixelsMapToCellsAndClampToTheGrid() throws {
        let (terminal, controller) = try makeController("hello")
        _ = terminal

        #expect(controller.gridPoint(at: SurfacePoint(x: 0, y: 0)) == TerminalGridPoint(x: 0, y: 0))
        #expect(controller.gridPoint(at: SurfacePoint(x: 55, y: 41)) == TerminalGridPoint(x: 5, y: 2))
        // Past the right/bottom edge the pointer still resolves, clamped to the last cell.
        #expect(controller.gridPoint(at: SurfacePoint(x: 9_999, y: 9_999)) == TerminalGridPoint(x: 19, y: 5))
        #expect(controller.gridPoint(at: SurfacePoint(x: -50, y: -50)) == TerminalGridPoint(x: 0, y: 0))
    }

    // MARK: - Autoscroll

    @Test func autoscrollPolicyIsSignedForTheScrollDelta() {
        let policy = AutoscrollPolicy(rowsPerTick: 2)
        #expect(policy.rows(for: .none) == 0)
        #expect(policy.rows(for: .up) == -2)
        #expect(policy.rows(for: .down) == 2)
        // A zero or negative tick size would freeze the drag; it is clamped to one row.
        #expect(AutoscrollPolicy(rowsPerTick: 0).rowsPerTick == 1)
    }

    /// Dragging above the top of the surface asks for an upward autoscroll, and one tick both
    /// scrolls the viewport and extends the selection into the newly revealed row.
    @Test func autoscrollTickScrollsAndExtends() throws {
        let terminal = try GhosttyTerminalHandle(cols: 20, rows: 6)
        for line in 0..<50 { terminal.write("line \(line)\r\n") }
        let controller = try SelectionController(
            terminal: terminal,
            geometry: geometry,
            doubleClickInterval: 0.5
        )

        try controller.press(at: pixels(col: 0, row: 5), timestamp: 1)
        // A drag with a negative y is above the surface: libghostty asks for an upward autoscroll.
        try controller.drag(to: SurfacePoint(x: 5, y: -40))
        #expect(controller.autoscrollDirection == .up)

        let selectionBefore = controller.copySelection()
        let rows = try controller.autoscrollTick(at: SurfacePoint(x: 5, y: -40))
        #expect(rows == -1)
        #expect(MouseEncoder.isViewportPinned(terminal) == false)
        #expect(controller.copySelection() != selectionBefore)
    }

    @Test func autoscrollTickIsANoOpWhenTheDragIsInside() throws {
        let (terminal, controller) = try makeController("hello world")
        _ = terminal

        try controller.press(at: pixels(col: 0, row: 0), timestamp: 1)
        try controller.drag(to: dragEnd(col: 4, row: 0))
        #expect(controller.autoscrollDirection == .none)
        #expect(try controller.autoscrollTick(at: pixels(col: 4, row: 0)) == 0)
    }

    // MARK: - Lifecycle

    @Test func resetEndsTheClickSequence() throws {
        let (terminal, controller) = try makeController("hello world")
        _ = terminal

        try controller.press(at: pixels(col: 7, row: 0), timestamp: 1)
        try controller.release(at: pixels(col: 7, row: 0))
        controller.reset()
        // After a reset the next press starts a fresh sequence, so it is a single click again.
        let produced = try controller.press(at: pixels(col: 7, row: 0), timestamp: 1.1)
        #expect(produced == false)
    }

    @Test func staticCopyMatchesTheInstanceCopy() throws {
        let (terminal, controller) = try makeController("hello world")

        try controller.press(at: pixels(col: 0, row: 0), timestamp: 1)
        try controller.drag(to: dragEnd(col: 4, row: 0))
        #expect(SelectionController.copySelection(terminal: terminal) == "hello")
    }
}

@Suite struct HyperlinkLookupTests {
    /// OSC 8 marks a run of cells; the lookup returns the URI and the run's columns.
    @Test func findsTheUriAndItsRun() throws {
        let terminal = try GhosttyTerminalHandle(cols: 40, rows: 4)
        terminal.write("see \u{1b}]8;;https://tkz.se/x\u{1b}\\link text\u{1b}]8;;\u{1b}\\ end")

        // "see " is columns 0-3, "link text" is columns 4-12.
        #expect(HyperlinkLookup.uri(at: TerminalGridPoint(x: 6, y: 0), in: terminal) == "https://tkz.se/x")
        #expect(HyperlinkLookup.uri(at: TerminalGridPoint(x: 1, y: 0), in: terminal) == nil)
        #expect(HyperlinkLookup.uri(at: TerminalGridPoint(x: 20, y: 0), in: terminal) == nil)

        let run = HyperlinkLookup.run(at: TerminalGridPoint(x: 6, y: 0), in: terminal, columns: 40)
        #expect(run?.uri == "https://tkz.se/x")
        #expect(run?.columns == 4...12)
    }

    @Test func returnsNilOutsideTheGrid() throws {
        let terminal = try GhosttyTerminalHandle(cols: 10, rows: 2)
        terminal.write("hi")
        #expect(HyperlinkLookup.uri(at: TerminalGridPoint(x: 99, y: 99), in: terminal) == nil)
    }

    /// Spike item: "hyperlink ref cost while scrolled". Measures a viewport-tag lookup deep in
    /// scrollback and prints it; the assertion is only a sanity bound so CI never flakes on time.
    @Test func lookupCostWhileScrolledBack() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        for line in 0..<2_000 {
            terminal.write("row \(line) \u{1b}]8;;https://tkz.se/\(line)\u{1b}\\link\u{1b}]8;;\u{1b}\\\r\n")
        }
        // Scroll ~1000 rows into history.
        let encoder = try MouseEncoder(geometry: geometry)
        _ = try encoder.wheel(rows: -1_000, at: SurfacePoint(x: 0, y: 0), terminal: terminal)
        #expect(MouseEncoder.isViewportPinned(terminal) == false)

        let point = TerminalGridPoint(x: 12, y: 5, space: .viewport)
        #expect(HyperlinkLookup.uri(at: point, in: terminal) != nil)

        let iterations = 10_000
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<iterations {
                _ = HyperlinkLookup.uri(at: point, in: terminal)
            }
        }
        let perLookup = elapsed / iterations
        print("hyperlink lookup while scrolled back (viewport tag): \(perLookup) per lookup")
        #expect(perLookup < .milliseconds(1))
    }
}
