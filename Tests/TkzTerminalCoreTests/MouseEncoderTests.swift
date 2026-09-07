import Testing
@testable import TkzTerminalCore

/// 80×24 cells of 10×20 px, no padding — the geometry every test below uses.
private let geometry = TerminalPixelGeometry(
    screenWidth: 800,
    screenHeight: 480,
    cellWidth: 10,
    cellHeight: 20
)

/// Surface pixels for the top-left corner of the 0-based cell (col, row).
private func pixels(col: Int, row: Int) -> SurfacePoint {
    SurfacePoint(x: Double(col) * 10, y: Double(row) * 20)
}

private func makeTerminal(_ setup: String...) throws -> GhosttyTerminalHandle {
    let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
    for sequence in setup { terminal.write(sequence) }
    return terminal
}

private func string(_ bytes: [UInt8]?) -> String? {
    bytes.map { String(decoding: $0, as: UTF8.self) }
}

@Suite struct MouseEncoderTests {
    // MARK: - SGR reports

    /// SGR mouse mode (1000 tracking + 1006 format): a left press at cell (5, 2) must be the
    /// exact xterm SGR report, 1-based: `ESC [ < 0 ; 6 ; 3 M`.
    @Test func sgrPressAtKnownCell() throws {
        let terminal = try makeTerminal("\u{1b}[?1000h", "\u{1b}[?1006h")
        let encoder = try MouseEncoder(geometry: geometry)

        let bytes = try encoder.encode(
            MousePress(action: .press, button: .left, position: pixels(col: 5, row: 2)),
            terminal: terminal
        )
        #expect(string(bytes) == "\u{1b}[<0;6;3M")
    }

    /// The release form differs only in the final byte: lowercase `m`.
    @Test func sgrReleaseUsesLowercaseTerminator() throws {
        let terminal = try makeTerminal("\u{1b}[?1000h", "\u{1b}[?1006h")
        let encoder = try MouseEncoder(geometry: geometry)

        _ = try encoder.encode(
            MousePress(action: .press, button: .left, position: pixels(col: 5, row: 2)),
            terminal: terminal
        )
        let bytes = try encoder.encode(
            MousePress(action: .release, button: .left, position: pixels(col: 5, row: 2)),
            terminal: terminal
        )
        #expect(string(bytes) == "\u{1b}[<0;6;3m")
    }

    /// Motion needs any-event tracking (1003). Button 3 + the 32 "motion" bit = 35.
    @Test func sgrMotionReport() throws {
        let terminal = try makeTerminal("\u{1b}[?1003h", "\u{1b}[?1006h")
        let encoder = try MouseEncoder(geometry: geometry)

        let bytes = try encoder.encode(
            MousePress(action: .motion, button: nil, position: pixels(col: 5, row: 2)),
            terminal: terminal
        )
        #expect(string(bytes) == "\u{1b}[<35;6;3M")
    }

    /// Modifiers ride in the button field: shift 4 + alt 8 + ctrl 16 = 28 on top of button 0.
    @Test func modifiersAreEncoded() throws {
        let terminal = try makeTerminal("\u{1b}[?1000h", "\u{1b}[?1006h")
        let encoder = try MouseEncoder(geometry: geometry)

        let bytes = try encoder.encode(
            MousePress(
                action: .press,
                button: .left,
                mods: [.shift, .option, .control],
                position: pixels(col: 0, row: 0)
            ),
            terminal: terminal
        )
        #expect(string(bytes) == "\u{1b}[<28;1;1M")
    }

    /// With no tracking mode enabled the terminal wants no report at all.
    @Test func noReportWhenTrackingIsOff() throws {
        let terminal = try makeTerminal()
        let encoder = try MouseEncoder(geometry: geometry)

        #expect(MouseEncoder.isTrackingEnabled(terminal) == false)
        let bytes = try encoder.encode(
            MousePress(action: .press, button: .left, position: pixels(col: 5, row: 2)),
            terminal: terminal
        )
        #expect(bytes == nil)
    }

