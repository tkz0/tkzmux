// The split container: the pane tree, as views (TKZ-36).
//
// One `PaneSplitView` per `.split` node, plain `NSView`s as leaves. Nested `NSSplitView`s rather
// than a hand-laid container because everything a divider needs — hit testing, the resize cursor,
// the modal tracking loop, min-size clamping — is already there and none of it is interesting to
// reimplement. Not `NSSplitViewController`: that wants an `NSViewController` per pane and drags
// containment lifecycle in, while `addArrangedSubview` takes a plain `NSView`, which is what keeps
// the whole `TkzAppTests` suite running with no GPU over a `FakeTerminalView`.
//
// The container **diffs**. A pane's view is created once and moved between split views as the tree
// changes; rebuilding a sibling's view would detach and re-attach its surface, and a re-attach is
// a `DIRTY_FULL` — a visible flash on every split, on the pane the user did not touch.

import AppKit
import TkzCore
import TkzTerminalView

// MARK: - One split node

/// An `NSSplitView` that knows which leaf it divides, and turns a drag into a ratio.
final class PaneSplitView: NSSplitView, NSSplitViewDelegate {
    /// A leaf below `first`. The model addresses a split as "the parent of this pane", so the view
    /// never has to hold a node id it would then have to keep in step with the tree.
    let anchorLeaf: TerminalID
    /// How many splits sit between this one and `anchorLeaf` — 0 when the anchor is an immediate
    /// child. Passed straight to `AppState.setRatio(above:levels:to:)`.
    let anchorLevels: Int
    let axis: PaneAxis

    /// Called when a drag settles, with the first child's new share.
    var onRatioChanged: ((TerminalID, Int, Double) -> Void)?
    /// Every terminal view below this split, so a drag can bracket them all.
    var synchronousResizeTargets: () -> [TerminalMetalView] = { [] }

    init(axis: PaneAxis, anchorLeaf: TerminalID, anchorLevels: Int) {
        self.axis = axis
        self.anchorLeaf = anchorLeaf
        self.anchorLevels = anchorLevels
        super.init(frame: .zero)
        isVertical = axis.isVerticalSplitView
        dividerStyle = .thin
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `super.mouseDown` runs the divider's tracking loop synchronously and does not return until
    /// the mouse comes up, so bracketing it here is exactly the extent of the drag.
    ///
    /// This is what `TerminalMetalView.beginSynchronousResize` exists for: a divider drag is not a
    /// *window* resize, so `inLiveResize` is false throughout and, without this, Core Animation
    /// stretches each pane's previous texture across its new bounds for the whole drag.
    override func mouseDown(with event: NSEvent) {
        let targets = synchronousResizeTargets()
        targets.forEach { $0.beginSynchronousResize() }
        defer {
            targets.forEach { $0.endSynchronousResize() }
            reportRatio()
        }
        super.mouseDown(with: event)
    }

    private func reportRatio() {
        guard arrangedSubviews.count == 2 else { return }
        let first = arrangedSubviews[0].frame
        let total = axis == .horizontal
            ? bounds.width - dividerThickness : bounds.height - dividerThickness
        guard total > 0 else { return }
        let ratio = Double((axis == .horizontal ? first.width : first.height) / total)
        onRatioChanged?(anchorLeaf, anchorLevels, ratio)
    }

    // MARK: NSSplitViewDelegate

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat,
        ofSubviewAt index: Int
    ) -> CGFloat {
        max(proposedMin, SplitMetrics.minPaneSide)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat,
        ofSubviewAt index: Int
    ) -> CGFloat {
        let extent = axis == .horizontal ? bounds.width : bounds.height
        return min(proposedMax, extent - SplitMetrics.minPaneSide - dividerThickness)
    }
}

// MARK: - The container

/// Holds the tree for one tab and rebuilds it in place as the tree changes.
public final class PaneContainerView: NSView {
    /// Makes (or returns) the view for a pane. The window supplies a real `TerminalMetalView`;
    /// tests supply a plain focusable `NSView`.
    var viewForTerminal: (TerminalID) -> NSView = { _ in NSView() }
    /// A settled divider drag: `(anchor leaf, levels above it, the first child's new share)`.
    var onRatioChanged: ((TerminalID, Int, Double) -> Void)?

    /// What is on screen right now, in reading order. `nil` root means nothing is shown.
    private(set) var terminalIDs: [TerminalID] = []
    /// The shape the current view tree was built from, so an unchanged tree is not rebuilt.
    private var builtTab: Tab?
    private var rootView: NSView?
    private var splitViews: [PaneSplitView] = []

    public override var isFlipped: Bool { true }

    /// The view showing `id`, if it is on screen.
    public func paneView(for id: TerminalID) -> NSView? { paneViews[id] }
    private var paneViews: [TerminalID: NSView] = [:]

