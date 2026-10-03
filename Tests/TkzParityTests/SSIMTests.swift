// SSIM as ADR-0003 §3 defines it: the S1 acceptance cases (identical → 1.0, a 1 px glyph shift
// → below 0.99, masked regions excluded) plus checks of the formula and of the fast filter.

import Foundation
import Testing
@testable import TkzParity

@Suite struct SSIMTests {
    @Test func identicalImagesScoreExactlyOne() throws {
        for image in [TestImages.glyphLine(), TestImages.noise(width: 70, height: 45, seed: 7),
                      TestImages.solid(width: 3, height: 2, grey: 0)] {
            let map = try #require(SSIM.compute(image, image))
            #expect(map.global == 1.0)
            #expect(map.tiles().allSatisfy { $0.ssim == 1.0 })
        }
    }

    @Test func aOnePixelGlyphShiftScoresBelowPoint99() throws {
        let base = TestImages.glyphLine()
        let shifted = TestImages.glyphLine(shift: 1)
        let score = try #require(SSIM.compute(base, shifted)?.global)
        #expect(score < 0.99, "1 px shift scored \(score)")
        print("glyph line, 1 px shift: SSIM \(score)")
        // And a shift well below a pixel still registers, but less.
        let subpixel = try #require(SSIM.compute(base, TestImages.glyphLine(shift: 0.25))?.global)
        #expect(subpixel > score && subpixel < 1)
    }

    @Test func maskedRegionsAreExcludedFromTheScore() throws {
        let a = TestImages.noise(width: 64, height: 40, seed: 3)
        // b is a, except a 24×18 block of other noise at (16, 10).
        let other = TestImages.noise(width: 64, height: 40, seed: 99)
        var bytes = a.bgra
        for y in 10..<28 {
            for x in 16..<40 {
                let base = (y * 64 + x) * 4
                for channel in 0..<4 { bytes[base + channel] = other.bgra[base + channel] }
            }
        }
        let b = ParityImage(width: 64, height: 40, premultipliedBGRA: bytes)

        let unmasked = try #require(SSIM.compute(a, b)?.global)
        #expect(unmasked < 0.95)

        let masks = ParityMaskSet(masks: [ParityMask(kind: .vibrancy, rect: PixelRect(x: 16, y: 10, width: 24, height: 18))])
        let mask = masks.bitmap(width: 64, height: 40)
        // Not just the centres: no window reads a masked pixel, so the neighbours score 1 too.
        let masked = try #require(SSIM.compute(a, b, mask: mask))
        #expect(masked.global == 1.0)

        let result = ImageComparison.compare(a, b, masks: masks, gate: .l5Component)
        #expect(result.report.channel?.differingPixels == 0)
        #expect(result.report.maskedPixels == 24 * 18)
        #expect(result.report.ssim?.global == 1.0)
        #expect(result.report.pass)
        // Without the mask the same pair fails both rules.
        let unmaskedResult = ImageComparison.compare(a, b, gate: .l5Component)
        #expect(!unmaskedResult.report.pass)
        #expect(unmaskedResult.report.failures.count == 2)
    }

    /// The structure term vanishes for flat images, so two solid greys score exactly the luminance
    /// term (2μxμy + C1) / (μx² + μy² + C1).
    @Test func solidGreysScoreTheLuminanceTerm() throws {
        let a = TestImages.solid(width: 20, height: 20, grey: 100)
        let b = TestImages.solid(width: 20, height: 20, grey: 110)
        let score = try #require(SSIM.compute(a, b)?.global)
        let c1 = (0.01 * 255.0) * (0.01 * 255.0)
        let mx = a.luma()[0], my = b.luma()[0]
        #expect(abs(score - (2 * mx * my + c1) / (mx * mx + my * my + c1)) < 1e-12)
        #expect(abs(score - 0.995_476) < 1e-6)
    }

