// Panes and tabs — the split tree a session's content area is laid out from (TKZ-36).
//
// A session owns an ordered list of `Tab`s; each tab owns a strictly **binary** tree of panes.
// Binary is a deliberate constraint: with an N-ary node every operation here (`setRatio`,
// `equalizeSplits`, directional focus, collapse-on-close) needs an extra child index to say
// *which* divider or sibling it means, and collapse-on-close stops being a local rewrite.
//
// Everything in this file is durable layout. A pane's *cwd* and *pid* are not: they live in
// `LiveSessionState.paneCwds` / `panePids` and are rebuilt at launch, keeping the 2026-09-08
// decision that a shell's working directory is process state (see `LiveSessionState.shellCwd`).

import CoreGraphics
import Foundation

// MARK: - Identifiers

/// Identity of one terminal — one pty, one VT, one `.ghsnap`.
///
/// This, not `SessionID`, is the snapshot basename. `TKZMUX_SESSION_ID` still carries the **row's**
/// `SessionID`, so every pane of a row is one row to the shim, the hook relay and ClaudeBridge.
///
/// Every session migrated from schema v1 has exactly one leaf whose `uuid` **is** its
/// `SessionID.uuid` (see `Migrations.liftV1ToV2`). That is why no `<uuid>.ghsnap` had to be
/// renamed at the v2 bump, and why `TerminalHost.restoreAll` can default its owner lookup to
/// `SessionID(uuid: terminalID.uuid)`. New sessions keep the same invariant for their first leaf.
public struct TerminalID: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// Identity of one tab within a session.
public struct TabID: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

// MARK: - The tree

/// Which way a split divides its two children.
public enum PaneAxis: String, Hashable, Sendable, Codable, CaseIterable {
    /// Children side by side, divider vertical. `ratio` is the **first** (left) child's width share.
    /// This is what the toolbar's `◫` "Split vertically" button and ⌘D produce.
    case horizontal
    /// Children stacked, divider horizontal. `ratio` is the **first** (top) child's height share.
    /// The toolbar's `⬓` "Split horizontally" button and ⇧⌘D.
    case vertical

    public var opposite: PaneAxis { self == .horizontal ? .vertical : .horizontal }
}

/// One terminal in the tree. A leaf carries nothing but identity: everything else about a pane is
/// either live state (cwd, pid) or lives on the split above it (its share of the axis).
public struct Pane: Hashable, Sendable, Identifiable, Codable {
    public var id: TerminalID
    public init(id: TerminalID) { self.id = id }
}

/// An internal node: two children and the first one's share of the axis.
public struct PaneSplit: Hashable, Sendable {
    public var axis: PaneAxis
    /// The **first** child's share, clamped to `ratioRange`.
    public var ratio: Double
    public var first: PaneNode
    public var second: PaneNode

    /// A pane narrower than this is unusable, and a ratio outside it is almost always a corrupt
    /// file rather than an intent. The divider drag clamps to the same range.
    public static let ratioRange: ClosedRange<Double> = 0.1...0.9

    public init(axis: PaneAxis, ratio: Double = 0.5, first: PaneNode, second: PaneNode) {
        self.axis = axis
        self.ratio = PaneSplit.clamp(ratio)
        self.first = first
        self.second = second
    }

    /// Clamps into `ratioRange`, mapping a non-finite value to the midpoint rather than trapping:
    /// the only way to get one is a hand-edited `state.json`, and refusing to open the file over it
    /// would be worse than losing one divider position.
    public static func clamp(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 0.5 }
        return Swift.min(Swift.max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }
}

public indirect enum PaneNode: Hashable, Sendable {
    case leaf(Pane)
    case split(PaneSplit)

    public static func leaf(_ id: TerminalID) -> PaneNode { .leaf(Pane(id: id)) }
}

// MARK: - Reading the tree

extension PaneNode {
    /// Every terminal in the subtree, in reading order: left→right for a horizontal split,
    /// top→bottom for a vertical one. Also the tab order for anything that walks panes linearly.
    public var leafIDs: [TerminalID] {
        var out: [TerminalID] = []
        appendLeafIDs(into: &out)
        return out
    }

