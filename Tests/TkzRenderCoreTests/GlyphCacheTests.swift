// GlyphCacheTests — the glyph cache over a synthetic `GlyphSource` (WOR-311 S3).
//
// The CoreText routing cases stay in TkzTerminalRenderTests; these pin the cache logic itself on
// both OSes: only a miss reaches the source, empty clusters are remembered, sprites are keyed once
// for every style, and placements survive a regrow but not a rebuild.

import Testing
import TkzRenderCore

@Suite("GlyphCache over GlyphSource")
struct GlyphCacheTests {
    private static let metrics = CellMetrics(ascent: 25.5, descent: 7.5, leading: 0, maxAdvance: 15,
                                             underlinePosition: -3.875, underlineThickness: 1.25,
                                             strikeoutPosition: 8, strikeoutThickness: 1.25, scale: 2)

    private func source(sprites: Bool = false, color: Set<Unicode.Scalar> = []) -> BlockGlyphSource {
        BlockGlyphSource(metrics: Self.metrics, drawsSprites: sprites, colorScalars: color)
    }

    @Test("the cache reads the source's metrics and starts with empty atlases")
    func construction() {
        let cache = GlyphCache(source: source(), grayscaleInitialSize: 64, colorInitialSize: 32)
        #expect(cache.metrics == Self.metrics)
        #expect(cache.grayscale.kind == .grayscale && cache.grayscale.size == 64)
        #expect(cache.color.kind == .color && cache.color.size == 32)
        #expect(cache.atlas(for: .grayscale) === cache.grayscale)
        #expect(cache.atlas(for: .color) === cache.color)
        #expect(cache.cachedCount == 0)
    }

    @Test("a hit never reaches the source; a miss shapes and rasterizes once")
    func hitsSkipTheSource() throws {
        let source = self.source()
        let cache = GlyphCache(source: source)

        let first = try #require(cache.glyph(forScalar: "A", cellSpan: 1))
        #expect(source.shapeCalls == 1)
        #expect(source.rasterizeCalls == 1)
        #expect(first.cellSpan == 1)
        #expect(first.slot.kind == .grayscale)
        #expect(first.slot.width == 15 + 2 && first.slot.height == 33 + 2)
        #expect(first.bearingX == -1 && first.bearingTop == 27)

        // Every entry point finds the same placement without asking the source again.
        #expect(cache.glyph(forScalar: "A", cellSpan: 1) == first)
        #expect(cache.glyph(for: ["A"], cellSpan: 1) == first)
        #expect(cache.glyph(for: Character("A"), cellSpan: 1) == first)
        #expect(source.shapeCalls == 1)
        #expect(source.rasterizeCalls == 1)

        // With no span the key needs the shaper's answer, but the bitmap is still reused.
        #expect(cache.glyph(for: ["A"]) == first)
        #expect(source.shapeCalls == 2)
        #expect(source.rasterizeCalls == 1)
        #expect(cache.cachedCount == 1)
    }

    @Test("style and span are part of the key")
    func keyedByStyleAndSpan() throws {
        let source = self.source()
        let cache = GlyphCache(source: source)
        let regular = try #require(cache.glyph(forScalar: "A", style: .regular, cellSpan: 1))
        let bold = try #require(cache.glyph(forScalar: "A", style: .bold, cellSpan: 1))
        let wide = try #require(cache.glyph(forScalar: "A", style: .regular, cellSpan: 2))
        #expect(regular.slot != bold.slot)
        #expect(wide.cellSpan == 2)
        #expect(wide.slot.width == 15 * 2 + 2)
        #expect(cache.cachedCount == 3)
        #expect(source.rasterizeCalls == 3)
    }

    @Test("multi-scalar clusters are keyed by every scalar")
    func clusterKeys() throws {
        let source = self.source()
        let cache = GlyphCache(source: source)
        let composed = try #require(cache.glyph(for: ["e", "\u{301}"], cellSpan: 1))
        let other = try #require(cache.glyph(for: ["e", "\u{300}"], cellSpan: 1))
        let bare = try #require(cache.glyph(forScalar: "e", cellSpan: 1))
        #expect(composed.slot != other.slot)
        #expect(composed.slot != bare.slot)
        #expect(cache.glyph(for: Character("e\u{301}"), cellSpan: 1) == composed)
        #expect(source.rasterizeCalls == 3)
    }

    @Test("a cluster with nothing to draw is cached as empty and never re-derived")
    func emptyIsRemembered() {
        let source = self.source()
        let cache = GlyphCache(source: source)
        #expect(cache.glyph(forScalar: " ", cellSpan: 1) == nil)
        #expect(source.shapeCalls == 1)
        #expect(source.rasterizeCalls == 1)
        #expect(cache.cachedCount == 1)
        for _ in 0..<5 {
            #expect(cache.glyph(forScalar: " ", cellSpan: 1) == nil)
            #expect(cache.glyph(for: [" "], cellSpan: 1) == nil)
        }
        #expect(source.shapeCalls == 1)
        #expect(source.rasterizeCalls == 1)
        #expect(cache.grayscale.hasPendingUpload == false)
    }

