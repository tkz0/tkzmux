import CoreGraphics
import Foundation
import Testing
import TkzRenderCore
@testable import TkzTerminalRender

@Suite("BoxSprites")
struct BoxSpritesTests {

    private let metrics = CellMetrics(fontSet: FontSet(pointSize: 12.5, scale: 2))
    private var sprites: BoxSprites { BoxSprites(metrics: metrics, padding: 1) }

    /// Alpha of the cell pixel at `(x, y)` — cell coordinates, y down, padding stripped.
    private func alpha(_ glyph: RasterizedGlyph, _ x: Int, _ y: Int) -> UInt8 {
        let padding = 1
        return glyph.pixels[(y + padding) * glyph.bytesPerRow + x + padding]
    }

    private func sprite(_ scalar: Unicode.Scalar) -> RasterizedGlyph {
        guard let glyph = sprites.rasterize(scalar) else {
            Issue.record("no sprite for U+\(String(scalar.value, radix: 16))")
            return RasterizedGlyph(width: 0, height: 0, bytesPerRow: 0, bytesPerPixel: 1,
                                   bearingX: 0, bearingTop: 0, isColor: false,
                                   appliedScale: 1, pixels: [])
        }
        return glyph
    }

    // MARK: - Coverage

    @Test("the two synthesized ranges are claimed, and nothing else")
    func coverage() {
        #expect(BoxSprites.covers("─" as Unicode.Scalar))
        #expect(BoxSprites.covers("█" as Unicode.Scalar))
        #expect(BoxSprites.covers("▟" as Unicode.Scalar))
        #expect(!BoxSprites.covers("A" as Unicode.Scalar))
        #expect(!BoxSprites.covers("⠿" as Unicode.Scalar))  // braille is still the font's job
        // Only single-scalar clusters: an emoji ZWJ sequence must not be mistaken for a sprite.
        #expect(!BoxSprites.covers(["█", "\u{FE0F}"] as [Unicode.Scalar]))
    }

