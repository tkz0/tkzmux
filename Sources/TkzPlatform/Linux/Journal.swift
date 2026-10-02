// Where Linux log lines go (WOR-304 S2): the journal's native protocol, stderr, or both.
//
// The journal is written directly, without libsystemd: one datagram per line to
// /run/systemd/journal/socket (systemd.io JOURNAL_NATIVE_PROTOCOL). A datagram is a list of fields,
// each `KEY=value\n`, or, when the value contains a newline, `KEY\n`, the value's length as a
// little-endian UInt64, the value and `\n`. tkzmux sends four fields: MESSAGE, PRIORITY,
// SYSLOG_IDENTIFIER=tkzmux and TKZ_CATEGORY, so `journalctl --user -t tkzmux` finds every line and
// `-o verbose` shows its category.
//
// Sends never block the caller: they use MSG_DONTWAIT, and a line that would block (EAGAIN, the
// journal is behind) is dropped. MESSAGE is cut at 16 KiB, so a datagram never needs the memfd
// path the protocol uses for large entries.
//
// Sinks, chosen once per process:
//   socket present, stderr is the journal stream   journal only (uwsm/systemd already journals
//                                                   stderr, so writing both would log twice)
//   socket present, stderr is anything else         journal and stderr (a terminal sees the lines)
//   no socket                                       stderr only
// "stderr is the journal stream" means `$JOURNAL_STREAM` (`<dev>:<ino>`) names fd 2's device and
// inode, as systemd.exec(5) describes. If a send fails for any reason other than EAGAIN, the line
// goes to stderr instead, unless it was already written there.

#if os(Linux)
import Glibc

/// The journal datagram encoder.
enum JournalDatagram {
    /// The largest MESSAGE value sent, in bytes; longer messages are cut at a UTF-8 boundary.
    static let maxMessageBytes = 16 * 1024

    /// The identifier `journalctl -t` filters on.
    static let syslogIdentifier = "tkzmux"

    /// The datagram for one line.
    static func encode(message: String, priority: Int, category: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(message.utf8.count + category.utf8.count + 64)
        append("MESSAGE", truncated(message, toBytes: maxMessageBytes), to: &bytes)
        append("PRIORITY", Array(String(priority).utf8), to: &bytes)
        append("SYSLOG_IDENTIFIER", Array(syslogIdentifier.utf8), to: &bytes)
        append("TKZ_CATEGORY", Array(category.utf8), to: &bytes)
        return bytes
    }

    /// Appends one field, length-framed when the value contains a newline.
    static func append(_ key: String, _ value: [UInt8], to bytes: inout [UInt8]) {
        bytes.append(contentsOf: key.utf8)
        if value.contains(UInt8(ascii: "\n")) {
            bytes.append(UInt8(ascii: "\n"))
            withUnsafeBytes(of: UInt64(value.count).littleEndian) { bytes.append(contentsOf: $0) }
        } else {
            bytes.append(UInt8(ascii: "="))
        }
        bytes.append(contentsOf: value)
        bytes.append(UInt8(ascii: "\n"))
    }

    /// The UTF-8 of `text`, cut to at most `limit` bytes without splitting a scalar.
    static func truncated(_ text: String, toBytes limit: Int) -> [UInt8] {
        var utf8 = Array(text.utf8)
        guard utf8.count > limit else { return utf8 }
        var end = limit
        // Back up over continuation bytes (10xxxxxx) to the start of the scalar that does not fit.
        while end > 0, utf8[end] & 0xC0 == 0x80 { end -= 1 }
        utf8.removeSubrange(end...)
        return utf8
    }
}

/// What happened to one datagram.
enum JournalSendResult: Equatable {
    case sent
    /// The socket would have blocked (EAGAIN); the line is dropped.
    case dropped
    /// Any other error, such as journald being down.
    case failed(Int32)
}

/// A datagram socket that sends to the journal's native socket. Each send names the address, so a
/// journald restart (which replaces the socket file) does not leave the socket pointing at nothing.
final class JournalSocket: Sendable {
    static let defaultPath = "/run/systemd/journal/socket"

