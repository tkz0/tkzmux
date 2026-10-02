// Clocks — the two clocks tkzmux measures time with, per OS (WOR-304 S4).
//
//                    stops while asleep        keeps counting while asleep
//   Linux            CLOCK_MONOTONIC           CLOCK_BOOTTIME
//   macOS            CLOCK_UPTIME_RAW          CLOCK_MONOTONIC_RAW
//                    (mach_absolute_time)      (mach_continuous_time)
//
// `monotonicNanos` is the clock `DispatchTime.now().uptimeNanoseconds` reads on both OSes, so
// intervals and deadlines agree with Dispatch. `bootNanos` is for "how long ago" questions that
// must count a suspend, such as process start times and sleep/wake gaps (WOR-320). Neither is wall
// time, and neither is comparable across reboots.

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public enum Clocks {
    /// Nanoseconds since an arbitrary start, not counting time the machine was asleep.
    public static var monotonicNanos: UInt64 {
        #if canImport(Darwin)
        return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #else
        return nanos(CLOCK_MONOTONIC)
        #endif
    }

    /// Nanoseconds since boot, counting time the machine was asleep. Never less than
    /// `monotonicNanos` read before it.
    public static var bootNanos: UInt64 {
        #if canImport(Darwin)
        return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        #else
        return nanos(CLOCK_BOOTTIME)
        #endif
    }

    #if !canImport(Darwin)
    private static func nanos(_ clock: clockid_t) -> UInt64 {
        var now = timespec()
        clock_gettime(clock, &now)
        return UInt64(now.tv_sec) * 1_000_000_000 + UInt64(now.tv_nsec)
    }
    #endif
}
