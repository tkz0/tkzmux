// The decoder's contract on hostile input: every malformed file throws a `PNGError`, and nothing
// traps (an overflow or out-of-range index would take the whole test process down, so a suite that
// finishes is itself the "no trap" evidence).
//
// The corpus has three parts: hand-made files that each break one rule, systematic damage to valid
// files (every truncation, every single-bit flip — with and without the CRC repaired, so damage
// reaches inflate instead of stopping at the chunk check), and seeded random mutation.

import Testing
@testable import TkzPNG

@Suite("PNG decoding of malformed input")
struct MalformedInputTests {

    // MARK: - Builders

    /// A greyscale PNG of `width`×1 around `zlib`; the decoder expects `width + 1` filtered bytes.
    private func grayPNG(width: UInt32 = 1, zlib: [UInt8]) -> [UInt8] {
        assemble([ihdr(width: width, height: 1, colorType: 0), Chunk(type: "IDAT", data: zlib), Chunk(type: "IEND", data: [])])
    }

    /// Writes a fixed-Huffman literal/length symbol (RFC 1951 §3.2.6), MSB-first code into the
    /// LSB-first stream.
    private func fixedSymbol(_ symbol: Int, _ writer: inout BitWriter) {
        let (code, length): (Int, Int) = switch symbol {
        case 0..<144: (0x30 + symbol, 8)
        case 144..<256: (0x190 + symbol - 144, 9)
        case 256..<280: (symbol - 256, 7)
        default: (0xC0 + symbol - 280, 8)
        }
        writeCode(code, length, &writer)
    }

    private func writeCode(_ code: Int, _ length: Int, _ writer: inout BitWriter) {
        var reversed = 0
        for bit in 0..<length where code & (1 << bit) != 0 { reversed |= 1 << (length - 1 - bit) }
        writer.write(UInt32(reversed), bits: length)
    }

    /// Dynamic block header whose code-length code gives symbols 0, 16, 17, 18 two-bit codes
    /// (canonical: 0 → 00, 16 → 01, 17 → 10, 18 → 11), with HLIT = 257 and HDIST = 1.
    private func dynamicPrefix(_ writer: inout BitWriter) {
        writer.write(1, bits: 1)  // BFINAL
        writer.write(2, bits: 2)  // dynamic
        writer.write(0, bits: 5)  // HLIT 257
        writer.write(0, bits: 5)  // HDIST 1
        writer.write(0, bits: 4)  // HCLEN 4: lengths for 16, 17, 18, 0
        for _ in 0..<4 { writer.write(2, bits: 3) }
    }

