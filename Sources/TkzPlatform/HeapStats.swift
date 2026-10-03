// HeapStats — how much the process's malloc heap holds right now, per OS (WOR-311 S7).
//
//   macOS  `malloc_zone_statistics(nil, …).blocks_in_use`: live blocks across every malloc zone.
//          A COUNT of blocks.
//   Linux  `mallinfo2()` `uordblks + hblkhd` (through TkzPlatformShim): bytes in allocated arena
//          chunks plus bytes in mmap-served chunks. A number of BYTES; glibc keeps no count of
//          live blocks.
//
// The two numbers measure different things, so the field has a different name on each OS and
// there is no shared accessor: code that reads it has to say which one it means, and a Mac block
// count can never be compared with a Linux byte count by accident. `fieldName` is the key a
// report or JSON record writes it under.
//
// The only heap helper in tkzmux. `tkzmux-vtdump bench-frame` reads it around each frame, and the
// glibc memory work (WOR-321) and the Linux benches (WOR-323) reuse it. Both calls walk allocator
// state under the allocator's lock; read it at measurement points, never per allocation.

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import TkzPlatformShim
#endif

public struct HeapStats: Sendable, Equatable {
    #if canImport(Darwin)
    /// `malloc_statistics_t.blocks_in_use` for all zones: net live blocks, not bytes and not a
    /// cumulative allocation count.
    public var blocksInUse: Int

    /// The report key for `blocksInUse`.
    public static let fieldName = "blocks_in_use"

    public static func sample() -> HeapStats {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return HeapStats(blocksInUse: Int(statistics.blocks_in_use))
    }
    #else
    /// `mallinfo2()` `uordblks + hblkhd`: live heap bytes, arena chunks and mmap'd chunks together.
    /// Includes chunk headers and rounding, so it is at least what was requested.
    public var bytesInUse: Int

    /// The report key for `bytesInUse`.
    public static let fieldName = "bytes_in_use"

    public static func sample() -> HeapStats {
        HeapStats(bytesInUse: Int(tkz_heap_bytes_in_use()))
    }
    #endif
}
