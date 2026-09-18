// TkzCore — what tkzmux can see of a running agent, from the side.
//
// Some agents write a descriptor file describing themselves while they run; Claude Code does, at
// `<configDir>/sessions/<pid>.json`. That file is one agent's schema, so the parsed form of it
// belongs in that agent's adapter (`AgentBridge/Claude/ClaudeSessionInfo.swift`), not here. This
// is the projection of it that the store reacts to — the fields any such file would have to supply
// to be useful, and nothing agent-specific.
//
// Carrying only this is what makes the layering work: `TkzCore` cannot import `AgentBridge` (the
// dependency runs the other way), so `LiveSessionState` could not hold a Claude type even if we
// wanted it to. An agent with no descriptor file at all — Codex has none — simply never produces
// an observation, and `StatusDerivation`'s rule 4b covers that case from hook evidence instead.

import Foundation

public struct AgentObservation: Hashable, Sendable {
    /// What the agent says it is doing right now.
    public enum Activity: String, Hashable, Sendable, Codable {
        case idle
        case busy
        /// A prompt is on screen and unanswered. Claude Code writes this while a permission prompt
        /// is up, which is what lets a session with no hooks at all still light `NEEDS YOU`.
        case waiting
    }

    public var pid: pid_t
    /// The agent's own conversation id, opaque to tkzmux.
    public var conversationId: String
    /// The directory the descriptor was found in, which is what says *which account* this is.
    /// Kept on the observation because `learnAccount` and the watcher's key both need it.
    public var configDir: String
    /// Where the agent says it is running, which can differ from where its shell is: `claude -w`
    /// chdirs into the worktree it just created and the shell underneath never follows.
    public var cwd: String?
    /// `nil` when the descriptor carried a status this build does not recognise — treated as "no
    /// evidence" rather than guessed, so a newer agent's new status cannot flip a row wrongly.
    public var activity: Activity?
    /// A background job parked under this session: not busy, not waiting.
    public var parked: Bool
    public var name: String?
    /// Whether `name` was derived by the agent rather than set by the user. A derived name loses to
    /// tkzmux's own title derivation.
    public var nameIsDerived: Bool
    public var startedAt: Date?
    /// When the agent last changed `activity`. Used to decide whether a pending prompt has been
    /// overtaken by newer evidence.
    public var statusUpdatedAt: Date?

    public init(
        pid: pid_t,
        conversationId: String,
        configDir: String,
        cwd: String? = nil,
        activity: Activity? = nil,
        parked: Bool = false,
        name: String? = nil,
        nameIsDerived: Bool = false,
        startedAt: Date? = nil,
        statusUpdatedAt: Date? = nil
    ) {
        self.pid = pid
        self.conversationId = conversationId
        self.configDir = configDir
        self.cwd = cwd
        self.activity = activity
        self.parked = parked
        self.name = name
        self.nameIsDerived = nameIsDerived
        self.startedAt = startedAt
        self.statusUpdatedAt = statusUpdatedAt
    }
}
