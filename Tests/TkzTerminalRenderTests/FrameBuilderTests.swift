// FrameBuilderTests — the CoreText half of the frame builder's tests (M1.5; split in WOR-311 S4).
//
// `FrameBuilder` and `TerminalSurface` live in TkzRenderCore now, and the spike pins (dirty
// semantics, colours, decorations, the cursor overlay, scroll metrics) run on both OSes over a
// synthetic glyph source in Tests/TkzRenderCoreTests/FrameBuilderTests.swift. What stays here is
// what only the real font stack can answer: CJK fallback, colour emoji and distinct bold/italic
// faces, through `CoreTextGlyphSource`. No Metal device is needed for any of these.

import Foundation
import GhosttyVt
import Testing
import TkzCore
import TkzRenderCore
import TkzShaderTypes
import TkzTerminalCore
@testable import TkzTerminalRender

// MARK: - Fixtures

/// A session plus an attached surface, at a small grid, building against CoreText.
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
    GlyphCache(fontSet: FontSet(pointSize: 12.5, scale: 2))
}

// MARK: - Glyphs through CoreText

@Suite(.serialized)
struct FrameBuilderCoreTextTests {
    /// The synthetic-source twin in TkzRenderCoreTests pins spike 6 itself; this one also needs the
    /// CJK fallback face to cover 你.
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
}

// MARK: - Selection helper

/// Installs a viewport selection through libghostty. `withTerminal` is `package`-visible, so a test
/// in the same package can drive the terminal directly without a `SelectionController`.
///
/// Used by the golden frame in TerminalRendererTests; TkzRenderCoreTests carries the same helper.
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
