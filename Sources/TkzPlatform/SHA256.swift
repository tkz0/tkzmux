// SHA256 — FIPS 180-4 SHA-256 in plain Swift (WOR-304 S4), the same code on both OSes.
//
// It replaces CryptoKit's `SHA256`, which Linux does not have, with the same call shape:
// `init()`, `update(data:)` / `update(bufferPointer:)`, a non-mutating `finalize()` returning a
// digest that is a `Sequence` of `UInt8`, and `hash(data:)`. A call site switches by changing its
// import, so `ShimInstaller.version`'s bytes and digest are what CryptoKit produced
// (Tests/AgentBridgeTests/ShimVersionGoldenTests.swift).
//
// Not constant-time and not for secrets: tkzmux hashes its own resources to notice changes.
// Checked against the NIST CAVP SHAVS byte-oriented short- and long-message vectors
// (Tests/TkzPlatformTests/Fixtures/SHAVS) and, on the Mac, against CryptoKit.

import Foundation

public struct SHA256: Sendable {
    /// The digest size, in bytes.
    public static let byteCount = 32
    /// The block size, in bytes.
    public static let blockByteCount = 64

    public typealias Digest = SHA256Digest

    /// H0…H7 (FIPS 180-4 §5.3.3), advanced by every whole block.
    private var state = State()
    /// The bytes of a block not yet compressed, fewer than ``blockByteCount``.
    private var pending: [UInt8] = []
    /// Message length so far, in bytes. SHA-256 encodes it mod 2^64 bits.
    private var length: UInt64 = 0

    public init() {
        pending.reserveCapacity(Self.blockByteCount)
    }

    /// The digest of `data` in one call.
    public static func hash(data: some DataProtocol) -> SHA256Digest {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize()
    }

    public mutating func update(data: some DataProtocol) {
        for region in data.regions {
            region.withUnsafeBytes { update(bufferPointer: $0) }
        }
    }

    public mutating func update(bufferPointer input: UnsafeRawBufferPointer) {
        guard !input.isEmpty else { return }
        length &+= UInt64(input.count)
        var offset = 0
        if !pending.isEmpty {
            let take = min(Self.blockByteCount - pending.count, input.count)
            pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: input[0..<take]))
            offset = take
            guard pending.count == Self.blockByteCount else { return }
            pending.withUnsafeBytes { state.compress($0) }
            pending.removeAll(keepingCapacity: true)
        }
        let whole = (input.count - offset) / Self.blockByteCount * Self.blockByteCount
        if whole > 0 {
            state.compress(UnsafeRawBufferPointer(rebasing: input[offset..<(offset + whole)]))
            offset += whole
        }
        if offset < input.count {
            pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: input[offset...]))
        }
    }

    /// The digest of everything passed to `update` so far. Like CryptoKit's, it does not change
    /// the hasher, so more data can still be added.
    public func finalize() -> SHA256Digest {
        // §5.1.1: a 1 bit, zeros up to 56 mod 64 bytes, then the bit length as a big-endian UInt64.
        var tail = pending
        tail.append(0x80)
        let zeros = (Self.blockByteCount + 56 - tail.count % Self.blockByteCount) % Self.blockByteCount
        tail.append(contentsOf: repeatElement(0, count: zeros))
        withUnsafeBytes(of: (length &* 8).bigEndian) { tail.append(contentsOf: $0) }

        var final = state
        tail.withUnsafeBytes { final.compress($0) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.byteCount)
        for word in final.words {
            withUnsafeBytes(of: word.bigEndian) { bytes.append(contentsOf: $0) }
        }
        return SHA256Digest(bytes: bytes)
    }

    // MARK: Compression

    /// The eight working hash words.
    private struct State: Sendable {
        var h0: UInt32 = 0x6a09_e667, h1: UInt32 = 0xbb67_ae85
        var h2: UInt32 = 0x3c6e_f372, h3: UInt32 = 0xa54f_f53a
        var h4: UInt32 = 0x510e_527f, h5: UInt32 = 0x9b05_688c
        var h6: UInt32 = 0x1f83_d9ab, h7: UInt32 = 0x5be0_cd19

        var words: [UInt32] { [h0, h1, h2, h3, h4, h5, h6, h7] }

        /// Runs §6.2.2 over every 64-byte block in `blocks`. Words are read with unaligned
        /// big-endian loads, so `blocks` can start anywhere.
        mutating func compress(_ blocks: UnsafeRawBufferPointer) {
            precondition(blocks.count % SHA256.blockByteCount == 0)
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
                SHA256.roundConstants.withUnsafeBufferPointer { k in
                    for base in stride(from: 0, to: blocks.count, by: SHA256.blockByteCount) {
                        for t in 0..<16 {
                            w[t] = UInt32(bigEndian: blocks.loadUnaligned(fromByteOffset: base + 4 * t, as: UInt32.self))
                        }
                        for t in 16..<64 {
                            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
                        }

                        var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
                        for t in 0..<64 {
                            let sum1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                            let choose = (e & f) ^ (~e & g)
                            let t1 = h &+ sum1 &+ choose &+ k[t] &+ w[t]
                            let sum0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                            let majority = (a & b) ^ (a & c) ^ (b & c)
                            let t2 = sum0 &+ majority
                            h = g; g = f; f = e; e = d &+ t1
                            d = c; c = b; b = a; a = t1 &+ t2
                        }
                        h0 &+= a; h1 &+= b; h2 &+= c; h3 &+= d
                        h4 &+= e; h5 &+= f; h6 &+= g; h7 &+= h
                    }
                }
            }
        }

        @inline(__always)
        private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    }

    /// K (§4.2.2): the first 32 bits of the fractional parts of the cube roots of the first 64 primes.
    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
}

/// A SHA-256 digest: 32 bytes, iterated in order like CryptoKit's `SHA256Digest`.
public struct SHA256Digest: Sequence, Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = SHA256.byteCount

    public let bytes: [UInt8]

    init(bytes: [UInt8]) {
        precondition(bytes.count == Self.byteCount)
        self.bytes = bytes
    }

    public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }

    /// Lowercase hex, 64 characters.
    public var description: String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(2 * Self.byteCount)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}
