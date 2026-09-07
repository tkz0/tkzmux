import CoreGraphics
import Foundation
import Metal
import Testing
@testable import TkzTerminalRender

@Suite("GlyphAtlas & GlyphCache")
struct GlyphAtlasTests {

    /// `nil` on a machine with no Metal device; the atlas then runs CPU-only, which is enough for
    /// packing, generation and PNG-dump coverage.
    private var device: MTLDevice? { MTLCreateSystemDefaultDevice() }

    private func cache(gray: Int? = nil, color: Int? = nil) -> GlyphCache {
        GlyphCache(fontSet: FontSet(pointSize: 12.5, scale: 2), device: device,
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
        let device = try #require(device, "no Metal device on this machine")
        let cache = GlyphCache(fontSet: FontSet(pointSize: 12.5, scale: 2), device: device)
        let gray = try #require(cache.grayscale.texture)
        #expect(gray.pixelFormat == .r8Unorm)
        #expect(gray.width == 2048 && gray.height == 2048)
        let color = try #require(cache.color.texture)
        #expect(color.pixelFormat == .bgra8Unorm)
        #expect(color.width == 1024 && color.height == 1024)
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
        let cache = self.cache()
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
        let shaper = cache.shaper
        let narrow = shaper.shape("😀", cellSpan: 1)
        let raster = try #require(cache.rasterizer.rasterize(narrow))
        #expect(raster.appliedScale < 1)
        #expect(raster.isColor)
        #expect(raster.bytesPerPixel == 4)
        #expect(raster.width <= metrics.width + 2 * cache.rasterizer.padding)
        #expect(raster.height <= metrics.height + 2 * cache.rasterizer.padding)

        // Grayscale glyphs fit as drawn.
        let letter = try #require(cache.rasterizer.rasterize(shaper.shape("A")))
        #expect(letter.appliedScale == 1)
        #expect(letter.bytesPerPixel == 1)
    }

    @Test("rasterizing produces non-empty coverage and sane bearings")
    func rasterCoverage() throws {
        let cache = self.cache()
        let raster = try #require(cache.rasterizer.rasterize(cache.shaper.shape("A")))
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

    // MARK: - Packing, generations, regrow

    @Test("the shelf packer places glyphs without overlapping")
    func shelfPacking() {
        let atlas = GlyphAtlas(kind: .grayscale, device: nil, initialSize: 64)
        var slots: [AtlasSlot] = []
        for _ in 0..<6 {
            let pixels = [UInt8](repeating: 0xFF, count: 10 * 10)
            if let slot = atlas.insert(pixels: pixels, width: 10, height: 10, bytesPerRow: 10) {
                slots.append(slot)
            }
        }
        #expect(slots.count == 6)
        for (i, a) in slots.enumerated() {
            for b in slots[(i + 1)...] {
                let ra = CGRect(x: a.x, y: a.y, width: a.width, height: a.height)
                let rb = CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
                #expect(ra.intersects(rb) == false)
            }
        }
    }

    @Test("regrow doubles the atlas, bumps the generation and invalidates old slots")
    func regrowInvalidatesViaGeneration() throws {
        let atlas = GlyphAtlas(kind: .grayscale, device: device, initialSize: 32)
        #expect(atlas.size == 32)
        let generationBefore = atlas.generation

        let pixels = [UInt8](repeating: 0xAB, count: 16 * 16)
        let first = try #require(atlas.insert(pixels: pixels, width: 16, height: 16, bytesPerRow: 16))
        #expect(atlas.isValid(first))
        #expect(first.atlasSize == 32)

        // Fill past 32² so the atlas has to grow.
        var grown = false
        for _ in 0..<8 {
            _ = atlas.insert(pixels: pixels, width: 16, height: 16, bytesPerRow: 16)
            if atlas.size > 32 { grown = true; break }
        }
        #expect(grown)
        #expect(atlas.growCount >= 1)
        #expect(atlas.generation != generationBefore)

        // The old slot's *coordinates* survive the copy, but its UVs are wrong for the bigger
        // texture — which is exactly what the generation stamp tells the holder.
        #expect(atlas.isValid(first) == false)
        #expect(atlas.stagedPixel(x: first.x, y: first.y) == [0xAB])

        // The pixels moved with the atlas, so the slot can be re-stamped rather than re-rasterized.
        let revalidated = try #require(atlas.revalidate(first))
        #expect(revalidated.x == first.x && revalidated.y == first.y)
        #expect(revalidated.width == first.width && revalidated.height == first.height)
        #expect(revalidated.generation == atlas.generation)
        #expect(revalidated.atlasSize == atlas.size)
        #expect(atlas.isValid(revalidated))

        // Re-inserting under the new generation produces a valid slot again.
        let refreshed = try #require(atlas.insert(pixels: pixels, width: 16, height: 16, bytesPerRow: 16))
        #expect(atlas.isValid(refreshed))
        #expect(refreshed.generation == atlas.generation)
        #expect(refreshed.atlasSize == atlas.size)
    }

    @Test("overflow at max size rebuilds the atlas rather than failing")
    func overflowRebuilds() throws {
        let atlas = GlyphAtlas(kind: .color, device: nil, initialSize: 2048)
        #expect(atlas.size == 2048)
        let generationBefore = atlas.generation
        let pixels = [UInt8](repeating: 0xFF, count: 512 * 512 * 4)
        var slots: [AtlasSlot] = []
        for _ in 0..<20 {
            if let slot = atlas.insert(pixels: pixels, width: 512, height: 512, bytesPerRow: 512 * 4) {
                slots.append(slot)
            }
        }
        #expect(slots.count == 20)
        #expect(atlas.rebuildCount >= 1)
        #expect(atlas.generation != generationBefore)
        #expect(atlas.isValid(slots[0]) == false)
        // A rebuild threw the pixels away: the slot cannot be re-stamped either.
        #expect(atlas.revalidate(slots[0]) == nil)
        #expect(atlas.isValid(slots[slots.count - 1]))
    }

    @Test("a glyph larger than an empty max-size atlas is refused instead of looping")
    func impossibleGlyph() {
        let atlas = GlyphAtlas(kind: .grayscale, device: nil, initialSize: 64)
        let pixels = [UInt8](repeating: 0xFF, count: 4096 * 4)
        #expect(atlas.insert(pixels: pixels, width: 4096, height: 4, bytesPerRow: 4096) == nil)
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

    @Test("uploads are batched: one flush clears the pending region")
    func batchedUpload() throws {
        let cache = self.cache()
        _ = cache.glyph(for: "A")
        _ = cache.glyph(for: "B")
        _ = cache.glyph(for: "😀")
        #expect(cache.grayscale.hasPendingUpload)
        #expect(cache.color.hasPendingUpload)
        cache.flushUploads()
        #expect(cache.grayscale.hasPendingUpload == false)
        #expect(cache.color.hasPendingUpload == false)
    }

    // MARK: - Dump

    @Test("the atlas exposes a CGImage and PNG bytes for `vtdump atlas --png`")
    func pngDump() throws {
        let cache = self.cache(gray: 128, color: 128)
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
        let raster = try #require(cache.rasterizer.rasterize(cache.shaper.shape("A")))
        let glyphImage = try #require(GlyphRasterizer.makeCGImage(raster))
        #expect(glyphImage.width == raster.width)
        #expect(GlyphRasterizer.pngData(from: glyphImage) != nil)
    }

    @Test("slot UVs are normalized against the atlas size the slot was packed at")
    func uvs() throws {
        let atlas = GlyphAtlas(kind: .grayscale, device: nil, initialSize: 64)
        let pixels = [UInt8](repeating: 0xFF, count: 16 * 8)
        let slot = try #require(atlas.insert(pixels: pixels, width: 16, height: 8, bytesPerRow: 16))
        #expect(slot.uvOrigin.0 == 0)
        #expect(slot.uvOrigin.1 == 0)
        #expect(slot.uvSize.0 == 16.0 / 64.0)
        #expect(slot.uvSize.1 == 8.0 / 64.0)
    }
}
