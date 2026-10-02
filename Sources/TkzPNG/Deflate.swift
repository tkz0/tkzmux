// Deflate (RFC 1951) in a zlib wrapper (RFC 1950), tuned for what tkzmux encodes: rendered terminal
// frames and glyph atlases — large flat areas, repeated rows and repeated glyphs.
//
//   * **Greedy LZ77** over a 32 KiB window with hash chains (3-byte hash, at most `maxChain`
//     candidates per position, stop at the first 258-byte match). No lazy matching: on terminal
//     frames it buys a few percent of size for a large share of the time.
//   * **Fixed-Huffman blocks** only — no code-table construction, so the output is a single pass.
//   * **Stored fallback**: each block covers at most 65 535 input bytes, and whichever of fixed and
//     stored is smaller for that span is written. Noise therefore costs ~0.01 % over its raw size
//     rather than the ~12 % that 9-bit fixed literals would add.

enum Deflate {
    static let windowSize = 1 << 15
    static let maxMatch = 258
    static let minMatch = 3
    /// Hash-chain candidates examined per position.
    static let maxChain = 48
    private static let hashBits = 15
    /// Largest input span of one block, so that the stored alternative is a single stored block.
    private static let maxBlockSpan = 0xFFFF

    /// The zlib stream (`78 01`, deflate data, Adler-32) for `input`.
    static func zlibCompress(_ input: UnsafeRawBufferPointer) -> [UInt8] {
        var writer = BitWriter()
        writer.reserve(input.count / 4 + 64)
        writer.appendByte(0x78)  // CM 8, 32 KiB window
        writer.appendByte(0x01)  // FLEVEL 0, no dictionary; (0x7801 % 31 == 0)
        compress(input, into: &writer)
        writer.flushToByte()
        let adler = Adler32.checksum(input)
        writer.appendByte(UInt8(adler >> 24))
        writer.appendByte(UInt8((adler >> 16) & 0xFF))
        writer.appendByte(UInt8((adler >> 8) & 0xFF))
        writer.appendByte(UInt8(adler & 0xFF))
        return writer.bytes
    }

    // MARK: - LZ77

    /// A block's symbols: a literal byte, or a match packed as `1 << 31 | length << 16 | distance`.
    private static let matchFlag: UInt32 = 1 << 31

    private static func compress(_ input: UnsafeRawBufferPointer, into writer: inout BitWriter) {
        let count = input.count
        let hashSize = 1 << hashBits
        let windowMask = windowSize - 1
        let head = UnsafeMutablePointer<Int32>.allocate(capacity: hashSize)
        head.initialize(repeating: -1, count: hashSize)
        let previous = UnsafeMutablePointer<Int32>.allocate(capacity: windowSize)
        previous.initialize(repeating: -1, count: windowSize)
        defer {
            head.deallocate()
            previous.deallocate()
        }

        @inline(__always)
        func hash(_ at: Int) -> Int {
            let value = UInt32(input[at]) | UInt32(input[at + 1]) << 8 | UInt32(input[at + 2]) << 16
            return Int((value &* 2_654_435_761) >> UInt32(32 - hashBits))
        }

        @inline(__always)
        func insert(_ at: Int) -> Int32 {
            let h = hash(at)
            let candidate = head[h]
            previous[at & windowMask] = candidate
            head[h] = Int32(at)
            return candidate
        }

        var symbols: [UInt32] = []
        symbols.reserveCapacity(maxBlockSpan)
        var blockStart = 0
        var fixedBits = 0
        var position = 0

        while position < count {
            if position - blockStart > maxBlockSpan - maxMatch {
                emitBlock(symbols, fixedBits: fixedBits, input: input, start: blockStart,
                          end: position, final: false, into: &writer)
                symbols.removeAll(keepingCapacity: true)
                blockStart = position
                fixedBits = 0
            }

            var bestLength = 0
            var bestDistance = 0
            if count - position >= minMatch {
                var candidate = Int(insert(position))
                let limit = min(maxMatch, count - position)
                let oldest = position - windowSize
                var chain = maxChain
                while candidate >= 0, candidate > oldest, chain > 0 {
                    // Cheap reject: a longer match must agree at the current best length.
                    if input[candidate + bestLength] == input[position + bestLength] {
                        var length = 0
                        while length < limit, input[candidate + length] == input[position + length] {
                            length += 1
                        }
                        if length > bestLength {
                            bestLength = length
                            bestDistance = position - candidate
                            if length == limit { break }
                        }
                    }
                    let next = Int(previous[candidate & windowMask])
                    // A chain link at or after its own position is stale (the slot was reused).
                    guard next < candidate else { break }
                    candidate = next
                    chain -= 1
                }
            }

            if bestLength >= minMatch {
                symbols.append(matchFlag | UInt32(bestLength) << 16 | UInt32(bestDistance))
                fixedBits += FixedCodes.matchCost(length: bestLength, distance: bestDistance)
                let end = position + bestLength
                var at = position + 1
                let lastHashable = count - minMatch
                while at < end, at <= lastHashable {
                    _ = insert(at)
                    at += 1
                }
                position = end
            } else {
                let byte = input[position]
                symbols.append(UInt32(byte))
                fixedBits += byte < 144 ? 8 : 9
                position += 1
            }
        }
        emitBlock(symbols, fixedBits: fixedBits, input: input, start: blockStart, end: count,
                  final: true, into: &writer)
    }