    private func appendLeafIDs(into out: inout [TerminalID]) {
        switch self {
        case .leaf(let pane): out.append(pane.id)
        case .split(let split):
            split.first.appendLeafIDs(into: &out)
            split.second.appendLeafIDs(into: &out)
        }
    }

    public var leafCount: Int {
        switch self {
        case .leaf: 1
        case .split(let split): split.first.leafCount + split.second.leafCount
        }
    }

    /// The first leaf in reading order. Never nil: a tree always has at least one leaf.
    public var firstLeafID: TerminalID {
        switch self {
        case .leaf(let pane): pane.id
        case .split(let split): split.first.firstLeafID
        }
    }

    public func contains(_ id: TerminalID) -> Bool {
        switch self {
        case .leaf(let pane): pane.id == id
        case .split(let split): split.first.contains(id) || split.second.contains(id)
        }
    }

    /// The maximum number of splits between this node and any leaf below it.
    public var depth: Int {
        switch self {
        case .leaf: 0
        case .split(let split): 1 + Swift.max(split.first.depth, split.second.depth)
        }
    }
}

// MARK: - Geometry

extension PaneNode {
    /// Lays the subtree out in `rect`, subtracting `divider` points between siblings.
    ///
    /// Pure, and deliberately in TkzCore rather than the view layer: it is what makes ⌘⌥-arrow
    /// focus movement a table-testable rule over a unit rectangle (`AppState.focusPaneInDirection`)
    /// instead of a guess made from live AppKit frames. The split container lays panes out with the
    /// same function, so the model and the screen cannot disagree.
    ///
    /// `rect` is in a **y-up** space: for a `.vertical` split the first child takes the top, i.e.
    /// the high y range. Callers in a flipped space flip once, at the top.
    public func frames(in rect: CGRect, divider: CGFloat = 0) -> [TerminalID: CGRect] {
        var out: [TerminalID: CGRect] = [:]
        appendFrames(in: rect, divider: divider, into: &out)
        return out
    }

    private func appendFrames(
        in rect: CGRect, divider: CGFloat, into out: inout [TerminalID: CGRect]
    ) {
        switch self {
        case .leaf(let pane):
            out[pane.id] = rect
        case .split(let split):
            let (a, b) = split.divide(rect, divider: divider)
            split.first.appendFrames(in: a, divider: divider, into: &out)
            split.second.appendFrames(in: b, divider: divider, into: &out)
        }
    }
}

extension PaneNode {
    /// Whether two trees have the same **shape**: the same leaves under the same axes, in the same
    /// order. The divider ratios do not count.
    ///
    /// This is what the split container asks before rebuilding its view tree. A ratio is placed by
    /// `applyRatios` inside the views that already exist; rebuilding for one would detach every
    /// surface and take the focused view out of the window, which drops the first responder.
    public func hasSameShape(as other: PaneNode) -> Bool {
        switch (self, other) {
        case (.leaf(let a), .leaf(let b)):
            return a.id == b.id
        case (.split(let a), .split(let b)):
            return a.axis == b.axis && a.first.hasSameShape(as: b.first)
                && a.second.hasSameShape(as: b.second)
        default:
            return false
        }
    }
}

extension PaneSplit {
    /// Splits `rect` into the first and second child's rectangles, y-up (see `PaneNode.frames`).
    ///
    /// Deliberately **exact**, not rounded to whole points: `focusPaneInDirection` lays the tree
    /// out in a 1×1 rectangle, where rounding would round every child to 0 or 1 and collapse the
    /// geometry it is reasoning about. Rounding for crisp pixels is the view layer's job, at the
    /// one place it puts a divider.
    public func divide(_ rect: CGRect, divider: CGFloat = 0) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let usable = Swift.max(rect.width - divider, 0)
            let firstWidth = usable * ratio
            return (
                CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                CGRect(
                    x: rect.minX + firstWidth + divider, y: rect.minY,
                    width: usable - firstWidth, height: rect.height)
            )
        case .vertical:
            let usable = Swift.max(rect.height - divider, 0)
            let firstHeight = usable * ratio
            return (
                CGRect(
                    x: rect.minX, y: rect.maxY - firstHeight, width: rect.width,
                    height: firstHeight),
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: usable - firstHeight)
            )
        }
    }
}

