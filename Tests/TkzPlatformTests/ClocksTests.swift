// Clocks (WOR-304 S4): both clocks advance with real time, `bootNanos` never trails
// `monotonicNanos`, and `monotonicNanos` is the clock Dispatch reads. On Linux, `bootNanos` is
// checked against /proc/uptime, which counts suspend; on a machine that has slept since boot that
// tells CLOCK_BOOTTIME from CLOCK_MONOTONIC.

import Dispatch
import Foundation
import Testing
@testable import TkzPlatform

@Suite struct ClocksTests {
    @Test func monotonicNeverGoesBackwards() {
        var previous = Clocks.monotonicNanos
        for _ in 0..<10_000 {
            let now = Clocks.monotonicNanos
            #expect(now >= previous)
            previous = now
        }
    }

    @Test func bootNeverTrailsMonotonic() {
        for _ in 0..<1_000 {
            let monotonic = Clocks.monotonicNanos
            let boot = Clocks.bootNanos
            #expect(boot >= monotonic)
        }
    }

    @Test func bothFollowRealTime() async throws {
        let monotonic = Clocks.monotonicNanos
        let boot = Clocks.bootNanos
        try await Task.sleep(nanoseconds: 20_000_000)
        let monotonicElapsed = Clocks.monotonicNanos - monotonic
        let bootElapsed = Clocks.bootNanos - boot
        #expect(monotonicElapsed >= 20_000_000)
        #expect(bootElapsed >= 20_000_000)
        // Nothing suspends in 20 ms, so they differ only by when each was read; the bound leaves
        // room for a busy CI runner to preempt the test between two reads.
        let gap = bootElapsed > monotonicElapsed ? bootElapsed - monotonicElapsed : monotonicElapsed - bootElapsed
        #expect(gap < 50_000_000)
    }

    /// `DispatchTime.uptimeNanoseconds` reads CLOCK_MONOTONIC on Linux and mach_absolute_time
    /// (CLOCK_UPTIME_RAW) on the Mac, so deadlines and `monotonicNanos` intervals agree.
    @Test func monotonicIsDispatchsClock() {
        let before = DispatchTime.now().uptimeNanoseconds
        let monotonic = Clocks.monotonicNanos
        let after = DispatchTime.now().uptimeNanoseconds
        // Both sides convert hardware ticks to nanoseconds; allow for rounding.
        #expect(monotonic + 1_000 >= before)
        #expect(monotonic <= after + 1_000)
    }

    #if os(Linux)
    /// The first field of /proc/uptime is CLOCK_BOOTTIME in centiseconds.
    @Test func bootMatchesProcUptime() throws {
        let text = try String(contentsOfFile: "/proc/uptime", encoding: .utf8)
        let uptime = try #require(text.split(separator: " ").first.flatMap { Double($0) })
        let boot = Double(Clocks.bootNanos) / 1e9
        #expect(abs(boot - uptime) < 0.5, "bootNanos \(boot) s, /proc/uptime \(uptime) s")
    }
    #endif
}
