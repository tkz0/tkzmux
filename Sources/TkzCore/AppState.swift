// TkzCore — the single value that describes the whole app. See docs/design.md → *App architecture
// → Store*: `AppStore` owns one of these, services post mutations into it, views read it.
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
    /// `claudeSessionId` gets `claude --resume` typed into a fresh shell when the app starts.
    public var autoResumeOnLaunch: Bool
    /// Whether the statusline consent sheet has already been put to the user (TKZ-32). Asked once
    /// and never again: declining is an answer, and re-asking every launch would be nagging. The
    /// menu command stays available either way.
    public var statuslineOffered: Bool
    /// The release the user closed the sidebar's update card for (TKZ-50). That version never
    /// shows the card again; a newer one does. Durable, in `PersistedPreferences`.
    public var dismissedUpdateVersion: String?
    /// The active colour scheme. The ☾/☀ toggle in the toolbar writes it; `MainWindowController` is
    /// its sole observer, via `ChangeSet.theme`. Durable, in `PersistedPreferences`.
    public var themePreset: Theme.Preset
    /// The release check's answer and the in-app upgrade's progress. Process state, never
    /// persisted — see `UpdateState`.
    public var update: UpdateState

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
        dismissedUpdateVersion: String? = nil,
        themePreset: Theme.Preset = Theme.default.preset,
        update: UpdateState = UpdateState()
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
        self.dismissedUpdateVersion = dismissedUpdateVersion
        self.themePreset = themePreset
        self.update = update
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
