// Panes and tabs — the tree, its geometry, its wire form and its reducers (TKZ-36).

import CoreGraphics
import Foundation
import Testing

@testable import TkzCore

// MARK: - Fixtures

/// A session with a known tree, built from a shape description so a test reads as its layout.
private func makeState(
    tree: PaneNode, focused: TerminalID? = nil
) -> (AppState, SessionID) {
    var state = AppState()
    let group = state.addGroup(name: "G", repoRoot: "/repo")
    let session = state.createSession(groupID: group.id, cwd: "/repo")
    let tab = Tab(id: .generate(), root: tree, focusedLeaf: focused ?? tree.firstLeafID)
    state.sessions[session.id]?.tabs = [tab]
    state.sessions[session.id]?.activeTab = tab.id
    state.sessions[session.id]?.live = LiveSessionState()
    return (state, session.id)
}

private func terminals(_ count: Int) -> [TerminalID] {
    (0..<count).map { _ in TerminalID.generate() }
}

// MARK: - The tree

@Suite struct PaneTreeTests {

    @Test func leafIDsAreInReadingOrder() {
        let t = terminals(3)
        // t0 | (t1 stacked over t2)
        let tree = PaneNode.split(
            PaneSplit(
                axis: .horizontal, ratio: 0.5, first: .leaf(t[0]),
                second: .split(
                    PaneSplit(axis: .vertical, ratio: 0.5, first: .leaf(t[1]), second: .leaf(t[2])))
            ))
        #expect(tree.leafIDs == [t[0], t[1], t[2]])
        #expect(tree.leafCount == 3)
        #expect(tree.firstLeafID == t[0])
        #expect(tree.depth == 2)
    }

    /// The split container rebuilds its views only when this says so. A divider drag changes a
    /// ratio and a click changes the focused leaf; neither moves a view, so neither is a shape
    /// change. A different axis, leaf, zoom or tab is.
    @Test func hasSameShapeIgnoresRatioAndFocus() {
        let t = terminals(3)
        let tabID = TabID.generate()
        func tab(
            ratio: Double = 0.5, axis: PaneAxis = .horizontal, second: TerminalID,
            focused: TerminalID, zoomed: TerminalID? = nil
        ) -> Tab {
            Tab(
                id: tabID,
                root: .split(
                    PaneSplit(axis: axis, ratio: ratio, first: .leaf(t[0]), second: .leaf(second))),
                focusedLeaf: focused, zoomedLeaf: zoomed)
        }
        let base = tab(second: t[1], focused: t[0])
        #expect(base.hasSameShape(as: tab(ratio: 0.3, second: t[1], focused: t[0])))
        #expect(base.hasSameShape(as: tab(second: t[1], focused: t[1])))
        #expect(!base.hasSameShape(as: tab(axis: .vertical, second: t[1], focused: t[0])))
        #expect(!base.hasSameShape(as: tab(second: t[2], focused: t[0])))
        #expect(!base.hasSameShape(as: tab(second: t[1], focused: t[0], zoomed: t[0])))
        #expect(!base.hasSameShape(as: Tab(id: .generate(), root: base.root, focusedLeaf: t[0])))
        #expect(!base.root.hasSameShape(as: .leaf(t[0])))
    }

