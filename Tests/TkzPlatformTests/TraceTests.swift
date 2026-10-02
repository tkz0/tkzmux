// Linux signposts (WOR-304 S2): the Chrome trace JSON a `TKZMUX_TRACE` run writes, which must stay
// loadable (valid JSON, matched async pairs) after every event, and the disabled path.

#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import TkzPlatform

@Suite struct TraceTests {
    static func temporaryPath() -> String {
        NSTemporaryDirectory() + "tkzmux-trace-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).json"
    }

    /// The file parsed as the JSON Object Format: `traceEvents` is an array of objects.
    static func events(at path: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["displayTimeUnit"] as? String == "ms")
        return try #require(root["traceEvents"] as? [[String: Any]])
    }

    @Test func intervalsAndEventsHaveTheChromeTraceShape() throws {
        let path = Self.temporaryPath()
        defer { unlink(path) }
        let writer = try #require(TraceWriter(path: path))
        let signposter = TkzSignposter(subsystem: "se.tkz.tkzmux", category: "terminalhost", writer: writer)

        // Valid before any interval: just the process name.
        let initial = try Self.events(at: path)
        #expect(initial.count == 1)
        #expect(initial[0]["ph"] as? String == "M")
        #expect(initial[0]["name"] as? String == "process_name")
        #expect((initial[0]["args"] as? [String: Any])?["name"] as? String == "tkzmux")

        // The writer reports the kernel thread id of the calling thread.
        let threadID = writer.currentThreadID()
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/thread-self")
        #expect(link.hasSuffix("/task/\(threadID)"))
        #expect(writer.currentThreadID() == threadID)  // cached

        let id = signposter.makeSignpostID()
        let interval = signposter.beginInterval("show", id: id)
        #expect(try Self.events(at: path).count == 2)  // valid JSON mid-interval
        signposter.emitEvent("mark")
        signposter.endInterval("show", interval)

        let events = try Self.events(at: path)
        #expect(events.map { $0["ph"] as? String } == ["M", "b", "i", "e"])
        let begin = events[1], instant = events[2], end = events[3]
        for event in [begin, instant, end] {
            #expect(event["cat"] as? String == "terminalhost")
            #expect(event["pid"] as? Int == Int(getpid()))
            #expect(event["tid"] as? Int == Int(threadID))  // a kernel tid, which Perfetto reads as 32-bit
            #expect(event["ts"] is NSNumber)
        }
        #expect(begin["name"] as? String == "show")
        #expect(end["name"] as? String == "show")
        #expect(instant["name"] as? String == "mark")
        #expect(instant["s"] as? String == "t")
        #expect(begin["id"] as? String == "0x\(String(id.rawValue, radix: 16))")
        #expect(end["id"] as? String == begin["id"] as? String)
        let times = [begin, instant, end].compactMap { ($0["ts"] as? NSNumber)?.doubleValue }
        #expect(times == times.sorted())
    }

    @Test func signpostIDsAreDistinct() {
        let signposter = TkzSignposter(subsystem: "se.tkz.tkzmux", category: "tests")
        let ids = (0..<100).map { _ in signposter.makeSignpostID() }
        #expect(Set(ids).count == 100)
        #expect(!ids.contains(.exclusive))
    }

    /// Concurrent intervals from many threads all land, and the file stays one JSON document.
    @Test func concurrentWritesKeepTheFileValid() async throws {
        let path = Self.temporaryPath()
        defer { unlink(path) }
        let writer = try #require(TraceWriter(path: path))
        let signposter = TkzSignposter(subsystem: "se.tkz.tkzmux", category: "tests", writer: writer)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<50 {
                        let state = signposter.beginInterval("work", id: signposter.makeSignpostID())
                        signposter.endInterval("work", state)
                    }
                }
            }
        }
        let events = try Self.events(at: path)
        let expected = 1 + 8 * 50 * 2  // the process name, then a begin and an end per interval
        #expect(events.count == expected)
        let begins = Set(events.filter { $0["ph"] as? String == "b" }.compactMap { $0["id"] as? String })
        let ends = Set(events.filter { $0["ph"] as? String == "e" }.compactMap { $0["id"] as? String })
        #expect(begins.count == 400)
        #expect(begins == ends)
    }

    /// Without `TKZMUX_TRACE` the signposter writes nothing and its states are untraced.
    @Test(.enabled(if: getenv("TKZMUX_TRACE") == nil))
    func disabledByDefault() {
        let signposter = TkzSignposter(subsystem: "se.tkz.tkzmux", category: "tests")
        let enabled = TraceSession.enabled.load(ordering: .relaxed)
        #expect(!enabled)
        let state = signposter.beginInterval("show", id: signposter.makeSignpostID())
        #expect(!state.traced)
        signposter.endInterval("show", state)
    }

    @Test func eventJSON() {
        let event = TraceEvent(name: "a\"b\\c\n\u{1}", category: "cat", phase: .begin, id: TkzSignpostID(255))
        #expect(
            event.json(timestampNanos: 1_234_567_089, pid: 42, tid: 7)
                == #"{"name":"a\"b\\c\n\u0001","cat":"cat","ph":"b","ts":1234567.089,"pid":42,"tid":7,"id":"0xff"}"#)
        let instant = TraceEvent(name: "mark", category: "c", phase: .instant, id: .exclusive)
        #expect(
            instant.json(timestampNanos: 5, pid: 1, tid: 2)
                == #"{"name":"mark","cat":"c","ph":"i","ts":0.005,"pid":1,"tid":2,"s":"t"}"#)
    }
}
#endif
