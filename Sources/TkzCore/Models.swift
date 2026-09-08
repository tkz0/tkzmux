// TkzCore — the app's domain model. See docs/design.md → *App architecture → Store*,
// *Claude integration*, *Git integration* and *Session flows & persistence*.
//
// Everything in this file is a value type: `Hashable`, `Sendable`, and (where it is persisted)
// `Codable`. No AppKit, no SwiftUI — TkzCore is the half of the app that can be tested headless,
// and `TkzCoreTests.noUIFrameworksInTkzCore` enforces that mechanically.
//
// Persistence note (M5 / `state.json` v1): the *durable* fields are the stored properties of
// `Group`, `Session` (minus `live`), `Preset` and the selection/window fields of `AppState`.
// Everything that describes a running process — `LiveSessionState` and everything it holds —
// is rebuilt at launch, never written to disk, hence `Session.live` is excluded from `Codable`.

import CoreGraphics
import Foundation

// MARK: - Identifiers

/// Shared behaviour for the UUID-backed identifiers below.
///
/// The string form is `UUID.uuidString` (uppercase, hyphenated). That matters beyond aesthetics:
/// a session id is also used as a **file basename** (`<id>.ghsnap`, `sessions/<id>.json`) and as the
/// value of the **`TKZMUX_SESSION_ID`** environment variable handed to the shim, so it must never
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
    /// The 2–3 pt colour edge on the group header. `nil` = `Theme.groupEdgeDefault`.
    public var color: RGB?
    public var isCollapsed: Bool
    /// Sort key among groups. Contiguous from 0 after `AppState.normalizeGroupOrder()`.
    public var order: Int
    /// Which account new sessions in this group default to (`Account.key`).
    public var defaultAccountKey: String?

    public init(
        id: GroupID = .generate(),
        name: String,
        repoRoot: String? = nil,
        color: RGB? = nil,
        isCollapsed: Bool = false,
        order: Int = 0,
        defaultAccountKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.repoRoot = repoRoot
        self.color = color
        self.isCollapsed = isCollapsed
        self.order = order
        self.defaultAccountKey = defaultAccountKey
    }
}

// MARK: - Session

/// One terminal session — a row in the sidebar and, when selected, the terminal surface.
///
/// The stored properties are durable; `live` is not (see the file header). A restored session
/// therefore has `live == nil`, which makes `status` report `.exited` — exactly the "rows come back
/// exited and resumable" behaviour in design.md → *Session flows & persistence*.
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
    /// `Account.key` — the basename of the Claude config dir (`claude`, `claude-alt`).
    public var accountKey: String
    /// The most recent Claude `sessionId`, used for `claude --resume <id>`. Rotates on
    /// `/clear`, resume and fork, so it is updated whenever a descriptor or SessionStart says so.
    public var claudeSessionId: String?
    /// The preset this session was created from, if any.
    public var presetID: UUID?
    public var createdAt: Date
    public var lastActiveAt: Date

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
        accountKey: String,
        claudeSessionId: String? = nil,
        presetID: UUID? = nil,
        createdAt: Date = Date(),
        lastActiveAt: Date = Date(),
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
        self.accountKey = accountKey
        self.claudeSessionId = claudeSessionId
        self.presetID = presetID
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.live = live
    }

    /// `.exited` whenever there is no live state — see the type's doc comment.
    public var status: SessionStatus { live?.status ?? .exited }

    /// Amber `NEEDS YOU` badge in the sidebar.
    public var needsAttention: Bool { live?.attention ?? false }

    /// design.md → *Claude integration → Titles*: user rename → descriptor `name` (unless the
    /// descriptor derived it) → worktree name → `basename(cwd)`, where `cwd` is **Claude's own**
    /// once a descriptor is bound: a shell started in the home group and `cd`'d into a repo before
    /// `claude` should read as that repo, not as the home directory (GUI pass 2026-09-08, 5a).
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let name = live?.descriptor?.name, !name.isEmpty, live?.descriptor?.nameSource != .derived {
            return name
        }
        if let worktreePath, !worktreePath.isEmpty {
            return (worktreePath as NSString).lastPathComponent
        }
        if let claudeCwd = live?.descriptor?.cwd, !claudeCwd.isEmpty {
            return (claudeCwd as NSString).lastPathComponent
        }
        return (cwd as NSString).lastPathComponent
    }

    /// The directory a resume should start in: the worktree if it still applies, else the repo root.
    public var resumeDirectory: String {
        if isWorktree, let worktreePath { return worktreePath }
        return repoRoot ?? cwd
    }
}

