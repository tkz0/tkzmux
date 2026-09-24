// TkzCore — the app's domain model.
//
// Everything in this file is a value type: `Hashable`, `Sendable`, and (where it is persisted)
// `Codable`. No AppKit, no SwiftUI — TkzCore is the half of the app that can be tested headless,
// and `TkzCoreTests.noUIFrameworksInTkzCore` enforces that mechanically.
//
// Persistence note (M5 / `state.json` v1): the *durable* fields are the stored properties of
// `Group`, `Session` (minus `live`) and the selection/window fields of `AppState`.
// Everything that describes a running process — `LiveSessionState` and everything it holds —
// is rebuilt at launch, never written to disk, hence `Session.live` is excluded from `Codable`.

import CoreGraphics
import Foundation

// MARK: - Identifiers

/// Shared behaviour for the UUID-backed identifiers below.
///
/// The string form is `UUID.uuidString` (uppercase, hyphenated). That matters beyond aesthetics:
/// a `TerminalID` is used as a **file basename** (`<id>.ghsnap`) and a `SessionID` as the value of
/// the **`TKZMUX_SESSION_ID`** environment variable handed to the shim, so neither may ever
/// contain `/`, NUL, or be `.`/`..`. A UUID string satisfies all of that by construction, which is
/// why `init?(_:)` rejects anything that is not a UUID rather than merely checking for slashes.
public protocol UUIDIdentifier: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    var uuid: UUID { get }
    init(uuid: UUID)
}

extension UUIDIdentifier {
    /// The round-trippable string form; valid as a file basename and as `TKZMUX_SESSION_ID`.
    public var rawValue: String { uuid.uuidString }

    /// Parses the string form produced by `rawValue`. Fails for anything that is not a UUID.
    public init?(_ rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.init(uuid: uuid)
    }

    /// A fresh, random identifier.
    public static func generate() -> Self { Self(uuid: UUID()) }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "'\(raw)' is not a UUID identifier")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Identity of a session group (one repo, or a hand-made bucket).
public struct GroupID: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// Identity of a terminal session. Also the `.ghsnap` basename and `TKZMUX_SESSION_ID`.
///
/// `TkzApp/TerminalHost.swift` carries a temporary `SessionID` of its own from M1.10; this is the
/// real one and M2.2 migrates the host onto it. The shapes match deliberately (`rawValue`,
/// `init?(_:)`, `generate()`, `Comparable`, `CustomStringConvertible`), so the migration is a
/// deletion plus an import.
public struct SessionID: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

// MARK: - Codable for RGB

/// `RGB` (M0.2) is deliberately Foundation-free, so its `Codable` conformance lives here, with the
/// persisted models that need it (`Group.color`). Wire form: `{"r":…, "g":…, "b":…, "a":…}`.
extension RGB: Codable {
    private enum CodingKeys: String, CodingKey { case r, g, b, a }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            r: try c.decode(Double.self, forKey: .r),
            g: try c.decode(Double.self, forKey: .g),
            b: try c.decode(Double.self, forKey: .b),
            a: try c.decodeIfPresent(Double.self, forKey: .a) ?? 1
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(r, forKey: .r)
        try c.encode(g, forKey: .g)
        try c.encode(b, forKey: .b)
        try c.encode(a, forKey: .a)
    }
}

// MARK: - Group

/// A sidebar group: normally one repo, sometimes a hand-made bucket ("Scheduled", "Elsewhere").
public struct Group: Hashable, Sendable, Codable, Identifiable {
    public var id: GroupID
    /// Displayed uppercased by the sidebar; stored as typed.
    public var name: String
    /// Absolute path of the repo this group represents, or `nil` for a bucket with no repo.
    public var repoRoot: String?
    /// The 2.5 pt colour edge down the group's left side — the header row and every session row in
    /// it. `nil` = **no edge at all** (fully transparent), never `Theme.groupEdgeDefault`: that
    /// token is the colour the picker offers as its default, not a fallback. Set from the sidebar's
    /// "Group color" context menu, whose entries are `GroupPalette.swatches`.
    public var color: RGB?
    public var isCollapsed: Bool
    /// Sort key among groups. Contiguous from 0 after `AppState.normalizeGroupOrder()`.
    public var order: Int
    /// Which account new sessions in this group default to (`Account.key`).
    public var defaultAccountKey: String?
    /// Which coding agent new sessions in this group start. Set from the sidebar's "Agent" context
    /// menu, the ＋ menu's own picker, and Settings → Agents.
    ///
    /// `nil` means *never chosen*, not *Claude*: the ＋ menu resolves one (see
    /// `NewSessionMenu.effectiveAgent`), which is what every group did implicitly before this field
    /// existed. Keeping it optional is also what lets a group survive uninstalling an agent —
    /// a non-optional defaulted to `.claude` would need a migration to stamp every existing group,
    /// and would pin them all to an agent the user may not have.
    ///
    /// Optional for the decode story too: an older `state.json` simply has no key here, and the
    /// synthesised `Codable` reads that as `nil` with no migration and no schema bump. Contrast
    /// `Session.agent`, whose absence would mislabel every row — which is why *that* one earned the
    /// v3→v4 lift and this one does not.
    public var agent: AgentKind?

    public init(
        id: GroupID = .generate(),
        name: String,
        repoRoot: String? = nil,
        color: RGB? = nil,
        isCollapsed: Bool = false,
        order: Int = 0,
        defaultAccountKey: String? = nil,
        agent: AgentKind? = nil
    ) {
        self.id = id
        self.name = name
        self.repoRoot = repoRoot
        self.color = color
        self.isCollapsed = isCollapsed
        self.order = order
        self.defaultAccountKey = defaultAccountKey
        self.agent = agent
    }
}

// MARK: - Session