    /// Writes one block, fixed-Huffman or stored, whichever is smaller.
    private static func emitBlock(
        _ symbols: [UInt32], fixedBits: Int, input: UnsafeRawBufferPointer, start: Int, end: Int,
        final: Bool, into writer: inout BitWriter
    ) {
        let span = end - start
        let fixedCost = 3 + fixedBits + 7  // header + symbols + end-of-block
        let storedCost = 3 + writer.bitsToByteBoundary(after: 3) + 32 + span * 8
        writer.write(final ? 1 : 0, bits: 1)
        if storedCost < fixedCost {
            writer.write(0, bits: 2)
            writer.flushToByte()
            writer.appendByte(UInt8(span & 0xFF))
            writer.appendByte(UInt8(span >> 8))
            writer.appendByte(UInt8(~span & 0xFF))
            writer.appendByte(UInt8((~span >> 8) & 0xFF))
            writer.append(UnsafeRawBufferPointer(rebasing: input[start..<end]))
            return
        }
        writer.write(1, bits: 2)
        let codes = FixedCodes.shared
        for symbol in symbols {
            if symbol & matchFlag == 0 {
                let code = codes.literal[Int(symbol)]
                writer.write(UInt32(code.bits), bits: Int(code.length))
                continue
            }
            let length = Int((symbol >> 16) & 0x1FF)
            let distance = Int(symbol & 0xFFFF)
            let lengthIndex = Int(codes.lengthIndex[length])
            let lengthCode = codes.literal[257 + lengthIndex]
            writer.write(UInt32(lengthCode.bits), bits: Int(lengthCode.length))
            let lengthExtra = Int(DeflateTables.lengthExtra[lengthIndex])
            if lengthExtra > 0 {
                writer.write(UInt32(length - Int(DeflateTables.lengthBase[lengthIndex])), bits: lengthExtra)
            }
            let distanceIndex = Int(codes.distanceIndex[distance])
            writer.write(UInt32(codes.distance[distanceIndex]), bits: 5)
            let distanceExtra = Int(DeflateTables.distanceExtra[distanceIndex])
            if distanceExtra > 0 {
                writer.write(UInt32(distance - Int(DeflateTables.distanceBase[distanceIndex])), bits: distanceExtra)
            }
        }
        let endOfBlock = codes.literal[256]
        writer.write(UInt32(endOfBlock.bits), bits: Int(endOfBlock.length))
    }
}

/// The fixed Huffman codes (RFC 1951 §3.2.6), bit-reversed for an LSB-first writer, plus the
/// length → length-symbol and distance → distance-symbol maps.
private struct FixedCodes: Sendable {
    struct Code: Sendable {
        var bits: UInt16
        var length: UInt8
    }

    static let shared = FixedCodes()

    let literal: [Code]
    let distance: [UInt8]
    /// Indexed by match length 3…258: the index into `DeflateTables.lengthBase`.
    let lengthIndex: [UInt8]
    /// Indexed by distance 1…32768: the distance symbol.
    let distanceIndex: [UInt8]