extension Session: Codable {
    /// `live` is deliberately absent: process state is rebuilt at launch, never persisted.
    private enum CodingKeys: String, CodingKey {
        case id, groupID, order, title, cwd, repoRoot, worktreePath, isWorktree
        case accountKey, claudeSessionId, presetID, createdAt, lastActiveAt
    }
}

// MARK: - Live state

/// The volatile half of a session: the process, what Claude says about it, and what the
/// services (git, ports, sidecar) have most recently learned.
public struct LiveSessionState: Hashable, Sendable {
    /// pid of the `claude` process, once the shim's `launch` frame or a descriptor has bound it.
    public var pid: pid_t?
    /// pid of the login shell in the pty (known immediately; the fallback for pid attribution).
    public var shellPid: pid_t?
    /// The parsed `~/.claude*/sessions/<pid>.json` descriptor, when one exists.
    public var descriptor: ClaudeSessionInfo?
    /// Derived by `ClaudeBridge` (M3.4) from descriptor + hooks + liveness; the sidebar's dot.
    public var status: SessionStatus
    /// `true` = the amber `NEEDS YOU` badge. Set for `waiting(.doneUnattended)` and for pending
    /// permission/elicitation prompts; kept separate from `status` because the badge and the dot
    /// have independent lifetimes (a prompt answered elsewhere clears the badge, not the dot).
    public var attention: Bool
    /// Up to 4 KiB of the last `Stop` hook's `last_assistant_message`.
    public var lastStopMessage: String?
    public var lastStopAt: Date?
    /// The most recent hook frame received for this session.
    public var lastHook: HookEvent?
    public var git: GitSummary?
    /// Listening TCP ports found under the shell pid, ascending.
    public var ports: [UInt16]
    /// The per-session statusline sidecar (context %, model, PR).
    public var context: SessionSidecar?
    /// The `claude` process (when a descriptor is bound) or the shell is running. `false` only once
    /// the pty itself has gone away — see `AppState.setAlive`/`descriptorLost`.
    public var alive: Bool
    /// `true` once a `SessionEnd` with a reason other than `clear`/`resume` has been seen; reset by
    /// `SessionStart` or by binding a new descriptor. design.md → *Claude integration → Status
    /// derivation*.
    public var ended: Bool
    /// The most recent unanswered `Notification` hook, if any.
    public var pendingNotification: PendingNotification?
    /// When the user last looked at this session — the other half of the `NEEDS YOU` (60 s) rule.
    public var attendedAt: Date?
    /// `UserPromptSubmit`'s timestamp.
    public var lastPromptAt: Date?
    /// The "done" tint: a `Stop` newer than `attendedAt` that has not yet aged into `NEEDS YOU`.
    public var isDone: Bool

