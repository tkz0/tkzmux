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

// MARK: - Pasteboard

extension NSPasteboard.PasteboardType {
    /// A session row being dragged inside our own sidebar. The payload is `SessionID.rawValue`.
    ///
    /// Private to the app on purpose: a session row is only meaningful next to the store that owns
    /// it, so there is nothing to promise another application and nothing to accept from one.
    static let tkzSidebarSession = NSPasteboard.PasteboardType("com.tkz.tkzmux.sidebar-session")
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
    /// The context menu for the row under a right-click (M5.2). `nil` = no menu for that row.
    var onContextMenu: (@MainActor (SidebarItem.Kind) -> NSMenu?)?

    /// Right-click: the row under the pointer gets its own menu, without moving the selection —
    /// "Remove" on a row the user is not looking at must not first switch the terminal to it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let item = item(atRow: row) as? SidebarItem else { return nil }
        return onContextMenu?(item.kind)
    }

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

/// Root view. Stacks, top to bottom, the fixed-height summary strip (under the toolbar, as
/// artboard 2c draws it — moved there 2026-09-08), the scroll view and the "＋ New group" footer,
/// and tells the controller when it changes window so occlusion notifications can follow. The
/// strip starts at the top safe-area inset, so with the content extending under the titlebar the
/// strip and the rows still start below it.
final class SidebarContainerView: NSView {
    var onWindowChange: (@MainActor (NSWindow?) -> Void)?
    var scrollView: NSScrollView?
    var summaryStrip: SummaryStripView?
    var newGroupFooter: NewGroupFooterView?

    override var isFlipped: Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        onWindowChange?(newWindow)
    }

    override func layout() {
        super.layout()
        let footerHeight = CGFloat(SidebarMetrics.newGroupFooterHeight)
        let stripHeight = CGFloat(SidebarMetrics.summaryStripHeight)
        let topInset = safeAreaInsets.top
        newGroupFooter?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: footerHeight)
        let stripY = max(footerHeight, bounds.height - topInset - stripHeight)
        summaryStrip?.frame = NSRect(x: 0, y: stripY, width: bounds.width, height: stripHeight)
        scrollView?.frame = NSRect(
            x: 0, y: footerHeight, width: bounds.width,
            height: max(0, stripY - footerHeight))
    }
}

// MARK: - Controller

@MainActor
public final class SidebarViewController: NSViewController {

    // MARK: Public API (wave 3 embeds this; M2.4 wires the menus)

    /// Invoked by a group header's `＋`. M2.4 replaces this with the new-session menu.
    public var onNewSession: (@MainActor (GroupID) -> Void)?

    /// Invoked by the "＋ New group" footer. The assembler asks for the group's name.
    public var onNewGroup: (@MainActor () -> Void)? {
        didSet { footer.onNewGroup = onNewGroup }
    }

    /// Builds the context menu for a right-clicked session row (M5.2). The assembler owns the
    /// verbs (Resume, Rename, Close, Remove); the sidebar only knows which row was hit.
    public var onSessionContextMenu: (@MainActor (SessionID) -> NSMenu?)? {
        didSet { wireContextMenu() }
    }
    /// The same for a group header (New session…, Resume all in group).
    public var onGroupContextMenu: (@MainActor (GroupID) -> NSMenu?)? {
        didSet { wireContextMenu() }
    }

    /// The `×` that appears on a hovered row was clicked (2026-09-08). The assembler removes the
    /// session, with the same confirmation ⌘W has.
    public var onRemoveSession: (@MainActor (SessionID) -> Void)?

    private func wireContextMenu() {
        outline.onContextMenu = { [weak self] kind in
            guard let self else { return nil }
            switch kind {
            case .session(let id): return self.onSessionContextMenu?(id)
            case .group(let id): return self.onGroupContextMenu?(id)
            }
        }
    }

    /// The menu the outline would show for a right-click on `id`'s row — for tests, which have no
    /// pointer to right-click with.
    public func contextMenu(forSession id: SessionID) -> NSMenu? {
        outline.onContextMenu?(.session(id))
    }

    public func contextMenu(forGroup id: GroupID) -> NSMenu? {
        outline.onContextMenu?(.group(id))
    }

    /// What `showLastMessage(for:)` shows. Defaults to the session's `lastStopMessage`; overridable
    /// for tests and for anyone who wants to feed the popover something else.
    public var lastMessageProvider: (@MainActor (SessionID) -> String?)?

