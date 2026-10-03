// The Mac half of the glyph atlases: CoreText routing and fitting through `CoreTextGlyphSource`,
// the Metal textures `MetalAtlasUploader` keeps in step, and the CoreGraphics dump. The packer
// itself (shelves, generations, regrow, rebuild, the dirty region) and the cache logic over a
// synthetic source are tested in TkzRenderCoreTests, on both OSes.

import CoreGraphics
import Foundation
import Metal
import Testing
import TkzRenderCore
@testable import TkzTerminalRender

@Suite("GlyphAtlas & GlyphCache (CoreText, Metal)")
struct GlyphAtlasTests {

    private func source() -> CoreTextGlyphSource {
        CoreTextGlyphSource(fontSet: FontSet(pointSize: 12.5, scale: 2))
    }

    private func cache(gray: Int? = nil, color: Int? = nil) -> GlyphCache {
        GlyphCache(fontSet: FontSet(pointSize: 12.5, scale: 2),
                   grayscaleInitialSize: gray, colorInitialSize: color)
    }

    // MARK: - Formats

    @Test("atlas kinds carry the design formats and sizes")
    func kinds() {
        #expect(AtlasKind.grayscale.pixelFormat == .r8Unorm)
        #expect(AtlasKind.grayscale.defaultInitialSize == 2048)
        #expect(AtlasKind.grayscale.bytesPerPixel == 1)
        #expect(AtlasKind.color.pixelFormat == .bgra8Unorm)
        #expect(AtlasKind.color.defaultInitialSize == 1024)
        #expect(AtlasKind.color.maxSize == 2048)
        #expect(AtlasKind.color.bytesPerPixel == 4)
    }