    public init(
        pid: pid_t? = nil,
        shellPid: pid_t? = nil,
        descriptor: ClaudeSessionInfo? = nil,
        status: SessionStatus = .idle,
        attention: Bool = false,
        lastStopMessage: String? = nil,
        lastStopAt: Date? = nil,
        lastHook: HookEvent? = nil,
        git: GitSummary? = nil,
        ports: [UInt16] = [],
        context: SessionSidecar? = nil,
        alive: Bool = true,
        ended: Bool = false,
        pendingNotification: PendingNotification? = nil,
        attendedAt: Date? = nil,
        lastPromptAt: Date? = nil,
        isDone: Bool = false
    ) {
        self.pid = pid
        self.shellPid = shellPid
        self.descriptor = descriptor
        self.status = status
        self.attention = attention
        self.lastStopMessage = lastStopMessage
        self.lastStopAt = lastStopAt
        self.lastHook = lastHook
        self.git = git
        self.ports = ports
        self.context = context
        self.alive = alive
        self.ended = ended
        self.pendingNotification = pendingNotification
        self.attendedAt = attendedAt
        self.lastPromptAt = lastPromptAt
        self.isDone = isDone
    }
}

/// One outstanding `Notification` hook — the kind and when it was received. design.md → *Claude
/// integration → Status derivation*.
public struct PendingNotification: Hashable, Sendable {
    public var type: HookEvent.NotificationType
    public var receivedAt: Date

    public init(type: HookEvent.NotificationType, receivedAt: Date) {
        self.type = type
        self.receivedAt = receivedAt
    }
}

/// The sidebar's status dot. Derivation rules live in design.md → *Claude integration →
/// Status derivation*; this type only names the outcomes.
public enum SessionStatus: Hashable, Sendable, Codable {
    case working
    case waiting(WaitReason)
    case idle
    case exited

    public var isWaiting: Bool { if case .waiting = self { return true }; return false }

    /// Stable key for tests, logs and the summary strip.
    public var name: String {
        switch self {
        case .working: "working"
        case .waiting(let reason): "waiting(\(reason.rawValue))"
        case .idle: "idle"
        case .exited: "exited"
        }
    }
}

/// Why a session is waiting on the human.
public enum WaitReason: String, Hashable, Sendable, Codable, CaseIterable {
    /// A tool-permission prompt is on screen.
    case permission
    /// An elicitation dialog is open.
    case elicitation
    /// `Notification.notification_type == agent_needs_input`.
    case agentInput
    /// Claude stopped while the session was not attended (idle_prompt, or ≥ 60 s) — `NEEDS YOU`.
    case doneUnattended
}

// MARK: - Claude descriptor

