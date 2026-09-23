// ActivityFeedController — ⌘I, the catch-up inbox over the terminal.
//
// The same glass as the ⇧⌘P palette and the ⌥⌘P card: a floating, key-taking panel top-centred
// over the detail area, a filter field on top, the list under it, the key hints at the bottom.
// `ActivityFeedModel` decides the rows; this controller draws them, walks them with ↑↓, opens the
// row with ↵, folds and unfolds a thread with ← →, and offers *Mark as unread* on right-click.
//
// Nothing here writes the store. ↵ and the context menu hand a session id to the window
// controller (`onActivate`, `onMarkUnread`), which runs the reducer; the panel re-renders from
// the delivery like every other observer.

import AppKit
import TkzCore

@MainActor
public final class ActivityFeedController: NSObject, NSWindowDelegate {
    public static let width: CGFloat = 640

    private let store: AppStore
    public var theme: Theme { didSet { applyTheme() } }

    /// ↵ on a row: select that session (the window controller closes nothing else; the panel
    /// dismisses itself first).
    var onActivate: ((SessionID) -> Void)?
    /// The context menu's *Mark as unread*.
    var onMarkUnread: ((SessionID) -> Void)?
    /// The clock, injectable so a test can pin the ages.
    var now: () -> Date = Date.init
    /// How the panel comes on screen. Tests replace it so no window is ever ordered front.
    var orderFront: (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }

    private var panel: ActivityFeedPanel?
    private var effectView: NSVisualEffectView?
    private var searchField: NSSearchField?
    private var tableView: ActivityTableView?
    private var scrollView: NSScrollView?
    private var footer: ActivityFooterView?

    private var token: AppStore.ObserverToken?
    private var anchorFrame: NSRect?
    private var query = ""
    private var expanded: Set<SessionID> = []
    private(set) var rows: [ActivityFeedModel.Row] = []
    private var selectedIndex: Int?

    public init(store: AppStore, theme: Theme) {
        self.store = store
        self.theme = theme
        super.init()
        token = store.addObserver { [weak self] change in
            guard let self, self.isShown else { return }
            // A new entry, a read flip, a title change, a working row's status — all redraw. The
            // elapsed time on a pinned row rides the 5 s status tick's `sessions` delivery.
            if change.activity || change.selection || change.structure || !change.sessions.isEmpty
                || !change.groups.isEmpty
            {
                rebuildRows(keepingSelection: true)
            }
        }
    }

    // MARK: Presentation

    /// Tracked here rather than read off `panel.isVisible`, so a test whose `orderFront` stub
    /// never puts the panel on screen still sees the feed as up.
    public private(set) var isShown = false

    /// ⌘I: up if down, down if up.
    public func toggle(over anchor: NSRect?) {
        if isShown { dismiss() } else { present(over: anchor) }
    }

    /// Shows the panel with the filter cleared and the newest thread selected.
    public func present(over anchor: NSRect?) {
        anchorFrame = anchor
        query = ""
        expanded = []
        let panel = makePanelIfNeeded()
        searchField?.stringValue = ""
        rebuildRows(keepingSelection: false)
        place(panel)
        isShown = true
        orderFront(panel)
        if let searchField { panel.makeFirstResponder(searchField) }
    }

    public func dismiss() {
        guard isShown, let panel else { return }
        isShown = false
        panel.orderOut(nil)
    }

    /// Esc, ⌘I again, ↵, or the panel losing key (a click elsewhere).
    public func windowDidResignKey(_ notification: Notification) { dismiss() }

    // MARK: Rows

    private func rebuildRows(keepingSelection: Bool) {
        let previous = keepingSelection ? selectedIndex.flatMap { $0 < rows.count ? rows[$0].identity : nil } : nil
        rows = ActivityFeedModel.rows(state: store.state, query: query, expanded: expanded, now: now())
        if let previous, let index = rows.firstIndex(where: { $0.identity == previous }) {
            selectedIndex = index
        } else {
            selectedIndex = rows.firstIndex(where: \.isSelectable)
        }
        tableView?.reloadData()
        syncTableSelection()
        if let panel, isShown { place(panel) }
    }

