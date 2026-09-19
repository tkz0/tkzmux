// TranscriptUsageReaderTests — summing `message.usage` off a synthetic transcript, and the
// incremental-cursor rule that makes repeated calls cheap: bytes already parsed are never re-read,
// so an in-place edit to an already-consumed line must not change the answer, only newly appended
// lines may.

import Foundation
import Testing
import TkzCore

@testable import AgentBridge

@Suite struct TranscriptUsageReaderTests {
    private static var codexFixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex")
    }

    /// A minimal `"type":"assistant"` transcript line carrying exactly the fields the reader looks
    /// at.
    private func assistantLine(
        model: String, input: Int, output: Int = 0,
        cacheCreate: Int = 0, cacheRead: Int = 0, thinking: Int = 0, sidechain: Bool = false
    ) -> String {
        """
        {"type":"assistant","isSidechain":\(sidechain),"message":{"model":"\(model)",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),\
        "cache_creation_input_tokens":\(cacheCreate),"cache_read_input_tokens":\(cacheRead),\
        "output_tokens_details":{"thinking_tokens":\(thinking)}}}}
        """
    }

    private func tempTranscript() throws -> URL {
        let dir = try StatuslineTestSupport.tempDirectory("usage-reader")
        return dir.appendingPathComponent("session.jsonl")
    }

    @Test("Sums input/output/cache tokens across assistant lines, folding in a sidechain turn")
    func sumsAcrossAssistantLines() async throws {
        let lines = [
            assistantLine(model: "claude-sonnet-5", input: 10, output: 20, cacheCreate: 5, cacheRead: 100),
            #"{"type":"user","message":{"content":"hi"}}"#,  // ignored: not an assistant line
            assistantLine(model: "claude-sonnet-5", input: 4, output: 6, sidechain: true),  // subagent spend counts
        ]
        let path = try tempTranscript()
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: path)

        let reader = TranscriptUsageReader(cacheDirectory: try StatuslineTestSupport.tempDirectory("usage-cache").path)
        let usage = try #require(await reader.refresh(sessionId: "s1", transcriptPath: path.path))
        #expect(usage.perModel.count == 1)
        let model = try #require(usage.perModel.first)
        #expect(model.modelId == "claude-sonnet-5")
        #expect(model.inputTokens == 14)
        #expect(model.outputTokens == 26)
        #expect(model.cacheCreationTokens == 5)
        #expect(model.cacheReadTokens == 100)
    }

    @Test("A total only appears once every model used is priced; an unpriced model still shows tokens")
    func totalRequiresEveryModelPriced() async throws {
        let lines = [
            assistantLine(model: "claude-sonnet-5", input: 1_000_000, output: 1_000_000),
            assistantLine(model: "claude-not-a-real-model", input: 10, output: 10),
        ]
        let path = try tempTranscript()
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: path)

        let reader = TranscriptUsageReader(cacheDirectory: try StatuslineTestSupport.tempDirectory("usage-cache").path)
        let usage = try #require(await reader.refresh(sessionId: "s2", transcriptPath: path.path))
        #expect(usage.perModel.count == 2)
        #expect(usage.totalCostUSD == nil)
        let priced = usage.perModel.first { $0.modelId == "claude-sonnet-5" }
        let unpriced = usage.perModel.first { $0.modelId == "claude-not-a-real-model" }
        #expect(priced?.costUSD != nil)
        #expect(unpriced?.costUSD == nil)
    }

    @Test("Bytes already parsed are never re-read: an in-place edit is invisible, only appended lines count")
    func incrementalReparseSkipsConsumedBytes() async throws {
        let path = try tempTranscript()
        let first = assistantLine(model: "claude-sonnet-5", input: 100)
        try Data((first + "\n").utf8).write(to: path)

        let cacheDir = try StatuslineTestSupport.tempDirectory("usage-cache")
        let reader = TranscriptUsageReader(cacheDirectory: cacheDir.path)
        let afterFirst = try #require(await reader.refresh(sessionId: "s3", transcriptPath: path.path))
        #expect(afterFirst.perModel.first?.inputTokens == 100)

        // Overwrite the already-consumed line's input_tokens in place — same byte length (both
        // 3-digit), so the file size (and therefore the stored cursor) does not move.
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        let editedFirst = assistantLine(model: "claude-sonnet-5", input: 999)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(editedFirst.utf8))

        let afterEdit = try #require(await reader.refresh(sessionId: "s3", transcriptPath: path.path))
        #expect(afterEdit.perModel.first?.inputTokens == 100, "an edit inside already-parsed bytes must not change the total")

        // Now append a genuinely new line — this is the only thing that should move the total.
        try handle.seekToEnd()
        let second = assistantLine(model: "claude-sonnet-5", input: 50)
        try handle.write(contentsOf: Data(("\n" + second + "\n").utf8))

        let afterAppend = try #require(await reader.refresh(sessionId: "s3", transcriptPath: path.path))
        #expect(afterAppend.perModel.first?.inputTokens == 150)
    }

    @Test("No transcript and no prior cache means no data, not a zeroed usage")
    func noDataYetIsNilNotZero() async throws {
        let reader = TranscriptUsageReader(cacheDirectory: try StatuslineTestSupport.tempDirectory("usage-cache").path)
        let usage = await reader.refresh(sessionId: "never-seen", transcriptPath: nil)
        #expect(usage == nil)
    }

    @Test("A partial trailing line (mid-write) is not parsed until it is completed by a later call")
    func partialTrailingLineIsDeferred() async throws {
        let path = try tempTranscript()
        let partial = String(assistantLine(model: "claude-sonnet-5", input: 100).dropLast(10))
        try Data(partial.utf8).write(to: path)  // no trailing newline: this line is still "being written"

        let cacheDir = try StatuslineTestSupport.tempDirectory("usage-cache")
        let reader = TranscriptUsageReader(cacheDirectory: cacheDir.path)
        let whilePartial = await reader.refresh(sessionId: "s4", transcriptPath: path.path)
        #expect(whilePartial == nil)

        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine(model: "claude-sonnet-5", input: 100).suffix(10).utf8))
        try handle.write(contentsOf: Data("\n".utf8))

        let complete = try #require(await reader.refresh(sessionId: "s4", transcriptPath: path.path))
        #expect(complete.perModel.first?.inputTokens == 100)
    }

    // MARK: - Codex (TKZ-86 part 2): a running thread total, never a per-line sum

    /// The trap this slice exists to avoid, made explicit: `rollout-token-count.jsonl`'s second turn
    /// spends 1100 tokens of its own, but the thread's running total by then is 2600, and a third
    /// line repeats 2600 unchanged (standing in for Codex's rate-limit-refresh re-emission). A
    /// reader that sums every line's total would report 1500 + 2600 + 2600 = 6700; this one must
    /// report 2600.
    @Test("Codex's cumulative usage lines are taken as the latest snapshot, never summed: 2600, not 6700")
    func codexTakesTheLatestTotalRatherThanSumming() async throws {
        let path = Self.codexFixturesDirectory.appendingPathComponent("rollout-token-count.jsonl").path
        let cacheDir = try StatuslineTestSupport.tempDirectory("usage-cache-codex")
        let reader = TranscriptUsageReader(cacheDirectory: cacheDir.path)
        let usage = try #require(
            await reader.refresh(sessionId: "codex-total-check", transcriptPath: path, agent: .codex))
        #expect(usage.perModel.count == 1)
        let model = try #require(usage.perModel.first)
        // `input_tokens` (2100) already includes `cached_input_tokens` (1500) in Codex's own
        // accounting — see `CodexUsageExtractor`'s doc comment — so the reader splits it into an
        // uncached remainder and a separate cache-read pool, the same shape the other agent's fields
        // already have.
        #expect(model.inputTokens == 600)
        #expect(model.cacheReadTokens == 1500)
        #expect(model.outputTokens == 500)
        #expect(model.thinkingTokens == 250)
        // Explicitly the number the whole slice hinges on.
        #expect(model.inputTokens + model.cacheReadTokens + model.outputTokens == 2600)
    }

    @Test("The duplicate rate-limit-refresh line changes nothing: refreshing again still reports 2600")
    func codexRefreshingAgainIsIdempotent() async throws {
        let path = Self.codexFixturesDirectory.appendingPathComponent("rollout-token-count.jsonl").path
        let cacheDir = try StatuslineTestSupport.tempDirectory("usage-cache-codex-idempotent")
        let reader = TranscriptUsageReader(cacheDirectory: cacheDir.path)
        _ = await reader.refresh(sessionId: "codex-idempotent", transcriptPath: path, agent: .codex)
        let again = try #require(
            await reader.refresh(sessionId: "codex-idempotent", transcriptPath: path, agent: .codex))
        let model = try #require(again.perModel.first)
        #expect(model.inputTokens + model.cacheReadTokens + model.outputTokens == 2600)
    }

    @Test("The cache file is keyed by agent, so a Claude and a Codex session sharing an id do not collide")
    func cacheKeyIncludesTheAgent() async throws {
        let cacheDir = try StatuslineTestSupport.tempDirectory("usage-cache-key")
        let reader = TranscriptUsageReader(cacheDirectory: cacheDir.path)

        let claudePath = try tempTranscript()
        try Data((assistantLine(model: "claude-sonnet-5", input: 10, output: 20) + "\n").utf8)
            .write(to: claudePath)
        _ = await reader.refresh(sessionId: "shared-id", transcriptPath: claudePath.path)

        let codexPath = Self.codexFixturesDirectory.appendingPathComponent("rollout-token-count.jsonl").path
        let codexUsage = try #require(
            await reader.refresh(sessionId: "shared-id", transcriptPath: codexPath, agent: .codex))
        #expect(codexUsage.perModel.first?.outputTokens == 500)

        let names = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).sorted()
        #expect(names == ["claude-shared-id.json", "codex-shared-id.json"])
    }

    @Test("A Codex model id unknown to ModelPricing leaves the total nil rather than showing $0")
    func codexUnpricedModelLeavesTotalNil() async throws {
        let path = Self.codexFixturesDirectory.appendingPathComponent("rollout-exec.jsonl").path
        let cacheDir = try StatuslineTestSupport.tempDirectory("usage-cache-codex-unpriced")
        let reader = TranscriptUsageReader(cacheDirectory: cacheDir.path)
        let usage = try #require(
            await reader.refresh(sessionId: "codex-unpriced", transcriptPath: path, agent: .codex))
        // `rollout-exec.jsonl`'s `turn_context` names `gpt-5.6-terra`, which `ModelPricing` carries
        // no rate for — deliberately, see `ModelPricing.swift`'s header — so the total must stay
        // `nil`, never a guessed or zeroed cost.
        #expect(usage.perModel.first?.modelId == "gpt-5.6-terra")
        #expect(usage.perModel.first?.costUSD == nil)
        #expect(usage.totalCostUSD == nil)
    }

    // MARK: - An agent nobody has measured

    /// The strategy used to be picked by `agent == .codex ? codex : claude`, so a third agent
    /// silently inherited Claude's *summing* fold. The two are not interchangeable — Claude reports
    /// per-message deltas that add up, Codex a running thread total that replaces — so the fallback
    /// would not have been a mild default, it would have reported a number nobody had checked.
    @Test("An agent with no measured usage shape yields nil, never Claude's arithmetic")
    func anUnmeasuredAgentYieldsNoUsage() async throws {
        let lines = [
            assistantLine(model: "claude-sonnet-5", input: 10, output: 20, cacheCreate: 5, cacheRead: 100)
        ]
        let path = try tempTranscript()
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: path)

        let reader = TranscriptUsageReader(cacheDirectory: try StatuslineTestSupport.tempDirectory("usage-cache").path)
        let usage = await reader.refresh(
            sessionId: "s1", transcriptPath: path.path, agent: AgentKind(rawValue: "aider"))
        #expect(usage == nil)
    }

    /// And the bytes are left unread rather than skipped: the offset must not advance past a window
    /// nothing folded, or a later build that *does* know the shape would start after the lines it
    /// needed. Proven by re-reading the same file under an agent that does have a strategy.
    @Test("An unmeasured agent does not consume the bytes it could not fold")
    func anUnmeasuredAgentLeavesTheOffsetAlone() async throws {
        let lines = [
            assistantLine(model: "claude-sonnet-5", input: 10, output: 20, cacheCreate: 5, cacheRead: 100)
        ]
        let path = try tempTranscript()
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: path)

        let cacheDir = try StatuslineTestSupport.tempDirectory("usage-cache-unmeasured")
        let reader = TranscriptUsageReader(cacheDirectory: cacheDir.path)
        let unknown = AgentKind(rawValue: "aider")
        #expect(await reader.refresh(sessionId: "shared", transcriptPath: path.path, agent: unknown) == nil)
        // A second pass under the same unknown agent still reads from byte 0 — and a pass under
        // Claude sees the whole file, which it could not if the first call had eaten it. (The cache
        // is keyed by agent, so this also relies on that isolation staying true.)
        #expect(await reader.refresh(sessionId: "shared", transcriptPath: path.path, agent: unknown) == nil)
        let claude = try #require(
            await reader.refresh(sessionId: "shared", transcriptPath: path.path, agent: .claude))
        #expect(claude.perModel.first?.inputTokens == 10)
        #expect(claude.perModel.first?.outputTokens == 20)
    }
}