/// A parsed `~/.claude/sessions/<pid>.json` (or `~/.claude-alt/…`) descriptor.
///
/// Shape from design.md → *Evidence*. **Another program writes this file in place**, so a read can
/// land mid-write: decoding is deliberately forgiving. Only `pid` and `sessionId` are required;
/// every other field is optional, unknown keys are ignored, and unknown enum values fall back to
/// `.unknown(raw)` rather than throwing the whole descriptor away. A *torn* file (truncated JSON)
/// still throws a `DecodingError` — there is nothing to salvage — and the watcher's contract is to
/// keep the previous value in that case.
///
/// `configDir` is **not** in the JSON: it is the directory the file was found in, which is what
/// tells us which account the session belongs to. Inject it with `decode(_:configDir:)`, or set
/// `decoder.userInfo[ClaudeSessionInfo.configDirUserInfoKey]`.
public struct ClaudeSessionInfo: Hashable, Sendable, Decodable {
    public enum Kind: Hashable, Sendable {
        case interactive
        case background
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "interactive": self = .interactive
            case "bg", "background": self = .background
            default: self = .unknown(raw)
            }
        }
    }

    public enum NameSource: Hashable, Sendable {
        case auto
        case derived
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "auto": self = .auto
            case "derived": self = .derived
            default: self = .unknown(raw)
            }
        }
    }

    public enum Status: Hashable, Sendable {
        case idle
        case busy
        /// Claude Code 2.1.263 writes `"waiting"` while a permission prompt is on screen
        /// (measured 2026-09-08: idle → busy on submit → waiting at the prompt → busy the moment
        /// it is answered → idle at Stop). It is the hook-free way to see NEEDS YOU.
        case waiting
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "idle": self = .idle
            case "busy": self = .busy
            case "waiting": self = .waiting
            default: self = .unknown(raw)
            }
        }
    }

    /// The directory the descriptor was found in (`~/.claude`, `~/.claude-alt`) — the account key
    /// is its basename. Injected, never decoded.
    public var configDir: String
    public var pid: pid_t
    public var sessionId: String
    public var cwd: String?
    /// Decoded from epoch **milliseconds**; also the pid-reuse guard against `pbi_start_tvsec`.
    public var startedAt: Date?
    public var version: String?
    public var kind: Kind?
    public var entrypoint: String?
    public var name: String?
    public var nameSource: NameSource?
    public var status: Status?
    public var updatedAt: Date?
    public var statusUpdatedAt: Date?
    public var messagingSocketPath: String?
    public var bridgeSessionId: String?
    public var parkedJobId: String?
    public var jobId: String?

    /// The account key: the basename of the config dir **minus its leading dot**, so
    /// `~/.claude` → `"claude"` and `~/.claude-alt` → `"claude-alt"`. That is the spelling
    /// `Account.key`, `Session.accountKey` and the `dash-usage-<key>.json` filenames all use, and
    /// the join key for `descriptor.accountKey == session.accountKey` in M3.
    public var accountKey: String {
        let basename = (configDir as NSString).lastPathComponent
        return basename.hasPrefix(".") ? String(basename.dropFirst()) : basename
    }

    /// A background descriptor parked under this job id belongs to the interactive session whose
    /// `jobId` matches — design.md → *Claude integration → Discovery*.
    public var isBackground: Bool { kind == .background }

    public init(
        configDir: String,
        pid: pid_t,
        sessionId: String,
        cwd: String? = nil,
        startedAt: Date? = nil,
        version: String? = nil,
        kind: Kind? = nil,
        entrypoint: String? = nil,
        name: String? = nil,
        nameSource: NameSource? = nil,
        status: Status? = nil,
        updatedAt: Date? = nil,
        statusUpdatedAt: Date? = nil,
        messagingSocketPath: String? = nil,
        bridgeSessionId: String? = nil,
        parkedJobId: String? = nil,
        jobId: String? = nil
    ) {
        self.configDir = configDir
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.version = version
        self.kind = kind
        self.entrypoint = entrypoint
        self.name = name
        self.nameSource = nameSource
        self.status = status
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.messagingSocketPath = messagingSocketPath
        self.bridgeSessionId = bridgeSessionId
        self.parkedJobId = parkedJobId
        self.jobId = jobId
    }

    /// `decoder.userInfo` key carrying the config dir (a `String`) into `init(from:)`.
    public static let configDirUserInfoKey = CodingUserInfoKey(rawValue: "se.tkz.tkzmux.configDir")!

    /// The supported way to parse a descriptor file.
    /// - Throws: `DecodingError` when the bytes are not a JSON object with `pid` and `sessionId`
    ///   (a torn write); the caller keeps the previous value.
    public static func decode(_ data: Data, configDir: String) throws -> ClaudeSessionInfo {
        let decoder = JSONDecoder()
        decoder.userInfo[configDirUserInfoKey] = configDir
        return try decoder.decode(ClaudeSessionInfo.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, startedAt, version, kind, entrypoint, name, nameSource
        case status, updatedAt, statusUpdatedAt, messagingSocketPath, bridgeSessionId
        case parkedJobId, jobId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configDir = decoder.userInfo[Self.configDirUserInfoKey] as? String ?? ""
        // Required: without these two the descriptor identifies nothing.
        guard let pid = Self.int(c, .pid).map({ pid_t($0) }) else {
            throw DecodingError.keyNotFound(
                CodingKeys.pid,
                .init(codingPath: c.codingPath, debugDescription: "descriptor has no usable 'pid'"))
        }
        guard let sessionId = try? c.decode(String.self, forKey: .sessionId), !sessionId.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.sessionId,
                .init(codingPath: c.codingPath, debugDescription: "descriptor has no 'sessionId'"))
        }
        self.pid = pid
        self.sessionId = sessionId
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        startedAt = Self.date(c, .startedAt)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).map(Kind.init(raw:))
        entrypoint = try? c.decodeIfPresent(String.self, forKey: .entrypoint)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        nameSource = (try? c.decodeIfPresent(String.self, forKey: .nameSource))
            .map(NameSource.init(raw:))
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).map(Status.init(raw:))
        updatedAt = Self.date(c, .updatedAt)
        statusUpdatedAt = Self.date(c, .statusUpdatedAt)
        messagingSocketPath = try? c.decodeIfPresent(String.self, forKey: .messagingSocketPath)
        bridgeSessionId = try? c.decodeIfPresent(String.self, forKey: .bridgeSessionId)
        parkedJobId = try? c.decodeIfPresent(String.self, forKey: .parkedJobId)
        jobId = try? c.decodeIfPresent(String.self, forKey: .jobId)
    }

    /// Number or numeric string — Claude Code has shipped both shapes for ids.
    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let text = try? c.decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }

    /// Epoch **milliseconds** → `Date`; tolerant of a numeric string.
    private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        var millis: Double?
        if let value = try? c.decodeIfPresent(Double.self, forKey: key) { millis = value }
        else if let text = try? c.decodeIfPresent(String.self, forKey: key) { millis = Double(text) }
        guard let millis, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}

