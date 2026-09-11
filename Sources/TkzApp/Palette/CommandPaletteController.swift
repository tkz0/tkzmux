// CommandPaletteController.swift — ⌘P “Search sessions…” and ⇧⌘P “Command palette” (M2.4 / TKZ-20).
//
// design.md → App architecture → Palette: "⇧⌘P; `NSPanel` + `NSVisualEffectView`: fuzzy over
// sessions (title, branch, cwd, group), groups, commands".
//
// Structure: a `.nonactivatingPanel` holding an `NSVisualEffectView`, an `NSSearchField` and a
// view-based `NSTableView` of section headers and result rows, all themed through `ThemeAppKit`.
//
// **All the logic lives in plain methods** — ``updateQuery(_:)``, ``moveSelection(by:)``,
// ``activateSelection()`` — and the panel is built lazily on the first ``present(state:over:)``, so
// the behaviour is unit-testable in a process with no window. The controller owns no application
// state and is wired to nothing: ``onActivate`` and ``onDismiss`` are the whole interface, and wave
// 3 (MainWindowController) attaches them.
//
// Keyboard: the search field keeps first responder, so ↑/↓/Return/Escape arrive as
// `doCommandBy:` selectors on the field editor and are forwarded here — the same pattern
// `MainToolbarController` uses for its search item.

import AppKit
import TkzCore

@MainActor
public final class CommandPaletteController: NSObject {

    /// A rendered line: either a section header or a hit. Headers are skipped by the selection.
    public enum Row: Sendable {
        case header(String)
        case result(PaletteResult)

        public var isSelectable: Bool { if case .result = self { return true }; return false }
        public var result: PaletteResult? { if case .result(let r) = self { return r }; return nil }
    }

    /// How many hits the panel will show. The list is ranked, so the tail is never interesting.
    public static let resultLimit = 60

    public var theme: Theme { didSet { if theme != oldValue { applyTheme() } } }
    public private(set) var mode: PaletteDataSource.Mode
    public private(set) var dataSource: PaletteDataSource
    public private(set) var rows: [Row] = []
    /// Index into ``rows``; always a selectable row, or `nil` when there are no hits.
    public private(set) var selectedIndex: Int?
    public private(set) var query: String = ""

    /// The user chose a row (Return, or a click).
    public var onActivate: ((PaletteResult) -> Void)?
    /// Escape, or the panel resigning key.
    public var onDismiss: (() -> Void)?

    private var panel: NSPanel?
    private var searchField: NSSearchField?
    private var tableView: NSTableView?
    private var effectView: NSVisualEffectView?

    public init(state: AppState = AppState(), mode: PaletteDataSource.Mode = .all, theme: Theme = .default) {
        self.theme = theme
        self.mode = mode
        self.dataSource = PaletteDataSource(state: state, mode: mode)
        super.init()
        rebuildRows()
    }

    // MARK: State

    /// Rebuilds the searchable items. Call whenever the palette is opened, or when a `ChangeSet`
    /// touches sessions/groups while it is open.
    public func update(state: AppState, mode: PaletteDataSource.Mode? = nil) {
        if let mode { self.mode = mode }
        dataSource = PaletteDataSource(state: state, mode: self.mode)
        rebuildRows()
    }

    /// A keystroke in the search field.
    public func updateQuery(_ query: String) {
        self.query = query
        rebuildRows()
    }

    private func rebuildRows() {
        var rows: [Row] = []
        let sections = dataSource.sections(for: query, limit: Self.resultLimit)
        for section in sections {
            // ⌘P is sessions-only; a lone "Sessions" header would be noise.
            if sections.count > 1 { rows.append(.header(section.title)) }
            rows.append(contentsOf: section.results.map(Row.result))
        }
        self.rows = rows
        selectedIndex = rows.firstIndex { $0.isSelectable }
        reloadTable()
    }

    /// The currently highlighted hit.
    public var selectedResult: PaletteResult? {
        selectedIndex.flatMap { rows[$0].result }
    }

    /// The visible hits, in display order.
    public var results: [PaletteResult] { rows.compactMap(\.result) }

    // MARK: Keyboard behaviour

    /// ↓ = +1, ↑ = −1. Skips headers and stops at the ends (no wraparound: a palette that wraps
    /// makes "am I at the bottom?" unanswerable at a glance).
    public func moveSelection(by offset: Int) {
        guard offset != 0, !rows.isEmpty else { return }
        let step = offset > 0 ? 1 : -1
        var remaining = abs(offset)
        var index = selectedIndex ?? (step > 0 ? -1 : rows.count)
        while remaining > 0 {
            var next = index + step
            while next >= 0, next < rows.count, !rows[next].isSelectable { next += step }
            guard next >= 0, next < rows.count else { break }
            index = next
            remaining -= 1
        }
        guard index >= 0, index < rows.count, rows[index].isSelectable else { return }
        selectedIndex = index
        syncTableSelection()
    }

    /// Return.
    public func activateSelection() {
        guard let result = selectedResult else { return }
        onActivate?(result)
        dismiss()
    }

    /// Escape.
    public func dismiss() {
        panel?.orderOut(nil)
        onDismiss?()
    }

    // MARK: Presentation

