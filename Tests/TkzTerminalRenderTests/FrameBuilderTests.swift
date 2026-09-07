// FrameBuilderTests — the CPU half of M1.5 (TKZ-11): no Metal device is needed for any of these.
//
// Each test here pins one *measured* spike finding from docs/design.md → Spike results (M1.1–M1.3)
// into executable form, so a libghostty upgrade that changes the behaviour fails here rather than
// silently painting the wrong pixels:
//
//   * spike 4  — inverse is NOT resolved by the library; bold-brightening is NOT applied
//   * spike 5  — a cursor move is DIRTY_PARTIAL; a selection change is DIRTY_FULL
//   * spike 6  — SPACER_TAIL cells report GRAPHEMES_LEN == 0 and must not produce a glyph
//   * spike 7  — BG_COLOR returns GHOSTTY_INVALID_VALUE when unset → theme background
//
// `GlyphCache(device: nil)` is a fully working CPU atlas, which is what makes this possible.

import Foundation
import GhosttyVt
import Testing
import TkzCore
import TkzShaderTypes
import TkzTerminalCore
@testable import TkzTerminalRender

// MARK: - Fixtures

/// A session plus an attached surface, at a small grid.
struct SurfaceFixture {
    let session: TerminalSession
    let surface: TerminalSurface
    let builder: FrameBuilder
    let theme: Theme

    init(cols: UInt16 = 20, rows: UInt16 = 4, theme: Theme = .default) throws {
        self.theme = theme
        session = try TerminalSession(options: TerminalSessionOptions(cols: cols, rows: rows, theme: theme))
        surface = TerminalSurface()
        try surface.attach(session)
        builder = FrameBuilder(glyphCache: makeTestGlyphCache(), theme: theme)
    }

    @discardableResult
    func write(_ text: String) -> Self {
        session.write(ptyText: text)
        return self
    }

    @discardableResult
    func update() throws -> FrameUpdate {
        try builder.update(surface)
    }

    /// The packed background of one cell.
    func background(_ column: Int, _ row: Int) -> UInt32 {
        surface.backgroundCells[row * surface.columns + column].color
    }

    /// The glyph instances on one row.
    func glyphs(row: Int) -> [TkzGlyphInstance] {
        surface.glyphInstances().filter { Int($0.gridPos.y) == row }
    }
}

/// A CPU-only glyph cache for one test.
///
/// Deliberately *not* shared: `FontSet`, `GraphemeShaper` and `GlyphCache` all memoize into plain
/// dictionaries and are documented as render-thread-only, and Swift Testing runs test functions in
/// parallel. (`FontSet` serialises CoreText registration and matching internally, which is what
/// keeps building one per test from wedging the XType XPC connection.)
func makeTestGlyphCache() -> GlyphCache {
    GlyphCache(fontSet: FontSet(pointSize: 12.5, scale: 2), device: nil)
}

// MARK: - Attach / detach

@Suite(.serialized)
struct TerminalSurfaceLifecycleTests {
    @Test("a fresh surface owns nothing until it is attached")
    func detachedSurfaceIsInert() throws {
        let surface = TerminalSurface()
        #expect(!surface.isAttached)
        #expect(surface.columns == 0)
        #expect(!surface.needsDisplay)

        let builder = FrameBuilder(glyphCache: makeTestGlyphCache())
        let update = try builder.update(surface)
        #expect(update.isClean)
    }

    @Test("attach makes the first frame a FULL rebuild, detach frees everything")
    func attachThenDetach() throws {
        let fixture = try SurfaceFixture()
        #expect(fixture.surface.isAttached)
        #expect(fixture.surface.needsDisplay)

        let first = try fixture.update()
        #expect(first.dirty == .full, "a brand-new render state must report FULL on its first update")
        #expect(fixture.surface.columns == 20)
        #expect(fixture.surface.rowCount == 4)

        fixture.surface.detach()
        #expect(!fixture.surface.isAttached)
        #expect(fixture.surface.columns == 0)
        #expect(fixture.surface.backgroundCells.isEmpty)
        #expect(!fixture.surface.needsDisplay)

        // Detached is inert, not fatal — M1.6 switches sessions through exactly this path.
        #expect(try fixture.builder.update(fixture.surface).isClean)

        // And re-attaching works.
        try fixture.surface.attach(fixture.session)
        #expect(try fixture.builder.update(fixture.surface).dirty == .full)
    }
}

// MARK: - Dirty semantics (spike 5)

@Suite(.serialized)
struct FrameBuilderDirtyTests {
    @Test("an unchanged terminal reports DIRTY_FALSE and rebuilds no rows")
    func idleTickIsClean() throws {
        let fixture = try SurfaceFixture()
        fixture.write("hello")
        _ = try fixture.update()

        fixture.surface.clearNeedsDisplay()  // stands in for a frame the renderer encoded

        let second = try fixture.update()
        #expect(second.dirty == .none)
        #expect(second.rowsRebuilt == 0)
        #expect(!fixture.surface.needsDisplay, "a clean tick must leave the surface not needing a frame")
    }