// MARK: - Mutating the tree

extension PaneNode {
    /// Replaces the leaf `id` with a split of itself and a new leaf. Returns false if `id` is not
    /// in this subtree, leaving the tree untouched.
    public mutating func split(
        _ id: TerminalID, axis: PaneAxis, ratio: Double, newLeaf: TerminalID
    ) -> Bool {
        switch self {
        case .leaf(let pane):
            guard pane.id == id else { return false }
            self = .split(
                PaneSplit(
                    axis: axis, ratio: ratio, first: .leaf(pane), second: .leaf(Pane(id: newLeaf))))
            return true
        case .split(var split):
            if split.first.split(id, axis: axis, ratio: ratio, newLeaf: newLeaf) {
                self = .split(split)
                return true
            }
            if split.second.split(id, axis: axis, ratio: ratio, newLeaf: newLeaf) {
                self = .split(split)
                return true
            }
            return false
        }
    }

    /// Removes the leaf `id`, replacing its parent split with the surviving sibling **wholesale**.
    ///
    /// No ratio is re-distributed, and the grandparent's ratio is untouched — with a binary tree
    /// the sibling already occupies exactly the union of the two rectangles, so it simply inherits
    /// the closed pane's space. ("Re-distribute the ratio" is the intuitive guess and it is wrong;
    /// evening panes out is what `equalize` is for.)
    ///
    /// Returns the id of the leaf that should take focus if the closed one had it — the surviving
    /// sibling subtree's first leaf — or nil when `id` is not here or is the subtree's only leaf.
    public mutating func closeLeaf(_ id: TerminalID) -> TerminalID? {
        guard case .split(var split) = self else { return nil }

        if case .leaf(let pane) = split.first, pane.id == id {
            let successor = split.second.firstLeafID
            self = split.second
            return successor
        }
        if case .leaf(let pane) = split.second, pane.id == id {
            let successor = split.first.firstLeafID
            self = split.first
            return successor
        }
        if let successor = split.first.closeLeaf(id) {
            self = .split(split)
            return successor
        }
        if let successor = split.second.closeLeaf(id) {
            self = .split(split)
            return successor
        }
        return nil
    }

    /// Sets the ratio of the split `levels` above the leaf `id` — 0 is its immediate parent, 1 its
    /// grandparent. Returns false when there is no such ancestor, so the caller can do nothing
    /// rather than move an arbitrary divider.
    public mutating func setRatio(above id: TerminalID, levels: Int = 0, to ratio: Double) -> Bool {
        guard case .split(var split) = self else { return false }
        guard let distance = ancestorDistance(of: id) else { return false }
        if distance == levels {
            split.ratio = PaneSplit.clamp(ratio)
            self = .split(split)
            return true
        }
        if split.first.setRatio(above: id, levels: levels, to: ratio)
            || split.second.setRatio(above: id, levels: levels, to: ratio)
        {
            self = .split(split)
            return true
        }
        return false
    }

    /// How many splits sit between this node and the leaf `id`: 0 when `id` is an immediate child
    /// of this split, 1 when it is a grandchild. Nil when the leaf is not in this subtree.
    public func ancestorDistance(of id: TerminalID) -> Int? {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? -1 : nil
        case .split(let split):
            if let d = split.first.ancestorDistance(of: id) { return d + 1 }
            if let d = split.second.ancestorDistance(of: id) { return d + 1 }
            return nil
        }
    }

    /// Sets every split's ratio so that all leaves in the subtree end the same size.
    ///
    /// Weighting by leaf count is the only definition under which that is true at any nesting
    /// depth: in `1 | (2 | 3)` the root must give the left pane ⅓, not ½.
    public mutating func equalize() {
        guard case .split(var split) = self else { return }
        split.first.equalize()
        split.second.equalize()
        let a = Double(split.first.leafCount)
        let b = Double(split.second.leafCount)
        split.ratio = PaneSplit.clamp(a / (a + b))
        self = .split(split)
    }
}

