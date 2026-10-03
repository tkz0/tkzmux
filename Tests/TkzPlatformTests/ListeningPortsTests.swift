// ListeningPorts (WOR-304 S6): IPv4 and IPv6 listeners of this process and of a child are found
// for the process that holds them, once per port, and a closed listener disappears. On Linux also:
// the /proc/net/tcp{,6} parser keeps exactly the LISTEN rows, the result matches `ss -ltnp` for
// the same pids, and a scan of 50 processes (the tree walk plus the port join) is timed. The
// budget is 5 ms in a release build (`swift test -c release`); a debug build only prints it.

import Foundation
import Synchronization
import Testing
@testable import TkzPlatform

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif

extension WatcherTests {
    @Suite struct ListeningPortsTests {
        @Test func listenersOfSelfAndChildAreFound() async throws {
            // v4 and v6 on one port count once; a second, v6-only port shows on its own.
            let shared = try Listener(.v4)
            defer { shared.close() }
            let sharedV6 = Listener.ipv6Available ? try Listener(.v6, port: shared.port) : nil
            defer { sharedV6?.close() }
            let v6 = Listener.ipv6Available ? try Listener(.v6) : nil
            defer { v6?.close() }
            if !Listener.ipv6Available { print("ListeningPorts: no IPv6 loopback here, IPv4 only") }
            // A listener the child holds as fd 3 and this process does not.
            let handed = try Listener(.v4)
            let child = try spawnChild("/bin/sleep", ["30"], fd3: handed.fd)
            handed.close()
            defer {
                kill(child, SIGKILL)
                reapBlocking(child)
            }

            let me = getpid()
            let mine = ([shared.port] + (v6.map { [$0.port] } ?? [])).sorted()
            let scan = ListeningPorts.scan(pids: [child, me, child])
            #expect(scan.filter { $0.pid == me }.map(\.port) == mine)
            #expect(scan.filter { $0.pid == child }.map(\.port) == [handed.port])
            // Grouped by pid in the order given; the repeated child is scanned once.
            #expect(scan.first?.pid == child)
            #expect(scan.count == mine.count + 1)
            #expect(ListeningPorts.ports(ofProcess: me) == mine)
            #expect(ListeningPorts.scan(pids: []).isEmpty)

            v6?.close()
            #expect(ListeningPorts.ports(ofProcess: me) == [shared.port])
            sharedV6?.close()
            shared.close()
            #expect(ListeningPorts.ports(ofProcess: me).isEmpty)
        }

        @Test func goneProcessHasNoPorts() throws {
            let pid = try spawnChild("/bin/sh", ["-c", "exit 0"])
            reapBlocking(pid)
            #expect(ListeningPorts.ports(ofProcess: pid).isEmpty)
            _ = ListeningPorts.ports(ofProcess: 1)  // not ours: no crash, whatever it answers
        }

