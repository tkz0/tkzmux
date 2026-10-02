// Shared test inputs for TkzPNG: small PNGs written by a *different* encoder (zlib), the pixel
// formula they were built from, and chunk-level helpers for building and mutating PNGs.
//
// ## Where the embedded PNGs come from
//
// Python's `zlib` (the reference deflate implementation) produced every stream below; the PNG
// wrapping and the row filters were done by a short script, so none of these bytes went through
// TkzPNG's encoder. Each image is `FixturePNG.value(x:y:channel:)` per channel; row `y` uses filter
// `y % 5`, so every image exercises all five filters against independent encoder output. Recipe:
//
//     raw   = b''.join(bytes([y % 5]) + filter(y % 5, row(y)) for y in range(h))
//     zdata = zlib.compress(raw, 9)        # "dynamic": large enough that zlib picks BTYPE 2
//           | zlib.compress(raw, 0)        # "stored"
//           | compressobj(9, DEFLATED, 15, 9, Z_FIXED)   # "fixed"
//     png   = sig + IHDR + [sRGB, iCCP, eXIf]? + tRNS? + IDAT×n (zdata split evenly) + tEXt? + IEND
//
// The ancillary variants put `sRGB`/`iCCP`/`eXIf` before the image data and a `tEXt` after it, the
// way ImageIO and other encoders lay them out; the decoder must skip all of them.

import Foundation
@testable import TkzPNG

enum FixturePNG {
    /// The pixel formula every embedded fixture was generated from. Rows with `y % 6 == 5` are
    /// constant, so the encoder produced long overlapping (distance < length) matches there.
    static func value(x: Int, y: Int, channel c: Int) -> UInt8 {
        if y % 6 == 5 { return UInt8((y * 29 + c * 53) & 0xFF) }
        return UInt8((((x >> 2) * 3 + y + c * 5) % 12) * 20 + (x & 1))
    }

