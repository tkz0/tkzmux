// ProcessMetrics (WOR-311 S7): the /proc/self/status and smaps_rollup parsers over fixture text,
// the footprint formula, and on Linux a live sample of this test process. The fixtures are the
// shape Linux 6.x prints (proc_pid_status(5)), trimmed to the lines around the ones read.

import Testing
@testable import TkzPlatform

@Suite struct ProcessMetricsTests {
    static let status = """
        Name:\ttkzmuxPackageTe
        Umask:\t0022
        State:\tS (sleeping)
        Tgid:\t41207
        Pid:\t41207
        Uid:\t1000\t1000\t1000\t1000
        VmPeak:\t 1503420 kB
        VmSize:\t 1437884 kB
        VmHWM:\t  198412 kB
        VmRSS:\t  187904 kB
        RssAnon:\t  151552 kB
        RssFile:\t   34304 kB
        RssShmem:\t    2048 kB
        VmData:\t  402640 kB
        VmSwap:\t    4096 kB
        Threads:\t17
        SigQ:\t0/126513
        Cpus_allowed_list:\t0-31
        voluntary_ctxt_switches:\t1503
        """

    static let smapsRollup = """
        55d0c3a4b000-7ffd1b3fe000 ---p 00000000 00:00 0                          [rollup]
        Rss:              187904 kB
        Pss:              160221 kB
        Anonymous:        151552 kB
        LazyFree:           6144 kB
        AnonHugePages:         0 kB
        Swap:               4096 kB
        Locked:                0 kB
        """

    @Test func parsesTheStatusFields() {
        let metrics = ProcessMetrics(status: Array(Self.status.utf8), cpuSeconds: 1.25)
        #expect(metrics.residentBytes == 187_904 * 1024)
        #expect(metrics.anonymousBytes == 151_552 * 1024)
        #expect(metrics.sharedMemoryBytes == 2048 * 1024)
        #expect(metrics.swapBytes == 4096 * 1024)
        #expect(metrics.threadCount == 17)
        #expect(metrics.cpuSeconds == 1.25)
    }

    /// footprint = RssAnon + RssShmem + VmSwap. RssFile and VmRSS are not in it.
    @Test func footprintIsAnonPlusShmemPlusSwap() {
        let metrics = ProcessMetrics(status: Array(Self.status.utf8), cpuSeconds: 0)
        #expect(metrics.footprintBytes == (151_552 + 2048 + 4096) * 1024)
        #expect(metrics.footprintBytes != metrics.residentBytes)
    }

    /// A kernel thread has no Vm*/Rss* lines, and a pre-4.5 kernel no RssAnon/RssShmem: absent
    /// fields read as 0, never as garbage from a neighbouring line.
    @Test func missingFieldsReadAsZero() {
        let metrics = ProcessMetrics(
            status: Array("Name:\tkthreadd\nState:\tS (sleeping)\nThreads:\t1\n".utf8), cpuSeconds: 0)
        #expect(metrics == ProcessMetrics(residentBytes: 0, anonymousBytes: 0, sharedMemoryBytes: 0,
                                          swapBytes: 0, threadCount: 1, cpuSeconds: 0))
        #expect(ProcessMetrics(status: [], cpuSeconds: 0).footprintBytes == 0)
    }

    /// Keys match whole: `VmRSS` is not read from a `VmRSSx` line, a value with no digits is
    /// skipped, and an overflowing one is dropped rather than trapping.
    @Test func matchesWholeKeysAndSurvivesJunk() {
        let text = "VmRSSx:\t1 kB\nVmRSS:\tjunk\nRssAnon:\t99999999999999999999999 kB\nVmSwap:\t3 kB"
        let metrics = ProcessMetrics(status: Array(text.utf8), cpuSeconds: 0)
        #expect(metrics.residentBytes == 0)
        #expect(metrics.anonymousBytes == 0)
        #expect(metrics.swapBytes == 3 * 1024)  // last line, no trailing newline
    }

    @Test func readsLazyFreeFromSmapsRollup() {
        #expect(ProcessMetrics.lazyFreeBytes(smapsRollup: Array(Self.smapsRollup.utf8)) == 6144 * 1024)
        #expect(ProcessMetrics.lazyFreeBytes(smapsRollup: Array("Rss: 1 kB\n".utf8)) == nil)
    }

    #if os(Linux)
    @Test func samplesThisProcess() {
        let metrics = ProcessMetrics.sample()
        #expect(metrics.residentBytes > 0)
        #expect(metrics.anonymousBytes > 0)
        #expect(metrics.footprintBytes >= metrics.anonymousBytes)
        // The test runner has its main thread plus Swift Testing's and Dispatch's workers.
        #expect(metrics.threadCount >= 1)
        #expect(metrics.cpuSeconds > 0)
        #expect(ProcessMetrics.sampleLazyFreeBytes() != nil)
    }

    @Test func cpuTimeAdvancesWithWork() {
        let before = ProcessMetrics.sample()
        var sink: UInt64 = 0
        let deadline = ProcessMetrics.processCPUSeconds() + 0.02
        while ProcessMetrics.processCPUSeconds() < deadline { sink &+= 1 }
        let after = ProcessMetrics.sample()
        #expect(after.cpuSeconds - before.cpuSeconds >= 0.02)
        #expect(sink > 0)
    }
    #endif
}
