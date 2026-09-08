// SidebarViewController — the outline view that binds `AppStore` to the sidebar rows
// (M2.3 / TKZ-19). See docs/design.md → *App architecture → Sidebar* and *Store*.
//
// The whole reason this type is a hand-written `NSOutlineView` controller instead of a SwiftUI
// `List` is the last sentence of the Store section: **a Claude status flip on one session must cost
// one `reloadData(forRowIndexes:)`, not forty row re-renders**. So every update path here is driven
// by a `ChangeSet` field:
//
//   | change      | what happens                                                             |
//   |-------------|--------------------------------------------------------------------------|
//   | `structure` | `insertItems`/`removeItems`/`moveItem` inside `beginUpdates`/`endUpdates` |
//   | `groups`    | `expandItem`/`collapseItem` + a one-row reload of the header             |
//   | `sessions`  | `reloadData(forRowIndexes:)` for exactly the rows named                   |
//   | `selection` | `selectRowIndexes` + a reload of the two rows whose `isSelected` flipped  |
//   | `usage`/`chrome` | ignored — no sidebar row depends on them                            |
//
// `reloadData()` is called exactly once, at load. `SidebarOutlineView` counts every one of these
// calls so the tests can assert the table above rather than eyeball it.
//
// **Collapse is not structural.** `numberOfChildrenOfItem` always reports a group's full session
// list; whether those rows exist is `expandItem`/`collapseItem`, driven by `Group.isCollapsed`.
// Returning 0 for a collapsed group would make every collapse a structural change and defeat the
// design's central claim.
//
// **The shadow tree.** By the time an observer runs, `store.state` is already the *new* state, so
// the structural diff cannot ask the data source what the old rows were. `shadowGroups` /
// `shadowSessions` are this controller's copy of what the outline view currently shows; the diff is
// computed against them and they are updated in lockstep.
//
// **Row ownership.** The rows paint their own `Theme.selection`, so `selectionHighlightStyle` is
// `.none` — otherwise the system highlight double-paints. The rows also own their pulse, their
// backing scale and their reuse cleanup; this controller only forwards window occlusion (per row,
// on `NSWindow.didChangeOcclusionStateNotification`) and re-wires `GroupRowView.onAdd`, which
// `prepareForReuse()` clears.

import AppKit
import TkzCore

// MARK: - Items

/// The object `NSOutlineView` holds on to for a row.
///
/// It has to be a class: `NSOutlineView` keeps items in an identity-keyed map, and a Swift value
/// type would be boxed afresh on every `child(_:ofItem:)` call, so the same group would look like a
/// different item each time. `SidebarViewController` hands out cached instances *and* implements
/// `isEqual`/`hash`, so both identity and equality agree.
final class SidebarItem: NSObject {
    enum Kind: Hashable {
        case group(GroupID)
        case session(SessionID)
    }

    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }

    var groupID: GroupID? { if case .group(let id) = kind { return id }; return nil }
    var sessionID: SessionID? { if case .session(let id) = kind { return id }; return nil }

    override func isEqual(_ object: Any?) -> Bool { (object as? SidebarItem)?.kind == kind }
    override var hash: Int { kind.hashValue }
    override var description: String { "SidebarItem(\(kind))" }
}

// MARK: - Outline view

/// The sidebar's `NSOutlineView`, with two jobs beyond the stock one:
///
///  * it counts every reload/insert/remove/move so the tests can assert *which* API ran — the
///    ticket's acceptance criterion is "a status flip reloads exactly that row", and a counter is
///    the only honest way to check it;
///  * it owns ↑/↓, which move the selection over visible session rows only.
final class SidebarOutlineView: NSOutlineView {
    /// ↑ = `-1`, ↓ = `+1`. Set by the controller.
    var onArrowKey: (@MainActor (Int) -> Void)?

    // MARK: Call counters (tests only; free in release)