    @Test("every codepoint in U+2500…U+259F draws something")
    func everyCodepointHasInk() {
        for value in 0x2500...0x259F {
            let scalar = Unicode.Scalar(UInt32(value))!
            guard let glyph = sprites.rasterize(scalar) else {
                Issue.record("no sprite for U+\(String(value, radix: 16))")
                continue
            }
            #expect(glyph.pixels.contains { $0 > 0 },
                    "U+\(String(value, radix: 16)) rasterized empty")
        }
    }

    // MARK: - Cell geometry

    @Test("sprites are exactly one cell plus padding, unscaled")
    func cellExact() {
        let glyph = sprite("█")
        #expect(glyph.width == metrics.width + 2)
        #expect(glyph.height == metrics.height + 2)
        #expect(glyph.appliedScale == 1)
        #expect(glyph.bearingX == -1)
        #expect(glyph.bearingTop == metrics.baseline + 1)
        #expect(!glyph.isColor)
    }

    @Test("the full block covers the whole cell and nothing outside it")
    func fullBlock() {
        let glyph = sprite("█")
        for y in 0..<metrics.height {
            for x in 0..<metrics.width {
                #expect(alpha(glyph, x, y) == 255, "hole at (\(x), \(y))")
            }
        }
        // The padding ring stays transparent, so neighbouring cells cannot be overpainted.
        for x in 0..<glyph.width {
            #expect(glyph.pixels[x] == 0)
            #expect(glyph.pixels[(glyph.height - 1) * glyph.bytesPerRow + x] == 0)
        }
    }

    // MARK: - Tiling

    /// The whole point of the file: pairs that make up a cell must not leave a seam or overlap.
    @Test("half blocks tile into a full block")
    func halvesTile() {
        let left = sprite("▌"), right = sprite("▐")
        for x in 0..<metrics.width {
            let covered = (alpha(left, x, 0) == 255 ? 1 : 0) + (alpha(right, x, 0) == 255 ? 1 : 0)
            #expect(covered == 1, "column \(x) covered \(covered) times")
        }
        let upper = sprite("▀"), lower = sprite("▄")
        for y in 0..<metrics.height {
            let covered = (alpha(upper, 0, y) == 255 ? 1 : 0) + (alpha(lower, 0, y) == 255 ? 1 : 0)
            #expect(covered == 1, "row \(y) covered \(covered) times")
        }
    }

    @Test("the four quadrants tile into a full block")
    func quadrantsTile() {
        let quads = [sprite("▘"), sprite("▝"), sprite("▖"), sprite("▗")]
        for y in 0..<metrics.height {
            for x in 0..<metrics.width {
                let covered = quads.filter { alpha($0, x, y) == 255 }.count
                #expect(covered == 1, "(\(x), \(y)) covered \(covered) times")
            }
        }
    }

    @Test("the eighth blocks are a monotonic ramp that ends at the full block")
    func eighthRamp() {
        var previous = -1
        for value in 0x2581...0x2588 {  // ▁ … █
            let glyph = sprite(Unicode.Scalar(UInt32(value))!)
            let filled = (0..<metrics.height).filter { alpha(glyph, 0, $0) == 255 }.count
            #expect(filled > previous, "U+\(String(value, radix: 16)) did not grow")
            previous = filled
        }
        #expect(previous == metrics.height)
    }

    // MARK: - Box drawing

    @Test("a horizontal line runs edge to edge so neighbours join up")
    func horizontalLineSpansTheCell() {
        let glyph = sprite("─")
        let row = (0..<metrics.height).first { alpha(glyph, 0, $0) > 0 }
        #expect(row != nil)
        guard let row else { return }
        for x in 0..<metrics.width {
            #expect(alpha(glyph, x, row) == 255, "gap at column \(x)")
        }
    }

    @Test("a corner reaches both of its own edges and neither of the others")
    func cornerArms() {
        let glyph = sprite("┌")  // down and right
        let midY = metrics.height / 2
        let midX = metrics.width / 2
        #expect(alpha(glyph, metrics.width - 1, midY) == 255)   // right arm reaches the edge
        #expect(alpha(glyph, midX, metrics.height - 1) == 255)  // down arm reaches the edge
        #expect(alpha(glyph, 0, midY) == 0)                     // nothing to the left
        #expect(alpha(glyph, midX, 0) == 0)                     // nothing above
    }

    @Test("a cross is thin everywhere — the junction grows no nub")
    func crossHasNoNub() {
        let glyph = sprite("┼")
        let midY = metrics.height / 2
        // The widest run of ink on any row must be the full width (the horizontal arm), and every
        // other row must be no wider than the vertical arm.
        let vertical = (0..<metrics.width).filter { alpha(glyph, $0, 0) > 0 }.count
        #expect(vertical > 0)
        for y in 0..<metrics.height where y < midY - 2 || y > midY + 2 {
            let run = (0..<metrics.width).filter { alpha(glyph, $0, y) > 0 }.count
            #expect(run <= vertical, "row \(y) is \(run) px wide, arm is \(vertical)")
        }
    }

    // MARK: - Shared geometry (WOR-311 S5)

    /// The pinned cell sizes: 25 px (12.5 pt at 2x, 15x33), 28 px (14 pt at 2x, 17x37) and
    /// 22.4 px (14 pt at 1.6x, 14x30).
    static let sizes: [(pointSize: CGFloat, scale: CGFloat)] = [(12.5, 2), (14, 2), (14, 1.6)]

    private static let allScalars: [Unicode.Scalar] = (0x2500...0x259F).map { Unicode.Scalar(UInt32($0))! }

    @Test("every sprite at every pinned size is byte-identical to the pre-split drawing code")
    func unchangedByTheGeometrySplit() throws {
        let cells = Self.sizes.map { CellMetrics(fontSet: FontSet(pointSize: $0.pointSize, scale: $0.scale)) }
        #expect(cells.map { [$0.width, $0.height] } == [[15, 33], [17, 37], [14, 30]])
        for metrics in cells {
            for padding in [1, 2] {
                let now = BoxSprites(metrics: metrics, padding: padding)
                let before = LegacyBoxSprites(metrics: metrics, padding: padding)
                for scalar in Self.allScalars {
                    let a = try #require(now.rasterize(scalar)), b = try #require(before.rasterize(scalar))
                    #expect(a == b, "U+\(String(scalar.value, radix: 16)) at \(metrics.width)x\(metrics.height)")
                }
            }
        }
    }

    @Test("CoreGraphics and the pure-Swift rasterizer agree: rect sprites exactly, strokes within the glyph threshold")
    func coreGraphicsAgreesWithPureSwift() throws {
        for size in Self.sizes {
            let metrics = CellMetrics(fontSet: FontSet(pointSize: size.pointSize, scale: size.scale))
            let mac = BoxSprites(metrics: metrics, padding: 2)
            let linux = BoxSpriteRasterizer(metrics: metrics, padding: 2)
            for scalar in Self.allScalars {
                let name = "U+\(String(scalar.value, radix: 16)) at \(metrics.width)x\(metrics.height)"
                let a = try #require(mac.rasterize(scalar)), b = try #require(linux.rasterize(scalar))
                guard BoxSpriteGeometry.isAntialiased(scalar) else {
                    #expect(a == b, "\(name)")
                    continue
                }
                #expect(a.width == b.width && a.height == b.height && a.bytesPerRow == b.bytesPerRow)
                #expect(a.bearingX == b.bearingX && a.bearingTop == b.bearingTop && a.appliedScale == b.appliedScale)
                // WOR-299 / ADR-0003 L4: SSIM ≥ 0.90 and every ink-box edge within 1 px.
                let similarity = A8Similarity.ssim(a.pixels, b.pixels, width: a.width, height: a.height)
                #expect(similarity >= 0.90, "\(name): SSIM \(similarity)")
                let boxA = try #require(A8Similarity.inkBox(a.pixels, width: a.width))
                let boxB = try #require(A8Similarity.inkBox(b.pixels, width: b.width))
                #expect(abs(boxA.minX - boxB.minX) <= 1 && abs(boxA.maxX - boxB.maxX) <= 1, "\(name): \(boxA) vs \(boxB)")
                #expect(abs(boxA.minY - boxB.minY) <= 1 && abs(boxA.maxY - boxB.maxY) <= 1, "\(name): \(boxA) vs \(boxB)")
            }
        }
    }

    // MARK: - Cache integration

    @Test("the cache draws sprites instead of shaping them, once for every style")
    func cacheUsesSprites() {
        let source = CoreTextGlyphSource(fontSet: FontSet(pointSize: 12.5, scale: 2))
        let cache = GlyphCache(source: source)
        let regular = cache.glyph(for: "█", style: .regular)
        let bold = cache.glyph(for: "█", style: .bold)
        #expect(regular != nil)
        #expect(regular == bold)  // one sprite, shared by every style
        #expect(cache.cachedCount == 1)
        #expect(regular?.cellSpan == 1)
        #expect(regular?.slot.width == cache.metrics.width + 2 * source.rasterizer.padding)
        // The shaper was never asked for it.
        #expect(source.shaper.cachedCount == 0)
    }
}