/// One terminal session — a row in the sidebar and, when selected, the terminal surface.
///
/// The stored properties are durable; `live` is not (see the file header). A restored session
/// therefore has `live == nil` until it is first shown, when the launcher puts a shell behind it.
public struct Session: Hashable, Sendable, Identifiable {
    public var id: SessionID
    public var groupID: GroupID
    /// Sort key within the group. Contiguous from 0 after `AppState.normalizeSessionOrder(in:)`.
    public var order: Int
    /// A user rename. `nil` means "derive it" — see `displayTitle`.
    public var title: String?
    /// Working directory the session was started in.
    public var cwd: String
    /// Root of the repo the session belongs to (the *main* checkout, even for a worktree).
    public var repoRoot: String?
    /// `<repo>/.claude/worktrees/<name>` when the session runs `claude -w`.
    public var worktreePath: String?
    /// Drives the `WT` badge. Kept explicit rather than derived from `worktreePath != nil`,
    /// because a restored session whose worktree has been deleted clears the badge but may keep
    /// the path for the error message.
    public var isWorktree: Bool
    /// Which coding agent this row runs. Persisted; the v4 lift stamps `claude` on every row that
    /// predates the key, so it is never absent on disk.
    public var agent: AgentKind
    /// `Account.key` — the basename of the agent's config dir (`claude`, `claude-work`, `codex`).
    public var accountKey: String
    /// The agent's own conversation id — for Claude, its `session_id` — used for
    /// `claude --resume <id>`. Opaque to tkzmux. Rotates on `/clear`, resume and fork, so it is
    /// updated whenever an observation or a session-start event says so.
    public var conversationId: String?
    public var createdAt: Date
    public var lastActiveAt: Date
    /// This session's own opt-out of the token usage/spend feature (design: enable/disable, per
    /// session), on top of `AppState.showSessionSpend`'s global switch. `nil` = tracked, the
    /// default; `true` = this session opted out. Never `false` — see
    /// `AppState.setSpendTrackingDisabled(_:_:)`, the only writer.
    public var spendTrackingDisabled: Bool?
    /// This session posts no macOS notifications: neither NEEDS YOU nor "finished". The
    /// badge and the tint are untouched. `nil` = not muted, the default; `true` = muted. Never
    /// `false` — see `AppState.setNotificationsMuted(_:_:)`, the only writer.
    public var notificationsMuted: Bool?
    /// The agent in this row has exited (`/exit`, a crash, its process gone) and has not come
    /// back since. Persisted, because it is what tells the launch-time auto-resume pass that this
    /// conversation was *not* running when tkzmux quit — `conversationId` alone cannot. It gates
    /// only that pass: ⌘R and the menu's Resume still reopen the conversation. `nil` = running or
    /// unknown (the default, and what a file from before this key decodes to); `true` = exited.
    /// Never `false`: `applyEvent`, `applyObservation`, `adoptDescriptor` and `agentLost` write it.
    public var agentExited: Bool?

    /// The session's tabs, in strip order. Never empty: `closePane`/`closeTab` refuse to empty a
    /// row, and `normalizeLayout` re-seeds a file that says otherwise.
    public var tabs: [Tab]
    /// Which tab is on screen. Always one of `tabs`.
    public var activeTab: TabID

    /// Everything about the *running* process. `nil` = not running (never persisted).
    public var live: LiveSessionState?

    public init(
        id: SessionID = .generate(),
        groupID: GroupID,
        order: Int = 0,
        title: String? = nil,
        cwd: String,
        repoRoot: String? = nil,
        worktreePath: String? = nil,
        isWorktree: Bool = false,
        agent: AgentKind = .claude,
        accountKey: String,
        conversationId: String? = nil,
        createdAt: Date = Date(),
        lastActiveAt: Date = Date(),
        spendTrackingDisabled: Bool? = nil,
        notificationsMuted: Bool? = nil,
        agentExited: Bool? = nil,
        tabs: [Tab]? = nil,
        activeTab: TabID? = nil,
        live: LiveSessionState? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.order = order
        self.title = title
        self.cwd = cwd
        self.repoRoot = repoRoot
        self.worktreePath = worktreePath
        self.isWorktree = isWorktree
        self.agent = agent
        self.accountKey = accountKey
        self.conversationId = conversationId
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.spendTrackingDisabled = spendTrackingDisabled
        self.notificationsMuted = notificationsMuted
        self.agentExited = agentExited
        // A default argument cannot reference another parameter, so the single-leaf seed is built
        // here. Its terminal and tab ids are the session's own uuid — the same invariant
        // `Migrations.liftV1ToV2` gives every row it lifts, which is what lets `restoreAll` map a
        // `<uuid>.ghsnap` back to its row without a lookup table.
        let seeded = tabs ?? [Tab.single(TerminalID(uuid: id.uuid), tab: TabID(uuid: id.uuid))]
        self.tabs = seeded
        self.activeTab = activeTab ?? seeded[0].id
        self.live = live
    }

    /// `.idle` whenever there is no live state. There is no "exited" status (decision 2026-09-08:
    /// a terminal cannot be exited — when a pane's shell ends the *leaf* goes, and the row goes
    /// with its last leaf; see `AppState.closePane`). A row with no `live` is
    /// one restored from `state.json` that has not been shown yet; it gets its shell on first show.
    public var status: SessionStatus { live?.status ?? .idle }

    /// Amber `NEEDS YOU` badge in the sidebar.
    public var needsAttention: Bool { live?.attention ?? false }

