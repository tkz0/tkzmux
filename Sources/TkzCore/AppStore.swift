// TkzCore — the store. See docs/design.md → *App architecture → Store*.
//
// The reason this type exists instead of `@Observable`: the sidebar must learn *which* session
// changed, so that a Claude status flip on one session costs one `reloadData(forRowIndexes:)`
// rather than 40 row re-renders. So every mutation is diffed into a `ChangeSet`, and the change
// sets produced within one run-loop turn are unioned and delivered **once**.

import Dispatch
import Foundation

// MARK: - ChangeSet

/// What changed since the last delivery. Every field is independent; observers act on the ones
/// they care about and ignore the rest.
///
/// **Granularity rules** (asserted by `AppStoreTests`):
///
/// | Mutation | Fields set |
/// |---|---|
/// | a session's `live.status`, title, git, ports … | `sessions = [id]` — **never** `structure` |
/// | a session's tabs, splits, ratios, focused pane, active tab, zoom | `sessions = [id]` **and** `layout = [id]` — **never** `structure` |
/// | a pane's live `cwd` (OSC 7) or pid | `sessions = [id]` — **never** `layout` |
/// | a group's name, colour, `isCollapsed` | `groups = [id]` — **never** `structure` |
/// | a session or group added / removed | `structure`, plus the id in `sessions` / `groups` |
/// | a session's `groupID` or `order`, a group's `order` | `structure`, plus the id |
/// | selection | `selection` |
/// | usage / accounts | `usage` |
/// | sidebar visibility, sidebar width, window frame, shortcuts | `chrome` |
/// | the active theme preset | `theme` — **never** `chrome` |
///
/// `structure` therefore means exactly "the outline view's rows or their parents moved" — the only
/// case that needs `insert/remove/moveItem` or a full `reloadData`. Collapsing a group is *not*
/// structural: that is `expandItem`/`collapseItem`, driven by `groups`.
///
/// One mutation legitimately sets both: `createSession` into a *collapsed* group expands it, so the
/// change set carries `structure` (the new row) **and** `groups` (the group that reopened).
/// `layout` means exactly "the split container's *shape* changed" — the only case that needs the
/// detail view to build or destroy terminal views. It always co-fires with `sessions`, and it is a
/// separate bucket because `sessions` fires on every status flip and port scan, while rebuilding an
/// `NSSplitView` subtree is the one reaction that must not happen at that rate. A pane's `cwd`
/// follows the shell on every `cd`, so it rides `sessions` alone: walking a directory tree must
/// never re-attach a surface.
public struct ChangeSet: Hashable, Sendable {
    /// Sessions whose value differs (including any part of `live`).
    public var sessions: Set<SessionID>
    /// Groups whose value differs.
    public var groups: Set<GroupID>
    /// Rows were added, removed, re-parented or reordered.
    public var structure: Bool
    /// Sessions whose pane tree changed shape — see the note above `ChangeSet`.
    public var layout: Set<SessionID>
    /// `AppState.selection` differs.
    public var selection: Bool
    /// `AppState.usage` or `AppState.accounts` differ.
    public var usage: Bool
    /// Window chrome and settings that belong to no row: `sidebarVisible`, `sidebarWidth`,
    /// `windowFrame`, `shortcuts`, and the update card's `update` /
    /// `dismissedUpdateVersion` (TKZ-50). The sidebar's update card listens to this; the outline
    /// rows ignore it. `StateAutosaver`
    /// deliberately does *not*:
    /// a durable change can arrive in any bucket, and `sessions` carries mostly non-durable ones,
    /// so it compares projections on every delivery rather than trusting a bit here (M5.1).
    public var chrome: Bool
    /// `AppState.themePreset` differs. Its own bucket rather than a corner of `chrome`, for the same
    /// reason `layout` is not a corner of `sessions`: `chrome` fires on every window-frame nudge and
    /// sidebar-divider settle, while reacting to this one re-tints every row, every pane and every
    /// live terminal. `MainWindowController` is its **sole** observer — the fan-out has an order
    /// (window appearance first, terminals last), and a second subscriber would make that order
    /// depend on observer registration order, which is not guaranteed.
    public var theme: Bool

    public init(
        sessions: Set<SessionID> = [],
        groups: Set<GroupID> = [],
        layout: Set<SessionID> = [],
        structure: Bool = false,
        selection: Bool = false,
        usage: Bool = false,
        chrome: Bool = false,
        theme: Bool = false
    ) {
        self.sessions = sessions
        self.groups = groups
        self.layout = layout
        self.structure = structure
        self.selection = selection
        self.usage = usage
        self.chrome = chrome
        self.theme = theme
    }

    /// Nothing changed; no delivery happens for one of these.
    public static let none = ChangeSet()

    public var isEmpty: Bool {
        sessions.isEmpty && groups.isEmpty && layout.isEmpty && !structure && !selection
            && !usage && !chrome && !theme
    }

    public mutating func formUnion(_ other: ChangeSet) {
        sessions.formUnion(other.sessions)
        groups.formUnion(other.groups)
        layout.formUnion(other.layout)
        structure = structure || other.structure
        selection = selection || other.selection
        usage = usage || other.usage
        chrome = chrome || other.chrome
        theme = theme || other.theme
    }

    /// Does this change set touch a given session? (The status bar's re-render test.)
    public func touches(_ id: SessionID) -> Bool {
        structure || sessions.contains(id)
    }