    @Test("a Metal device backs the atlases with textures of the right format")
    func textures() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device on this machine")
        let cache = self.cache()
        let uploader = try #require(MetalAtlasUploader(device: device, cache: cache))
        #expect(uploader.grayscale.pixelFormat == .r8Unorm)
        #expect(uploader.grayscale.width == 2048 && uploader.grayscale.height == 2048)
        #expect(uploader.color.pixelFormat == .bgra8Unorm)
        #expect(uploader.color.width == 1024 && uploader.color.height == 1024)
    }

    // MARK: - Routing

    @Test("A / 你 / 😀 / 👨‍👩‍👧 land in the right atlas with the right cell span")
    func routing() throws {
        let cache = self.cache()

        let a = try #require(cache.glyph(for: "A"))
        #expect(a.slot.kind == .grayscale)
        #expect(a.isColor == false)
        #expect(a.cellSpan == 1)

        let han = try #require(cache.glyph(for: "你"))
        #expect(han.slot.kind == .grayscale)
        #expect(han.cellSpan == 2)

        let emoji = try #require(cache.glyph(for: "😀"))
        #expect(emoji.slot.kind == .color)
        #expect(emoji.isColor)
        #expect(emoji.cellSpan == 2)

        let family = try #require(cache.glyph(for: "👨‍👩‍👧"))
        #expect(family.slot.kind == .color)
        #expect(family.isColor)
        #expect(family.cellSpan == 2)
    }

    @Test("every glyph fits its 1- or 2-cell box; oversize colour bitmaps are scaled down")
    func fitsCellBox() throws {
        let source = self.source()
        let cache = GlyphCache(source: source)
        let metrics = cache.metrics

        for (text, span) in [("A", 1), ("你", 2), ("😀", 2), ("👨‍👩‍👧", 2)] {
            let glyph = try #require(cache.glyph(for: Character(text)))
            #expect(glyph.cellSpan == span)
            // + 2 px for the transparent padding the rasterizer keeps around each glyph.
            #expect(glyph.slot.width <= metrics.width * span + 2)
            #expect(glyph.slot.height <= metrics.height + 2)
        }

        // Apple Color Emoji is drawn far larger than a terminal cell, so the fit path must run.
        // Force it deterministically by asking for a single-cell box.
        let shaper = source.shaper
        let narrow = shaper.shape("😀", cellSpan: 1)
        let raster = try #require(source.rasterizer.rasterize(narrow))
        #expect(raster.appliedScale < 1)
        #expect(raster.isColor)
        #expect(raster.bytesPerPixel == 4)
        #expect(raster.width <= metrics.width + 2 * source.rasterizer.padding)
        #expect(raster.height <= metrics.height + 2 * source.rasterizer.padding)

        // Grayscale glyphs fit as drawn.
        let letter = try #require(source.rasterizer.rasterize(shaper.shape("A")))
        #expect(letter.appliedScale == 1)
        #expect(letter.bytesPerPixel == 1)
    }

    @Test("rasterizing produces non-empty coverage and sane bearings")
    func rasterCoverage() throws {
        let source = self.source()
        let raster = try #require(source.rasterizer.rasterize(source.shaper.shape("A")))
        #expect(raster.pixels.contains { $0 > 0 })
        #expect(raster.width > 0 && raster.height > 0)
        // 'A' sits on the baseline, so its top bearing is positive and no lower than its height.
        #expect(raster.bearingTop > 0)
        #expect(raster.bearingTop >= raster.height - 2)
    }

    @Test("a space has nothing to draw")
    func blankCluster() {
        let cache = self.cache()
        #expect(cache.glyph(for: " ") == nil)
    }

    // MARK: - CoreTextGlyphSource

    /// The seam must not change a single bitmap: shaping and rasterizing through the source's
    /// `FontFace`/`GlyphID` round trip gives the bytes the shaper and rasterizer give directly.
    @Test("the CoreText source rasterizes exactly what GraphemeShaper + GlyphRasterizer draw")
    func sourceMatchesDirectPath() throws {
        let source = self.source()
        let clusters: [Character] = ["A", "g", "@", "你", "é", "e\u{301}", "😀", "👨‍👩‍👧", "❤️", "→", "\u{E0B0}"]
        var earlier: [(cluster: ShapedCluster, style: FontStyle, expected: RasterizedGlyph?)] = []
        for character in clusters {
            let scalars = Array(character.unicodeScalars)
            for style in FontStyle.allCases {
                let direct = source.shaper.shape(scalars, style: style)
                let shaped = source.shape(scalars, style: style, cellSpan: nil)
                #expect(shaped.cellSpan == direct.cellSpan)
                #expect(shaped.isColor == direct.isColor)
                #expect(shaped.glyphs.map(\.glyph.rawValue) == direct.glyphs.map { UInt32($0.glyph) })
                #expect(source.name(of: shaped.face) == direct.fontName)
                let expected = source.rasterizer.rasterize(direct, style: style)
                #expect(source.rasterize(shaped, style: style) == expected, "\(character) \(style)")
                earlier.append((shaped, style, expected))
            }
        }
        // Rasterized again after other clusters were shaped, each goes through the face table.
        for (cluster, style, expected) in earlier {
            #expect(source.rasterize(cluster, style: style) == expected, "\(cluster.glyphs) \(style)")
        }
    }

    @Test("the CoreText source hands out one FontFace per resolved face")
    func faceTable() throws {
        let source = self.source()
        let a = source.shape(["A"], style: .regular, cellSpan: nil)
        let b = source.shape(["B"], style: .regular, cellSpan: nil)
        #expect(a.face == b.face)
        #expect(source.name(of: a.face) == source.fontSet.postScriptName(for: .regular))
        let bold = source.shape(["A"], style: .bold, cellSpan: nil)
        #expect(bold.face != a.face)
        let emoji = source.shape(["😀"], style: .regular, cellSpan: nil)
        #expect(emoji.face != a.face)
        #expect(emoji.isColor)
        #expect(source.font(of: FontFace(rawValue: 9999)) == nil)
        #expect(source.name(of: FontFace(rawValue: 9999)) == "?")
    }

    @Test("GlyphCache re-validates cached placements after the atlas changes generation")
    func cacheRevalidates() throws {
        // A tiny colour atlas forces a regrow while packing emoji.
        let cache = self.cache(gray: 2048, color: 16)
        let before = try #require(cache.glyph(for: "😀"))
        #expect(cache.color.isValid(before.slot))
        #expect(before.slot.generation == cache.color.generation)

        // 😀 alone already overflows a 16² atlas, so the atlas must have grown.
        #expect(cache.color.growCount >= 1)

        let after = try #require(cache.glyph(for: "😀"))
        #expect(cache.color.isValid(after.slot))
        #expect(after.slot.atlasSize == cache.color.size)

        // Repeated lookups of a still-valid entry are served from the cache.
        let again = try #require(cache.glyph(for: "😀"))
        #expect(again == after)
    }

    // MARK: - Upload

    @Test("uploads are batched: one upload clears the pending region")
    func batchedUpload() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device on this machine")
        let cache = self.cache()
        let uploader = try #require(MetalAtlasUploader(device: device, cache: cache))
        _ = cache.glyph(for: "A")
        _ = cache.glyph(for: "B")
        _ = cache.glyph(for: "😀")
        #expect(cache.grayscale.hasPendingUpload)
        #expect(cache.color.hasPendingUpload)
        uploader.upload(cache)
        #expect(cache.grayscale.hasPendingUpload == false)
        #expect(cache.color.hasPendingUpload == false)
    }

    @Test("a grown atlas gets a new texture of the new size, filled from the staging buffer")
    func uploadReplacesTextureOnGrow() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device on this machine")
        let cache = self.cache(gray: 16, color: 16)
        let uploader = try #require(MetalAtlasUploader(device: device, cache: cache))
        let before = uploader.grayscale
        #expect(before.width == 16)

        let glyph = try #require(cache.glyph(for: "W"))
        #expect(cache.grayscale.growCount >= 1)
        uploader.upload(cache)
        #expect(uploader.grayscale !== before)
        #expect(uploader.grayscale.width == cache.grayscale.size)
        #expect(uploader.grayscale.height == cache.grayscale.size)

        // The texture holds the staged bytes of the glyph's slot.
        let slot = glyph.slot
        var read = [UInt8](repeating: 0, count: slot.width * slot.height)
        read.withUnsafeMutableBytes { raw in
            uploader.grayscale.getBytes(raw.baseAddress!, bytesPerRow: slot.width,
                                        from: MTLRegionMake2D(slot.x, slot.y, slot.width, slot.height),
                                        mipmapLevel: 0)
        }
        var staged: [UInt8] = []
        for y in slot.y..<(slot.y + slot.height) {
            for x in slot.x..<(slot.x + slot.width) { staged += cache.grayscale.stagedPixel(x: x, y: y) }
        }
        #expect(read == staged)
        #expect(read.contains { $0 > 0 })
    }

    // MARK: - Dump

    @Test("the atlas exposes a CGImage and PNG bytes for `vtdump atlas --png`")
    func pngDump() throws {
        let source = self.source()
        let cache = GlyphCache(source: source, grayscaleInitialSize: 128, colorInitialSize: 128)
        _ = cache.glyph(for: "A")
        _ = cache.glyph(for: "😀")

        let grayImage = try #require(cache.grayscale.makeCGImage())
        #expect(grayImage.width == cache.grayscale.size)
        let grayPNG = try #require(cache.grayscale.pngData())
        #expect(grayPNG.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let colorImage = try #require(cache.color.makeCGImage())
        #expect(colorImage.width == cache.color.size)
        let colorPNG = try #require(cache.color.pngData())
        #expect(colorPNG.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        // A single rasterized glyph can also be dumped.
        let raster = try #require(source.rasterizer.rasterize(source.shaper.shape("A")))
        let glyphImage = try #require(GlyphRasterizer.makeCGImage(raster))
        #expect(glyphImage.width == raster.width)
        #expect(GlyphRasterizer.pngData(from: glyphImage) != nil)
    }
}
