// Tests for CodexHookMapper — driven from the captured fixtures in `Fixtures/codex/` wherever one
// exists (see that directory's README for which files came off a real binary versus which are
// inferred), because those captures are the whole point of the TKZ-86 spike: they are what proved
// the ticket wrong about `Stop` carrying `last_assistant_message` itself, and they are what
// `SessionEnd`'s "always an exit" rule is measured against.
import Foundation
import Testing
import TkzCore

@testable import ClaudeBridge

@Suite struct CodexHookMapperTests {
    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/ClaudeBridgeTests/CodexHookMapperTests.swift
            .deletingLastPathComponent()          // Tests/ClaudeBridgeTests
            .appendingPathComponent("Fixtures/codex")
    }

    /// Loads one fixture the same way `HookServer.parseHookFrame` would build a `HookPayload` out
    /// of its own `payload` dictionary — a fixture file *is* that dictionary, verbatim.
    private static func loadPayload(_ name: String) throws -> HookPayload {
        let url = fixturesDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        // `notify-agent-turn-complete.json` has no `hook_event_name` at all — it is the `notify`
        // argv payload, not a hook payload, and names itself with `type` instead. Falling back to
        // that mirrors how the real frame's envelope event ends up as `eventName` when the payload
        // itself is silent on it (`HookServer.parseHookFrame`).
        let eventName = (obj["hook_event_name"] as? String) ?? (obj["type"] as? String) ?? ""
        return HookPayload(
            agent: .codex,
            eventName: eventName,
            sessionId: obj["session_id"] as? String,
            transcriptPath: obj["transcript_path"] as? String,
            cwd: obj["cwd"] as? String,
            notificationType: obj["notification_type"] as? String,
            message: obj["message"] as? String,
            lastAssistantMessage: obj["last_assistant_message"] as? String,
            reason: obj["reason"] as? String,
            source: obj["source"] as? String,
            toolName: obj["tool_name"] as? String
        )
    }

    private func payload(
        eventName: String,
        sessionId: String? = nil,
        toolName: String? = nil,
        reason: String? = nil
    ) -> HookPayload {
        HookPayload(agent: .codex, eventName: eventName, sessionId: sessionId, reason: reason, toolName: toolName)
    }

    // MARK: - Measured, from fixtures

    @Test func sessionStart() throws {
        let event = CodexHookMapper.map(try Self.loadPayload("hook-session-start.json"))
        #expect(event?.kind == .sessionStart)
    }

    @Test func userPromptSubmit() throws {
        let event = CodexHookMapper.map(try Self.loadPayload("hook-user-prompt-submit.json"))
        #expect(event?.kind == .promptSubmitted)
    }

    /// The fact this proves: `last_assistant_message` rides in on the `Stop` hook itself, which is
    /// what the fixture's README says the ticket had gotten wrong.
    @Test func stopCarriesTheLastAssistantMessage() throws {
        let event = CodexHookMapper.map(try Self.loadPayload("hook-stop.json"))
        #expect(event?.kind == .turnEnded)
        #expect(event?.lastAssistantMessage == "pong")
    }

    /// Measured: Codex's own `reason` is `"other"` here, and unlike Claude's `clear`/`resume` pair
    /// it does not mean the row stays alive — every `SessionEnd` is a real exit.
    @Test func sessionEndIsAlwaysAnExit() throws {
        let event = CodexHookMapper.map(try Self.loadPayload("hook-session-end.json"))
        #expect(event?.kind == .sessionEnd(exited: true))
    }

    @Test func preToolUseClearsAttention() throws {
        let event = CodexHookMapper.map(try Self.loadPayload("hook-pre-tool-use.json"))
        #expect(event?.kind == .attentionCleared)
    }

    @Test func postToolUseClearsAttention() throws {
        let event = CodexHookMapper.map(try Self.loadPayload("hook-post-tool-use.json"))
        #expect(event?.kind == .attentionCleared)
    }

    // MARK: - Inferred (fixture, but not off a real binary)

    /// `hook-permission-request.json` is inferred, not measured — `codex exec`'s sandbox refuses a
    /// write outright rather than asking — but its shape follows the real `PreToolUse` fixture.
    @Test func permissionRequestPutsTheToolNameInMessage() throws {
        let event = CodexHookMapper.map(try Self.loadPayload("hook-permission-request.json"))
        #expect(event?.kind == .attention(.permission))
        #expect(event?.message == "shell")
    }

    /// `hook-interrupt.json` is inferred — `Interrupt` is interactive-only, so a scripted run
    /// cannot produce it — but without this mapping a Codex row would stay "working" forever after
    /// the user hits Esc.
    @Test func interruptEndsTheTurn() throws {
        let event = CodexHookMapper.map(try Self.loadPayload("hook-interrupt.json"))
        #expect(event?.kind == .turnEnded)
    }

    /// The `notify` argv event, hand-written because a single scripted `codex exec` run has no
    /// occasion to produce a rate-limit-refresh-shaped notify call.
    @Test func agentTurnCompleteEndsTheTurn() throws {
        let event = CodexHookMapper.map(try Self.loadPayload("notify-agent-turn-complete.json"))
        #expect(event?.kind == .turnEnded)
    }

    // MARK: - Real event names with no mapping of their own

    @Test func preCompactIsUnknown() {
        let event = CodexHookMapper.map(payload(eventName: "PreCompact"))
        #expect(event?.kind == .unknown("PreCompact"))
    }

    @Test func postCompactIsUnknown() {
        let event = CodexHookMapper.map(payload(eventName: "PostCompact"))
        #expect(event?.kind == .unknown("PostCompact"))
    }

    @Test func subagentStartIsUnknown() {
        let event = CodexHookMapper.map(payload(eventName: "SubagentStart"))
        #expect(event?.kind == .unknown("SubagentStart"))
    }

    @Test func subagentStopIsUnknown() {
        let event = CodexHookMapper.map(payload(eventName: "SubagentStop"))
        #expect(event?.kind == .unknown("SubagentStop"))
    }

    @Test func somethingUnrecognisedIsUnknownRatherThanGuessed() {
        let event = CodexHookMapper.map(payload(eventName: "SomeFutureEvent"))
        #expect(event?.kind == .unknown("SomeFutureEvent"))
    }

    // MARK: - Envelope plumbing

    /// `sessionId` carries across as `conversationId`, exactly as it does for Claude — same field,
    /// same meaning, because Codex reuses Claude's own wire vocabulary for it.
    @Test func sessionIdCarriesAcrossAsConversationId() {
        let event = CodexHookMapper.map(payload(eventName: "Stop", sessionId: "11111111-2222-3333-4444-555555555555"))
        #expect(event?.conversationId == "11111111-2222-3333-4444-555555555555")
        #expect(event?.sessionID == nil)
    }
}
