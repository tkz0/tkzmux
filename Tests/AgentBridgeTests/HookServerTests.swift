// Tests for HookServer's socket protocol: framing, malformed-line recovery, stale-socket cleanup,
// start/stop lifecycle. Exercises the server directly over a real AF_UNIX socket — no tkzmux-hook
// binary involved (that's HookBinaryTests). M3.2.
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
import TkzCore
import TkzTerminalCore

@testable import AgentBridge

/// Unix socket paths are capped at 104 bytes (`sun_path`; 108 on Linux), so sockets live under a short
/// `mkdtemp`-created directory in `/tmp` rather than `FileManager.default.temporaryDirectory`
/// (whose per-run path is often already close to that limit on its own).
private func makeSocketDir() throws -> URL {
    var template = Array("/tmp/tkzhs.XXXXXX".utf8CString)
    let result = template.withUnsafeMutableBufferPointer { buf -> UnsafeMutablePointer<CChar>? in
        mkdtemp(buf.baseAddress!)
    }
    guard result != nil else { throw TestSetupError.mkdtempFailed }
    let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private enum TestSetupError: Error { case mkdtempFailed }

/// An `AF_UNIX` stream socket. Glibc imports `SOCK_*` as an enum, hence `rawValue`.
private func unixStreamSocket() -> Int32 {
    #if os(macOS)
    socket(AF_UNIX, SOCK_STREAM, 0)
    #elseif os(Linux)
    socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

/// Never die to SIGPIPE if the server drops the connection mid-write. macOS sets `SO_NOSIGPIPE`
/// on the socket; Linux has none, so `sendBytes` passes `MSG_NOSIGNAL` instead.
private func suppressSigpipe(_ fd: Int32) {
    #if os(macOS)
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif
}

/// One write to a connected socket: `write` on macOS, `send(MSG_NOSIGNAL)` on Linux.
private func sendBytes(_ fd: Int32, _ base: UnsafeRawPointer?, _ count: Int) -> Int {
    #if os(macOS)
    write(fd, base, count)
    #elseif os(Linux)
    send(fd, base, count, Int32(MSG_NOSIGNAL))
    #endif
}

/// Binds `fd` to `path` and returns `bind`'s result.
private func bindUnix(_ fd: Int32, path: String) -> Int32 {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        path.withCString { cstr in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: cstr, count: min(path.utf8.count + 1, raw.count)))
        }
    }
    return withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
            #if os(macOS)
            Darwin.bind(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            #elseif os(Linux)
            Glibc.bind(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            #endif
        }
    }
}

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
    let fd = unixStreamSocket()
    #expect(fd >= 0)
    defer { close(fd) }
    suppressSigpipe(fd)
    try connectBlocking(fd: fd, path: socketPath.path)
    let bytes = Array(text.utf8)
    bytes.withUnsafeBytes { buf in
        _ = sendBytes(fd, buf.baseAddress, buf.count)
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
            guard case .hook(let payload, let sessionID, _, _) = frame else {
                Issue.record("expected a .hook frame")
                continue
            }
            #expect(sessionID == nil)
            #expect(payload.sessionId == "claude-session-1" || payload.sessionId == "claude-session-2")
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
        #expect(first.eventName == "UserPromptSubmit")
        #expect(second.eventName == "Stop")
    }

    /// A frame with no `agent` field is what an already-installed old shim keeps sending until
    /// `ShimInstaller.ensureInstalled` refreshes `bin/`, and every one of those is Claude's.
    @Test func frameWithNoAgentFieldParsesAsClaude() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")
        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        try sendLine(#"{"v":1,"type":"hook","event":"Stop","sid":"","ppid":1,"ts":1,"payload":{}}"# + "\n", to: socketPath)

        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
        guard case .hook(let payload, _, _, _) = frames[0] else {
            Issue.record("expected a .hook frame")
            return
        }
        #expect(payload.agent == .claude)
    }

    @Test func frameWithAgentCodexParsesAsCodex() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")
        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        try sendLine(#"{"v":1,"type":"hook","event":"Stop","agent":"codex","sid":"","ppid":1,"ts":1,"payload":{}}"# + "\n", to: socketPath)

        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
        guard case .hook(let payload, _, _, _) = frames[0] else {
            Issue.record("expected a .hook frame")
            return
        }
        #expect(payload.agent == .codex)
    }

    /// A launch frame with no `agent` field — an already-installed old shim — parses as Claude,
    /// same fallback as a `hook` frame's `agent`.
    @Test func launchFrameWithNoAgentFieldParsesAsClaude() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")
        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        try sendLine(
            #"{"v":1,"type":"launch","sid":"","pid":1,"cwd":"/tmp","config_dir":"/tmp/.claude","argv":["claude"]}"# + "\n",
            to: socketPath)

        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
        guard case .launch(let announcement) = frames[0] else {
            Issue.record("expected a .launch frame")
            return
        }
        #expect(announcement.agent == .claude)
    }

    @Test func launchFrameWithAgentCodexParsesAsCodex() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")
        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        try sendLine(
            #"{"v":1,"type":"launch","sid":"","pid":1,"cwd":"/tmp","config_dir":"/tmp/.codex","agent":"codex","argv":["codex"]}"# + "\n",
            to: socketPath)

        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
        guard case .launch(let announcement) = frames[0] else {
            Issue.record("expected a .launch frame")
            return
        }
        #expect(announcement.agent == .codex)
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
        let fd = unixStreamSocket()
        #expect(fd >= 0)
        suppressSigpipe(fd)
        try connectBlocking(fd: fd, path: socketPath.path)
        let payload = Array("not json at all\n{\"v\":1,\"type\":\"hook\",\"event\":\"Stop\",\"sid\":\"\",\"ppid\":9,\"ts\":9,\"payload\":{}}\n".utf8)
        payload.withUnsafeBytes { buf in _ = sendBytes(fd, buf.baseAddress, buf.count) }
        close(fd)

        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
        guard case .hook(let payload, _, let ppid, _) = frames[0] else {
            Issue.record("expected a .hook frame")
            return
        }
        #expect(payload.eventName == "Stop")
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
        let staleFD = unixStreamSocket()
        #expect(staleFD >= 0)
        let bindResult = bindUnix(staleFD, path: socketPath.path)
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

        let fd = unixStreamSocket()
        #expect(fd >= 0)
        suppressSigpipe(fd)
        try connectBlocking(fd: fd, path: socketPath.path)

        // 300 KiB with no newline at all: over the 256 KiB unterminated-buffer cap.
        let junk = [UInt8](repeating: 0x61, count: 300 * 1024)
        var offset = 0
        while offset < junk.count {
            let n = junk.withUnsafeBytes { buf -> Int in
                sendBytes(fd, buf.baseAddress!.advanced(by: offset), junk.count - offset)
            }
            if n <= 0 { break } // the server may have closed the connection already
            offset += n
        }

        // Detect the drop by poll(POLLIN) + read()==0 — never by expecting a write error, since
        // SO_NOSIGPIPE/MSG_NOSIGNAL only prevent the signal, not an EPIPE return once the peer is gone.
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

    /// Sockets are named per instance pid, so a crashed instance leaves one behind under a name
    /// no later launch reuses. The sweep removes exactly those: a dead instance socket goes, a
    /// live sibling (another running tkzmux) stays and keeps working, our own path is skipped,
    /// and files that are not instance sockets — the legacy `tkzmux.sock`, anything else — are
    /// never touched.
    @Test func staleSiblingSocketsAreSweptLiveOnesKept() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A crashed instance: bind-and-close leaves the file with nobody listening.
        let stale = dir.appendingPathComponent("tkzmux-111.sock")
        let staleFD = unixStreamSocket()
        #expect(staleFD >= 0)
        let bindResult = bindUnix(staleFD, path: stale.path)
        #expect(bindResult == 0)
        close(staleFD)

        // A running sibling.
        let live = dir.appendingPathComponent("tkzmux-222.sock")
        let collector = FrameCollector()
        let sibling = HookServer(socketPath: live) { collector.append($0) }
        try sibling.start()
        defer { sibling.stop() }

        // Not instance sockets: never candidates, whatever they contain.
        let legacy = dir.appendingPathComponent("tkzmux.sock")
        let notes = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: legacy)
        try Data("y".utf8).write(to: notes)
        // Our own name, not yet bound: skipped even though nothing listens on it.
        let own = dir.appendingPathComponent("tkzmux-333.sock")
        try Data().write(to: own)

        let removed = HookServer.sweepStaleInstanceSockets(in: dir, except: own)
        #expect(removed == ["tkzmux-111.sock"])
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(FileManager.default.fileExists(atPath: own.path))

        // The sibling was probed, not disturbed.
        try sendLine(#"{"v":1,"type":"hook","event":"Stop","sid":"","ppid":1,"ts":1,"payload":{}}"# + "\n", to: live)
        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)

        // A second sweep has nothing left to do, and our own server then starts on its name
        // (its own start replaces the dead placeholder).
        #expect(HookServer.sweepStaleInstanceSockets(in: dir, except: own).isEmpty)
        let server = HookServer(socketPath: own) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        #expect(server.isRunning)
    }

    /// Where the socket lives, and that the pane and the server agree on it. Linux: in
    /// `$XDG_RUNTIME_DIR/tkzmux`, created 0700, the socket itself 0600 — the whole access
    /// boundary, there is no peer-credential check. macOS: in the support directory, unchanged,
    /// whatever `XDG_RUNTIME_DIR` says. Either way the pane's `TKZMUX_SOCKET` for the same
    /// environment is the path the server listens on, and a frame sent there arrives.
    @Test func paneAndServerAgreeOnTheSocketDirectory() async throws {
        let runtimeRoot = try makeSocketDir()
        let support = try makeSocketDir()
        defer {
            try? FileManager.default.removeItem(at: runtimeRoot)
            try? FileManager.default.removeItem(at: support)
        }
        let environment = [
            "HOME": support.path, "PATH": "/usr/bin:/bin", "XDG_RUNTIME_DIR": runtimeRoot.path,
        ]
        let pid = getpid()
        let socketPath = HookSocket.url(
            in: HookSocket.directory(support: support, environment: environment), pid: pid)
        #if os(Linux)
        #expect(socketPath.path == "\(runtimeRoot.path)/tkzmux/tkzmux-\(pid).sock")
        #else
        #expect(socketPath.path == support.appending(path: "tkzmux-\(pid).sock").path)
        #endif

        let pane = TerminalEnvironment.make(
            sessionID: "S1", tkzmuxDir: support, baseEnvironment: environment, home: support.path,
            terminfoDirectory: nil, shell: .zsh)
        #expect(pane["TKZMUX_SOCKET"] == socketPath.path)

        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        func mode(_ path: String) -> Int {
            var info = stat()
            guard lstat(path, &info) == 0 else { return -1 }
            return Int(info.st_mode) & 0o777
        }
        #if os(Linux)
        #expect(mode(socketPath.deletingLastPathComponent().path) == 0o700)
        #endif
        #expect(mode(socketPath.path) == 0o600)

        try sendLine(#"{"v":1,"type":"hook","event":"Stop","sid":"S1","ppid":1,"ts":1,"payload":{}}"# + "\n", to: socketPath)
        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
    }

    #if os(Linux)
    /// The listener and every accepted connection are close-on-exec, so a pane spawned while a
    /// hook is connected never inherits either (`SOCK_CLOEXEC`, `accept4`).
    @Test func listenerAndConnectionsAreCloseOnExec() async throws {
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")
        let server = HookServer(socketPath: socketPath) { _ in }
        try server.start()
        defer { server.stop() }

        let client = unixStreamSocket()
        #expect(client >= 0)
        defer { close(client) }
        try connectBlocking(fd: client, path: socketPath.path)

        // The server's fds, found by socket inode: every socket in /proc/self/fd other than
        // `client` that /proc/net/unix lists under the bound path.
        func socketInode(_ fd: Int32) -> String? {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(fd)")) ?? ""
            return target.hasPrefix("socket:") ? target : nil
        }
        let clientInode = socketInode(client)
        let deadline = Date().addingTimeInterval(2)
        var serverFDs: [Int32] = []
        while Date() < deadline {
            let fds = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? [])
                .compactMap(Int32.init)
            serverFDs = fds.filter { fd in
                guard let inode = socketInode(fd), inode != clientInode else { return false }
                return HookServerTests.isServerSocket(inode: inode, path: socketPath.path)
            }
            if serverFDs.count >= 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(serverFDs.count >= 2, "expected the listener and one accepted connection")
        for fd in serverFDs {
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0, "fd \(fd) is inheritable")
        }
    }

    /// Whether the socket with `inode` (`socket:[N]`) is bound to `path`, as /proc/net/unix lists
    /// it: the listener and every connection it accepted carry the bound path; a client does not.
    static func isServerSocket(inode: String, path: String) -> Bool {
        let number = inode.dropFirst("socket:[".count).dropLast()
        // Read to EOF: /proc files report a size of 0, so a size-driven read sees nothing.
        guard let data = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/proc/net/unix")).readToEnd(),
            let table = String(data: data, encoding: .utf8)
        else { return false }
        return table.split(separator: "\n").contains { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            return fields.count >= 8 && fields[6] == number && fields[7] == path
        }
    }
    #endif
}