    /// The diff of two states. Pure and `nonisolated` — usable from tests without a store.
    public static func diff(from old: AppState, to new: AppState) -> ChangeSet {
        var change = ChangeSet()

        // Sessions: symmetric difference of ids is structural; value inequality is a row reload.
        for (id, newSession) in new.sessions {
            guard let oldSession = old.sessions[id] else {
                change.sessions.insert(id)
                change.layout.insert(id)
                change.structure = true
                continue
            }
            if oldSession != newSession {
                change.sessions.insert(id)
                if !oldSession.hasSameLayoutShape(as: newSession) { change.layout.insert(id) }
                if oldSession.groupID != newSession.groupID || oldSession.order != newSession.order {
                    change.structure = true
                }
            }
        }
        for id in old.sessions.keys where new.sessions[id] == nil {
            change.sessions.insert(id)
            change.layout.insert(id)
            change.structure = true
        }

        for (id, newGroup) in new.groups {
            guard let oldGroup = old.groups[id] else {
                change.groups.insert(id)
                change.structure = true
                continue
            }
            if oldGroup != newGroup {
                change.groups.insert(id)
                if oldGroup.order != newGroup.order { change.structure = true }
            }
        }
        for id in old.groups.keys where new.groups[id] == nil {
            change.groups.insert(id)
            change.structure = true
        }

        if old.selection != new.selection { change.selection = true }
        if old.usage != new.usage || old.accounts != new.accounts { change.usage = true }
        if old.sidebarVisible != new.sidebarVisible || old.sidebarWidth != new.sidebarWidth
            || old.windowFrame != new.windowFrame
            || old.shortcuts != new.shortcuts
            || old.autoResumeOnLaunch != new.autoResumeOnLaunch
            || old.statuslineOffered != new.statuslineOffered
            || old.dismissedUpdateVersion != new.dismissedUpdateVersion
            || old.update != new.update
        {
            change.chrome = true
        }
        if old.themePreset != new.themePreset { change.theme = true }

        return change
    }
}

// MARK: - AppStore

/// Owns the one `AppState`, diffs every mutation, and delivers coalesced change sets on the main
/// run loop.
///
/// Usage:
/// ```swift
/// let store = AppStore(state: .fixture)
/// let token = store.addObserver { change in
///     if change.structure { outline.reloadData() }
///     else { outline.reloadRows(for: change.sessions) }
/// }
/// store.update { $0.renameSession(id, title: "review") }   // one delivery, next turn
/// store.removeObserver(token)
/// ```
///
/// Services (`ClaudeBridge`, `GitStatus`) run on their own queues and hop to the main actor to call
/// `update`; they never touch views.
@MainActor
public final class AppStore {
    /// The current state. Read freely; mutate only through `update`.
    public private(set) var state: AppState

    /// Handle returned by `addObserver`; pass it to `removeObserver`. Removing is optional — the
    /// store holds observers for its own lifetime, which is the app's.
    public struct ObserverToken: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private var observers: [(token: ObserverToken, body: (ChangeSet) -> Void)] = []
    private var nextObserverID: UInt64 = 1
    private var pending = ChangeSet()
    private var deliveries: UInt64 = 0
    private let signal: any DispatchSourceUserDataAdd

    public init(state: AppState = AppState()) {
        self.state = state
        signal = DispatchSource.makeUserDataAddSource(queue: .main)
        signal.setEventHandler { [weak self] in
            // The source is bound to the main queue, so this handler *is* the main actor; the
            // compiler cannot see that through the @Sendable handler type.
            MainActor.assumeIsolated { self?.deliver() }
        }
        signal.activate()
    }

    deinit { signal.cancel() }

    // MARK: Mutation

    /// Mutates the state, diffs it, and schedules delivery for the end of this run-loop turn.
    /// Mutations that change nothing deliver nothing.
    ///
    /// The closure gets exclusive access to the state, so it must **not** call `update` (or
    /// `updating`) again — that is an exclusivity violation and traps at runtime. Observers may
    /// call `update` freely; their change lands in the next turn.
    public func update(_ mutate: (inout AppState) -> Void) {
        let old = state
        mutate(&state)
        let change = ChangeSet.diff(from: old, to: state)
        guard !change.isEmpty else { return }
        pending.formUnion(change)
        signal.add(data: 1)
    }

    /// Convenience for reducers that return a value (`createSession`, say).
    @discardableResult
    public func updating<T>(_ mutate: (inout AppState) -> T) -> T {
        let old = state
        let result = mutate(&state)
        let change = ChangeSet.diff(from: old, to: state)
        if !change.isEmpty {
            pending.formUnion(change)
            signal.add(data: 1)
        }
        return result
    }

    // MARK: Observation

    /// Registers an observer, called on the main actor once per run-loop turn in which something
    /// changed. Observers are called in registration order.
    @discardableResult
    public func addObserver(_ body: @escaping (ChangeSet) -> Void) -> ObserverToken {
        let token = ObserverToken(id: nextObserverID)
        nextObserverID += 1
        observers.append((token, body))
        return token
    }

    public func removeObserver(_ token: ObserverToken) {
        observers.removeAll { $0.token == token }
    }

    // MARK: Delivery

    /// Delivers any pending change set immediately instead of waiting for the run loop.
    /// For tests and for the "apply everything before we quit" path; normal code never calls it.
    public func flush() { deliver() }

    /// Number of change sets delivered so far — the coalescing assertion in the tests.
    public var deliveryCount: UInt64 { deliveries }

    /// Whether anything is queued for the next turn.
    public var hasPendingChanges: Bool { !pending.isEmpty }

    private func deliver() {
        guard !pending.isEmpty else { return }
        let change = pending
        // Reset *before* notifying: an observer that calls `update` must arm the next turn, not
        // have its change swallowed by this one.
        pending = .none
        deliveries &+= 1
        for observer in observers { observer.body(change) }
    }
}
