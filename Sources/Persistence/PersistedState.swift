// The durable projection of `AppState` — what `state.json` v1 actually contains.
//
// `AppState` is deliberately *not* `Codable`. Three reasons it must not be encoded directly:
//
//   * its `groups`/`sessions` are dictionaries keyed by `GroupID`/`SessionID`, and a `Codable`
//     dictionary with a struct key encodes as a flat `[k, v, k, v]` array — unreadable by hand and
//     nothing like design.md's `groups[]` / `sessions[]`;
//   * `CGRect` encodes as `[[x, y], [w, h]]`, where the ticket asks for explicit keys;
//   * `accounts`, `usage` and `update` are not durable at all. Accounts come from config, usage
//     from `UsageReader` and `update` from the release check; persisting any of them
//     would mean restoring a stale reading as if it were current. Only the *dismissed* update
//     version is kept, in `preferences`.
//
// `Session.live` needs no handling here: `Session.CodingKeys` already omits it, so a decoded row has
// `live == nil` and therefore `status == .exited` *by construction* (design.md → *Session flows &
// persistence*). A restored row is a resumable row, and there is no code path that can make it
// anything else.

import CoreGraphics
import Foundation
import TkzCore

/// A rectangle with names. `CGRect: Codable` writes `[[x,y],[w,h]]`; a file a human may have to
/// repair by hand deserves better, and `TkzCore`/`Persistence` may not use `NSStringFromRect`.
public struct PersistedFrame: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }

    /// `nil` for a degenerate rectangle: a hand-edited zero size must degrade to "let AppKit place
    /// the window", never to an invisible one.
    public var rect: CGRect? {
        guard width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// `sidebar` in the schema. Note what is *not* here: `collapsedGroups`. `Group.isCollapsed` is
/// already persisted with the group and is already the single source the outline view renders from
/// (`SidebarViewController.applyCollapse`), so a second copy would be two truths that can drift.
public struct PersistedSidebar: Hashable, Sendable, Codable {
    public var visible: Bool
    /// Points, as the user last dragged the divider. `nil` = the built-in default width.
    public var width: Double?

    public init(visible: Bool, width: Double?) {
        self.visible = visible
        self.width = width
    }
}

/// `preferences` in the schema (M5.2). Every field has a default and the whole block is optional
/// on read, so a v1 file written before the block existed still loads — no schema bump for a
/// new switch.
public struct PersistedPreferences: Hashable, Sendable, Codable {
    /// `claude --resume` every restored row at launch.
    public var autoResumeOnLaunch: Bool
    /// The statusline consent sheet has been shown once.
    public var statuslineOffered: Bool
    /// The release whose "Update available" card was closed; `nil` = none dismissed.
    public var dismissedUpdateVersion: String?
    /// `Theme.Preset.rawValue`; `nil` = never chosen, so the default preset stands.
    ///
    /// Deliberately a raw `String` rather than `Theme.Preset`: a preset name written by a newer
    /// build must degrade to a warning in `apply(to:)`, not throw out of `init(from:)` and take the
    /// whole `state.json` with it.
    public var themePreset: String?
    /// The token usage/spend feature's global on/off (design: enable/disable). Absent in a file
    /// written before this existed, which must default to *on* — `decodeIfPresent(...) ?? true`
    /// below, not `?? false` like the other switches here, all of which default off.
    public var showSessionSpend: Bool
    /// The periodic base-branch fetch (2026-09-13). Absent in older files ⇒ off, like the other
    /// switches: it is background network activity and must be a choice.
    public var checkOriginPeriodically: Bool
    /// The "Claude finished" notification switch (2026-09-15). Absent in older files ⇒ **on**,
    /// like `showSessionSpend`: a file written before the switch existed must not silently turn
    /// it off.
    public var notifyOnDone: Bool

    public init(
        autoResumeOnLaunch: Bool = false,
        statuslineOffered: Bool = false,
        dismissedUpdateVersion: String? = nil,
        themePreset: String? = nil,
        showSessionSpend: Bool = true,
        checkOriginPeriodically: Bool = false,
        notifyOnDone: Bool = true
    ) {
        self.autoResumeOnLaunch = autoResumeOnLaunch
        self.statuslineOffered = statuslineOffered
        self.dismissedUpdateVersion = dismissedUpdateVersion
        self.themePreset = themePreset
        self.showSessionSpend = showSessionSpend
        self.checkOriginPeriodically = checkOriginPeriodically
        self.notifyOnDone = notifyOnDone
    }

    private enum CodingKeys: String, CodingKey {
        case autoResumeOnLaunch, statuslineOffered, dismissedUpdateVersion, themePreset
        case showSessionSpend, checkOriginPeriodically, notifyOnDone
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoResumeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoResumeOnLaunch) ?? false
        statuslineOffered = try c.decodeIfPresent(Bool.self, forKey: .statuslineOffered) ?? false
        dismissedUpdateVersion = try c.decodeIfPresent(String.self, forKey: .dismissedUpdateVersion)
        themePreset = try c.decodeIfPresent(String.self, forKey: .themePreset)
        showSessionSpend = try c.decodeIfPresent(Bool.self, forKey: .showSessionSpend) ?? true
        checkOriginPeriodically = try c.decodeIfPresent(Bool.self, forKey: .checkOriginPeriodically) ?? false
        notifyOnDone = try c.decodeIfPresent(Bool.self, forKey: .notifyOnDone) ?? true
    }
}

