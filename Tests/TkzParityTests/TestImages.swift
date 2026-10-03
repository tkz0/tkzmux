// Synthetic images for the toolkit's tests: solid fills, a glyph line drawn with area coverage, and
// an independent, slow SSIM to check the fast one against.

import Foundation
@testable import TkzParity

enum TestImages {
    /// The repository root, from this file.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // Tests/TkzParityTests/TestImages.swift
            .deletingLastPathComponent()  // Tests/TkzParityTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // <repo>
    }

    /// An opaque image from a per-pixel (r, g, b).
    static func image(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> ParityImage {
        var bgra = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let base = (y * width + x) * 4
                bgra[base] = b
                bgra[base + 1] = g
                bgra[base + 2] = r
            }
        }
        return ParityImage(width: width, height: height, premultipliedBGRA: bgra)
    }

    static func solid(width: Int, height: Int, grey: UInt8) -> ParityImage {
        image(width: width, height: height) { _, _ in (grey, grey, grey) }
    }

    /// A seeded pseudo-random image (xorshift), so a failure reproduces.
    static func noise(width: Int, height: Int, seed: UInt64) -> ParityImage {
        var state = seed | 1
        func next() -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        return image(width: width, height: height) { _, _ in (next(), next(), next()) }
    }

    /// Three terminal-like glyphs ("H", "I", "L" from stems and bars with fractional edges, light on
    /// dark, antialiased by area coverage) in 17×37 px cells, shifted right by `shift` pixels.
    static func glyphLine(shift: Double = 0) -> ParityImage {
        // Rects in cell coordinates (x0, y0, x1, y1), as a 14 pt mono face at 2.0 might draw them.
        let glyphs: [[(Double, Double, Double, Double)]] = [
            [(3.3, 8, 5.7, 29), (11.3, 8, 13.7, 29), (5.7, 17.4, 11.3, 19.6)],  // H
            [(7.3, 8, 9.7, 29), (4.2, 8, 12.8, 10.2), (4.2, 26.8, 12.8, 29)],   // I
            [(4.3, 8, 6.7, 29), (6.7, 26.8, 13.6, 29)],                         // L
        ]
        let cellWidth = 17.0
        var rects: [(Double, Double, Double, Double)] = []
        for (index, glyph) in glyphs.enumerated() {
            let dx = Double(index) * cellWidth + shift
            rects += glyph.map { ($0.0 + dx, $0.1, $0.2 + dx, $0.3) }
        }
        return image(width: 51, height: 37) { x, y in
            var coverage = 0.0
            for rect in rects {
                let w = max(0, min(Double(x + 1), rect.2) - max(Double(x), rect.0))
                let h = max(0, min(Double(y + 1), rect.3) - max(Double(y), rect.1))
                coverage = max(coverage, w * h)
            }
            let value = UInt8((30 + coverage * (230 - 30)).rounded())
            return (value, value, value)
        }
    }

    /// SSIM straight from the definition: for each unmasked centre, the weighted moments over its
    /// 11×11 window's unmasked, in-image pixels, with weights from `exp`. Slow, independent of the
    /// separable ring in `SSIM`.
    static func referenceSSIM(_ a: ParityImage, _ b: ParityImage, mask: MaskBitmap) -> [Double?] {
        let la = a.luma(), lb = b.luma()
        let c1 = (0.01 * 255.0) * (0.01 * 255.0), c2 = (0.03 * 255.0) * (0.03 * 255.0)
        var out: [Double?] = []
        for y in 0..<a.height {
            for x in 0..<a.width {
                guard !mask.isMasked(y * a.width + x) else { out.append(nil); continue }
                var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
                for j in -5...5 {
                    for i in -5...5 {
                        let px = x + i, py = y + j
                        guard px >= 0, px < a.width, py >= 0, py < a.height,
                              !mask.isMasked(py * a.width + px) else { continue }
                        let weight = exp(-Double(i * i) / 4.5) * exp(-Double(j * j) / 4.5)
                        let va = la[py * a.width + px], vb = lb[py * a.width + px]
                        sw += weight; sx += weight * va; sy += weight * vb
                        sxx += weight * va * va; syy += weight * vb * vb; sxy += weight * va * vb
                    }
                }
                let mx = sx / sw, my = sy / sw
                let vx = sxx / sw - mx * mx, vy = syy / sw - my * my, cov = sxy / sw - mx * my
                out.append(((2 * mx * my + c1) * (2 * cov + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2)))
            }
        }
        return out
    }
}
