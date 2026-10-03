// The channel rule (the golden comparator's), ΔE2000 as a diagnostic, the gates and the heatmap.

import Foundation
import Testing
import TkzPNG
@testable import TkzParity

@Suite struct ImageComparisonTests {
    /// A 40×25 (1000 px) grey image with `count` pixels changed by `delta` in one channel.
    static func pair(count: Int, delta: UInt8, channel: Int = 2) -> (ParityImage, ParityImage) {
        let a = TestImages.solid(width: 40, height: 25, grey: 100)
        var bytes = a.bgra
        // Pixels 0, 7, 14, … (7 is coprime to 1000, so up to 1000 distinct pixels).
        for index in 0..<count { bytes[(index * 7 % 1000) * 4 + channel] &+= delta }
        return (a, ParityImage(width: 40, height: 25, premultipliedBGRA: bytes))
    }

    /// `assertMatchesGolden`: a pixel differs when a channel moves by more than 2, and the run
    /// passes while at most 0.2 % of pixels differ (`fraction <= pixelTolerance`).
    @Test func theChannelRuleMatchesTheGoldenComparator() {
        let (a, withinTolerance) = Self.pair(count: 50, delta: 2)
        let quiet = ImageComparison.compare(a, withinTolerance).report
        #expect(quiet.channel?.differingPixels == 0)
        #expect(quiet.channel?.worstDelta == 2)
        #expect(quiet.pass)

        let (_, two) = Self.pair(count: 2, delta: 3)
        let atLimit = ImageComparison.compare(a, two).report
        #expect(atLimit.channel?.differingPixels == 2)
        #expect(atLimit.channel?.fraction == 0.002)
        #expect(atLimit.channel?.firstDiffering == .init(x: 0, y: 0))
        #expect(atLimit.pass)

        let (_, three) = Self.pair(count: 3, delta: 3)
        let over = ImageComparison.compare(a, three).report
        #expect(over.channel?.differingPixels == 3)
        #expect(!over.pass)
        #expect(over.failures.count == 1)

        // Alpha is a channel too.
        let (_, alpha) = Self.pair(count: 3, delta: 200, channel: 3)
        #expect(ImageComparison.compare(a, alpha).report.channel?.differingPixels == 3)
    }

    @Test func theDefaultGateIsTheGoldenComparatorsTolerances() {
        #expect(ParityGate.golden.channelTolerance == 2)
        #expect(ParityGate.golden.pixelTolerance == 0.002)
        #expect(ParityGate.golden.minSSIM == nil)
        #expect(ParityGate.named("l6") == .l6Window)
        #expect(ParityGate.named("L3")?.channelTolerance == ParityThresholds.l3ChannelTolerance)
        #expect(ParityGate.named("loose") == nil)
    }

    /// L3 allows ±1 and no outliers at all.
    @Test func theL3GateAllowsOneLSBAndNoOutliers() {
        let (a, one) = Self.pair(count: 400, delta: 1)
        #expect(ImageComparison.compare(a, one, gate: .l3).report.pass)
        let (_, two) = Self.pair(count: 1, delta: 2)
        #expect(!ImageComparison.compare(a, two, gate: .l3).report.pass)
    }

    @Test func l6CapsTheMaskedFraction() {
        let image = TestImages.noise(width: 100, height: 100, seed: 2)
        func masks(_ height: Double) -> ParityMaskSet {
            ParityMaskSet(masks: [ParityMask(kind: .vibrancy, rect: PixelRect(x: 0, y: 0, width: 100, height: height))])
        }
        #expect(ImageComparison.compare(image, image, masks: masks(15), gate: .l6Window).report.pass)
        let over = ImageComparison.compare(image, image, masks: masks(16), gate: .l6Window).report
        #expect(!over.pass)
        #expect(over.maskedFraction == 0.16)
        #expect(over.maskedByKind == ["vibrancy": 1600])
    }