    private(set) var reloadDataCallCount = 0
    private(set) var reloadedRowIndexSets: [IndexSet] = []
    private(set) var insertedItemCalls: [(rows: IndexSet, parent: SidebarItem?)] = []
    private(set) var removedItemCalls: [(rows: IndexSet, parent: SidebarItem?)] = []
    private(set) var movedItemCalls: [(from: Int, to: Int, parent: SidebarItem?)] = []

    func resetCounters() {
        reloadDataCallCount = 0
        reloadedRowIndexSets = []
        insertedItemCalls = []
        removedItemCalls = []
        movedItemCalls = []
    }

    /// Total rows touched by `reloadData(forRowIndexes:)` since the last reset.
    var reloadedRowCount: Int { reloadedRowIndexSets.reduce(0) { $0 + $1.count } }

    override func reloadData() {
        reloadDataCallCount += 1
        super.reloadData()
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        reloadedRowIndexSets.append(rowIndexes)
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    override func insertItems(
        at indexes: IndexSet, inParent parent: Any?, withAnimation animationOptions: NSTableView.AnimationOptions
    ) {
        insertedItemCalls.append((indexes, parent as? SidebarItem))
        super.insertItems(at: indexes, inParent: parent, withAnimation: animationOptions)
    }

    override func removeItems(
        at indexes: IndexSet, inParent parent: Any?, withAnimation animationOptions: NSTableView.AnimationOptions
    ) {
        removedItemCalls.append((indexes, parent as? SidebarItem))
        super.removeItems(at: indexes, inParent: parent, withAnimation: animationOptions)
    }

    override func moveItem(at fromIndex: Int, inParent oldParent: Any?, to toIndex: Int, inParent newParent: Any?) {
        movedItemCalls.append((fromIndex, toIndex, newParent as? SidebarItem))
        super.moveItem(at: fromIndex, inParent: oldParent, to: toIndex, inParent: newParent)
    }

    // MARK: Chrome

    /// The rows draw their own chevron, so the system disclosure triangle gets no space at all.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 126: onArrowKey?(-1)  // ↑
        case 125: onArrowKey?(+1)  // ↓
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Container

/// Root view. Lays the scroll view over a fixed-height summary strip, and tells the controller when
/// it changes window so occlusion notifications can follow.
final class SidebarContainerView: NSView {
    var onWindowChange: (@MainActor (NSWindow?) -> Void)?
    var scrollView: NSScrollView?
    var summaryStrip: SummaryStripView?

    override var isFlipped: Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        onWindowChange?(newWindow)
    }

    override func layout() {
        super.layout()
        let stripHeight = CGFloat(SidebarMetrics.summaryStripHeight)
        summaryStrip?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
        scrollView?.frame = NSRect(
            x: 0, y: stripHeight, width: bounds.width, height: max(0, bounds.height - stripHeight))
    }
}

// MARK: - Controller

@MainActor
public final class SidebarViewController: NSViewController {

    // MARK: Public API (wave 3 embeds this; M2.4 wires the menus)

    /// Invoked by a group header's `＋`. M2.4 replaces this with the new-session menu.
    public var onNewSession: (@MainActor (GroupID) -> Void)?

    /// The list itself, for the split-view host (sizing, first responder, scrolling).
    public var outlineView: NSOutlineView { outline }

    /// The "N working · N need you" strip beneath the list.
    public var summaryStrip: SummaryStripView { strip }

    /// The scroll view the outline lives in; the split view sets its width constraints.
    public var scrollView: NSScrollView { scroll }

    // MARK: Storage

    private let store: AppStore
    private var theme: Theme
    private let outline = SidebarOutlineView()
    private let scroll = NSScrollView()
    private let strip = SummaryStripView()

    private var itemCache: [SidebarItem.Kind: SidebarItem] = [:]

    /// What the outline view currently shows — see the file header.
    private var shadowGroups: [GroupID] = []
    private var shadowSessions: [GroupID: [SessionID]] = [:]

    private var isApplyingStoreSelection = false
    private var isApplyingStoreCollapse = false
    private var appliedSelection: SessionID?
    private var isOccluded = false
    private var occlusionWindow: NSWindow?

