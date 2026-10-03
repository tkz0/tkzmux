// LayerContentsScale.swift — the one place the hand-made layers' `contentsScale` comes from.
//
// Four sites build a layer outside any view's backing store and so have to choose a
// `contentsScale` themselves: every `CATextLayer` and chevron made by `SidebarLayers`
// (`StatusDotView.swift`), the startup spinner (`PaneStartupOverlayView`) and the empty-state label
// (`EmptyStateView` in `MainWindowController.swift`). Production has always used 2, and still does:
// nothing in the app ever sets this.
//
// It exists for capture, not for the app. The component snapshots (WOR-307) render the same views
// at 2.0 and at 1.6, Hyprland's fractional scale, through `withScale(_:_:)`. WOR-322 S4's
// full-window capture (`TKZMUX_DEV_CAPTURE_SCALE`) sets `current` once, before the window is built,
// and needs no edit at any of the four sites. Deriving the value from `backingScaleFactor` instead
// would change what a 1x display draws today, so this is deliberately the only way in.
//
// A `Mutex` rather than a main-actor static: `SidebarLayers` is called from `CALayer` subclasses'
// initialisers, which are not main-actor isolated.

import AppKit
import Synchronization

enum LayerContentsScale {
    /// What every site used before this seam existed, and what production still uses.
    static let production: CGFloat = 2

    private static let storage = Mutex<CGFloat>(production)

    /// The scale a newly made layer gets. Read when the layer is created, so changing it does not
    /// touch layers that already exist; `SidebarLayers.applyContentsScale(_:to:)` does that.
    static var current: CGFloat {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// Runs `body` with `scale` as `current`, then puts the previous value back.
    static func withScale<Result>(_ scale: CGFloat, _ body: () throws -> Result) rethrows -> Result {
        let previous = storage.withLock { value in
            let old = value
            value = scale
            return old
        }
        defer { storage.withLock { $0 = previous } }
        return try body()
    }
}
