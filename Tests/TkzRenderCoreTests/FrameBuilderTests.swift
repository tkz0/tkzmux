// FrameBuilderTests — the CPU half of M1.5 over a synthetic `GlyphSource` (WOR-311 S4).
//
// Each test here pins one *measured* spike finding (M1.1–M1.3)
// into executable form, so a libghostty upgrade that changes the behaviour fails here rather than
// silently painting the wrong pixels:
//
//   * spike 4  — inverse is NOT resolved by the library; bold-brightening is NOT applied
//   * spike 5  — a cursor move is DIRTY_PARTIAL; a selection change is DIRTY_FULL
//   * spike 6  — SPACER_TAIL cells report GRAPHEMES_LEN == 0 and must not produce a glyph
//   * spike 7  — BG_COLOR returns GHOSTTY_INVALID_VALUE when unset → theme background
//
// None of them depends on a font stack: the glyphs come from `BlockGlyphSource`, so they run on
// both OSes. The CoreText shaping cases (CJK fallback, colour emoji, real bold/italic faces) stay in
// TkzTerminalRenderTests/FrameBuilderTests.swift.

import Foundation
import GhosttyVt
import Testing
import TkzCore
import TkzShaderTypes
import TkzTerminalCore
@testable import TkzRenderCore

// MARK: - Fixtures

/// A session plus an attached surface, at a small grid, building against a synthetic source.
struct SurfaceFixture {
    /// 15×33 cells, baseline 26: JetBrains Mono at 12.5 pt × 2, like the Mac fixture.
    static let metrics = CellMetrics(ascent: 25.5, descent: 7.5, leading: 0, maxAdvance: 15,
                                     underlinePosition: -3.875, underlineThickness: 1.25,
                                     strikeoutPosition: 8, strikeoutThickness: 1.25, scale: 2)

    let session: TerminalSession
    let surface: TerminalSurface
    let builder: FrameBuilder
    let source: BlockGlyphSource
    let theme: Theme

