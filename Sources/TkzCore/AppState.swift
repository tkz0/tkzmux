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
    /// Keyed by `Account.key` (`claude`, `claude-alt`).
    public var accounts: [String: Account]
    /// Keyed by `Account.key`; what `UsageReader` (M3.5) publishes.
    public var usage: [String: UsageSnapshot]
    /// The selected session, i.e. the one attached to the terminal surface.
    public var selection: SessionID?
    public var sidebarVisible: Bool
    /// Restored on launch; `nil` = let AppKit place the window.
    public var windowFrame: CGRect?
    public var presets: [Preset]
    /// Command id → key-equivalent string (e.g. `"newSession": "cmd+t"`). Persisted verbatim;
    /// M2.4 owns the vocabulary.
    public var shortcuts: [String: String]

    public init(
        groups: [GroupID: Group] = [:],
        sessions: [SessionID: Session] = [:],
        accounts: [String: Account] = [:],
        usage: [String: UsageSnapshot] = [:],
        selection: SessionID? = nil,
        sidebarVisible: Bool = true,
        windowFrame: CGRect? = nil,
        presets: [Preset] = [],
        shortcuts: [String: String] = [:]
    ) {
        self.groups = groups
        self.sessions = sessions
        self.accounts = accounts
        self.usage = usage
        self.selection = selection
        self.sidebarVisible = sidebarVisible
        self.windowFrame = windowFrame
        self.presets = presets
        self.shortcuts = shortcuts
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

    /// "5 working · 2 need you" — counts for the sidebar footer.
    public var summaryCounts: (working: Int, needsYou: Int, idle: Int, exited: Int) {
        var working = 0, needsYou = 0, idle = 0, exited = 0
        for session in sessions.values {
            if session.needsAttention { needsYou += 1 }
            switch session.status {
            case .working: working += 1
            case .waiting: break
            case .idle: idle += 1
            case .exited: exited += 1
            }
        }
        return (working, needsYou, idle, exited)
    }
}
