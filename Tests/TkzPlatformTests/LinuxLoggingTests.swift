// The Linux logger (WOR-304 S2): the redaction table, the interpolation overloads that decide
// whether a value counts as a scalar, and the call shapes the app uses. The Mac's redaction is
// `os.Logger`'s own, so these run on Linux only.

#if os(Linux)
import Glibc
import Testing
@testable import TkzPlatform

@Suite struct LinuxLoggingTests {
    /// Every row of the table, with and without `TKZMUX_LOG_PRIVATE=1`.
    @Test(arguments: [
        (TkzLogValueKind.scalar, TkzLogPrivacy.public, false, true),
        (.scalar, .private, false, false),
        (.scalar, .auto, false, true),
        (.dynamic, .public, false, true),
        (.dynamic, .private, false, false),
        (.dynamic, .auto, false, false),
        (.scalar, .public, true, true),
        (.scalar, .private, true, true),
        (.scalar, .auto, true, true),
        (.dynamic, .public, true, true),
        (.dynamic, .private, true, true),
        (.dynamic, .auto, true, true),
    ])
    func redactionTable(kind: TkzLogValueKind, privacy: TkzLogPrivacy, revealPrivate: Bool, shown: Bool) {
        #expect(tkzLogReveals(kind, privacy, revealPrivate: revealPrivate) == shown)
    }

    /// With `.auto`, the overload picks the kind: numbers and booleans are shown, strings and
    /// other values are not, as on the Mac.
    @Test func autoShowsScalarsAndHidesDynamicValues() {
        let pid: Int32 = 4242
        let count = 3
        let bytes: UInt64 = 1 << 40
        let seconds = 1.5
        let ratio: Float = 0.25
        let flag = true
        let name = "secret"
        let list = ["a", "b"]
        let message: TkzLogMessage =
            "pid=\(pid) n=\(count) b=\(bytes) s=\(seconds) r=\(ratio) f=\(flag) name=\(name) list=\(list) lit=\(7)"
        #expect(
            message.rendered(revealPrivate: false)
                == "pid=4242 n=3 b=1099511627776 s=1.5 r=0.25 f=true name=<private> list=<private> lit=7")
        #expect(
            message.rendered(revealPrivate: true)
                == "pid=4242 n=3 b=1099511627776 s=1.5 r=0.25 f=true name=secret list=[\"a\", \"b\"] lit=7")
    }

    @Test func explicitPrivacyOverridesTheKind() {
        let pid: Int32 = 7
        let path = "/some/where"
        let message: TkzLogMessage = "\(path, privacy: .public) \(pid, privacy: .private) \(path, privacy: .auto)"
        #expect(message.rendered(revealPrivate: false) == "/some/where <private> <private>")
        #expect(message.rendered(revealPrivate: true) == "/some/where 7 /some/where")
    }

    @Test func aRedactedValueIsNeverEvaluated() {
        final class Counter: CustomStringConvertible {
            var calls = 0
            var description: String {
                calls += 1
                return "counted"
            }
        }
        let counter = Counter()
        let message: TkzLogMessage = "value \(counter)"
        #expect(message.rendered(revealPrivate: false) == "value <private>")
        #expect(counter.calls == 0)
        #expect(message.rendered(revealPrivate: true) == "value counted")
        #expect(counter.calls == 1)
    }

    @Test func aPlainLiteralIsTheMessage() {
        let message: TkzLogMessage = "dropping malformed hook frame (invalid JSON)"
        #expect(message.rendered(revealPrivate: false) == "dropping malformed hook frame (invalid JSON)")
    }

    @Test func levelsMapToSyslogPriorities() {
        #expect(TkzLogLevel.allCases.map(\.priority) == [7, 6, 5, 4, 3, 2])
        #expect(TkzLogLevel.allCases.map(\.name) == ["debug", "info", "notice", "warning", "error", "fault"])
    }

    /// Each level reaches the sink once, with its priority and the rendered, redacted text. The
    /// call shapes are the app's own (UserPath, HookServer, StateAutosaver). The expected text is
    /// the redacted one, so the test is skipped when `TKZMUX_LOG_PRIVATE` is set.
    @Test(.enabled(if: getenv("TKZMUX_LOG_PRIVATE") == nil))
    func eachLevelSendsOneDatagram() throws {
        let server = try JournalTestServer()
        let socket = try #require(JournalSocket(path: server.path))
        let logger = TkzLogger(
            subsystem: "se.tkz.tkzmux", category: "tests",
            sink: LogSink(journal: socket, stderr: false, stderrIsJournal: false))
        let shell = (name: "zsh", path: "/bin/zsh")
        let deadline = 2.0
        let error = "boom"

        logger.debug("debug \(shell.path)")
        logger.info("removing stale hook socket at \(shell.path, privacy: .public)")
        logger.notice("\(shell.name, privacy: .public) did not answer within \(deadline, privacy: .public)s")
        logger.warning("hook connection exceeded \(4096) bytes without a newline; dropping")
        logger.error("state.json save failed: \(String(describing: error), privacy: .public)")
        logger.fault("fault \(error)")

        let expected = [
            (7, "debug <private>"),
            (6, "removing stale hook socket at /bin/zsh"),
            (5, "zsh did not answer within 2.0s"),
            (4, "hook connection exceeded 4096 bytes without a newline; dropping"),
            (3, "state.json save failed: boom"),
            (2, "fault <private>"),
        ]
        for (priority, text) in expected {
            let datagram = try #require(server.receive())
            #expect(datagram == JournalDatagram.encode(message: text, priority: priority, category: "tests"))
        }
        #expect(server.receive() == nil)
    }
}
#endif