    @Test func theTapsAreTheGaussianAtSigmaOnePointFive() {
        #expect(SSIM.taps.count == SSIM.windowSize)
        for (index, tap) in SSIM.taps.enumerated() {
            let k = Double(index - 5)
            let expected = exp(-k * k / (2 * SSIM.sigma * SSIM.sigma))
            #expect(abs(tap - expected) <= expected.ulp, "tap \(k): \(tap) against \(expected)")
        }
    }

    /// The separable ring filter against the definition, with a mask and the image border in play.
    @Test func theFastFilterMatchesTheDefinition() throws {
        let a = TestImages.noise(width: 37, height: 23, seed: 11)
        let b = TestImages.glyphLine().crop(width: 37, height: 23)
        let masks = ParityMaskSet(masks: [
            ParityMask(kind: .cjkEmoji, rect: PixelRect(x: 4, y: 3, width: 6, height: 5)),
            ParityMask(kind: .windowControls, rect: PixelRect(x: 30, y: 0, width: 7, height: 2)),
        ])
        let mask = masks.bitmap(width: 37, height: 23)
        let fast = try #require(SSIM.compute(a, b, mask: mask))
        let reference = TestImages.referenceSSIM(a, b, mask: mask)
        var worst = 0.0
        for (index, expected) in reference.enumerated() {
            guard let expected else { continue }
            worst = max(worst, abs(fast.values[index] - expected))
        }
        #expect(worst < 1e-12, "largest difference \(worst)")
    }

    @Test func imagesSmallerThanTheWindowStillScore() throws {
        let a = TestImages.noise(width: 4, height: 3, seed: 5)
        let b = TestImages.noise(width: 4, height: 3, seed: 6)
        let fast = try #require(SSIM.compute(a, b))
        let reference = TestImages.referenceSSIM(a, b, mask: .none(width: 4, height: 3))
        for (index, expected) in reference.enumerated() {
            #expect(abs(fast.values[index] - expected!) < 1e-12)
        }
        #expect(SSIM.compute(ParityImage(width: 0, height: 0, premultipliedBGRA: []),
                             ParityImage(width: 0, height: 0, premultipliedBGRA: []))?.global == nil)
    }

    @Test func tilesCoverTheImageWithPartialEdges() throws {
        let image = TestImages.noise(width: 150, height: 70, seed: 1)
        let tiles = try #require(SSIM.compute(image, image)).tiles()
        #expect(tiles.count == 3 * 2)
        #expect(tiles.map(\.width) == [64, 64, 22, 64, 64, 22])
        #expect(tiles.map(\.height) == [64, 64, 64, 6, 6, 6])
        // A fully masked tile has no score.
        let masks = ParityMaskSet(masks: [ParityMask(kind: .vibrancy, rect: PixelRect(x: 0, y: 0, width: 64, height: 64))])
        let masked = try #require(SSIM.compute(image, image, mask: masks.bitmap(width: 150, height: 70)))
        #expect(masked.tiles().count == 5)
    }

    @Test func differentSizesAreAFailureNotACrash() {
        let result = ImageComparison.compare(TestImages.solid(width: 4, height: 4, grey: 1),
                                             TestImages.solid(width: 4, height: 5, grey: 1))
        #expect(!result.report.pass)
        #expect(result.report.failures == ["size differs: 4×4 against 4×5"])
        #expect(result.report.ssim == nil)
        #expect(SSIM.compute(TestImages.solid(width: 4, height: 4, grey: 1),
                             TestImages.solid(width: 5, height: 4, grey: 1)) == nil)
    }
}

extension ParityImage {
    /// The top-left `width` × `height` of the image.
    func crop(width: Int, height: Int) -> ParityImage {
        var out: [UInt8] = []
        for y in 0..<height {
            let start = y * self.width * 4
            out += bgra[start..<(start + width * 4)]
        }
        return ParityImage(width: width, height: height, premultipliedBGRA: out)
    }
}
