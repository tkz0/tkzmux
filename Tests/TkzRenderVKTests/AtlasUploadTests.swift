// AtlasUploadTests — glyph atlases into Vulkan images through a FrameRing slot (WOR-313 S4a).
//
// The content comes from the WOR-312 glyph cache (FreeType and HarfBuzz over the bundled fonts),
// plus synthetic blocks where a test needs the atlases to grow and rebuild quickly. After every
// submitted upload, the image read back from the GPU must equal the atlas's staging bytes exactly.
// Needs a Vulkan driver, like every test in this target.

import CVulkan
import Foundation
import Testing
import TkzFontsFT
import TkzRenderCore
@testable import TkzRenderVK

private enum TestFonts {
    static let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tkzmux-tests-fontconfig-\(getuid())", isDirectory: true)

    static func source() throws -> FreeTypeGlyphSource {
        let fallback = FontFallback(configuration: .system(bundled: BundledFonts.fontDirectories, cacheDirectory: cacheDirectory))
        return FreeTypeGlyphSource(faces: try TerminalFaces(pointSize: 14, scale: 2, fallback: fallback))
    }
}

/// The GPU copy of `kind` against the atlas's staging bytes, compared with memcmp (a 16 MiB
/// element-wise `==` is slow in a debug build).
private func matches(_ uploader: VulkanAtlasUploader, _ atlas: GlyphAtlas) throws -> Bool {
    guard let gpu = try uploader.readback(atlas.kind), gpu.count == atlas.staging.count else { return false }
    return gpu.withUnsafeBytes { gpu in
        atlas.staging.withUnsafeBytes { staged in
            guard let gpu = gpu.baseAddress, let staged = staged.baseAddress else { return false }
            return memcmp(gpu, staged, atlas.staging.count) == 0
        }
    }
}

/// A deterministic block of `width × height` pixels for `kind`, every byte nonzero.
private func block(_ kind: AtlasKind, width: Int, height: Int, seed: Int) -> [UInt8] {
    (0..<(width * height * kind.bytesPerPixel)).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ seed &* 97) % 255 + 1) }
}

/// A small linear congruential generator, so the stress run is the same on every machine.
private struct Generator {
    var state: UInt64
    mutating func next(_ range: ClosedRange<Int>) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return range.lowerBound + Int((state >> 33) % UInt64(range.count))
    }
}

