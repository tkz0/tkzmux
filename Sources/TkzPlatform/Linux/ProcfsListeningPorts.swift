// The Linux `ListeningPorts` (WOR-304 S6): /proc/net joined with /proc/<pid>/fd.
//
// /proc/<pid>/net/tcp is not per process: it is the whole TCP table of the process's network
// namespace. So a scan reads /proc/self/net/tcp and tcp6 once, keeps the rows whose state is
// LISTEN (`st` 0A) as a map from socket inode to local port, and then reads each pid's fd links,
// where a socket shows as `socket:[<inode>]`. A process in another network namespace (a
// container) has inodes that are not in this table, so it reports no ports.
//
// Reading another process's fd directory needs the same permission as ptrace-reading it, so only
// this user's processes are seen, which is all tkzmux asks about.

#if os(Linux)
import Glibc

public enum ProcfsListeningPorts: ListeningPortsBackend {
    public static func scan(pids: [pid_t]) -> [ListeningSocket] {
        var seen = Set<pid_t>()
        let unique = pids.filter { $0 > 0 && seen.insert($0).inserted }
        guard !unique.isEmpty else { return [] }
        let listeners = listeningInodes()
        guard !listeners.isEmpty else { return [] }
        var result: [ListeningSocket] = []
        for pid in unique {
            var ports = Set<UInt16>()
            forEachSocketInode(of: pid) { inode in
                if let port = listeners[inode] { ports.insert(port) }
            }
            result += ports.sorted().map { ListeningSocket(port: $0, pid: pid) }
        }
        return result
    }

    // MARK: /proc/net

    /// One LISTEN row of a /proc/net/tcp or tcp6 table.
    struct ListenRow: Hashable {
        var inode: UInt64
        var port: UInt16
    }

    /// Socket inode → local port, for every TCP socket in LISTEN in this network namespace.
    static func listeningInodes() -> [UInt64: UInt16] {
        var map: [UInt64: UInt16] = [:]
        for table in ["/proc/self/net/tcp", "/proc/self/net/tcp6"] {
            guard let bytes = Procfs.read(table) else { continue }
            for row in parseTable(bytes) { map[row.inode] = row.port }
        }
        return map
    }

    /// The LISTEN rows of a /proc/net/tcp or tcp6 table (the same layout; only the address width
    /// differs). After the header line, each row's space-separated fields are
    /// `sl local_address rem_address st tx:rx tr:when retrnsmt uid timeout inode …`, where
    /// `local_address` is `<hex address>:<hex port>` and `st` is the hex TCP state.
    static func parseTable(_ bytes: [UInt8]) -> [ListenRow] {
        var rows: [ListenRow] = []
        for line in bytes.split(separator: 0x0A).dropFirst() {
            let fields = line.split(separator: 0x20, omittingEmptySubsequences: true)
            guard fields.count > 9, fields[3].elementsEqual("0A".utf8),
                let colon = fields[1].lastIndex(of: 0x3A),
                let port = number(fields[1][(colon + 1)...], radix: 16).flatMap({ UInt16(exactly: $0) }),
                let inode = number(fields[9], radix: 10),
                port != 0, inode != 0
            else { continue }
            rows.append(ListenRow(inode: inode, port: port))
        }
        return rows
    }

    /// An unsigned number in `radix` (10 or 16, upper- or lowercase), or nil.
    private static func number(_ field: ArraySlice<UInt8>, radix: UInt64) -> UInt64? {
        guard !field.isEmpty, field.count <= 16 else { return nil }
        var value: UInt64 = 0
        for byte in field {
            let digit: UInt64
            switch byte {
            case 0x30...0x39: digit = UInt64(byte - 0x30)
            case 0x41...0x46 where radix == 16: digit = UInt64(byte - 0x41 + 10)
            case 0x61...0x66 where radix == 16: digit = UInt64(byte - 0x61 + 10)
            default: return nil
            }
            let (shifted, overflow) = value.multipliedReportingOverflow(by: radix)
            guard !overflow else { return nil }
            value = shifted + digit
        }
        return value
    }

    // MARK: /proc/<pid>/fd

    private static let socketPrefix = Array("socket:[".utf8)

    /// Calls `body` with the inode of every socket among `pid`'s open fds.
    static func forEachSocketInode(of pid: pid_t, _ body: (UInt64) -> Void) {
        // Socket links are short (`socket:[4294967295]`); anything longer is not one.
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 64) { buffer in
            _ = Procfs.forEachEntry(in: "/proc/\(pid)/fd") { name, directoryFD in
                let count = readlinkat(directoryFD, name, buffer.baseAddress!, buffer.count)
                guard count > socketPrefix.count + 1, count < buffer.count else { return }
                let target = UnsafeRawBufferPointer(start: buffer.baseAddress!, count: count)
                guard target.starts(with: socketPrefix), target[count - 1] == 0x5D else { return }
                let digits = Array(target[socketPrefix.count..<(count - 1)])
                if let inode = number(digits[...], radix: 10) { body(inode) }
            }
        }
    }
}
#endif
