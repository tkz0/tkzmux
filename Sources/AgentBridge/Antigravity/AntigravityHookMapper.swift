// AntigravityHookMapper — Antigravity CLI's own hook vocabulary, translated into `AgentEvent`.
//
// Sibling to the other agents' own hook mappers: this is the one place in the codebase allowed to
// contain Antigravity's event-name strings.
//
// Every claim below came off a real logged-in Antigravity CLI 1.2.7, captured in this module's test
// target's own `Fixtures/antigravity/`. Two things that directory records and this file depends on:
//
//   * Antigravity supports exactly **five** `hooks.json` events — `PreInvocation`, `PostInvocation`,
//     `Stop`, `PreToolUse`, `PostToolUse`. `SessionStart`, `PreTurn` and `PostTurn` exist as types
//     inside the binary but are not configurable, and a probe registering them was ignored. There
//     is therefore **no session-start event to map**, which is why this mapper has no `.sessionStart`
//     case and why `AntigravityAdapter` leans on the launch frame for that instead.
//   * The payload is **camelCase** (protojson): `conversationId`, `transcriptPath`, `modelName`.
//     The *transcript* is snake_case. Both casings in one agent is real, not a typo.

import TkzCore

public enum AntigravityHookMapper {
    /// Translates one Antigravity hook payload into the `AgentEvent` the store reacts to.
    /// `sessionID` is left nil here, exactly as the other mappers leave it: it is envelope data,
    /// not something the agent sent, and the caller fills it in from the frame.
    public static func map(_ payload: HookPayload) -> AgentEvent? {
        AgentEvent(
            kind: mapKind(payload),
            conversationId: payload.sessionId,
            message: payload.message,
            lastAssistantMessage: payload.lastAssistantMessage,
            cwd: payload.cwd,
            transcriptPath: payload.transcriptPath,
            source: payload.source,
            reason: payload.reason
        )
    }

    private static func mapKind(_ payload: HookPayload) -> AgentEvent.Kind {
        switch payload.eventName {
        case "PreInvocation":
            // Measured: fires immediately before the model is called, once per invocation, and is
            // the earliest signal a turn is under way. The store reads a submitted prompt as "this
            // row is working", which is exactly what this means.
            return .promptSubmitted
        case "Stop":
            // Measured: fires when the execution loop terminates, carrying `terminationReason`
            // (`NO_TOOL_CALL` on a plain answer) and `fullyIdle`. `fullyIdle == false` means the
            // loop stopped but the agent has more to do, so only a fully idle Stop ends the turn —
            // otherwise a row would flip to "done" mid-way through a multi-step task.
            return payload.reason == "partial" ? .unknown("Stop") : .turnEnded
        case "PostInvocation":
            // Measured: fires after the tool calls of one invocation finish, which is *not* the end
            // of the turn — `Stop` is. Mapping this to `.turnEnded` too would end the turn on the
            // first invocation of a multi-invocation task. It clears a pending permission prompt
            // and nothing more.
            return .attentionCleared
        case "PreToolUse":
            // A mapper is a pure function of one payload and cannot know whether a permission
            // prompt is pending — that state lives in the store's `pendingNotification`. The same
            // reasoning the other installing agent's own mapper spells out applies here.
            return .attentionCleared
        case "PostToolUse":
            return .attentionCleared
        default:
            return .unknown(payload.eventName)
        }
    }
}