    /// The "＋ New group" footer beneath the summary strip.
    public var newGroupFooter: NewGroupFooterView { footer }

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
    private let footer = NewGroupFooterView()
    /// Internal rather than private: `LastMessagePopoverTests` asserts `isShown` on this directly,
    /// since `showLastMessage(for:)` deliberately returns nothing to check against.
    var lastMessagePopover: LastMessagePopover

    private var itemCache: [SidebarItem.Kind: SidebarItem] = [:]

    /// What the outline view currently shows — see the file header.
    private var shadowGroups: [GroupID] = []
    private var shadowSessions: [GroupID: [SessionID]] = [:]

    /// The colour each group's rows were last rendered with (TKZ-48).
    ///
    /// `ChangeSet.groups` names a group but not *which* field changed, and since the colour edge now
    /// runs through the group's session rows too, a colour change has to reload them while a rename
    /// or a collapse must still reload only the header — the tests count reloaded rows. Hence a
    /// shadow, like `shadowGroups`/`shadowSessions`.
    ///
    /// `applyGroups` is the only writer for an existing group's entry. `applyStructure` merely adds
    /// entries for new groups and drops them for removed ones: it runs *before* `applyGroups` in
    /// `apply(_:)`, and deliveries are coalesced per run-loop turn, so a blanket refresh there would
    /// hide a colour change that arrived in the same change set as a structural one.
    private var shadowGroupColors: [GroupID: RGB?] = [:]

    private var isApplyingStoreSelection = false
    private var isApplyingStoreCollapse = false
    private var appliedSelection: SessionID?
    private var isOccluded = false
    private var occlusionWindow: NSWindow?

    public init(store: AppStore, theme: Theme = .default) {
        self.store = store
        self.theme = theme
        self.lastMessagePopover = LastMessagePopover(theme: theme)
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
        outline.registerForDraggedTypes([.tkzSidebarSession])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        // `.gap` opens the insertion point between rows instead of drawing a two-pixel line the
        // rows' own `selectionLayer` would sit on top of.
        outline.draggingDestinationFeedbackStyle = .gap

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = theme.sidebarBackground.nsColor
        scroll.wantsLayer = true

        container.addSubview(scroll)
        container.addSubview(strip)
        footer.configure(theme: theme)
        footer.onNewGroup = onNewGroup
        container.addSubview(footer)
        container.scrollView = scroll
        container.summaryStrip = strip
        container.newGroupFooter = footer
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
        footer.configure(theme: theme)
        lastMessagePopover.close()
        lastMessagePopover = LastMessagePopover(theme: theme)
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
        shadowGroupColors = [:]
        for id in shadowGroups {
            shadowSessions[id] = store.state.sessions(in: id).map(\.id)
            shadowGroupColors[id] = store.state.groups[id]?.color
        }
        syncExpansion(for: shadowGroups)
        syncSelectionToOutline(scroll: false)
        updateSummary()
    }

    // MARK: Change-set dispatch