    /// Precedence: user rename → the agent's own `name` (unless the
    /// agent derived it) → worktree name → `basename(cwd)`, where `cwd` is **the agent's own**
    /// once an observation is bound: a shell started in the home group and `cd`'d into a repo
    /// before the agent started should read as that repo, not as the home directory (GUI pass
    /// 2026-09-08, 5a).
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let name = live?.observation?.name, !name.isEmpty, live?.observation?.nameIsDerived != true {
            return name
        }
        return directoryTitle
    }

    /// The title the session would have with no rename and no name from the agent: the worktree
    /// name for a `claude -w` session, else the last segment of `effectiveCwd`. The sidebar shows
    /// it as `…/<name>` under the title whenever `displayTitle` is something else (design 2c.1),
    /// so the folder stays visible once the agent has named the session after the task.
    public var directoryTitle: String {
        if isWorktree, let worktreePath, !worktreePath.isEmpty {
            return Self.title(forPath: worktreePath)
        }
        return Self.title(forPath: effectiveCwd)
    }

    /// Where the session *is*: the agent's own cwd while an observation is bound, else the shell's
    /// last reported cwd (it follows `cd`), else the directory the session was started in.
    public var effectiveCwd: String {
        if let agentCwd = live?.observation?.cwd, !agentCwd.isEmpty { return agentCwd }
        if let shellCwd = live?.shellCwd, !shellCwd.isEmpty { return shellCwd }
        return cwd
    }

    /// Where `terminal`'s shell is standing, for the pane header and for git: its own OSC 7,
    /// or the row's `effectiveCwd` while it has not reported one (a split in its first second).
    ///
    /// **Except in the pane that is running the agent**, where the shell's OSC 7 is stale by
    /// construction: `claude -w <name>` is typed in the main checkout and chdirs into
    /// `.claude/worktrees/<name>` itself, and the shell underneath never `cd`s. That pane
    /// (`live.agentTerminal`, or the row's only pane) answers with the agent's own cwd while a
    /// live observation is bound. Every other pane keeps its shell's answer.
    public func paneDirectory(_ terminal: TerminalID) -> String {
        guard let live else { return effectiveCwd }
        if let agentCwd = live.observation?.cwd, !agentCwd.isEmpty, paneHostsAgent(terminal) {
            return agentCwd
        }
        return live.paneCwds[terminal] ?? effectiveCwd
    }

    /// `terminal` is where the bound agent runs: the pane the shim's `launch` frame was placed
    /// in, or — when the frame could not be placed — the row's only pane, since a *live*
    /// observation means the agent is running in *some* pane of this row. A dead one (a stale
    /// observation from before a crash, matched to a resumed row by its conversation id) is no
    /// such evidence, and its cwd may name a worktree that no longer exists.
    public func paneHostsAgent(_ terminal: TerminalID) -> Bool {
        guard let live, live.observation != nil, live.alive else { return false }
        if let agentTerminal = live.agentTerminal { return agentTerminal == terminal }
        let panes = terminalIDs
        return panes.count == 1 && panes[0] == terminal
    }

    /// The `WT` badge: the session is a `claude -w` session, or it currently sits inside a
    /// `.claude/worktrees/<name>` directory.
    public var showsWorktreeBadge: Bool {
        isWorktree || worktreeRoot(ofPath: effectiveCwd) != nil
    }

    /// The last segment of a path, as a title: `/Users/x/dev/toolbox/` → `toolbox`, `/Users/x` → `x`,
    /// `~` → the home directory's name, `/` → `/`.
    public static func title(forPath path: String) -> String {
        let expanded = path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
        let last = (expanded as NSString).lastPathComponent
        return last.isEmpty ? expanded : last
    }

    /// Where a resume should start, best first: the worktree while it still applies, then the
    /// directory the session was started in, then the repo root. The launcher takes the first one
    /// that exists on disk (M5.2) — a worktree Claude removed on exit falls through to the repo
    /// root, which is the "missing worktree → repoRoot" rule.
    ///
    /// `cwd` outranks `repoRoot` deliberately: for a repo-root or worktree launch the two are the
    /// same directory, and for a session opened elsewhere `cwd` is where Claude actually ran,
    /// which is the project `--resume` looks the conversation up under.
    public var resumeDirectoryCandidates: [String] {
        var out: [String] = []
        if isWorktree, let worktreePath, !worktreePath.isEmpty { out.append(worktreePath) }
        for candidate in [cwd, repoRoot ?? ""] where !candidate.isEmpty && !out.contains(candidate) {
            out.append(candidate)
        }
        return out
    }

    /// The first of `resumeDirectoryCandidates` — what a resume starts in when every directory
    /// still exists.
    public var resumeDirectory: String {
        resumeDirectoryCandidates.first ?? cwd
    }

    // MARK: Layout

    /// The tab on screen. Falls back to the first tab rather than returning nil: `tabs` is never
    /// empty, and every caller would otherwise have to invent the same fallback.
    public var activeTabValue: Tab {
        tabs.first { $0.id == activeTab } ?? tabs[0]
    }

    public var activeTabIndex: Int {
        tabs.firstIndex { $0.id == activeTab } ?? 0
    }

    /// The pane that takes keystrokes.
    public var focusedTerminalID: TerminalID { activeTabValue.focusedLeaf }

    /// Every terminal of every tab, in tab order then reading order. This is the set that owns
    /// `.ghsnap` files, so it is what snapshot housekeeping must keep.
    public var terminalIDs: [TerminalID] { tabs.flatMap(\.terminalIDs) }

    /// The sidebar's pane-count badge shows this when it is > 1.
    public var terminalCount: Int { tabs.reduce(0) { $0 + $1.terminalCount } }

    /// The terminals the active tab puts on screen — one while zoomed, otherwise all of them.
    public var visibleTerminalIDs: [TerminalID] { activeTabValue.visibleTerminalIDs }

    public func tab(containing terminal: TerminalID) -> Tab? {
        tabs.first { $0.root.contains(terminal) }
    }

    /// True when the two sessions lay out identically — same tabs in the same order, same active
    /// tab, focus and zoom, same tree shape, axes, ratios and leaf ids.
    ///
    /// `ChangeSet.diff` uses this to decide the `layout` bucket, so it runs once per changed
    /// session per delivery and must not allocate. That is why it is a structural walk rather than
    /// a comparison of two projections.
    public func hasSameLayoutShape(as other: Session) -> Bool {
        guard activeTab == other.activeTab, tabs.count == other.tabs.count else { return false }
        for (a, b) in zip(tabs, other.tabs) {
            guard a.id == b.id, a.focusedLeaf == b.focusedLeaf, a.zoomedLeaf == b.zoomedLeaf,
                a.root == b.root
            else { return false }
        }
        return true
    }

    /// The worktree a path lies in for *this row's agent*, or `nil`.
    ///
    /// Claude Code creates its worktrees under `<repo>/.claude/worktrees/<name>` and starts the
    /// session with that directory as its cwd, which is what the observation then reports. An
    /// agent with no worktree flag (`AgentKind.worktreeMarker == nil`) never matches — see
    /// `AgentKind`.
    ///
    /// An instance method, not a static one, because both in-module callers (`showsWorktreeBadge`
    /// and `applyObservation`) already hold the session, and TkzCore has no adapter registry to ask.
    public func worktreeRoot(ofPath path: String) -> String? {
        agent.worktreeRoot(ofPath: path)
    }
}

