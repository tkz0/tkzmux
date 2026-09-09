// Fixed geometry for the split container (TKZ-36).
//
// Same role as `SidebarMetrics`: the numbers the design fixes, in one place, so a view never
// invents one inline. Nothing here is a theme token — colours come from `Theme`.

import AppKit
import CoreGraphics
import TkzCore

public enum SplitMetrics {
    /// `NSSplitView`'s `.thin` divider draws 1 pt, and the tree's geometry has to agree with it or
    /// a pane's grid is computed for a width it does not have.
    public static let dividerThickness: CGFloat = 1
    /// A pane narrower or shorter than this is not a terminal any more. `PaneSplitView` clamps
    /// drags to it, and `PaneSplit.ratioRange` is the model's coarser version of the same idea.
    public static let minPaneSide: CGFloat = 120
    /// What a fresh split gives each side.
    public static let defaultRatio: Double = 0.5
    /// Ratios closer than this are the same ratio. Guards the drag→store→drag round trip from
    /// oscillating on sub-pixel differences.
    public static let ratioEpsilon: Double = 0.005
}

// MARK: - Axis, in AppKit's terms

extension PaneAxis {
    /// `NSSplitView.isVertical` means "the **divider** is vertical", i.e. children side by side.
    ///
    /// This is the one naming collision in the feature and it is worth stating once: the toolbar's
    /// `◫` button is labelled *Split vertically*, produces side-by-side panes, and therefore maps
    /// to `PaneAxis.horizontal` and `isVertical == true`. Everything below the view layer speaks
    /// `PaneAxis` so nobody has to re-derive that.
    var isVerticalSplitView: Bool { self == .horizontal }
}

// MARK: - The stand-in

/// A focusable, layer-backed `NSView` with nothing in it.
///
/// Vended by the single-view initialiser for any pane past the first: that path exists for callers
/// that drive the window with one injected terminal, and giving them a second *real* terminal is
/// not something they asked for. A pane that shows one of these is inert, not broken — the host
/// has no surface for it, so nothing is attached and nothing is drawn.
final class FocusableStubView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