    /// The straight RGBA a correct decoder must produce for a fixture of the given layout.
    static func expectedRGBA(
        width: Int, height: Int, colorType: PNGColorType, key: [UInt8]? = nil
    ) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = (0..<4).map { value(x: x, y: y, channel: $0) }
                var pixel: [UInt8] = switch colorType {
                case .gray: [v[0], v[0], v[0], 255]
                case .grayAlpha: [v[0], v[0], v[0], v[1]]
                case .rgb: [v[0], v[1], v[2], 255]
                case .rgba: [v[0], v[1], v[2], v[3]]
                }
                if let key {
                    let sample = colorType == .gray ? [v[0], v[0], v[0]] : [v[0], v[1], v[2]]
                    let keyRGB = key.count == 1 ? [key[0], key[0], key[0]] : key
                    if sample == keyRGB { pixel[3] = 0 }
                }
                out += pixel
            }
        }
        return out
    }

    struct Case: Sendable, CustomStringConvertible {
        let name: String
        let base64: String
        let width: Int
        let height: Int
        let colorType: PNGColorType
        let key: [UInt8]?
        var bytes: [UInt8] { [UInt8](Data(base64Encoded: base64.filter { !$0.isWhitespace })!) }
        var description: String { name }
    }

    static let cases: [Case] = [
        Case(name: "RGBA, dynamic Huffman, 3 IDATs, sRGB/iCCP/eXIf/tEXt", base64: rgbaDynamic,
             width: 64, height: 40, colorType: .rgba, key: nil),
        Case(name: "RGB, fixed Huffman", base64: rgbFixed,
             width: 21, height: 11, colorType: .rgb, key: nil),
        Case(name: "grey, stored blocks, 2 IDATs", base64: grayStored,
             width: 17, height: 9, colorType: .gray, key: nil),
        Case(name: "grey+alpha, dynamic Huffman, sRGB/iCCP/eXIf/tEXt", base64: grayAlphaDynamic,
             width: 61, height: 37, colorType: .grayAlpha, key: nil),
        Case(name: "RGB with a tRNS key colour", base64: rgbKeyed, width: 48, height: 30, colorType: .rgb,
             key: [value(x: 3, y: 2, channel: 0), value(x: 3, y: 2, channel: 1), value(x: 3, y: 2, channel: 2)]),
        Case(name: "grey with a tRNS key, fixed Huffman", base64: grayKeyed, width: 12, height: 10,
             colorType: .gray, key: [value(x: 0, y: 5, channel: 0)]),
    ]

    // rgbaDynamic: 64x40 type 6, dynamic (first block BTYPE 2), 3 IDAT, 944 bytes
    static let rgbaDynamic = """
        iVBORw0KGgoAAAANSUhEUgAAAEAAAAAoCAYAAABOzvzpAAAAAXNSR0IArs4c6QAAACJpQ0NQZmFrZQAAeJzLyy9RKEpNzMmp
        VEhUKCjKT8vMSQUATukHjd2CmmgAAAAKZVhJZk1NACoAAAAIAAC+oPKvAAAA90lEQVR42uWZTUhUURTH7/uAYgQ33tlIZE4z
        8YQpZSCafCMTFC10M25aRJrCDExUrvoYFVq1CXXRjLXoA3Rl02qwmcI+FmWW1qYgGgWVYDKoRV+iEpl2rnHgvTvBa1p55154
        /ObMm//m8vjNOe8SEp0MKbGpJmRoiCaaht3dyMRsJNs915pDZo1+kqsbUJCi5xUKdxRY67AYTbPFtNUtpr2GH1hruG2KnFcp
        9VL7VeoSO68ZR+nhClguWIwGLFudMYKAFJRJxiDcT8GHJHyR2vh9xhA5r7NdsD4SbBNttcnV1KEWLE8uP/vZIPOlMDty0ihN
        Mvx9wfKq5A6kKZzVKQAAAPdJREFUGjgwwUkkY63BISCVFNRJF+NfJGOInGcS9FofCdhE+yNDHSUkdJ5MQss0BS0TkjVGbmiZ
        kBFomVqhZUL2Q8s1AC0XUvS8Ej6TnicSL/Xx15r2J992HEf+8p+8trb71HXk/vjI28YTt/LIs9mC51zu/U6k6HkNHBiwS4Tr
        rKB1AndUgENcjMWS4SUkVl5n/x12SZildV6C54ls4y+fV5gdZRp/+bx6s6ue3Di9Zx3Z6Vl82lH7fRzp+3Av4V24ex45c7s3
        NJ3uMZGi5zX1pa/refuae6JtlTIq6WDHgr7tQUGrvs9YHz6y3OdpnLlUG5xmnGi7SNMH3ghy2LEAAAD4SURBVK2MhOeXGQu9
        1QGR87ps42+RBMEds+COOSS4wwB31CHBHVFwRwwJ7hgCdwwjRc9v2FGm8ZfPq7KNv3xe2zeaa/jYPFr1qflOFeMh/5Wlg/7B
        JeSuyi95X+XnPHJr/PXYlvirMSTmRM3rscFxVaZHns8T2cZfPq8wOzrsmENn5bjjmzqvlqqN/3DQps5rgej2iEzjL5/Xf7zo
        O2Z9Q/Logv2NyUNC3ljrvSRvuw95InKeyDb+8nmF2VGm8bf4YES21o8/GAEHJsv59Ncprzu/cyvv02Oy4u+8KvP1x5ISzwKq
        5A6kGjgwVM6nv075f5FgWZ8e/wZqq0qSMzXUrAAAABx0RVh0Q29tbWVudABhZnRlciB0aGUgaW1hZ2UgZGF0Yfg5SPQAAAAA
        SUVORK5CYII=
        """
    // rgbFixed: 21x11 type 2, fixed (first block BTYPE 1), 1 IDAT, 279 bytes
    static let rgbFixed = """
        iVBORw0KGgoAAAANSUhEUgAAABUAAAALCAIAAAAfqVEqAAAA3klEQVR4AWNgSDnBmHoSQtosELFdKAohK+4EVN4NhJBbNHq2
        avZCSDT1jCIVdxgZGf///w8kra29EWxvayRxBNvbGlncm0lERAUJEQNQ1DNrRIlwc3NzcXEBSQ0NDQR7A4JtoaExmZt7EhfX
        ZJCaDcjqWYBmwN0DNBHBtkZii+Bgq4gwTDz2mxLECAxhrGGGFk5YwxKonomy4BNhjhJxwxp+GzQsuLknc3FNApK4whU9/FSQ
        2NYihMMPqJ7hhM2Ck7YLISQwLYlW3oWQAVs0ArdqQsgehpRexlQIiaYeAJCiy/VkKwY+AAAAAElFTkSuQmCC
        """
    // grayStored: 17x9 type 0, stored (first block BTYPE 0), 2 IDAT, 242 bytes
    static let grayStored = """
        iVBORw0KGgoAAAANSUhEUgAAABEAAAAJCAAAAADxg5jQAAAAVklEQVR4AQGiAF3/AAABAAE8PTw9eHl4ebS1tLUAARQB/wE7
        Af8BOwH/ATsB/wFLAhQUFBQUFBQUFBQUFBQUFBQUAygLCgsoCwoLKAsKCziTkpMoBBQB/wEUAR5ZdlEAAABXSURBVP8BFAH/
        ARQB/wEUAJGRkZGRkZGRkZGRkZGRkZGRAXgB/wE7Af8BSwH/ATsB/wE7AhQUFBQUFBQUFBQUFBQUFBQUA1oLCgsoCwoLsAsK
        CygLCgsoqvcl6LTlUekAAAAASUVORK5CYII=
        """
    // grayAlphaDynamic: 61x37 type 4, dynamic (first block BTYPE 2), 1 IDAT, 653 bytes
    static let grayAlphaDynamic = """
        iVBORw0KGgoAAAANSUhEUgAAAD0AAAAlCAQAAABb7imUAAAAAXNSR0IArs4c6QAAACJpQ0NQZmFrZQAAeJzLyy9RKEpNzMmp
        VEhUKCjKT8vMSQUATukHjd2CmmgAAAAKZVhJZk1NACoAAAAIAAC+oPKvAAAB20lEQVR42s2Xv0sCYRjH3/fuoPDA6W0NFI0L
        jCCIrFMUigZddA2UAgUbaqpQgvZIh7zGAp3imiR0q6Gg0voHCnQSA5tqioZ++OCroXW0+L7X+/Lh4e6zvfflnudFKIbjgCfn
        zQPJaqoGFJXSOMDOY5LE+PMTY1WlNdj7HFRZeYGYtkRlSZYtFllWFFoL7epWNDlr0b7fD9xLhLQPgDhopQfTfc/Mo/1rszZO
        Vns//49YqKy8QBx0Gy1mXlwivTEoGMRi8L4bMwetKvk9JoP3qOypeAGSHEkBoWK4BKRRBgPsPPZtIJOWcPF8+QK8uz4mgNnE
        3CqwWdwqAey8SBb7YuGWNUtW1gxjMzAvEYNYsK+If7Ps+lCRd7PseOFo/XANWLEv2wDno6MBPJzc6wA7Lwp3N9GryE0U6w2p
        LjakSd+efde2Z7+K6P5jn+6vb7PyEv9m2Y1ZjuRHgGqoFgaU9HgGiJXjFYCdx63xjHOz/Hs2Y95MxZnTZuAp0AwsuOZdwJjV
        aQWGE0MJABwbL8UPeB90xyP+zbLjsZL+d1cA9iObOBXj3Sw7Xnq7bc8M5zvtekZniGlaGXoTmiX1rbTxbpb/4aYZG+V1s+z3
        xrMZ82aKXl1mbdxKm0n/8C8eShjUdG26igAAABx0RVh0Q29tbWVudABhZnRlciB0aGUgaW1hZ2UgZGF0Yfg5SPQAAAAASUVO
        RK5CYII=
        """
    // rgbKeyed: 48x30 type 2, dynamic (first block BTYPE 2), 1 IDAT, 643 bytes
    static let rgbKeyed = """
        iVBORw0KGgoAAAANSUhEUgAAADAAAAAeCAIAAADlxgqWAAAABnRSTlMAKQCNAAE8nfKhAAACOElEQVR42s2WP2gTURzH37s7
        UN5Bp5eliNqSyCtEC4J49hJSaOnQLMniUKgoJBDxz6SSWHDqIk0Hk7pZSKYap1BzuuigUk100UmFRIRYQQf/TqI2vvKD3Etp
        iMuPu+P48OX4DHfJl8eXkFSdphvASIlHywFgtpnItZLAmsg7Y8tAbJ/ybJNS2ul0JG077ua4rTx3c9y2UX2N86By/8+F6+ti
        jpumyRiTFEK4uepmS4iiaRYYK247VVTfkC/V/bnkN7jZVjLvkxF8cuPpb1/dVPZ816L1LaP6HMHXfNZprs/xmV1LVxWWaRYZ
        K0j2KyOG31PqoJJtPrikGD6pR0qNaBkoD8lArgVM1ETSGQPmSWqZpoHYPo1dqhA/Xdqjbwcefz8I/Bs+t3X4PPBEZm3i7G3g
        5Vr7ivMBiO3rfCarlE45VS1hFk1WYJK9ZRSovix1UCmXPfi0RfaJHyaH6lPZc88nh+prqxfHb104Ajwz+vP0yA9g6OP94OY9
        4Ns7C28qV4HYvq69CD07tbUx/0eSVqxNY19bH5Ycj51cGp24PmJJbswvVibfr8XeSbYXhlF9ww+To6fUJZ4tB3LAZqLWSjpA
        kSdy4AJT9Ui6EQVi+1T23PPJsWNTez85VF8/vu58ml3/PHtXcjp8cyq8Ajw09DU09AW4N/NqT+YlEEw830ivPPH8b1J94ofJ
        ofrbPR/41r2nahzV13zWaa4fTe33fHKovvHr+VJ3rT285i63B8qKO0ZedzO2/w+m3P8XUQTguQAAAABJRU5ErkJggg==
        """
    // grayKeyed: 12x10 type 0, fixed (first block BTYPE 1), 1 IDAT, 134 bytes
    static let grayKeyed = """
        iVBORw0KGgoAAAANSUhEUgAAAAwAAAAKCAAAAAClR+AmAAAAAnRSTlMAkfGbbuoAAAA/SURBVHgBY2BgZGC0sbWxraisqGQU
        YfzPaA3FTCJIgFmDm4sbhllAymCYYSISYKyAavbGMCAKqnkDzAAVqFIABFEcRBVmoqMAAAAASUVORK5CYII=
        """
}