@Suite("Vulkan atlas uploads", .serialized, .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
struct AtlasUploadTests {

    @Test("images match the cache's sizes in UNORM formats, and nothing is readable before an upload")
    func construction() throws {
        let device = try VulkanTestDevice.make()
        let cache = GlyphCache(source: try TestFonts.source())
        let uploader = try VulkanAtlasUploader(device: device, cache: cache)
        #expect(uploader.size(of: .grayscale) == 2048)
        #expect(uploader.size(of: .color) == 1024)
        #expect(AtlasKind.grayscale.vulkanFormat == VK_FORMAT_R8_UNORM)
        #expect(AtlasKind.color.vulkanFormat == VK_FORMAT_B8G8R8A8_UNORM)
        #expect(try uploader.readback(.grayscale) == nil)
        #expect(uploader.stats == AtlasUploadStats(copies: 0, bytesUploaded: 0, imagesCreated: 2, imagesReplaced: 0))
        VulkanTestDevice.expectNoValidationErrors(device)
    }

    @Test("real glyphs: the first upload clears the images and copies the dirty box; an idle frame records nothing")
    func uploadsTheDirtyBox() throws {
        let device = try VulkanTestDevice.make()
        let cache = GlyphCache(source: try TestFonts.source(), grayscaleInitialSize: 256, colorInitialSize: 64)
        for scalar in ["A", "g", "@", "─", "╭"] as [Unicode.Scalar] {
            #expect(cache.glyph(forScalar: scalar, cellSpan: 1) != nil)
        }
        let box = try #require(cache.grayscale.pendingRegion)
        let uploader = try VulkanAtlasUploader(device: device, cache: cache)
        let ring = try FrameRing(device: device)

        let first = try ring.acquire()
        try uploader.upload(cache, into: first)
        #expect(uploader.stats.copies == 1, "the colour atlas has nothing pending: cleared, not copied")
        #expect(uploader.stats.bytesUploaded == box.width * box.height)
        #expect(!cache.grayscale.hasPendingUpload)
        #expect(first.capacity(of: .staging) == (box.width * box.height + 15) & ~15)
        #expect(first.mustSubmit, "the atlas has forgotten its box: this frame cannot bail out")
        try ring.submit(first)
        #expect(!first.mustSubmit)
        try ring.waitUntilCompleted(first)
        #expect(try matches(uploader, cache.grayscale))
        #expect(try matches(uploader, cache.color), "a cleared image reads back as zeros")

        // Nothing staged since: the upload records nothing and touches no buffer.
        let idle = try ring.acquire()
        try uploader.upload(cache, into: idle)
        #expect(!idle.isRecording && !idle.mustSubmit)
        #expect(idle.capacity(of: .staging) == nil)
        #expect(uploader.stats.copies == 1)
        try ring.submit(idle)

        // One more glyph: just its box, into the image as it is.
        #expect(cache.glyph(forScalar: "Q", style: .bold, cellSpan: 1) != nil)
        let second = try #require(cache.grayscale.pendingRegion)
        #expect(second.width * second.height < box.width * box.height)
        let third = try ring.acquire()
        try uploader.upload(cache, into: third)
        #expect(uploader.stats.copies == 2)
        #expect(uploader.stats.bytesUploaded == box.width * box.height + second.width * second.height)
        try ring.submit(third)
        try ring.waitUntilCompleted(third)
        #expect(try matches(uploader, cache.grayscale))

        // A colour glyph, where the machine has a colour emoji font.
        if let emoji = cache.glyph(for: "😀", cellSpan: 2), emoji.isColor {
            let slot = try ring.acquire()
            try uploader.upload(cache, into: slot)
            try ring.submit(slot)
            try ring.waitUntilCompleted(slot)
            #expect(try matches(uploader, cache.color))
        }
        #expect(uploader.stats.imagesReplaced == 0)
        VulkanTestDevice.expectNoValidationErrors(device)
    }

    @Test("a grown atlas gets a new image; the old one lives until the fence of the slot that replaced it")
    func growDefersDestruction() throws {
        let device = try VulkanTestDevice.make()
        let cache = GlyphCache(source: try TestFonts.source(), grayscaleInitialSize: 64, colorInitialSize: 32)
        let uploader = try VulkanAtlasUploader(device: device, cache: cache)
        let ring = try FrameRing(device: device)
        try ring.submit(try ring.acquire().also { try uploader.upload(cache, into: $0) })

        weak let outgrown = uploader.image(for: .grayscale)
        #expect(cache.grayscale.insert(pixels: block(.grayscale, width: 100, height: 40, seed: 1), width: 100, height: 40,
                                       bytesPerRow: 100) != nil)
        #expect(cache.grayscale.size == 128)
        let growing = try ring.acquire()
        try uploader.upload(cache, into: growing)
        #expect(uploader.size(of: .grayscale) == 128)
        #expect(uploader.stats.imagesReplaced == 1)
        #expect(uploader.imageGeneration == 1)
        #expect(outgrown != nil && growing.heldRetirements == 1)
        try ring.submit(growing)

        // The other slots come and go; the old image stays until `growing` is acquired again.
        try ring.submit(try ring.acquire())
        try ring.submit(try ring.acquire())
        #expect(outgrown != nil)
        #expect(try ring.acquire() === growing)
        #expect(outgrown == nil)
        #expect(growing.heldRetirements == 0)
        try ring.submit(growing)
        try ring.waitUntilCompleted(growing)
        #expect(try matches(uploader, cache.grayscale))
        VulkanTestDevice.expectNoValidationErrors(device)
    }

    @Test("stress: both atlases grow to 2048² and rebuild across two surfaces' rings, with 0 validation errors")
    func growStress() throws {
        let device = try VulkanTestDevice.make()
        let cache = GlyphCache(source: try TestFonts.source(), grayscaleInitialSize: 64, colorInitialSize: 32)
        let uploader = try VulkanAtlasUploader(device: device, cache: cache)
        let rings = [try FrameRing(device: device), try FrameRing(device: device)]
        var random = Generator(state: 0x7C3A_91E5)
        let text = Array("The quick brown fox jumps over the lazy dog 0123456789 ─│╭╮╰╯█░".unicodeScalars)
        weak let firstGrayscale = uploader.image(for: .grayscale)
        weak let firstColor = uploader.image(for: .color)

        let frames = 64
        for frame in 0..<frames {
            let ring = rings[frame % rings.count]
            let slot = try ring.acquire()
            for _ in 0..<5 {
                let width = random.next(8...240), height = random.next(8...240)
                cache.grayscale.insert(pixels: block(.grayscale, width: width, height: height, seed: frame), width: width,
                                       height: height, bytesPerRow: width)
            }
            for _ in 0..<2 {
                let width = random.next(40...420), height = random.next(40...420)
                cache.color.insert(pixels: block(.color, width: width, height: height, seed: frame), width: width,
                                   height: height, bytesPerRow: width * 4)
            }
            _ = cache.glyph(forScalar: text[frame % text.count], style: FontStyle.allCases[frame % 4], cellSpan: 1)
            try uploader.upload(cache, into: slot)
            try ring.submit(slot)
            if frame % 16 == 15 || frame == frames - 1 {
                try ring.waitUntilCompleted(slot)
                #expect(try matches(uploader, cache.grayscale), "frame \(frame)")
                #expect(try matches(uploader, cache.color), "frame \(frame)")
            }
        }

        #expect(cache.grayscale.size == 2048 && cache.color.size == 2048)
        #expect(cache.grayscale.rebuildCount >= 1 && cache.color.rebuildCount >= 1,
                "grayscale \(cache.grayscale.rebuildCount), colour \(cache.color.rebuildCount) rebuilds")
        // 64 → 2048 is five grows, 32 → 2048 six; several grows in one frame make one replacement.
        #expect((2...11).contains(uploader.stats.imagesReplaced))
        #expect(uploader.stats.imagesReplaced <= cache.grayscale.growCount + cache.color.growCount)

        // One more round of every slot: each retired image's fence has signalled.
        for _ in 0..<FrameRing.depth { for ring in rings { try ring.submit(try ring.acquire()) } }
        #expect(firstGrayscale == nil && firstColor == nil)
        VulkanTestDevice.expectNoValidationErrors(device)
        #expect(!VulkanTestEnvironment.required || device.instance.validationEnabled, "CI runs this under validation")
    }
}

private extension FrameRing.Slot {
    /// Runs `body` on the slot and returns it, so a one-line frame reads acquire → record → submit.
    func also(_ body: (FrameRing.Slot) throws -> Void) rethrows -> FrameRing.Slot {
        try body(self)
        return self
    }
}
