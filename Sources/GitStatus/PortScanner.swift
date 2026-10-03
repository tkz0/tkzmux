// PortScanner — listening TCP ports under a session's process tree (M4.3).
//
// A dev server spawned by Claude (or by a shell it drove) shows up as a listening TCP socket on
// some descendant pid, not necessarily the session's own pid — `npm run dev` forks node, which may
// fork again. So the scan walks the whole descendant tree (BFS, depth-capped) and asks for the
// listening sockets of every process in it. Both halves are TkzPlatform's (WOR-306 S4):
// `ProcessTable` for the tree and the names, `ListeningPorts` for the sockets — libproc on macOS,
// /proc on Linux, where the TCP table (/proc/net/tcp and tcp6) is read once per scan and joined
// with each pid's /proc/<pid>/fd links. `GitStatus` does not depend on `AgentBridge` (and must
// not — it is a lower-level, git-focused module usable without Claude at all); TkzPlatform is
// below both.
//
// Everything below is best-effort: a pid that exits mid-scan, or one this process lacks permission
// to inspect, is skipped silently. This is polled every ~10s from a live UI, so it must never throw,
// log per-pid noise, or block on a runaway tree — hence the depth cap and the total-process cap.

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif
import TkzPlatform

/// One listening TCP socket found in a session's process tree.
public struct ListeningPort: Hashable, Sendable, Comparable {
    public var port: UInt16
    public var pid: pid_t
    /// The owning process's name (`ProcessTable.name`: `proc_name` on macOS, `comm` on Linux), for
    /// the badge tooltip. `nil` if unreadable.
    public var processName: String?

    public init(port: UInt16, pid: pid_t, processName: String?) {
        self.port = port
        self.pid = pid
        self.processName = processName
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        return lhs.pid < rhs.pid
    }
}

public enum PortScanner {
    /// A pathological tree (e.g. a shell fork bomb) must not stall a caller polling every 10s.
    private static let maxProcessesVisited = 512

    /// Every distinct listening TCP port under `rootPid` (inclusive), ascending, one entry per
    /// port (the first owner wins when v4 and v6 sockets duplicate a port).
    public static func scan(rootPid: pid_t, maxDepth: Int = 8) -> [ListeningPort] {
        var seenPorts: Set<UInt16> = []
        var names: [pid_t: String?] = [:]
        var result: [ListeningPort] = []
        // One `ListeningPorts` call for the whole tree: on Linux that is one read of the TCP table.
        for socket in ListeningPorts.scan(pids: processTree(from: rootPid, maxDepth: maxDepth)) {
            guard seenPorts.insert(socket.port).inserted else { continue }
            if names[socket.pid] == nil { names[socket.pid] = .some(processName(of: socket.pid)) }
            let name = names[socket.pid] ?? nil
            result.append(ListeningPort(port: socket.port, pid: socket.pid, processName: name))
        }
        return result.sorted()
    }

    /// Just the port numbers, ascending — what `LiveSessionState.ports` stores.
    public static func listeningPorts(rootPid: pid_t, maxDepth: Int = 8) -> [UInt16] {
        scan(rootPid: rootPid, maxDepth: maxDepth).map(\.port)
    }

    /// Listening ports of one process, no tree walk, ascending and each port once.
    public static func listeningPorts(ofProcess pid: pid_t) -> [ListeningPort] {
        let sockets = ListeningPorts.scan(pids: [pid])
        guard !sockets.isEmpty else { return [] }
        let name = processName(of: pid)
        return sockets.map { ListeningPort(port: $0.port, pid: $0.pid, processName: name) }
    }

    /// BFS over `rootPid` and its descendants, depth-capped. Includes `rootPid` itself.
    public static func processTree(from rootPid: pid_t, maxDepth: Int = 8) -> [pid_t] {
        [rootPid]
            + ProcessTable.descendants(
                of: rootPid, maxDepth: maxDepth, maxProcesses: maxProcessesVisited - 1)
    }

    /// The process's short name (`ProcessTable.name`), or `nil`.
    public static func processName(of pid: pid_t) -> String? {
        ProcessTable.name(of: pid)
    }
}
