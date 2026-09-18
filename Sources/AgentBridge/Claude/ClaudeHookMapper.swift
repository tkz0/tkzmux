// ClaudeHookMapper — Claude Code's own hook vocabulary, translated into `AgentEvent`.
//
// `HookServer` and `HookPayload` are deliberately agent-blind (see `HookFrame.swift`'s doc
// comments): they lift the union of fields any agent might send, without knowing what any of the
// strings mean. This file is where the meaning lives for Claude specifically — the only place in
// the codebase allowed to contain `"SessionStart"`, `"permission_prompt"`, `"idle_prompt"` and the
// rest of Claude's vocabulary. A `CodexHookMapper` alongside it will own Codex's own strings the
// same way.
import TkzCore

public enum ClaudeHookMapper {
    /// Translates one Claude hook payload into the `AgentEvent` the store reacts to. `sessionID` is
    /// left nil here — it is envelope data (`HookFrame.hook`'s own associated value), not something
    /// Claude sent, and the caller fills it in from the frame.
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
        case "SessionStart":
            return .sessionStart
        case "SessionEnd":
            // Claude's own reason vocabulary: a `/clear` or a `--resume` both leave the row alive,
            // so only those two count as "not exited". Everything else — a real quit, a crash — is.
            let staysAlive = payload.reason == "clear" || payload.reason == "resume"
            return .sessionEnd(exited: !staysAlive)
        case "UserPromptSubmit":
            return .promptSubmitted
        case "Stop":
            return .turnEnded
        case "Notification":
            return mapNotification(payload.notificationType)
        default:
            return .unknown(payload.eventName)
        }
    }

    /// Claude's `notification_type` values. The alias pairs (`elicitation_dialog` /
    /// `elicitation_url_dialog`, `elicitation_complete` / `elicitation_response`) both matter: they
    /// come from different Claude Code versions for the same UI state, not from different states.
    private static func mapNotification(_ raw: String?) -> AgentEvent.Kind {
        guard let raw else { return .unknown("Notification") }
        switch raw {
        case "permission_prompt":
            return .attention(.permission)
        case "idle_prompt":
            return .attention(.idleNudge)
        case "elicitation_dialog", "elicitation_url_dialog":
            return .attention(.question)
        case "elicitation_complete", "elicitation_response":
            return .attentionCleared
        case "agent_needs_input":
            return .attention(.agentInput)
        default:
            return .unknown(raw)
        }
    }
}