    @Test("writing one line marks only that row dirty")
    func writeIsPartial() throws {
        let fixture = try SurfaceFixture()
        fixture.write("first\r\n")
        _ = try fixture.update()

        fixture.write("second")
        let update = try fixture.update()
        #expect(update.dirty == .partial)
        #expect(update.rowsRebuilt >= 1)
        #expect(update.rowsRebuilt < fixture.surface.rowCount)
    }

    @Test("a cursor move is DIRTY_PARTIAL — the cursor may stay an overlay (spike 5)")
    func cursorMoveIsPartial() throws {
        let fixture = try SurfaceFixture()
        fixture.write("abc")
        _ = try fixture.update()

        fixture.write("\u{1b}[3;10H")  // row 3, col 10
        let update = try fixture.update()
        #expect(update.dirty == .partial)
        #expect(update.rowsRebuilt <= 2, "only the old and the new cursor row should be dirty")
        #expect(fixture.surface.cursor.column == 9)
        #expect(fixture.surface.cursor.row == 2)
    }

    @Test("a selection is DIRTY_FULL and every row is re-iterated (spike 5)")
    func selectionIsFull() throws {
        let fixture = try SurfaceFixture()
        fixture.write("selectable text")
        _ = try fixture.update()
        #expect(try fixture.update().dirty == .none)

        try setSelection(fixture.session, startX: 0, startY: 0, endX: 5, endY: 0)
        let update = try fixture.update()
        #expect(update.dirty == .full)
        #expect(update.rowsRebuilt == fixture.surface.rowCount,
                "a selection change costs a full row rebuild — it is not a free overlay")

        // And the selected cells carry the theme's selection tint composited over the cell bg.
        let expected = pack(fixture.theme.selection.over(RGB(packed: fixture.surface.colors.background)))
        #expect(fixture.background(0, 0) == expected)
        #expect(fixture.background(5, 0) == expected)
        #expect(fixture.background(6, 0) != expected)
    }

    @Test("the cursor blink phase needs a frame but no row rebuild")
    func blinkIsAnOverlay() throws {
        let fixture = try SurfaceFixture()
        fixture.write("x")
        _ = try fixture.update()
        fixture.surface.clearNeedsDisplay()
        _ = try fixture.update()
        #expect(!fixture.surface.needsDisplay)

        fixture.surface.cursorBlinkOn = false
        #expect(fixture.surface.needsDisplay)
        let update = try fixture.update()
        #expect(update.dirty == .none)
        #expect(update.rowsRebuilt == 0)
        #expect(fixture.surface.needsDisplay, "an overlay change still owes the screen a frame")
    }
}

// MARK: - Colours (spikes 4 and 7)