extension Session: Codable {
    /// `live` is deliberately absent: process state is rebuilt at launch, never persisted.
    private enum CodingKeys: String, CodingKey {
        case id, groupID, order, title, cwd, repoRoot, worktreePath, isWorktree
        case agent
        case accountKey, createdAt, lastActiveAt, spendTrackingDisabled
        /// Schema v4 renamed the on-disk key from `claudeSessionId`; `Migrations.liftV3ToV4` is
        /// what moves an existing file's value across, so no alias is needed here any more.
        case conversationId
        case notificationsMuted
        case agentExited
        case tabs, activeTab
    }
}

// MARK: - Live state

/// The volatile half of a session: the process, what the agent says about itself, and what the
/// services (git, ports, sidecar) have most recently learned.
public struct LiveSessionState: Hashable, Sendable {
    /// pid of the agent's own process, once the shim's `launch` frame or an observation has bound
    /// it.
    public var pid: pid_t?
    /// pid of the login shell in the pty (known immediately; the fallback for pid attribution).
    public var shellPid: pid_t?
    /// What the agent's own descriptor file says about itself right now, projected out of that
    /// agent's schema — see `AgentObservation`. `nil` for an agent with no descriptor file, or one
    /// tkzmux has not found yet.
    public var observation: AgentObservation?
    /// Derived by `AgentBridge`/`TkzCore` (M3.4) from the observation + hooks + liveness; the
    /// sidebar's dot.
    public var status: SessionStatus
    /// `true` = the amber `NEEDS YOU` badge. Set for `waiting(.doneUnattended)` and for pending
    /// permission/elicitation prompts; kept separate from `status` because the badge and the dot
    /// have independent lifetimes (a prompt answered elsewhere clears the badge, not the dot).
    public var attention: Bool
    /// Up to 4 KiB of the last `Stop` hook's `last_assistant_message`.
    public var lastStopMessage: String?
    /// Claude's own one-liner from the last permission / elicitation / agent-input `Notification`
    /// hook ("Claude needs your permission to use Bash") — the NEEDS YOU banner's body. Cleared
    /// when the prompt is answered or the row is attended.
    public var lastNotificationMessage: String?
    public var lastStopAt: Date?
    /// The most recent event received for this session, already mapped out of its agent's own
    /// wire vocabulary by that agent's adapter.
    public var lastEvent: AgentEvent?
    public var git: GitSummary?
    /// Listening TCP ports found under the shell pid, ascending.
    public var ports: [UInt16]
    /// Owning process name per port (`proc_name`), for the status bar's badge tooltip. Kept beside
    /// `ports` rather than inside it so `ports` stays the plain, `Codable`-shaped list every other
    /// reader wants; the scanner fills both in one pass.
    public var portOwners: [UInt16: String]
    /// The per-session statusline sidecar (context %, model, PR).
    public var context: SessionSidecar?
    /// Token usage and estimated spend, summed off this session's transcript by
    /// `TranscriptUsageReader`. Process state like `context`: cheap to rebuild (the reader's own
    /// cursor cache survives a relaunch under `~/Library/Application Support/tkzmux/usage/`), so
    /// there is nothing here worth persisting in `state.json` itself.
    public var usage: SessionUsage?
    /// The agent's own process (when an observation is bound) or the shell is running. `false`
    /// only once the pty itself has gone away — see `AppState.setAlive`/`agentLost`.
    public var alive: Bool
    /// `true` once the agent reported an ending that really was one — `sessionEnd(exited: true)`,
    /// which the agent's own adapter decides, since only it knows that agent's reason vocabulary.
    /// Reset by a session-start event or by binding a new observation.
    public var ended: Bool
    /// The most recent unanswered attention signal, if any.
    public var pendingNotification: PendingNotification?
    /// When the user last looked at this session — the other half of the `NEEDS YOU` (60 s) rule.
    public var attendedAt: Date?
    /// `UserPromptSubmit`'s timestamp.
    public var lastPromptAt: Date?
    /// The "done" tint: a `Stop` newer than `attendedAt` that has not yet aged into `NEEDS YOU`.
    public var isDone: Bool
    /// The shell's working directory as it last reported it (OSC 7 from the ZDOTDIR wrapper on
    /// every `cd`). Process state: the title follows it, nothing is persisted (2026-09-08).
    /// This is the *focused* pane's directory; `paneCwds` holds one per pane.
    public var shellCwd: String?
    /// Summed `phys_footprint` of this session's pty child and its descendants, as last sampled.
    ///
    /// The memory tkzmux's *own* metrics cannot see, and which macOS bills to tkzmux anyway because
    /// everything forked from a pty shares the app's process coalition. `nil` until first sampled.
    /// Process state, never persisted. See docs/perf.md → *Session process memory*.
    public var subtreeFootprintBytes: UInt64?
    /// Login-shell pid per pane. `shellPid` is still the focused pane's, because the
    /// status derivation and the row's identity are session-level by design; this map exists so
    /// that the things which walk the process tree — the port scanner and the hook relay's ppid
    /// fallback — can see a shell started in *any* pane, not only the focused one.
    /// Process state, like every other field here: rebuilt as panes are opened.
    public var panePids: [TerminalID: pid_t]
    /// Working directory per pane, from the same OSC 7 the row's `shellCwd` comes from. A split
    /// starts in the source pane's directory by reading this. Not persisted — the 2026-09-08
    /// decision that cwd is process state holds for panes too, so a reopened pane starts in the
    /// row's resume directory.
    public var paneCwds: [TerminalID: String]
    /// The agent launch this row is waiting on, while the boot command is still starting up —
    /// what the pane's "Starting Claude…" overlay reads. Process state, never persisted.
    public var agentStartup: AgentStartup?
    /// The pane whose shell is running the bound agent process, once the shim's `launch`
    /// frame has said which. That pane's OSC 7 is stale by construction: `claude -w` chdirs into
    /// the worktree it created and the shell underneath never follows, so the git strip must
    /// read the agent's own cwd there and the shell's everywhere else (`GitIntegration`). Process
    /// state: cleared when the observation is lost or the pane closes, never persisted.
    public var agentTerminal: TerminalID?
    /// Sub-agents the agent reported starting and has not yet reported stopping, by the agent's
    /// own id for them. While any is here the row is working even when the main turn has ended
    /// (`StatusDerivation` rule 4a) — a Claude that backgrounded three agents is not done.
    /// Process state, never persisted.
    public var runningSubagents: [String: RunningSubagent] = [:]

