// GlyphAtlasTests — the device-free packer (WOR-311 S3, moved from TkzTerminalRenderTests): shelf
// packing, generations, regrow, rebuild, UVs and the one dirty region an uploader takes per frame.

import Testing
import TkzRenderCore

@Suite("GlyphAtlas packer")
struct GlyphAtlasTests {

    private func overlaps(_ a: AtlasSlot, _ b: AtlasSlot) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }

    /// Packs a `width`×`height` grayscale block of `value`.
    private func block(_ atlas: GlyphAtlas, _ width: Int, _ height: Int, _ value: UInt8) -> AtlasSlot? {
        atlas.insert(pixels: [UInt8](repeating: value, count: width * height), width: width, height: height,
                     bytesPerRow: width)
    }

    @Test("atlas kinds carry the design sizes")
    func kinds() {
        #expect(AtlasKind.grayscale.defaultInitialSize == 2048)
        #expect(AtlasKind.grayscale.bytesPerPixel == 1)
        #expect(AtlasKind.color.defaultInitialSize == 1024)
        #expect(AtlasKind.color.maxSize == 2048)
        #expect(AtlasKind.color.bytesPerPixel == 4)

        let atlas = GlyphAtlas(kind: .color)
        #expect(atlas.size == 1024)
        #expect(atlas.bytesPerRow == 4096)
        #expect(atlas.staging.count == 1024 * 1024 * 4)
        #expect(atlas.hasPendingUpload == false)
        // Below 16 or above the maximum, the start size is clamped.
        #expect(GlyphAtlas(kind: .grayscale, initialSize: 4).size == 16)
        #expect(GlyphAtlas(kind: .grayscale, initialSize: 9000).size == 2048)
    }

    @Test("the shelf packer places glyphs without overlapping")
    func shelfPacking() {
        let atlas = GlyphAtlas(kind: .grayscale, initialSize: 64)
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
                #expect(overlaps(a, b) == false)
            }
        }
    }

    @Test("best fit: a short glyph goes on the shortest shelf that holds it")
    func bestFitShelf() throws {
        let atlas = GlyphAtlas(kind: .grayscale, initialSize: 64)
        let tall = try #require(block(atlas, 8, 20, 1))
        let short = try #require(block(atlas, 60, 10, 2))
        // The 60-wide glyph does not fit beside the tall one, so it opened a shelf above it.
        #expect(tall.x == 0 && tall.y == 0)
        #expect(short.x == 0 && short.y == 20)
        // A 4×8 glyph fits both shelves; the 10-high one is the better fit.
        let small = try #require(block(atlas, 4, 8, 3))
        #expect(small.x == 60 && small.y == 20)
    }

    @Test("rows are copied from the source stride into the staging buffer")
    func blitHonoursStride() throws {
        let atlas = GlyphAtlas(kind: .color, initialSize: 16)
        // 2×2 BGRA pixels in rows of 3 pixels: the third pixel of each row must not be copied.
        let pixels: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 99, 99, 99, 99,
                               9, 10, 11, 12, 13, 14, 15, 16, 99, 99, 99, 99]
        let slot = try #require(atlas.insert(pixels: pixels, width: 2, height: 2, bytesPerRow: 12))
        #expect(atlas.stagedPixel(x: slot.x, y: slot.y) == [1, 2, 3, 4])
        #expect(atlas.stagedPixel(x: slot.x + 1, y: slot.y) == [5, 6, 7, 8])
        #expect(atlas.stagedPixel(x: slot.x, y: slot.y + 1) == [9, 10, 11, 12])
        #expect(atlas.stagedPixel(x: slot.x + 1, y: slot.y + 1) == [13, 14, 15, 16])
        #expect(atlas.stagedPixel(x: slot.x + 2, y: slot.y) == [0, 0, 0, 0])
        #expect(atlas.stagedPixel(x: -1, y: 0) == [])
        #expect(atlas.stagedPixel(x: 0, y: 16) == [])
    }

    @Test("regrow doubles the atlas, bumps the generation and invalidates old slots")
    func regrowInvalidatesViaGeneration() throws {
        let atlas = GlyphAtlas(kind: .grayscale, initialSize: 32)
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
        let atlas = GlyphAtlas(kind: .color, initialSize: 2048)
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
        #expect(atlas.rebuildGeneration > generationBefore)
        #expect(atlas.isValid(slots[0]) == false)
        // A rebuild threw the pixels away: the slot cannot be re-stamped either.
        #expect(atlas.revalidate(slots[0]) == nil)
        #expect(atlas.isValid(slots[slots.count - 1]))
    }

    @Test("a glyph larger than an empty max-size atlas is refused instead of looping")
    func impossibleGlyph() {
        let atlas = GlyphAtlas(kind: .grayscale, initialSize: 64)
        let pixels = [UInt8](repeating: 0xFF, count: 4096 * 4)
        #expect(atlas.insert(pixels: pixels, width: 4096, height: 4, bytesPerRow: 4096) == nil)
        #expect(atlas.insert(pixels: [], width: 0, height: 4, bytesPerRow: 0) == nil)
    }

    @Test("slot UVs are normalized against the atlas size the slot was packed at")
    func uvs() throws {
        let atlas = GlyphAtlas(kind: .grayscale, initialSize: 64)
        let pixels = [UInt8](repeating: 0xFF, count: 16 * 8)
        let slot = try #require(atlas.insert(pixels: pixels, width: 16, height: 8, bytesPerRow: 16))
        #expect(slot.uvOrigin.0 == 0)
        #expect(slot.uvOrigin.1 == 0)
        #expect(slot.uvSize.0 == 16.0 / 64.0)
        #expect(slot.uvSize.1 == 8.0 / 64.0)
    }

    // MARK: - Dirty region

    @Test("the pending region is the bounding box of everything staged since the last take")
    func dirtyBoundingBox() throws {
        let atlas = GlyphAtlas(kind: .grayscale, initialSize: 64)
        #expect(atlas.takePendingRegion() == nil)

        let a = try #require(block(atlas, 10, 12, 1))
        #expect(atlas.pendingRegion == AtlasRegion(x: a.x, y: a.y, width: 10, height: 12))
        let b = try #require(block(atlas, 6, 4, 1))
        #expect(b.x == 10 && b.y == 0)
        let c = try #require(block(atlas, 60, 5, 1))
        #expect(c.x == 0 && c.y == 12)

        #expect(atlas.hasPendingUpload)
        #expect(atlas.takePendingRegion() == AtlasRegion(x: 0, y: 0, width: 60, height: 17))
        #expect(atlas.hasPendingUpload == false)
        #expect(atlas.takePendingRegion() == nil)

        // The next frame's region starts afresh.
        let d = try #require(block(atlas, 3, 3, 1))
        #expect(atlas.takePendingRegion() == AtlasRegion(x: d.x, y: d.y, width: 3, height: 3))
    }

    @Test("a grow or a rebuild marks the whole atlas for upload")
    func growAndRebuildDirtyEverything() throws {
        let grower = GlyphAtlas(kind: .grayscale, initialSize: 16)
        _ = grower.takePendingRegion()
        _ = try #require(block(grower, 20, 20, 1))
        #expect(grower.size == 32)
        #expect(grower.takePendingRegion() == AtlasRegion(x: 0, y: 0, width: 32, height: 32))

        let rebuilder = GlyphAtlas(kind: .grayscale, initialSize: 2048)
        _ = try #require(block(rebuilder, 2048, 1500, 1))
        _ = rebuilder.takePendingRegion()
        _ = try #require(block(rebuilder, 2048, 1000, 1))
        #expect(rebuilder.rebuildCount == 1)
        #expect(rebuilder.takePendingRegion() == AtlasRegion(x: 0, y: 0, width: 2048, height: 2048))
        // The rebuild cleared the old pixels; only the new glyph is left.
        #expect(rebuilder.stagedPixel(x: 0, y: 1500) == [0])
        #expect(rebuilder.stagedPixel(x: 0, y: 999) == [1])
    }

    @Test("region union covers both rectangles")
    func regionUnion() {
        let a = AtlasRegion(x: 4, y: 10, width: 6, height: 2)
        let b = AtlasRegion(x: 0, y: 3, width: 2, height: 2)
        #expect(a.union(b) == AtlasRegion(x: 0, y: 3, width: 10, height: 9))
        #expect(b.union(a) == a.union(b))
        #expect(a.union(a) == a)
    }
}