    @Test func framesDivideTheRectangleByRatio() {
        let t = terminals(2)
        let tree = PaneNode.split(
            PaneSplit(axis: .horizontal, ratio: 0.25, first: .leaf(t[0]), second: .leaf(t[1])))
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 400, height: 100))
        #expect(frames[t[0]] == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(frames[t[1]] == CGRect(x: 100, y: 0, width: 300, height: 100))
    }

    /// A `.vertical` split stacks, and the *first* child is the top one — the property every
    /// directional-focus test below leans on.
    @Test func aVerticalSplitPutsTheFirstChildOnTop() {
        let t = terminals(2)
        let tree = PaneNode.split(
            PaneSplit(axis: .vertical, ratio: 0.5, first: .leaf(t[0]), second: .leaf(t[1])))
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 100, height: 200))
        #expect(frames[t[0]]?.minY == 100)
        #expect(frames[t[1]]?.minY == 0)
    }

    @Test func theDividerIsSubtractedBeforeTheSplit() {
        let t = terminals(2)
        let tree = PaneNode.split(
            PaneSplit(axis: .horizontal, ratio: 0.5, first: .leaf(t[0]), second: .leaf(t[1])))
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 101, height: 10), divider: 1)
        #expect(frames[t[0]]?.width == 50)
        #expect(frames[t[1]]?.width == 50)
        #expect(frames[t[1]]?.minX == 51)
    }

    @Test func nestedFramesTileTheWholeRectangle() {
        let t = terminals(3)
        let tree = PaneNode.split(
            PaneSplit(
                axis: .horizontal, ratio: 0.5, first: .leaf(t[0]),
                second: .split(
                    PaneSplit(axis: .vertical, ratio: 0.5, first: .leaf(t[1]), second: .leaf(t[2])))
            ))
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 200, height: 200))
        let area = frames.values.reduce(0) { $0 + $1.width * $1.height }
        #expect(area == CGFloat(200 * 200))
    }

    @Test func ratiosAreClampedAndNaNBecomesTheMidpoint() {
        #expect(PaneSplit.clamp(0.5) == 0.5)
        #expect(PaneSplit.clamp(-3) == PaneSplit.ratioRange.lowerBound)
        #expect(PaneSplit.clamp(42) == PaneSplit.ratioRange.upperBound)
        #expect(PaneSplit.clamp(.nan) == 0.5)
        #expect(PaneSplit.clamp(.infinity) == 0.5)
    }

    @Test func equalizeWeightsBySubtreeLeafCount() {
        let t = terminals(3)
        // 1 | (2 | 3): the root must give the left pane a third, not a half.
        var tree = PaneNode.split(
            PaneSplit(
                axis: .horizontal, ratio: 0.8, first: .leaf(t[0]),
                second: .split(
                    PaneSplit(
                        axis: .horizontal, ratio: 0.9, first: .leaf(t[1]), second: .leaf(t[2])))))
        tree.equalize()
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 300, height: 10))
        #expect(frames[t[0]]?.width == 100)
        #expect(frames[t[1]]?.width == 100)
        #expect(frames[t[2]]?.width == 100)
    }

    @Test func ancestorDistanceCountsSplitsNotLeaves() {
        let t = terminals(3)
        let tree = PaneNode.split(
            PaneSplit(
                axis: .horizontal, ratio: 0.5, first: .leaf(t[0]),
                second: .split(
                    PaneSplit(axis: .vertical, ratio: 0.5, first: .leaf(t[1]), second: .leaf(t[2])))
            ))
        #expect(tree.ancestorDistance(of: t[0]) == 0)   // immediate child of the root split
        #expect(tree.ancestorDistance(of: t[1]) == 1)   // grandchild
        #expect(tree.ancestorDistance(of: TerminalID.generate()) == nil)
    }
}

// MARK: - Codable

@Suite struct PaneCodableTests {

    /// The wire form is a contract, not whatever the compiler synthesises. Assert the literal keys.
    @Test func theWireFormIsTheDocumentedOne() throws {
        let leaf = TerminalID.generate()
        let other = TerminalID.generate()
        let tree = PaneNode.split(
            PaneSplit(axis: .horizontal, ratio: 0.25, first: .leaf(leaf), second: .leaf(other)))

        let data = try JSONEncoder().encode(tree)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "split")
        #expect(object["axis"] as? String == "horizontal")
        #expect(object["ratio"] as? Double == 0.25)
        let first = try #require(object["first"] as? [String: Any])
        #expect(first["kind"] as? String == "leaf")
        #expect(first["id"] as? String == leaf.rawValue)
        #expect(first["axis"] == nil)
    }

    @Test(arguments: [1, 2, 5]) func treesOfEveryShapeRoundTrip(depth: Int) throws {
        var tree = PaneNode.leaf(TerminalID.generate())
        for level in 0..<depth {
            tree = .split(
                PaneSplit(
                    axis: level.isMultiple(of: 2) ? .horizontal : .vertical,
                    ratio: 0.3 + Double(level) * 0.1,
                    first: tree,
                    second: .leaf(TerminalID.generate())))
        }
        let decoded = try JSONDecoder().decode(
            PaneNode.self, from: JSONEncoder().encode(tree))
        #expect(decoded == tree)
    }

    @Test func aTabRoundTripsWithItsFocusAndZoom() throws {
        let t = terminals(2)
        var tab = Tab(
            id: .generate(),
            root: .split(
                PaneSplit(axis: .vertical, ratio: 0.4, first: .leaf(t[0]), second: .leaf(t[1]))),
            focusedLeaf: t[1])
        tab.zoomedLeaf = t[1]
        let decoded = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))
        #expect(decoded == tab)
    }

    /// A hand-edited file must not be able to overflow the stack on the way in.
    ///
    /// Nests on **one** side only, with a cheap leaf on the other: nesting both sides doubles the
    /// JSON string's length at every level, so 200 levels of *that* is 2^200 bytes rather than 200
    /// nested objects — the test hung the process before it ever reached the decoder.
    @Test func aTreeNestedTooDeeplyIsRejectedRatherThanCrashing() throws {
        let leaf = #"{"kind":"leaf","id":"\#(TerminalID.generate().rawValue)"}"#
        var json = leaf
        for _ in 0..<200 {
            json = #"{"kind":"split","axis":"horizontal","ratio":0.5,"first":\#(json),"second":\#(leaf)}"#
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PaneNode.self, from: Data(json.utf8))
        }
    }
}

