// GlyphPlacementTests — the Mac's placement rules as pure arithmetic (WOR-312 S5): union, stroke
// outset, fit scale, integer extent with padding, and the one-time tighten.

import Foundation
import Testing
import TkzRenderCore

@Suite("Glyph placement")
struct GlyphPlacementTests {
    func box(_ minX: CGFloat, _ minY: CGFloat, _ maxX: CGFloat, _ maxY: CGFloat) -> GlyphBounds {
        GlyphBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    @Test("a glyph that fits: its box rounded outwards plus the padding")
    func fits() throws {
        let placed = try #require(GlyphPlacement.place(glyphs: [(box(0.7, -0.2, 12.3, 16.35), 0, 0)],
                                                       boxWidth: 14, boxHeight: 30, padding: 2))
        #expect(placed.appliedScale == 1)
        #expect(placed.originX == -2 && placed.originY == -3)
        #expect(placed.width == 13 - 0 + 4 && placed.height == 17 - (-1) + 4)
        #expect(placed.bearingX == -2 && placed.bearingTop == 19)
    }

    @Test("empty boxes are skipped; nothing with ink means no bitmap")
    func empty() {
        #expect(GlyphPlacement.place(glyphs: [], boxWidth: 14, boxHeight: 30, padding: 1) == nil)
        #expect(GlyphPlacement.place(glyphs: [(box(0, 0, 0, 0), 0, 0), (box(3, 1, 3, 9), 0, 0)],
                                     boxWidth: 14, boxHeight: 30, padding: 1) == nil)
        let one = GlyphPlacement.place(glyphs: [(box(0, 0, 0, 0), 5, 5), (box(1, 1, 2, 2), 0, 0)],
                                       boxWidth: 14, boxHeight: 30, padding: 1)
        #expect(one?.union == box(1, 1, 2, 2))
    }

    @Test("glyphs are unioned at their pen offsets")
    func union() throws {
        let placed = try #require(GlyphPlacement.place(
            glyphs: [(box(1, 0, 8, 10), 0, 0), (box(-2, 0, 2, 3), 4, 11)],
            boxWidth: 14, boxHeight: 30, padding: 1))
        #expect(placed.union == box(1, 0, 8, 14))
    }

    @Test("the synthetic-bold stroke outsets the union by its whole width")
    func strokeOutset() throws {
        let placed = try #require(GlyphPlacement.place(glyphs: [(box(1, 0, 8, 10), 0, 0)], strokeOutset: 1,
                                                       boxWidth: 14, boxHeight: 30, padding: 1))
        #expect(placed.union == box(0, -1, 9, 11))
    }

    @Test("an overflowing union is scaled uniformly to fit the box")
    func fitScale() throws {
        // A 34.9 × 32.9 emoji into a 34 × 37 two-cell box.
        let placed = try #require(GlyphPlacement.place(glyphs: [(box(0, -6.4, 34.9, 26.5), 0, 0)],
                                                       boxWidth: 34, boxHeight: 37, padding: 1))
        #expect(placed.appliedScale <= 34 / 34.9)
        #expect(placed.width - 2 <= 34 && placed.height - 2 <= 37)
    }

    @Test("rounding outwards past the box tightens the scale once")
    func tighten() throws {
        // Scaled to exactly 14 wide, but starting at x = 0.5 the rounded extent is 15 px.
        let placed = try #require(GlyphPlacement.place(glyphs: [(box(0.5, 0, 28.5, 10), 0, 0)],
                                                       boxWidth: 14, boxHeight: 30, padding: 0))
        #expect(placed.width <= 14)
        #expect(placed.appliedScale < 0.5)
    }
}