    /// Premultiplied bytes are compared, as a GPU readback holds them: the colour under alpha 0
    /// is not a difference.
    @Test func colourUnderZeroAlphaIsNotADifference() throws {
        let a = PNGImage(width: 2, height: 1, pixels: [255, 0, 0, 0, 10, 20, 30, 255])
        let b = PNGImage(width: 2, height: 1, pixels: [0, 0, 255, 0, 10, 20, 30, 255])
        let report = ImageComparison.compare(ParityImage(a), ParityImage(b), gate: .exact).report
        #expect(report.pass)
        #expect(report.deltaE2000?.mean == 0)
    }

    /// Sharma, Wu and Dalal 2005, table 1: pairs 1, 7, 17, 25 and 34.
    @Test(arguments: [
        (50.0, 2.6772, -79.7751, 50.0, 0.0, -82.7485, 2.0425),
        (50.0, 0.0, 0.0, 50.0, -1.0, 2.0, 2.3669),
        (50.0, 2.5, 0.0, 56.0, -27.0, -3.0, 31.9030),
        (60.2574, -34.0099, 36.2677, 60.4626, -34.1751, 39.4387, 1.2644),
        (90.8027, -2.0831, 1.4410, 91.1528, -1.6435, 0.0447, 1.4441),
    ])
    func deltaE2000MatchesSharmasTable(l1: Double, a1: Double, b1: Double, l2: Double, a2: Double,
                                       b2: Double, expected: Double) {
        let value = DeltaE2000.difference(.init(l: l1, a: a1, b: b1), .init(l: l2, a: a2, b: b2))
        #expect(abs(value - expected) < 0.0001, "ΔE2000 \(value), expected \(expected)")
    }

    @Test func srgbConvertsToTheD65WhitePoint() {
        let white = DeltaE2000.lab(r: 255, g: 255, b: 255)
        #expect(abs(white.l - 100) < 1e-3 && abs(white.a) < 1e-2 && abs(white.b) < 1e-2)
        let black = DeltaE2000.lab(r: 0, g: 0, b: 0)
        #expect(black.l == 0 && black.a == 0 && black.b == 0)
    }

    /// ΔE is reported and never decides a verdict.
    @Test func deltaEIsADiagnosticOnly() throws {
        let a = TestImages.solid(width: 10, height: 10, grey: 0)
        let b = TestImages.image(width: 10, height: 10) { x, y in x == 0 && y == 0 ? (255, 0, 0) : (0, 0, 0) }
        let report = ImageComparison.compare(a, b, gate: .l4Glyph).report
        let deltaE = try #require(report.deltaE2000)
        #expect(deltaE.diagnosticOnly)
        #expect(deltaE.comparedPixels == 100)
        #expect(deltaE.p99 == 0)                 // 1 of 100: below the 99th percentile
        #expect(deltaE.mean > 0)
        #expect(report.failures.allSatisfy { !$0.contains("ΔE") })
    }

    @Test func theHeatmapMarksDifferencesAndMasks() throws {
        let (a, b) = Self.pair(count: 3, delta: 3)
        let masks = ParityMaskSet(masks: [ParityMask(kind: .windowControls, rect: PixelRect(x: 30, y: 20, width: 10, height: 5))])
        let result = ImageComparison.compare(a, b, masks: masks)
        let png = try #require(try ImageComparison.heatmapPNG(result))
        let heatmap = try PNG.decode(png)
        #expect(heatmap.width == 40 && heatmap.height == 25)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(heatmap.pixels[((y * 40 + x) * 4)..<((y * 40 + x) * 4 + 3)]) }
        #expect(pixel(0, 0)[0] > 128 && pixel(0, 0)[1] == 0)            // differs: red
        #expect(pixel(1, 0) == [33, 33, 33])                            // identical: dimmed grey
        #expect(pixel(35, 22)[2] > pixel(35, 22)[0])                    // masked: blue
        let sizes = ImageComparison.compare(a, TestImages.solid(width: 1, height: 1, grey: 0))
        #expect(try ImageComparison.heatmapPNG(sizes) == nil)
    }

    @Test func theReportEncodesAsCanonicalJSON() throws {
        let (a, b) = Self.pair(count: 3, delta: 3)
        var report = ImageComparison.compare(a, b).report
        report.a = "a.png"
        report.b = "b.png"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(ImageComparisonReport.self, from: data)
        #expect(decoded == report)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix(#"{"a":"a.png","b":"b.png","channel":"#))
    }
}