    /// Rebuilds the tree for `tab`, reusing every pane view it already has.
    ///
    /// Reuse is the point: a pane's view carries its surface, and re-creating one detaches and
    /// re-attaches it, which is a full rebuild of that pane's grid. Splitting the pane on the left
    /// must not flash the pane on the right.
    ///
    /// Returns whether the tree was rebuilt. A caller that needs the first responder back after a
    /// rebuild (every view left the window and came back) keys off it.
    @discardableResult
    func apply(_ tab: Tab?) -> Bool {
        guard let tab else {
            teardown()
            return false
        }
        // A tab whose *shape* is unchanged needs nothing: `layout()` keeps the frames honest and
        // `applyRatios` places the dividers. Focus and ratios are not shape — comparing the whole
        // `Tab` here rebuilt the tree on every click and every divider drag, and a rebuild takes
        // the focused view out of the window, which is how a pane stopped taking keys.
        if let built = builtTab, built.hasSameShape(as: tab) {
            builtTab = tab
            return false
        }
        builtTab = tab

        let visible = tab.visibleTerminalIDs
        terminalIDs = visible

        // Drop the views of panes that are no longer on screen — a closed pane, or every sibling
        // of a zoomed one. Their surfaces detach with them, which is what makes a hidden pane free.
        for (id, view) in paneViews where !visible.contains(id) {
            view.removeFromSuperview()
            paneViews[id] = nil
        }

        splitViews.removeAll(keepingCapacity: true)
        lastApplied.removeAll(keepingCapacity: true)
        rootView?.removeFromSuperview()

        let root: NSView
        if let zoomed = tab.zoomedLeaf, tab.root.contains(zoomed) {
            root = paneView(making: zoomed)
        } else {
            root = build(tab.root)
        }
        rootView = root
        root.translatesAutoresizingMaskIntoConstraints = true
        root.frame = bounds
        root.autoresizingMask = [.width, .height]
        addSubview(root)
        needsLayout = true
        return true
    }

    private func teardown() {
        rootView?.removeFromSuperview()
        rootView = nil
        splitViews.removeAll()
        for view in paneViews.values { view.removeFromSuperview() }
        paneViews.removeAll()
        terminalIDs = []
        builtTab = nil
    }

    /// The view for a pane, created once and kept.
    private func paneView(making id: TerminalID) -> NSView {
        if let existing = paneViews[id] { return existing }
        let view = viewForTerminal(id)
        paneViews[id] = view
        return view
    }

    private func build(_ node: PaneNode) -> NSView {
        switch node {
        case .leaf(let pane):
            return paneView(making: pane.id)

        case .split(let split):
            // The anchor is the first leaf below this node; `anchorLevels` is how far above that
            // leaf this split sits, which is exactly what `AppState.setRatio` takes. It has to be
            // measured along the path to *that* leaf — `depth` is a max over both children, so a
            // right-heavy subtree would report a level nothing sits at.
            let anchor = split.first.firstLeafID
            let levels = node.ancestorDistance(of: anchor) ?? 0
            let view = PaneSplitView(axis: split.axis, anchorLeaf: anchor, anchorLevels: levels)
            view.onRatioChanged = { [weak self] leaf, levels, ratio in
                self?.onRatioChanged?(leaf, levels, ratio)
            }
            view.synchronousResizeTargets = { [weak view] in
                guard let view else { return [] }
                return PaneContainerView.metalViews(under: view)
            }
            let first = build(split.first)
            let second = build(split.second)
            for child in [first, second] {
                child.translatesAutoresizingMaskIntoConstraints = true
                view.addArrangedSubview(child)
            }
            splitViews.append(view)
            return view
        }
    }

    static func metalViews(under view: NSView) -> [TerminalMetalView] {
        var out: [TerminalMetalView] = []
        if let metal = view as? TerminalMetalView { out.append(metal) }
        for child in view.subviews { out.append(contentsOf: metalViews(under: child)) }
        return out
    }

    // MARK: Placing the dividers

    /// Places every divider from the model's ratios.
    ///
    /// Store→view, and it must be idempotent: `applyRatios` is called on every layout and every
    /// layout delivery, and re-placing a divider the user just dragged is exactly the snap-back
    /// bug `MainSplitViewController` documents. `lastApplied` is the guard.
    func applyRatios(_ tab: Tab?) {
        guard let tab, tab.zoomedLeaf == nil else { return }
        layoutSubtreeIfNeeded()
        for split in splitViews {
            guard let ratio = ratio(in: tab.root, above: split.anchorLeaf, levels: split.anchorLevels)
            else { continue }
            let key = SplitKey(leaf: split.anchorLeaf, levels: split.anchorLevels)
            let last = lastApplied[key]
            if let last, abs(last - ratio) < SplitMetrics.ratioEpsilon { continue }
            let extent = split.axis == .horizontal ? split.bounds.width : split.bounds.height
            let usable = extent - split.dividerThickness
            guard usable > 0 else { continue }
            lastApplied[key] = ratio
            isApplyingStoreState = true
            appliedRatioCount += 1
            split.setPosition(usable * CGFloat(ratio), ofDividerAt: 0)
            isApplyingStoreState = false
        }
    }

    /// How many times a divider has been re-placed from the store. A drag that snaps back is
    /// exactly "this went up when nothing about the ratio changed", so the regression test counts it.
    private(set) var appliedRatioCount = 0
    /// True while `applyRatios` is placing dividers, so a resize notification it causes is not
    /// reported back as a user drag.
    private(set) var isApplyingStoreState = false
    /// A split is named by its anchor leaf *and* how far above it it sits: every split on the
    /// leftmost path shares the same first leaf, so the leaf alone is not a key.
    private struct SplitKey: Hashable {
        var leaf: TerminalID
        var levels: Int
    }
    private var lastApplied: [SplitKey: Double] = [:]

    /// The ratio of the split `levels` above `leaf` — the same addressing
    /// `AppState.setRatio(above:levels:to:)` uses, read back.
    private func ratio(in node: PaneNode, above leaf: TerminalID, levels: Int) -> Double? {
        guard case .split(let split) = node else { return nil }
        if node.ancestorDistance(of: leaf) == levels { return split.ratio }
        return ratio(in: split.first, above: leaf, levels: levels)
            ?? ratio(in: split.second, above: leaf, levels: levels)
    }

    public override func layout() {
        super.layout()
        rootView?.frame = bounds
    }
}
