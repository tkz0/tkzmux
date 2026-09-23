// The parsed form of one NDJSON frame received by `HookServer`. See the wire protocol in the M3.2
// ticket.
import Darwin
import Foundation
import TkzCore

/// One hook frame's payload, still in the agent's own vocabulary.
///
/// This is deliberately raw. `HookServer` does not know what `"Stop"` or `"permission_prompt"`
/// mean — it lifts the union of string fields any agent is known to send, and an adapter's mapper
/// (`ClaudeHookMapper`, `CodexHookMapper`) turns that into the `AgentEvent` the store reacts to.
/// Keeping the server agent-blind is what lets a second agent arrive as a mapper rather than as a
/// second parser.
///
/// Both Claude Code and Codex CLI happen to spell the event name `hook_event_name` and pass it on
/// stdin as JSON, so one shape covers both; `eventName` falls back to the argv name the shim used
/// when the payload omits it.
public struct HookPayload: Hashable, Sendable {
    /// Which agent sent this. Defaults to `.claude` when the frame carries no `agent` field: an
    /// already-installed shim from an older build keeps sending v1 frames without one until
    /// `ShimInstaller.ensureInstalled` refreshes `bin/`, and those are always Claude's.
    public var agent: AgentKind
    /// `hook_event_name`, or the name the shim passed as `argv[1]`.
    public var eventName: String
    /// The agent's own conversation id (`payload.session_id`).
    public var sessionId: String?
    public var transcriptPath: String?
    public var cwd: String?
    /// Claude's `notification_type`. Codex has no equivalent — its event names carry the meaning.
    public var notificationType: String?
    /// The agent's one-liner for a prompt, capped at 1 KiB by the server.
    public var message: String?
    /// The finished turn's last message, capped at 4 KiB by the server. The untruncated text rides
    /// alongside on the frame, for the recap cache.
    public var lastAssistantMessage: String?
    /// The ending reason, in the agent's own words. The mapper decides what counts as an exit.
    public var reason: String?
    public var source: String?
    /// Which tool a permission request is about. Codex populates it; Claude does not.
    public var toolName: String?
    /// The sub-agent a sub-agent lifecycle event is about (Claude's `agent_id`).
    public var agentId: String?
    /// That sub-agent's kind, in the agent's own words (Claude's `agent_type`).
    public var agentType: String?
    /// The agent's own list of work still running after this event, when it sends one (Claude's
    /// `background_tasks`, on `Stop` and `SubagentStop`). `nil` when the field is absent — an older
    /// agent build — which is distinct from `[]`, "nothing is running".
    public var backgroundTasks: [HookBackgroundTask]?

    public init(
        agent: AgentKind = .claude,
        eventName: String,
        sessionId: String? = nil,
        transcriptPath: String? = nil,
        cwd: String? = nil,
        notificationType: String? = nil,
        message: String? = nil,
        lastAssistantMessage: String? = nil,
        reason: String? = nil,
        source: String? = nil,
        toolName: String? = nil,
        agentId: String? = nil,
        agentType: String? = nil,
        backgroundTasks: [HookBackgroundTask]? = nil
    ) {
        self.agent = agent
        self.eventName = eventName
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.notificationType = notificationType
        self.message = message
        self.lastAssistantMessage = lastAssistantMessage
        self.reason = reason
        self.source = source
        self.toolName = toolName
        self.agentId = agentId
        self.agentType = agentType
        self.backgroundTasks = backgroundTasks
    }
}

/// One entry of an agent's running-work list, lifted as raw strings like the rest of
/// `HookPayload` — which `type` values exist and what they mean is the mapper's business.
public struct HookBackgroundTask: Hashable, Sendable {
    public var id: String
    public var type: String?
    public var status: String?
    public var description: String?
    public var agentType: String?

    public init(
        id: String, type: String? = nil, status: String? = nil, description: String? = nil,
        agentType: String? = nil
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.description = description
        self.agentType = agentType
    }
}

/// One decoded wire frame handed to `HookServer`'s `onFrame` callback, in arrival order.
public enum HookFrame: Sendable {
    /// A hook event forwarded by `tkzmux-hook <Event>`.
    ///
    /// `sessionID` and `ppid` are **envelope** data — the shim's own `TKZMUX_SESSION_ID` and the
    /// hook process's parent — not something the agent sent, which is why they ride here rather
    /// than on `HookPayload`. Keeping that line clean matters: `HookPayload` is what an adapter's
    /// mapper sees, and a mapper has no business reading tkzmux's own identifiers.
    ///
    /// `fullMessage` carries the untruncated `last_assistant_message` alongside the payload, which
    /// keeps only a 4 KiB prefix. Every hook kind carries the transcript path, so the first frame
    /// of a session is enough to learn where the agent keeps its conversation.
    case hook(HookPayload, sessionID: SessionID?, ppid: pid_t, fullMessage: String?)
    case launch(LaunchAnnouncement)
}

/// A `launch` frame sent by `tkzmux-hook launch` right after the shim `exec`s the real agent, so
/// the shim's pid is known as a `SessionID` before any descriptor file exists.
public struct LaunchAnnouncement: Hashable, Sendable {
    /// `rawSid` parsed as a `SessionID`, when it is a valid UUID; nil for a missing/empty/invalid sid.
    public var sessionID: SessionID?
    /// The `sid` field exactly as sent (may be empty).
    public var rawSid: String
    public var pid: pid_t
    public var cwd: String
    public var configDir: String
    public var argv: [String]
    /// Which agent the shim launched. Defaults to `.claude` for the same reason
    /// `HookPayload.agent` does: an already-installed shim keeps sending frames with no `agent`
    /// field until `ShimInstaller.ensureInstalled` refreshes `bin/`, and those are always Claude's.
    public var agent: AgentKind

    public init(
        sessionID: SessionID?, rawSid: String, pid: pid_t, cwd: String, configDir: String,
        argv: [String], agent: AgentKind = .claude
    ) {
        self.sessionID = sessionID
        self.rawSid = rawSid
        self.pid = pid
        self.cwd = cwd
        self.configDir = configDir
        self.argv = argv
        self.agent = agent
    }
}
