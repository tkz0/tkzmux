// Inflate (RFC 1951) inside a zlib wrapper (RFC 1950): stored, fixed-Huffman and dynamic-Huffman
// blocks, which is everything a PNG encoder may emit.
//
// ## Built to be fed hostile bytes
//
// A PNG off disk is untrusted input and Swift traps on overflow and out-of-range indexing, so every
// length here is checked before it is used rather than relied on to be sane:
//
//   * The output size is fixed up front (a PNG's IHDR says exactly how many filtered bytes the image
//     needs). Producing one byte more, or ending one byte short, is an error — so a hostile stream
//     can never make the decoder allocate more than the header promised, and the header itself is
//     bounded by the caller before anything is allocated.
//   * A back-reference farther than the bytes produced so far, a length or distance symbol the format
//     reserves (286/287, 30/31), an over-subscribed code, a repeat code with nothing to repeat and a
//     code-length run past the declared table are all errors.
//   * Running out of input mid-block is `PNGError.truncated`.
//
// ## Huffman decoding
//
// Each table is canonical (RFC 1951 §3.2.2). Codes up to `fastBits` long resolve with one lookup in
// a table indexed by the next `fastBits` input bits (deflate packs Huffman codes MSB-first into an
// LSB-first stream, so the table is filled at bit-reversed indices). Longer codes — rare in practice
// — fall back to walking the code lengths one bit at a time, which needs only the per-length counts
// and the symbols in canonical order.

/// A canonical Huffman code, ready for decoding.
struct HuffmanTable {
    static let fastBits = 10
    static let maxBits = 15

    /// Indexed by the next `fastBits` stream bits: `length << 9 | symbol`, or 0 when the code is
    /// longer than `fastBits` (or no code starts with those bits).
    var fast: [UInt16]
    /// `counts[n]` is the number of codes of length `n`.
    var counts: [Int]
    /// Symbols ordered by (length, symbol), i.e. by canonical code.
    var symbols: [UInt16]

    /// Builds the code for `lengths` (one per symbol, 0 = unused). Throws on an over-subscribed set
    /// of lengths. An incomplete set is accepted, as zlib accepts it; a stream that then uses one of
    /// the missing codes fails when it does.
    init(lengths: UnsafeBufferPointer<UInt8>) throws {
        var counts = [Int](repeating: 0, count: Self.maxBits + 1)
        for length in lengths { counts[Int(length)] += 1 }
        counts[0] = 0

        // Over-subscription: at each length, no more codes than the remaining code space.
        var left = 1
        for length in 1...Self.maxBits {
            left <<= 1
            left -= counts[length]
            if left < 0 { throw PNGError.corruptData("over-subscribed Huffman code") }
        }

        // First canonical code of each length, and each length's start in `symbols`.
        var nextCode = [Int](repeating: 0, count: Self.maxBits + 2)
        var offsets = [Int](repeating: 0, count: Self.maxBits + 2)
        var code = 0
        for length in 1...Self.maxBits {
            code = (code + counts[length - 1]) << 1
            nextCode[length] = code
            offsets[length + 1] = offsets[length] + counts[length]
        }

        var symbols = [UInt16](repeating: 0, count: offsets[Self.maxBits + 1])
        var fast = [UInt16](repeating: 0, count: 1 << Self.fastBits)
        for (symbol, rawLength) in lengths.enumerated() {
            let length = Int(rawLength)
            guard length > 0 else { continue }
            symbols[offsets[length]] = UInt16(symbol)
            offsets[length] += 1
            let canonical = nextCode[length]
            nextCode[length] += 1
            guard length <= Self.fastBits else { continue }
            // Reverse the code into stream order, then fill every index whose low bits match.
            var reversed = 0
            for bit in 0..<length where canonical & (1 << bit) != 0 {
                reversed |= 1 << (length - 1 - bit)
            }
            let entry = UInt16(length << 9 | symbol)
            var index = reversed
            while index < fast.count {
                fast[index] = entry
                index += 1 << length
            }
        }
        self.fast = fast
        self.counts = counts
        self.symbols = symbols
    }

    /// The fixed literal/length code (RFC 1951 §3.2.6).
    static let fixedLiteral: HuffmanTable = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for symbol in 144..<256 { lengths[symbol] = 9 }
        for symbol in 256..<280 { lengths[symbol] = 7 }
        return lengths.withUnsafeBufferPointer { try! HuffmanTable(lengths: $0) }
    }()

    /// The fixed distance code: 30 usable 5-bit codes (and the two reserved ones, which decode to
    /// symbols that are then rejected).
    static let fixedDistance: HuffmanTable = {
        let lengths = [UInt8](repeating: 5, count: 32)
        return lengths.withUnsafeBufferPointer { try! HuffmanTable(lengths: $0) }
    }()
}

