// SHA256 (WOR-304 S4) against the NIST CAVP SHAVS byte-oriented vectors (Fixtures/SHAVS, read
// through #filePath), the FIPS 180-4 examples and split-invariance over seeded random inputs. The
// Mac also checks it against CryptoKit (SHA256CryptoKitTests.swift).

import Foundation
import Testing
@testable import TkzPlatform

@Suite struct SHA256Tests {
    // MARK: SHAVS

    struct Vector: Sendable, CustomTestStringConvertible {
        var bits: Int
        var message: [UInt8]
        var digest: String
        var testDescription: String { "Len = \(bits)" }
    }

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)           // Tests/TkzPlatformTests/SHA256Tests.swift
            .deletingLastPathComponent()           // Tests/TkzPlatformTests
            .appendingPathComponent("Fixtures/SHAVS")
    }

    /// The `Len`/`Msg`/`MD` triples of a `.rsp` file. `Msg` holds `Len / 8` bytes, except that
    /// `Len = 0` is written as `Msg = 00`.
    static func vectors(_ name: String) throws -> [Vector] {
        let text = try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
        var vectors: [Vector] = []
        var bits: Int?
        var message: [UInt8]?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("["), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Len": bits = Int(value)
            case "Msg": message = hexBytes(value)
            case "MD":
                guard let length = bits, let bytes = message else { throw CocoaError(.fileReadCorruptFile) }
                vectors.append(Vector(bits: length, message: Array(bytes.prefix(length / 8)), digest: value))
                bits = nil
                message = nil
            default: continue
            }
        }
        return vectors
    }

    static func hexBytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        return stride(from: 0, to: digits.count - 1, by: 2).map {
            UInt8(String(decoding: digits[$0...$0 + 1], as: UTF8.self), radix: 16)!
        }
    }

    static let shortMessages = (try? vectors("SHA256ShortMsg.rsp")) ?? []
    static let longMessages = (try? vectors("SHA256LongMsg.rsp")) ?? []

    @Test func readsEveryVector() {
        #expect(Self.shortMessages.count == 65)
        #expect(Self.shortMessages.map(\.bits) == Array(stride(from: 0, through: 512, by: 8)))
        #expect(Self.longMessages.count == 64)
        #expect(Self.longMessages.allSatisfy { $0.message.count == $0.bits / 8 && $0.bits > 512 })
    }

    @Test(arguments: shortMessages)
    func shortMessage(_ vector: Vector) {
        #expect(SHA256.hash(data: vector.message).description == vector.digest)
        // One byte per update: every message goes through the partial-block path.
        var hasher = SHA256()
        for byte in vector.message { hasher.update(data: [byte]) }
        #expect(hasher.finalize().description == vector.digest)
    }

    @Test(arguments: longMessages)
    func longMessage(_ vector: Vector) {
        #expect(SHA256.hash(data: vector.message).description == vector.digest)
        // Splits either side of a block boundary.
        for split in [1, 55, 63, 64, 65, 127] where split < vector.message.count {
            var hasher = SHA256()
            hasher.update(data: vector.message[..<split])
            hasher.update(data: vector.message[split...])
            #expect(hasher.finalize().description == vector.digest, "split at \(split)")
        }
    }

    // MARK: FIPS 180-4 examples

    @Test func fipsExamples() {
        #expect(SHA256.hash(data: Data("abc".utf8)).description
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hash(data: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)).description
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(SHA256.hash(data: [UInt8](repeating: 0x61, count: 1_000_000)).description
            == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    // MARK: API

    @Test func finalizeLeavesTheHasherUsable() {
        var hasher = SHA256()
        hasher.update(data: Data("ab".utf8))
        let first = hasher.finalize()
        #expect(hasher.finalize() == first)
        hasher.update(data: Data("c".utf8))
        #expect(hasher.finalize() == SHA256.hash(data: Data("abc".utf8)))
    }

    @Test func digestIsThirtyTwoBytesInOrder() {
        let digest = SHA256.hash(data: Data())
        #expect(Array(digest).count == SHA256Digest.byteCount)
        #expect(digest.map { String(format: "%02x", $0) }.joined() == digest.description)
        #expect(digest.withUnsafeBytes { Array($0) } == digest.bytes)
    }

    /// A non-contiguous `DataProtocol` value hashes region by region, like a flat copy.
    @Test func hashesEveryRegion() {
        let parts = (0..<5).map { Data(repeating: UInt8($0), count: 37 * ($0 + 1)) }
        let regions = DispatchData.joined(parts)
        #expect(SHA256.hash(data: regions) == SHA256.hash(data: parts.reduce(Data(), +)))
    }

    // MARK: Random inputs

    /// The same message split at seeded random `update` boundaries always gives the one-shot digest.
    @Test func splitsDoNotChangeTheDigest() {
        var random = SplitMix64(seed: 0x5348_4132_3536)
        for _ in 0..<300 {
            let message = random.bytes(count: Int(random.next() % 1_500))
            var hasher = SHA256()
            for chunk in random.split(message) { hasher.update(data: chunk) }
            #expect(hasher.finalize() == SHA256.hash(data: message), "\(message.count) bytes")
        }
    }

    // MARK: Speed

    /// 1 MB in under 10 ms in a release build (`swift test -c release`). A debug build has no
    /// optimiser and checks every index, so it only reports the time.
    @Test func hashesOneMegabyteQuickly() {
        let message = [UInt8](repeating: 0xa5, count: 1 << 20)
        var best = UInt64.max
        for _ in 0..<5 {
            let start = Clocks.monotonicNanos
            _ = SHA256.hash(data: message)
            best = min(best, Clocks.monotonicNanos - start)
        }
        let milliseconds = Double(best) / 1e6
        #if DEBUG
        print("SHA256: 1 MB in \(milliseconds) ms (debug build, not checked)")
        #else
        #expect(milliseconds < 10, "1 MB took \(milliseconds) ms")
        #endif
    }
}

extension DispatchData {
    /// One `DispatchData` holding `parts` as separate regions.
    static func joined(_ parts: [Data]) -> DispatchData {
        var joined = DispatchData.empty
        for part in parts {
            part.withUnsafeBytes { joined.append(DispatchData(bytes: $0)) }
        }
        return joined
    }
}

/// A seeded generator, so a failure names an input that can be reproduced.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    mutating func bytes(count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }
    }

    /// `message` cut at random points into consecutive chunks, empty ones included.
    mutating func split(_ message: [UInt8]) -> [ArraySlice<UInt8>] {
        var chunks: [ArraySlice<UInt8>] = []
        var start = 0
        while start < message.count {
            let length = Int(next() % 200)
            let end = min(message.count, start + length)
            chunks.append(message[start..<end])
            start = end
        }
        chunks.append(message[message.count...])
        return chunks
    }
}
