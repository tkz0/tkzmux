// TkzPlatform's SHA256 against CryptoKit's, which it replaced in ShimInstaller (WOR-304 S4). Mac
// only. A file of its own because importing CryptoKit makes the bare names `SHA256` and
// `SHA256Digest` ambiguous, so every use here is module-qualified.

#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing
@testable import TkzPlatform

@Suite struct SHA256CryptoKitTests {
    /// 1,000 seeded random inputs, fed through both at the same random `update` boundaries.
    @Test func matchesCryptoKit() {
        var random = SplitMix64(seed: 0x4372_7970_746f)
        for _ in 0..<1_000 {
            let message = random.bytes(count: Int(random.next() % 4_096))
            var ours = TkzPlatform.SHA256()
            var theirs = CryptoKit.SHA256()
            for chunk in random.split(message) {
                ours.update(data: chunk)
                theirs.update(data: chunk)
            }
            #expect(Array(ours.finalize()) == Array(theirs.finalize()), "\(message.count) bytes")
        }
    }
}
#endif
