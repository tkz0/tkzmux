// TkzPNG against ImageIO/CoreGraphics, on the Mac only (this target does not build on Linux).
//
// The golden comparison used to decode through ImageIO into a DeviceRGB premultiplied-BGRA
// CGContext; it now decodes through TkzPNG so the same check can run on Linux. These tests prove
// the swap changed nothing: the goldens decode to the same bytes both ways, and PNGs written by
// ImageIO (`vtdump atlas --png`, the app's `pngData` paths) are read back exactly.
//
// The one place the two could differ is colour management — the goldens carry an `sRGB` chunk, and
// drawing into a DeviceRGB context may convert. TkzPNG never converts. If the first test fails, the
// message gives the worst channel delta; record it in docs/linux/ rather than loosening the check.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import TkzPNG
import TkzRenderCore
@testable import TkzTerminalRender

/// The decode `TerminalRendererTests` used before TkzPNG: ImageIO, drawn into a DeviceRGB
/// premultiplied-first, little-endian (BGRA in memory) context.
private func decodeWithCoreGraphics(_ data: Data) throws -> (width: Int, height: Int, pixels: [UInt8]) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        struct UndecodablePNG: Error {}
        throw UndecodablePNG()
    }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { raw in
        guard let context = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (width, height, pixels)
}

private func fixtureURL(_ name: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
}

@Suite("TkzPNG parity with ImageIO")
struct TkzPNGParityTests {

    @Test("the goldens decode to the same premultiplied BGRA through TkzPNG and CoreGraphics",
          arguments: ["golden-bar-cursor.png", "golden-block-cursor.png"])
    func goldens(_ name: String) throws {
        let data = try Data(contentsOf: fixtureURL(name))
        let reference = try decodeWithCoreGraphics(data)
        let image = try PNG.decode([UInt8](data))
        #expect(image.width == reference.width && image.height == reference.height)
        let pixels = image.premultipliedBGRA()
        guard pixels != reference.pixels else { return }
        var worst = 0, differing = 0
        for index in pixels.indices where pixels[index] != reference.pixels[index] {
            differing += 1
            worst = max(worst, abs(Int(pixels[index]) - Int(reference.pixels[index])))
        }
        Issue.record("\(name): \(differing) channel bytes differ from the CoreGraphics decode, worst delta \(worst)")
    }

    @Test("an ImageIO-written greyscale atlas reads back as its staging bytes")
    func grayAtlas() throws {
        let cache = GlyphCache(fontSet: FontSet(pointSize: 12.5, scale: 2),
                               grayscaleInitialSize: 128, colorInitialSize: 128)
        for text in ["A", "g", "你", "─"] { _ = cache.glyph(for: Character(text)) }
        let atlas = cache.grayscale
        let png = try #require(atlas.pngData())
        let image = try PNG.decode([UInt8](png))
        #expect(image.width == atlas.size && image.height == atlas.size)
        var inked = 0
        for y in 0..<atlas.size {
            for x in 0..<atlas.size {
                let coverage = atlas.stagedPixel(x: x, y: y)[0]
                let offset = (y * atlas.size + x) * 4
                guard Array(image.pixels[offset..<(offset + 4)]) == [coverage, coverage, coverage, 255] else {
                    Issue.record("pixel (\(x), \(y)): \(image.pixels[offset..<(offset + 4)]) for coverage \(coverage)")
                    return
                }
                if coverage != 0 { inked += 1 }
            }
        }
        #expect(inked > 0)
    }

    /// The colour atlas is premultiplied BGRA; ImageIO un-premultiplies it to straight RGBA on the
    /// way out, and `premultipliedBGRA()` re-premultiplies. That round trip is exact when both
    /// directions round to nearest, and off by one where ImageIO truncates.
    @Test("an ImageIO-written colour atlas reads back as its staging bytes (±1 after un/premultiply)")
    func colorAtlas() throws {
        let cache = GlyphCache(fontSet: FontSet(pointSize: 12.5, scale: 2),
                               grayscaleInitialSize: 128, colorInitialSize: 128)
        _ = cache.glyph(for: "😀")
        let atlas = cache.color
        let png = try #require(atlas.pngData())
        let image = try PNG.decode([UInt8](png))
        #expect(image.width == atlas.size && image.height == atlas.size)
        let pixels = image.premultipliedBGRA()
        var worst = 0
        for y in 0..<atlas.size {
            for x in 0..<atlas.size {
                let staged = atlas.stagedPixel(x: x, y: y)
                let offset = (y * atlas.size + x) * 4
                for channel in 0..<4 {
                    worst = max(worst, abs(Int(pixels[offset + channel]) - Int(staged[channel])))
                }
            }
        }
        #expect(worst <= 1, "worst channel delta \(worst)")
    }

    @Test("TkzPNG output reads back through ImageIO unchanged")
    func imageIOReadsTkzPNG() throws {
        var pixels: [UInt8] = []
        for y in 0..<40 {
            for x in 0..<64 { pixels += [UInt8(x * 4), UInt8(y * 6), UInt8((x ^ y) & 0xFF), 255] }
        }
        let png = try PNG.encode(pixels, width: 64, height: 40)
        let reference = try decodeWithCoreGraphics(Data(png))
        #expect(reference.pixels == PNGImage(width: 64, height: 40, pixels: pixels).premultipliedBGRA())
    }
}
