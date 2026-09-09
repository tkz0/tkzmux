// SessionMemory — how much memory the processes *inside* a session are using.
//
// Why this exists. `HostProcessMetrics` measures the tkzmux process precisely, and docs/perf.md
// lists "the RSS/CPU of the spawned `zsh` children" and "anything with live Claude Code sessions"
// as explicitly **not measured**. That gap made a real incident undiagnosable from inside the app:
// on 2026-09-09 macOS reported tkzmux at >30 GB and ran out of application memory, while tkzmux
// itself never passed 295 MB. The memory belonged to one runaway `swiftpm-testing-helper` started
// from a session's pty. Every process forked from a tkzmux pty inherits tkzmux's **process
// coalition**, and both jetsam and Activity Monitor's hierarchical view bill a coalition to its
// leader — so the app got the blame for its children.
//
// This is the missing number: per session, the summed footprint of the pty child and everything
// under it, plus the single biggest process in that tree so the UI can name the culprit.
//
// ## Why `proc_pid_rusage` and not `task_info`
//
// `phys_footprint` — the number Activity Monitor shows and the memory-pressure system charges you
// for — comes from `task_info(TASK_VM_INFO)`, which needs a task port for the target. You cannot
// get one for another process without `com.apple.security.get-task-allow` on the target or heavy
// entitlements on us. `proc_pid_rusage(pid, RUSAGE_INFO_V4, …)` needs neither, and its
// `ri_phys_footprint` is the same accounting. It works on any process the user owns, which is
// exactly the set spawned from our own ptys.

import ClaudeBridge
import Darwin
import Foundation

/// One reading of a session's process subtree.
///
/// The root (the pty child, i.e. the session's own login shell) is deliberately separated from its
/// descendants, because the two are used for different things: the *total* is what the session
/// costs, while the *descendants* are what a kill action would actually take — it spares the shell
/// so the row stays usable. Naming the root as "what will be killed" would be a lie, and for an
/// idle session the root is the biggest process in the tree.
public struct SessionMemorySample: Sendable, Equatable {
    /// Summed `ri_phys_footprint` over the pty child **and** its descendants.
    public var footprintBytes: UInt64
    /// How many processes were counted, including the pty child.
    ///
    /// This can exceed the number of *live* processes: a killed child stays in
    /// `proc_listchildpids` as a zombie until its parent reaps it, and contributes ~0 bytes. So
    /// trust `footprintBytes` for "how bad is it", not this.
    public var processCount: Int
    /// The pty child's own footprint — the part a kill action would leave behind.
    public var rootBytes: UInt64
    /// The largest process *below* the root: the runaway, when there is one. Empty/zero when the
    /// session is just a shell.
    public var largestName: String
    public var largestPid: pid_t
    public var largestBytes: UInt64
    /// True when the walk hit `maxProcesses`, i.e. the total is a floor, not a total.
    public var truncated: Bool

    /// What a kill would reclaim: everything except the shell it spares.
    public var descendantBytes: UInt64 { footprintBytes - min(rootBytes, footprintBytes) }
    /// How many processes a kill would signal.
    public var descendantCount: Int { max(0, processCount - 1) }

    public static let empty = SessionMemorySample(
        footprintBytes: 0, processCount: 0, rootBytes: 0, largestName: "", largestPid: 0,
        largestBytes: 0, truncated: false)
}

public enum SessionMemory {
    /// How many processes one sample will visit. Each costs one `proc_pid_rusage` syscall, so this
    /// also bounds the cost of a tick.
    public static let maxProcesses = 512

    /// `ri_phys_footprint` for one pid, or `nil` when it cannot be read (exited, or not ours).
    public static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard ok == 0 else { return nil }
        return info.ri_phys_footprint
    }

    /// The process's `p_comm` (short name, no path), or "" when unavailable.
    public static func name(of pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_name(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard written > 0 else { return "" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// Sums the footprint of `pid` and everything under it.
    ///
    /// A pid that has already exited contributes nothing rather than failing the whole sample —
    /// a tree this size is always slightly stale by the time it is summed.
    public static func sample(rootPid pid: pid_t) -> SessionMemorySample {
        guard pid > 0 else { return .empty }
        let children = ProcessTree.descendants(of: pid, maxProcesses: maxProcesses)

        var total: UInt64 = 0
        var counted = 0
        var rootBytes: UInt64 = 0
        var largestBytes: UInt64 = 0
        var largestPid: pid_t = 0

        if let bytes = footprint(of: pid) {
            rootBytes = bytes
            total += bytes
            counted += 1
        }
        // `largest*` covers descendants only — see `SessionMemorySample`.
        for p in children {
            guard let bytes = footprint(of: p) else { continue }
            total += bytes
            counted += 1
            if bytes > largestBytes {
                largestBytes = bytes
                largestPid = p
            }
        }
        guard counted > 0 else { return .empty }
        return SessionMemorySample(
            footprintBytes: total,
            processCount: counted,
            rootBytes: rootBytes,
            largestName: largestPid == 0 ? "" : name(of: largestPid),
            largestPid: largestPid,
            largestBytes: largestBytes,
            // `descendants` returns at most `maxProcesses`, so a full list means it may have cut.
            truncated: children.count >= maxProcesses)
    }

    /// Signals `pid` and every descendant — the "this session's processes are eating the machine,
    /// stop them" action.
    ///
    /// Deepest-first, so a parent cannot fork a replacement child after its children are gone. The
    /// pty child itself is signalled last and only when `includingRoot` is set; leaving it alive is
    /// what lets the session's shell survive while a runaway build under it is killed.
    ///
    /// Returns the pids actually signalled. Nothing here reclaims memory by itself — the point is
    /// that a stalled process holding 40 GB is never released by the system (jetsam does not kill
    /// it), so someone has to.
    @discardableResult
    public static func terminateTree(
        rootPid pid: pid_t, signal: Int32 = SIGKILL, includingRoot: Bool = false
    ) -> [pid_t] {
        guard pid > 0 else { return [] }
        var signalled: [pid_t] = []
        for p in ProcessTree.descendants(of: pid, maxProcesses: maxProcesses).reversed() {
            if kill(p, signal) == 0 { signalled.append(p) }
        }
        if includingRoot, kill(pid, signal) == 0 { signalled.append(pid) }
        return signalled
    }
}