    private let fd: Int32
    private let path: [UInt8]

    /// Nil when `path` is not a socket or a socket cannot be created.
    init?(path: String = JournalSocket.defaultPath) {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        let utf8 = Array(path.utf8)
        guard utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { return nil }
        let fd = socket(AF_UNIX, Int32(SOCK_DGRAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { return nil }
        self.fd = fd
        self.path = utf8
    }

    deinit { close(fd) }

    func send(_ datagram: [UInt8]) -> JournalSendResult {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
            sunPath.copyBytes(from: path)
            sunPath[path.count] = 0
        }
        let flags = Int32(MSG_DONTWAIT | MSG_NOSIGNAL)
        let sent = datagram.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, flags, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        if sent >= 0 { return .sent }
        let error = errno
        return error == EAGAIN || error == EWOULDBLOCK ? .dropped : .failed(error)
    }
}

/// The sinks a process writes to, per the table at the top of this file.
struct LogSinkPlan: Equatable {
    var journal: Bool
    var stderr: Bool

    static func choose(socketAvailable: Bool, stderrIsJournal: Bool) -> LogSinkPlan {
        guard socketAvailable else { return LogSinkPlan(journal: false, stderr: true) }
        return LogSinkPlan(journal: true, stderr: !stderrIsJournal)
    }
}

/// Parses `$JOURNAL_STREAM` (`<dev>:<ino>`, both decimal).
func parseJournalStream(_ value: String) -> (device: UInt64, inode: UInt64)? {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let device = UInt64(parts[0]), let inode = UInt64(parts[1]) else { return nil }
    return (device, inode)
}

/// Whether `$JOURNAL_STREAM` names the file open on `fd`.
func journalStreamMatches(_ value: String?, fd: Int32) -> Bool {
    guard let value, let stream = parseJournalStream(value) else { return false }
    var info = stat()
    guard fstat(fd, &info) == 0 else { return false }
    return UInt64(info.st_dev) == stream.device && UInt64(info.st_ino) == stream.inode
}

/// The process's log sinks.
final class LogSink: Sendable {
    static let shared: LogSink = {
        let socket = JournalSocket()
        let stream = getenv("JOURNAL_STREAM").map { String(cString: $0) }
        let stderrIsJournal = journalStreamMatches(stream, fd: STDERR_FILENO)
        let plan = LogSinkPlan.choose(socketAvailable: socket != nil, stderrIsJournal: stderrIsJournal)
        return LogSink(journal: plan.journal ? socket : nil, stderr: plan.stderr, stderrIsJournal: stderrIsJournal)
    }()

    private let journal: JournalSocket?
    private let mirrorsToStderr: Bool
    private let stderrIsJournal: Bool

    init(journal: JournalSocket?, stderr: Bool, stderrIsJournal: Bool) {
        self.journal = journal
        self.mirrorsToStderr = stderr
        self.stderrIsJournal = stderrIsJournal
    }

    func write(level: TkzLogLevel, category: String, message: String) {
        var onStderr = mirrorsToStderr
        if let journal {
            let datagram = JournalDatagram.encode(message: message, priority: level.priority, category: category)
            if case .failed = journal.send(datagram) { onStderr = true }
        }
        if onStderr {
            writeStderr(Self.stderrLine(level: level, category: category, message: message, prefixed: stderrIsJournal))
        }
    }

    /// The stderr form of a line. When stderr is the journal stream, the `<priority>` prefix that
    /// journald parses on stream lines carries the level.
    static func stderrLine(level: TkzLogLevel, category: String, message: String, prefixed: Bool) -> String {
        let prefix = prefixed ? "<\(level.priority)>" : ""
        return "\(prefix)tkzmux[\(category)] \(level.name): \(message)\n"
    }

    /// One `write(2)` per line, so lines from different threads do not interleave. (Not through
    /// `FILE *stderr`, a mutable global in Glibc.)
    private func writeStderr(_ line: String) {
        var line = line
        line.withUTF8 { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Glibc.write(STDERR_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
#endif
