import Foundation
import Testing
@testable import TkzPNG

@Suite("PNG decoding")
struct DecodeTests {

    // MARK: - Independent encoder (zlib) fixtures

    @Test("zlib-written fixtures decode to the formula they were built from", arguments: FixturePNG.cases)
    func fixture(_ fixture: FixturePNG.Case) throws {
        let image = try PNG.decode(fixture.bytes)
        #expect(image.width == fixture.width)
        #expect(image.height == fixture.height)
        let expected = FixturePNG.expectedRGBA(
            width: fixture.width, height: fixture.height, colorType: fixture.colorType, key: fixture.key)
        #expect(image.pixels == expected)
    }

    @Test("the fixtures cover what they claim: all filters, dynamic/fixed/stored, split IDATs, tRNS")
    func fixtureCoverage() throws {
        let dynamic = FixturePNG.cases[0].bytes
        let parts = chunks(of: dynamic)
        #expect(parts.map(\.type) == ["IHDR", "sRGB", "iCCP", "eXIf", "IDAT", "IDAT", "IDAT", "tEXt", "IEND"])
        let stream = parts.filter { $0.type == "IDAT" }.flatMap(\.data)
        #expect((stream[2] >> 1) & 3 == 2, "first deflate block should be dynamic Huffman")
        #expect(FixturePNG.cases[0].height >= 5, "rows cycle through all five filters")

        let fixed = chunks(of: FixturePNG.cases[1].bytes).filter { $0.type == "IDAT" }.flatMap(\.data)
        #expect((fixed[2] >> 1) & 3 == 1)
        let stored = chunks(of: FixturePNG.cases[2].bytes).filter { $0.type == "IDAT" }.flatMap(\.data)
        #expect((stored[2] >> 1) & 3 == 0)

        // The keyed fixtures really have transparent pixels.
        for fixture in FixturePNG.cases where fixture.key != nil {
            let image = try PNG.decode(fixture.bytes)
            #expect(stride(from: 3, to: image.pixels.count, by: 4).contains { image.pixels[$0] == 0 })
        }
    }

    // MARK: - ImageIO-written files from the repository

    /// The two committed golden frames: 600×297 RGBA from ImageIO, with `sRGB` and `eXIf` chunks,
    /// dynamic Huffman and three IDATs. The fingerprints were computed with an independent decoder
    /// (Python's zlib plus a reference unfilter), so a match means byte-identical pixels.
    @Test("both golden frames decode on any platform", arguments: [
        ("golden-bar-cursor.png", UInt64(0x6B62_017A_F85A_B838)),
        ("golden-block-cursor.png", UInt64(0xD545_5089_64F1_79E7)),
    ])
    func golden(_ name: String, fingerprint: UInt64) throws {
        let url = repoRoot().appendingPathComponent("Tests/TkzTerminalRenderTests/Fixtures/\(name)")
        let bytes = [UInt8](try Data(contentsOf: url))
        let types = chunks(of: bytes).map(\.type)
        #expect(types == ["IHDR", "sRGB", "eXIf", "IDAT", "IDAT", "IDAT", "IEND"])

        let image = try PNG.decode(bytes)
        #expect(image.width == 600 && image.height == 297)
        #expect(fnv1a64(image.pixels) == fingerprint)
        // The goldens are opaque, so the premultiplied BGRA used by the golden comparison is lossless.
        #expect(stride(from: 3, to: image.pixels.count, by: 4).allSatisfy { image.pixels[$0] == 255 })
        #expect(Array(image.premultipliedBGRA().prefix(4)) == [43, 26, 23, 255])
    }

    /// A macOS-written screenshot: `iCCP`, `eXIf` and `iTXt` ahead of ten IDATs, row filters 1–4,
    /// partly transparent (the window's rounded corners).
    @Test("a macOS screenshot with iCCP/eXIf/iTXt decodes")
    func screenshot() throws {
        let url = repoRoot().appendingPathComponent("docs/images/main-window.png")
        let bytes = [UInt8](try Data(contentsOf: url))
        let types = chunks(of: bytes).map(\.type)
        #expect(Array(types.prefix(4)) == ["IHDR", "iCCP", "eXIf", "iTXt"])
        #expect(types.filter { $0 == "IDAT" }.count == 10)

        let image = try PNG.decode(bytes)
        #expect(image.width == 1320 && image.height == 820)
        #expect(fnv1a64(image.pixels) == 0x57ED_B4F2_298B_02F2)
        #expect(Array(image.pixels.prefix(4)) == [0, 0, 0, 0])
    }

    // MARK: - Premultiplied BGRA

    @Test("premultipliedBGRA swaps to B,G,R,A and rounds c·a/255 correctly for every pair")
    func premultiplied() {
        let single = PNGImage(width: 1, height: 1, pixels: [255, 128, 0, 128])
        #expect(single.premultipliedBGRA() == [0, 64, 128, 128])

        // Exhaustive over (channel, alpha), against exact rational rounding.
        var pixels: [UInt8] = []
        pixels.reserveCapacity(256 * 256 * 4)
        for alpha in 0...255 {
            for channel in 0...255 { pixels += [UInt8(channel), 0, 0, UInt8(alpha)] }
        }
        let bgra = PNGImage(width: 256, height: 256, pixels: pixels).premultipliedBGRA()
        for alpha in 0...255 {
            for channel in 0...255 {
                let index = (alpha * 256 + channel) * 4
                // round(c·a/255) with integers: floor((2·c·a + 255) / 510).
                let exact = (2 * channel * alpha + 255) / 510
                if Int(bgra[index + 2]) != exact {
                    Issue.record("c=\(channel) a=\(alpha): \(bgra[index + 2]) ≠ \(exact)")
                    return
                }
            }
        }
    }
}