    func updateQuery(_ text: String) {
        guard text != query else { return }
        query = text
        rebuildRows(keepingSelection: false)
    }

    /// ↑ / ↓: the next selectable row, no wraparound.
    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        var index = selectedIndex ?? (delta > 0 ? -1 : rows.count)
        repeat {
            index += delta
            guard index >= 0, index < rows.count else { return }
        } while !rows[index].isSelectable
        selectedIndex = index
        syncTableSelection()
    }

    /// ↵: the selected row's session, then the panel goes.
    func activateSelection() {
        guard let selectedIndex, selectedIndex < rows.count, let id = rows[selectedIndex].sessionID else { return }
        dismiss()
        onActivate?(id)
    }

    /// → unfolds the selected thread, ← folds it (or the thread a folded row belongs to).
    func setSelectedThreadExpanded(_ expand: Bool) {
        guard let selectedIndex, selectedIndex < rows.count else { return }
        let target: SessionID?
        switch rows[selectedIndex] {
        case .thread(let row): target = row.olderCount > 0 ? row.sessionID : nil
        case .folded(let row): target = expand ? nil : row.sessionID
        case .working, .empty: target = nil
        }
        guard let target else { return }
        if expand { expanded.insert(target) } else { expanded.remove(target) }
        // Folding from a folded row lands the selection on the thread it was under.
        if !expand, case .folded = rows[selectedIndex] {
            self.selectedIndex = rows.firstIndex { if case .thread(let t) = $0 { return t.sessionID == target }; return false }
        }
        rebuildRows(keepingSelection: true)
    }

    private func contextMenu(forRow index: Int) -> NSMenu? {
        guard index >= 0, index < rows.count else { return nil }
        guard case .thread(let row) = rows[index] else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Mark as Unread", action: #selector(markUnread(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = row.sessionID.rawValue
        item.identifier = NSUserInterfaceItemIdentifier("tkzmux.activity.markUnread")
        item.isEnabled = !row.unread
        menu.addItem(item)
        menu.autoenablesItems = false
        return menu
    }

    @objc private func markUnread(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = SessionID(raw) else { return }
        onMarkUnread?(id)
    }

    // MARK: Panel

    private func makePanelIfNeeded() -> ActivityFeedPanel {
        if let panel { return panel }

        let panel = ActivityFeedPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.identifier = NSUserInterfaceItemIdentifier("tkzmux.activity")
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.borderWidth = 1
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        effectView = effect

        let field = NSSearchField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.focusRingType = .none
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.placeholderString = "Filter by session, group or message\u{2026}"
        field.delegate = self
        searchField = field

        let table = ActivityTableView()
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        table.action = #selector(tableClicked)
        table.onContextMenu = { [weak self] index in self?.contextMenu(forRow: index) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("activity"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        tableView = table

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scrollView = scroll

        let hints = ActivityFooterView(theme: theme)
        hints.translatesAutoresizingMaskIntoConstraints = false
        footer = hints

        effect.addSubview(field)
        effect.addSubview(scroll)
        effect.addSubview(hints)
        panel.contentView = effect
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: hints.topAnchor),
            hints.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hints.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hints.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])

        self.panel = panel
        applyTheme()
        return panel
    }

    private func applyTheme() {
        effectView?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        effectView?.layer?.borderColor = theme.accent.nsColor.withAlphaComponent(0.35).cgColor
        searchField?.font = Theme.Fonts.ui(theme.fontUI.title)
        footer?.apply(theme: theme)
        tableView?.reloadData()
    }

    /// The height the rows want, bracketed by the field and the footer.
    private var contentHeight: CGFloat {
        let rowsHeight = rows.reduce(CGFloat(0)) { $0 + Self.height(of: $1) + 2 }
        return 14 + 22 + 10 + rowsHeight + 8 + ActivityFooterView.height
    }

    /// Top-centred over the anchor, 40 pt down; never taller than ~60 % of it.
    private func place(_ panel: NSPanel) {
        let maxHeight = anchorFrame.map { max(200, ($0.height * 0.6).rounded()) } ?? 480
        let size = NSSize(width: Self.width, height: min(max(contentHeight, 160), maxHeight))
        panel.setFrame(Self.frame(for: size, over: anchorFrame), display: true)
    }

    /// 40 pt below the anchor's top, horizontally centred — or, with no anchor, a fifth down the
    /// main screen.
    static func frame(for size: NSSize, over anchor: NSRect?) -> NSRect {
        if let anchor {
            return NSRect(
                x: (anchor.midX - size.width / 2).rounded(),
                y: (anchor.maxY - 40 - size.height).rounded(),
                width: size.width, height: size.height)
        }
        let host = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(
            x: (host.midX - size.width / 2).rounded(),
            y: (host.maxY - size.height - host.height * 0.18).rounded(),
            width: size.width, height: size.height)
    }

    private func syncTableSelection() {
        guard let tableView else { return }
        if let selectedIndex, selectedIndex < rows.count {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        } else {
            tableView.deselectAll(nil)
        }
    }

    @objc private func tableClicked() {
        guard let tableView, tableView.clickedRow >= 0, tableView.clickedRow < rows.count else { return }
        let index = tableView.clickedRow
        guard rows[index].isSelectable else { return }
        selectedIndex = index
        syncTableSelection()
    }

    @objc private func tableDoubleClicked() {
        tableClicked()
        activateSelection()
    }

    /// The `+N older` affordance on a thread row.
    private func toggleExpanded(_ id: SessionID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        rebuildRows(keepingSelection: true)
    }

    static func height(of row: ActivityFeedModel.Row) -> CGFloat {
        switch row {
        case .working: 32
        case .thread(let thread): thread.head.preview.isEmpty ? 40 : 64
        case .folded(let folded): folded.event.preview.isEmpty ? 26 : 44
        case .empty: 40
        }
    }

    // MARK: Test access

    var panelForTesting: NSPanel? { panel }
    var searchFieldForTesting: NSSearchField? { searchField }
    var tableViewForTesting: NSTableView? { tableView }
    var rowsForTesting: [ActivityFeedModel.Row] { rows }
    var selectedIndexForTesting: Int? { selectedIndex }
    var expandedForTesting: Set<SessionID> { expanded }
    func contextMenuForTesting(row: Int) -> NSMenu? { contextMenu(forRow: row) }
}