    private init() {
        func reversed(_ code: Int, _ length: Int) -> UInt16 {
            var out = 0
            for bit in 0..<length where code & (1 << bit) != 0 { out |= 1 << (length - 1 - bit) }
            return UInt16(out)
        }
        var literal = [Code](repeating: Code(bits: 0, length: 0), count: 288)
        for symbol in 0..<288 {
            let (base, first, length): (Int, Int, Int) = switch symbol {
            case 0..<144: (0x30, 0, 8)
            case 144..<256: (0x190, 144, 9)
            case 256..<280: (0x00, 256, 7)
            default: (0xC0, 280, 8)
            }
            literal[symbol] = Code(bits: reversed(base + symbol - first, length), length: UInt8(length))
        }
        self.literal = literal
        self.distance = (0..<30).map { UInt8(reversed($0, 5)) }

        var lengthIndex = [UInt8](repeating: 0, count: Deflate.maxMatch + 1)
        for index in 0..<29 {
            let base = Int(DeflateTables.lengthBase[index])
            let span = 1 << Int(DeflateTables.lengthExtra[index])
            for length in base..<min(base + span, Deflate.maxMatch + 1) { lengthIndex[length] = UInt8(index) }
        }
        lengthIndex[258] = 28  // 258 has its own symbol (285), not the end of 284's range
        self.lengthIndex = lengthIndex

        var distanceIndex = [UInt8](repeating: 0, count: Deflate.windowSize + 1)
        for index in 0..<30 {
            let base = Int(DeflateTables.distanceBase[index])
            let span = 1 << Int(DeflateTables.distanceExtra[index])
            for distance in base..<min(base + span, Deflate.windowSize + 1) { distanceIndex[distance] = UInt8(index) }
        }
        self.distanceIndex = distanceIndex
    }

    /// Bits a match costs in a fixed block.
    static func matchCost(length: Int, distance: Int) -> Int {
        let codes = shared
        let lengthIndex = Int(codes.lengthIndex[length])
        let distanceIndex = Int(codes.distanceIndex[distance])
        return Int(codes.literal[257 + lengthIndex].length) + Int(DeflateTables.lengthExtra[lengthIndex])
            + 5 + Int(DeflateTables.distanceExtra[distanceIndex])
    }
}

/// LSB-first bit writer.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var accumulator: UInt64 = 0
    private var count = 0

    mutating func reserve(_ capacity: Int) { bytes.reserveCapacity(capacity) }

    /// Appends the low `bits` bits of `value` (bits ≤ 32).
    @inline(__always)
    mutating func write(_ value: UInt32, bits: Int) {
        accumulator |= UInt64(value) << UInt64(count)
        count += bits
        if count >= 32 {
            bytes.append(UInt8(truncatingIfNeeded: accumulator))
            bytes.append(UInt8(truncatingIfNeeded: accumulator >> 8))
            bytes.append(UInt8(truncatingIfNeeded: accumulator >> 16))
            bytes.append(UInt8(truncatingIfNeeded: accumulator >> 24))
            accumulator >>= 32
            count -= 32
        }
    }

    /// Pads with zero bits to a byte boundary and drains the accumulator into `bytes`.
    mutating func flushToByte() {
        while count > 0 {
            bytes.append(UInt8(truncatingIfNeeded: accumulator))
            accumulator >>= 8
            count = max(0, count - 8)
        }
        accumulator = 0
    }

    /// The padding a byte-aligned write would need after `extra` more bits.
    func bitsToByteBoundary(after extra: Int) -> Int {
        (8 - (count + extra) % 8) % 8
    }

    /// Appends a whole byte; the writer must be byte-aligned.
    mutating func appendByte(_ byte: UInt8) {
        precondition(count == 0, "BitWriter.appendByte needs a byte boundary")
        bytes.append(byte)
    }

    /// Appends raw bytes; the writer must be byte-aligned.
    mutating func append(_ raw: UnsafeRawBufferPointer) {
        precondition(count == 0, "BitWriter.append needs a byte boundary")
        bytes.append(contentsOf: raw)
    }
}
