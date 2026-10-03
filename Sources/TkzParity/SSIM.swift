// SSIM — structural similarity as ADR-0003 §3 defines it (WOR-322 S1).
//
// Wang, Bovik, Sheikh and Simoncelli 2004: an 11×11 Gaussian window with σ = 1.5, K1 = 0.01,
// K2 = 0.03 and L = 255, on the luma of the gamma-encoded bytes (`ParityImage.luma()`), with the
// population (not sample) moments. Every pixel is a window centre, and the global score is the
// mean over the centres that are not masked.
//
// Masked pixels have weight zero inside every window as well, so what is under a mask cannot reach
// the score through a neighbouring window: two images that differ only under the mask score
// exactly 1. The image border is handled the same way: a window that hangs over the edge uses the
// pixels it covers, with its weights renormalised, and no padding values are invented. Every
// moment is therefore a ratio of two filtered planes, `G ∗ (m·f) / G ∗ m`, and the filter is
// separable: one horizontal pass per row into an 11-row ring, then a vertical pass per pixel.
//
// Determinism: the Gaussian taps are literals (below) rather than `exp` calls, so the scores do
// not depend on the platform's libm, and the summation order is fixed. Identical images score
// exactly 1.0, not 0.99999…: the numerator and denominator are then computed from the same values.

public enum SSIM {
    public static let windowSize = 11
    public static let sigma = 1.5
    public static let k1 = 0.01
    public static let k2 = 0.03
    public static let dynamicRange = 255.0
    static let c1 = (k1 * dynamicRange) * (k1 * dynamicRange)
    static let c2 = (k2 * dynamicRange) * (k2 * dynamicRange)

    /// The per-tile size of the diagnostic tile scores (ADR-0003 §3).
    public static let tileSize = 64

    /// `exp(-k² / (2σ²))` for k = 0…5 at σ = 1.5, as `exp` gives them, to the last digit. Not
    /// normalised: every moment divides by the summed weights anyway. `SSIMTests` recomputes them.
    static let halfTaps: [Double] = [
        1.0,
        0.8007374029168081,
        0.41111229050718745,
        0.1353352832366127,
        0.028565500784550377,
        0.0038659201394728076,
    ]

    /// The 11 taps, k = −5…5.
    static let taps: [Double] = (-5...5).map { halfTaps[abs($0)] }

    /// The SSIM of two images of equal size; nil when the sizes differ.
    public static func compute(_ a: ParityImage, _ b: ParityImage, mask: MaskBitmap? = nil) -> SSIMMap? {
        guard a.width == b.width, a.height == b.height else { return nil }
        return compute(lumaA: a.luma(), lumaB: b.luma(), width: a.width, height: a.height, mask: mask)
    }

    /// The SSIM of two luma planes (0…255, row-major).
    public static func compute(lumaA: [Double], lumaB: [Double], width: Int, height: Int,
                               mask: MaskBitmap? = nil) -> SSIMMap {
        let count = width * height
        precondition(lumaA.count == count && lumaB.count == count, "SSIM: plane size")
        precondition(mask == nil || (mask!.width == width && mask!.height == height), "SSIM: mask size")
        let maskBits = mask?.bits ?? [UInt8](repeating: 0, count: count)
        var map = [Double](repeating: 0, count: count)
        guard count > 0 else { return SSIMMap(width: width, height: height, values: map, maskBits: maskBits) }

        let radius = windowSize / 2
        // The ring of horizontally filtered rows: 6 planes (Σm, Σmx, Σmy, Σmx², Σmy², Σmxy) per row.
        let planes = 6
        let rowStride = planes * width
        var ring = [Double](repeating: 0, count: windowSize * rowStride)

        lumaA.withUnsafeBufferPointer { la in
        lumaB.withUnsafeBufferPointer { lb in
        maskBits.withUnsafeBufferPointer { mb in
        taps.withUnsafeBufferPointer { g in
        ring.withUnsafeMutableBufferPointer { ring in
        map.withUnsafeMutableBufferPointer { out in
            func filterRow(_ y: Int) {
                let slot = (y % windowSize) * rowStride
                let base = y * width
                for x in 0..<width {
                    var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
                    for k in max(-radius, -x)...min(radius, width - 1 - x) {
                        let index = base + x + k
                        if mb[index] != 0 { continue }
                        let weight = g[k + radius]
                        let va = la[index], vb = lb[index]
                        sw += weight
                        sx += weight * va
                        sy += weight * vb
                        sxx += weight * (va * va)
                        syy += weight * (vb * vb)
                        sxy += weight * (va * vb)
                    }
                    let o = slot + x * planes
                    ring[o] = sw; ring[o + 1] = sx; ring[o + 2] = sy
                    ring[o + 3] = sxx; ring[o + 4] = syy; ring[o + 5] = sxy
                }
            }

            for y in 0..<min(radius, height) { filterRow(y) }
            for y in 0..<height {
                if y + radius < height { filterRow(y + radius) }
                let rows = max(-radius, -y)...min(radius, height - 1 - y)
                for x in 0..<width {
                    let index = y * width + x
                    if mb[index] != 0 { continue }
                    var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
                    for j in rows {
                        let weight = g[j + radius]
                        let o = ((y + j) % windowSize) * rowStride + x * planes
                        sw += weight * ring[o]
                        sx += weight * ring[o + 1]
                        sy += weight * ring[o + 2]
                        sxx += weight * ring[o + 3]
                        syy += weight * ring[o + 4]
                        sxy += weight * ring[o + 5]
                    }
                    let mx = sx / sw, my = sy / sw
                    let vx = sxx / sw - mx * mx
                    let vy = syy / sw - my * my
                    let cov = sxy / sw - mx * my
                    out[index] = ((2 * mx * my + c1) * (2 * cov + c2))
                        / ((mx * mx + my * my + c1) * (vx + vy + c2))
                }
            }
        }}}}}}
        return SSIMMap(width: width, height: height, values: map, maskBits: maskBits)
    }
}

/// The per-pixel SSIM, with the mask it was computed under.
public struct SSIMMap: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major; 0 where the pixel is masked (`maskBits` non-zero).
    public let values: [Double]
    let maskBits: [UInt8]

    /// The mean over unmasked pixels; nil when every pixel is masked or the image is empty.
    public var global: Double? { mean(x0: 0, y0: 0, x1: width, y1: height) }

    /// The mean over the unmasked pixels of `[x0, x1) × [y0, y1)`; nil when there are none.
    public func mean(x0: Int, y0: Int, x1: Int, y1: Int) -> Double? {
        var sum = 0.0
        var count = 0
        for y in max(0, y0)..<min(height, y1) {
            for x in max(0, x0)..<min(width, x1) where maskBits[y * width + x] == 0 {
                sum += values[y * width + x]
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    /// The scores of the `size` × `size` tiles from the top left, row by row; edge tiles are
    /// partial. A tile whose pixels are all masked has no score and is left out.
    public func tiles(size: Int = SSIM.tileSize) -> [TileScore] {
        precondition(size > 0)
        var out: [TileScore] = []
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                if let score = mean(x0: x, y0: y, x1: x + size, y1: y + size) {
                    out.append(TileScore(x: x, y: y, width: min(size, width - x),
                                         height: min(size, height - y), ssim: score))
                }
                x += size
            }
            y += size
        }
        return out
    }
}

/// One tile's mean SSIM. Diagnostic only (ADR-0003 §3).
public struct TileScore: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let ssim: Double
}