    @Test func trackingFlagFollowsTheTerminalModes() throws {
        let terminal = try makeTerminal()
        #expect(MouseEncoder.isTrackingEnabled(terminal) == false)
        terminal.write("\u{1b}[?1000h")
        #expect(MouseEncoder.isTrackingEnabled(terminal) == true)
        terminal.write("\u{1b}[?1000l")
        #expect(MouseEncoder.isTrackingEnabled(terminal) == false)
    }

    // MARK: - Wheel

    /// Wheel with tracking on: buttons four/five, i.e. the 64/65 SGR button codes.
    /// (Spike item "wheel button 4/5 bytes" — these are the measured values.)
    @Test func wheelWithTrackingOnReportsButtonsFourAndFive() throws {
        let terminal = try makeTerminal("\u{1b}[?1000h", "\u{1b}[?1006h")
        let encoder = try MouseEncoder(geometry: geometry)

        let up = try encoder.wheel(rows: -1, at: pixels(col: 5, row: 2), terminal: terminal)
        #expect(up == .report(Array("\u{1b}[<64;6;3M".utf8)))

        let down = try encoder.wheel(rows: 1, at: pixels(col: 5, row: 2), terminal: terminal)
        #expect(down == .report(Array("\u{1b}[<65;6;3M".utf8)))
    }

    /// Several rows in one gesture produce one report per row.
    @Test func wheelEmitsOneReportPerRow() throws {
        let terminal = try makeTerminal("\u{1b}[?1000h", "\u{1b}[?1006h")
        let encoder = try MouseEncoder(geometry: geometry)

        let outcome = try encoder.wheel(rows: 3, at: pixels(col: 0, row: 0), terminal: terminal)
        let expected = String(repeating: "\u{1b}[<65;1;1M", count: 3)
        #expect(outcome == .report(Array(expected.utf8)))
    }

