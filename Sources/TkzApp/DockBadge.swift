// DockBadge — how many rows need the user, on the Dock icon (TKZ-67).
//
// The number is `AppState.summaryCounts.needsYou`, the summary strip's own figure, so the Dock and
// the window can never disagree. Through `StatusDerivation` that is exactly the rows in
// `waiting(_)` (permission, question, agent input, unattended done): every waiting outcome raises
// `attention`, and nothing else does. `working` rows need nothing and are not counted.
//
// A store observer, like `AttentionNotifier`: every flip lands in `ChangeSet.sessions`, the switch
// lands in `ChangeSet.chrome`. No polling. The tile sits behind `DockTileBadging` so tests never
// reach `NSApp`.

import AppKit
import TkzCore

/// Where the badge goes. Production writes `NSApp.dockTile`; tests use a recording fake.
@MainActor
public protocol DockTileBadging: AnyObject {
    /// `nil` shows no badge.
    var badgeLabel: String? { get set }
}

/// `NSApp.dockTile`. A no-op before an `NSApplication` exists, so a stray construction under
/// `swift test` never traps.
@MainActor
public final class SystemDockTile: DockTileBadging {
    public init() {}

    public var badgeLabel: String? {
        get { NSApp?.dockTile.badgeLabel }
        set {
            guard let tile = NSApp?.dockTile else { return }
            tile.badgeLabel = newValue
        }
    }
}

@MainActor
public final class DockBadge {
    private let store: AppStore
    private let tile: any DockTileBadging
    private var token: AppStore.ObserverToken?
    /// The label last written, so a session tick that leaves the count alone does not repaint
    /// the Dock.
    private var shown: String?

    public init(store: AppStore, tile: any DockTileBadging = SystemDockTile()) {
        self.store = store
        self.tile = tile
        // A relaunch with a prompt already up shows it at once, not at the next change.
        shown = tile.badgeLabel
        refresh()
        token = store.addObserver { [weak self] change in self?.apply(change) }
    }

    /// The label for a state: the NEEDS YOU count, or nothing when it is zero or the switch is off.
    static func label(for state: AppState) -> String? {
        guard state.badgeDockIcon else { return nil }
        let count = state.summaryCounts.needsYou
        return count > 0 ? String(count) : nil
    }

    /// One delivery. Internal so tests drive it through the store and `flush()`.
    func apply(_ change: ChangeSet) {
        // The summary strip's triggers (`SidebarViewController.apply`), plus `chrome` for the switch.
        guard change.chrome || change.structure || !change.sessions.isEmpty else { return }
        refresh()
    }

    private func refresh() {
        let label = DockBadge.label(for: store.state)
        guard label != shown else { return }
        shown = label
        tile.badgeLabel = label
    }
}
