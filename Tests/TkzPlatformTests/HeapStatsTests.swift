// HeapStats (WOR-311 S7): the one heap number per OS follows live allocations up and back down.
// macOS counts blocks, Linux counts bytes, and each names its field accordingly.
//
// The allocations are big enough (2048 blocks of 8 KiB, 16 MiB) that whatever another thread of
// the test process allocates or frees meanwhile cannot hide them, and the bounds are half the
// expected change for the same reason. Every block is written to, so no allocator can hand back
// untouched address space for it.

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif
import Testing
@testable import TkzPlatform

@Suite struct HeapStatsTests {
    static let blockCount = 2048
    static let blockSize = 8192

    /// The OS's own figure for `HeapStats`: blocks on macOS, bytes on Linux.
    static func inUse(_ stats: HeapStats) -> Int {
        #if canImport(Darwin)
        return stats.blocksInUse
        #else
        return stats.bytesInUse
        #endif
    }

    /// What `blockCount` live blocks of `blockSize` should add, in the OS's unit.
    static var expectedGrowth: Int {
        #if canImport(Darwin)
        return blockCount
        #else
        return blockCount * blockSize
        #endif
    }

    @Test func fieldNameSaysWhatIsCounted() {
        #if canImport(Darwin)
        #expect(HeapStats.fieldName == "blocks_in_use")
        #else
        #expect(HeapStats.fieldName == "bytes_in_use")
        #endif
    }

    /// Under AddressSanitizer every allocation goes to ASan's own allocator, which glibc's
    /// mallinfo2 does not see (asan-valgrind job, WOR-314 S2). The sanitized build exports its
    /// runtime's entry point.
    static let addressSanitizer: Bool = {
        #if os(Linux)
        return dlsym(nil, "__asan_init") != nil
        #else
        return false
        #endif
    }()

    @Test(.enabled(if: !addressSanitizer, "mallinfo2 does not see AddressSanitizer's allocator"))
    func readsAPositiveNumber() {
        #expect(Self.inUse(HeapStats.sample()) > 0)
    }

    @Test(.enabled(if: !addressSanitizer, "mallinfo2 does not see AddressSanitizer's allocator"))
    func followsLiveAllocationsUpAndDown() throws {
        let before = Self.inUse(HeapStats.sample())
        var blocks: [UnsafeMutableRawPointer] = []
        blocks.reserveCapacity(Self.blockCount)
        defer { for block in blocks { free(block) } }
        for _ in 0..<Self.blockCount {
            let block = try #require(malloc(Self.blockSize))
            memset(block, 0xA5, Self.blockSize)
            blocks.append(block)
        }
        let held = Self.inUse(HeapStats.sample())
        #expect(held - before >= Self.expectedGrowth / 2, "before \(before), held \(held)")

        for block in blocks { free(block) }
        blocks.removeAll()
        let after = Self.inUse(HeapStats.sample())
        #expect(held - after >= Self.expectedGrowth / 2, "held \(held), after \(after)")
    }
}
