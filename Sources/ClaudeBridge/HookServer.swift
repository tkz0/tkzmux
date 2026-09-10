// HookServer — the app-side half of the tkzmux-hook wire protocol. See docs/design.md → Claude
// integration → tkzmux-hook, and Sources/tkzmux-hook for the client. M3.2 (TKZ-22).
import Darwin
import Dispatch
import Foundation
import Synchronization
import TkzCore
import os

public enum HookServerError: Error, Sendable {
    case socketCreateFailed(Int32)
    case pathTooLong
    case bindFailed(Int32)
    case listenFailed(Int32)
    case alreadyRunning
}

/// Listens on a Unix domain socket for NDJSON frames from `tkzmux-hook`, one frame per connection.
/// All socket work happens on a private serial queue; `onFrame` is called on that queue, in arrival
/// order. Not `@unchecked Sendable`: state lives in a `Mutex` (the same pattern `Pty` uses for its
/// `DispatchSource` handles), which the standard library itself makes safe to share.
public final class HookServer: Sendable {
    public let socketPath: URL

    private let onFrame: @Sendable (HookFrame) -> Void
    private let queue = DispatchQueue(label: "se.tkz.tkzmux.hookserver")
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "hookserver")
    private let state: Mutex<State>

    /// Per-connection state: the growing read buffer plus its `DispatchSourceRead`. A value type
    /// (not a class, unlike `Connection`-style designs) so `State` — and therefore everything the
    /// `Mutex` protects — stays a plain Sendable struct, matching the pattern `Pty.State` uses for
    /// its own `DispatchSource` fields.
    private struct ConnectionState: Sendable {
        var readSource: (any DispatchSourceRead)?
        var buffer: [UInt8] = []
    }

    private struct State {
        var listenFD: Int32 = -1
        var acceptSource: (any DispatchSourceRead)?
        var connections: [Int32: ConnectionState] = [:]
        var running = false
    }

    private static let maxUnterminatedBuffer = 256 * 1024
    private static let readChunkSize = 65536

    public init(socketPath: URL, onFrame: @escaping @Sendable (HookFrame) -> Void) {
        self.socketPath = socketPath
        self.onFrame = onFrame
        self.state = Mutex(State())
    }

    public var isRunning: Bool {
        state.withLock { $0.running }
    }

    public func start() throws {
        try queue.sync {
            try self.startOnQueue()
        }
    }

    /// Stops accepting connections, cancels open ones, and removes the socket file. Must not be
    /// called from inside `onFrame` (or any block running on `queue`) — `queue.sync` would deadlock.
    public func stop() {
        queue.sync {
            self.stopOnQueue()
        }
    }

    // MARK: - Queue-confined implementation

    private func startOnQueue() throws {
        guard !(state.withLock { $0.running }) else { throw HookServerError.alreadyRunning }

        let dir = socketPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = socketPath.path
        guard path.utf8.count < HookServer.sunPathCapacity else {
            throw HookServerError.pathTooLong
        }

        removeStaleSocketIfNeeded(at: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookServerError.socketCreateFailed(errno) }

        var addr = HookServer.makeSockaddr(path: path)
        let bindResult = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.bind(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw HookServerError.bindFailed(e)
        }

        chmod(path, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw HookServerError.listenFailed(e)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection(listenFD: fd)
        }
        source.setCancelHandler {
            close(fd)
        }

        state.withLock { s in
            s.listenFD = fd
            s.acceptSource = source
            s.running = true
        }
        source.resume()
    }

    private func stopOnQueue() {
        let (readSources, acceptSource, path) = state.withLock { s -> ([(any DispatchSourceRead)?], (any DispatchSourceRead)?, String) in
            let sources = s.connections.values.map(\.readSource)
            let accept = s.acceptSource
            s.connections.removeAll()
            s.acceptSource = nil
            s.listenFD = -1
            s.running = false
            return (sources, accept, self.socketPath.path)
        }
        for source in readSources {
            source?.cancel()
        }
        acceptSource?.cancel()
        unlink(path)
    }

    /// A socket file left behind by a previous run (crash, force-kill) blocks `bind` with
    /// `EADDRINUSE` even though nothing is listening. Probe it with a real `connect()`: only when
    /// that fails do we know it's safe to `unlink` — a live server's socket must never be removed
    /// out from under it.
    private func removeStaleSocketIfNeeded(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let probeFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeFD >= 0 else { return }
        defer { close(probeFD) }

        var addr = HookServer.makeSockaddr(path: path)
        let result = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(probeFD, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            logger.info("removing stale hook socket at \(path, privacy: .public)")
            unlink(path)
        }
    }

    private func acceptConnection(listenFD: Int32) {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        let flags = fcntl(clientFD, F_GETFL, 0)
        _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.readAvailable(fd: clientFD)
        }
        readSource.setCancelHandler {
            close(clientFD)
        }

        state.withLock { s in
            s.connections[clientFD] = ConnectionState(readSource: readSource, buffer: [])
        }
        readSource.resume()
    }

    private func readAvailable(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: HookServer.readChunkSize)
        let n = buf.withUnsafeMutableBytes { ptr -> Int in
            read(fd, ptr.baseAddress, ptr.count)
        }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            closeConnection(fd: fd)
            return
        }
        if n == 0 {
            closeConnection(fd: fd)
            return
        }

        var completedLines: [[UInt8]] = []
        var overLimit = false
        state.withLock { s in
            guard var conn = s.connections[fd] else { return }
            conn.buffer.append(contentsOf: buf[0..<n])
            while let newlineIndex = conn.buffer.firstIndex(of: 0x0A) {
                completedLines.append(Array(conn.buffer[0..<newlineIndex]))
                conn.buffer.removeFirst(newlineIndex + 1)
            }
            if conn.buffer.count > HookServer.maxUnterminatedBuffer {
                overLimit = true
            }
            s.connections[fd] = conn
        }

        for line in completedLines {
            handleLine(line)
        }

        if overLimit {
            logger.warning("hook connection exceeded \(HookServer.maxUnterminatedBuffer) bytes without a newline; dropping")
            closeConnection(fd: fd)
        }
    }

    private func closeConnection(fd: Int32) {
        let readSource = state.withLock { s -> (any DispatchSourceRead)? in
            let rs = s.connections[fd]?.readSource
            s.connections.removeValue(forKey: fd)
            return rs
        }
        readSource?.cancel()
    }

    private func handleLine(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any] else {
            logger.warning("dropping malformed hook frame (invalid JSON)")
            return
        }
        guard let v = obj["v"] as? Int, v == 1 else { return }
        guard let type = obj["type"] as? String else { return }

        switch type {
        case "hook":
            guard let frame = Self.parseHookFrame(obj) else {
                logger.warning("dropping malformed hook frame (bad 'hook' fields)")
                return
            }
            onFrame(frame)
        case "launch":
            guard let frame = Self.parseLaunchFrame(obj) else {
                logger.warning("dropping malformed hook frame (bad 'launch' fields)")
                return
            }
            onFrame(frame)
        default:
            return // unknown type, silently ignored per the wire protocol
        }
    }

    // MARK: - Frame parsing

    private static func parseHookFrame(_ obj: [String: Any]) -> HookFrame? {
        guard let event = obj["event"] as? String else { return nil }
        let sid = (obj["sid"] as? String) ?? ""
        let ppidRaw = (obj["ppid"] as? Int) ?? 0
        let payload = (obj["payload"] as? [String: Any]) ?? [:]

        let claudeSessionId = payload["session_id"] as? String
        let notificationTypeRaw = payload["notification_type"] as? String
        let lastAssistantMessageFull = payload["last_assistant_message"] as? String
        let source = payload["source"] as? String
        let reason = payload["reason"] as? String
        let cwd = payload["cwd"] as? String
        let transcriptPath = payload["transcript_path"] as? String

        let sessionID = sid.isEmpty ? nil : SessionID(sid)

        let hookEvent = HookEvent(
            kind: .init(raw: event),
            sessionID: sessionID,
            claudeSessionId: claudeSessionId,
            notificationType: notificationTypeRaw.map(HookEvent.NotificationType.init(raw:)),
            lastAssistantMessage: lastAssistantMessageFull.map { prefixUTF8($0, maxBytes: 4096) },
            source: source,
            reason: reason,
            pid: nil,
            receivedAt: Date()
        )
        return .hook(
            hookEvent, ppid: pid_t(ppidRaw), fullMessage: lastAssistantMessageFull, cwd: cwd,
            transcriptPath: transcriptPath)
    }

    private static func parseLaunchFrame(_ obj: [String: Any]) -> HookFrame? {
        guard let pidRaw = obj["pid"] as? Int,
              let cwd = obj["cwd"] as? String,
              let configDir = obj["config_dir"] as? String,
              let argv = obj["argv"] as? [String]
        else { return nil }
        let sid = (obj["sid"] as? String) ?? ""
        let announcement = LaunchAnnouncement(
            sessionID: sid.isEmpty ? nil : SessionID(sid),
            rawSid: sid,
            pid: pid_t(pidRaw),
            cwd: cwd,
            configDir: configDir,
            argv: argv
        )
        return .launch(announcement)
    }

    /// The first `maxBytes` UTF-8 bytes of `s`, cut on a character boundary.
    private static func prefixUTF8(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var end = s.startIndex
        var bytes = 0
        for idx in s.indices {
            let charBytes = s[idx].utf8.count
            if bytes + charBytes > maxBytes { break }
            bytes += charBytes
            end = s.index(after: idx)
        }
        return String(s[..<end])
    }

    // MARK: - sockaddr_un helpers

    private static let sunPathCapacity = 104 // sizeof(sockaddr_un.sun_path)

    private static func makeSockaddr(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withCString { cstr in
                let len = path.utf8.count + 1 // include NUL
                raw.copyMemory(from: UnsafeRawBufferPointer(start: cstr, count: min(len, raw.count)))
            }
        }
        return addr
    }
}
