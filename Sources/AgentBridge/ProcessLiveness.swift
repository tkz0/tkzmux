// ProcessLiveness — M3.1.
//
// `kill(pid, 0)` tells us whether *a* process with that pid exists and is signalable, but pids get
// reused: a descriptor's `startedAt` (ms since epoch) is compared against the live process's actual
// start time (TkzPlatform's `ProcessTable`: `pbi_start_tvsec` on macOS, /proc on Linux) so a reused
// pid reads as dead rather than alive. The comparison is one-sided — see
// `SystemProcessLiveness.startTimeMatches`.
//
// On Linux, Claude Code also stamps the descriptor with `procStart` (field 22 of
// /proc/<pid>/stat) and `pidDomain` (which pid namespace on which machine the pid belongs to), and
// those give an exact guard instead — see `isAlive(pid:startedAt:procStart:pidDomain:)`.

#if os(macOS)
import Darwin
#else
import Glibc
#endif
import Foundation
import TkzPlatform

/// Abstraction over "is this pid alive" so the watcher's liveness sweep is testable without real
/// processes.
public protocol ProcessLiveness: Sendable {
    /// `kill(pid,0)`: `ESRCH` → false, `EPERM` → true (exists, not ours to signal); when `startedAt`
    /// is known, also requires the live process not to have started more than 30 s *after* it, else
    /// false (pid-reuse guard).
    func isAlive(pid: pid_t, startedAt: Date?) -> Bool

    /// `isAlive(pid:startedAt:)` for a descriptor that may carry Claude Code's exact process
    /// identity: `procStart` (the process's start in the OS's own ticks) and `pidDomain` (the pid
    /// namespace it was written in). The default ignores both; `SystemProcessLiveness` uses them.
    func isAlive(pid: pid_t, startedAt: Date?, procStart: UInt64?, pidDomain: String?) -> Bool
}

extension ProcessLiveness {
    public func isAlive(pid: pid_t, startedAt: Date?, procStart: UInt64?, pidDomain: String?) -> Bool {
        isAlive(pid: pid, startedAt: startedAt)
    }
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
        guard let actualStart = ProcessTable.startTime(of: pid) else {
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

    /// The exact guard, when the descriptor allows it:
    ///
    /// - written in this pid namespace on this machine (`pidDomain == ownPidDomain`) with a
    ///   `procStart`: alive only while the pid exists and its start ticks equal `procStart`.
    ///   Field 22 of /proc/<pid>/stat is what Claude Code writes, so a reused pid can never match;
    /// - written in another domain (a distrobox or other container sharing `~/.claude`): not
    ///   ours, so not alive — its pid names a different process here, if any;
    /// - otherwise (no `pidDomain` or `procStart`, or no domain of our own, which is always the
    ///   case on macOS): `isAlive(pid:startedAt:)` and its 30 s window.
    public func isAlive(pid: pid_t, startedAt: Date?, procStart: UInt64?, pidDomain: String?) -> Bool {
        switch Self.identityCheck(procStart: procStart, pidDomain: pidDomain, ownDomain: Self.ownPidDomain) {
        case .foreign:
            return false
        case .exact(let expected):
            if kill(pid, 0) != 0, errno == ESRCH { return false }
            return ProcessTable.startTicks(of: pid) == expected
        case .window:
            return isAlive(pid: pid, startedAt: startedAt)
        }
    }

    /// Which guard `isAlive(pid:startedAt:procStart:pidDomain:)` applies.
    enum IdentityCheck: Equatable {
        /// Compare the live process's start ticks with this value.
        case exact(UInt64)
        /// Another pid namespace or machine wrote the descriptor.
        case foreign
        /// Not enough to go on: the one-sided start-time window.
        case window
    }

    static func identityCheck(procStart: UInt64?, pidDomain: String?, ownDomain: String?) -> IdentityCheck {
        guard let pidDomain, !pidDomain.isEmpty, let ownDomain else { return .window }
        guard pidDomain == ownDomain else { return .foreign }
        return procStart.map(IdentityCheck.exact) ?? .window
    }

    /// This process's `pidDomain`, spelled as Claude Code writes it:
    /// `linux:<machine-id>:pid:[<inode of /proc/self/ns/pid>]`. Nil on macOS, and on Linux when
    /// either part cannot be read — every descriptor then falls back to the 30 s window.
    public static let ownPidDomain: String? = {
        #if os(Linux)
        let machineID = ["/etc/machine-id", "/var/lib/dbus/machine-id"].lazy
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .first
        let namespace = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/ns/pid")
        return pidDomain(machineID: machineID, pidNamespace: namespace)
        #else
        return nil
        #endif
    }()

    /// `linux:<machine-id>:<pid namespace link>` (`pid:[4026531836]`), or nil when either is
    /// missing or empty.
    static func pidDomain(machineID: String?, pidNamespace: String?) -> String? {
        let id = machineID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let namespace = pidNamespace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, namespace.hasPrefix("pid:[") else { return nil }
        return "linux:\(id):\(namespace)"
    }
}