    init(cols: UInt16 = 20, rows: UInt16 = 4, theme: Theme = .default,
         colorScalars: Set<Unicode.Scalar> = []) throws {
        self.theme = theme
        session = try TerminalSession(options: TerminalSessionOptions(cols: cols, rows: rows, theme: theme))
        surface = TerminalSurface()
        try surface.attach(session)
        // Deliberately one per fixture: `GlyphCache` and the source memoize into plain dictionaries
        // and are render-thread-only, and Swift Testing runs test functions in parallel.
        source = BlockGlyphSource(metrics: Self.metrics, colorScalars: colorScalars)
        builder = FrameBuilder(glyphCache: GlyphCache(source: source), theme: theme)
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

// MARK: - Attach / detach

@Suite(.serialized)
struct TerminalSurfaceLifecycleTests {
    @Test("a fresh surface owns nothing until it is attached")
    func detachedSurfaceIsInert() throws {
        let surface = TerminalSurface()
        #expect(!surface.isAttached)
        #expect(surface.columns == 0)
        #expect(!surface.needsDisplay)

        let builder = FrameBuilder(glyphCache: GlyphCache(source: BlockGlyphSource(metrics: SurfaceFixture.metrics)))
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

    @Test("detach drops the renderer's resources with everything else")
    func detachDropsRenderResources() throws {
        final class Resources: SurfaceRenderResources {}
        let fixture = try SurfaceFixture()
        _ = try fixture.update()
        let resources = Resources()
        fixture.surface.renderResources = resources
        #expect(fixture.surface.renderResources === resources)

        fixture.surface.detach()
        #expect(fixture.surface.renderResources == nil)
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

    @Test("a space echoed onto a blank cell still advances the drawn cursor")
    func spaceOntoBlankCellMovesTheCursor() throws {
        // A printed space is a cell write, so libghostty does mark the row dirty and this case was
        // never broken — it is kept as the shell-side counterpart of `sameRowCursorMoveIsAFrame`,
        // which is the case the GUI pass actually hit (Ink repositions the cursor without printing).
        let fixture = try SurfaceFixture()
        fixture.write("ab")
        _ = try fixture.update()
        fixture.surface.clearNeedsDisplay()
        #expect(fixture.surface.cursor.column == 2)

        fixture.write(" ")
        let update = try fixture.update()
        #expect(fixture.surface.cursor.column == 3)
        #expect(update.dirty != .none, "a cursor that moved is not a clean frame")
        #expect(fixture.surface.needsDisplay)

        // And a genuinely idle tick after that is still clean.
        fixture.surface.clearNeedsDisplay()
        let idle = try fixture.update()
        #expect(idle.dirty == .none)
        #expect(!fixture.surface.needsDisplay)
    }

    @Test("a cursor move within its own row, with no cell change, is still a frame")
    func sameRowCursorMoveIsAFrame() throws {
        // Ink (Claude Code's UI) trims trailing whitespace from the lines it draws, so typing a
        // space at the end of the prompt produces *only* a cursor reposition within the same row —
        // no cell changes, no dirty row. libghostty's dirty flag tracks cells, so this tick is
        // reported clean, and the cursor stayed drawn one cell short until the next letter (GUI
        // pass 2026-09-08). The frame builder reads the cursor on clean ticks for exactly this.
        let fixture = try SurfaceFixture()
        fixture.write("abc")
        _ = try fixture.update()
        fixture.surface.clearNeedsDisplay()
        #expect(fixture.surface.cursor.column == 3)

        fixture.write("\u{1b}[1;2H")  // same row, column 2
        let update = try fixture.update()
        #expect(fixture.surface.cursor.column == 1)
        #expect(fixture.surface.cursor.row == 0)
        #expect(update.dirty != .none, "a cursor that moved is not a clean frame")
        #expect(fixture.surface.needsDisplay)

        fixture.surface.clearNeedsDisplay()
        let idle = try fixture.update()
        #expect(idle.dirty == .none)
        #expect(!fixture.surface.needsDisplay)
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

    @Test("only program-coloured glyphs opt into the min-contrast fix")
    func minContrastFollowsTheProgram() throws {
        let fixture = try SurfaceFixture()
        fixture.write("d\u{1b}[31mr\u{1b}[0m\u{1b}[7mi")
        _ = try fixture.update()
        let row = fixture.glyphs(row: 0)
        let flag = UInt32(TKZ_GLYPH_FLAG_MIN_CONTRAST)
        // The cursor sits after the run, so no glyph carries the under-cursor override.
        #expect(try #require(row.first { $0.gridPos.x == 0 }).flags & flag == 0, "theme default")
        #expect(try #require(row.first { $0.gridPos.x == 1 }).flags & flag != 0, "SGR 31")
        #expect(try #require(row.first { $0.gridPos.x == 2 }).flags & flag != 0, "inverse")

        fixture.builder.appliesMinContrast = false
        fixture.write("\u{1b}[2J\u{1b}[H\u{1b}[31mr")
        _ = try fixture.update()
        #expect(fixture.glyphs(row: 0).allSatisfy { $0.flags & flag == 0 })
    }
}

// MARK: - Glyphs (spike 6)

@Suite(.serialized)
struct FrameBuilderGlyphTests {
    @Test("a wide cell produces one WIDE glyph and its tail cell produces none (spike 6)")
    func wideTailProducesNoGlyph() throws {
        let fixture = try SurfaceFixture()
        fixture.write("你a")
        _ = try fixture.update()

        let row = fixture.glyphs(row: 0)
        #expect(row.count == 2, "one glyph for 你 (columns 0–1) and one for a (column 2)")
        let wide = try #require(row.first { $0.gridPos.x == 0 })
        #expect(wide.flags & UInt32(TKZ_GLYPH_FLAG_WIDE) != 0)
        // libghostty's WIDE reaches the source as the span: the block is two cells wide.
        #expect(Int(wide.sizePx.x) == SurfaceFixture.metrics.width * 2 + 2 * fixture.source.padding)
        #expect(!row.contains { $0.gridPos.x == 1 }, "the SPACER_TAIL cell must draw nothing at all")
        #expect(row.contains { $0.gridPos.x == 2 })
    }

    @Test("a colour cluster is flagged COLOR and placed from the colour atlas")
    func colourClusterIsFlagged() throws {
        let fixture = try SurfaceFixture(colorScalars: ["😀"])
        fixture.write("😀")
        _ = try fixture.update()
        let glyph = try #require(fixture.glyphs(row: 0).first)
        #expect(glyph.flags & UInt32(TKZ_GLYPH_FLAG_COLOR) != 0)
        #expect(glyph.flags & UInt32(TKZ_GLYPH_FLAG_WIDE) != 0)
        #expect(fixture.builder.glyphCache.color.hasPendingUpload)
    }

    @Test("a blank screen produces no glyph instances at all")
    func spacesDrawNothing() throws {
        let fixture = try SurfaceFixture()
        fixture.write("   ")
        _ = try fixture.update()
        #expect(fixture.surface.glyphCount == 0)
    }

    @Test("bold and italic reach the source as their own styles")
    func boldAndItalicAreKeyedApart() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[0mR\u{1b}[1mR\u{1b}[0m\u{1b}[3mR\u{1b}[1mR\u{1b}[0m")
        _ = try fixture.update()
        let row = fixture.glyphs(row: 0)
        #expect(row.count == 4)
        // One scalar, four styles: four cache entries in four atlas slots.
        #expect(Set(row.map { $0.atlasPos }).count == 4)
        #expect(fixture.builder.glyphCache.cachedCount == 4)
    }

    @Test("an instance is placed from the cache's bearings and the cell baseline")
    func instanceGeometry() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[2;3HQ")
        _ = try fixture.update()
        let glyph = try #require(fixture.glyphs(row: 1).first)
        let cached = try #require(fixture.builder.glyphCache.glyph(forScalar: "Q", cellSpan: 1))
        #expect(glyph.gridPos == SIMD2<UInt16>(2, 1))
        #expect(glyph.offsetPx == SIMD2<Int16>(Int16(cached.bearingX),
                                               Int16(fixture.builder.metrics.baseline - cached.bearingTop)))
        #expect(glyph.offsetPx == SIMD2<Int16>(-1, -1), "a padded cell-sized block sits one px up-left")
        #expect(glyph.sizePx == SIMD2<UInt16>(UInt16(cached.slot.width), UInt16(cached.slot.height)))
        #expect(glyph.atlasPos == SIMD2<UInt16>(UInt16(cached.slot.x), UInt16(cached.slot.y)))
        #expect(glyph.bgColor == fixture.surface.colors.background)
        #expect(glyph.reserved0 == 0)
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

    @Test("a run breaks where its colour changes, and the rect box sits on the underline")
    func runsSplitOnColour() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[4mab\u{1b}[31mcd\u{1b}[0m")
        _ = try fixture.update()
        let metrics = fixture.builder.metrics
        let rects = fixture.surface.rectInstancesAbove(
            geometry: GridGeometry(metrics: metrics, viewportWidth: 100, viewportHeight: 100))
        #expect(rects.count == 2)
        #expect(rects.map(\.originPx.x) == [0, Float(metrics.width * 2)])
        #expect(rects.allSatisfy { $0.sizePx.x == Float(metrics.width * 2) })
        #expect(rects[0].color != rects[1].color)

        let thickness = Float(metrics.underlineThickness)
        let box = max(thickness * 3, 3)
        #expect(rects[0].sizePx.y == box)
        #expect(rects[0].originPx.y == Float(metrics.baseline) + Float(metrics.underlineOffset) - box / 2)
        #expect(rects[0].thicknessPx == thickness)
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

    @Test("a suppressed cursor draws nothing and flags nothing")
    func suppressedCursor() throws {
        let fixture = try SurfaceFixture()
        fixture.write("ab\u{1b}[1;1H")
        _ = try fixture.update()
        fixture.surface.clearNeedsDisplay()

        fixture.surface.isCursorSuppressed = true
        #expect(fixture.surface.needsDisplay)
        #expect(fixture.surface.cursorRect(geometry: geometry(fixture)) == nil)
        #expect(fixture.surface.glyphInstances().allSatisfy {
            $0.flags & UInt32(TKZ_GLYPH_FLAG_UNDER_CURSOR) == 0
        })
    }

    @Test("the borrowed flatten views match the returned arrays")
    func borrowedViewsMatch() throws {
        let fixture = try SurfaceFixture()
        fixture.write("\u{1b}[4mab\u{1b}[0m cd\u{1b}[1;1H")
        _ = try fixture.update()
        fixture.surface.isFocused = false

        let glyphs = fixture.surface.glyphInstances()
        let borrowedGlyphs = fixture.surface.withGlyphInstances { Array($0) }
        #expect(glyphs.count == 4 && borrowedGlyphs.count == glyphs.count)
        #expect(zip(glyphs, borrowedGlyphs).allSatisfy { $0.gridPos == $1.gridPos && $0.flags == $1.flags })

        let rects = fixture.surface.rectInstancesAbove(geometry: geometry(fixture))
        let borrowedRects = fixture.surface.withRectInstancesAbove(geometry: geometry(fixture)) { Array($0) }
        #expect(rects.count == 2, "the underline run plus the hollow cursor")
        #expect(zip(rects, borrowedRects).allSatisfy { $0.originPx == $1.originPx && $0.style == $1.style })
        #expect(fixture.surface.glyphCount == 4 && fixture.surface.rectCount == 1)
    }
}

// MARK: - Atlas rebuild

@Suite(.serialized)
struct FrameBuilderAtlasRebuildTests {
    @Test("an atlas rebuild turns the next dirty tick into a full one")
    func rebuildForcesAFullTick() throws {
        let fixture = try SurfaceFixture(rows: 3)
        fixture.write("abc\r\ndef\r\nghi")
        _ = try fixture.update()
        #expect(try fixture.update().dirty == .none)

        // A rebuild caused elsewhere (another surface on the same cache) stales every row here.
        // The glyphs fill one shelf; a full-width block fills the rest of the max-size atlas, and a
        // second one cannot fit, so packing it clears the atlas and leaves room for the glyphs.
        let atlas = fixture.builder.glyphCache.grayscale
        let shelf = SurfaceFixture.metrics.height + 2 * fixture.source.padding
        #expect(atlas.size == AtlasKind.grayscale.maxSize)
        let rebuilds = atlas.rebuildCount
        for height in [atlas.size - shelf, atlas.size - 2 * shelf] {
            atlas.insert(pixels: [UInt8](repeating: 0, count: atlas.size * height),
                         width: atlas.size, height: height, bytesPerRow: atlas.size)
        }
        #expect(atlas.rebuildCount == rebuilds + 1)

        // One more cell on the last row: libghostty reports one dirty row, and the stale stamp
        // turns the tick into a full rebuild. (A tick with no dirty cell returns before the stamp
        // is compared.)
        fixture.write("j")
        let update = try fixture.update()
        #expect(update.dirty == .full)
        #expect(update.rowsRebuilt == 3)
        #expect(atlas.rebuildCount == rebuilds + 1, "the re-placed glyphs fit; no second rebuild")
        let glyphs = fixture.surface.glyphInstances()
        #expect(glyphs.count == 10)
        // Every instance points at pixels the atlas holds now, not into the zeroed block.
        for glyph in glyphs {
            #expect(atlas.stagedPixel(x: Int(glyph.atlasPos.x), y: Int(glyph.atlasPos.y)) == [0xFF])
        }
        #expect(try fixture.update().dirty == .none, "and the next idle tick is clean again")
    }
}

// MARK: - Selection helper

/// Installs a viewport selection through libghostty. `withTerminal` is `package`-visible, so a test
/// in the same package can drive the terminal directly without a `SelectionController`.
///
/// TkzTerminalRenderTests carries the same helper for its golden frame; test targets cannot share
/// a file.
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

// MARK: - Scroll metrics
//
// The builder polls `DATA_SCROLLBAR` because libghostty offers no change notification for scroll
// state. Where that read sits — and what it is careful *not* to do — is the whole design.

@Test func theBuilderPollsScrollMetricsIntoTheSurface() throws {
    let fixture = try SurfaceFixture(cols: 20, rows: 4)
    #expect(fixture.surface.scrollMetrics == .empty, "nothing until the first update")

    try fixture.update()
    #expect(fixture.surface.scrollMetrics.visible == 4)
    #expect(fixture.surface.scrollMetrics.total == 4)
    #expect(fixture.surface.scrollMetrics.isAlternateScreen == false)

    fixture.write("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\n")
    try fixture.update()
    #expect(fixture.surface.scrollMetrics.total > 4, "scrollback must grow the total")
}

/// The load-bearing one. Scrolled into history, new child output grows `total` and moves the thumb
/// while every *visible* cell stays clean — so a read behind the builder's `dirty == .none` guard
/// would freeze the thumb exactly when it is carrying the most information.
@Test func scrollMetricsAreRefreshedOnACleanTick() throws {
    let fixture = try SurfaceFixture(cols: 20, rows: 4)
    for line in 0..<50 { fixture.write("line \(line)\r\n") }
    try fixture.update()

    // Scroll into history, then settle: the next tick has nothing to rebuild.
    fixture.session.withTerminal { terminal in
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = -20
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }
    try fixture.update()
    let settled = try fixture.update()
    #expect(settled.dirty == .none, "precondition: the tick under test is a clean one")
    let before = fixture.surface.scrollMetrics

    // Output that lands *below* the viewport: the total grows, the visible cells do not change.
    for line in 0..<10 { fixture.write("more \(line)\r\n") }
    let update = try fixture.update()

    #expect(update.dirty == .none, "no visible cell changed — this is the case that matters")
    #expect(fixture.surface.scrollMetrics.total > before.total,
            "the poll must sit ahead of the dirty guard, or the thumb freezes")
}

/// The thumb is an overlay, not GPU content. Marking the surface dirty for one would leave the
/// renderer's `needsUpdate = surface.needsDisplay` handoff permanently true and pin the display
/// link at 120 Hz — M1.6's idle guarantee, lost to an overlay.
@Test func aMovedThumbNeverRequestsAFrame() throws {
    let fixture = try SurfaceFixture(cols: 20, rows: 4)
    for line in 0..<50 { fixture.write("line \(line)\r\n") }
    try fixture.update()

    fixture.session.withTerminal { terminal in
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = -20
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }
    // The viewport moved, so this one legitimately redraws. Settle first, then take the baseline.
    try fixture.update()
    try fixture.update()
    fixture.surface.clearNeedsDisplay()
    let revision = fixture.surface.revision
    let scrolled = fixture.surface.scrollMetrics

    // Now a pure scroll-metrics change with no cell change at all.
    for line in 0..<10 { fixture.write("more \(line)\r\n") }
    try fixture.update()

    #expect(fixture.surface.scrollMetrics.total > scrolled.total, "precondition: the metrics moved")
    #expect(fixture.surface.needsDisplay == false, "a moved thumb must not ask for a frame")
    #expect(fixture.surface.revision == revision, "and must not count as an instance-data rebuild")
}

@Test func detachClearsTheScrollMetrics() throws {
    let fixture = try SurfaceFixture(cols: 20, rows: 4)
    for line in 0..<50 { fixture.write("line \(line)\r\n") }
    try fixture.update()
    #expect(fixture.surface.scrollMetrics.isScrollable)

    fixture.surface.detach()
    #expect(fixture.surface.scrollMetrics == .empty)
}