    public init(
        pid: pid_t? = nil,
        shellPid: pid_t? = nil,
        observation: AgentObservation? = nil,
        status: SessionStatus = .idle,
        attention: Bool = false,
        lastStopMessage: String? = nil,
        lastNotificationMessage: String? = nil,
        lastStopAt: Date? = nil,
        lastEvent: AgentEvent? = nil,
        git: GitSummary? = nil,
        ports: [UInt16] = [],
        portOwners: [UInt16: String] = [:],
        context: SessionSidecar? = nil,
        usage: SessionUsage? = nil,
        alive: Bool = true,
        ended: Bool = false,
        pendingNotification: PendingNotification? = nil,
        attendedAt: Date? = nil,
        lastPromptAt: Date? = nil,
        isDone: Bool = false,
        shellCwd: String? = nil,
        panePids: [TerminalID: pid_t] = [:],
        paneCwds: [TerminalID: String] = [:],
        agentStartup: AgentStartup? = nil,
        agentTerminal: TerminalID? = nil
    ) {
        self.pid = pid
        self.shellPid = shellPid
        self.observation = observation
        self.status = status
        self.attention = attention
        self.lastStopMessage = lastStopMessage
        self.lastNotificationMessage = lastNotificationMessage
        self.lastStopAt = lastStopAt
        self.lastEvent = lastEvent
        self.git = git
        self.ports = ports
        self.portOwners = portOwners
        self.context = context
        self.usage = usage
        self.alive = alive
        self.ended = ended
        self.pendingNotification = pendingNotification
        self.attendedAt = attendedAt
        self.lastPromptAt = lastPromptAt
        self.isDone = isDone
        self.shellCwd = shellCwd
        self.panePids = panePids
        self.paneCwds = paneCwds
        self.agentStartup = agentStartup
        self.agentTerminal = agentTerminal
    }
}

/// One sub-agent still running under a session — see `LiveSessionState.runningSubagents`.
public struct RunningSubagent: Hashable, Sendable {
    public var info: SubagentInfo
    public var startedAt: Date
    /// The newest evidence it is still doing something: its start, or its own transcript being
    /// written to. The stale-entry sweep (`AppState.expireSubagents`) reads this.
    public var lastActivityAt: Date

    public init(info: SubagentInfo, startedAt: Date, lastActivityAt: Date? = nil) {
        self.info = info
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt ?? startedAt
    }
}

/// The agent launch a row is waiting on: the boot command `.zlogin` is running, until the agent is
/// up (an observation binds, or a session-start event arrives) or the command returns to the prompt (the
/// OSC 9;4 *remove* `.zlogin` emits after it). Only launches that carry a boot command record
/// one — a bare shell (⌘T, ⌘D, `.shell`) never does. Drives the pane's "Starting Claude…"
/// overlay; the give-up delay lives at the AppKit edge (`StartupOverlayPolicy`).
public struct AgentStartup: Hashable, Sendable {
    /// The pane the command runs in — the row's first leaf for a new row, the focused pane for a
    /// resume.
    public var terminal: TerminalID
    /// The command as it rides in `TKZMUX_BOOT_COMMAND`, for the overlay's caption.
    public var command: String
    public var startedAt: Date

    public init(terminal: TerminalID, command: String, startedAt: Date) {
        self.terminal = terminal
        self.command = command
        self.startedAt = startedAt
    }
}

/// One outstanding attention signal — what the agent wants, and when it said so.
///
/// Named `kind` rather than `type` since it stopped being a Claude notification type and became
/// `AttentionKind`, which every agent's adapter maps its own vocabulary onto.
public struct PendingNotification: Hashable, Sendable {
    public var kind: AttentionKind
    public var receivedAt: Date