/// The ADR-0003 glyph comparison for A8 bitmaps: SSIM after Wang et al. 2004 (11x11 Gaussian
/// window, σ = 1.5, K1 = 0.01, K2 = 0.03, L = 255, a window centred on every pixel and cut at
/// the bitmap edge) and the ink box.
enum A8Similarity {
    static func ssim(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> Double {
        let radius = 5, sigma = 1.5
        let kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let c1 = (0.01 * 255) * (0.01 * 255), c2 = (0.03 * 255) * (0.03 * 255)
        var total = 0.0
        for cy in 0..<height {
            for cx in 0..<width {
                var weight = 0.0, meanA = 0.0, meanB = 0.0, aa = 0.0, bb = 0.0, ab = 0.0
                for dy in -radius...radius where (0..<height).contains(cy + dy) {
                    for dx in -radius...radius where (0..<width).contains(cx + dx) {
                        let w = kernel[dy + radius] * kernel[dx + radius]
                        let i = (cy + dy) * width + cx + dx
                        let va = Double(a[i]), vb = Double(b[i])
                        weight += w
                        meanA += w * va
                        meanB += w * vb
                        aa += w * va * va
                        bb += w * vb * vb
                        ab += w * va * vb
                    }
                }
                meanA /= weight
                meanB /= weight
                let varianceA = aa / weight - meanA * meanA
                let varianceB = bb / weight - meanB * meanB
                let covariance = ab / weight - meanA * meanB
                total += ((2 * meanA * meanB + c1) * (2 * covariance + c2))
                    / ((meanA * meanA + meanB * meanB + c1) * (varianceA + varianceB + c2))
            }
        }
        return total / Double(width * height)
    }

    /// The smallest box holding every inked pixel, edges inclusive; `nil` for an empty bitmap.
    static func inkBox(_ pixels: [UInt8], width: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for (i, value) in pixels.enumerated() where value > 0 {
            let x = i % width, y = i / width
            if let b = box {
                box = (min(b.minX, x), min(b.minY, y), max(b.maxX, x), max(b.maxY, y))
            } else {
                box = (x, y, x, y)
            }
        }
        return box
    }
}