// MARK: - Accounts & usage

/// One Claude account = one `CLAUDE_CONFIG_DIR`.
public struct Account: Hashable, Sendable, Codable, Identifiable {
    /// Basename of `configDir` (`claude`, `claude-alt`); also the `dash-usage-<key>.json` suffix.
    public var key: String
    public var configDir: String
    /// Display label. Comes from config (`dash-accounts.json` overlay), never hard-coded.
    public var label: String
    /// Plan name reported by the usage file, e.g. from `account.plan`.
    public var plan: String?

    public var id: String { key }

    public init(key: String, configDir: String, label: String, plan: String? = nil) {
        self.key = key
        self.configDir = configDir
        self.label = label
        self.plan = plan
    }
}

extension Account {
    /// The account a session falls back to when neither the group nor the preset names one:
    /// the key of the default `~/.claude` config dir.
    public static let defaultKey = "claude"
}

/// One quota window from `~/.claude/dash-usage-<key>.json` (`five_hour` / `seven_day`).
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

/// The whole `dash-usage-<key>.json` document, keyed in `AppState.usage` by `accountKey`.
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

/// ISO-8601 with fractional seconds, the format the dash files use. A single shared formatter;
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
        self.pr = pr
        self.updatedAt = updatedAt
    }

    public var isDirty: Bool { changedFiles > 0 || untrackedFiles > 0 }
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

/// `~/.claude/dash-sessions/<session_id>.json`, the tkzmux-owned statusline contract in
/// design.md → *Claude integration → Per-session sidecar*. snake_case on the wire.
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

// MARK: - Hooks