// MARK: - Session defaults

@Suite struct SessionLayoutTests {

    /// The invariant the whole migration rests on: a session's first terminal, and its first tab,
    /// carry the session's own uuid. `Migrations.liftV1ToV2` produces exactly this, which is why
    /// no `.ghsnap` had to be renamed.
    @Test func aNewSessionHasOneLeafCarryingItsOwnUUID() {
        let session = Session(groupID: .generate(), cwd: "/tmp", accountKey: "claude")
        #expect(session.terminalIDs == [TerminalID(uuid: session.id.uuid)])
        #expect(session.activeTab == TabID(uuid: session.id.uuid))
        #expect(session.focusedTerminalID == TerminalID(uuid: session.id.uuid))
        #expect(session.terminalCount == 1)
    }

    @Test func layoutShapeIgnoresEverythingThatIsNotTheTree() {
        var a = Session(groupID: .generate(), cwd: "/tmp", accountKey: "claude")
        var b = a
        b.title = "renamed"
        b.live = LiveSessionState(shellPid: 42, paneCwds: [a.focusedTerminalID: "/elsewhere"])
        #expect(a.hasSameLayoutShape(as: b))

        a.tabs[0].root = .split(
            PaneSplit(
                axis: .horizontal, ratio: 0.5, first: a.tabs[0].root,
                second: .leaf(TerminalID.generate())))
        #expect(!a.hasSameLayoutShape(as: b))
    }

    @Test func aRatioChangeIsALayoutChange() {
        var a = Session(groupID: .generate(), cwd: "/tmp", accountKey: "claude")
        a.tabs[0].root = .split(
            PaneSplit(
                axis: .horizontal, ratio: 0.5, first: a.tabs[0].root,
                second: .leaf(TerminalID.generate())))
        var b = a
        guard case .split(var split) = b.tabs[0].root else { Issue.record("not a split"); return }
        split.ratio = 0.7
        b.tabs[0].root = .split(split)
        #expect(!a.hasSameLayoutShape(as: b))
    }
}

// MARK: - Reducers

@Suite struct PaneReducerTests {

    @Test func splitFocusesTheNewPaneAndClearsZoom() throws {
        let root = TerminalID.generate()
        var (state, id) = makeState(tree: .leaf(root))
        state.zoomPane(root, in: id)
        #expect(state.sessions[id]?.activeTabValue.zoomedLeaf == root)

        let split = state.splitPane(root, axis: .horizontal)
        let new = try #require(split)
        let session = try #require(state.sessions[id])
        #expect(session.terminalCount == 2)
        #expect(session.focusedTerminalID == new)
        // Splitting a zoomed pane would otherwise be invisible.
        #expect(session.activeTabValue.zoomedLeaf == nil)
    }

    @Test func splitRefusesPastTheCap() {
        let root = TerminalID.generate()
        var (state, _) = makeState(tree: .leaf(root))
        var last = root
        for _ in 1..<AppState.maxPanesPerTab {
            last = state.splitPane(last, axis: .horizontal)!
        }
        let overflow = state.splitPane(last, axis: .horizontal)
        #expect(overflow == nil)
    }

