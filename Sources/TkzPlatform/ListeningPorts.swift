// ListeningPorts — which TCP ports a set of processes is listening on, per OS (WOR-304 S6).
//
//   Linux  `ProcfsListeningPorts` (Linux/): /proc/self/net/tcp and tcp6, read once per scan, for
//          the inode of every socket in LISTEN; then each pid's /proc/<pid>/fd links
//          (`socket:[<inode>]`) are joined against them.
//   macOS  `LibprocListeningPorts` (Darwin/): each pid's fds through PROC_PIDLISTFDS and
//          PROC_PIDFDSOCKETINFO, lifted from GitStatus's `PortScanner`.
//
// `ListeningPorts` names the back-end for the OS being built. GitStatus's `PortScanner` keeps the
// tree walk, the per-port de-duplication and the process names, and calls this once per scan
// (WOR-306 S4).
//
// Best-effort like ProcessTable: a pid that exits mid-scan or may not be inspected has no ports.

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// One process listening on one TCP port.
public struct ListeningSocket: Hashable, Sendable {
    public var port: UInt16
    public var pid: pid_t

    public init(port: UInt16, pid: pid_t) {
        self.port = port
        self.pid = pid
    }
}

/// The call every `ListeningPorts` back-end answers.
public protocol ListeningPortsBackend {
    /// The TCP ports each of `pids` holds a listening socket on (IPv4 and IPv6). Grouped by pid in
    /// the order given, ports ascending within a pid, each (port, pid) once: an IPv4 and an IPv6
    /// listener on one port by one process count once. A socket shared by several processes (an
    /// inherited listener) is reported for each of them. Repeated pids are scanned once.
    static func scan(pids: [pid_t]) -> [ListeningSocket]
}

extension ListeningPortsBackend {
    /// The listening TCP ports of one process, ascending.
    public static func ports(ofProcess pid: pid_t) -> [UInt16] {
        scan(pids: [pid]).map(\.port)
    }
}

#if os(Linux)
/// The listening-port scanner of the OS being built.
public typealias ListeningPorts = ProcfsListeningPorts
#elseif canImport(Darwin)
/// The listening-port scanner of the OS being built.
public typealias ListeningPorts = LibprocListeningPorts
#endif
