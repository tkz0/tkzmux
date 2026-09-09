// The tab strip: pure geometry, and the layers it draws (TKZ-36).
//
// Modelled on `SidebarRowViewTests`: the layout maths is a pure function, so it is asserted
// without a view at all, and the view is asserted structurally — layer count, frames, colours —
// with no window, which is what "no subviews" buys.

import AppKit
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct TabStripViewTests {

    private static func model(_ count: Int, selected: Int = 0, panes: [Int: Int] = [:])
        -> TabStripModel
    {
        TabStripModel(
            items: (0..<count).map { index in
                TabStripItem(
                    title: "Terminal \(index + 1)",
                    isSelected: index == selected,
                    terminalCount: panes[index] ?? 1)
            })
    }

    private static func strip(_ model: TabStripModel, width: CGFloat = 600) -> TabStripView {
        let view = TabStripView(theme: .default)
        view.frame = NSRect(x: 0, y: 0, width: width, height: TabStripMetrics.stripHeight)
        view.configure(model, theme: .default)
        view.layout()
        return view
    }

    // MARK: Geometry (pure)

    @Test func tabsShareTheStripAndDoNotOverlap() {
        let rects = Self.model(3).tabRects(in: 600)
        #expect(rects.count == 3)
        for (a, b) in zip(rects, rects.dropFirst()) {
            #expect(a.maxX <= b.minX, "tabs must not overlap")
        }
        #expect(rects[0].minX == TabStripMetrics.horizontalInset)
        #expect(rects.last!.maxX <= 600)
    }

    /// A wide strip with few tabs must not give each one the whole width.
    @Test func aTabIsNeverWiderThanTheMaximum() {
        let rects = Self.model(2).tabRects(in: 2000)
        for rect in rects { #expect(rect.width <= TabStripMetrics.tabMaxWidth) }
    }

    @Test func hitTestingFindsTheTabUnderThePoint() {
        let model = Self.model(3)
        let rects = model.tabRects(in: 600)
        for (index, rect) in rects.enumerated() {
            let point = CGPoint(x: rect.midX, y: rect.midY)
            #expect(model.tabIndex(at: point, width: 600) == index)
        }
        // The inset either side belongs to no tab.
        #expect(model.tabIndex(at: CGPoint(x: 1, y: 10), width: 600) == nil)
        #expect(model.tabIndex(at: CGPoint(x: 599, y: 10), width: 600) == nil)
    }

    @Test func theCloseAffordanceIsTheRightEdgeOfATab() {
        let model = Self.model(2)
        let rect = model.tabRects(in: 600)[0]
        #expect(model.isOnClose(CGPoint(x: rect.maxX - 3, y: rect.midY), width: 600))
        #expect(!model.isOnClose(CGPoint(x: rect.minX + 10, y: rect.midY), width: 600))
    }

    /// A lone tab conveys nothing, and hiding the strip keeps a single-terminal session's layout
    /// exactly what it was before tabs existed.
    @Test func aSingleTabHidesTheStrip() {
        #expect(!Self.model(1).isVisible)
        #expect(Self.model(2).isVisible)
        #expect(!TabStripModel().isVisible)
    }

    // MARK: The view

    @Test func theStripDrawsOneBackgroundPerTab() {
        let view = Self.strip(Self.model(3))
        #expect(view.tabBackgroundLayers.count == 3)
        #expect(view.tabTitleLayers.count == 3)
        for (layer, rect) in zip(view.tabBackgroundLayers, Self.model(3).tabRects(in: 600)) {
            #expect(layer.frame.minX == rect.minX)
            #expect(layer.frame.width == rect.width)
        }
    }

    @Test func theSelectedTabIsTintedAndTheOthersAreNot() throws {
        let view = Self.strip(Self.model(3, selected: 1))
        let selected = try #require(view.tabBackgroundLayers[1].backgroundColor)
        #expect(selected == Theme.default.selection.cgColor)
        for index in [0, 2] {
            let alpha = view.tabBackgroundLayers[index].backgroundColor?.alpha ?? 0
            #expect(alpha == 0, "an unselected tab draws no background")
        }
    }

    @Test func aTabWithSeveralPanesShowsACount() {
        let view = Self.strip(Self.model(2, panes: [1: 3]))
        #expect(view.tabBadgeLayers[0].isHidden)
        #expect(!view.tabBadgeLayers[1].isHidden)
    }

    /// Re-configuring with the same model must be idempotent — the strip is rebuilt on every
    /// layout delivery, and churning layers would flicker.
    @Test func reconfiguringWithTheSameModelChangesNothing() {
        let view = Self.strip(Self.model(3))
        let before = view.tabBackgroundLayers
        view.configure(Self.model(3), theme: .default)
        let after = view.tabBackgroundLayers
        #expect(before.count == after.count)
        for (a, b) in zip(before, after) { #expect(a === b) }
    }

    @Test func titlesTruncateRatherThanEscapeTheirTab() {
        let long = TabStripModel(items: [
            TabStripItem(title: String(repeating: "very long name ", count: 8), isSelected: true),
            TabStripItem(title: "second"),
        ])
        let view = Self.strip(long, width: 300)
        for (title, rect) in zip(view.tabTitleLayers, long.tabRects(in: 300)) {
            #expect(title.frame.maxX <= rect.maxX)
            #expect(title.truncationMode == .end)
        }
    }
}