// MARK: - Chunk-level helpers

/// One chunk of a PNG, for tests that take files apart and put them back together.
struct Chunk: Equatable {
    var type: String
    var data: [UInt8]

    /// Serialized with a correct CRC.
    var bytes: [UInt8] {
        let typeBytes = Array(type.utf8)
        let crc = CRC32.update(CRC32.checksum(typeBytes), data)
        return be32(UInt32(data.count)) + typeBytes + data + be32(crc)
    }
}

func be32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

/// The chunks of a well-formed PNG (no CRC checking: the decoder's job, not this helper's).
func chunks(of png: [UInt8]) -> [Chunk] {
    var out: [Chunk] = []
    var at = 8
    while at + 8 <= png.count {
        let length = Int(png[at]) << 24 | Int(png[at + 1]) << 16 | Int(png[at + 2]) << 8 | Int(png[at + 3])
        let type = String(decoding: png[(at + 4)..<(at + 8)], as: UTF8.self)
        out.append(Chunk(type: type, data: Array(png[(at + 8)..<(at + 8 + length)])))
        at += 12 + length
    }
    return out
}

/// A PNG made of `chunks`, every CRC correct.
func assemble(_ chunks: [Chunk]) -> [UInt8] {
    pngSignature + chunks.flatMap(\.bytes)
}

