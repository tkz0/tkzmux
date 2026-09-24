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
        let kind = mapKind(payload)
        return AgentEvent(
            kind: kind,
            conversationId: payload.sessionId,
            message: payload.message,
            // A sub-agent's `SubagentStop` carries *its* last message, which is not the session's
            // recap and must never land where the main turn's does.
            lastAssistantMessage: kind.isSubagentEvent ? nil : payload.lastAssistantMessage,
            cwd: payload.cwd,
            transcriptPath: payload.transcriptPath,
            source: payload.source,
            reason: payload.reason,
            // Only `Stop`'s list is a snapshot to trust: `SubagentStop`'s still names the agent
            // that is stopping (measured 2026-09-23, Claude Code 2.1.280).
            runningSubagents: kind == .turnEnded ? payload.backgroundTasks.map(runningSubagents) : nil,
            backgroundShells: kind == .turnEnded ? payload.backgroundTasks.map(backgroundShells) : nil
        )
    }

    private static let finishedStatuses: Set<String> = ["completed", "failed", "killed", "stopped", "cancelled"]

    /// `background_tasks` entries of `type: "subagent"` that have not finished.
    private static func runningSubagents(_ tasks: [HookBackgroundTask]) -> [SubagentInfo] {
        tasks.compactMap { task in
            guard task.type == "subagent", !finishedStatuses.contains(task.status ?? "") else { return nil }
            return SubagentInfo(id: task.id, type: task.agentType, description: task.description)
        }
    }

    /// `background_tasks` entries of `type: "shell"` that have not finished — for the status bar
    /// to name. Whether the row is working on their account is the descriptor's `"shell"` status.
    private static func backgroundShells(_ tasks: [HookBackgroundTask]) -> [BackgroundShellInfo] {
        tasks.compactMap { task in
            guard task.type == "shell", !finishedStatuses.contains(task.status ?? "") else { return nil }
            return BackgroundShellInfo(id: task.id, description: task.description, command: task.command)
        }
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
        case "SubagentStart":
            guard let agentId = payload.agentId, !agentId.isEmpty else { return .unknown(payload.eventName) }
            return .subagentStarted(SubagentInfo(id: agentId, type: payload.agentType))
        case "SubagentStop":
            guard let agentId = payload.agentId, !agentId.isEmpty else { return .unknown(payload.eventName) }
            return .subagentStopped(id: agentId)
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