    private func apply(_ change: ChangeSet) {
        // Captured *before* `applyStructure`, which ends in `syncSelectionToOutline` and therefore
        // overwrites `appliedSelection` with the incoming id. Reading it afterwards makes "the row
        // that lost the selection" and "the row that gained it" the same row, so the old one is
        // never reloaded and keeps painting `Theme.selection` — one extra highlighted row per
        // launch, since creating a session selects it in the same change set.
        let losingSelection = appliedSelection
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
            for id in [losingSelection, store.state.selection].compactMap({ $0 }) {
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
        // A colour change also repaints the group's session rows — they carry the same edge, so the
        // stripe would otherwise stop at the header until something else touched them. Resolved
        // after `syncExpansion`, for the same reason the headers are.
        for id in ids {
            let color = store.state.groups[id]?.color
            // `RGB??` against `RGB?`: a group we have never rendered counts as changed.
            guard shadowGroupColors[id] != color else { continue }
            shadowGroupColors[id] = color
            for session in store.state.sessions(in: id) {
                let row = self.row(forSession: session.id)
                if row >= 0 { rows.insert(row) }
            }
        }
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

        // A group whose rows came or went shows a different count in its header, but the group
        // *value* did not change, so `change.groups` never names it. Reload those headers here
        // (GUI pass 2026-09-08: "ACME LEDGER 0" over a freshly launched row).
        var countChanged = IndexSet()
        for groupID in newGroups where (shadowSessions[groupID] ?? []).count != (newSessions[groupID] ?? []).count {
            let row = row(forGroup: groupID)
            if row >= 0 { countChanged.insert(row) }
        }
        if !countChanged.isEmpty {
            outline.reloadData(forRowIndexes: countChanged, columnIndexes: IndexSet(integer: 0))
        }

        shadowGroups = newGroups
        shadowSessions = newSessions
        // Only add and drop keys — never refresh an existing one. See `shadowGroupColors`.
        shadowGroupColors = shadowGroupColors.filter { survivingGroups.contains($0.key) }
        for groupID in newGroups where !shadowGroupColors.keys.contains(groupID) {
            shadowGroupColors[groupID] = state.groups[groupID]?.color
        }

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

    // MARK: Last-message popover

    /// Shows `id`'s last message (via `lastMessageProvider`, or `LiveSessionState.lastStopMessage`
    /// by default) anchored to its row. A missing row or an empty message shows nothing.
    public func showLastMessage(for id: SessionID) {
        let message = lastMessageProvider?(id) ?? store.state.sessions[id]?.live?.lastStopMessage
        guard let message, !message.isEmpty else { return }
        let row = self.row(forSession: id)
        guard row >= 0 else { return }
        lastMessagePopover.show(message: message, relativeTo: outline.rect(ofRow: row), of: outline)
    }

    /// `true` when a click on the status dot should open the popover instead of selecting the row
    /// — design.md's amber/"done" rows, i.e. `waiting` or an idle row still showing the "done" tint.
    private func statusDotClickIsEligible(for id: SessionID) -> Bool {
        guard let session = store.state.sessions[id] else { return false }
        return session.status.isWaiting || (session.live?.isDone ?? false)
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

// MARK: - Drag and drop

// Dragging a session row into another group is a *store* edit: `acceptDrop` calls
// `AppState.moveSession` and nothing else. The rows that leave and arrive are then produced by the
// ordinary `structure` change set through `applyStructure()`, exactly as a launch or a remove is, so
// there is no second, drag-shaped update path that could disagree with the store about what the
// sidebar shows.
//
// **Only sessions drag.** `pasteboardWriterForItem` returns `nil` for a group header, so reordering
// groups stays the `moveGroup` affair it already was.
//
// **A collapsed group is a valid destination**, and the only thing it can offer is "on the header",
// which appends. Hovering one mid-drag also lets AppKit spring-load it open, which runs the ordinary
// `outlineViewItemDidExpand` path and so writes `setGroupCollapsed(false)` to the store — the group
// stays open after the drop. That is wanted: the row has to be somewhere the user can see it.
//
// **The two index bases differ, and that is the one real trap.** `NSOutlineView` reports a
// `childIndex` within the group *as currently displayed* — the dragged row included. `moveSession`
// inserts into the group *after* the dragged session has been pulled out of it. For a drop into a
// different group the two agree; for a drop into the session's own group, every position below the
// row it came from is off by one. So the two are kept apart: `dropTarget(for:childIndex:)` yields
// the *displayed* index, which is what `setDropItem` needs to draw the gap, and
// `storeIndex(forDisplayed:in:dragging:)` rebases it for `moveSession`. Both are pure functions with
// their own tests — a real drag cannot be staged in a headless suite.

extension SidebarViewController {

    /// Where a drop lands, resolved from whatever `NSOutlineView` proposes.
    ///
    /// Every proposal is normalised onto a group, because a session row is never a drop *container*:
    ///
    ///  * a group with no child index — dropping *on* the header, which is also all a collapsed
    ///    group can offer — appends;
    ///  * a group with a child index — that position among its session rows;
    ///  * a session — the position that row occupies in its own group;
    ///  * the root list (between or below the headers) — the end of the group above the drop point,
    ///    or the top of the first group when the drop is above every header.
    ///
    /// The index is *displayed*: it counts the group's session rows as they are on screen right now,
    /// dragged row included, so it can be handed straight back to `setDropItem` to place the gap.
    /// `storeIndex(forDisplayed:in:dragging:)` is what turns it into a `moveSession` argument.
    ///
    /// - Parameters:
    ///   - item: the proposed drop item; `nil` is the root list.
    ///   - childIndex: the proposed child index, or `NSOutlineViewDropOnItemIndex` for "on the item".
    /// - Returns: the destination group and a displayed index (`nil` = on the header, i.e. append),
    ///   or `nil` when there is nowhere sensible to drop.
    func dropTarget(for item: SidebarItem?, childIndex: Int) -> (group: GroupID, displayed: Int?)? {
        let state = store.state

        /// A collapsed group has no visible children, so no child index can point into it — the only
        /// thing to say about such a drop is "this group", which appends.
        func placed(_ id: GroupID, at index: Int) -> (group: GroupID, displayed: Int?) {
            guard state.groups[id]?.isCollapsed != true else { return (id, nil) }
            return (id, min(max(index, 0), state.sessions(in: id).count))
        }

        switch item?.kind {
        case .group(let id):
            guard state.groups[id] != nil else { return nil }
            guard childIndex != NSOutlineViewDropOnItemIndex else { return (id, nil) }
            return placed(id, at: childIndex)

        case .session(let id):
            // A session row is never a container: a drop on one means "take that row's place".
            guard let session = state.sessions[id],
                let index = state.sessions(in: session.groupID).map(\.id).firstIndex(of: id)
            else { return nil }
            return (session.groupID, index)

        case nil:
            // The root list, where `childIndex` counts group headers: `n` means "after group n-1".
            let groups = state.orderedGroups.map(\.id)
            guard !groups.isEmpty, childIndex != NSOutlineViewDropOnItemIndex else { return nil }
            guard childIndex > 0 else { return placed(groups[0], at: 0) }
            return (groups[min(childIndex, groups.count) - 1], nil)
        }
    }

    /// Rebases a displayed drop index onto the list `moveSession` inserts into — the group with
    /// `dragged` already removed. `nil` in, `nil` out: both mean append.
    func storeIndex(forDisplayed displayed: Int?, in group: GroupID, dragging dragged: SessionID) -> Int? {
        guard let displayed else { return nil }
        let rows = store.state.sessions(in: group).map(\.id)
        guard let from = rows.firstIndex(of: dragged) else {
            // Another group: no row is leaving it, so the two bases already agree.
            return min(max(displayed, 0), rows.count)
        }
        // Its own group: every slot below the dragged row shifts up by one once it lifts out.
        return min(max(displayed > from ? displayed - 1 : displayed, 0), max(rows.count - 1, 0))
    }

    /// The session id carried by a sidebar drag, if this drag is one of ours at all.
    func draggedSession(from info: any NSDraggingInfo) -> SessionID? {
        guard let raw = info.draggingPasteboard.string(forType: .tkzSidebarSession) else { return nil }
        return SessionID(raw)
    }
}

extension SidebarViewController {
    public func outlineView(
        _ outlineView: NSOutlineView, pasteboardWriterForItem item: Any
    ) -> (any NSPasteboardWriting)? {
        // `nil` is how a row is told not to drag, which is what a group header wants.
        guard let id = (item as? SidebarItem)?.sessionID else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id.rawValue, forType: .tkzSidebarSession)
        return pasteboardItem
    }

    public func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard draggedSession(from: info) != nil,
            let target = dropTarget(for: item as? SidebarItem, childIndex: index)
        else { return [] }
        // Retarget, so the gap the user sees is the row the drop will actually produce.
        outlineView.setDropItem(
            self.item(.group(target.group)),
            dropChildIndex: target.displayed ?? NSOutlineViewDropOnItemIndex)
        return .move
    }

    public func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        guard let dragged = draggedSession(from: info), store.state.sessions[dragged] != nil,
            let target = dropTarget(for: item as? SidebarItem, childIndex: index)
        else { return false }
        let at = storeIndex(forDisplayed: target.displayed, in: target.group, dragging: dragged)
        store.update { $0.moveSession(dragged, toGroup: target.group, at: at) }
        return true
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
            // Cleared by `prepareForReuse()`, so it is rewired on every vend — see `GroupRowView.onAdd`.
            view.onStatusDotClick = { [weak self] in
                guard let self, self.statusDotClickIsEligible(for: id) else { return false }
                self.showLastMessage(for: id)
                return true
            }
            view.onClose = { [weak self] in self?.onRemoveSession?(id) }
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
