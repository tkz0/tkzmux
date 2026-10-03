// ParityImage — the pixels every image metric reads (WOR-322 S1).
//
// ADR-0003 §1 defines colour parity as equal gamma-encoded sRGB bytes. Both sides are therefore
// compared as stored, with no colour management, after one normalisation: alpha is premultiplied,
// so the bytes are what a `bgra8Unorm` target holds after a readback (the layout the golden
// comparator reads, `PNGImage.premultipliedBGRA()`). A transparent pixel's colour cannot differ, and
// a translucent pixel reads as if composited over black. Opaque images are unchanged.

import Foundation
import TkzPNG

public struct ParityImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Premultiplied BGRA, 8 bits per channel, rows top to bottom with no padding.
    public let bgra: [UInt8]

    public init(width: Int, height: Int, premultipliedBGRA bgra: [UInt8]) {
        precondition(width >= 0 && height >= 0 && bgra.count == width * height * 4,
                     "ParityImage: \(bgra.count) bytes for \(width)×\(height)")
        self.width = width
        self.height = height
        self.bgra = bgra
    }

    public init(_ png: PNGImage) {
        self.init(width: png.width, height: png.height, premultipliedBGRA: png.premultipliedBGRA())
    }

    /// Decodes PNG bytes through TkzPNG.
    public init(pngBytes: [UInt8]) throws {
        self.init(try PNG.decode(pngBytes))
    }

    /// Decodes a PNG file through TkzPNG.
    public init(contentsOf url: URL) throws {
        try self.init(pngBytes: [UInt8](try Data(contentsOf: url)))
    }

    public var pixelCount: Int { width * height }

    /// Luma of the gamma-encoded bytes, Y′ = 0.2126 R′ + 0.7152 G′ + 0.0722 B′ on 0…255, not
    /// linearised (ADR-0003 §3, SSIM).
    public func luma() -> [Double] {
        var out = [Double](repeating: 0, count: pixelCount)
        bgra.withUnsafeBufferPointer { src in
            for index in 0..<pixelCount {
                let base = index * 4
                out[index] = Self.luma(b: src[base], g: src[base + 1], r: src[base + 2])
            }
        }
        return out
    }

    @inline(__always)
    static func luma(b: UInt8, g: UInt8, r: UInt8) -> Double {
        0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
    }
}