        #if os(Linux)
        @Test func tablesKeepOnlyListenRows() {
            // Captured from /proc/net/tcp and tcp6 on the reference machine, with a TIME_WAIT (06),
            // an ESTABLISHED (01) and a listener with inode 0 (not a real socket) added.
            let tcp = """
                  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
                   0: 3600007F:0035 00000000:0000 0A 00000000:00000000 00:00000000 00000000   193        0 7313 1 0000000000000000 100 0 0 10 0
                   1: 0100007F:13EC 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1234567 1 0000000000000000 100 0 0 10 0
                   2: 0100007F:A1B2 0100007F:13EC 01 00000000:00000000 00:00000000 00000000  1000        0 7654321 1 0000000000000000 20 4 30 10 -1
                   3: 0100007F:C350 0100007F:13EC 06 00000000:00000000 03:00000C1D 00000000     0        0 0 3 0000000000000000
                   4: 0100007F:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 0 1 0000000000000000 100 0 0 10 0

                """
            let tcp6 = """
                  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
                   0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 99887766 1 0000000000000000 100 0 0 10 0
                   1: 00000000000000000000000000000000:FFFF 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 42 1 0000000000000000 100 0 0 10 0
                   2: 00000000000000000000000001000000:1F90 00000000000000000000000001000000:B00B 01 00000000:00000000 00:00000000 00000000  1000        0 99887767 1 0000000000000000 20 4 30 10 -1
                """
            #expect(ProcfsListeningPorts.parseTable(Array(tcp.utf8)) == [
                .init(inode: 7313, port: 53), .init(inode: 1_234_567, port: 5100),
            ])
            #expect(ProcfsListeningPorts.parseTable(Array(tcp6.utf8)) == [
                .init(inode: 99_887_766, port: 8080), .init(inode: 42, port: 65535),
            ])
            #expect(ProcfsListeningPorts.parseTable([]).isEmpty)
            #expect(ProcfsListeningPorts.parseTable(Array("header only\n".utf8)).isEmpty)
        }

        /// The same pids, the same answer as `ss -ltnp`.
        @Test func matchesSs() throws {
            guard let ss = ["/usr/bin/ss", "/bin/ss", "/usr/sbin/ss"].first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else {
                print("ListeningPorts: no ss on this machine, comparison skipped")
                return
            }
            let v4 = try Listener(.v4)
            defer { v4.close() }
            let v6 = Listener.ipv6Available ? try Listener(.v6) : nil
            defer { v6?.close() }
            if !Listener.ipv6Available { print("ListeningPorts: no IPv6 loopback here, IPv4 only") }
            let handed = try Listener(Listener.ipv6Available ? .v6 : .v4)
            let child = try spawnChild("/bin/sleep", ["30"], fd3: handed.fd)
            handed.close()
            defer {
                kill(child, SIGKILL)
                reapBlocking(child)
            }

            let pids: Set<pid_t> = [getpid(), child]
            let ours = Set(ListeningPorts.scan(pids: Array(pids)))
            let theirs = try ssListeners(ss).filter { pids.contains($0.pid) }
            #expect(ours == theirs)
            #expect(ours.contains(ListeningSocket(port: v4.port, pid: getpid())))
            if let v6 { #expect(ours.contains(ListeningSocket(port: v6.port, pid: getpid()))) }
            #expect(ours.contains(ListeningSocket(port: handed.port, pid: child)))
        }

        /// 50 children plus this process: the walk that finds them and the port join over them.
        @Test(.timeLimit(.minutes(1))) func scanOfFiftyProcessesIsQuick() async throws {
            var children: [pid_t] = []
            defer {
                for pid in children {
                    kill(pid, SIGKILL)
                    reapBlocking(pid)
                }
            }
            for _ in 0..<50 { children.append(try spawnChild("/bin/sleep", ["30"])) }
            let listener = try Listener(.v4)
            defer { listener.close() }

            var times: [UInt64] = []
            for _ in 0..<21 {
                let start = Clocks.monotonicNanos
                let tree = [getpid()] + ProcessTable.descendants(of: getpid())
                let found = ListeningPorts.scan(pids: tree)
                times.append(Clocks.monotonicNanos - start)
                #expect(tree.count >= 51)
                #expect(found.contains(ListeningSocket(port: listener.port, pid: getpid())))
            }
            times.sort()
            let median = Double(times[times.count / 2]) / 1e6
            #if DEBUG
            print("ListeningPorts: 51 processes in a median of \(median) ms (debug build, not checked)")
            #else
            print("ListeningPorts: 51 processes in a median of \(median) ms")
            #expect(median < 5, "median \(median) ms")
            #endif
        }

        /// (port, pid) for every row of `ss -ltnpH`; a socket shared by several processes gives
        /// one entry per process.
        private func ssListeners(_ ss: String) throws -> Set<ListeningSocket> {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ss)
            process.arguments = ["-ltnpH"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            var result = Set<ListeningSocket>()
            for line in output.split(separator: "\n") {
                // State Recv-Q Send-Q Local:Port Peer:Port users:(("name",pid=N,fd=N),…)
                let columns = line.split(separator: " ", omittingEmptySubsequences: true)
                guard columns.count >= 6, let colon = columns[3].lastIndex(of: ":"),
                    let port = UInt16(columns[3][columns[3].index(after: colon)...])
                else { continue }
                for match in columns[5...].joined(separator: " ").split(separator: "pid=").dropFirst() {
                    if let pid = pid_t(match.prefix(while: \.isNumber)) {
                        result.insert(ListeningSocket(port: port, pid: pid))
                    }
                }
            }
            return result
        }
        #endif
    }
}

/// A TCP socket listening on the loopback address, on an ephemeral port unless one is given.
final class Listener: Sendable {
    enum Family { case v4, v6 }

    private let descriptor: Atomic<Int32>
    let port: UInt16

    /// The socket, or -1 once closed.
    var fd: Int32 { descriptor.load(ordering: .relaxed) }

    /// Whether this machine can listen on ::1. Docker turns IPv6 off in containers whose network
    /// has none, which takes ::1 away too.
    static let ipv6Available: Bool = {
        guard let probe = try? Listener(.v6) else { return false }
        probe.close()
        return true
    }()

    init(_ family: Family, port requested: UInt16 = 0) throws {
        #if os(Linux)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        let fd = socket(family == .v4 ? AF_INET : AF_INET6, stream, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var storage = sockaddr_storage()
        let length: socklen_t
        switch family {
        case .v4:
            var address = sockaddr_in()
            #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = requested.bigEndian
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: address, as: sockaddr_in.self) }
        case .v6:
            var on: Int32 = 1
            setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            #if canImport(Darwin)
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_loopback
            address.sin6_port = requested.bigEndian
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: address, as: sockaddr_in6.self) }
        }
        let bound = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            closeDescriptor(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var actual = sockaddr_storage()
        var actualLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualLength) }
        }
        // sin_port and sin6_port are both at offset 2, on both OSes.
        let portBytes = withUnsafeBytes(of: actual) { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self) }
        descriptor = Atomic(fd)
        port = UInt16(bigEndian: portBytes)
    }

    deinit {
        close()
    }

    /// Closes the socket; later calls do nothing, so a closed fd number is never closed again.
    func close() {
        let fd = descriptor.exchange(-1, ordering: .relaxed)
        if fd >= 0 { closeDescriptor(fd) }
    }
}

/// close(2), named so `Listener.close()` does not shadow it.
private func closeDescriptor(_ fd: Int32) {
    close(fd)
}