/// RFC 1951 length and distance bases and extra-bit counts, indexed by `symbol - 257` and by the
/// distance symbol.
enum DeflateTables {
    static let lengthBase: [UInt16] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    static let lengthExtra: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    static let distanceBase: [UInt16] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ]
    static let distanceExtra: [UInt8] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
    /// The order code-length code lengths are transmitted in (RFC 1951 §3.2.7).
    static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
}

/// LSB-first bit reader over the compressed bytes, with a 64-bit reservoir.
private struct BitReader {
    let input: UnsafeRawBufferPointer
    var position = 0
    var buffer: UInt64 = 0
    var count = 0

    init(_ input: UnsafeRawBufferPointer) { self.input = input }

    /// Tops the reservoir up to at least 57 bits, or with whatever input remains.
    @inline(__always)
    mutating func refill() {
        while count <= 56, position < input.count {
            buffer |= UInt64(input[position]) << UInt64(count)
            position += 1
            count += 8
        }
    }

    /// The next `n` bits (n ≤ 32), consumed.
    @inline(__always)
    mutating func bits(_ n: Int) throws -> Int {
        if count < n {
            refill()
            if count < n { throw PNGError.truncated }
        }
        let value = Int(truncatingIfNeeded: buffer & ((1 << UInt64(n)) - 1))
        buffer >>= UInt64(n)
        count -= n
        return value
    }

    /// Drops the bits up to the next byte boundary.
    mutating func alignToByte() {
        let drop = count & 7
        buffer >>= UInt64(drop)
        count -= drop
    }

    /// Hands the whole bytes still in the reservoir back to the input, so the caller can read
    /// byte-aligned data (a stored block, the Adler-32 trailer) straight from `input`.
    mutating func returnWholeBytes() {
        alignToByte()
        position -= count / 8
        buffer = 0
        count = 0
    }

    @inline(__always)
    mutating func decode(_ table: HuffmanTable) throws -> Int {
        if count < HuffmanTable.maxBits { refill() }
        let entry = Int(table.fast[Int(truncatingIfNeeded: buffer) & ((1 << HuffmanTable.fastBits) - 1)])
        let length = entry >> 9
        if length != 0, length <= count {
            buffer >>= UInt64(length)
            count -= length
            return entry & 0x1FF
        }
        // Long code (or the stream is nearly out): walk the canonical code one bit at a time.
        var code = 0, first = 0, index = 0
        for length in 1...HuffmanTable.maxBits {
            code |= try bits(1)
            let n = table.counts[length]
            if code - first < n { return Int(table.symbols[index + code - first]) }
            index += n
            first = (first + n) << 1
            code <<= 1
        }
        throw PNGError.corruptData("invalid Huffman code")
    }
}

enum Inflate {
    /// Inflates the zlib stream `input` into exactly `outputSize` bytes and checks its Adler-32.
    /// Trailing bytes after the Adler-32 are ignored, as libpng ignores them.
    static func zlibDecompress(_ input: UnsafeRawBufferPointer, outputSize: Int) throws -> [UInt8] {
        guard input.count >= 2 else { throw PNGError.truncated }
        let cmf = Int(input[0]), flg = Int(input[1])
        guard cmf & 0x0F == 8, cmf >> 4 <= 7 else { throw PNGError.corruptData("not a deflate zlib stream") }
        guard (cmf << 8 | flg) % 31 == 0 else { throw PNGError.corruptData("bad zlib header check") }
        guard flg & 0x20 == 0 else { throw PNGError.corruptData("zlib preset dictionary") }

        var output = [UInt8](repeating: 0, count: outputSize)
        let trailer = try output.withUnsafeMutableBufferPointer { out throws -> Int in
            let body = UnsafeRawBufferPointer(rebasing: input[2...])
            var reader = BitReader(body)
            let produced = try inflate(&reader, into: out)
            guard produced == outputSize else { throw PNGError.corruptData("image data is too short") }
            reader.returnWholeBytes()
            return 2 + reader.position
        }
        guard input.count - trailer >= 4 else { throw PNGError.truncated }
        let stored = UInt32(input[trailer]) << 24 | UInt32(input[trailer + 1]) << 16
            | UInt32(input[trailer + 2]) << 8 | UInt32(input[trailer + 3])
        guard stored == Adler32.checksum(output) else { throw PNGError.checksumMismatch("Adler-32") }
        return output
    }