    public init(store: AppStore, theme: Theme = .default) {
        self.store = store
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    // MARK: View

    public override func loadView() {
        let container = SidebarContainerView(
            frame: NSRect(x: 0, y: 0, width: SidebarMetrics.sidebarWidth, height: 600))
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.sidebarBackground.cgColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tkz.sidebar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.selectionHighlightStyle = .none  // the rows paint Theme.selection themselves
        outline.usesAutomaticRowHeights = false
        outline.rowSizeStyle = .custom
        outline.indentationPerLevel = 0
        outline.intercellSpacing = .zero
        outline.gridStyleMask = []
        outline.floatsGroupRows = false
        outline.autosaveExpandedItems = false
        outline.autoresizesOutlineColumn = false
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.backgroundColor = theme.sidebarBackground.nsColor
        outline.wantsLayer = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(outlineClicked)
        outline.onArrowKey = { [weak self] offset in self?.moveSelection(by: offset) }

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = theme.sidebarBackground.nsColor
        scroll.wantsLayer = true

        container.addSubview(scroll)
        container.addSubview(strip)
        container.scrollView = scroll
        container.summaryStrip = strip
        container.onWindowChange = { [weak self] window in self?.windowChanged(to: window) }

        view = container
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        strip.configure(SidebarRowAdapter.summaryModel(for: store.state), theme: theme)
        rebuild()
        store.addObserver { [weak self] change in self?.apply(change) }
    }

    /// Swaps the theme (M2.4's preset picker). Rebuilds every row, so it is not on a hot path.
    public func setTheme(_ theme: Theme) {
        self.theme = theme
        view.layer?.backgroundColor = theme.sidebarBackground.cgColor
        outline.backgroundColor = theme.sidebarBackground.nsColor
        scroll.backgroundColor = theme.sidebarBackground.nsColor
        strip.configure(SidebarRowAdapter.summaryModel(for: store.state), theme: theme)
        outline.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows),
            columnIndexes: IndexSet(integer: 0))
    }

    // MARK: Full rebuild (load, and nothing else)

    /// The only `reloadData()` in the class. Rebuilds the shadow tree and the expansion state from
    /// the store, then restores the selection.
    public func rebuild() {
        outline.reloadData()
        shadowGroups = store.state.orderedGroups.map(\.id)
        shadowSessions = [:]
        for id in shadowGroups { shadowSessions[id] = store.state.sessions(in: id).map(\.id) }
        syncExpansion(for: shadowGroups)
        syncSelectionToOutline(scroll: false)
        updateSummary()
    }

    // MARK: Change-set dispatch

    private func apply(_ change: ChangeSet) {
        if change.structure { applyStructure() }
        if !change.groups.isEmpty { applyGroups(change.groups) }

        var rows = IndexSet()
        for id in change.sessions {
            let row = self.row(forSession: id)
            if row >= 0 { rows.insert(row) }
        }
        if change.selection {
            // Both the row that lost the selection and the one that gained it repaint their own
            // `Theme.selection`, so both need a reload. The new id is usually already in
            // `change.sessions` (`select` touches `lastActiveAt`); the old one never is.
            for id in [appliedSelection, store.state.selection].compactMap({ $0 }) {
                let row = self.row(forSession: id)
                if row >= 0 { rows.insert(row) }
            }
        }
        if !rows.isEmpty {
            outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        }

        if change.selection { syncSelectionToOutline() }
        if change.structure || !change.sessions.isEmpty { updateSummary() }
    }

