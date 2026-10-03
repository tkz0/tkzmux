// ImageComparison — every image metric of one pair, the verdict and the heatmap (WOR-322 S1).
//
// `compare(_:_:masks:gate:)` measures, always and whatever the gate:
//
//   * the size of both images (a mismatch fails, and nothing else is measured);
//   * the masked pixels, per kind and as a fraction of the image;
//   * the channel rule: a pixel differs when any premultiplied channel differs by more than the
//     tolerance, and the fraction is over the unmasked pixels. It is the golden comparator's rule
//     (`assertMatchesGolden`), with masked pixels counting in neither the numerator nor the
//     denominator (ADR-0003 §3, Masks);
//   * SSIM, global and per 64 px tile;
//   * ΔE2000 mean and p99, as a diagnostic.
//
// The gate (`ParityGate`) decides which of them pass or fail the run. The heatmap is drawn from the
// channel rule: see `heatmapPNG`.

import TkzPNG

public struct ImageComparisonReport: Codable, Equatable, Sendable {
    public struct Size: Codable, Equatable, Sendable {
        public let width: Int
        public let height: Int
    }

    public struct Point: Codable, Equatable, Sendable {
        public let x: Int
        public let y: Int
    }

    public struct Channel: Codable, Equatable, Sendable {
        /// The tolerance this summary was counted at: the gate's, else the golden comparator's.
        public let tolerance: Int
        public let comparedPixels: Int
        public let differingPixels: Int
        public let fraction: Double
        public let worstDelta: Int
        public let firstDiffering: Point?
    }

    public struct SSIMSummary: Codable, Equatable, Sendable {
        public let global: Double?
        public let tileSize: Int
        public let worstTile: TileScore?
        public let tiles: [TileScore]
    }

    public var schema = 1
    public var kind = "image"
    /// The compared files, filled in by the caller when there are any.
    public var a: String?
    public var b: String?
    public var heatmap: String?
    public let gate: ParityGate
    public let sizeA: Size
    public let sizeB: Size
    public let pixels: Int
    public let maskedPixels: Int
    public let maskedFraction: Double
    /// Masked pixels per `MaskKind` raw value; a pixel under two kinds counts for both.
    public let maskedByKind: [String: Int]
    public let channel: Channel?
    public let ssim: SSIMSummary?
    public let deltaE2000: DeltaESummary?
    public let pass: Bool
    /// Why the run failed, one line per broken rule; empty when it passed.
    public let failures: [String]
}

public enum ImageComparison {
    /// The outcome: the report, plus what the heatmap is drawn from.
    public struct Result: Sendable {
        public var report: ImageComparisonReport
        /// The per-pixel worst channel delta, row-major; nil when the sizes differ.
        public let maxDelta: [UInt8]?
        public let mask: MaskBitmap?
        public let a: ParityImage
    }