// MARK: - Tab

public struct Tab: Hashable, Sendable, Identifiable {
    public var id: TabID
    public var root: PaneNode
    /// The pane that takes keystrokes when this tab is active. Always a leaf of `root`;
    /// `Session.normalizeLayout` repairs a file that says otherwise.
    public var focusedLeaf: TerminalID
    /// ⇧⌘↩: one pane fills the tab, its siblings detached. Part of the layout, so it persists.
    public var zoomedLeaf: TerminalID?

    public init(id: TabID, root: PaneNode, focusedLeaf: TerminalID, zoomedLeaf: TerminalID? = nil) {
        self.id = id
        self.root = root
        self.focusedLeaf = focusedLeaf
        self.zoomedLeaf = zoomedLeaf
    }

    /// The one-terminal tab every new and every migrated session starts as. Shared by
    /// `Session.init`, `Migrations.liftV1ToV2`, `AppState.addTab` and the repair path, so all four
    /// cannot drift.
    public static func single(_ terminal: TerminalID, tab: TabID = .generate()) -> Tab {
        Tab(id: tab, root: .leaf(terminal), focusedLeaf: terminal)
    }

    public var terminalIDs: [TerminalID] { root.leafIDs }
    public var terminalCount: Int { root.leafCount }

    /// What is actually on screen: one pane while zoomed, otherwise every leaf.
    public var visibleTerminalIDs: [TerminalID] {
        if let zoomedLeaf, root.contains(zoomedLeaf) { return [zoomedLeaf] }
        return root.leafIDs
    }

    /// Whether `other` would build the same view tree: same tab, same zoom, same tree shape.
    /// The focused leaf and the ratios are not part of it — both change without any view moving.
    public func hasSameShape(as other: Tab) -> Bool {
        id == other.id && zoomedLeaf == other.zoomedLeaf && root.hasSameShape(as: other.root)
    }
}

// MARK: - Codable

/// The wire form is written by hand rather than synthesized: the compiler's
/// enum-with-payload encoding is an implementation detail of the Swift version that compiled the
/// app, and `state.json` is a file a human is invited to read and repair. The contract is
///
///     {"kind": "leaf",  "id": "5B4C…"}
///     {"kind": "split", "axis": "horizontal", "ratio": 0.5, "first": {…}, "second": {…}}
extension PaneNode: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id, axis, ratio, first, second }
    private enum Kind: String, Codable { case leaf, split }

    /// A tree deeper than this is a corrupt or hostile file, not a layout: 64 splits is more panes
    /// than there are atoms worth counting. Without the bound a recursive `init(from:)` is a stack
    /// overflow on a fat-fingered edit, which crashes the app; with it the file falls into the
    /// existing `.bak` → quarantine path in `StateFile.load`.
    public static let maxDecodeDepth = 64

    public init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count < PaneNode.maxDecodeDepth * 2 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "pane tree nested deeper than \(PaneNode.maxDecodeDepth) splits"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .leaf:
            self = .leaf(Pane(id: try container.decode(TerminalID.self, forKey: .id)))
        case .split:
            self = .split(
                PaneSplit(
                    axis: try container.decode(PaneAxis.self, forKey: .axis),
                    ratio: try container.decode(Double.self, forKey: .ratio),
                    first: try container.decode(PaneNode.self, forKey: .first),
                    second: try container.decode(PaneNode.self, forKey: .second)))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let pane):
            try container.encode(Kind.leaf, forKey: .kind)
            try container.encode(pane.id, forKey: .id)
        case .split(let split):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(split.axis, forKey: .axis)
            try container.encode(split.ratio, forKey: .ratio)
            try container.encode(split.first, forKey: .first)
            try container.encode(split.second, forKey: .second)
        }
    }
}

extension Tab: Codable {}

