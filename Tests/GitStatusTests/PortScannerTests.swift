// PortScannerTests — M4.3 / TKZ-28.
//
// These are only meaningfully testable against real processes: `PortScanner` walks the live
// process table via libproc, so the tests spawn an actual listening process (a Python HTTP
// server) as a child of the test runner and poll for it to show up / disappear, rather than
// mocking libproc. `withKnownIssue`/an early return skips gracefully when `/usr/bin/python3` is
// unavailable so the suite still passes on a minimal CI image.

import Darwin
import Foundation
import Testing

@testable import GitStatus

@Suite(.serialized)
struct PortScannerTests {

    // MARK: - Helpers

    /// Binds an ephemeral TCP port on 127.0.0.1, reads the assigned port, then closes the socket
    /// so the caller can hand it to a child process. There is a small window where another
    /// process could grab the port before the child binds it; acceptable for a test.
    private static func freeEphemeralPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len)
            }
        }
        guard getResult == 0 else { return nil }
        return UInt16(bigEndian: actual.sin_port)
    }

    private static let python3Path = "/usr/bin/python3"

    private static var python3Available: Bool {
        FileManager.default.isExecutableFile(atPath: python3Path)
    }

    /// Polls `condition` up to ~5s (100ms steps).
    private static func poll(timeout: TimeInterval = 5, step: TimeInterval = 0.1, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: step)
        }
        return condition()
    }

    // MARK: - Tests

    @Test func spawnedListenerIsFound() throws {
        guard Self.python3Available else {
            // No python3 on this machine/image — nothing to spawn against.
            return
        }
        guard let port = Self.freeEphemeralPort() else {
            Issue.record("could not reserve an ephemeral port")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.python3Path)
        process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let rootPid = getpid()
        let found = Self.poll {
            PortScanner.scan(rootPid: rootPid).contains { $0.port == port }
        }
        #expect(found)

        let entry = PortScanner.scan(rootPid: rootPid).first { $0.port == port }
        #expect(entry?.pid == process.processIdentifier)
        #expect(entry?.processName != nil)

        process.terminate()
        process.waitUntilExit()

        let gone = Self.poll {
            !PortScanner.scan(rootPid: rootPid).contains { $0.port == port }
        }
        #expect(gone)
    }

    @Test func processTreeIncludesSelfAndChild() throws {
        guard Self.python3Available else { return }
        guard let port = Self.freeEphemeralPort() else {
            Issue.record("could not reserve an ephemeral port")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.python3Path)
        process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let rootPid = getpid()
        // Give the child a moment to actually appear as a child pid.
        _ = Self.poll {
            PortScanner.processTree(from: rootPid).contains(process.processIdentifier)
        }

        let tree = PortScanner.processTree(from: rootPid)
        #expect(tree.contains(rootPid))
        #expect(tree.contains(process.processIdentifier))

        // A depth cap of 0 must not run away — with no BFS levels expanded, only the root itself
        // is returned.
        let shallow = PortScanner.processTree(from: rootPid, maxDepth: 0)
        #expect(shallow == [rootPid])
    }

    @Test func purityAndRobustness() {
        // pid 1 (launchd) — must not crash; result may or may not be empty depending on
        // permissions, so only assert it runs to completion.
        _ = PortScanner.listeningPorts(ofProcess: 1)

        // An impossible pid returns an empty result rather than crashing.
        #expect(PortScanner.listeningPorts(ofProcess: 999_999) == [])
    }

    @Test func scanIsSortedAndDeduplicated() throws {
        let rootPid = getpid()
        let ports = PortScanner.scan(rootPid: rootPid).map(\.port)
        #expect(ports == ports.sorted())
        #expect(Set(ports).count == ports.count)

        guard Self.python3Available else { return }
        guard let port = Self.freeEphemeralPort() else {
            Issue.record("could not reserve an ephemeral port")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.python3Path)
        process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        _ = Self.poll { PortScanner.scan(rootPid: rootPid).contains { $0.port == port } }

        let withListener = PortScanner.scan(rootPid: rootPid)
        let listenerPorts = withListener.map(\.port)
        #expect(listenerPorts == listenerPorts.sorted())
        #expect(Set(listenerPorts).count == listenerPorts.count)
        // Exactly one entry for the spawned port even though a v4-only bind can still surface a
        // dual-stack fd depending on platform.
        #expect(withListener.filter { $0.port == port }.count == 1)
    }
}
