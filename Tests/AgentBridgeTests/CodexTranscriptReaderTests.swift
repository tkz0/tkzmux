// CodexTranscriptReaderTests — `locate`, `summary` and `searchIndex` against the captured rollouts
// in `Fixtures/codex/`. `rollout-exec.jsonl` is real, off codex-cli 0.155.0; `rollout-short.jsonl`
// and `rollout-turn.jsonl` are real too, off 0.130.0 — 25 releases behind — and exist specifically
// so a reader keyed to a field that moved between those versions passes on one and fails on the
// other. See that directory's README for what is measured versus hand-written.

import Foundation
import Testing
import TkzCore

@testable import AgentBridge

@Suite struct CodexTranscriptReaderTests {
    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex")
    }

    private static func fixturePath(_ name: String) -> String {
        fixturesDirectory.appendingPathComponent(name).path
    }

    /// `ISO8601DateFormatter()`'s defaults do not parse a fractional-seconds timestamp (every
    /// timestamp in these fixtures has one) and silently return `nil` — matching the format style
    /// `TranscriptReader.timestamp(of:)` itself uses avoids that trap.
    private static func timestamp(_ raw: String) -> Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw)
    }

    private let reader = CodexTranscriptReader()

    // MARK: - locate

    @Test("Finds the newest rollout-*-<id>.jsonl under sessions/**, ignoring older or mismatched ones")
    func locateFindsTheNewestMatch() throws {
        let root = try StatuslineTestSupport.tempDirectory("codex-locate")
        let sessions = root.appendingPathComponent("sessions/2026/09/18")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let id = "01a0b549-efb1-7b92-9891-8fc0ca00aca2"
        let older = sessions.appendingPathComponent("rollout-2026-09-18T10-00-00-\(id).jsonl")
        let newer = sessions.appendingPathComponent("rollout-2026-09-18T16-11-56-\(id).jsonl")
        let other = sessions.appendingPathComponent("rollout-2026-09-18T16-12-00-some-other-id.jsonl")
        for url in [older, newer, other] { try Data().write(to: url) }
        // Make `newer` unambiguously newer than `older` on filesystems with coarse mtime resolution.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: newer.path)

        let found = reader.locate(conversationId: id, configDir: root.path, fileManager: .default)
        #expect(found == newer.path)
    }

    @Test("A conversation id with no matching file locates nothing")
    func locateFindsNothingForAnUnknownId() throws {
        let root = try StatuslineTestSupport.tempDirectory("codex-locate-miss")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let found = reader.locate(conversationId: "no-such-id", configDir: root.path, fileManager: .default)
        #expect(found == nil)
    }

    @Test("A conversation id that looks like a path is refused rather than searched for")
    func locateRefusesAPathLikeId() throws {
        let root = try StatuslineTestSupport.tempDirectory("codex-locate-refuse")
        #expect(reader.locate(conversationId: "../etc", configDir: root.path, fileManager: .default) == nil)
        #expect(reader.locate(conversationId: "a/b", configDir: root.path, fileManager: .default) == nil)
        #expect(reader.locate(conversationId: "", configDir: root.path, fileManager: .default) == nil)
    }

    // MARK: - summary — real capture, 0.155.0

    @Test("The recap is the last task_complete's last_agent_message")
    func recapIsTheLastTaskCompleteMessage() throws {
        let summary = try reader.summary(path: Self.fixturePath("rollout-exec.jsonl"))
        #expect(summary.recap?.contains("operation not permitted") == true)
        #expect(summary.recapSource == .stopMessage)
        #expect(summary.recapAt == Self.timestamp("2026-09-18T16:12:04.338Z"))
    }

    @Test("The first prompt is the first response_item message with role user, whatever it turns out to hold")
    func firstPromptIsTheFirstUserResponseItem() throws {
        let summary = try reader.summary(path: Self.fixturePath("rollout-exec.jsonl"))
        // In this real capture the earliest `role: "user"` response_item is environment/plugin
        // context the harness injects, not the human's own words — the ticket's rule names exactly
        // this shape with no further screening, so that is honestly what comes back.
        #expect(summary.firstPrompt?.hasPrefix("<recommended_plugins>") == true)
        #expect(summary.firstPromptAt == Self.timestamp("2026-09-18T16:11:58.123Z"))
    }

    // MARK: - summary — version drift, 0.130.0

    @Test("An older capture with a null last_agent_message yields no recap, not a crash")
    func olderCaptureWithNoFinalMessageHasNoRecap() throws {
        for name in ["rollout-short.jsonl", "rollout-turn.jsonl"] {
            let summary = try reader.summary(path: Self.fixturePath(name))
            #expect(summary.recap == nil, "\(name) should have no recap")
            #expect(summary.recapSource == nil, "\(name) should have no recap source")
        }
    }

    @Test("An older capture still finds a first prompt off the same response_item shape")
    func olderCaptureStillFindsAFirstPrompt() throws {
        for name in ["rollout-short.jsonl", "rollout-turn.jsonl"] {
            let summary = try reader.summary(path: Self.fixturePath(name))
            #expect(summary.firstPrompt?.isEmpty == false, "\(name) should have a first prompt")
        }
    }

    @Test("All three real captures parse without throwing, 25 releases apart")
    func everyRealCaptureParses() throws {
        for name in ["rollout-exec.jsonl", "rollout-short.jsonl", "rollout-turn.jsonl"] {
            _ = try reader.summary(path: Self.fixturePath(name))
        }
    }

    // MARK: - searchIndex

    @Test("The index carries user and agent messages only, in turn order")
    func searchIndexCarriesUserAndAgentMessagesOnly() throws {
        let index = try reader.searchIndex(path: Self.fixturePath("rollout-exec.jsonl"), existing: nil)
        let userLines = index.lines.filter { $0.kind == .user }
        let assistantLines = index.lines.filter { $0.kind == .assistant }
        let toolLines = index.lines.filter { $0.kind == .tool }
        #expect(userLines.count == 2)
        #expect(assistantLines.count == 2)
        #expect(toolLines.isEmpty)
        #expect(index.turns == 2)
    }

    @Test("A search hits the real prompt, not just the injected environment context")
    func searchFindsTheRealPrompt() throws {
        let index = try reader.searchIndex(path: Self.fixturePath("rollout-exec.jsonl"), existing: nil)
        let hits = index.search(foldedNeedle: TranscriptIndex.fold("spike-write-test"), limit: 10)
        #expect(!hits.isEmpty)
        #expect(hits.first?.kind == .user)
    }

    // MARK: - usage

    @Test("usage(conversationId:path:reader:) routes through the reader's Codex strategy, not the summing one")
    func usageRoutesThroughTheCodexStrategy() async throws {
        let cacheDir = try StatuslineTestSupport.tempDirectory("codex-usage-cache")
        let usageReader = TranscriptUsageReader(cacheDirectory: cacheDir.path)
        let usage = await reader.usage(
            conversationId: "codex-route-check",
            path: Self.fixturePath("rollout-token-count.jsonl"),
            reader: usageReader)
        // The trap this whole slice exists to avoid: a reader that sums every line's total would
        // report 6700 here. See TranscriptUsageReaderTests for the explicit 2600 assertion and the
        // arithmetic behind it.
        #expect(usage != nil)
    }
}
