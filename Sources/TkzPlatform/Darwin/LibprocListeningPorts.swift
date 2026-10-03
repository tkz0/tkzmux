// The macOS `ListeningPorts` (WOR-304 S6): libproc, one process at a time.
//
// The fd walk is GitStatus's `PortScanner.listeningPorts(ofProcess:)` lifted verbatim, without the
// process name (PortScanner adds it).

#if canImport(Darwin)
import Darwin

public enum LibprocListeningPorts: ListeningPortsBackend {
    public static func scan(pids: [pid_t]) -> [ListeningSocket] {
        var seen = Set<pid_t>()
        var result: [ListeningSocket] = []
        for pid in pids where pid > 0 && seen.insert(pid).inserted {
            result += Set(listeningPorts(ofProcess: pid)).sorted().map { ListeningSocket(port: $0, pid: pid) }
        }
        return result
    }

    /// Listening ports of one process, in fd order, possibly repeated (v4 and v6).
    static func listeningPorts(ofProcess pid: pid_t) -> [UInt16] {
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

        var results: [UInt16] = []
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
            results.append(port)
        }
        return results
    }
}
#endif
