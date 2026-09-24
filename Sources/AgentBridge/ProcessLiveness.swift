// ProcessLiveness — M3.1.
//
// `kill(pid, 0)` tells us whether *a* process with that pid exists and is signalable, but pids get
// reused: a descriptor's `startedAt` (ms since epoch) is compared against the live process's actual
// start time (`PROC_PIDTBSDINFO.pbi_start_tvsec`) so a reused pid reads as dead rather than alive.
// The comparison is one-sided — see `SystemProcessLiveness.startTimeMatches`.

import Darwin
import Foundation

/// Abstraction over "is this pid alive" so the watcher's liveness sweep is testable without real
/// processes.
public protocol ProcessLiveness: Sendable {
    /// `kill(pid,0)`: `ESRCH` → false, `EPERM` → true (exists, not ours to signal); when `startedAt`
    /// is known, also requires the live process not to have started more than 30 s *after* it, else
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
        return Self.startTimeMatches(actualStart: actualStart, descriptorStartedAt: startedAt)
    }

    /// Whether the process holding a pid now can be the one that wrote a descriptor stamped
    /// `descriptorStartedAt`.
    ///
    /// One-sided on purpose. The writer held the pid at `descriptorStartedAt`, so a live process
    /// that started *before* then has held it ever since and is the writer; a reused pid can only
    /// belong to a process that started *after* it. The 30 s slack on that side is the old window.
    ///
    /// The window used to be symmetric (`abs(…) <= 30`), and that was wrong for any agent whose
    /// startup runs long before it writes its descriptor: a repo's `WorktreeCreate` hook runs
    /// inside `claude -w` first, and `startedAt` lands as late as the hook takes (measured 31.5 s
    /// on aira, 2026-09-24). The live row then read as dead, and `StatusDerivation` rule 1 made it
    /// idle for good — no pulse while working, no NEEDS YOU at a prompt.
    public static func startTimeMatches(actualStart: Date, descriptorStartedAt: Date) -> Bool {
        actualStart.timeIntervalSince(descriptorStartedAt) <= 30
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

    /// BFS over descendants of `pid` (excludes `pid` itself).
    ///
    /// Bounded by **total process count**, not by depth. The old 6-level cap was too shallow for
    /// what actually hangs off a tkzmux pty: `zsh` → `claude` → `bash` → `swift-package` →
    /// `swiftpm-testing-helper` is already five, and a nested shell or a subagent pushes past six —
    /// which would have hidden exactly the process worth finding (see docs/perf.md → *Session
    /// process memory*). `maxDepth` stays as a belt-and-braces stop; `maxProcesses` is the real
    /// bound, matching `PortScanner`'s `maxProcessesVisited`.
    ///
    /// A `visited` set makes the walk safe against a pid appearing twice (pid reuse between two
    /// `proc_listchildpids` calls), which would otherwise loop.
    public static func descendants(
        of pid: pid_t, maxDepth: Int = 32, maxProcesses: Int = 512
    ) -> [pid_t] {
        var result: [pid_t] = []
        var visited: Set<pid_t> = [pid]
        var frontier: [pid_t] = [pid]
        var depth = 0
        while depth < maxDepth, !frontier.isEmpty, result.count < maxProcesses {
            var next: [pid_t] = []
            for p in frontier {
                for kid in children(of: p) where visited.insert(kid).inserted {
                    result.append(kid)
                    next.append(kid)
                    if result.count >= maxProcesses { return result }
                }
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

    /// The process's short name (`p_comm`, the executable's file name capped at `MAXCOMLEN`)
    /// via `proc_name`, or `nil` when the pid is gone or not readable. Used on both sides of the
    /// comparison in `ProcessOwnership`, so the cap cannot make two names disagree.
    public static func name(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_name(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard written > 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
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