    public init(kind: AttentionKind, receivedAt: Date) {
        self.kind = kind
        self.receivedAt = receivedAt
    }
}

/// The sidebar's status dot. This type only names the outcomes.
public enum SessionStatus: Hashable, Sendable, Codable {
    case working
    case waiting(WaitReason)
    case idle

    public var isWaiting: Bool { if case .waiting = self { return true }; return false }

    /// Stable key for tests, logs and the summary strip.
    public var name: String {
        switch self {
        case .working: "working"
        case .waiting(let reason): "waiting(\(reason.rawValue))"
        case .idle: "idle"
        }
    }
}

/// Why a session is waiting on the human.
public enum WaitReason: String, Hashable, Sendable, Codable, CaseIterable {
    /// A tool-permission prompt is on screen.
    case permission
    /// An elicitation dialog is open.
    case elicitation
    /// The agent is blocked on input that is neither a permission nor a question.
    case agentInput
    /// The agent finished while the session was not attended — either an idle nudge arrived after
    /// the turn ended, or ≥ 60 s passed. `NEEDS YOU`.
    case doneUnattended
}

// MARK: - Accounts & usage

/// One agent account = one config dir (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, …).
public struct Account: Hashable, Sendable, Codable, Identifiable {
    /// Basename of `configDir` (`claude`, `claude-work`, `codex`); also the
    /// `statusline/usage-<key>.json` suffix.
    public var key: String
    public var configDir: String
    /// Display label. Derived from the account's own identity at runtime, never hard-coded.
    public var label: String
    /// True when `label` was written by a human, in `dash-accounts.json`. A configured name is the
    /// last word and nothing may overwrite it; a *derived* one is only the best guess so far, and
    /// has to stay open to correction — the identity behind a config dir changes whenever the user
    /// signs it into a different account. Not persisted: accounts are rediscovered at launch, and
    /// this is a fact about where the current label came from, not about the account.
    public var labelIsConfigured: Bool = false
    /// Plan name reported by the usage file, e.g. from `account.plan`.
    public var plan: String?
    /// Which agent this account belongs to. The key namespace is shared (`claude`, `claude-work`,
    /// `codex`, `codex-work`), so every `accounts[key]` lookup that could straddle agents filters
    /// on this as well — two agents must never inherit each other's config dir.
    public var agent: AgentKind

    public var id: String { key }

    public init(
        key: String, configDir: String, label: String, labelIsConfigured: Bool = false,
        plan: String? = nil, agent: AgentKind = .claude
    ) {
        self.key = key
        self.configDir = configDir
        self.label = label
        self.labelIsConfigured = labelIsConfigured
        self.plan = plan
        self.agent = agent
    }

    /// `labelIsConfigured` is deliberately absent: it describes this run's discovery, so a decoded
    /// account is one whose label nobody has claimed yet.
    private enum CodingKeys: String, CodingKey {
        case key, configDir, label, plan, agent
    }
}

extension Account {
    /// The account as a human would name it: the label, qualified by the key whenever the two
    /// differ.
    ///
    /// The key is not decoration. Two config dirs can carry the same name — `~/.claude` and
    /// `~/.claude-alt` both signed into one team org resolve to the same label, and a stale label
    /// on one of them looks exactly the same — so anywhere several accounts are listed side by
    /// side, the label alone is not enough to tell one row from another.
    public var qualifiedName: String {
        label == key ? key : "\(label) (\(key))"
    }

    /// The account a session falls back to when the group names none: the key of that agent's
    /// primary config dir (`~/.claude` for Claude, `~/.codex` for Codex).
    ///
    /// The key namespace is shared across agents, and an agent's primary key is its own name, so
    /// the mapping is the raw value. An agent nobody has an adapter for still answers, which is
    /// what keeps a row from an unknown-agent `state.json` decodable.
    public static func defaultKey(for agent: AgentKind) -> String { agent.rawValue }

    /// The `CLAUDE_CONFIG_DIR` an account key stands for: `claude-work` → `<home>/.claude-work`,
    /// and the primary `claude` → `<home>/.claude`. `nil` only for a key that is not a config-dir
    /// basename (empty, or containing a `/`).
    ///
    /// The key is the config dir's basename minus its leading dot, so the mapping inverts without a
    /// lookup. This is the fallback for a session
    /// whose account the store does not (yet) know — every restored row after a relaunch, since
    /// accounts are rediscovered rather than persisted — and it is what keeps a resume on the
    /// account the session was started with. **The primary is spelled out too** (M5.2, GUI pass):
    /// a user whose environment points `CLAUDE_CONFIG_DIR` at a second account by default would
    /// otherwise resume a `~/.claude` conversation on the wrong account.
    public static func configDirectory(forKey key: String, home: String) -> String? {
        guard !key.isEmpty, !key.contains("/"), key != ".", key != ".." else { return nil }
        return home.hasSuffix("/") ? "\(home).\(key)" : "\(home)/.\(key)"
    }

    /// The inverse: `/Users/x/.claude-work` → `claude-work`, `/Users/x/.claude` → `claude`.
    public static func key(forConfigDirectory configDir: String) -> String {
        let basename = (configDir as NSString).lastPathComponent
        return basename.hasPrefix(".") ? String(basename.dropFirst()) : basename
    }
}

