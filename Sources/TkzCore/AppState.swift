// TkzCore — the single value that describes the whole app. `AppStore` owns one of these, services
// post mutations into it, views read it.
//
// Groups and sessions are stored in dictionaries keyed by id, not arrays. Two reasons:
//   * the diff in `AppStore` is then O(n) by key and cannot confuse "moved" with "changed";
//   * every view addresses rows by id anyway (`NSOutlineView` items are ids).
// Display order comes from the `order` field via the ordered accessors below.

import CoreGraphics
import Foundation

public struct AppState: Hashable, Sendable {
    public var groups: [GroupID: Group]
    public var sessions: [SessionID: Session]
    /// Keyed by `Account.key` (`claude`, `claude-work`).
    public var accounts: [String: Account]
    /// Keyed by `Account.key`; what `UsageReader` (M3.5) publishes.
    public var usage: [String: UsageSnapshot]
    /// The selected session, i.e. the one attached to the terminal surface.
    public var selection: SessionID?
    public var sidebarVisible: Bool
    /// The sidebar's width in points, as the user last left it; `nil` = the built-in default.
    /// Recorded from a divider drag, restored onto the sidebar's width constraint.
    public var sidebarWidth: CGFloat?
    /// Restored on launch; `nil` = let AppKit place the window.
    public var windowFrame: CGRect?
    /// Command id → key-equivalent string (e.g. `"newSession": "cmd+t"`). Persisted verbatim;
    /// M2.4 owns the vocabulary.
    public var shortcuts: [String: String]
    /// The "auto-resume on launch" preference (M5.2): every restored row with a
    /// `conversationId` whose agent was still running at quit (`Session.agentExited` unset) gets
    /// `claude --resume` typed into a fresh shell when the app starts.
    public var autoResumeOnLaunch: Bool
    /// Whether the statusline consent sheet has already been put to the user. Asked once
    /// and never again: declining is an answer, and re-asking every launch would be nagging. The
    /// menu command stays available either way.
    public var statuslineOffered: Bool
    /// Which agents the user has already been asked about installing hooks for — accepted or
    /// declined, the question is not re-asked either way.
    ///
    /// **A set, not a flag.** It was one global `Bool` while exactly one agent needed hooks
    /// installed with consent. A second such agent makes that actively wrong: a user who declined
    /// for the first would never be asked for the second, so a feature would be silently suppressed
    /// for an agent that was never mentioned.
    public var hooksOffered: Set<AgentKind>
    /// The release the user closed the sidebar's update card for. That version never
    /// shows the card again; a newer one does. Durable, in `PersistedPreferences`.
    public var dismissedUpdateVersion: String?
    /// The token usage/spend feature's global on/off switch (design: token usage and spend per
    /// session — enable/disable). A session can also opt out on its own via
    /// `Session.spendTrackingDisabled`; that per-session flag is checked in addition to this one,
    /// never instead of it. Durable, in `PersistedPreferences`.
    public var showSessionSpend: Bool
    /// Fetch every tracked repo's base branch from its remote every few minutes, so the status
    /// bar's `⤿ 7 behind main` chip reflects what is on GitHub rather than what the last manual fetch
    /// brought in (2026-09-13). **Off by default**: it is the one background network activity
    /// besides the release check, and it runs under the user's own git credentials.
    /// Durable, in `PersistedPreferences`.
    public var checkOriginPeriodically: Bool
    /// Post a macOS user notification when Claude finishes a turn in a session the user is not
    /// looking at, i.e. when the row gets its "done" tint (2026-09-15). On by default. The NEEDS
    /// YOU banner has no switch of its own: it is the reason notifications exist, and macOS's
    /// per-app setting is the master switch for both. Durable, in `PersistedPreferences`.
    /// `AttentionNotifier` (TkzApp) is its sole reader.
    public var notifyOnDone: Bool
    /// Show on the Dock icon how many rows need the user — `summaryCounts.needsYou`, the summary
    /// strip's own figure (2026-09-22, TKZ-67). On by default. Durable, in `PersistedPreferences`.
    /// `DockBadge` (TkzApp) is its sole reader.
    public var badgeDockIcon: Bool
    /// The active colour scheme. The ☾/☀ toggle in the toolbar writes it; `MainWindowController` is
    /// its sole observer, via `ChangeSet.theme`. Durable, in `PersistedPreferences`.
    public var themePreset: Theme.Preset
    /// The release check's answer and the in-app upgrade's progress. Process state, never
    /// persisted — see `UpdateState`.
    public var update: UpdateState
    /// The activity feed's event log (⌘I), oldest first, at most `activityCap` entries. Appended
    /// by `applyEvent`/`rederiveStatus`, read flags cleared by `markAttended`. Durable, its own
    /// top-level key in `state.json`; `ChangeSet.activity` is its bucket.
    public var activity: [ActivityEvent]