    /// The rule that is easiest to get wrong: the sibling inherits the closed pane's rectangle
    /// wholesale, and nothing above it moves.
    @Test func closingCollapsesIntoTheSiblingAndLeavesTheGrandparentAlone() throws {
        let t = terminals(3)
        // t0 | (t1 | t2), with a deliberately lopsided root ratio.
        let tree = PaneNode.split(
            PaneSplit(
                axis: .horizontal, ratio: 0.25, first: .leaf(t[0]),
                second: .split(
                    PaneSplit(
                        axis: .vertical, ratio: 0.5, first: .leaf(t[1]), second: .leaf(t[2])))))
        var (state, id) = makeState(tree: tree)

        let closed = state.closePane(t[1])
        #expect(closed)
        let session = try #require(state.sessions[id])
        #expect(session.terminalIDs == [t[0], t[2]])

        guard case .split(let root) = session.activeTabValue.root else {
            Issue.record("root is no longer a split")
            return
        }
        #expect(root.ratio == 0.25)          // untouched
        #expect(root.second == .leaf(t[2]))  // the sibling took the whole subtree
    }

    @Test func closingTheFocusedPaneMovesFocusToTheSibling() throws {
        let t = terminals(2)
        let tree = PaneNode.split(
            PaneSplit(axis: .horizontal, ratio: 0.5, first: .leaf(t[0]), second: .leaf(t[1])))
        var (state, id) = makeState(tree: tree, focused: t[1])
        let closed = state.closePane(t[1])
        #expect(closed)
        #expect(state.sessions[id]?.focusedTerminalID == t[0])
    }

    /// Not a failure — this is how `SessionLauncher` learns the row itself has to go.
    @Test func closingTheLastPaneOfTheLastTabRefusesAndChangesNothing() throws {
        let root = TerminalID.generate()
        var (state, id) = makeState(tree: .leaf(root))
        let before = state.sessions[id]

        let closed = state.closePane(root)
        #expect(closed == false)
        #expect(state.sessions[id] == before)
    }

    @Test func closingTheLastPaneOfANonLastTabDropsTheTab() throws {
        let root = TerminalID.generate()
        var (state, id) = makeState(tree: .leaf(root))
        let added = state.addTab(to: id)
        let second = try #require(added)
        #expect(state.sessions[id]?.tabs.count == 2)
        #expect(state.sessions[id]?.activeTab == state.sessions[id]?.tabs[1].id)

        let closed = state.closePane(second)
        #expect(closed)
        let session = try #require(state.sessions[id])
        #expect(session.tabs.count == 1)
        // The active tab fell back to the surviving one rather than dangling.
        #expect(session.activeTab == session.tabs[0].id)
        #expect(session.terminalIDs == [root])
    }

    @Test func closingATabTakesEveryPaneWithIt() throws {
        let root = TerminalID.generate()
        var (state, id) = makeState(tree: .leaf(root))
        let added = state.addTab(to: id)
        let second = try #require(added)
        let secondTab = try #require(state.sessions[id]?.tabs[1].id)
        _ = state.splitPane(second, axis: .horizontal)
        #expect(state.sessions[id]?.terminalCount == 3)

        let closed = state.closeTab(secondTab)
        #expect(closed)
        #expect(state.sessions[id]?.terminalIDs == [root])
    }

    @Test func closingTheLastTabRefuses() throws {
        let root = TerminalID.generate()
        var (state, id) = makeState(tree: .leaf(root))
        let only = try #require(state.sessions[id]?.tabs[0].id)
        let closed = state.closeTab(only)
        #expect(closed == false)
        #expect(state.sessions[id]?.tabs.count == 1)
    }

    @Test func adjacentTabWraps() throws {
        let root = TerminalID.generate()
        var (state, id) = makeState(tree: .leaf(root))
        _ = state.addTab(to: id)
        _ = state.addTab(to: id)
        let tabs = try #require(state.sessions[id]?.tabs.map(\.id))

        state.selectTab(tabs[0])
        state.selectAdjacentTab(in: id, offset: -1)
        #expect(state.sessions[id]?.activeTab == tabs[2])   // wrapped backwards
        state.selectAdjacentTab(in: id, offset: 1)
        #expect(state.sessions[id]?.activeTab == tabs[0])   // and forwards
    }