    /// `groups` without `structure`: a rename, a colour, or a collapse. Never a row move.
    private func applyGroups(_ ids: Set<GroupID>) {
        var rows = IndexSet()
        for id in ids {
            let row = self.row(forGroup: id)
            if row >= 0 { rows.insert(row) }
        }
        syncExpansion(for: Array(ids))
        // Re-resolve the rows *after* expansion: collapsing a group moves every header below it.
        var settled = IndexSet()
        for id in ids {
            let row = self.row(forGroup: id)
            if row >= 0 { settled.insert(row) }
        }
        rows.formUnion(settled)
        if !rows.isEmpty {
            outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        }
        // Collapsing a group drops the outline view's selection if the selected row was inside it,
        // while the *store* keeps it (the session still exists). Re-expanding must therefore hand
        // the selection back, or the row would paint selected with `selectedRow == -1`.
        syncSelectionToOutline(scroll: false)
    }

    /// Mirrors `Group.isCollapsed` onto the outline view. Guarded so the resulting
    /// `outlineViewItemDidExpand/Collapse` notifications do not write straight back into the store.
    private func syncExpansion(for ids: [GroupID]) {
        isApplyingStoreCollapse = true
        defer { isApplyingStoreCollapse = false }
        for id in ids {
            guard let group = store.state.groups[id] else { continue }
            let item = self.item(.group(id))
            let expanded = outline.isItemExpanded(item)
            if group.isCollapsed, expanded {
                outline.collapseItem(item)
            } else if !group.isCollapsed, !expanded {
                outline.expandItem(item)
            }
        }
    }

    // MARK: Structural diff

    /// Turns the difference between the shadow tree and `store.state` into
    /// `removeItems`/`insertItems`/`moveItem`. Never `reloadData`.
    ///
    /// Three passes, in this order, because the index each call takes is relative to the tree *at
    /// that moment*: removals (descending, so earlier indices stay valid), then insertions
    /// (ascending, so each target index is the final one), then moves (one at a time, each computed
    /// against the shadow as it stands). A session that changed group is a remove plus an insert;
    /// `moveItem` across parents would need both trees to be correct simultaneously.
    private func applyStructure() {
        let state = store.state
        let newGroups = state.orderedGroups.map(\.id)
        var newSessions: [GroupID: [SessionID]] = [:]
        for id in newGroups { newSessions[id] = state.sessions(in: id).map(\.id) }

        var groups = shadowGroups
        var sessions = shadowSessions
        let survivingGroups = Set(newGroups)

        outline.beginUpdates()

        // 1. Removals — sessions first (a removed group takes its children with it).
        for groupID in groups where survivingGroups.contains(groupID) {
            let current = sessions[groupID] ?? []
            let wanted = Set(newSessions[groupID] ?? [])
            let doomed = IndexSet(current.indices.filter { !wanted.contains(current[$0]) })
            guard !doomed.isEmpty else { continue }
            outline.removeItems(at: doomed, inParent: item(.group(groupID)), withAnimation: [])
            sessions[groupID] = current.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
        }
        let doomedGroups = IndexSet(groups.indices.filter { !survivingGroups.contains(groups[$0]) })
        if !doomedGroups.isEmpty {
            outline.removeItems(at: doomedGroups, inParent: nil, withAnimation: [])
            for index in doomedGroups { sessions[groups[index]] = nil }
            groups = groups.enumerated().filter { !doomedGroups.contains($0.offset) }.map(\.element)
        }

        // 2. Insertions — groups (in final order), then each group's new sessions.
        for (index, groupID) in newGroups.enumerated() where !groups.contains(groupID) {
            outline.insertItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
            groups.insert(groupID, at: index)
            sessions[groupID] = []
        }
        for groupID in newGroups {
            let current = sessions[groupID] ?? []
            let wanted = newSessions[groupID] ?? []
            let existing = Set(current)
            var rebuilt = current
            var inserted = IndexSet()
            for (index, sessionID) in wanted.enumerated() where !existing.contains(sessionID) {
                inserted.insert(index)
                rebuilt.insert(sessionID, at: min(index, rebuilt.count))
            }
            if !inserted.isEmpty {
                outline.insertItems(at: inserted, inParent: item(.group(groupID)), withAnimation: [])
                sessions[groupID] = rebuilt
            }
        }

        // 3. Moves — the id sets now match; only the order can differ.
        move(&groups, to: newGroups, parent: nil)
        for groupID in newGroups {
            var current = sessions[groupID] ?? []
            move(&current, to: newSessions[groupID] ?? [], parent: item(.group(groupID)))
            sessions[groupID] = current
        }

        outline.endUpdates()

        shadowGroups = newGroups
        shadowSessions = newSessions

        // A group that was just inserted has no expansion state yet.
        syncExpansion(for: newGroups)
        syncSelectionToOutline(scroll: false)
    }

