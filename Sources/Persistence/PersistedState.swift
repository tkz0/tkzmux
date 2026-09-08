// The durable projection of `AppState` — what `state.json` v1 actually contains.
//
// `AppState` is deliberately *not* `Codable`. Three reasons it must not be encoded directly:
//
//   * its `groups`/`sessions` are dictionaries keyed by `GroupID`/`SessionID`, and a `Codable`
//     dictionary with a struct key encodes as a flat `[k, v, k, v]` array — unreadable by hand and
//     nothing like design.md's `groups[]` / `sessions[]`;
//   * `CGRect` encodes as `[[x, y], [w, h]]`, where the ticket asks for explicit keys;
//   * `accounts` and `usage` are not durable at all. Accounts come from config and usage from
//     `UsageReader`; persisting either would mean restoring a stale quota reading as if it were
//     current.
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

    public init(autoResumeOnLaunch: Bool = false) {
        self.autoResumeOnLaunch = autoResumeOnLaunch
    }

    private enum CodingKeys: String, CodingKey { case autoResumeOnLaunch }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoResumeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoResumeOnLaunch) ?? false
    }
}

/// `state.json` v1.
public struct PersistedState: Hashable, Sendable, Codable {
    /// The version this build writes. Bumping it needs a `Migrations` case.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Display order, so the file reads top to bottom like the sidebar does.
    public var groups: [Group]
    public var sessions: [Session]
    public var presets: [Preset]
    public var selection: SessionID?
    public var sidebar: PersistedSidebar
    public var windowFrame: PersistedFrame?
    public var shortcuts: [String: String]
    public var preferences: PersistedPreferences

    /// The keys this build writes. Anything else in the file is a newer build's and is carried in
    /// `StateDocument.extras`.
    static let knownKeys: Set<String> = [
        "schemaVersion", "groups", "sessions", "presets", "selection", "sidebar", "windowFrame",
        "shortcuts", "preferences",
    ]

    public init(
        schemaVersion: Int = PersistedState.currentSchemaVersion,
        groups: [Group] = [],
        sessions: [Session] = [],
        presets: [Preset] = [],
        selection: SessionID? = nil,
        sidebar: PersistedSidebar = PersistedSidebar(visible: true, width: nil),
        windowFrame: PersistedFrame? = nil,
        shortcuts: [String: String] = [:],
        preferences: PersistedPreferences = PersistedPreferences()
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.sessions = sessions
        self.presets = presets
        self.selection = selection
        self.sidebar = sidebar
        self.windowFrame = windowFrame
        self.shortcuts = shortcuts
        self.preferences = preferences
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, groups, sessions, presets, selection, sidebar, windowFrame, shortcuts
        case preferences
    }

    /// `preferences` is optional on the way in: files written before M5.2 have no such key.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        groups = try c.decode([Group].self, forKey: .groups)
        sessions = try c.decode([Session].self, forKey: .sessions)
        presets = try c.decode([Preset].self, forKey: .presets)
        selection = try c.decodeIfPresent(SessionID.self, forKey: .selection)
        sidebar = try c.decode(PersistedSidebar.self, forKey: .sidebar)
        windowFrame = try c.decodeIfPresent(PersistedFrame.self, forKey: .windowFrame)
        shortcuts = try c.decode([String: String].self, forKey: .shortcuts)
        preferences = try c.decodeIfPresent(PersistedPreferences.self, forKey: .preferences)
            ?? PersistedPreferences()
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
            presets: state.presets,
            selection: state.selection,
            sidebar: PersistedSidebar(
                visible: state.sidebarVisible, width: state.sidebarWidth.map { Double($0) }),
            windowFrame: state.windowFrame.map(PersistedFrame.init),
            shortcuts: state.shortcuts,
            preferences: PersistedPreferences(autoResumeOnLaunch: state.autoResumeOnLaunch))
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
            for session in sessions {
                guard state.groups[session.groupID] != nil else {
                    warnings.append("session \(session.id) names unknown group \(session.groupID)")
                    continue
                }
                kept[session.id] = session
            }
            state.sessions = kept
        } else if !sessions.isEmpty {
            warnings.append("\(sessions.count) session(s) with no groups; dropped")
        }

        state.presets = presets
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
        state.autoResumeOnLaunch = preferences.autoResumeOnLaunch

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
