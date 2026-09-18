// Tests for ClaudeHookMapper: every event name Claude's shim injects, every notification type
// (including both alias pairs), and the SessionEnd reason vocabulary. M3.2 follow-up (TKZ-80).
import Testing
import TkzCore

@testable import ClaudeBridge

@Suite struct ClaudeHookMapperTests {
    private func payload(
        eventName: String,
        notificationType: String? = nil,
        reason: String? = nil,
        sessionId: String? = nil
    ) -> HookPayload {
        HookPayload(eventName: eventName, sessionId: sessionId, notificationType: notificationType, reason: reason)
    }

    @Test func sessionStart() {
        let event = ClaudeHookMapper.map(payload(eventName: "SessionStart"))
        #expect(event?.kind == .sessionStart)
    }

    @Test func userPromptSubmit() {
        let event = ClaudeHookMapper.map(payload(eventName: "UserPromptSubmit"))
        #expect(event?.kind == .promptSubmitted)
    }

    @Test func stop() {
        let event = ClaudeHookMapper.map(payload(eventName: "Stop"))
        #expect(event?.kind == .turnEnded)
    }

    @Test func sessionEndWithClearReasonDoesNotCountAsExited() {
        let event = ClaudeHookMapper.map(payload(eventName: "SessionEnd", reason: "clear"))
        #expect(event?.kind == .sessionEnd(exited: false))
    }

    @Test func sessionEndWithResumeReasonDoesNotCountAsExited() {
        let event = ClaudeHookMapper.map(payload(eventName: "SessionEnd", reason: "resume"))
        #expect(event?.kind == .sessionEnd(exited: false))
    }

    @Test func sessionEndWithOtherReasonCountsAsExited() {
        let event = ClaudeHookMapper.map(payload(eventName: "SessionEnd", reason: "other"))
        #expect(event?.kind == .sessionEnd(exited: true))
    }

    @Test func sessionEndWithNoReasonCountsAsExited() {
        let event = ClaudeHookMapper.map(payload(eventName: "SessionEnd"))
        #expect(event?.kind == .sessionEnd(exited: true))
    }

    @Test func unknownEventName() {
        let event = ClaudeHookMapper.map(payload(eventName: "SomethingElse"))
        #expect(event?.kind == .unknown("SomethingElse"))
    }

    @Test func notificationWithNoTypeIsUnknownNotACrash() {
        let event = ClaudeHookMapper.map(payload(eventName: "Notification"))
        #expect(event?.kind == .unknown("Notification"))
    }

    @Test func notificationPermissionPrompt() {
        let event = ClaudeHookMapper.map(payload(eventName: "Notification", notificationType: "permission_prompt"))
        #expect(event?.kind == .attention(.permission))
    }

    @Test func notificationIdlePrompt() {
        let event = ClaudeHookMapper.map(payload(eventName: "Notification", notificationType: "idle_prompt"))
        #expect(event?.kind == .attention(.idleNudge))
    }

    @Test func notificationElicitationDialog() {
        let event = ClaudeHookMapper.map(payload(eventName: "Notification", notificationType: "elicitation_dialog"))
        #expect(event?.kind == .attention(.question))
    }

    @Test func notificationElicitationUrlDialog() {
        let event = ClaudeHookMapper.map(payload(eventName: "Notification", notificationType: "elicitation_url_dialog"))
        #expect(event?.kind == .attention(.question))
    }

    @Test func notificationElicitationComplete() {
        let event = ClaudeHookMapper.map(payload(eventName: "Notification", notificationType: "elicitation_complete"))
        #expect(event?.kind == .attentionCleared)
    }

    @Test func notificationElicitationResponse() {
        let event = ClaudeHookMapper.map(payload(eventName: "Notification", notificationType: "elicitation_response"))
        #expect(event?.kind == .attentionCleared)
    }

    @Test func notificationAgentNeedsInput() {
        let event = ClaudeHookMapper.map(payload(eventName: "Notification", notificationType: "agent_needs_input"))
        #expect(event?.kind == .attention(.agentInput))
    }

    @Test func notificationUnknownType() {
        let event = ClaudeHookMapper.map(payload(eventName: "Notification", notificationType: "something_new"))
        #expect(event?.kind == .unknown("something_new"))
    }

    /// `sessionId` carries across as `conversationId`; `sessionID` (tkzmux's own identifier) is not
    /// something the mapper ever sees, since it lives on the frame, not the payload.
    @Test func sessionIdCarriesAcrossAsConversationId() {
        let event = ClaudeHookMapper.map(payload(eventName: "Stop", sessionId: "11111111-2222-3333-4444-555555555555"))
        #expect(event?.conversationId == "11111111-2222-3333-4444-555555555555")
        #expect(event?.sessionID == nil)
    }
}
