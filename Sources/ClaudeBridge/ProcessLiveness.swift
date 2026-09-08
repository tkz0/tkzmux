// ProcessLiveness — TKZ-21 (M3.1). See docs/design.md → Claude integration → Discovery.
//
// `kill(pid, 0)` tells us whether *a* process with that pid exists and is signalable, but pids get
// reused: a descriptor's `startedAt` (ms since epoch) is compared against the live process's actual
// start time (`PROC_PIDTBSDINFO.pbi_start_tvsec`) so a reused pid reads as dead rather than alive.

import Darwin
import Foundation

/// Abstraction over "is this pid alive" so the watcher's liveness sweep is testable without real
/// processes.
public protocol ProcessLiveness: Sendable {
    /// `kill(pid,0)`: `ESRCH` → false, `EPERM` → true (exists, not ours to signal); when `startedAt`
    /// is known, also requires the live process's actual start time to be within 30 s of it, else
    /// false (pid-reuse guard).
    func isAlive(pid: pid_t, startedAt: Date?) -> Bool
}

/// The real, syscall-backed implementation.
public struct SystemProcessLiveness: ProcessLiveness {
    public init() {}

    public func isAlive(pid: pid_t, startedAt: Date?) -> Bool {
        if kill(pid, 0) != 0 {
            if errno == ESRCH { return false }
            // EPERM (owned by someone else, but exists) and anything else: fall through to the
            // pid-reuse guard below when we can, otherwise assume alive.
        }
        guard let startedAt else { return true }
        guard let actualStart = ProcessTree.startTime(of: pid) else {
            // Could not read start time (process gone between the kill() and the pidinfo call, or
            // no permission) — do not claim aliveness we cannot verify.
            return false
        }
        return abs(actualStart.timeIntervalSince(startedAt)) <= 30
    }
}

/// `libproc`-backed helpers for walking the process tree — used to locate a Claude Code session's
/// child/descendant processes and to read start times for the pid-reuse guard.
public enum ProcessTree {
    /// Direct children of `pid` via `proc_listchildpids`.
    ///
    /// Unlike `proc_listallpids`, this call does not support the "pass NULL to size the buffer"
    /// idiom (it ignores `pid` and returns a bogus system-wide count), and its return value is the
    /// **number of pids** written, not a byte count — so a fixed, generous buffer is used and the
    /// return value indexes directly into it.
    public static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    /// BFS over descendants of `pid` (excludes `pid` itself), capped at `maxDepth` levels.
    public static func descendants(of pid: pid_t, maxDepth: Int = 6) -> [pid_t] {
        var result: [pid_t] = []
        var frontier: [pid_t] = [pid]
        var depth = 0
        while depth < maxDepth, !frontier.isEmpty {
            var next: [pid_t] = []
            for p in frontier {
                let kids = children(of: p)
                result.append(contentsOf: kids)
                next.append(contentsOf: kids)
            }
            frontier = next
            depth += 1
        }
        return result
    }

    /// The process's start time via `PROC_PIDTBSDINFO.pbi_start_tvsec`, or `nil` if unavailable.
    public static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard result == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    /// The parent pid via `PROC_PIDTBSDINFO.pbi_ppid`, or `nil` if unavailable.
    public static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard result == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
