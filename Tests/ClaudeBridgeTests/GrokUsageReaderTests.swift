// GrokUsageReaderTests — Grok CLI usage and spend off a synthetic `updates.jsonl`, and the pieces
// that find a running Grok and tie it to a pty: `active_sessions.json`, the cwd directory encoding,
// and pid-ancestry attribution.

import Darwin
import Foundation
import Testing

@testable import ClaudeBridge

@Suite struct GrokUsageReaderTests {
    /// A `turn_completed` update line in the shape Grok 1.0.x writes, trimmed to the fields read.
    private func turnLine(
        model: String = "grok-4.6-build", input: Int, output: Int, cachedRead: Int = 0,
        reasoning: Int = 0, ticks: Int64
    ) -> String {
        let fields = """
            "inputTokens":\(input),"outputTokens":\(output),"cachedReadTokens":\(cachedRead),\
            "cacheCreationTokens":0,"reasoningTokens":\(reasoning),"costUsdTicks":\(ticks)
            """
        return """
            {"method":"session/update","params":{"update":{"sessionUpdate":"turn_completed",\
            "usage":{\(fields),"modelUsage":{"\(model)":{\(fields)}}}}}}
            """
    }

    private let chunkLine =
        #"{"method":"session/update","params":{"_meta":{"totalTokens":1610},"update":{"sessionUpdate":"agent_message_chunk"}}}"#

    private func tempUpdates() throws -> URL {
        try StatuslineTestSupport.tempDirectory("grok-updates").appendingPathComponent("updates.jsonl")
    }

    private func reader() throws -> GrokUsageReader {
        GrokUsageReader(cacheDirectory: try StatuslineTestSupport.tempDirectory("grok-cache").path)
    }

    @Test("Sums every completed turn; cost is Grok's own, in ticks of 1e-10 USD")
    func sumsTurnsAndConvertsTicks() async throws {
        let path = try tempUpdates()
        let lines = [
            chunkLine,
            turnLine(input: 1_000, output: 200, cachedRead: 600, reasoning: 50, ticks: 12_742_688_800),
            chunkLine,
            turnLine(input: 500, output: 100, cachedRead: 100, reasoning: 10, ticks: 3_945_931_200),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: path)

        let usage = try #require(await reader().refresh(sessionId: "g1", updatesPath: path.path))
        let model = try #require(usage.perModel.first)
        #expect(usage.perModel.count == 1)
        #expect(model.modelId == "grok-4.6-build")
        // Grok's input includes cached reads; ModelUsage keeps them apart, Claude-style.
        #expect(model.inputTokens == 800)
        #expect(model.cacheReadTokens == 700)
        #expect(model.outputTokens == 300)
        #expect(model.thinkingTokens == 60)
        let total = try #require(usage.totalCostUSD)
        #expect(abs(total - 1.66886200) < 1e-9)
    }

    @Test("Only new lines are read, a partial last line waits, and no turn yet means no figure")
    func incrementalAndPartial() async throws {
        let path = try tempUpdates()
        let reader = try reader()
        try Data((chunkLine + "\n").utf8).write(to: path)
        #expect(await reader.refresh(sessionId: "g2", updatesPath: path.path) == nil)

        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((turnLine(input: 10, output: 1, ticks: 10_000_000_000) + "\n").utf8))
        // Half a line: must not be counted until it is finished.
        let second = turnLine(input: 20, output: 2, ticks: 20_000_000_000)
        try handle.write(contentsOf: Data(second.prefix(40).utf8))
        var usage = try #require(await reader.refresh(sessionId: "g2", updatesPath: path.path))
        #expect(usage.totalCostUSD == 1)

        try handle.write(contentsOf: Data((second.dropFirst(40) + "\n").utf8))
        try handle.close()
        usage = try #require(await reader.refresh(sessionId: "g2", updatesPath: path.path))
        #expect(usage.totalCostUSD == 3)
        #expect(usage.perModel.first?.inputTokens == 30)
    }

    @Test func parsesActiveSessions() {
        let data = Data(#"""
            [{"session_id":"01a09c18","pid":4242,"cwd":"/Users/me/My App","opened_at":"x"},
             {"session_id":"","pid":1,"cwd":"/"},{"pid":7}]
            """#.utf8)
        #expect(GrokSessions.parseActive(data) == [
            GrokSessions.Active(sessionId: "01a09c18", pid: 4242, cwd: "/Users/me/My App")
        ])
        #expect(GrokSessions.parseActive(Data("nope".utf8)).isEmpty)
    }

    @Test("A cwd maps to Grok's directory name, and a session is found under it or anywhere")
    func locatesUpdates() throws {
        #expect(GrokSessions.encodedDirectoryName(cwd: "/Users/me/.grok/My App")
            == "%2FUsers%2Fme%2F.grok%2FMy%20App")

        let home = try StatuslineTestSupport.tempDirectory("grok-home")
        let dir = home.appendingPathComponent("sessions/%2Frepo%20one/abc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("updates.jsonl"))

        let expected = dir.appendingPathComponent("updates.jsonl").path
        #expect(GrokSessions.updatesPath(sessionId: "abc", cwd: "/repo one", grokHome: home.path) == expected)
        #expect(GrokSessions.updatesPath(sessionId: "abc", cwd: "/elsewhere", grokHome: home.path) == expected)
        #expect(GrokSessions.updatesPath(sessionId: "missing", cwd: nil, grokHome: home.path) == nil)
    }

    @Test("A Grok pid is attributed to the pty shell it descends from, and nothing else")
    func attributesByAncestry() {
        // launchd(1) → zsh(100) → grok(200) → helper(300); an unrelated grok(900) under launchd.
        let parents: [pid_t: pid_t] = [300: 200, 200: 100, 100: 1, 900: 1]
        let parent: (pid_t) -> pid_t? = { parents[$0] }
        #expect(GrokSessions.owningRoot(of: 200, in: [100, 555], parent: parent) == 100)
        #expect(GrokSessions.owningRoot(of: 300, in: [100], parent: parent) == 100)
        #expect(GrokSessions.owningRoot(of: 900, in: [100], parent: parent) == nil)
    }
}