    private func move<ID: Equatable>(_ current: inout [ID], to wanted: [ID], parent: SidebarItem?) {
        for (target, id) in wanted.enumerated() {
            guard current.indices.contains(target), current[target] != id,
                let from = current.firstIndex(of: id)
            else { continue }
            outline.moveItem(at: from, inParent: parent, to: target, inParent: parent)
            current.remove(at: from)
            current.insert(id, at: target)
        }
    }

    // MARK: Selection

    /// `scroll` is `false` for the initial load and for structural updates: scrolling to the
    /// selection before the view has been laid out would jump the list by one row (the clip view is
    /// still zero-height, so "make row 1 visible" scrolls the header off the top).
    private func syncSelectionToOutline(scroll: Bool = true) {
        isApplyingStoreSelection = true
        defer { isApplyingStoreSelection = false }
        appliedSelection = store.state.selection
        guard let id = store.state.selection else {
            if outline.selectedRow >= 0 { outline.deselectAll(nil) }
            return
        }
        let row = self.row(forSession: id)
        guard row >= 0 else {
            if outline.selectedRow >= 0 { outline.deselectAll(nil) }
            return
        }
        if outline.selectedRow != row {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if scroll { outline.scrollRowToVisible(row) }
        }
    }

    // MARK: Commands (M2.4 hangs the key equivalents off these)

    /// ⌘1–⌘9. `index` is 1-based over the **visible** rows, so a collapsed group's sessions are not
    /// reachable — they are not rows.
    public func selectSession(atVisibleIndex index: Int) {
        guard let id = SidebarRowAdapter.session(atVisibleIndex: index, in: store.state) else { return }
        store.update { $0.select(id) }
    }

    /// ⇧⌘U. Jumps to the first session showing `NEEDS YOU`, expanding its group if it is collapsed —
    /// both in one mutation, so the outline sees one change set with `groups` before `selection`.
    @discardableResult
    public func selectFirstSessionNeedingAttention() -> SessionID? {
        guard let id = SidebarRowAdapter.firstSessionNeedingAttention(in: store.state) else { return nil }
        let groupID = store.state.sessions[id]?.groupID
        store.update { state in
            if let groupID, state.groups[groupID]?.isCollapsed == true {
                state.setGroupCollapsed(groupID, false)
            }
            state.select(id)
        }
        return id
    }

    /// ↑/↓, clamped over the visible rows. `AppState.selectAdjacentSession(offset:)` is the wrapping
    /// ⌥⌘↑/⌥⌘↓ command and stays with the store; this is the list's own arrow-key behaviour.
    public func moveSelection(by offset: Int) {
        guard let id = SidebarRowAdapter.session(adjacentTo: store.state.selection, offset: offset, in: store.state),
            id != store.state.selection
        else { return }
        store.update { $0.select(id) }
    }

    /// Collapse state lives in the store, so the sidebar's chevron and `state.json` can never drift.
    public func toggleCollapse(_ groupID: GroupID) {
        store.update { $0.toggleGroupCollapsed(groupID) }
    }

    // MARK: Occlusion
    //
    // Per row, as the row-view agent specified: the row owns detach/re-attach (`viewDidMoveToWindow`)
    // and this only forwards "the window is behind another window". A selector-based observer is
    // used deliberately — the block form is `@Sendable` and cannot touch main-actor state without
    // an `assumeIsolated` dance.

