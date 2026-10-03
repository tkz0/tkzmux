// ProcessTable — read-only questions about other processes, per OS (WOR-304 S6).
//
//   Linux  `ProcfsProcessTable` (Linux/): /proc. Children from /proc/<pid>/task/*/children (a scan
//          of /proc/*/stat when the kernel lacks CONFIG_PROC_CHILDREN), ppid and start ticks from
//          /proc/<pid>/stat, the name from /proc/<pid>/comm, exe and cwd through readlink.
//   macOS  `LibprocProcessTable` (Darwin/): libproc, lifted from AgentBridge's `ProcessTree`.
//
// `ProcessTable` names the back-end for the OS being built, and is the one name callers use. It
// replaces `AgentBridge.ProcessTree` (ProcessLiveness.swift) and the private walk in GitStatus's
// `PortScanner`; WOR-306 moves those callers and deletes them.
//
// Everything is best-effort and never throws: a process that exits mid-call, or that this process
// may not inspect (another user's under `hidepid`, launchd), reads as nil or as having no children.
// Callers poll from a live UI and must not log per-pid noise.

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif
import Foundation

/// The calls every `ProcessTable` back-end answers. Static, because a process table has no state
/// worth owning; the protocol exists so that both back-ends are held to one signature.
public protocol ProcessTableBackend {
    /// Direct children of `pid`, or empty when it has none or cannot be read.
    static func children(of pid: pid_t) -> [pid_t]

    /// The parent pid, or nil when the process is gone or unreadable.
    static func parent(of pid: pid_t) -> pid_t?

    /// The process's short name, or nil. Linux: `comm`, the executable's file name capped at 15
    /// bytes. macOS: `proc_name`, capped at 2 × MAXCOMLEN. Compare names only with names from the
    /// same call, so the caps cannot make two names disagree.
    static func name(of pid: pid_t) -> String?

    /// When the process started, as wall-clock time, or nil. Linux: boot time plus `startTicks`,
    /// good to the second (`btime` is whole seconds). macOS: `pbi_start_tvsec`.
    static func startTime(of pid: pid_t) -> Date?

    /// The process's start time in the OS's own units, for an exact pid-reuse check: equal values
    /// for one pid mean the same process. Linux: clock ticks after boot, field 22 of
    /// /proc/<pid>/stat, which is what Claude Code writes as `procStart` in its session file.
    /// macOS: microseconds since 1970 (`pbi_start_tvsec`, `pbi_start_tvusec`). Not comparable
    /// across OSes or reboots.
    static func startTicks(of pid: pid_t) -> UInt64?

    /// The absolute path of the process's executable, or nil. On Linux a replaced or deleted
    /// executable (an auto-update) still answers with its old path, without ` (deleted)`.
    static func exe(of pid: pid_t) -> String?

    /// The process's working directory, or nil. On Linux without ` (deleted)`, as for `exe`.
    static func cwd(of pid: pid_t) -> String?
}

extension ProcessTableBackend {
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
    /// `children(of:)` calls), which would otherwise loop.
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
}

#if os(Linux)
/// The process table of the OS being built.
public typealias ProcessTable = ProcfsProcessTable
#elseif canImport(Darwin)
/// The process table of the OS being built.
public typealias ProcessTable = LibprocProcessTable
#endif
