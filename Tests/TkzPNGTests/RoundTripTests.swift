import Foundation
import Testing
@testable import TkzPNG

@Suite("PNG encoding and round trips")
struct RoundTripTests {

    /// Expands `pixels` in `colorType` layout to the RGBA a decoder returns.
    private func rgba(_ pixels: [UInt8], _ colorType: PNGColorType) -> [UInt8] {
        let channels = colorType.channels
        var out: [UInt8] = []
        out.reserveCapacity(pixels.count / channels * 4)
        for start in stride(from: 0, to: pixels.count, by: channels) {
            let p = pixels[start..<(start + channels)]
            switch colorType {
            case .rgba: out += p
            case .rgb: out += p + [255]
            case .grayAlpha: out += [p[start], p[start], p[start], p[start + 1]]
            case .gray: out += [p[start], p[start], p[start], 255]
            }
        }
        return out
    }

    private enum Content: CaseIterable { case noise, flat, gradient, terminal }

    private func image(_ content: Content, width: Int, height: Int, channels: Int, seed: UInt64) -> [UInt8] {
        var generator = SeededGenerator(seed: seed)
        let count = width * height * channels
        switch content {
        case .noise:
            return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
        case .flat:
            let pixel = (0..<channels).map { _ in UInt8.random(in: 0...255, using: &generator) }
            return (0..<count).map { pixel[$0 % channels] }
        case .gradient:
            return (0..<count).map { index in
                let pixel = index / channels, c = index % channels
                return UInt8(truncatingIfNeeded: (pixel % width) * 3 + (pixel / width) * 2 + c * 40)
            }
        case .terminal:
            // A background with sparse "glyph" blocks repeating every few cells.
            let glyphs = (0..<4).map { _ in (0..<64).map { _ in UInt8.random(in: 0...3, using: &generator) == 0 } }
            return (0..<count).map { index in
                let pixel = index / channels, x = pixel % width, y = pixel / width
                let glyph = glyphs[(x / 8 + y / 8) % glyphs.count]
                return glyph[(y % 8) * 8 + x % 8] ? 230 : 24 + UInt8(index % channels)
            }
        }
    }

    @Test("encode → decode is pixel-identical for every colour type, size and content",
          arguments: PNGColorType.allCases)
    func selfRoundTrip(_ colorType: PNGColorType) throws {
        let sizes = [(1, 1), (1, 9), (9, 1), (2, 2), (17, 5), (257, 3), (64, 64), (300, 80)]
        for (index, (width, height)) in sizes.enumerated() {
            for content in Content.allCases {
                let pixels = image(content, width: width, height: height,
                                   channels: colorType.channels, seed: UInt64(index + 1))
                let png = try PNG.encode(pixels, width: width, height: height, colorType: colorType)
                let decoded = try PNG.decode(png)
                #expect(decoded.width == width && decoded.height == height)
                #expect(decoded.pixels == rgba(pixels, colorType), "\(colorType) \(width)×\(height) \(content)")
            }
        }
    }

    @Test("re-encoding the golden frame round-trips exactly and compresses it")
    func goldenRoundTrip() throws {
        let url = repoRoot().appendingPathComponent("Tests/TkzTerminalRenderTests/Fixtures/golden-block-cursor.png")
        let original = try PNG.decode([UInt8](try Data(contentsOf: url)))
        let png = try PNG.encode(original)
        #expect(try PNG.decode(png) == original)
        #expect(png.count < original.pixels.count / 8)
    }

    @Test("the output is plain: IHDR, IDAT×n of at most 64 KiB, IEND — no colour chunks")
    func structure() throws {
        let pixels = image(.noise, width: 200, height: 200, channels: 4, seed: 3)
        let png = try PNG.encode(pixels, width: 200, height: 200)
        let parts = chunks(of: png)
        #expect(parts.first?.type == "IHDR" && parts.last?.type == "IEND")
        let idats = parts.dropFirst().dropLast()
        #expect(idats.count > 1 && idats.allSatisfy { $0.type == "IDAT" && $0.data.count <= 1 << 16 })
        #expect(parts[0].data == be32(200) + be32(200) + [8, 6, 0, 0, 0])
    }

    @Test("noise falls back to stored blocks; flat content collapses to almost nothing")
    func blockChoice() throws {
        let noise = image(.noise, width: 256, height: 256, channels: 4, seed: 9)
        let noisy = try PNG.encode(noise, width: 256, height: 256)
        // Stored overhead: 5 bytes per ≤ 65 535-byte block plus the filter bytes and framing.
        #expect(noisy.count < noise.count + noise.count / 100 + 256 + 200)

        let flat = image(.flat, width: 256, height: 256, channels: 4, seed: 9)
        // Fixed Huffman bottoms out at 13 bits per 258-byte match: ~160:1 on a flat frame.
        #expect(try PNG.encode(flat, width: 256, height: 256).count < flat.count / 100)
    }

    @Test("an empty or mismatched pixel buffer is an argument error, not a trap")
    func badArguments() {
        #expect(throws: PNGError.self) { try PNG.encode([], width: 0, height: 1) }
        #expect(throws: PNGError.self) { try PNG.encode([0, 0, 0], width: 1, height: 1) }
        #expect(throws: PNGError.self) { try PNG.encode([0, 0], width: 1, height: 1, colorType: .gray) }
        #expect(throws: PNGError.self) { try PNG.encode([0], width: Int.max, height: 2) }
    }

    @Test("deflate streams round-trip through inflate across block and window boundaries")
    func deflateLongInputs() throws {
        var generator = SeededGenerator(seed: 11)
        // Repeats at distances up to and past the 32 KiB window, interleaved with noise.
        let seedBlock = (0..<40_000).map { _ in UInt8.random(in: 0...255, using: &generator) }
        var input = seedBlock
        input += seedBlock[0..<30_000]
        input += [UInt8](repeating: 7, count: 70_000)
        input += seedBlock[5_000..<9_000]
        let compressed = input.withUnsafeBytes { Deflate.zlibCompress($0) }
        let output = try compressed.withUnsafeBytes { try Inflate.zlibDecompress($0, outputSize: input.count) }
        #expect(output == input)
        #expect(compressed.count < input.count * 3 / 4)
    }
}