    private func windowChanged(to window: NSWindow?) {
        if let occlusionWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification, object: occlusionWindow)
        }
        occlusionWindow = window
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            setOccluded(!window.occlusionState.contains(.visible))
        } else {
            setOccluded(false)
        }
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        setOccluded(!window.occlusionState.contains(.visible))
    }

    /// Parks (or restarts) the pulse on every visible session row. Public for the perf harness and
    /// the tests, which have no real window to occlude.
    public func setOccluded(_ occluded: Bool) {
        isOccluded = occluded
        outline.enumerateAvailableRowViews { rowView, _ in
            for subview in rowView.subviews {
                (subview as? SessionRowView)?.setOccluded(occluded)
            }
        }
    }

    // MARK: Helpers

    func item(_ kind: SidebarItem.Kind) -> SidebarItem {
        if let cached = itemCache[kind] { return cached }
        let item = SidebarItem(kind)
        itemCache[kind] = item
        return item
    }

    func row(forSession id: SessionID) -> Int { outline.row(forItem: item(.session(id))) }
    func row(forGroup id: GroupID) -> Int { outline.row(forItem: item(.group(id))) }

    private func updateSummary() {
        strip.configure(SidebarRowAdapter.summaryModel(for: store.state), theme: theme)
    }

    @objc private func outlineClicked() {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem, let groupID = item.groupID
        else { return }
        toggleCollapse(groupID)
    }
}

// MARK: - Data source

extension SidebarViewController: NSOutlineViewDataSource {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return store.state.groups.count }
        guard let sidebarItem = item as? SidebarItem, let groupID = sidebarItem.groupID else { return 0 }
        // Deliberately independent of `isCollapsed` — see the file header.
        return store.state.sessions(in: groupID).count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            let groups = store.state.orderedGroups
            return self.item(.group(groups[index].id))
        }
        guard let sidebarItem = item as? SidebarItem, let groupID = sidebarItem.groupID else {
            preconditionFailure("a session row has no children")
        }
        return self.item(.session(store.state.sessions(in: groupID)[index].id))
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.groupID != nil
    }
}

// MARK: - Delegate

extension SidebarViewController: NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let sidebarItem = item as? SidebarItem else { return SidebarMetrics.sessionRowHeight }
        return sidebarItem.groupID == nil
            ? SidebarMetrics.sessionRowHeight : SidebarMetrics.groupRowHeight
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarItem)?.sessionID != nil
    }

    public func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }
        switch sidebarItem.kind {
        case .group(let id):
            guard let group = store.state.groups[id] else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("tkz.sidebar.group")
            let view = (outlineView.makeView(withIdentifier: identifier, owner: self) as? GroupRowView)
                ?? {
                    let fresh = GroupRowView(frame: .zero)
                    fresh.identifier = identifier
                    return fresh
                }()
            view.configure(SidebarRowAdapter.groupModel(group, in: store.state), theme: theme)
            // `prepareForReuse()` clears this, so it is rewired on every vend.
            view.onAdd = { [weak self] in self?.onNewSession?(id) }
            return view

        case .session(let id):
            guard let session = store.state.sessions[id] else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("tkz.sidebar.session")
            let view = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SessionRowView)
                ?? {
                    let fresh = SessionRowView(frame: .zero)
                    fresh.identifier = identifier
                    return fresh
                }()
            view.configure(SidebarRowAdapter.sessionModel(session, in: store.state), theme: theme)
            view.setOccluded(isOccluded)
            return view
        }
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingStoreSelection else { return }
        let row = outline.selectedRow
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem, let id = item.sessionID
        else { return }
        guard store.state.selection != id else { return }
        store.update { $0.select(id) }
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplyingStoreCollapse,
            let item = notification.userInfo?["NSObject"] as? SidebarItem,
            let groupID = item.groupID
        else { return }
        store.update { $0.setGroupCollapsed(groupID, false) }
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplyingStoreCollapse,
            let item = notification.userInfo?["NSObject"] as? SidebarItem,
            let groupID = item.groupID
        else { return }
        store.update { $0.setGroupCollapsed(groupID, true) }
    }
}
