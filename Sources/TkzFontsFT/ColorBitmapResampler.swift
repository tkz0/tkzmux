// ColorBitmapResampler — scales a premultiplied BGRA bitmap into a glyph bitmap with an exact
// area average (WOR-312 S5).
//
// Colour emoji come as fixed bitmap strikes (Noto Color Emoji's CBDT strike is 109 ppem), drawn at
// a terminal size of 20-40 px, so nearly every colour glyph is a large downscale by a fractional
// factor, to a fractional position. Each destination pixel takes the area-weighted sum of the
// source pixels its square overlaps, separably per axis: a box filter with exact coverage, so a
// flat colour stays exactly flat and the glyph's total ink is preserved. The arithmetic runs on
// premultiplied values, which is what keeps edges free of fringes: a transparent source pixel
// contributes nothing to any channel, not a dark colour weighted by zero alpha's leftover.
//
// The result is composited source-over into the destination, so the glyphs of a multi-glyph colour
// cluster stack like the Mac's CGContext draws them.
//
// Pure Swift on plain arrays; no FreeType, so the tests drive it directly.

import Foundation

enum ColorBitmapResampler {
    /// Overlap weights of the destination pixels with the source pixels along one axis.
    struct Weights {
        /// For destination pixel `i`: the first source index and the weight of each source pixel.
        var first: [Int]
        var weights: [[Double]]
    }

    /// Source pixel `u` covers `[origin + u * scale, origin + (u + 1) * scale)` in destination
    /// pixels; destination pixel `i` covers `[i, i + 1)`. Weight = length of the overlap.
    static func weights(sourceCount: Int, destinationCount: Int, origin: Double, scale: Double) -> Weights {
        var first = [Int](repeating: 0, count: destinationCount)
        var weights = [[Double]](repeating: [], count: destinationCount)
        guard sourceCount > 0, scale > 0 else { return Weights(first: first, weights: weights) }
        for i in 0..<destinationCount {
            let lo = Double(i), hi = Double(i + 1)
            // Source pixels whose span can intersect [lo, hi).
            let start = max(0, Int(((lo - origin) / scale).rounded(.down)))
            let end = min(sourceCount - 1, Int(((hi - origin) / scale).rounded(.down)))
            guard start <= end else { continue }
            first[i] = start
            var row: [Double] = []
            row.reserveCapacity(end - start + 1)
            for u in start...end {
                let a = origin + Double(u) * scale
                let b = a + scale
                row.append(max(0, min(hi, b) - max(lo, a)))
            }
            weights[i] = row
        }
        return Weights(first: first, weights: weights)
    }

    /// Draws `source` (premultiplied BGRA, `sourceWidth`×`sourceHeight`, rows top-down) into
    /// `destination` (premultiplied BGRA, rows top-down), source-over. The source's top-left corner
    /// lands at (`originX`, `originY`) destination pixels from the destination's top-left, and each
    /// source pixel becomes `scale` destination pixels wide and tall.
    static func draw(source: UnsafeBufferPointer<UInt8>,
                     sourceWidth: Int,
                     sourceHeight: Int,
                     sourceBytesPerRow: Int,
                     into destination: inout [UInt8],
                     destinationWidth: Int,
                     destinationHeight: Int,
                     originX: Double,
                     originY: Double,
                     scale: Double) {
        guard sourceWidth > 0, sourceHeight > 0, destinationWidth > 0, destinationHeight > 0, scale > 0 else { return }
        let columns = weights(sourceCount: sourceWidth, destinationCount: destinationWidth, origin: originX, scale: scale)
        let rows = weights(sourceCount: sourceHeight, destinationCount: destinationHeight, origin: originY, scale: scale)

        // Horizontal pass into a Double buffer (sourceHeight × destinationWidth × 4), then vertical.
        var horizontal = [Double](repeating: 0, count: sourceHeight * destinationWidth * 4)
        for v in 0..<sourceHeight {
            let sourceRow = v * sourceBytesPerRow
            let outRow = v * destinationWidth * 4
            for i in 0..<destinationWidth {
                let row = columns.weights[i]
                guard !row.isEmpty else { continue }
                var b = 0.0, g = 0.0, r = 0.0, a = 0.0
                var u = columns.first[i]
                for weight in row {
                    let p = sourceRow + u * 4
                    b += weight * Double(source[p])
                    g += weight * Double(source[p + 1])
                    r += weight * Double(source[p + 2])
                    a += weight * Double(source[p + 3])
                    u += 1
                }
                let o = outRow + i * 4
                horizontal[o] = b
                horizontal[o + 1] = g
                horizontal[o + 2] = r
                horizontal[o + 3] = a
            }
        }

        for j in 0..<destinationHeight {
            let row = rows.weights[j]
            guard !row.isEmpty else { continue }
            for i in 0..<destinationWidth {
                var sum = (0.0, 0.0, 0.0, 0.0)
                var v = rows.first[j]
                for weight in row {
                    let o = (v * destinationWidth + i) * 4
                    sum.0 += weight * horizontal[o]
                    sum.1 += weight * horizontal[o + 1]
                    sum.2 += weight * horizontal[o + 2]
                    sum.3 += weight * horizontal[o + 3]
                    v += 1
                }
                // Rounding is monotonic, so a premultiplied channel never ends up above alpha.
                let alpha = channel(sum.3)
                guard alpha > 0 else { continue }
                let d = (j * destinationWidth + i) * 4
                let keep = Double(255 - Int(alpha)) / 255
                destination[d] = over(channel(sum.0), destination[d], keep)
                destination[d + 1] = over(channel(sum.1), destination[d + 1], keep)
                destination[d + 2] = over(channel(sum.2), destination[d + 2], keep)
                destination[d + 3] = over(alpha, destination[d + 3], keep)
            }
        }
    }

    private static func channel(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, value.rounded())))
    }

    /// Premultiplied source-over: `src + dst * (1 - srcAlpha)`.
    private static func over(_ source: UInt8, _ destination: UInt8, _ keep: Double) -> UInt8 {
        guard destination > 0 else { return source }
        return UInt8(min(255, (Double(source) + Double(destination) * keep).rounded()))
    }
}
