// TkzPNG — a dependency-free PNG codec for the platforms that have no ImageIO.
//
// Scope is what tkzmux itself reads and writes, not the whole of PNG:
//
//   * **Decode** 8-bit greyscale, greyscale+alpha, RGB and RGBA (colour types 0, 4, 2, 6),
//     non-interlaced, with full inflate (stored, fixed and dynamic Huffman), any number of IDAT
//     chunks, all five row filters and `tRNS` for the two alpha-less types. Every chunk's CRC-32 and
//     the image data's Adler-32 are verified. Other ancillary chunks (`sRGB`, `iCCP`, `eXIf`, `iTXt`,
//     …) are skipped: no colour management happens here, the bytes come back as stored.
//   * **Encode** the same four layouts: a per-row filter choice (minimum sum of absolute
//     differences), greedy LZ77 into fixed-Huffman blocks, and a stored block wherever that is
//     smaller.
//
// Palette images, 1/2/4/16-bit depths and Adam7 interlacing throw `PNGError.unsupported`. ImageIO
// on the Mac never writes them for the frames, atlases and glyph dumps this codec exists for, and
// the app's own `pngData` paths keep using ImageIO there.
//
// No Foundation: the codec works on `[UInt8]`, and callers holding `Data` convert at the edge.

/// A decoded image: straight (non-premultiplied) RGBA, 8 bits per channel, rows top to bottom with no
/// padding, so `pixels.count == width * height * 4`.
public struct PNGImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The pixels as premultiplied BGRA (`B, G, R, A` in memory) — the layout of a CoreGraphics
    /// `premultipliedFirst | byteOrder32Little` context and of a `.bgra8Unorm` texture, which is
    /// what the golden-frame comparison reads back from the GPU.
    ///
    /// Each colour channel becomes `round(c · a / 255)`. That quotient is never exactly halfway
    /// between two integers (255 is odd), so this is the one correctly rounded value and does not
    /// depend on a tie rule. Premultiplying is lossy below alpha 255; opaque pixels are unchanged.
    public func premultipliedBGRA() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pixels.count)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var index = 0
                while index < src.count {
                    let alpha = UInt32(src[index + 3])
                    dst[index] = Self.premultiply(src[index + 2], alpha)
                    dst[index + 1] = Self.premultiply(src[index + 1], alpha)
                    dst[index + 2] = Self.premultiply(src[index], alpha)
                    dst[index + 3] = UInt8(alpha)
                    index += 4
                }
            }
        }
        return out
    }

    @inline(__always)
    private static func premultiply(_ channel: UInt8, _ alpha: UInt32) -> UInt8 {
        UInt8((UInt32(channel) * alpha + 127) / 255)
    }
}

/// The channel layouts the encoder writes and the decoder reads (all 8 bits per channel).
public enum PNGColorType: UInt8, Sendable, CaseIterable {
    case gray = 0
    case rgb = 2
    case grayAlpha = 4
    case rgba = 6

    /// Bytes per pixel.
    public var channels: Int {
        switch self {
        case .gray: 1
        case .rgb: 3
        case .grayAlpha: 2
        case .rgba: 4
        }
    }
}

public enum PNGError: Error, Equatable, Sendable {
    /// The input does not start with the PNG signature.
    case notPNG
    /// The input ends before the image does (in a chunk header, a chunk body or the zlib stream).
    case truncated
    /// A chunk's CRC-32, or the image data's Adler-32, does not match.
    case checksumMismatch(String)
    /// The structure is wrong: chunk order, a field out of range, an invalid deflate stream.
    case corruptData(String)
    /// Valid PNG this codec does not implement (palette, bit depth ≠ 8, interlacing).
    case unsupported(String)
    /// Larger than the caller's `maxPixels`.
    case tooLarge(width: Int, height: Int)
    /// `encode` was given pixels that do not match the dimensions, or a zero dimension.
    case invalidArgument(String)
}

public enum PNG {
    /// The default ceiling on `width * height` for `decode`: 2^28 pixels (a 16384² image, 1 GiB as
    /// RGBA) — far above any frame tkzmux renders, far below what a hostile header could claim.
    public static let defaultMaxPixels = 1 << 28

    /// The 8-byte signature every PNG starts with.
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Decodes `bytes` to straight RGBA8. Throws `PNGError` for anything malformed or unsupported;
    /// never traps on hostile input.
    public static func decode(_ bytes: [UInt8], maxPixels: Int = defaultMaxPixels) throws -> PNGImage {
        try bytes.withUnsafeBytes { raw in
            try PNGDecoder.decode(raw, maxPixels: maxPixels)
        }
    }

    /// Encodes `pixels` (rows top to bottom, `width * colorType.channels` bytes each, no padding;
    /// straight alpha) as a PNG.
    public static func encode(
        _ pixels: [UInt8], width: Int, height: Int, colorType: PNGColorType = .rgba
    ) throws -> [UInt8] {
        try PNGEncoder.encode(pixels, width: width, height: height, colorType: colorType)
    }

    /// Encodes a decoded (or hand-built) RGBA image.
    public static func encode(_ image: PNGImage) throws -> [UInt8] {
        try encode(image.pixels, width: image.width, height: image.height, colorType: .rgba)
    }
}
