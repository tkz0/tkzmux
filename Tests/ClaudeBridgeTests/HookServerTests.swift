// Tests for HookServer's socket protocol: framing, malformed-line recovery, stale-socket cleanup,
// start/stop lifecycle. Exercises the server directly over a real AF_UNIX socket — no tkzmux-hook
// binary involved (that's HookBinaryTests). M3.2 (TKZ-22).
import Darwin
import Foundation
import Synchronization
import Testing
import TkzCore

@testable import ClaudeBridge

/// Unix socket paths are capped at 104 bytes (`sun_path`), so sockets live under a short
/// `mkdtemp`-created directory in `/tmp` rather than `FileManager.default.temporaryDirectory`
/// (whose per-run path is often already close to that limit on its own).
private func makeSocketDir() throws -> URL {
    var template = Array("/tmp/tkzhs.XXXXXX".utf8CString)
    let result = template.withUnsafeMutableBufferPointer { buf -> UnsafeMutablePointer<CChar>? in
        mkdtemp(buf.baseAddress)
    }
    guard result != nil else { throw TestSetupError.mkdtempFailed }
    let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private enum TestSetupError: Error { case mkdtempFailed }

/// Collects frames delivered on HookServer's queue, safe to poll from the test's task.
private final class FrameCollector: Sendable {
    private let storage = Mutex<[HookFrame]>([])

    func append(_ frame: HookFrame) {
        storage.withLock { $0.append(frame) }
    }

    var frames: [HookFrame] {
        storage.withLock { $0 }
    }

    func waitFor(count: Int, timeout: TimeInterval = 2) async -> [HookFrame] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = frames
            if current.count >= count { return current }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return frames
    }
}

/// Writes `text` (already newline-terminated) as a single line to a fresh connection, then closes it.
private func sendLine(_ text: String, to socketPath: URL) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer { close(fd) }
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    try connectBlocking(fd: fd, path: socketPath.path)
    let bytes = Array(text.utf8)
    bytes.withUnsafeBytes { buf in
        _ = write(fd, buf.baseAddress, buf.count)
    }
}

private func connectBlocking(fd: Int32, path: String) throws {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        path.withCString { cstr in
            let len = path.utf8.count + 1
            raw.copyMemory(from: UnsafeRawBufferPointer(start: cstr, count: min(len, raw.count)))
        }
    }
    let result = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
            connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(result == 0, "connect() failed: errno \(errno)")
}

