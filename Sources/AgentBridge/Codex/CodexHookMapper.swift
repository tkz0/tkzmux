// CodexHookMapper — Codex CLI's own hook vocabulary, translated into `AgentEvent`.
//
// Sibling to the other agent's own hook mapper (see `HookFrame.swift`'s header for why
// `HookServer`/`HookPayload` stay agent-blind): this is the one place in the codebase allowed to
// contain Codex's event-name strings. Codex reuses the same field names on the wire that the other
// supported agent does (`session_id`, `transcript_path`, `cwd`, `hook_event_name`, …), which is
// why `HookPayload` needed no new fields for it — see this test target's own `Fixtures/codex/README.md`.
//
// Every claim below about which fields a real event carries came off a logged-in codex-cli
// 0.155.0 during the TKZ-86 spike, captured in that same `Fixtures/codex/` directory. Where a
// shape is *inferred* rather than measured (`PermissionRequest`, `Interrupt`), the fixture
// README says so and this file repeats it at the case in question.
import TkzCore

public enum CodexHookMapper {
    /// Translates one Codex hook payload into the `AgentEvent` the store reacts to. `sessionID` is
    /// left nil here for the same reason the other agent's mapper leaves it nil: it is envelope
    /// data, not something Codex sent, and the caller fills it in from the frame.
    public static func map(_ payload: HookPayload) -> AgentEvent? {
        AgentEvent(
            kind: mapKind(payload),
            conversationId: payload.sessionId,
            message: message(for: payload),
            lastAssistantMessage: payload.lastAssistantMessage,
            cwd: payload.cwd,
            transcriptPath: payload.transcriptPath,
            source: payload.source,
            reason: payload.reason
        )
    }

    /// Codex sends no one-liner notification message the way the other supported agent does, but a
    /// `PermissionRequest`'s `tool_name` (measured on `PreToolUse`, inferred here) is the closest
    /// equivalent for the NEEDS YOU banner, so it stands in when present.
    private static func message(for payload: HookPayload) -> String? {
        guard payload.eventName == "PermissionRequest" else { return payload.message }
        return payload.toolName ?? payload.message
    }

    private static func mapKind(_ payload: HookPayload) -> AgentEvent.Kind {
        switch payload.eventName {
        case "SessionStart":
            return .sessionStart
        case "SessionEnd":
            // Measured: Codex's own `reason` is always `"other"` — it has no `/clear` or `resume`
            // equivalent that would leave the row alive, so unlike the other agent's own mapper
            // there is nothing in the reason to compare against. Every `SessionEnd` is a real exit.
            return .sessionEnd(exited: true)
        case "UserPromptSubmit":
            return .promptSubmitted
        case "Stop":
            // Measured: `last_assistant_message` arrives on the hook itself (see `hook-stop.json`),
            // not dug out of the rollout as the ticket assumed — `map(_:)` above already carries it
            // through on every event, so nothing extra is needed here.
            return .turnEnded
        case "Interrupt":
            // Inferred, not measured (interactive-only; a scripted `codex exec` run cannot produce
            // it). Without this a Codex row would stay "working" forever after the user hits Esc,
            // since nothing else ends the turn.
            return .turnEnded
        case "agent-turn-complete":
            // The `notify` argv event name — Codex's non-interactive completion signal, distinct
            // from the TUI's `Stop` hook but meaning the same thing to this store.
            return .turnEnded
        case "PermissionRequest":
            // Inferred, not measured: under `codex exec` the sandbox refuses a write outright
            // rather than asking, so this was never produced by the spike's own binary. Its shape
            // follows `hook-pre-tool-use.json`, which is real.
            return .attention(.permission)
        case "PreToolUse", "PostToolUse":
            // A mapper is a pure function of one payload and cannot know whether a permission
            // prompt is actually pending — that state lives in the store's `pendingNotification`.
            // Mapping unconditionally to `.attentionCleared` and letting `applyEvent` be the thing
            // that decides it has nothing to clear (it already handles a clear with no pending
            // prompt) is simpler and no less correct than teaching this mapper state it has no
            // business holding.
            return .attentionCleared
        case "PreCompact", "PostCompact", "SubagentStart", "SubagentStop":
            // Real, measured Codex event names with no mapping of their own yet. Routing them
            // anywhere but `.unknown` would be inventing behaviour nobody has asked for.
            return .unknown(payload.eventName)
        default:
            return .unknown(payload.eventName)
        }
    }
}