/// `state.json`, at `currentSchemaVersion`.
public struct PersistedState: Hashable, Sendable, Codable {
    /// The version this build writes. Bumping it needs a `Migrations` case.
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    /// Display order, so the file reads top to bottom like the sidebar does.
    public var groups: [Group]
    public var sessions: [Session]
    public var selection: SessionID?
    public var sidebar: PersistedSidebar
    public var windowFrame: PersistedFrame?
    public var shortcuts: [String: String]
    public var preferences: PersistedPreferences
    /// The activity feed's log, oldest first. Its own top-level key, and **no schema bump**: an
    /// older v3 build carries an unknown top-level key through `StateDocument.extras` untouched,
    /// and this build reads a file without it as an empty log — neither of the two reasons the
    /// v2→v3 bump gives applies.
    public var activity: [ActivityEvent]

    /// The keys this build writes. Anything else in the file is a newer build's and is carried in
    /// `StateDocument.extras`.
    static let knownKeys: Set<String> = [
        "schemaVersion", "groups", "sessions", "selection", "sidebar", "windowFrame",
        "shortcuts", "preferences", "activity",
    ]

    public init(
        schemaVersion: Int = PersistedState.currentSchemaVersion,
        groups: [Group] = [],
        sessions: [Session] = [],
        selection: SessionID? = nil,
        sidebar: PersistedSidebar = PersistedSidebar(visible: true, width: nil),
        windowFrame: PersistedFrame? = nil,
        shortcuts: [String: String] = [:],
        preferences: PersistedPreferences = PersistedPreferences(),
        activity: [ActivityEvent] = []
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.sessions = sessions
        self.selection = selection
        self.sidebar = sidebar
        self.windowFrame = windowFrame
        self.shortcuts = shortcuts
        self.preferences = preferences
        self.activity = activity
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, groups, sessions, selection, sidebar, windowFrame, shortcuts
        case preferences, activity
    }

