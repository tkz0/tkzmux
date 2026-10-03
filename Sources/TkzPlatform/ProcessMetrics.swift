// ProcessMetrics — what this process costs the machine, read from the kernel (Linux back-end).
//
//   resident      VmRSS      /proc/self/status
//   anonymous     RssAnon    /proc/self/status
//   shmem         RssShmem   /proc/self/status
//   swap          VmSwap     /proc/self/status
//   threads       Threads    /proc/self/status
//   CPU           CLOCK_PROCESS_CPUTIME_ID: user + system for every thread, live ones included
//   footprint     RssAnon + RssShmem + VmSwap: the memory that is this process's alone, wherever
//                 it lives now. Not Darwin's `phys_footprint` (that counts compressed pages and
//                 IOKit/GPU memory, and excludes MADV_FREE'd pages); label the two per OS.
//   lazyFree      LazyFree   /proc/self/smaps_rollup, on demand: MADV_FREE'd pages still in RSS,
//                 the nearest thing to Darwin's `reusable`
//
// The single /proc sampler: nothing else in tkzmux parses /proc/self/status for memory. Status is
// cheap (one generated page). `smaps_rollup` walks every VMA of the process under the mmap lock,
// which is slow on a large address space, so it is a separate call made only at measurement
// checkpoints, never from a timer or a frame.
//
// Linux only for now. The macOS back-end (mach `task_info`, `task_threads`, `proc_pid_rusage`)
// still lives in its two callers, `HostProcessMetrics` (TkzApp) and `tkzmux-vtdump`'s
// `BenchCommands`; WOR-309 S1 moves `HostProcessMetrics` onto this type and adds it. The
// parsers are pure and build on both OSes so their tests can run anywhere.

#if os(Linux)
import Glibc
#endif

public struct ProcessMetrics: Sendable, Equatable {
    /// VmRSS.
    public var residentBytes: UInt64
    /// RssAnon: resident anonymous pages (heap, stacks, private mappings).
    public var anonymousBytes: UInt64
    /// RssShmem: resident shared memory (shmem, tmpfs, shared anonymous mappings).
    public var sharedMemoryBytes: UInt64
    /// VmSwap: this process's anonymous pages that are swapped out, zram included.
    public var swapBytes: UInt64
    /// Threads.
    public var threadCount: Int
    /// User + system CPU time of every thread, in seconds.
    public var cpuSeconds: Double

    /// RssAnon + RssShmem + VmSwap.
    public var footprintBytes: UInt64 { anonymousBytes &+ sharedMemoryBytes &+ swapBytes }

    public init(residentBytes: UInt64, anonymousBytes: UInt64, sharedMemoryBytes: UInt64,
                swapBytes: UInt64, threadCount: Int, cpuSeconds: Double) {
        self.residentBytes = residentBytes
        self.anonymousBytes = anonymousBytes
        self.sharedMemoryBytes = sharedMemoryBytes
        self.swapBytes = swapBytes
        self.threadCount = threadCount
        self.cpuSeconds = cpuSeconds
    }

    /// The memory and thread fields of a `/proc/<pid>/status` document, plus `cpuSeconds`, which
    /// status does not carry. A field the kernel did not print reads as 0: RssAnon and RssShmem
    /// need Linux 4.5, and a kernel thread has no Vm* lines at all.
    public init(status: [UInt8], cpuSeconds: Double) {
        let fields = ProcessMetrics.fields(
            in: status, named: ["VmRSS", "RssAnon", "RssShmem", "VmSwap", "Threads"])
        self.init(
            residentBytes: fields["VmRSS"] ?? 0,
            anonymousBytes: fields["RssAnon"] ?? 0,
            sharedMemoryBytes: fields["RssShmem"] ?? 0,
            swapBytes: fields["VmSwap"] ?? 0,
            threadCount: Int(clamping: fields["Threads"] ?? 0),
            cpuSeconds: cpuSeconds)
    }

    /// The `LazyFree` line of a `smaps_rollup` document, in bytes, or nil when it has none.
    public static func lazyFreeBytes(smapsRollup: [UInt8]) -> UInt64? {
        fields(in: smapsRollup, named: ["LazyFree"])["LazyFree"]
    }

    /// `Key:   value [kB]` lines, the shape status and smaps_rollup share. A value with a `kB` unit
    /// is returned in bytes; a bare number (Threads) as is. Keys not in `names` are skipped without
    /// parsing their values, which for status are often not numbers.
    static func fields(in bytes: [UInt8], named names: Set<String>) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        var lineStart = 0
        while lineStart < bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.count
            defer { lineStart = lineEnd + 1 }
            guard let colon = bytes[lineStart..<lineEnd].firstIndex(of: 0x3A) else { continue }
            let key = String(decoding: bytes[lineStart..<colon], as: UTF8.self)
            guard names.contains(key) else { continue }
            var index = colon + 1
            while index < lineEnd, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
            var value: UInt64 = 0
            var digits = 0
            while index < lineEnd, (0x30...0x39).contains(bytes[index]) {
                let (times10, overflow1) = value.multipliedReportingOverflow(by: 10)
                let (sum, overflow2) = times10.addingReportingOverflow(UInt64(bytes[index] - 0x30))
                guard !overflow1, !overflow2 else { digits = 0; break }
                value = sum
                digits += 1
                index += 1
            }
            guard digits > 0 else { continue }
            while index < lineEnd, bytes[index] == 0x20 { index += 1 }
            if lineEnd - index >= 2, bytes[index] == 0x6B, bytes[index + 1] == 0x42 {  // "kB"
                value = value.multipliedReportingOverflow(by: 1024).overflow ? .max : value * 1024
            }
            result[key] = value
        }
        return result
    }
}

#if os(Linux)
extension ProcessMetrics {
    /// This process, now. Fields that cannot be read are 0 (a /proc without status is not a
    /// system tkzmux runs on, but a sampler must not trap).
    public static func sample() -> ProcessMetrics {
        // CPU first: anything after it, the status read included, is charged to the next interval
        // rather than this one, which keeps two back-to-back samples' CPU delta honest.
        let cpu = processCPUSeconds()
        return ProcessMetrics(status: Procfs.read("/proc/self/status") ?? [], cpuSeconds: cpu)
    }

    /// LazyFree from /proc/self/smaps_rollup (Linux 4.14), or nil when it cannot be read. Slow on a
    /// large address space: call it at a measurement checkpoint, not on a timer.
    public static func sampleLazyFreeBytes() -> UInt64? {
        Procfs.read("/proc/self/smaps_rollup").flatMap { lazyFreeBytes(smapsRollup: $0) }
    }

    /// CLOCK_PROCESS_CPUTIME_ID, in seconds.
    static func processCPUSeconds() -> Double {
        var now = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &now) == 0 else { return 0 }
        return Double(now.tv_sec) + Double(now.tv_nsec) / 1e9
    }
}
#endif
