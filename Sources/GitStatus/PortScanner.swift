// PortScanner — listening TCP ports under a session's process tree (M4.3 / TKZ-28).
//
// A dev server spawned by Claude (or by a shell it drove) shows up as a listening TCP socket on
// some descendant pid, not necessarily the session's own pid — `npm run dev` forks node, which may
// fork again. So the scan walks the whole descendant tree (BFS, depth-capped) and inspects every
// process's open file descriptors for listening sockets, the same shape of problem
// `ClaudeBridge.ProcessLiveness` solves for liveness. `GitStatus` does not depend on `ClaudeBridge`
// (and must not — it is a lower-level, git-focused module usable without Claude at all), so the
// `proc_listchildpids` walk is re-implemented here rather than shared; the duplication is
// deliberate, not an oversight.
//
// Everything below is best-effort: a pid that exits mid-scan, or one this process lacks permission
// to inspect, is skipped silently. This is polled every ~10s from a live UI, so it must never throw,
// log per-pid noise, or block on a runaway tree — hence the depth cap and the total-process cap.

import Darwin

/// One listening TCP socket found in a session's process tree.
public struct ListeningPort: Hashable, Sendable, Comparable {
    public var port: UInt16
    public var pid: pid_t
    /// The owning process's name (`proc_name`), for the badge tooltip. `nil` if unreadable.
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
        var result: [ListeningPort] = []
        for pid in processTree(from: rootPid, maxDepth: maxDepth) {
            for entry in listeningPorts(ofProcess: pid) {
                guard seenPorts.insert(entry.port).inserted else { continue }
                result.append(entry)
            }
        }
        return result.sorted()
    }

    /// Just the port numbers, ascending — what `LiveSessionState.ports` stores.
    public static func listeningPorts(rootPid: pid_t, maxDepth: Int = 8) -> [UInt16] {
        scan(rootPid: rootPid, maxDepth: maxDepth).map(\.port)
    }

    /// Listening ports of one process, no tree walk. The unit-testable core.
    public static func listeningPorts(ofProcess pid: pid_t) -> [ListeningPort] {
        // PROC_PIDLISTFDS sizing call: unlike proc_listchildpids, this one *does* return a byte
        // count (not an fd count), so the buffer is sized from it directly.
        let initialSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard initialSize > 0 else { return [] }

        // fds can appear between the sizing call and the fill call, so ask for a bit more room
        // and only use as much as actually came back.
        let bufferSize = Int(initialSize) + Int(MemoryLayout<proc_fdinfo>.stride) * 32
        var fdInfos = [proc_fdinfo](
            repeating: proc_fdinfo(), count: bufferSize / MemoryLayout<proc_fdinfo>.stride)
        let filledSize = fdInfos.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filledSize > 0 else { return [] }
        let fdCount = Int(filledSize) / MemoryLayout<proc_fdinfo>.stride
        guard fdCount > 0 else { return [] }

        let name = processName(of: pid)
        var results: [ListeningPort] = []
        for fdInfo in fdInfos.prefix(fdCount) {
            guard fdInfo.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            var socketInfo = socket_fdinfo()
            let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            let result = withUnsafeMutablePointer(to: &socketInfo) {
                proc_pidfdinfo(pid, fdInfo.proc_fd, PROC_PIDFDSOCKETINFO, $0, socketInfoSize)
            }
            guard result == socketInfoSize else { continue }
            guard socketInfo.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcpInfo = socketInfo.psi.soi_proto.pri_tcp
            guard tcpInfo.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcpInfo.tcpsi_ini.insi_lport))
            guard port != 0 else { continue }
            results.append(ListeningPort(port: port, pid: pid, processName: name))
        }
        return results
    }

    /// BFS over `rootPid` and its descendants, depth-capped. Includes `rootPid` itself.
    public static func processTree(from rootPid: pid_t, maxDepth: Int = 8) -> [pid_t] {
        var visited: [pid_t] = [rootPid]
        var visitedSet: Set<pid_t> = [rootPid]
        var frontier: [pid_t] = [rootPid]
        var depth = 0
        while depth < maxDepth, !frontier.isEmpty, visited.count < maxProcessesVisited {
            var next: [pid_t] = []
            for pid in frontier {
                for child in children(of: pid) {
                    guard visitedSet.insert(child).inserted else { continue }
                    visited.append(child)
                    next.append(child)
                    if visited.count >= maxProcessesVisited { break }
                }
                if visited.count >= maxProcessesVisited { break }
            }
            frontier = next
            depth += 1
        }
        return visited
    }

    /// `proc_name` for a pid, or `nil`.
    public static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let result = proc_name(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // Direct children of `pid` via `proc_listchildpids`. Re-implemented from
    // `ClaudeBridge.ProcessTree.children(of:)` rather than shared, per the header comment above:
    // `GitStatus` must not depend on `ClaudeBridge`. Its return value is the **number of pids
    // written**, not a byte count, and (unlike proc_listallpids) it does not support the
    // NULL-sizing idiom, so a fixed, generous buffer is used and the return value indexes directly
    // into it.
    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }
}
