// Sends one NDJSON frame to the app over `AF_UNIX`. `Darwin` only.
//
// Every failure here is silent and non-fatal: `TKZMUX_SOCKET` unset/empty, no listener, a slow or
// wedged app, `sun_path` too long — all just skip the send. The hook binary always exits 0.
import Darwin

private let connectAndWritePollMillis: Int32 = 200
private let sunPathCapacity = 104 // sizeof(sockaddr_un.sun_path)

func sendFrame(_ frame: [UInt8]) {
    guard let socketPath = envString("TKZMUX_SOCKET"), !socketPath.isEmpty else {
        debugLog("TKZMUX_SOCKET unset or empty; not sending")
        return
    }
    guard socketPath.utf8.count < sunPathCapacity else {
        debugLog("TKZMUX_SOCKET path too long for sun_path: \(socketPath)")
        return
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        debugLog("socket() failed: errno \(errno)")
        return
    }
    defer { close(fd) }

    // Never die to SIGPIPE if the server closes the connection mid-write.
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        socketPath.withCString { cstr in
            let len = socketPath.utf8.count + 1 // include NUL
            raw.copyMemory(from: UnsafeRawBufferPointer(start: cstr, count: min(len, raw.count)))
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
            connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if connectResult != 0 {
        if errno == EINPROGRESS {
            guard pollFor(fd: fd, events: Int16(POLLOUT), millis: connectAndWritePollMillis) else {
                debugLog("connect() poll timed out")
                return
            }
            var soErr: Int32 = 0
            var soErrLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soErrLen)
            guard soErr == 0 else {
                debugLog("connect() failed: SO_ERROR \(soErr)")
                return
            }
        } else {
            debugLog("connect() failed: errno \(errno)")
            return
        }
    }

    var offset = 0
    while offset < frame.count {
        guard pollFor(fd: fd, events: Int16(POLLOUT), millis: connectAndWritePollMillis) else {
            debugLog("write() poll timed out")
            return
        }
        let n = frame.withUnsafeBytes { buf -> Int in
            write(fd, buf.baseAddress!.advanced(by: offset), frame.count - offset)
        }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { continue }
            debugLog("write() failed: errno \(errno)")
            return
        }
        if n == 0 { return }
        offset += n
    }
    debugLog("sent \(frame.count) bytes")
}

private func pollFor(fd: Int32, events: Int16, millis: Int32) -> Bool {
    var pfd = pollfd(fd: fd, events: events, revents: 0)
    let result = poll(&pfd, 1, millis)
    guard result > 0 else { return false }
    if pfd.revents & Int16(POLLERR) != 0 || pfd.revents & Int16(POLLHUP) != 0 {
        return events == Int16(POLLIN) // let a POLLHUP-with-data read proceed; writes never should
    }
    return pfd.revents & events != 0
}