    @Test func focusingAPaneOnAnotherTabAlsoSelectsThatTab() throws {
        let root = TerminalID.generate()
        var (state, id) = makeState(tree: .leaf(root))
        _ = state.addTab(to: id)
        state.focusPane(root)
        let session = try #require(state.sessions[id])
        #expect(session.activeTab == session.tabs[0].id)
        #expect(session.focusedTerminalID == root)
    }

    @Test func setRatioClampsAndAddressesTheParentSplit() throws {
        let t = terminals(2)
        let tree = PaneNode.split(
            PaneSplit(axis: .horizontal, ratio: 0.5, first: .leaf(t[0]), second: .leaf(t[1])))
        var (state, id) = makeState(tree: tree)

        state.setRatio(above: t[0], to: 0.3)
        guard case .split(let split)? = state.sessions[id]?.activeTabValue.root else {
            Issue.record("not a split")
            return
        }
        #expect(split.ratio == 0.3)

        state.setRatio(above: t[0], to: 99)
        guard case .split(let clamped)? = state.sessions[id]?.activeTabValue.root else { return }
        #expect(clamped.ratio == PaneSplit.ratioRange.upperBound)

        state.setRatio(above: t[0], to: .nan)
        guard case .split(let nan)? = state.sessions[id]?.activeTabValue.root else { return }
        #expect(nan.ratio == 0.5)
    }

    @Test func setRatioReachesAGrandparent() throws {
        let t = terminals(3)
        let tree = PaneNode.split(
            PaneSplit(
                axis: .horizontal, ratio: 0.5, first: .leaf(t[0]),
                second: .split(
                    PaneSplit(axis: .vertical, ratio: 0.5, first: .leaf(t[1]), second: .leaf(t[2])))
            ))
        var (state, id) = makeState(tree: tree)
        state.setRatio(above: t[1], levels: 1, to: 0.2)
        guard case .split(let root)? = state.sessions[id]?.activeTabValue.root else { return }
        #expect(root.ratio == 0.2)
        guard case .split(let inner) = root.second else { return }
        #expect(inner.ratio == 0.5)   // the immediate parent is untouched
    }

    @Test func zoomTogglesAndFocuses() throws {
        let t = terminals(2)
        let tree = PaneNode.split(
            PaneSplit(axis: .horizontal, ratio: 0.5, first: .leaf(t[0]), second: .leaf(t[1])))
        var (state, id) = makeState(tree: tree, focused: t[0])

        state.zoomPane(t[1], in: id)
        #expect(state.sessions[id]?.activeTabValue.zoomedLeaf == t[1])
        #expect(state.sessions[id]?.focusedTerminalID == t[1])
        #expect(state.sessions[id]?.visibleTerminalIDs == [t[1]])

        state.zoomPane(t[1], in: id)
        #expect(state.sessions[id]?.activeTabValue.zoomedLeaf == nil)
        #expect(state.sessions[id]?.visibleTerminalIDs == [t[0], t[1]])
    }

    @Test func perPaneLiveStateIsKeptAndCleanedUp() throws {
        let root = TerminalID.generate()
        var (state, id) = makeState(tree: .leaf(root))
        let split = state.splitPane(root, axis: .horizontal)
        let new = try #require(split)

        state.setPaneCwd(new, path: "/repo/sub")
        state.setPanePid(new, pid: 4321)
        #expect(state.paneCwd(new) == "/repo/sub")
        #expect(state.sessions[id]?.live?.panePids[new] == 4321)

        // An empty path means "unknown", like `setShellCwd`.
        state.setPaneCwd(new, path: "")
        #expect(state.paneCwd(new) == nil)

        state.setPaneCwd(new, path: "/repo/sub")
        let closed = state.closePane(new)
        #expect(closed)
        #expect(state.sessions[id]?.live?.paneCwds[new] == nil)
        #expect(state.sessions[id]?.live?.panePids[new] == nil)
    }

    @Test func unknownIDsAreNoOps() {
        let root = TerminalID.generate()
        var (state, _) = makeState(tree: .leaf(root))
        let before = state
        let stranger = TerminalID.generate()
        let split = state.splitPane(stranger, axis: .horizontal)
        #expect(split == nil)
        let closed = state.closePane(stranger)
        #expect(closed == false)
        state.focusPane(stranger)
        state.setRatio(above: stranger, to: 0.3)
        state.setPaneCwd(stranger, path: "/x")
        #expect(state == before)
    }
}