/// IHDR data for an 8-bit, non-interlaced image unless overridden.
func ihdr(width: UInt32, height: UInt32, depth: UInt8 = 8, colorType: UInt8 = 6,
          compression: UInt8 = 0, filter: UInt8 = 0, interlace: UInt8 = 0) -> Chunk {
    Chunk(type: "IHDR", data: be32(width) + be32(height) + [depth, colorType, compression, filter, interlace])
}

/// A zlib stream around raw deflate bytes, with the Adler-32 of `content`.
func zlibWrap(_ deflate: [UInt8], content: [UInt8]) -> [UInt8] {
    [0x78, 0x01] + deflate + be32(Adler32.checksum(content))
}

/// Raw deflate bytes built bit by bit (LSB first), for hand-made malformed streams.
func deflateBits(_ build: (inout BitWriter) -> Void) -> [UInt8] {
    var writer = BitWriter()
    build(&writer)
    writer.flushToByte()
    return writer.bytes
}

/// FNV-1a 64 — a dependency-free fingerprint for pinning decoded pixels.
func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash &*= 0x0000_0100_0000_01B3
    }
    return hash
}

/// Repo root, from this file's path (`<root>/Tests/TkzPNGTests/…`). Symlinks are resolved so a
/// scratch package that links the test directory still finds the repository's files.
func repoRoot(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// Deterministic pseudo-random bytes (xorshift64*), so a fuzz failure reproduces exactly.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}