    /// Shows the panel, centred over `parent` (or on the main screen), with the query cleared.
    public func present(state: AppState, mode: PaletteDataSource.Mode? = nil, over parent: NSWindow? = nil) {
        update(state: state, mode: mode)
        query = ""
        rebuildRows()

        let panel = makePanelIfNeeded()
        searchField?.stringValue = ""
        searchField?.placeholderString =
            self.mode == .sessions ? "Search sessions\u{2026}" : "Type a command or session\u{2026}"

        let frame = panelFrame(over: parent)
        panel.setFrame(frame, display: false)
        panel.makeKeyAndOrderFront(nil)
        if let searchField { panel.makeFirstResponder(searchField) }
    }

    /// Centred horizontally, a fifth from the top — the usual palette placement.
    func panelFrame(over parent: NSWindow?) -> NSRect {
        let host = parent?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(max(host.width * 0.5, 420), 720)
        let height = min(max(host.height * 0.5, 240), 480)
        return NSRect(
            x: host.midX - width / 2,
            y: host.maxY - height - host.height * 0.18,
            width: width,
            height: height)
    }

    @discardableResult
    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
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
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.translatesAutoresizingMaskIntoConstraints = false
        effectView = effect

        let field = NSSearchField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = Theme.Fonts.ui(theme.fontUI.title)
        field.focusRingType = .none
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        // Keystrokes arrive through `controlTextDidChange` only — wiring target/action *as well*
        // would rebuild and reload the list twice per character.
        field.delegate = self
        searchField = field

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        table.action = #selector(tableClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("palette"))
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

        effect.addSubview(field)
        effect.addSubview(scroll)
        panel.contentView = effect
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
        ])

        self.panel = panel
        applyTheme()
        reloadTable()
        return panel
    }

    private func applyTheme() {
        effectView?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        searchField?.font = Theme.Fonts.ui(theme.fontUI.title)
        tableView?.reloadData()
    }

    private func reloadTable() {
        tableView?.reloadData()
        syncTableSelection()
    }

    private func syncTableSelection() {
        guard let tableView else { return }
        if let selectedIndex {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: Actions

    @objc private func tableClicked() {
        guard let row = tableView?.clickedRow, row >= 0, row < rows.count, rows[row].isSelectable else { return }
        selectedIndex = row
        syncTableSelection()
    }

    @objc private func tableDoubleClicked() {
        tableClicked()
        activateSelection()
    }

    // MARK: Test access

    /// The live panel, once ``present(state:over:)`` has built it.
    var panelForTesting: NSPanel? { panel }
    var searchFieldForTesting: NSSearchField? { searchField }
    var tableViewForTesting: NSTableView? { tableView }
}

// MARK: - Keyboard

extension CommandPaletteController: NSSearchFieldDelegate {
    /// The search field keeps first responder; the list keys arrive here as editor commands.
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

extension CommandPaletteController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 40 }
        return rows[row].isSelectable ? 40 : 22
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < rows.count && rows[row].isSelectable
    }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = Theme.Fonts.ui(theme.fontUI.caption, weight: .semibold)
            label.textColor = theme.foregroundDim.nsColor
            return padded(label, leading: 12, top: 4)
        case .result(let result):
            return PaletteRowView(result: result, theme: theme)
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView, tableView.selectedRow >= 0, tableView.selectedRow < rows.count else { return }
        if rows[tableView.selectedRow].isSelectable { selectedIndex = tableView.selectedRow }
    }

    private func padded(_ view: NSView, leading: CGFloat, top: CGFloat) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
        ])
        return container
    }
}

// MARK: - Row view

/// One hit: title with the matched characters emphasised, dim subtitle (labelled with the field the
/// hit came from when it was not the title), and a trailing hint (`⇧⌘P`, the session's status).
final class PaletteRowView: NSTableCellView {
    init(result: PaletteResult, theme: Theme) {
        super.init(frame: .zero)

        let title = NSTextField(labelWithAttributedString: Self.titleString(result, theme: theme))
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithAttributedString: Self.subtitleString(result, theme: theme))
        subtitle.lineBreakMode = .byTruncatingMiddle
        let trailing = NSTextField(labelWithString: result.item.trailing ?? "")
        trailing.font = Theme.Fonts.mono(theme.fontMono.detail)
        trailing.textColor = theme.foregroundDim.nsColor

        for view in [title, subtitle, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func titleString(_ result: PaletteResult, theme: Theme) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: result.item.title,
            attributes: [
                .font: Theme.Fonts.ui(theme.fontUI.title),
                .foregroundColor: theme.foreground.nsColor,
            ])
        for range in result.titleRanges {
            out.addAttributes(
                [
                    .font: Theme.Fonts.ui(theme.fontUI.title, weight: .bold),
                    .foregroundColor: theme.accent.nsColor,
                ],
                range: NSRange(range, in: result.item.title))
        }
        return out
    }

    /// Non-title hits are labelled with the field, so a row that matched on `branch` explains itself.
    static func subtitleString(_ result: PaletteResult, theme: Theme) -> NSAttributedString {
        let prefix = result.field == .title ? "" : "\(result.field.label): "
        let body = result.field == .title ? result.item.subtitle : result.matchedText
        let out = NSMutableAttributedString(
            string: prefix + body,
            attributes: [
                .font: Theme.Fonts.mono(theme.fontMono.detail),
                .foregroundColor: theme.foregroundMuted.nsColor,
            ])
        if result.field != .title {
            for range in result.ranges {
                let ns = NSRange(range, in: result.matchedText)
                out.addAttributes(
                    [.foregroundColor: theme.accent.nsColor],
                    range: NSRange(location: ns.location + (prefix as NSString).length, length: ns.length))
            }
        }
        return out
    }
}