// MARK: - Directional focus

@Suite struct PaneFocusMovementTests {

    /// One tall pane on the left, two stacked on the right — the layout that makes the
    /// overlap tie-break earn its place.
    private func oneLeftTwoRight() -> (AppState, SessionID, [TerminalID]) {
        let t = terminals(3)
        let tree = PaneNode.split(
            PaneSplit(
                axis: .horizontal, ratio: 0.5, first: .leaf(t[0]),
                second: .split(
                    PaneSplit(axis: .vertical, ratio: 0.5, first: .leaf(t[1]), second: .leaf(t[2])))
            ))
        let (state, id) = makeState(tree: tree)
        return (state, id, t)
    }

    @Test func bothRightPanesReachTheSingleLeftOne() throws {
        var (state, id, t) = oneLeftTwoRight()
        for right in [t[1], t[2]] {
            state.focusPane(right)
            let moved = state.focusPaneInDirection(.left, in: id)
            #expect(moved == t[0])
        }
    }

    /// From the tall left pane, "right" is ambiguous by distance alone — both right panes start at
    /// the same x. Overlap breaks it, and with equal overlap the lower edge wins deterministically.
    @Test func movingRightFromTheTallPaneIsDeterministic() throws {
        var (state, id, t) = oneLeftTwoRight()
        state.focusPane(t[0])
        let first = state.focusPaneInDirection(.right, in: id)
        #expect(first == t[2])   // the lower of the two, by the documented tie-break
        state.focusPane(t[0])
        let again = state.focusPaneInDirection(.right, in: id)
        #expect(again == first)   // and it is stable
    }

    @Test func upAndDownWalkTheStack() throws {
        var (state, id, t) = oneLeftTwoRight()
        state.focusPane(t[2])
        let up = state.focusPaneInDirection(.up, in: id)
        #expect(up == t[1])
        let down = state.focusPaneInDirection(.down, in: id)
        #expect(down == t[2])
    }

    /// No wrap — deliberately unlike `selectAdjacentSession`, which wraps because a flat list has
    /// no edges.
    @Test func anArrowAtTheEdgeDoesNothing() throws {
        var (state, id, t) = oneLeftTwoRight()
        state.focusPane(t[0])
        let left = state.focusPaneInDirection(.left, in: id)
        #expect(left == nil)
        #expect(state.sessions[id]?.focusedTerminalID == t[0])
        state.focusPane(t[1])
        let up = state.focusPaneInDirection(.up, in: id)
        #expect(up == nil)
    }

    @Test func aTwoByTwoGridMovesOnBothAxes() throws {
        let t = terminals(4)
        // (t0 over t1) | (t2 over t3)
        let tree = PaneNode.split(
            PaneSplit(
                axis: .horizontal, ratio: 0.5,
                first: .split(
                    PaneSplit(axis: .vertical, ratio: 0.5, first: .leaf(t[0]), second: .leaf(t[1]))),
                second: .split(
                    PaneSplit(axis: .vertical, ratio: 0.5, first: .leaf(t[2]), second: .leaf(t[3])))
            ))
        var (state, id) = makeState(tree: tree)

        state.focusPane(t[0])
        let right = state.focusPaneInDirection(.right, in: id)
        #expect(right == t[2])
        let down = state.focusPaneInDirection(.down, in: id)
        #expect(down == t[3])
        let left = state.focusPaneInDirection(.left, in: id)
        #expect(left == t[1])
        let up = state.focusPaneInDirection(.up, in: id)
        #expect(up == t[0])
    }

    @Test func aZoomedTabDoesNotMoveFocus() throws {
        var (state, id, t) = oneLeftTwoRight()
        state.focusPane(t[0])
        state.zoomPane(t[0], in: id)
        let moved = state.focusPaneInDirection(.right, in: id)
        #expect(moved == nil)
    }

    @Test func aSinglePaneHasNowhereToGo() throws {
        let root = TerminalID.generate()
        var (state, id) = makeState(tree: .leaf(root))
        for direction in PaneDirection.allCases {
            let moved = state.focusPaneInDirection(direction, in: id)
            #expect(moved == nil)
        }
    }
}