/// One quota window from `<support>/statusline/usage-<key>.json` (`five_hour` / `seven_day`).
public struct UsageWindow: Hashable, Sendable, Codable {
    /// 0…100.
    public var usedPercentage: Double
    /// ISO-8601 instant the window resets; `nil` when the file has none.
    public var resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date? = nil) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usedPercentage = (try? c.decode(Double.self, forKey: .usedPercentage)) ?? 0
        resetsAt = (try? c.decodeIfPresent(String.self, forKey: .resetsAt))
            .flatMap(ISO8601.date(from:))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(usedPercentage, forKey: .usedPercentage)
        try c.encodeIfPresent(resetsAt.map(ISO8601.string(from:)), forKey: .resetsAt)
    }

    /// `"4d 12h"`, `"38m"` — the status bar's `resets …` text. `nil` when the window has no reset.
    public func resetsInText(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let seconds = max(0, resetsAt.timeIntervalSince(now))
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// The whole `usage-<key>.json` document, keyed in `AppState.usage` by `accountKey`. Written by
/// `tkzmux-hook statusline`, reconciled and published by `StatuslineReader`.
public struct UsageSnapshot: Hashable, Sendable, Codable {
    public var accountKey: String
    public var updatedAt: Date?
    public var label: String?
    public var plan: String?
    public var fiveHour: UsageWindow?
    /// What the status bar shows.
    public var sevenDay: UsageWindow?

    public init(
        accountKey: String,
        updatedAt: Date? = nil,
        label: String? = nil,
        plan: String? = nil,
        fiveHour: UsageWindow? = nil,
        sevenDay: UsageWindow? = nil
    ) {
        self.accountKey = accountKey
        self.updatedAt = updatedAt
        self.label = label
        self.plan = plan
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    private enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case account
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    private struct AccountBlock: Codable {
        var key: String?
        var label: String?
        var plan: String?
        var config_dir: String?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let account = try? c.decodeIfPresent(AccountBlock.self, forKey: .account)
        accountKey = account?.key ?? ""
        label = account?.label
        plan = account?.plan
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt))
            .flatMap(ISO8601.date(from:))
        fiveHour = try? c.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)
        sevenDay = try? c.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(updatedAt.map(ISO8601.string(from:)), forKey: .updatedAt)
        try c.encode(
            AccountBlock(key: accountKey, label: label, plan: plan, config_dir: nil), forKey: .account)
        try c.encodeIfPresent(fiveHour, forKey: .fiveHour)
        try c.encodeIfPresent(sevenDay, forKey: .sevenDay)
    }
}

/// ISO-8601 with fractional seconds, the format the sidecars use. A single shared formatter;
/// `ISO8601DateFormatter` is not `Sendable`, so it is created per call (these parses are rare).
enum ISO8601 {
    static func date(from text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Git

/// What `GitStatusService` (M4.1) learns for one session's directory. Rows re-render only when
/// this value changes, so its `Equatable` conformance is load-bearing.
public struct GitSummary: Hashable, Sendable, Codable {
    /// `HEAD`'s short name, or `nil` in a detached head.
    public var branch: String?
    public var upstream: String?
    /// `branch.ab` from `status --porcelain=v2 --branch`.
    public var ahead: Int
    public var behind: Int
    public var changedFiles: Int
    public var untrackedFiles: Int
    /// `diff HEAD --shortstat`.
    public var insertions: Int
    public var deletions: Int
    /// `realpath(git-dir) != realpath(git-common-dir)`.
    public var isWorktree: Bool
    /// The repo's base branch as `GitStatusService` resolved it — `origin/main` (`origin/HEAD`,
    /// else `origin/main`/`origin/master`), or a bare local `main`/`master` in a repo with no
    /// remote. `nil` = unresolved, which is a *state* (the chip draws nothing), not "not yet".
    public var baseBranch: String?
    /// `rev-list --left-right --count <base>...HEAD`: commits on this branch that the base lacks.
    /// `nil` when the branch *is* the base, HEAD is detached or unborn, or the base is unresolved.
    public var aheadOfBase: Int?
    /// Commits on the base that this branch lacks — what the `⤿ 7 behind main` chip shows. Compared
    /// against the *local* remote-tracking ref, so it is only as fresh as the last fetch.
    public var behindBase: Int?
    public var pr: PRInfo?
    public var updatedAt: Date

    public init(
        branch: String? = nil,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        changedFiles: Int = 0,
        untrackedFiles: Int = 0,
        insertions: Int = 0,
        deletions: Int = 0,
        isWorktree: Bool = false,
        baseBranch: String? = nil,
        aheadOfBase: Int? = nil,
        behindBase: Int? = nil,
        pr: PRInfo? = nil,
        updatedAt: Date = Date()
    ) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changedFiles = changedFiles
        self.untrackedFiles = untrackedFiles
        self.insertions = insertions
        self.deletions = deletions
        self.isWorktree = isWorktree
        self.baseBranch = baseBranch
        self.aheadOfBase = aheadOfBase
        self.behindBase = behindBase
        self.pr = pr
        self.updatedAt = updatedAt
    }

    public var isDirty: Bool { changedFiles > 0 || untrackedFiles > 0 }

    /// A base is known and this branch is not it: the only state in which "rebase onto main"
    /// means anything. `baseBranch` set with both counts `nil` is "on the base" (or detached).
    public var isOffBase: Bool { baseBranch != nil && aheadOfBase != nil && behindBase != nil }
}

/// A pull request, from the statusline sidecar or `gh pr view`.
public struct PRInfo: Hashable, Sendable, Codable {
    public var number: Int
    public var url: String?
    /// `OPEN`, `MERGED`, `CLOSED` as reported.
    public var state: String?
    public var isDraft: Bool
    /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, …
    public var reviewDecision: String?

    public init(
        number: Int,
        url: String? = nil,
        state: String? = nil,
        isDraft: Bool = false,
        reviewDecision: String? = nil
    ) {
        self.number = number
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
    }

    private enum CodingKeys: String, CodingKey {
        case number, url, state, isDraft, reviewDecision
    }