    /// How many feed entries are kept; the oldest go first.
    public static let activityCap = 200

    public init(
        groups: [GroupID: Group] = [:],
        sessions: [SessionID: Session] = [:],
        accounts: [String: Account] = [:],
        usage: [String: UsageSnapshot] = [:],
        selection: SessionID? = nil,
        sidebarVisible: Bool = true,
        sidebarWidth: CGFloat? = nil,
        windowFrame: CGRect? = nil,
        shortcuts: [String: String] = [:],
        autoResumeOnLaunch: Bool = false,
        statuslineOffered: Bool = false,
        hooksOffered: Set<AgentKind> = [],
        dismissedUpdateVersion: String? = nil,
        showSessionSpend: Bool = true,
        checkOriginPeriodically: Bool = false,
        notifyOnDone: Bool = true,
        badgeDockIcon: Bool = true,
        themePreset: Theme.Preset = Theme.default.preset,
        update: UpdateState = UpdateState(),
        activity: [ActivityEvent] = []
    ) {
        self.groups = groups
        self.sessions = sessions
        self.accounts = accounts
        self.usage = usage
        self.selection = selection
        self.sidebarVisible = sidebarVisible
        self.sidebarWidth = sidebarWidth
        self.windowFrame = windowFrame
        self.shortcuts = shortcuts
        self.autoResumeOnLaunch = autoResumeOnLaunch
        self.statuslineOffered = statuslineOffered
        self.hooksOffered = hooksOffered
        self.dismissedUpdateVersion = dismissedUpdateVersion
        self.showSessionSpend = showSessionSpend
        self.checkOriginPeriodically = checkOriginPeriodically
        self.notifyOnDone = notifyOnDone
        self.badgeDockIcon = badgeDockIcon
        self.themePreset = themePreset
        self.update = update
        self.activity = activity
    }

    // MARK: Update card

    /// The release the sidebar's card should show: the newest known release, unless the user has
    /// dismissed exactly that version. `nil` hides the card.
    public var visibleUpdate: AvailableUpdate? {
        guard let available = update.available, available.version != dismissedUpdateVersion else {
            return nil
        }
        return available
    }

    // MARK: Ordered access (what the sidebar renders)

    /// Groups in display order.
    public var orderedGroups: [Group] {
        groups.values.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    /// Sessions of one group in display order.
    public func sessions(in groupID: GroupID) -> [Session] {
        sessions.values
            .filter { $0.groupID == groupID }
            .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    /// Every session in sidebar order (group order, then session order) — the flat list ⌘P and the
    /// next/previous-session commands walk.
    public var orderedSessions: [Session] {
        orderedGroups.flatMap { sessions(in: $0.id) }
    }

    public func group(of sessionID: SessionID) -> Group? {
        sessions[sessionID].flatMap { groups[$0.groupID] }
    }

    public var selectedSession: Session? {
        selection.flatMap { sessions[$0] }
    }

    /// The usage snapshot the status bar shows for a session's account.
    public func usage(for session: Session) -> UsageSnapshot? {
        usage[session.accountKey]
    }

    // MARK: Summary strip

    /// "5 working · 2 need you" — counts for the sidebar's summary strip.
    public var summaryCounts: (working: Int, needsYou: Int, idle: Int) {
        var working = 0, needsYou = 0, idle = 0
        for session in sessions.values {
            if session.needsAttention { needsYou += 1 }
            switch session.status {
            case .working: working += 1
            case .waiting: break
            case .idle: idle += 1
            }
        }
        return (working, needsYou, idle)
    }
}