    /// Button-event tracking (1002) reports motion only while a button is held, and
    /// `setopt_from_terminal` never sets `OPT_ANY_BUTTON_PRESSED` — the encoder tracks that
    /// itself. Button 0 + the 32 motion bit = 32.
    @Test func buttonEventTrackingReportsMotionWhileDragging() throws {
        let terminal = try makeTerminal("\u{1b}[?1002h", "\u{1b}[?1006h")
        let encoder = try MouseEncoder(geometry: geometry)

        // No button held yet: no motion report.
        #expect(try encoder.encode(
            MousePress(action: .motion, button: nil, position: pixels(col: 1, row: 0)),
            terminal: terminal
        ) == nil)

        _ = try encoder.encode(
            MousePress(action: .press, button: .left, position: pixels(col: 2, row: 0)),
            terminal: terminal
        )
        let dragging = try encoder.encode(
            MousePress(action: .motion, button: .left, position: pixels(col: 5, row: 2)),
            terminal: terminal
        )
        #expect(string(dragging) == "\u{1b}[<32;6;3M")

        // After the release the drag is over and motion goes quiet again.
        _ = try encoder.encode(
            MousePress(action: .release, button: .left, position: pixels(col: 5, row: 2)),
            terminal: terminal
        )
        #expect(try encoder.encode(
            MousePress(action: .motion, button: nil, position: pixels(col: 7, row: 2)),
            terminal: terminal
        ) == nil)
    }

    /// A wheel click must not leave the encoder thinking a button is held (there is no release).
    @Test func wheelDoesNotLeaveAButtonHeld() throws {
        let terminal = try makeTerminal("\u{1b}[?1002h", "\u{1b}[?1006h")
        let encoder = try MouseEncoder(geometry: geometry)

        _ = try encoder.encode(
            MousePress(action: .press, button: .left, position: pixels(col: 0, row: 0)),
            terminal: terminal
        )
        _ = try encoder.wheel(rows: 1, at: pixels(col: 0, row: 0), terminal: terminal)
        // The wheel emitted a *press* of button five with no matching release; it must not be
        // left in the held set, or `OPT_ANY_BUTTON_PRESSED` would stay true after the real
        // button comes up.
        #expect(encoder.heldButtons == [.left])
        _ = try encoder.encode(
            MousePress(action: .release, button: .left, position: pixels(col: 0, row: 0)),
            terminal: terminal
        )
        #expect(encoder.heldButtons.isEmpty)
    }

    /// Wheel with tracking off scrolls the viewport instead of writing bytes, and the visible
    /// screen really moves: the viewport unpins from the active area and the top row changes.
    @Test func wheelWithTrackingOffScrollsTheViewport() throws {
        let terminal = try makeTerminal()
        for line in 0..<100 { terminal.write("line \(line)\r\n") }
        let encoder = try MouseEncoder(geometry: geometry)

        #expect(MouseEncoder.isViewportPinned(terminal) == true)
        let before = try topVisibleRow(of: terminal)

        let outcome = try encoder.wheel(rows: -3, at: pixels(col: 0, row: 0), terminal: terminal)
        #expect(outcome == .scrolledViewport(rows: -3))
        #expect(MouseEncoder.isViewportPinned(terminal) == false)

        let after = try topVisibleRow(of: terminal)
        #expect(before != after)
        #expect(after == "line 74")
        #expect(before == "line 77")
    }

    /// Reads the first visible row by running a cell-granular drag across it and copying —
    /// exercises the selection path as a bonus.
    private func topVisibleRow(of terminal: GhosttyTerminalHandle) throws -> String {
        let controller = try SelectionController(
            terminal: terminal,
            geometry: geometry,
            doubleClickInterval: 0.5
        )
        try controller.press(at: pixels(col: 0, row: 0), timestamp: 1)
        try controller.drag(to: pixels(col: 79, row: 0))
        try controller.release(at: pixels(col: 79, row: 0))
        return controller.copySelection() ?? ""
    }
}

@Suite struct ScrollAccumulatorTests {
    /// Fractional deltas accumulate instead of being rounded away.
    @Test func fractionsAccumulateIntoWholeRows() {
        var accumulator = ScrollAccumulator()
        #expect(accumulator.consume(rows: 0.4) == 0)
        #expect(accumulator.consume(rows: 0.4) == 0)
        #expect(accumulator.consume(rows: 0.4) == 1)
        #expect(abs(accumulator.remainder - 0.2) < 1e-9)
    }

    /// Negative (upward) deltas truncate toward zero the same way.
    @Test func negativeDeltasAccumulate() {
        var accumulator = ScrollAccumulator()
        #expect(accumulator.consume(rows: -0.6) == 0)
        #expect(accumulator.consume(rows: -0.6) == -1)
        #expect(abs(accumulator.remainder - -0.2) < 1e-9)
    }

    @Test func pixelsAreDividedByTheCellHeight() {
        var accumulator = ScrollAccumulator()
        #expect(accumulator.consume(pixels: 25, cellHeight: 20) == 1)
        #expect(accumulator.consume(pixels: 15, cellHeight: 20) == 1)
        #expect(accumulator.remainder == 0)
    }

    @Test func resetDropsTheCarriedFraction() {
        var accumulator = ScrollAccumulator()
        _ = accumulator.consume(rows: 0.5)
        accumulator.reset()
        #expect(accumulator.remainder == 0)
        #expect(accumulator.consume(rows: 0.6) == 0)
    }

    @Test func degenerateInputIsIgnored() {
        var accumulator = ScrollAccumulator()
        #expect(accumulator.consume(pixels: 100, cellHeight: 0) == 0)
        #expect(accumulator.consume(rows: .nan) == 0)
        #expect(accumulator.remainder == 0)
    }
}