    @Test("colour clusters go to the colour atlas")
    func colourRouting() throws {
        let source = self.source(color: ["😀"])
        let cache = GlyphCache(source: source, colorInitialSize: 128)
        let emoji = try #require(cache.glyph(for: ["😀"]))
        #expect(emoji.isColor)
        #expect(emoji.slot.kind == .color)
        #expect(emoji.cellSpan == 2)
        #expect(cache.color.hasPendingUpload)
        #expect(cache.grayscale.hasPendingUpload == false)
        #expect(cache.color.stagedPixel(x: emoji.slot.x, y: emoji.slot.y) == [0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test("box sprites are drawn, not shaped, and shared by every style")
    func spritesBypassTheShaper() throws {
        let source = self.source(sprites: true)
        let cache = GlyphCache(source: source)
        let regular = try #require(cache.glyph(forScalar: "█", style: .regular, cellSpan: 1))
        let bold = cache.glyph(forScalar: "█", style: .bold, cellSpan: 1)
        let italic = cache.glyph(for: ["█"], style: .italic)
        #expect(regular == bold)
        #expect(regular == italic)
        #expect(regular.cellSpan == 1)
        #expect(cache.cachedCount == 1)
        #expect(source.spriteCalls == 1)
        #expect(source.shapeCalls == 0)
        #expect(cache.grayscale.stagedPixel(x: regular.slot.x, y: regular.slot.y) == [0x80])
    }

    @Test("a sprite scalar the source cannot draw falls back to the font")
    func spriteFallback() throws {
        let source = self.source(sprites: false)
        let cache = GlyphCache(source: source)
        let glyph = try #require(cache.glyph(forScalar: "─", style: .bold, cellSpan: 1))
        // Asked twice on the first miss: once by `forScalar:`, once more by the general path it
        // falls through to. A source that covers the sprite range (the Mac's) never gets here.
        #expect(source.spriteCalls == 2)
        #expect(source.shapeCalls == 1)
        #expect(cache.grayscale.stagedPixel(x: glyph.slot.x, y: glyph.slot.y) == [0xFF])
        // Cached under the font key: the second lookup asks for the sprite again, then hits.
        #expect(cache.glyph(forScalar: "─", style: .bold, cellSpan: 1) == glyph)
        #expect(source.spriteCalls == 3)
        #expect(source.shapeCalls == 1)
        #expect(source.rasterizeCalls == 1)
    }

    @Test("a regrow re-stamps cached placements instead of re-rasterizing them")
    func regrowRevalidates() throws {
        let source = self.source()
        // 17×35 bitmaps: three fit one 64-px shelf, and a second shelf does not fit, so "d" grows it.
        let cache = GlyphCache(source: source, grayscaleInitialSize: 64)
        let first = try #require(cache.glyph(forScalar: "a", cellSpan: 1))
        _ = try #require(cache.glyph(forScalar: "b", cellSpan: 1))
        _ = try #require(cache.glyph(forScalar: "c", cellSpan: 1))
        _ = try #require(cache.glyph(forScalar: "d", cellSpan: 1))
        #expect(cache.grayscale.growCount >= 1)
        #expect(cache.grayscale.isValid(first.slot) == false)

        let again = try #require(cache.glyph(forScalar: "a", cellSpan: 1))
        #expect(source.rasterizeCalls == 4)
        #expect(again.slot.x == first.slot.x && again.slot.y == first.slot.y)
        #expect(again.slot.generation == cache.grayscale.generation)
        #expect(again.slot.atlasSize == cache.grayscale.size)
        #expect(cache.grayscale.isValid(again.slot))
    }

    @Test("a rebuild drops the placements it cleared but keeps the empty answers")
    func rebuildDropsEntries() throws {
        // 18×136 bitmaps: a 2048² atlas holds 113 per shelf and 15 shelves, then has to rebuild.
        let metrics = CellMetrics(ascent: 100, descent: 34, leading: 0, maxAdvance: 16,
                                  underlinePosition: -2, underlineThickness: 1,
                                  strikeoutPosition: 4, strikeoutThickness: 1, scale: 2)
        let source = BlockGlyphSource(metrics: metrics)
        let cache = GlyphCache(source: source, grayscaleInitialSize: 2048)
        #expect(cache.glyph(forScalar: " ", cellSpan: 1) == nil)
        let first = try #require(cache.glyph(forScalar: "A", cellSpan: 1))

        var scalar: UInt32 = 0x4E00
        while cache.grayscale.rebuildCount == 0 {
            _ = cache.glyph(forScalar: Unicode.Scalar(scalar)!, cellSpan: 1)
            scalar += 1
        }
        #expect(cache.grayscale.revalidate(first.slot) == nil)
        // Only the glyph that triggered the rebuild and the space are left.
        #expect(cache.cachedCount == 2)
        let calls = source.rasterizeCalls
        #expect(cache.glyph(forScalar: " ", cellSpan: 1) == nil)
        #expect(source.rasterizeCalls == calls)
        // "A" lost its pixels, so it is drawn again into the rebuilt atlas.
        let redrawn = try #require(cache.glyph(forScalar: "A", cellSpan: 1))
        #expect(source.rasterizeCalls == calls + 1)
        #expect(cache.grayscale.isValid(redrawn.slot))
    }
}