// MARK: - Repair

@Suite struct PaneHygieneTests {

    private func normalize(_ session: inout Session) -> [String] {
        var terminals: Set<TerminalID> = []
        var tabs: Set<TabID> = []
        return session.normalizeLayout(claimedTerminals: &terminals, claimedTabs: &tabs)
    }

    @Test func aSessionWithNoTabsGetsOne() {
        var session = Session(groupID: .generate(), cwd: "/tmp", accountKey: "claude")
        session.tabs = []
        let warnings = normalize(&session)
        #expect(session.tabs.count == 1)
        #expect(session.terminalIDs == [TerminalID(uuid: session.id.uuid)])
        #expect(warnings.contains { $0.contains("has no tabs") })
    }

    /// A terminal id is a `.ghsnap` basename, so it has to be unique across the whole file — not
    /// just within a row. Regenerating costs one saved screen; dropping the row would cost a
    /// conversation.
    @Test func aDuplicateTerminalIsRegeneratedRatherThanDropped() {
        let shared = TerminalID.generate()
        var a = Session(groupID: .generate(), cwd: "/a", accountKey: "claude")
        var b = Session(groupID: .generate(), cwd: "/b", accountKey: "claude")
        a.tabs = [Tab.single(shared)]
        a.activeTab = a.tabs[0].id
        b.tabs = [Tab.single(shared)]
        b.activeTab = b.tabs[0].id

        var terminals: Set<TerminalID> = []
        var tabs: Set<TabID> = []
        _ = a.normalizeLayout(claimedTerminals: &terminals, claimedTabs: &tabs)
        let warnings = b.normalizeLayout(claimedTerminals: &terminals, claimedTabs: &tabs)

        #expect(a.terminalIDs == [shared])
        #expect(b.terminalIDs != [shared])
        #expect(b.terminalCount == 1)
        #expect(b.focusedTerminalID == b.terminalIDs[0])   // focus followed the new id
        #expect(warnings.contains { $0.contains("appears twice") })
    }

    @Test func aFocusOutsideItsTabIsMovedToTheFirstLeaf() {
        var session = Session(groupID: .generate(), cwd: "/tmp", accountKey: "claude")
        let real = session.terminalIDs[0]
        session.tabs[0].focusedLeaf = TerminalID.generate()
        let warnings = normalize(&session)
        #expect(session.focusedTerminalID == real)
        #expect(warnings.contains { $0.contains("focuses a pane it does not contain") })
    }

    @Test func anUnknownActiveTabFallsBackToTheFirst() {
        var session = Session(groupID: .generate(), cwd: "/tmp", accountKey: "claude")
        session.activeTab = .generate()
        let warnings = normalize(&session)
        #expect(session.activeTab == session.tabs[0].id)
        #expect(warnings.contains { $0.contains("unknown active tab") })
    }

    /// Losing a zoom is not something a user notices; every other repair here is.
    @Test func aDanglingZoomIsClearedSilently() {
        var session = Session(groupID: .generate(), cwd: "/tmp", accountKey: "claude")
        session.tabs[0].zoomedLeaf = TerminalID.generate()
        let warnings = normalize(&session)
        #expect(session.tabs[0].zoomedLeaf == nil)
        #expect(warnings.isEmpty)
    }

    @Test func aDuplicateTabIDIsRenumbered() {
        var session = Session(groupID: .generate(), cwd: "/tmp", accountKey: "claude")
        let shared = session.tabs[0].id
        session.tabs.append(Tab(id: shared, root: .leaf(TerminalID.generate()), focusedLeaf: session.terminalIDs[0]))
        session.tabs[1].focusedLeaf = session.tabs[1].root.firstLeafID
        let warnings = normalize(&session)
        #expect(Set(session.tabs.map(\.id)).count == 2)
        #expect(warnings.contains { $0.contains("appears twice; renumbered") })
    }

    @Test func aCleanSessionIsLeftAloneAndSaysNothing() {
        var session = Session(groupID: .generate(), cwd: "/tmp", accountKey: "claude")
        let before = session
        let warnings = normalize(&session)
        #expect(warnings.isEmpty)
        #expect(session == before)
    }
}
