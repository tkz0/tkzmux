// The journal sink (WOR-304 S2): the native-protocol datagram bytes (a golden, including the
// length-framed form of a multi-line value), the 16 KiB cut, non-blocking sends, and the choice
// between the journal and stderr. The real journal is checked by hand, since CI runners may not
// have a user journal (docs/linux/platform.md).

#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import TkzPlatform

@Suite struct JournalTests {
    /// The bytes journald receives, written out field by field.
    @Test func singleLineDatagramGolden() {
        let bytes = JournalDatagram.encode(message: "removed stale hook socket a.sock", priority: 6, category: "hookserver")
        let golden = Array(
            "MESSAGE=removed stale hook socket a.sock\nPRIORITY=6\nSYSLOG_IDENTIFIER=tkzmux\nTKZ_CATEGORY=hookserver\n"
                .utf8)
        #expect(bytes == golden)
    }

    /// A value with a newline is `KEY\n`, its length as a little-endian UInt64, the value, `\n`.
    @Test func multiLineDatagramGolden() {
        let bytes = JournalDatagram.encode(message: "first line\nsecond line", priority: 3, category: "state")
        let golden: [UInt8] =
            Array("MESSAGE\n".utf8)
            + [0x16, 0, 0, 0, 0, 0, 0, 0]  // 22 bytes
            + Array("first line\nsecond line\n".utf8)
            + Array("PRIORITY=3\nSYSLOG_IDENTIFIER=tkzmux\nTKZ_CATEGORY=state\n".utf8)
        #expect(bytes == golden)
    }

    @Test func emptyMessageIsAnEmptyField() {
        let bytes = JournalDatagram.encode(message: "", priority: 5, category: "c")
        #expect(bytes == Array("MESSAGE=\nPRIORITY=5\nSYSLOG_IDENTIFIER=tkzmux\nTKZ_CATEGORY=c\n".utf8))
    }

    @Test func longMessagesAreCutAt16KiB() {
        let long = String(repeating: "x", count: 20_000)
        let bytes = JournalDatagram.encode(message: long, priority: 6, category: "c")
        let golden = Array("MESSAGE=".utf8) + Array(repeating: UInt8(ascii: "x"), count: 16_384)
            + Array("\nPRIORITY=6\nSYSLOG_IDENTIFIER=tkzmux\nTKZ_CATEGORY=c\n".utf8)
        #expect(bytes == golden)
    }

    /// The cut never splits a scalar: "é" is 2 bytes, "€" is 3, "🙂" is 4.
    @Test(arguments: ["é", "€", "🙂"])
    func theCutKeepsUTF8Whole(scalar: String) {
        let width = scalar.utf8.count
        let text = "a" + String(repeating: scalar, count: 10)  // 1 + 10*width bytes
        for limit in 0...(1 + 10 * width + 1) {
            let cut = JournalDatagram.truncated(text, toBytes: limit)
            #expect(cut.count <= limit)
            #expect(cut.count > limit - width)
            #expect(String(validating: cut, as: UTF8.self) != nil, "limit \(limit)")
        }
    }

    @Test func aSendReachesTheSocket() throws {
        let server = try JournalTestServer()
        let socket = try #require(JournalSocket(path: server.path))
        let datagram = JournalDatagram.encode(message: "hello\nworld", priority: 4, category: "tests")
        #expect(socket.send(datagram) == .sent)
        #expect(server.receive() == datagram)
    }

    /// A full receive queue drops lines instead of blocking the caller.
    @Test(.timeLimit(.minutes(1)))
    func aFullQueueDropsInsteadOfBlocking() throws {
        let server = try JournalTestServer()
        let socket = try #require(JournalSocket(path: server.path))
        let datagram = JournalDatagram.encode(message: String(repeating: "y", count: 1024), priority: 6, category: "c")
        var results: [JournalSendResult] = []
        for _ in 0..<5_000 {
            results.append(socket.send(datagram))
            if results.last == .dropped { break }
        }
        #expect(results.last == .dropped)
        #expect(results.first == .sent)
    }

    @Test func aMissingSocketIsUnavailable() {
        #expect(JournalSocket(path: "/nonexistent/tkzmux-journal.sock") == nil)
        #expect(JournalSocket(path: "/dev/null") == nil)  // exists, not a socket
    }

    @Test func aVanishedSocketFails() throws {
        var server: JournalTestServer? = try JournalTestServer()
        let socket = try #require(JournalSocket(path: server!.path))
        server = nil  // closes and unlinks
        let result = socket.send(JournalDatagram.encode(message: "x", priority: 6, category: "c"))
        #expect(result != .sent && result != .dropped)
    }

    @Test func sinkChoice() {
        #expect(LogSinkPlan.choose(socketAvailable: true, stderrIsJournal: true) == LogSinkPlan(journal: true, stderr: false))
        #expect(LogSinkPlan.choose(socketAvailable: true, stderrIsJournal: false) == LogSinkPlan(journal: true, stderr: true))
        #expect(LogSinkPlan.choose(socketAvailable: false, stderrIsJournal: true) == LogSinkPlan(journal: false, stderr: true))
        #expect(LogSinkPlan.choose(socketAvailable: false, stderrIsJournal: false) == LogSinkPlan(journal: false, stderr: true))
    }

    @Test func journalStreamParsing() {
        #expect(parseJournalStream("10:40331").map { [$0.device, $0.inode] } == [10, 40331])
        for bad in ["", "10", "10:", ":5", "a:b", "1:2:3", "-1:2", " 1:2"] {
            #expect(parseJournalStream(bad) == nil, "\(bad)")
        }
    }

    /// `JOURNAL_STREAM` matches an fd only when both the device and the inode do.
    @Test func journalStreamMatchesTheFd() throws {
        let path = NSTemporaryDirectory() + "tkzmux-journal-stream-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd); unlink(path) }
        var info = stat()
        try #require(fstat(fd, &info) == 0)
        #expect(journalStreamMatches("\(info.st_dev):\(info.st_ino)", fd: fd))
        #expect(!journalStreamMatches("\(info.st_dev):\(info.st_ino + 1)", fd: fd))
        #expect(!journalStreamMatches("\(info.st_dev + 1):\(info.st_ino)", fd: fd))
        #expect(!journalStreamMatches(nil, fd: fd))
        #expect(!journalStreamMatches("garbage", fd: fd))
    }

    @Test func stderrLines() {
        #expect(
            LogSink.stderrLine(level: .warning, category: "hookserver", message: "a\nb", prefixed: false)
                == "tkzmux[hookserver] warning: a\nb\n")
        #expect(
            LogSink.stderrLine(level: .error, category: "state", message: "failed", prefixed: true)
                == "<3>tkzmux[state] error: failed\n")
    }
}

/// A datagram socket bound in the temporary directory, standing in for journald.
final class JournalTestServer {
    let path: String
    private let fd: Int32

    init() throws {
        path = NSTemporaryDirectory() + "tkzmux-journal-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        fd = socket(AF_UNIX, Int32(SOCK_DGRAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(path.utf8)
        guard utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
    }

    deinit {
        close(fd)
        unlink(path)
    }

    /// The next queued datagram, or nil if none is waiting.
    func receive() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, Int32(MSG_DONTWAIT)) }
        guard count >= 0 else { return nil }
        return Array(buffer[..<count])
    }
}
#endif