    /// `preferences` is optional on the way in: files written before M5.2 have no such key.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        groups = try c.decode([Group].self, forKey: .groups)
        sessions = try c.decode([Session].self, forKey: .sessions)
        selection = try c.decodeIfPresent(SessionID.self, forKey: .selection)
        sidebar = try c.decode(PersistedSidebar.self, forKey: .sidebar)
        windowFrame = try c.decodeIfPresent(PersistedFrame.self, forKey: .windowFrame)
        shortcuts = try c.decode([String: String].self, forKey: .shortcuts)
        preferences = try c.decodeIfPresent(PersistedPreferences.self, forKey: .preferences)
            ?? PersistedPreferences()
        activity = try c.decodeIfPresent([ActivityEvent].self, forKey: .activity) ?? []
    }

    // MARK: Projection

    /// The durable half of a live `AppState`.
    ///
    /// `live` is cleared from every session here, not only on the way to JSON. `Session` is
    /// `Equatable` including `live`, and `StateAutosaver` decides whether to write by comparing two
    /// projections — so a projection that carried process state would differ on every Claude status
    /// flip, every git refresh and every port scan, and the comparison would filter nothing.
    public init(_ state: AppState) {
        self.init(
            groups: state.orderedGroups,
            sessions: state.orderedSessions.map { session in
                var durable = session
                durable.live = nil
                return durable
            },
            selection: state.selection,
            sidebar: PersistedSidebar(
                visible: state.sidebarVisible, width: state.sidebarWidth.map { Double($0) }),
            windowFrame: state.windowFrame.map(PersistedFrame.init),
            shortcuts: state.shortcuts,
            preferences: PersistedPreferences(
                autoResumeOnLaunch: state.autoResumeOnLaunch,
                statuslineOffered: state.statuslineOffered,
                dismissedUpdateVersion: state.dismissedUpdateVersion,
                themePreset: state.themePreset.rawValue,
                showSessionSpend: state.showSessionSpend,
                checkOriginPeriodically: state.checkOriginPeriodically,
                notifyOnDone: state.notifyOnDone),
            activity: state.activity)
    }

    // MARK: Restore

    /// Merges the file over a base state (`AppState.startup(homeDirectory:)`), leaving `accounts`
    /// and `usage` — which are rediscovered, not restored — alone.
    ///
    /// Returns what it had to throw away. A `state.json` may have been hand-edited, so a session
    /// pointing at a group that no longer exists is possible; dropping it silently would make a row
    /// vanish with no explanation anywhere.
    @discardableResult
    public func apply(to state: inout AppState) -> [String] {
        var warnings: [String] = []

        // An empty `groups` means "nothing was ever arranged" — keep the startup group rather than
        // handing the user a sidebar with no home to launch from.
        if !groups.isEmpty {
            state.groups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
            var kept: [SessionID: Session] = [:]
            // Threaded across every row, not reset per row: a terminal id is a `.ghsnap`
            // basename, so it has to be unique file-wide. Iterating `sessions` in file order
            // makes "the first occurrence keeps the id" deterministic.
            var claimedTerminals: Set<TerminalID> = []
            var claimedTabs: Set<TabID> = []
            for session in sessions {
                guard state.groups[session.groupID] != nil else {
                    warnings.append("session \(session.id) names unknown group \(session.groupID)")
                    continue
                }
                var session = session
                warnings.append(
                    contentsOf: session.normalizeLayout(
                        claimedTerminals: &claimedTerminals, claimedTabs: &claimedTabs))
                kept[session.id] = session
            }
            state.sessions = kept
        } else if !sessions.isEmpty {
            warnings.append("\(sessions.count) session(s) with no groups; dropped")
        }

        if let selection, state.sessions[selection] == nil {
            warnings.append("selection \(selection) names no session; cleared")
            state.selection = nil
        } else {
            state.selection = selection
        }
        state.sidebarVisible = sidebar.visible
        state.sidebarWidth = sidebar.width.map { CGFloat($0) }
        if let windowFrame { state.windowFrame = windowFrame.rect }
        state.shortcuts = shortcuts
        // An entry for a row that did not make it back can jump nowhere; the cap holds either way.
        let dropped = activity.count { state.sessions[$0.sessionID] == nil }
        if dropped > 0 { warnings.append("\(dropped) activity entr\(dropped == 1 ? "y" : "ies") for unknown sessions; dropped") }
        state.activity = Array(activity.filter { state.sessions[$0.sessionID] != nil }.suffix(AppState.activityCap))
        state.autoResumeOnLaunch = preferences.autoResumeOnLaunch
        state.statuslineOffered = preferences.statuslineOffered
        state.dismissedUpdateVersion = preferences.dismissedUpdateVersion
        state.showSessionSpend = preferences.showSessionSpend
        state.checkOriginPeriodically = preferences.checkOriginPeriodically
        state.notifyOnDone = preferences.notifyOnDone
        if let raw = preferences.themePreset {
            if let preset = Theme.Preset(rawValue: raw) {
                state.themePreset = preset
            } else {
                warnings.append(
                    "theme preset \"\(raw)\" is not one this build knows; kept \(state.themePreset.rawValue)")
            }
        }

        return warnings
    }
}

/// A parsed file: the typed state plus whatever top-level keys this build does not know.
public struct StateDocument: Hashable, Sendable {
    public var state: PersistedState
    /// Top-level keys written by a newer tkzmux, re-emitted verbatim on save.
    public var extras: [String: JSONValue]

    public init(state: PersistedState, extras: [String: JSONValue] = [:]) {
        self.state = state
        self.extras = extras
    }
}
