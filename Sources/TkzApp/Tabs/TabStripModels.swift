// The tab strip's presentation model.
//
// Same shape as `SidebarRowModels`: value types with no `TkzCore` model inside them, so the view
// renders deterministically from data a test can construct, and the geometry is a pure function
// rather than something only a laid-out view knows. Hit testing in particular is pure — a click
// landing on the wrong tab is a bug worth catching without a window.

import AppKit
import Foundation
import TkzCore

public enum TabStripMetrics {
    /// Tall enough for a 12.5 pt title and a badge, short enough that a single-tab session loses
    /// nothing by hiding the strip.
    public static let stripHeight = CGFloat(DesignTokens.Metrics.TabStrip.stripHeight.value)
    public static let tabMinWidth = CGFloat(DesignTokens.Metrics.TabStrip.tabMinWidth.value)
    public static let tabMaxWidth = CGFloat(DesignTokens.Metrics.TabStrip.tabMaxWidth.value)
    public static let tabGap = CGFloat(DesignTokens.Metrics.TabStrip.tabGap.value)
    public static let horizontalInset = CGFloat(DesignTokens.Metrics.TabStrip.horizontalInset.value)
    public static let cornerRadius = CGFloat(DesignTokens.Radii.tab.value)
    /// Space between a tab's title and its pane-count badge.
    public static let badgeGap = CGFloat(DesignTokens.Metrics.TabStrip.badgeGap.value)
    public static let closeSize = CGFloat(DesignTokens.Metrics.TabStrip.closeSize.value)
}

public struct TabStripItem: Hashable, Sendable {
    public var title: String
    public var isSelected: Bool
    /// Panes in this tab. Shown as a badge when > 1, the same rule as the sidebar row's.
    public var terminalCount: Int

    public init(title: String, isSelected: Bool = false, terminalCount: Int = 1) {
        self.title = title
        self.isSelected = isSelected
        self.terminalCount = terminalCount
    }
}

public struct TabStripModel: Hashable, Sendable {
    public var items: [TabStripItem]

    public init(items: [TabStripItem] = []) {
        self.items = items
    }

    /// The strip is hidden entirely for a session with one tab: a lone tab conveys nothing, and
    /// hiding it keeps a single-terminal session's layout exactly what it was before this ticket.
    public var isVisible: Bool { items.count > 1 }

    public var selectedIndex: Int? { items.firstIndex(where: \.isSelected) }

    /// Where each tab sits, left to right, in a strip `width` points wide.
    ///
    /// Tabs share the width evenly between `tabMinWidth` and `tabMaxWidth`; past the point where
    /// the minimum no longer fits they keep shrinking rather than scrolling, because a session
    /// with that many tabs has a bigger problem than a cramped strip.
    public func tabRects(in width: CGFloat, height: CGFloat = TabStripMetrics.stripHeight)
        -> [CGRect]
    {
        guard !items.isEmpty else { return [] }
        let count = CGFloat(items.count)
        let usable = max(0, width - TabStripMetrics.horizontalInset * 2)
        let gaps = TabStripMetrics.tabGap * (count - 1)
        let each = min(
            TabStripMetrics.tabMaxWidth, max(0, (usable - gaps) / count))
        return items.indices.map { index in
            CGRect(
                x: TabStripMetrics.horizontalInset
                    + CGFloat(index) * (each + TabStripMetrics.tabGap),
                y: 0,
                width: each,
                height: height)
        }
    }

    /// Which tab a point lands on, or nil for the strip's background.
    public func tabIndex(at point: CGPoint, width: CGFloat, height: CGFloat = TabStripMetrics.stripHeight)
        -> Int?
    {
        tabRects(in: width, height: height).firstIndex { $0.contains(point) }
    }

    /// Whether a point is on a tab's close affordance rather than its body.
    public func isOnClose(_ point: CGPoint, width: CGFloat, height: CGFloat = TabStripMetrics.stripHeight)
        -> Bool
    {
        guard let index = tabIndex(at: point, width: width, height: height) else { return false }
        let rect = tabRects(in: width, height: height)[index]
        return point.x >= rect.maxX - TabStripMetrics.closeSize - 4
    }
}

extension Array {
    /// Bounds-checked subscript. The strip's callbacks carry an index the view derived from a
    /// click, and the store can have moved on between the two — a stale index must be a no-op,
    /// not a trap.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
