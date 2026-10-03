// ColorBitmapResamplerTests — the premultiplied area-average downscale colour emoji go through
// (WOR-312 S5): a flat colour stays flat, edges get no fringe, ink is conserved.

import Testing
@testable import TkzFontsFT

@Suite("Colour bitmap resampler")
struct ColorBitmapResamplerTests {
    /// A `width`×`height` premultiplied BGRA image of one colour.
    func solid(_ width: Int, _ height: Int, bgra: [UInt8]) -> [UInt8] {
        (0..<(width * height)).flatMap { _ in bgra }
    }

    func draw(_ source: [UInt8], _ sw: Int, _ sh: Int, into dw: Int, _ dh: Int,
              x: Double, y: Double, scale: Double, over existing: [UInt8]? = nil) -> [UInt8] {
        var destination = existing ?? [UInt8](repeating: 0, count: dw * dh * 4)
        source.withUnsafeBufferPointer {
            ColorBitmapResampler.draw(source: $0, sourceWidth: sw, sourceHeight: sh, sourceBytesPerRow: sw * 4,
                                      into: &destination, destinationWidth: dw, destinationHeight: dh,
                                      originX: x, originY: y, scale: scale)
        }
        return destination
    }

    func pixel(_ image: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> [UInt8] {
        Array(image[((y * width + x) * 4)..<((y * width + x) * 4 + 4)])
    }

    @Test("a constant colour stays exactly constant wherever the source covers a whole pixel",
          arguments: [[0, 0, 255, 255], [16, 32, 64, 128], [200, 100, 50, 255]] as [[UInt8]])
    func constantStaysConstant(bgra: [UInt8]) {
        // Noto Color Emoji's 136×128 strike glyph at 28 px: 28/109 per strike pixel, at a
        // fractional offset.
        let scale = 28.0 / 109
        let out = draw(solid(136, 128, bgra: bgra), 136, 128, into: 40, 40, x: 0.37, y: 0.81, scale: scale)
        let right = 0.37 + 136 * scale, bottom = 0.81 + 128 * scale
        var inside = 0
        for y in 1..<Int(bottom.rounded(.down)) {
            for x in 1..<Int(right.rounded(.down)) {
                #expect(pixel(out, 40, x, y) == bgra, "(\(x), \(y))")
                inside += 1
            }
        }
        #expect(inside > 900)
        // Outside the footprint nothing is drawn.
        #expect(pixel(out, 40, 39, 39) == [0, 0, 0, 0])
    }

    @Test("no fringe: partly covered edge pixels keep the colour, only alpha drops")
    func noFringe() {
        // Opaque orange next to fully transparent pixels, at a fractional scale and offset.
        let orange: [UInt8] = [0, 128, 255, 255]
        var source = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for y in 16..<48 { for x in 16..<48 { source.replaceSubrange(((y * 64 + x) * 4)..<((y * 64 + x) * 4 + 4), with: orange) } }
        let out = draw(source, 64, 64, into: 30, 30, x: 0.3, y: 0.6, scale: 0.41)
        var edges = 0
        for y in 0..<30 {
            for x in 0..<30 {
                let p = pixel(out, 30, x, y)
                let a = Int(p[3])
                guard a > 0 else { #expect(p == [0, 0, 0, 0]); continue }
                // Unpremultiplied, the colour is orange to within rounding.
                let r = Double(p[2]) * 255 / Double(a), g = Double(p[1]) * 255 / Double(a), b = Double(p[0]) * 255 / Double(a)
                let tolerance = 255.0 / Double(a) // one premultiplied step
                #expect(abs(r - 255) <= tolerance && abs(g - 128) <= tolerance + 0.5 && b <= tolerance, "(\(x), \(y)) \(p)")
                if a < 255 { edges += 1 }
            }
        }
        #expect(edges > 10)
    }

    @Test("ink is conserved: Σ alpha scales with the area")
    func conservesInk() {
        let source = solid(50, 30, bgra: [255, 255, 255, 255])
        let scale = 0.3
        let out = draw(source, 50, 30, into: 20, 12, x: 0.45, y: 0.2, scale: scale)
        let alpha = stride(from: 3, to: out.count, by: 4).reduce(0.0) { $0 + Double(out[$1]) } / 255
        let expected = 50 * 30 * scale * scale
        #expect(abs(alpha - expected) < 0.5, "Σα \(alpha), expected \(expected)")
    }

    @Test("scale 1 at an integer offset copies the source")
    func identity() {
        var source = [UInt8](repeating: 0, count: 5 * 4 * 4)
        for i in 0..<20 { let v = UInt8(i * 12); source.replaceSubrange((i * 4)..<(i * 4 + 4), with: [v / 2, v / 3, v / 4, v]) }
        let out = draw(source, 5, 4, into: 7, 6, x: 1, y: 2, scale: 1)
        for y in 0..<4 {
            for x in 0..<5 {
                #expect(pixel(out, 7, x + 1, y + 2) == pixel(source, 5, x, y))
            }
        }
    }

    @Test("drawing composites source-over")
    func sourceOver() {
        let existing = solid(4, 4, bgra: [0, 0, 200, 200])
        let opaque = draw(solid(4, 4, bgra: [10, 20, 30, 255]), 4, 4, into: 4, 4, x: 0, y: 0, scale: 1, over: existing)
        #expect(pixel(opaque, 4, 2, 2) == [10, 20, 30, 255])
        let half = draw(solid(4, 4, bgra: [0, 128, 0, 128]), 4, 4, into: 4, 4, x: 0, y: 0, scale: 1, over: existing)
        // 128 + 200·(127/255) = 227.6, and R: 0 + 200·127/255 = 99.6.
        #expect(pixel(half, 4, 1, 1) == [0, 128, 100, 228])
    }
}