    public static func compare(_ a: ParityImage, _ b: ParityImage, masks: ParityMaskSet? = nil,
                               gate: ParityGate = .golden) -> Result {
        let sizeA = ImageComparisonReport.Size(width: a.width, height: a.height)
        let sizeB = ImageComparisonReport.Size(width: b.width, height: b.height)
        guard a.width == b.width, a.height == b.height else {
            let report = ImageComparisonReport(
                gate: gate, sizeA: sizeA, sizeB: sizeB, pixels: a.pixelCount, maskedPixels: 0,
                maskedFraction: 0, maskedByKind: [:], channel: nil, ssim: nil, deltaE2000: nil,
                pass: false,
                failures: ["size differs: \(a.width)×\(a.height) against \(b.width)×\(b.height)"])
            return Result(report: report, maxDelta: nil, mask: nil, a: a)
        }

        let mask = masks?.bitmap(width: a.width, height: a.height) ?? .none(width: a.width, height: a.height)
        let masked = mask.maskedCount
        let maskedFraction = a.pixelCount > 0 ? Double(masked) / Double(a.pixelCount) : 0

        // Channel rule.
        let tolerance = gate.channelTolerance ?? ParityThresholds.l5ChannelTolerance
        var maxDelta = [UInt8](repeating: 0, count: a.pixelCount)
        var differing = 0
        var worst = 0
        var first: ImageComparisonReport.Point?
        a.bgra.withUnsafeBufferPointer { pa in
            b.bgra.withUnsafeBufferPointer { pb in
                for index in 0..<a.pixelCount {
                    let base = index * 4
                    var delta = 0
                    for channel in 0..<4 {
                        delta = max(delta, abs(Int(pa[base + channel]) - Int(pb[base + channel])))
                    }
                    maxDelta[index] = UInt8(delta)
                    guard !mask.isMasked(index) else { continue }
                    worst = max(worst, delta)
                    if delta > tolerance {
                        differing += 1
                        if first == nil { first = .init(x: index % a.width, y: index / a.width) }
                    }
                }
            }
        }
        let compared = a.pixelCount - masked
        let fraction = compared > 0 ? Double(differing) / Double(compared) : 0
        let channel = ImageComparisonReport.Channel(
            tolerance: tolerance, comparedPixels: compared, differingPixels: differing,
            fraction: fraction, worstDelta: worst, firstDiffering: first)

        // SSIM.
        let map = SSIM.compute(a, b, mask: mask)!
        let tiles = map.tiles()
        let worstTile = tiles.min { $0.ssim < $1.ssim }
        let global = map.global
        let ssim = ImageComparisonReport.SSIMSummary(
            global: global, tileSize: SSIM.tileSize, worstTile: worstTile, tiles: tiles)

        // Verdict.
        var failures: [String] = []
        if let pixelTolerance = gate.pixelTolerance, fraction > pixelTolerance {
            failures.append("\(differing) of \(compared) compared pixels differ by more than \(tolerance) "
                            + "(fraction \(fraction), allowed \(pixelTolerance)); worst delta \(worst)")
        }
        if let minSSIM = gate.minSSIM {
            if let global {
                if global < minSSIM { failures.append("SSIM \(global) is below \(minSSIM)") }
            } else {
                failures.append("SSIM has no unmasked pixel to score")
            }
        }
        if let maxMasked = gate.maxMaskedFraction, maskedFraction > maxMasked {
            failures.append("masks cover \(maskedFraction) of the image, allowed \(maxMasked)")
        }

        var byKind: [String: Int] = [:]
        for (kind, count) in mask.countByKind { byKind[kind.rawValue] = count }
        let report = ImageComparisonReport(
            gate: gate, sizeA: sizeA, sizeB: sizeB, pixels: a.pixelCount, maskedPixels: masked,
            maskedFraction: maskedFraction, maskedByKind: byKind, channel: channel, ssim: ssim,
            deltaE2000: DeltaE2000.summary(a, b, mask: mask), pass: failures.isEmpty,
            failures: failures)
        return Result(report: report, maxDelta: maxDelta, mask: mask, a: a)
    }

    /// The heatmap, an opaque RGB PNG the size of the images; nil when the sizes differ.
    ///
    ///   grey, dimmed   identical (the luma of `a`, at a third)
    ///   amber          differs, within the channel tolerance
    ///   red            differs beyond the tolerance; brighter for a larger delta
    ///   blue           masked (the luma of `a` shows through faintly)
    public static func heatmapPNG(_ result: Result) throws -> [UInt8]? {
        guard let maxDelta = result.maxDelta, let mask = result.mask else { return nil }
        let image = result.a
        let tolerance = result.report.channel?.tolerance ?? ParityThresholds.l5ChannelTolerance
        var rgb = [UInt8](repeating: 0, count: image.pixelCount * 3)
        for index in 0..<image.pixelCount {
            let base = index * 4
            let luma = ParityImage.luma(b: image.bgra[base], g: image.bgra[base + 1], r: image.bgra[base + 2])
            let delta = Int(maxDelta[index])
            let pixel: (UInt8, UInt8, UInt8)
            if mask.isMasked(index) {
                pixel = (24, 40, UInt8(96 + luma / 4))
            } else if delta == 0 {
                let grey = UInt8(luma / 3)
                pixel = (grey, grey, grey)
            } else if delta <= tolerance {
                pixel = (200, 150, 0)
            } else {
                pixel = (UInt8(min(255, 128 + delta / 2)), 0, 0)
            }
            rgb[index * 3] = pixel.0
            rgb[index * 3 + 1] = pixel.1
            rgb[index * 3 + 2] = pixel.2
        }
        return try PNG.encode(rgb, width: image.width, height: image.height, colorType: .rgb)
    }
}