    /// Inflates raw deflate blocks into `out`; returns the bytes written. Fails rather than write
    /// past `out`.
    private static func inflate(
        _ reader: inout BitReader, into out: UnsafeMutableBufferPointer<UInt8>
    ) throws -> Int {
        var written = 0
        var final = false
        while !final {
            final = try reader.bits(1) == 1
            switch try reader.bits(2) {
            case 0:
                reader.returnWholeBytes()
                let input = reader.input
                var p = reader.position
                guard input.count - p >= 4 else { throw PNGError.truncated }
                let length = Int(input[p]) | Int(input[p + 1]) << 8
                let complement = Int(input[p + 2]) | Int(input[p + 3]) << 8
                guard length ^ 0xFFFF == complement else { throw PNGError.corruptData("stored block length check") }
                p += 4
                guard input.count - p >= length else { throw PNGError.truncated }
                guard out.count - written >= length else { throw PNGError.corruptData("image data is too long") }
                if length > 0 {
                    UnsafeMutableRawBufferPointer(out).baseAddress!.advanced(by: written)
                        .copyMemory(from: input.baseAddress!.advanced(by: p), byteCount: length)
                }
                written += length
                reader.position = p + length
            case 1:
                written = try inflateBlock(
                    &reader, literal: HuffmanTable.fixedLiteral, distance: HuffmanTable.fixedDistance,
                    into: out, at: written)
            case 2:
                let (literal, distance) = try readDynamicTables(&reader)
                written = try inflateBlock(&reader, literal: literal, distance: distance, into: out, at: written)
            default:
                throw PNGError.corruptData("reserved deflate block type")
            }
        }
        return written
    }

    private static func readDynamicTables(
        _ reader: inout BitReader
    ) throws -> (HuffmanTable, HuffmanTable) {
        let literalCount = try reader.bits(5) + 257
        let distanceCount = try reader.bits(5) + 1
        let codeLengthCount = try reader.bits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw PNGError.corruptData("too many Huffman codes") }

        var codeLengthLengths = [UInt8](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengthLengths[DeflateTables.codeLengthOrder[index]] = UInt8(try reader.bits(3))
        }
        let codeLengthTable = try codeLengthLengths.withUnsafeBufferPointer {
            buffer in try HuffmanTable(lengths: buffer)
        }

        let total = literalCount + distanceCount
        var lengths = [UInt8](repeating: 0, count: total)
        var index = 0
        while index < total {
            let symbol = try reader.decode(codeLengthTable)
            var repeatValue: UInt8 = 0
            var repeatCount: Int
            switch symbol {
            case 0...15:
                lengths[index] = UInt8(symbol)
                index += 1
                continue
            case 16:
                guard index > 0 else { throw PNGError.corruptData("length repeat with no previous length") }
                repeatValue = lengths[index - 1]
                repeatCount = 3 + (try reader.bits(2))
            case 17:
                repeatCount = 3 + (try reader.bits(3))
            default:
                repeatCount = 11 + (try reader.bits(7))
            }
            guard total - index >= repeatCount else { throw PNGError.corruptData("code lengths overrun the table") }
            for _ in 0..<repeatCount {
                lengths[index] = repeatValue
                index += 1
            }
        }
        guard lengths[256] != 0 else { throw PNGError.corruptData("no end-of-block code") }

        return try lengths.withUnsafeBufferPointer { all in
            let literal = try HuffmanTable(lengths: UnsafeBufferPointer(rebasing: all[0..<literalCount]))
            let distance = try HuffmanTable(lengths: UnsafeBufferPointer(rebasing: all[literalCount...]))
            return (literal, distance)
        }
    }

    /// Decodes one Huffman block into `out` starting at `start`; returns the new write position.
    private static func inflateBlock(
        _ reader: inout BitReader, literal: HuffmanTable, distance: HuffmanTable,
        into out: UnsafeMutableBufferPointer<UInt8>, at start: Int
    ) throws -> Int {
        var written = start
        let capacity = out.count
        while true {
            let symbol = try reader.decode(literal)
            if symbol < 256 {
                guard written < capacity else { throw PNGError.corruptData("image data is too long") }
                out[written] = UInt8(truncatingIfNeeded: symbol)
                written += 1
                continue
            }
            if symbol == 256 { return written }
            let lengthIndex = symbol - 257
            guard lengthIndex < 29 else { throw PNGError.corruptData("reserved length symbol") }
            let length = Int(DeflateTables.lengthBase[lengthIndex])
                + (try reader.bits(Int(DeflateTables.lengthExtra[lengthIndex])))
            let distanceSymbol = try reader.decode(distance)
            guard distanceSymbol < 30 else { throw PNGError.corruptData("reserved distance symbol") }
            let back = Int(DeflateTables.distanceBase[distanceSymbol])
                + (try reader.bits(Int(DeflateTables.distanceExtra[distanceSymbol])))
            guard back <= written else { throw PNGError.corruptData("back-reference before the start") }
            guard capacity - written >= length else { throw PNGError.corruptData("image data is too long") }
            // Byte by byte on purpose: an overlapping copy (back < length) must see its own output.
            var from = written - back
            let end = written + length
            while written < end {
                out[written] = out[from]
                written += 1
                from += 1
            }
        }
    }
}
