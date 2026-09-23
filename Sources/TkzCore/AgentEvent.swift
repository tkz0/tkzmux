// TkzCore — what an agent told us happened, in tkzmux's own vocabulary.
//
// `AgentEvent` is deliberately *not* a hook frame. A hook frame is one agent's wire format, full of
// that agent's event names, notification types and payload keys; this is the handful of things the
// store actually reacts to. Translating one into the other is an adapter's job, in AgentBridge —
// `ClaudeHookMapper` for Claude, `CodexHookMapper` later — which is what keeps TkzCore free of any
// agent's vocabulary. Grepping this directory for any agent's literal event or notification names
// and finding nothing is the mechanical form of that rule.

import Foundation

/// Why a session wants the human. Maps 1:1 onto `WaitReason` for the three that become a status —
/// and deliberately does not for the fourth.
public enum AttentionKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// A tool-permission prompt is on screen.
    case permission
    /// An elicitation dialog, or any other "answer this question" prompt.
    case question
    /// The agent is blocked waiting for input that is not a permission or a question.
    case agentInput
    /// **Not attention.** A nudge that the agent has been sitting idle. It never lights
    /// `NEEDS YOU` on its own; it only accelerates the rule that turns an unattended finished turn
    /// into `NEEDS YOU` before the 60 s grace is up. Keeping it inside
    /// `AttentionKind` rather than inventing a second enum is what lets one `pendingNotification`
    /// slot carry both, exactly as it did before.
    case idleNudge

    /// The status this kind becomes, or `nil` when it is not status-bearing on its own.
    public var waitReason: WaitReason? {
        switch self {
        case .permission: .permission
        case .question: .elicitation
        case .agentInput: .agentInput
        case .idleNudge: nil
        }
    }
}

/// One thing an agent reported, already translated out of its own wire vocabulary.
public struct AgentEvent: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        /// The agent started, or restarted after a `/clear`.
        case sessionStart
        /// The agent stopped. `exited` is false for the endings that are not an exit — for Claude,
        /// a `/clear` or a resume, which leave the row alive. The adapter decides which is which,
        /// because only it knows that agent's reason vocabulary.
        case sessionEnd(exited: Bool)
        /// The user sent a prompt. Evidence the row is attended, and — for an agent with no
        /// observation file — evidence that it is now working.
        case promptSubmitted
        /// A turn finished.
        case turnEnded
        /// The agent wants the human. See `AttentionKind` for why `.idleNudge` is in here.
        case attention(AttentionKind)
        /// A prompt that was up has been answered or withdrawn.
        case attentionCleared
        /// The agent started a sub-agent — in the foreground or, the case that matters, in the
        /// background, where it keeps working after the main turn has ended.
        case subagentStarted(SubagentInfo)
        /// A sub-agent finished.
        case subagentStopped(id: String)
        /// Something the adapter did not recognise, kept verbatim for the log.
        case unknown(String)

        /// About a sub-agent rather than the session's own turn.
        public var isSubagentEvent: Bool {
            switch self {
            case .subagentStarted, .subagentStopped: true
            default: false
            }
        }

        public var isSubagentStop: Bool {
            if case .subagentStopped = self { true } else { false }
        }
    }

    public var kind: Kind
    /// `TKZMUX_SESSION_ID` as the shim sent it, when it parsed.
    public var sessionID: SessionID?
    /// The agent's own conversation id — for Claude its `session_id`, for Codex the rollout id.
    public var conversationId: String?
    /// The agent's one-line description of the prompt, for the `NEEDS YOU` banner.
    public var message: String?
    /// The agent's last message of the finished turn, for the recap.
    public var lastAssistantMessage: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var source: String?
    /// The raw ending reason. `sessionEnd(exited:)` already carries the decision, but the string
    /// survives because `ActivityEvent.Kind.sessionEnded(reason:)` persists and renders it.
    public var reason: String?
    public var pid: pid_t?
    /// The agent's own list of sub-agents still running as of this event, when it sends one. A
    /// `turnEnded` carrying it replaces the row's running set outright — the list is authoritative
    /// and repairs any start/stop pair that went missing. `nil` means "not sent", never "none".
    public var runningSubagents: [SubagentInfo]?
    public var receivedAt: Date

    public init(
        kind: Kind,
        sessionID: SessionID? = nil,
        conversationId: String? = nil,
        message: String? = nil,
        lastAssistantMessage: String? = nil,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        source: String? = nil,
        reason: String? = nil,
        pid: pid_t? = nil,
        runningSubagents: [SubagentInfo]? = nil,
        receivedAt: Date = Date()
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.conversationId = conversationId
        self.message = message
        self.lastAssistantMessage = lastAssistantMessage
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.source = source
        self.reason = reason
        self.pid = pid
        self.runningSubagents = runningSubagents
        self.receivedAt = receivedAt
    }
}

/// A sub-agent as the agent described it. `type` and `description` are the agent's own words
/// ("Explore", "Compare CRM adapter interfaces"), shown verbatim in the status bar's tooltip.
public struct SubagentInfo: Hashable, Sendable, Codable {
    public var id: String
    public var type: String?
    public var description: String?

    public init(id: String, type: String? = nil, description: String? = nil) {
        self.id = id
        self.type = type
        self.description = description
    }
}