    /// Tolerant like the descriptor: the sidecar's `pr` block is written by another program and
    /// carries only what it knows, so everything but `number` has a default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        isDraft = (try? c.decodeIfPresent(Bool.self, forKey: .isDraft)) ?? false
        reviewDecision = try? c.decodeIfPresent(String.self, forKey: .reviewDecision)
    }
}

// MARK: - Statusline sidecar

/// `<support>/statusline/context-<session_id>.json`, the tkzmux-owned statusline contract
/// written by `tkzmux-hook statusline`. snake_case on the wire.
public struct SessionSidecar: Hashable, Sendable, Codable {
    public struct Model: Hashable, Sendable, Codable {
        public var id: String?
        public var displayName: String?
        public init(id: String? = nil, displayName: String? = nil) {
            self.id = id
            self.displayName = displayName
        }
        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    public struct Workspace: Hashable, Sendable, Codable {
        public var gitWorktree: String?
        public var projectDir: String?
        public var repo: String?
        public init(gitWorktree: String? = nil, projectDir: String? = nil, repo: String? = nil) {
            self.gitWorktree = gitWorktree
            self.projectDir = projectDir
            self.repo = repo
        }
        private enum CodingKeys: String, CodingKey {
            case gitWorktree = "git_worktree"
            case projectDir = "project_dir"
            case repo
        }
    }

    public var updatedAt: Date?
    public var sessionId: String
    public var accountKey: String?
    /// 0…100, the status bar's `Context 62%`.
    public var contextUsedPercentage: Double?
    public var model: Model?
    public var sessionName: String?
    public var workspace: Workspace?
    public var worktree: String?
    public var pr: PRInfo?
    public var cost: Double?

    public init(
        updatedAt: Date? = nil,
        sessionId: String,
        accountKey: String? = nil,
        contextUsedPercentage: Double? = nil,
        model: Model? = nil,
        sessionName: String? = nil,
        workspace: Workspace? = nil,
        worktree: String? = nil,
        pr: PRInfo? = nil,
        cost: Double? = nil
    ) {
        self.updatedAt = updatedAt
        self.sessionId = sessionId
        self.accountKey = accountKey
        self.contextUsedPercentage = contextUsedPercentage
        self.model = model
        self.sessionName = sessionName
        self.workspace = workspace
        self.worktree = worktree
        self.pr = pr
        self.cost = cost
    }

    private enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case sessionId = "session_id"
        case accountKey = "account_key"
        case contextUsedPercentage = "context_used_percentage"
        case model
        case sessionName = "session_name"
        case workspace, worktree, pr, cost
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let sessionId = try? c.decode(String.self, forKey: .sessionId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.sessionId,
                .init(codingPath: c.codingPath, debugDescription: "sidecar has no 'session_id'"))
        }
        self.sessionId = sessionId
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt))
            .flatMap(ISO8601.date(from:))
        accountKey = try? c.decodeIfPresent(String.self, forKey: .accountKey)
        contextUsedPercentage = try? c.decodeIfPresent(Double.self, forKey: .contextUsedPercentage)
        model = try? c.decodeIfPresent(Model.self, forKey: .model)
        sessionName = try? c.decodeIfPresent(String.self, forKey: .sessionName)
        workspace = try? c.decodeIfPresent(Workspace.self, forKey: .workspace)
        worktree = try? c.decodeIfPresent(String.self, forKey: .worktree)
        pr = try? c.decodeIfPresent(PRInfo.self, forKey: .pr)
        cost = try? c.decodeIfPresent(Double.self, forKey: .cost)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(updatedAt.map(ISO8601.string(from:)), forKey: .updatedAt)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(accountKey, forKey: .accountKey)
        try c.encodeIfPresent(contextUsedPercentage, forKey: .contextUsedPercentage)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(sessionName, forKey: .sessionName)
        try c.encodeIfPresent(workspace, forKey: .workspace)
        try c.encodeIfPresent(worktree, forKey: .worktree)
        try c.encodeIfPresent(pr, forKey: .pr)
        try c.encodeIfPresent(cost, forKey: .cost)
    }
}

// MARK: - Token usage / spend

/// One model's token totals for a session, summed out of its transcript by `TranscriptUsageReader`
/// (AgentBridge), and their estimated cost from ``ModelPricing``. `costUSD` is `nil` when
/// `modelId` has no pricing entry — tokens are still shown, just with no `$` figure.
public struct ModelUsage: Hashable, Sendable, Codable {
    public var modelId: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    /// Already counted within `outputTokens` (Anthropic bills thinking as output) — kept separately
    /// only so the breakdown can say how much of the output was thinking.
    public var thinkingTokens: Int
    public var costUSD: Double?

    public init(
        modelId: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        thinkingTokens: Int = 0,
        costUSD: Double? = nil
    ) {
        self.modelId = modelId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.thinkingTokens = thinkingTokens
        self.costUSD = costUSD
    }
}

/// A session's token usage and estimated spend, summed across every model it used. Published by
/// `TranscriptUsageReader` off the session's own `~/.claude` transcript — the only place Claude
/// Code records per-turn token counts — and joined onto `Session.live.usage` the same way the
/// statusline sidecar joins onto `Session.live.context`.
public struct SessionUsage: Hashable, Sendable, Codable {
    public var perModel: [ModelUsage]
    /// `nil` when not one of `perModel`'s models has a pricing entry — the status bar shows the
    /// token counts alone rather than a `$0` that would claim nothing was spent.
    public var totalCostUSD: Double?
    public var lastUpdatedAt: Date

    public init(perModel: [ModelUsage], totalCostUSD: Double?, lastUpdatedAt: Date) {
        self.perModel = perModel
        self.totalCostUSD = totalCostUSD
        self.lastUpdatedAt = lastUpdatedAt
    }
}