// MARK: - Repair

extension Session {
    /// Forces the layout invariants a hand-edited or half-written `state.json` can break, and
    /// reports what it had to change.
    ///
    /// This lives here rather than in `Persistence` so it is testable without a file, and so
    /// anything that builds an `AppState` from untrusted input can reuse it. The warnings are in
    /// the same voice as `PersistedState.apply(to:)`'s existing ones ("selection … names no
    /// session; cleared"): a loaded file is repaired and the user is told, never silently dropped.
    ///
    /// `claimedTerminals` is threaded across **every** session in the file, not reset per row: a
    /// terminal id is a `.ghsnap` basename, so it has to be unique file-wide. A duplicate is
    /// *regenerated* rather than dropped, because regenerating costs one saved screen while
    /// dropping the row would cost a whole conversation.
    public mutating func normalizeLayout(
        claimedTerminals: inout Set<TerminalID>,
        claimedTabs: inout Set<TabID>
    ) -> [String] {
        var warnings: [String] = []

        if tabs.isEmpty {
            tabs = [Tab.single(TerminalID(uuid: id.uuid), tab: TabID(uuid: id.uuid))]
            warnings.append("session \(id) has no tabs; a single terminal was made")
        }

        var clampedARatio = false
        for index in tabs.indices {
            if !claimedTabs.insert(tabs[index].id).inserted {
                let fresh = TabID.generate()
                warnings.append("tab \(tabs[index].id) appears twice; renumbered as \(fresh)")
                tabs[index].id = fresh
                claimedTabs.insert(fresh)
            }
            tabs[index].root.reidentifyDuplicates(
                claimed: &claimedTerminals, warnings: &warnings)
            tabs[index].root.clampRatios(didClamp: &clampedARatio)

            if !tabs[index].root.contains(tabs[index].focusedLeaf) {
                tabs[index].focusedLeaf = tabs[index].root.firstLeafID
                warnings.append(
                    "tab \(tabs[index].id) focuses a pane it does not contain; focus moved")
            }
            if let zoomed = tabs[index].zoomedLeaf, !tabs[index].root.contains(zoomed) {
                // Silent: losing a zoom is not something a user notices, and every other repair
                // here is one they might.
                tabs[index].zoomedLeaf = nil
            }
        }

        if clampedARatio {
            warnings.append("session \(id) had an out-of-range split ratio; clamped")
        }

        if !tabs.contains(where: { $0.id == activeTab }) {
            activeTab = tabs[0].id
            warnings.append("session \(id) names an unknown active tab; the first was used")
        }

        return warnings
    }
}

extension PaneNode {
    /// Gives any terminal id already seen elsewhere in the file a fresh one. See
    /// `Session.normalizeLayout` for why regenerating beats dropping.
    mutating func reidentifyDuplicates(claimed: inout Set<TerminalID>, warnings: inout [String]) {
        switch self {
        case .leaf(var pane):
            guard !claimed.insert(pane.id).inserted else { return }
            let fresh = TerminalID.generate()
            warnings.append(
                "terminal \(pane.id) appears twice; the second was given a new id and lost its "
                    + "saved screen")
            pane.id = fresh
            claimed.insert(fresh)
            self = .leaf(pane)
        case .split(var split):
            split.first.reidentifyDuplicates(claimed: &claimed, warnings: &warnings)
            split.second.reidentifyDuplicates(claimed: &claimed, warnings: &warnings)
            self = .split(split)
        }
    }

    /// Forces every ratio into `PaneSplit.ratioRange`, reporting whether anything moved.
    /// `PaneSplit.init` already clamps, so this only catches a tree built by other means.
    mutating func clampRatios(didClamp: inout Bool) {
        guard case .split(var split) = self else { return }
        let clamped = PaneSplit.clamp(split.ratio)
        if clamped != split.ratio {
            split.ratio = clamped
            didClamp = true
        }
        split.first.clampRatios(didClamp: &didClamp)
        split.second.clampRatios(didClamp: &didClamp)
        self = .split(split)
    }
}