// MARK: - Keyboard

extension ActivityFeedController: NSSearchFieldDelegate {
    /// The filter field keeps first responder; the list keys arrive as editor commands. ← and →
    /// are taken for the threads while the panel is up, as the ⌘F overlay takes them for its
    /// chips; ⌥← / ⌥→ and Home/End still move the caret.
    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveRight(_:)):
            setSelectedThreadExpanded(true)
            return true
        case #selector(NSResponder.moveLeft(_:)):
            setSelectedThreadExpanded(false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        updateQuery(field.stringValue)
    }
}

// MARK: - Table

extension ActivityFeedController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 40 }
        return Self.height(of: rows[row])
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < rows.count && rows[row].isSelectable
    }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .working(let working):
            return ActivityWorkingRowView(row: working, theme: theme)
        case .thread(let thread):
            let view = ActivityThreadRowView(row: thread, age: ActivityFeedModel.age(of: thread.head, now: now()), theme: theme)
            view.onToggleOlder = { [weak self] in self?.toggleExpanded(thread.sessionID) }
            return view
        case .folded(let folded):
            return ActivityFoldedRowView(row: folded, age: ActivityFeedModel.age(of: folded.event, now: now()), theme: theme)
        case .empty(let text):
            return ActivityEmptyRowView(text: text, theme: theme)
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView, tableView.selectedRow >= 0, tableView.selectedRow < rows.count else { return }
        if rows[tableView.selectedRow].isSelectable { selectedIndex = tableView.selectedRow }
    }
}

// MARK: - Panel and table

/// Escape closes it whether the key lands on the field's editor or the panel itself.
final class ActivityFeedPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }  // Escape
        super.keyDown(with: event)
    }
}

/// Right-click resolves the row under the pointer without moving the selection, like the
/// sidebar's outline view.
final class ActivityTableView: NSTableView {
    var onContextMenu: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        guard index >= 0 else { return nil }
        return onContextMenu?(index)
    }
}