/// One hook frame relayed by `tkzmux-hook` (M3.2). Typed rather than `[String: Any]`, both because
/// `Any` cannot be `Sendable` and because only these fields drive status derivation.
public struct HookEvent: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case sessionStart
        case sessionEnd
        case userPromptSubmit
        case stop
        case notification
        case unknown(String)

        /// Maps the hook names injected by the shim (`SessionStart`, `Stop`, …).
        public init(raw: String) {
            switch raw {
            case "SessionStart": self = .sessionStart
            case "SessionEnd": self = .sessionEnd
            case "UserPromptSubmit": self = .userPromptSubmit
            case "Stop": self = .stop
            case "Notification": self = .notification
            default: self = .unknown(raw)
            }
        }
    }

    /// `Notification.notification_type`. Matcher list in design.md → *Shim*.
    public enum NotificationType: Hashable, Sendable, Codable {
        case permissionPrompt
        case idlePrompt
        case elicitationDialog
        case elicitationComplete
        case agentNeedsInput
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "permission_prompt": self = .permissionPrompt
            case "idle_prompt": self = .idlePrompt
            case "elicitation_dialog", "elicitation_url_dialog": self = .elicitationDialog
            case "elicitation_complete", "elicitation_response": self = .elicitationComplete
            case "agent_needs_input": self = .agentNeedsInput
            default: self = .unknown(raw)
            }
        }
    }

    public var kind: Kind
    /// `TKZMUX_SESSION_ID` as sent by the shim, when it parsed.
    public var sessionID: SessionID?
    /// Claude's own `session_id` from the hook payload.
    public var claudeSessionId: String?
    public var notificationType: NotificationType?
    /// Up to 4 KiB of `Stop.last_assistant_message`.
    public var lastAssistantMessage: String?
    /// `SessionStart.source`.
    public var source: String?
    /// `SessionEnd.reason` — `clear` and `resume` do **not** mean the session exited.
    public var reason: String?
    public var pid: pid_t?
    public var receivedAt: Date

    public init(
        kind: Kind,
        sessionID: SessionID? = nil,
        claudeSessionId: String? = nil,
        notificationType: NotificationType? = nil,
        lastAssistantMessage: String? = nil,
        source: String? = nil,
        reason: String? = nil,
        pid: pid_t? = nil,
        receivedAt: Date = Date()
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.claudeSessionId = claudeSessionId
        self.notificationType = notificationType
        self.lastAssistantMessage = lastAssistantMessage
        self.source = source
        self.reason = reason
        self.pid = pid
        self.receivedAt = receivedAt
    }
}

// MARK: - Presets

/// A saved way to start a session — the "From preset…" entries in the new-session menu.
public struct Preset: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// The command line run in the pty, e.g. `claude -w` or `claude --resume`.
    public var command: String
    public var cwdMode: CwdMode
    /// `nil` = the group's `defaultAccountKey`.
    public var accountKey: String?
    /// Extra environment for the child, merged over `TerminalEnvironment`'s.
    public var env: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        cwdMode: CwdMode = .repoRoot,
        accountKey: String? = nil,
        env: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.cwdMode = cwdMode
        self.accountKey = accountKey
        self.env = env
    }
}

/// Where a preset starts. `claude -w` must run from the main checkout, hence `worktree` still
/// resolves its cwd to the repo root — the *name* is what it passes to `-w`.
public enum CwdMode: Hashable, Sendable {
    case repoRoot
    case worktree(name: String?)
    case fixed(path: String)

    /// The directory to launch in, given the group's repo root.
    public func directory(repoRoot: String?, fallback: String) -> String {
        switch self {
        case .repoRoot, .worktree: repoRoot ?? fallback
        case .fixed(let path): path
        }
    }
}

/// Hand-written rather than synthesized: this lands in `state.json` (M5.1), and the compiler's
/// enum-with-payload wire form is an implementation detail of the Swift version that built the app,
/// not a contract. The shape below is the contract — `{"mode": "worktree", "name": "review"}`.
extension CwdMode: Codable {
    private enum CodingKeys: String, CodingKey { case mode, name, path }
    private enum Mode: String, Codable { case repoRoot, worktree, fixed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Mode.self, forKey: .mode) {
        case .repoRoot: self = .repoRoot
        case .worktree: self = .worktree(name: try c.decodeIfPresent(String.self, forKey: .name))
        case .fixed: self = .fixed(path: try c.decode(String.self, forKey: .path))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .repoRoot:
            try c.encode(Mode.repoRoot, forKey: .mode)
        case .worktree(let name):
            try c.encode(Mode.worktree, forKey: .mode)
            try c.encodeIfPresent(name, forKey: .name)
        case .fixed(let path):
            try c.encode(Mode.fixed, forKey: .mode)
            try c.encode(path, forKey: .path)
        }
    }
}