@Suite struct HookServerTests {
    @Test func missingOrEmptySidYieldsNilSessionID() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")
        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        try sendLine(#"{"v":1,"type":"hook","event":"Stop","ppid":123,"ts":1,"payload":{"session_id":"claude-session-1"}}"# + "\n", to: socketPath)
        try sendLine(#"{"v":1,"type":"hook","event":"Stop","sid":"","ppid":124,"ts":2,"payload":{"session_id":"claude-session-2"}}"# + "\n", to: socketPath)

        let frames = await collector.waitFor(count: 2)
        #expect(frames.count == 2)
        for frame in frames {
            guard case .hook(let event, _, _, _) = frame else {
                Issue.record("expected a .hook frame")
                continue
            }
            #expect(event.sessionID == nil)
            #expect(event.claudeSessionId == "claude-session-1" || event.claudeSessionId == "claude-session-2")
        }
    }

    @Test func twoConnectionsArriveInOrder() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")
        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        try sendLine(#"{"v":1,"type":"hook","event":"UserPromptSubmit","sid":"","ppid":1,"ts":1,"payload":{}}"# + "\n", to: socketPath)
        // Give the server a moment to fully process the first connection before the second opens,
        // so arrival order is deterministic rather than racing two concurrent accepts.
        try await Task.sleep(nanoseconds: 30_000_000)
        try sendLine(#"{"v":1,"type":"hook","event":"Stop","sid":"","ppid":2,"ts":2,"payload":{}}"# + "\n", to: socketPath)

        let frames = await collector.waitFor(count: 2)
        #expect(frames.count == 2)
        guard case .hook(let first, _, _, _) = frames[0], case .hook(let second, _, _, _) = frames[1] else {
            Issue.record("expected two .hook frames")
            return
        }
        #expect(first.kind == .userPromptSubmit)
        #expect(second.kind == .stop)
    }

    @Test func malformedLineDroppedNextGoodFrameArrives() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")
        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        // Two lines over one connection: first malformed, second a good Stop frame.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        try connectBlocking(fd: fd, path: socketPath.path)
        let payload = Array("not json at all\n{\"v\":1,\"type\":\"hook\",\"event\":\"Stop\",\"sid\":\"\",\"ppid\":9,\"ts\":9,\"payload\":{}}\n".utf8)
        payload.withUnsafeBytes { buf in _ = write(fd, buf.baseAddress, buf.count) }
        close(fd)

        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
        guard case .hook(let event, let ppid, _, _) = frames[0] else {
            Issue.record("expected a .hook frame")
            return
        }
        #expect(event.kind == .stop)
        #expect(ppid == 9)
    }

    @Test func unknownVersionIgnored() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")
        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        try sendLine(#"{"v":2,"type":"hook","event":"Stop","sid":"","ppid":1,"ts":1,"payload":{}}"# + "\n", to: socketPath)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(collector.frames.isEmpty)
    }

    @Test func staleSocketFileIsReplaced() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")

        // Bind-and-close leaves a socket file with nobody listening — a stand-in for a crashed run.
        let staleFD = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(staleFD >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.path
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withCString { cstr in
                raw.copyMemory(from: UnsafeRawBufferPointer(start: cstr, count: min(path.utf8.count + 1, raw.count)))
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.bind(staleFD, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bindResult == 0)
        close(staleFD) // no unlink: the file survives, nothing is listening on it

        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        #expect(server.isRunning)

        try sendLine(#"{"v":1,"type":"hook","event":"Stop","sid":"","ppid":1,"ts":1,"payload":{}}"# + "\n", to: socketPath)
        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
    }

    @Test func oversizedUnterminatedFrameDropsConnection() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")
        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        try connectBlocking(fd: fd, path: socketPath.path)

        // 300 KiB with no newline at all: over the 256 KiB unterminated-buffer cap.
        let junk = [UInt8](repeating: 0x61, count: 300 * 1024)
        var offset = 0
        while offset < junk.count {
            let n = junk.withUnsafeBytes { buf -> Int in
                write(fd, buf.baseAddress!.advanced(by: offset), junk.count - offset)
            }
            if n <= 0 { break } // the server may have closed the connection already
            offset += n
        }

        // Detect the drop by poll(POLLIN) + read()==0 — never by expecting a write error, since
        // SO_NOSIGPIPE only prevents the signal, not an EPIPE return once the peer is gone.
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pfd, 1, 2000)
        #expect(pollResult > 0)
        var buf = [UInt8](repeating: 0, count: 16)
        let n = buf.withUnsafeMutableBytes { ptr -> Int in read(fd, ptr.baseAddress, ptr.count) }
        #expect(n == 0, "expected EOF once the server dropped the oversized connection")
        close(fd)
        #expect(collector.frames.isEmpty)
    }

    @Test func stopRemovesSocketAndSecondStartWorks() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")
        let collector = FrameCollector()

        let server1 = HookServer(socketPath: socketPath) { collector.append($0) }
        try server1.start()
        #expect(FileManager.default.fileExists(atPath: socketPath.path))
        server1.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath.path))

        let server2 = HookServer(socketPath: socketPath) { collector.append($0) }
        try server2.start()
        defer { server2.stop() }
        #expect(server2.isRunning)

        try sendLine(#"{"v":1,"type":"hook","event":"Stop","sid":"","ppid":1,"ts":1,"payload":{}}"# + "\n", to: socketPath)
        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
    }
}
