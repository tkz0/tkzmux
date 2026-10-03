// GlyphCacheFreeTypeTests — TkzRenderCore's GlyphCache over the FreeType source (WOR-311 S3): the
// Linux font stack fills the shared atlases the way CoreTextGlyphSource fills them on the Mac.

import Testing
import TkzRenderCore
@testable import TkzFontsFT

@Suite("GlyphCache over FreeTypeGlyphSource")
struct GlyphCacheFreeTypeTests {
    private func source() throws -> FreeTypeGlyphSource {
        FreeTypeGlyphSource(faces: try TerminalFaces(pointSize: 14, scale: 2, fallback: TestFallbacks.system))
    }

    /// The bytes of `slot` in `atlas`, row by row.
    private func pixels(of slot: AtlasSlot, in atlas: GlyphAtlas) -> [UInt8] {
        var out: [UInt8] = []
        for y in slot.y..<(slot.y + slot.height) {
            for x in slot.x..<(slot.x + slot.width) { out += atlas.stagedPixel(x: x, y: y) }
        }
        return out
    }

    @Test("ASCII lands in the grayscale atlas as the source rasterizes it, and a space draws nothing")
    func packsWhatTheSourceDraws() throws {
        let source = try source()
        let cache = GlyphCache(source: source, grayscaleInitialSize: 256, colorInitialSize: 64)
        #expect(cache.metrics == source.metrics)

        for style in FontStyle.allCases {
            for scalar in ["A", "g", "@", "─"] as [Unicode.Scalar] {
                let glyph = try #require(cache.glyph(forScalar: scalar, style: style, cellSpan: 1))
                let shaped = source.shape([scalar], style: style, cellSpan: 1)
                let raster = try #require(source.rasterize(shaped, style: style))
                #expect(glyph.slot.kind == .grayscale)
                #expect(glyph.cellSpan == 1)
                #expect(glyph.slot.width == raster.width && glyph.slot.height == raster.height)
                #expect(glyph.bearingX == raster.bearingX && glyph.bearingTop == raster.bearingTop)
                #expect(pixels(of: glyph.slot, in: cache.grayscale) == raster.pixels, "\(scalar) \(style)")
            }
        }
        #expect(cache.glyph(forScalar: " ", cellSpan: 1) == nil)
        #expect(cache.grayscale.hasPendingUpload)
        #expect(cache.color.hasPendingUpload == false)
    }

    @Test("a wide cluster gets a two-cell placement")
    func wideCluster() throws {
        let source = try source()
        let cache = GlyphCache(source: source)
        let glyph = try #require(cache.glyph(forScalar: "M", cellSpan: 2))
        #expect(glyph.cellSpan == 2)
        #expect(glyph.slot.width <= source.metrics.width * 2 + 2 * source.padding)
        #expect(cache.glyph(forScalar: "M", cellSpan: 2) == glyph)
        #expect(cache.glyph(forScalar: "M", cellSpan: 1) != glyph)
    }
}