    private func expectThrows(_ bytes: [UInt8], _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: PNGError.self, comment, sourceLocation: sourceLocation) { try PNG.decode(bytes) }
    }

    // MARK: - One broken rule per file

    @Test("container damage: signature, IHDR, chunk order and unsupported variants")
    func container() throws {
        let valid = try PNG.encode([1, 2, 3, 4], width: 1, height: 1)
        let parts = chunks(of: valid)
        let idat = parts[1], iend = parts[2]
        #expect(try PNG.decode(valid).pixels == [1, 2, 3, 4])

        #expect(throws: PNGError.truncated) { try PNG.decode([]) }
        #expect(throws: PNGError.truncated) { try PNG.decode(Array(pngSignature.prefix(5))) }
        #expect(throws: PNGError.notPNG) { try PNG.decode(Array("GIF89a and then some".utf8)) }
        #expect(throws: PNGError.truncated) { try PNG.decode(pngSignature) }

        let rgba1x1 = ihdr(width: 1, height: 1)
        expectThrows(assemble([Chunk(type: "IHDR", data: Array(rgba1x1.data.prefix(12))), idat, iend]), "short IHDR")
        expectThrows(assemble([ihdr(width: 0, height: 1), idat, iend]), "zero width")
        expectThrows(assemble([ihdr(width: 1, height: 0), idat, iend]), "zero height")
        expectThrows(assemble([ihdr(width: 0x8000_0000, height: 1), idat, iend]), "width ≥ 2^31")
        expectThrows(assemble([ihdr(width: 1, height: 1, colorType: 5), idat, iend]), "colour type 5")
        expectThrows(assemble([ihdr(width: 1, height: 1, compression: 1), idat, iend]), "compression method")
        expectThrows(assemble([ihdr(width: 1, height: 1, filter: 1), idat, iend]), "filter method")
        expectThrows(assemble([ihdr(width: 1, height: 1, interlace: 2), idat, iend]), "interlace method")
        #expect(throws: PNGError.unsupported("bit depth 16")) {
            try PNG.decode(assemble([ihdr(width: 1, height: 1, depth: 16), idat, iend]))
        }
        #expect(throws: PNGError.unsupported("palette images")) {
            try PNG.decode(assemble([ihdr(width: 1, height: 1, colorType: 3), idat, iend]))
        }
        #expect(throws: PNGError.unsupported("interlaced images")) {
            try PNG.decode(assemble([ihdr(width: 1, height: 1, interlace: 1), idat, iend]))
        }

        expectThrows(assemble([idat, rgba1x1, iend]), "IDAT before IHDR")
        expectThrows(assemble([rgba1x1, rgba1x1, idat, iend]), "two IHDRs")
        expectThrows(assemble([rgba1x1, iend]), "no IDAT")
        expectThrows(assemble([rgba1x1, idat]), "no IEND")
        let split = Chunk(type: "IDAT", data: Array(idat.data.prefix(3)))
        let rest = Chunk(type: "IDAT", data: Array(idat.data.dropFirst(3)))
        #expect(try PNG.decode(assemble([rgba1x1, split, rest, iend])).pixels == [1, 2, 3, 4])
        expectThrows(assemble([rgba1x1, split, Chunk(type: "tEXt", data: Array("k\0v".utf8)), rest, iend]),
                     "IDATs not consecutive")
        expectThrows(assemble([rgba1x1, Chunk(type: "ABCD", data: []), idat, iend]), "unknown critical chunk")
        #expect(try PNG.decode(assemble([rgba1x1, Chunk(type: "abCD", data: [9]), idat, iend])).pixels == [1, 2, 3, 4])
        #expect(try PNG.decode(assemble([rgba1x1, Chunk(type: "PLTE", data: [0, 0, 0]), idat, iend])).pixels == [1, 2, 3, 4])

        let grayIDAT = chunks(of: try PNG.encode([7], width: 1, height: 1, colorType: .gray))[1]
        let gray1x1 = ihdr(width: 1, height: 1, colorType: 0)
        expectThrows(assemble([gray1x1, Chunk(type: "PLTE", data: [0, 0, 0]), grayIDAT, iend]), "PLTE in greyscale")
        expectThrows(assemble([rgba1x1, Chunk(type: "tRNS", data: [0, 0]), idat, iend]), "tRNS with alpha")
        expectThrows(assemble([gray1x1, Chunk(type: "tRNS", data: [0]), grayIDAT, iend]), "short tRNS")
        expectThrows(assemble([gray1x1, grayIDAT, Chunk(type: "tRNS", data: [0, 7]), iend]), "tRNS after IDAT")
        #expect(try PNG.decode(assemble([gray1x1, Chunk(type: "tRNS", data: [0, 7]), grayIDAT, iend])).pixels
                == [7, 7, 7, 0])

        var badCRC = valid
        badCRC[badCRC.count - 1] ^= 1
        #expect(throws: PNGError.checksumMismatch("CRC-32 of chunk IEND")) { try PNG.decode(badCRC) }
        var hugeLength = valid
        hugeLength.replaceSubrange(33..<37, with: [0xFF, 0xFF, 0xFF, 0xF0])  // the IDAT's length field
        expectThrows(hugeLength, "chunk length over 2^31")
    }

    @Test("size limits are enforced before anything is allocated")
    func limits() throws {
        let tiny = chunks(of: try PNG.encode([1, 2, 3, 4], width: 1, height: 1))
        // 16384² RGBA is exactly the default ceiling; with one byte of data it cannot be real.
        #expect(throws: PNGError.truncated) {
            try PNG.decode(assemble([ihdr(width: 16384, height: 16384), tiny[1], tiny[2]]))
        }
        #expect(throws: PNGError.tooLarge(width: 16385, height: 16384)) {
            try PNG.decode(assemble([ihdr(width: 16385, height: 16384), tiny[1], tiny[2]]))
        }
        #expect(throws: PNGError.tooLarge(width: 0x7FFF_FFFF, height: 0x7FFF_FFFF)) {
            try PNG.decode(assemble([ihdr(width: 0x7FFF_FFFF, height: 0x7FFF_FFFF), tiny[1], tiny[2]]))
        }
        // A caller that lifts the ceiling entirely still gets an error, not an overflow trap, when
        // the derived buffer sizes cannot be represented.
        #expect(throws: PNGError.tooLarge(width: 0x7FFF_FFFF, height: 0x7FFF_FFFF)) {
            try PNG.decode(assemble([ihdr(width: 0x7FFF_FFFF, height: 0x7FFF_FFFF), tiny[1], tiny[2]]),
                           maxPixels: .max)
        }
        #expect(throws: PNGError.truncated) {
            try PNG.decode(assemble([ihdr(width: 0x7FFF_FFFF, height: 0x10000), tiny[1], tiny[2]]),
                           maxPixels: .max)
        }
        #expect(throws: PNGError.tooLarge(width: 2, height: 1)) {
            try PNG.decode(try PNG.encode([UInt8](repeating: 0, count: 8), width: 2, height: 1), maxPixels: 1)
        }
    }

    @Test("zlib and deflate damage, one rule at a time")
    func deflate() throws {
        let content: [UInt8] = [0, 42]  // filter byte + one grey pixel
        let stored = deflateBits {
            $0.write(1, bits: 1); $0.write(0, bits: 2); $0.flushToByte()
        } + [2, 0, 0xFD, 0xFF] + content
        #expect(try PNG.decode(grayPNG(zlib: zlibWrap(stored, content: content))).pixels == [42, 42, 42, 255])

        // zlib header.
        expectThrows(grayPNG(zlib: [0x78]), "one-byte zlib stream")
        expectThrows(grayPNG(zlib: [0x78, 0x00] + stored + be32(Adler32.checksum(content))), "FCHECK")
        expectThrows(grayPNG(zlib: [0x77, 0x01] + stored + be32(Adler32.checksum(content))), "CM 7")
        expectThrows(grayPNG(zlib: [0x88, 0x01] + stored + be32(Adler32.checksum(content))), "CINFO 8")
        let dictFlag = (0..<256).first { flg in flg & 0x20 != 0 && (0x78 << 8 | flg) % 31 == 0 }!
        expectThrows(grayPNG(zlib: [0x78, UInt8(dictFlag)] + stored + be32(Adler32.checksum(content))), "FDICT")
        expectThrows(grayPNG(zlib: zlibWrap(stored, content: [0, 43])), "Adler-32")
        expectThrows(grayPNG(zlib: Array(zlibWrap(stored, content: content).dropLast())), "Adler-32 cut short")

        // Sizes against IHDR.
        expectThrows(grayPNG(width: 2, zlib: zlibWrap(stored, content: content)), "too little data")
        let three = deflateBits { $0.write(1, bits: 1); $0.write(0, bits: 2); $0.flushToByte() } + [3, 0, 0xFC, 0xFF, 0, 1, 2]
        expectThrows(grayPNG(zlib: zlibWrap(three, content: [0, 1, 2])), "too much data (stored)")
        let fixedLong = deflateBits { w in
            w.write(1, bits: 1); w.write(1, bits: 2)
            for byte in [0, 1, 2] { fixedSymbol(byte, &w) }
            fixedSymbol(256, &w)
        }
        expectThrows(grayPNG(zlib: zlibWrap(fixedLong, content: [0, 1, 2])), "too much data (fixed)")
        let matchLong = deflateBits { w in
            w.write(1, bits: 1); w.write(1, bits: 2)
            fixedSymbol(0, &w)
            fixedSymbol(257, &w); w.write(0, bits: 5)  // length 3, distance 1
            fixedSymbol(256, &w)
        }
        expectThrows(grayPNG(zlib: zlibWrap(matchLong, content: [0, 0, 0, 0])), "too much data (match)")

        // Block-level damage.
        expectThrows(grayPNG(zlib: zlibWrap(deflateBits { $0.write(1, bits: 1); $0.write(3, bits: 2) }, content: content)),
                     "reserved block type")
        let badNLEN = deflateBits { $0.write(1, bits: 1); $0.write(0, bits: 2); $0.flushToByte() } + [2, 0, 0, 0] + content
        expectThrows(grayPNG(zlib: zlibWrap(badNLEN, content: content)), "stored LEN/NLEN")
        let shortStored = deflateBits { $0.write(1, bits: 1); $0.write(0, bits: 2); $0.flushToByte() } + [9, 0, 0xF6, 0xFF] + content
        expectThrows(grayPNG(zlib: zlibWrap(shortStored, content: content)), "stored block past the input")
        let notFinal = deflateBits { $0.write(0, bits: 1); $0.write(0, bits: 2); $0.flushToByte() } + [2, 0, 0xFD, 0xFF] + content
        expectThrows(grayPNG(zlib: zlibWrap(notFinal, content: content)), "no final block")

        let farBack = deflateBits { w in
            w.write(1, bits: 1); w.write(1, bits: 2)
            fixedSymbol(0, &w)
            fixedSymbol(257, &w); w.write(1, bits: 5)  // length 3, distance 2: only 1 byte exists
            fixedSymbol(256, &w)
        }
        expectThrows(grayPNG(width: 3, zlib: zlibWrap(farBack, content: [0, 0, 0, 0])), "distance before the start")
        for (symbol, label) in [(286, "length symbol 286"), (287, "length symbol 287")] {
            let reserved = deflateBits { w in
                w.write(1, bits: 1); w.write(1, bits: 2)
                fixedSymbol(0, &w); fixedSymbol(symbol, &w); w.write(0, bits: 5); fixedSymbol(256, &w)
            }
            expectThrows(grayPNG(width: 3, zlib: zlibWrap(reserved, content: [0, 0, 0, 0])), Comment(rawValue: label))
        }
        let reservedDistance = deflateBits { w in
            w.write(1, bits: 1); w.write(1, bits: 2)
            fixedSymbol(0, &w); fixedSymbol(257, &w); writeCode(30, 5, &w); fixedSymbol(256, &w)
        }
        expectThrows(grayPNG(width: 3, zlib: zlibWrap(reservedDistance, content: [0, 0, 0, 0])), "distance symbol 30")
        let noEndOfBlock = deflateBits { w in
            w.write(1, bits: 1); w.write(1, bits: 2)
            fixedSymbol(0, &w); fixedSymbol(42, &w)
        }
        expectThrows(grayPNG(zlib: zlibWrap(noEndOfBlock, content: content)), "stream ends without end-of-block")

        // Dynamic-table damage.
        let overSubscribed = deflateBits { w in
            w.write(1, bits: 1); w.write(2, bits: 2)
            w.write(0, bits: 5); w.write(0, bits: 5); w.write(15, bits: 4)
            for _ in 0..<19 { w.write(1, bits: 3) }  // 19 one-bit codes
        }
        expectThrows(grayPNG(zlib: zlibWrap(overSubscribed, content: content)), "over-subscribed code-length code")
        let repeatFirst = deflateBits { w in
            dynamicPrefix(&w)
            writeCode(0b01, 2, &w); w.write(0, bits: 2)  // 16 with nothing before it
        }
        expectThrows(grayPNG(zlib: zlibWrap(repeatFirst, content: content)), "repeat with no previous length")
        let overrun = deflateBits { w in
            dynamicPrefix(&w)
            writeCode(0b11, 2, &w); w.write(127, bits: 7)  // 138 zeros
            writeCode(0b11, 2, &w); w.write(127, bits: 7)  // 138 more: 276 > 258
        }
        expectThrows(grayPNG(zlib: zlibWrap(overrun, content: content)), "code lengths overrun HLIT + HDIST")
        let noEOB = deflateBits { w in
            dynamicPrefix(&w)
            writeCode(0b11, 2, &w); w.write(127, bits: 7)  // 138 zeros
            writeCode(0b11, 2, &w); w.write(109, bits: 7)  // 120 zeros: exactly 258, symbol 256 unused
        }
        expectThrows(grayPNG(zlib: zlibWrap(noEOB, content: content)), "no end-of-block code")
        let tooManyCodes = deflateBits { w in
            w.write(1, bits: 1); w.write(2, bits: 2)
            w.write(30, bits: 5)  // HLIT 287
            w.write(0, bits: 5); w.write(0, bits: 4)
        }
        expectThrows(grayPNG(zlib: zlibWrap(tooManyCodes, content: content)), "HLIT over 286")

        // Row filters.
        let badFilter = deflateBits { $0.write(1, bits: 1); $0.write(0, bits: 2); $0.flushToByte() } + [2, 0, 0xFD, 0xFF, 5, 42]
        expectThrows(grayPNG(zlib: zlibWrap(badFilter, content: [5, 42])), "filter type 5")
    }

    // MARK: - Systematic damage to valid files

    private var victims: [(String, [UInt8])] {
        get throws {
            let own = try PNG.encode((0..<(9 * 7 * 4)).map { UInt8(truncatingIfNeeded: $0 * 7) }, width: 9, height: 7)
            return [("zlib dynamic", FixturePNG.cases[0].bytes), ("zlib fixed, keyed", FixturePNG.cases[5].bytes),
                    ("zlib stored", FixturePNG.cases[2].bytes), ("TkzPNG", own)]
        }
    }

    @Test("every truncation of a valid file throws")
    func truncations() throws {
        for (name, file) in try victims {
            for length in 0..<file.count {
                expectThrows(Array(file.prefix(length)), "\(name) cut to \(length) of \(file.count) bytes")
            }
        }
    }

    @Test("every single-bit flip of a valid file throws (the CRC catches it)")
    func bitFlips() throws {
        for (name, file) in try victims {
            for bit in 0..<(file.count * 8) {
                var damaged = file
                damaged[bit / 8] ^= 1 << UInt8(bit % 8)
                expectThrows(damaged, "\(name), bit \(bit) flipped")
            }
        }
    }

    /// With the CRC repaired the damage reaches inflate, and a flipped bit there does not always
    /// make an invalid stream: it can land in padding or ignored header bits, turn one
    /// back-reference into another that copies identical bytes (a distance-4 → 8 copy in a repeating
    /// row), or — once in this corpus — change four bytes by ∓120/±120 in a pattern Adler-32 cannot
    /// see. Those files are *valid*, so the property here is agreement with the reference: for the
    /// three zlib-written fixtures the flips TkzPNG accepts were checked to be bit-for-bit the set
    /// Python's zlib accepts (with the same exact-size and filter-byte checks), and are pinned by
    /// count. Every accepted flip must decode to the original pixels except the one Adler-32 blind
    /// spot, which zlib decodes to the same different pixels.
    @Test("single-bit flips inside the zlib stream, CRC repaired, are rejected exactly where zlib rejects them")
    func zlibBitFlips() throws {
        let zlibAccepts: [String: Int] = ["zlib dynamic": 110, "zlib fixed, keyed": 2, "zlib stored": 5]
        let adlerCollisions: Set<String> = ["zlib dynamic/5417"]
        for (name, file) in try victims {
            let original = try PNG.decode(file)
            let parts = chunks(of: file)
            let header = parts[0]
            let tRNS = parts.filter { $0.type == "tRNS" }
            let stream = parts.filter { $0.type == "IDAT" }.flatMap(\.data)
            var accepted = 0
            for bit in 0..<(stream.count * 8) {
                var damaged = stream
                damaged[bit / 8] ^= 1 << UInt8(bit % 8)
                let png = assemble([header] + tRNS + [Chunk(type: "IDAT", data: damaged), Chunk(type: "IEND", data: [])])
                guard let image = try? PNG.decode(png) else { continue }
                accepted += 1
                if !adlerCollisions.contains("\(name)/\(bit)") {
                    #expect(image == original, "\(name), zlib bit \(bit) flipped: decoded to different pixels")
                }
            }
            if let expected = zlibAccepts[name] {
                #expect(accepted == expected, "\(name): \(accepted) flips accepted, zlib accepts \(expected)")
            } else {
                #expect(accepted * 20 < stream.count * 8, "\(name): \(accepted) flips went unnoticed")
            }
        }
    }

    @Test("random garbage as image data throws")
    func garbageStreams() {
        var generator = SeededGenerator(seed: 0x5EED)
        for trial in 0..<2_000 {
            let length = Int.random(in: 1...300, using: &generator)
            // A valid zlib header half the time, so the garbage reaches inflate.
            var stream = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if trial % 2 == 0 { stream = [0x78, 0x01] + stream }
            let png = assemble([ihdr(width: 16, height: 16), Chunk(type: "IDAT", data: stream), Chunk(type: "IEND", data: [])])
            expectThrows(png, "garbage trial \(trial)")
        }
    }

    @Test("seeded random mutations with repaired CRCs never trap")
    func randomMutations() throws {
        var generator = SeededGenerator(seed: 0xF022)
        var threw = 0, decoded = 0
        for (_, file) in try victims {
            let parts = chunks(of: file)
            for _ in 0..<500 {
                var mutated = parts
                for _ in 0..<Int.random(in: 1...6, using: &generator) {
                    let index = Int.random(in: 0..<mutated.count, using: &generator)
                    guard !mutated[index].data.isEmpty else { continue }
                    let at = Int.random(in: 0..<mutated[index].data.count, using: &generator)
                    switch Int.random(in: 0..<3, using: &generator) {
                    case 0: mutated[index].data[at] ^= UInt8.random(in: 1...255, using: &generator)
                    case 1: mutated[index].data.removeSubrange(at...)
                    default: mutated[index].data.insert(UInt8.random(in: 0...255, using: &generator), at: at)
                    }
                }
                do {
                    let image = try PNG.decode(assemble(mutated))
                    #expect(image.pixels.count == image.width * image.height * 4)
                    decoded += 1
                } catch {
                    threw += 1
                }
            }
        }
        #expect(threw > 0)
        _ = decoded  // mutations confined to ancillary chunks legitimately decode
    }
}