@Suite(.serialized)
struct FrameBuilderColorTests {
    @Test("a cell with no explicit background gets alpha 0 → the theme background (spike 7)")
    func unsetBackgroundIsTransparent() throws {
        let fixture = try SurfaceFixture()
        fixture.write("plain")
        _ = try fixture.update()

        #expect(fixture.background(0, 0) == 0,
                "BG_COLOR returns GHOSTTY_INVALID_VALUE when unset; alpha 0 means 'theme background'")
        // …and the render state's background is the theme's terminal background.
        #expect(fixture.surface.colors.background == pack(fixture.theme.terminalBackground))
    }

    @Test("an explicit background is packed straight through")
    func explicitBackground() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[48;2;10;20;30mX")
        _ = try fixture.update()
        #expect(fixture.background(0, 0) == (10 | 20 << 8 | 30 << 16 | 0xFF00_0000))
    }

    @Test("ESC[7m swaps the *defaults* — the library does not resolve inverse (spike 4)")
    func inverseSwapsDefaults() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[7mI")
        _ = try fixture.update()

        let colors = fixture.surface.colors
        #expect(fixture.background(0, 0) == colors.foreground,
                "an inverse cell's background is the default *foreground*")
        let glyph = try #require(fixture.glyphs(row: 0).first)
        #expect(glyph.color == colors.background,
                "an inverse cell's glyph is drawn in the default *background*")
    }

    @Test("ESC[1;31m renders bright red — bold-brightening is app-side (spike 4)")
    func boldBrightensThePaletteIndex() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[1;31mB\u{1b}[0m\u{1b}[31mn")
        _ = try fixture.update()

        let row = fixture.glyphs(row: 0)
        #expect(row.count == 2)
        let bold = try #require(row.first { $0.gridPos.x == 0 })
        let normal = try #require(row.first { $0.gridPos.x == 1 })
        let palette = fixture.surface.colors.palette
        #expect(normal.color == palette[1], "a non-bold SGR 31 stays palette[1]")
        #expect(bold.color == palette[9], "SGR 1;31 must be brightened to palette[9] by us")
    }

    @Test("a 24-bit foreground survives unpacked")
    func trueColorForeground() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[38;2;255;128;0mO")
        _ = try fixture.update()
        let glyph = try #require(fixture.glyphs(row: 0).first)
        #expect(glyph.color == (255 | 128 << 8 | 0 << 16 | 0xFF00_0000))
    }

    @Test("a 256-colour index resolves through the render state palette")
    func indexedForeground() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[38;5;208mP")
        _ = try fixture.update()
        let glyph = try #require(fixture.glyphs(row: 0).first)
        #expect(glyph.color == fixture.surface.colors.palette[208])
    }
}

// MARK: - Glyphs (spike 6)

@Suite(.serialized)
struct FrameBuilderGlyphTests {
    @Test("a wide grapheme produces one glyph and its tail cell produces none (spike 6)")
    func wideTailProducesNoGlyph() throws {
        let fixture = try SurfaceFixture()
        fixture.write("你a")
        _ = try fixture.update()

        let row = fixture.glyphs(row: 0)
        #expect(row.count == 2, "one glyph for 你 (columns 0–1) and one for a (column 2)")
        let wide = try #require(row.first { $0.gridPos.x == 0 })
        #expect(wide.flags & UInt32(TKZ_GLYPH_FLAG_WIDE) != 0)
        #expect(!row.contains { $0.gridPos.x == 1 }, "the SPACER_TAIL cell must draw nothing at all")
        #expect(row.contains { $0.gridPos.x == 2 })
    }

    @Test("an emoji is rasterized into the colour atlas")
    func emojiIsAColorGlyph() throws {
        let fixture = try SurfaceFixture()
        fixture.write("😀")
        _ = try fixture.update()
        let glyph = try #require(fixture.glyphs(row: 0).first)
        #expect(glyph.flags & UInt32(TKZ_GLYPH_FLAG_COLOR) != 0)
        #expect(glyph.flags & UInt32(TKZ_GLYPH_FLAG_WIDE) != 0)
    }

    @Test("a blank screen produces no glyph instances at all")
    func spacesDrawNothing() throws {
        let fixture = try SurfaceFixture()
        fixture.write("   ")
        _ = try fixture.update()
        #expect(fixture.surface.glyphCount == 0)
    }

    @Test("bold and italic pick different faces, and both rasterize")
    func boldAndItalicShapeDifferently() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[0mR\u{1b}[1mB\u{1b}[0m\u{1b}[3mI\u{1b}[0m")
        _ = try fixture.update()
        let row = fixture.glyphs(row: 0)
        #expect(row.count == 3)
        // Different faces land in different atlas slots.
        #expect(Set(row.map { $0.atlasPos.x }).count == 3)
    }

    @Test("SGR 8 (invisible) suppresses the glyph but keeps the background")
    func invisibleDrawsNoGlyph() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[8;48;2;1;2;3mS")
        _ = try fixture.update()
        #expect(fixture.glyphs(row: 0).isEmpty)
        #expect(fixture.background(0, 0) == (1 | 2 << 8 | 3 << 16 | 0xFF00_0000))
    }
}

// MARK: - Decorations

@Suite(.serialized)
struct FrameBuilderDecorationTests {
    @Test("an underlined run coalesces into a single rect")
    func underlineRunIsOneRect() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[4munderlined\u{1b}[0m")
        _ = try fixture.update()

        let rects = fixture.surface.rectInstancesAbove(
            geometry: GridGeometry(metrics: fixture.builder.metrics, viewportWidth: 100, viewportHeight: 100))
        #expect(rects.count == 1)
        let rect = try #require(rects.first)
        #expect(rect.style == UInt32(TKZ_RECT_STYLE_UNDERLINE_SINGLE))
        #expect(rect.sizePx.x == Float(fixture.builder.metrics.width * 10))
        #expect(rect.originPx.x == 0)
    }

    @Test("each underline style maps to its own rect style")
    func underlineStyles() throws {
        let cases: [(String, UInt32)] = [
            ("\u{1b}[4m", UInt32(TKZ_RECT_STYLE_UNDERLINE_SINGLE)),
            ("\u{1b}[21m", UInt32(TKZ_RECT_STYLE_UNDERLINE_DOUBLE)),
            ("\u{1b}[4:3m", UInt32(TKZ_RECT_STYLE_UNDERLINE_CURLY)),
            ("\u{1b}[4:4m", UInt32(TKZ_RECT_STYLE_UNDERLINE_DOTTED)),
            ("\u{1b}[4:5m", UInt32(TKZ_RECT_STYLE_UNDERLINE_DASHED)),
        ]
        for (sgr, expected) in cases {
            let fixture = try SurfaceFixture()
            fixture.write(sgr + "u")
            _ = try fixture.update()
            let rects = fixture.surface.rectInstancesAbove(
                geometry: GridGeometry(metrics: fixture.builder.metrics,
                                       viewportWidth: 100, viewportHeight: 100))
            #expect(rects.first?.style == expected, "SGR \(sgr.dropFirst()) → rect style \(expected)")
        }
    }

    @Test("strikethrough is its own rect, above the glyphs")
    func strikethrough() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[9mstruck")
        _ = try fixture.update()
        let rects = fixture.surface.rectInstancesAbove(
            geometry: GridGeometry(metrics: fixture.builder.metrics, viewportWidth: 100, viewportHeight: 100))
        #expect(rects.count == 1)
        #expect(rects.first?.style == UInt32(TKZ_RECT_STYLE_STRIKETHROUGH))
    }
}

// MARK: - Cursor overlay

@Suite(.serialized)
struct SurfaceCursorTests {
    private func geometry(_ fixture: SurfaceFixture) -> GridGeometry {
        GridGeometry(metrics: fixture.builder.metrics, viewportWidth: 400, viewportHeight: 200)
    }

    @Test("a focused block cursor is a solid rect below the glyphs")
    func blockCursor() throws {
        let fixture = try SurfaceFixture()
        fixture.write("ab")
        _ = try fixture.update()

        let below = fixture.surface.rectInstancesBelow(geometry: geometry(fixture))
        #expect(below.count == 1)
        #expect(below.first?.style == UInt32(TKZ_RECT_STYLE_SOLID))
        #expect(below.first?.sizePx == SIMD2<Float>(Float(fixture.builder.metrics.width),
                                                    Float(fixture.builder.metrics.height)))
    }

    @Test("DECSCUSR 5 switches to a bar cursor")
    func barCursor() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[5 qab")
        _ = try fixture.update()
        #expect(fixture.surface.cursor.style == .bar)
        let below = fixture.surface.rectInstancesBelow(geometry: geometry(fixture))
        #expect(below.first?.sizePx.x ?? 99 < Float(fixture.builder.metrics.width))
    }

    @Test("an unfocused window draws the hollow outline, above the glyphs")
    func unfocusedCursorIsHollow() throws {
        let fixture = try SurfaceFixture()
        fixture.write("ab")
        _ = try fixture.update()
        fixture.surface.isFocused = false

        #expect(fixture.surface.rectInstancesBelow(geometry: geometry(fixture)).isEmpty)
        let above = fixture.surface.rectInstancesAbove(geometry: geometry(fixture))
        #expect(above.contains { $0.style == UInt32(TKZ_RECT_STYLE_HOLLOW) })
    }

    @Test("the glyph under a filled cursor is flagged, and the flag is not baked into the cache")
    func cursorFlagIsAnOverlay() throws {
        let fixture = try SurfaceFixture()
        fixture.write("ab\u{1b}[1;1H")  // cursor back onto the 'a'
        _ = try fixture.update()

        let flagged = try #require(fixture.surface.glyphInstances().first { $0.gridPos.x == 0 })
        #expect(flagged.flags & UInt32(TKZ_GLYPH_FLAG_UNDER_CURSOR) != 0)

        fixture.surface.cursorBlinkOn = false
        let unflagged = try #require(fixture.surface.glyphInstances().first { $0.gridPos.x == 0 })
        #expect(unflagged.flags & UInt32(TKZ_GLYPH_FLAG_UNDER_CURSOR) == 0,
                "hiding the cursor must not need a row rebuild")
    }
}

// MARK: - Selection helper

/// Installs a viewport selection through libghostty. `withTerminal` is `package`-visible, so a test
/// in the same package can drive the terminal directly without a `SelectionController`.
func setSelection(
    _ session: TerminalSession, startX: UInt16, startY: UInt32, endX: UInt16, endY: UInt32
) throws {
    var result = GHOSTTY_SUCCESS
    session.withTerminal { terminal in
        func gridRef(_ x: UInt16, _ y: UInt32) -> GhosttyGridRef? {
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_VIEWPORT
            point.value.coordinate = GhosttyPointCoordinate(x: x, y: y)
            var ref = GhosttyGridRef()
            ref.size = MemoryLayout<GhosttyGridRef>.stride
            guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
            return ref
        }
        guard let start = gridRef(startX, startY), let end = gridRef(endX, endY) else {
            result = GHOSTTY_INVALID_VALUE
            return
        }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.stride
        selection.start = start
        selection.end = end
        result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }
    guard result == GHOSTTY_SUCCESS else {
        throw RenderError(result: Int32(result.rawValue), operation: "ghostty_terminal_set(SELECTION)")
    }
}
