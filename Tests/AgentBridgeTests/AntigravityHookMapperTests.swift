// AntigravityHookMapperTests — one case per captured fixture, plus the events that must NOT map.

import Foundation
import Testing
import TkzCore

@testable import AgentBridge

@Suite struct AntigravityHookMapperTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/antigravity")

    /// Builds a `HookPayload` the way `HookServer` would after parsing one of the captured files,
    /// so these tests exercise the real field names rather than a hand-made payload.
    static func payload(fixture: String, eventName: String) throws -> HookPayload {
        let data = try Data(contentsOf: fixtures.appendingPathComponent(fixture))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return HookPayload(
            agent: .antigravity,
            eventName: eventName,
            sessionId: HookServer.field(object, "session_id", "conversationId"),
            transcriptPath: HookServer.field(object, "transcript_path", "transcriptPath"),
            cwd: object["cwd"] as? String,
            reason: object["reason"] as? String)
    }

    @Test("PreInvocation is the earliest signal a turn is under way")
    func preInvocationStartsTheTurn() throws {
        let event = try #require(
            AntigravityHookMapper.map(Self.payload(fixture: "hook-pre-invocation.json", eventName: "PreInvocation")))
        #expect(event.kind == .promptSubmitted)
        // The captured payload carries the ids the store joins on.
        #expect(event.conversationId == "ec33ebf9-0cba-4100-8142-c61503f6c587")
        #expect(event.transcriptPath?.hasSuffix("transcript_full.jsonl") == true)
    }

    @Test("Stop ends the turn")
    func stopEndsTheTurn() throws {
        let event = try #require(
            AntigravityHookMapper.map(Self.payload(fixture: "hook-stop.json", eventName: "Stop")))
        #expect(event.kind == .turnEnded)
    }

    /// The distinction that matters most here. `PostInvocation` fires after the tool calls of *one*
    /// invocation finish, which is not the end of the turn — `Stop` is. Mapping it to `.turnEnded`
    /// too would mark a multi-step task done on its first step.
    @Test("PostInvocation does not end the turn")
    func postInvocationDoesNotEndTheTurn() throws {
        let event = try #require(
            AntigravityHookMapper.map(
                Self.payload(fixture: "hook-post-invocation.json", eventName: "PostInvocation")))
        #expect(event.kind == .attentionCleared)
        #expect(event.kind != .turnEnded)
    }

    @Test("Tool events clear a pending prompt and nothing more")
    func toolEventsClearAttention() {
        for name in ["PreToolUse", "PostToolUse"] {
            let event = AntigravityHookMapper.map(
                HookPayload(agent: .antigravity, eventName: name))
            #expect(event?.kind == .attentionCleared, "\(name)")
        }
    }

    /// Antigravity supports exactly five `hooks.json` events. `SessionStart`, `PreTurn` and
    /// `PostTurn` exist inside the binary but are not configurable, and a probe registering them
    /// was silently ignored — so nothing should claim to map them.
    @Test("An event Antigravity cannot actually send maps to unknown, not to a guess")
    func unconfigurableEventsAreUnknown() {
        for name in ["SessionStart", "PreTurn", "PostTurn", "Whatever"] {
            let event = AntigravityHookMapper.map(HookPayload(agent: .antigravity, eventName: name))
            #expect(event?.kind == .unknown(name), "\(name)")
        }
    }

    /// `HookServer` parses snake_case for the other two agents and camelCase for this one, because
    /// Antigravity's payloads are protojson. This pins that the camelCase spelling actually reaches
    /// the mapper — it is the difference between a bound row and a silently unbound one.
    @Test("The camelCase wire spelling is read, and snake_case still wins when both are present")
    func wireSpellings() {
        #expect(HookServer.field(["conversationId": "a"], "session_id", "conversationId") == "a")
        #expect(HookServer.field(["session_id": "b"], "session_id", "conversationId") == "b")
        #expect(
            HookServer.field(["session_id": "b", "conversationId": "a"], "session_id", "conversationId")
                == "b",
            "snake_case wins, so nothing about the existing agents can change")
        #expect(HookServer.field([:], "session_id", "conversationId") == nil)
    }
}
