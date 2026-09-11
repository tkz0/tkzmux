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
//
// Two placements (``Presentation``), because the design gives the two entry points different
// shapes. ⇧⌘P centres the panel and lets it take key. The toolbar's "Search sessions…" field
// (design 2c.6, TKZ-52) hangs the same panel from the window's top-right as a **child window that
// never becomes key**, hides the panel's own field, and drives ``updateQuery(_:)`` /
// ``moveSelection(by:)`` / ``activateSelection()`` from the toolbar field's editor commands — that
// is the only way the caret can stay in the toolbar while a list is on screen.

import AppKit
import TkzCore

@MainActor
public final class CommandPaletteController: NSObject {

    /// A rendered line. Headers are skipped by the selection; everything else can be activated.
    public enum Row: Sendable {
        /// `Transcripts · 7 hits` — the detail is the part after the middle dot.
        case header(title: String, detail: String?)
        case result(PaletteResult)
        case transcript(TranscriptRow)
        case file(FileRow)
        case action(SearchAction)
        /// `Show 4 more…` — expands its section in place.
        case more(SearchScope, remaining: Int)

        public var isSelectable: Bool { if case .header = self { return false }; return true }

        public var result: PaletteResult? { if case .result(let r) = self { return r }; return nil }

        /// What activating this row means, or `nil` for a header.
        public var activation: PaletteActivation? {
            switch self {
            case .header: nil
            case .result(let r): .result(r)
            case .transcript(let r): .transcript(r)
            case .file(let r): .file(r)
            case .action(let a): .action(a)
            case .more(let scope, _): .showMore(scope)
            }
        }

        /// Stable identity, so a rebuild that merges late results can keep the selection put.
        var identity: String {
            switch self {
            case .header(let title, _): "header:" + title
            case .result(let r): r.id
            case .transcript(let r): r.id
            case .file(let r): r.id
            case .action(let a): a.id
            case .more(let scope, _): "more:" + scope.rawValue
            }
        }
    }

    /// How many hits the panel will show. The list is ranked, so the tail is never interesting.
    public static let resultLimit = 60

    /// 2c.6 shows three transcript hits and then `Show 4 more…`. A section only truncates while
    /// the overlay is showing every kind at once; narrowing to one chip shows that kind in full.
    public static let sectionPreviewLimit = 3
    /// Sessions get a longer leash than the other sections — they are what ⌘P is for.
    public static let sessionPreviewLimit = 6

    /// Where the panel sits, and therefore who owns the keyboard.
    ///
    /// * ``centred`` — ⇧⌘P. The panel is key, its own `NSSearchField` is first responder.
    /// * ``anchored`` — the toolbar's "Search sessions…" field (design 2c.6). The panel hangs from
    ///   the window's top-right as a child window and **never becomes key**: the toolbar field keeps
    ///   first responder and forwards every keystroke here, so the caret stays where the user put it.
    public enum Presentation: Sendable {
        case centred
        case anchored
    }

    /// 2c.6 geometry: the overlay is 560 pt wide and hangs 14 pt from the window's right edge,
    /// 44 pt below its top — i.e. just under the 48 pt toolbar, overlapping it by 4 pt.
    public static let anchoredWidth: CGFloat = 560
    public static let anchoredInsetRight: CGFloat = 14
    public static let anchoredInsetTop: CGFloat = 44

    public var theme: Theme { didSet { if theme != oldValue { applyTheme() } } }
    public private(set) var mode: PaletteDataSource.Mode
    public private(set) var dataSource: PaletteDataSource
    /// The state the sections are assembled from — the Actions row needs group names, which the
    /// pre-folded `PaletteDataSource` items no longer carry.
    public private(set) var state: AppState
    /// Which chip is lit (design 2c.6). Only the anchored overlay draws the chips; ⇧⌘P ignores it.
    public private(set) var scope: SearchScope = .all
    public private(set) var groupFilter: SearchGroupFilter = .allGroups
    /// Sections the user expanded with "Show N more…", cleared whenever the query changes.
    private var expandedScopes: Set<SearchScope> = []
    /// Late-arriving sections, merged in without disturbing the selection.
    public private(set) var transcriptRows: [TranscriptRow] = []
    public private(set) var fileRows: [FileRow] = []
    public private(set) var rows: [Row] = []
    /// Index into ``rows``; always a selectable row, or `nil` when there are no hits.
    public private(set) var selectedIndex: Int?
    public private(set) var query: String = ""

    /// The user chose a row (Return, or a click). `Show N more…` never reaches here — it is
    /// handled in place.
    public var onActivate: ((PaletteActivation) -> Void)?
    /// Escape, or the panel resigning key.
    public var onDismiss: (() -> Void)?

    private var panel: NSPanel?
    private var searchField: NSSearchField?
    private var tableView: NSTableView?
    private var effectView: NSVisualEffectView?
    private var scrollView: NSScrollView?
    private var chipBar: SearchChipBarView?
    private var footer: SearchFooterView?
    /// Swapped when the panel's own field gives way to the chip bar in ``Presentation/anchored``.
    private var scrollTopToField: NSLayoutConstraint?
    private var scrollTopToChips: NSLayoutConstraint?
    private var scrollBottomToEffect: NSLayoutConstraint?
    private var scrollBottomToFooter: NSLayoutConstraint?
    private(set) var presentation: Presentation = .centred
    /// The window the anchored panel is a child of, so it can be detached on dismiss.
    private weak var anchorWindow: NSWindow?
    private var anchorObservers: [NSObjectProtocol] = []

    public init(state: AppState = AppState(), mode: PaletteDataSource.Mode = .all, theme: Theme = .default) {
        self.theme = theme
        self.mode = mode
        self.state = state
        self.dataSource = PaletteDataSource(state: state, mode: mode)
        super.init()
        rebuildRows()
    }

    // MARK: State

    /// Rebuilds the searchable items. Call whenever the palette is opened, or when a `ChangeSet`
    /// touches sessions/groups while it is open.
    public func update(state: AppState, mode: PaletteDataSource.Mode? = nil) {
        if let mode { self.mode = mode }
        self.state = state
        dataSource = PaletteDataSource(state: state, mode: self.mode)
        rebuildRows(preservingSelection: true)
    }

    /// A keystroke in the search field.
    public func updateQuery(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        // A new query invalidates everything the old one produced; the async sections re-arrive.
        expandedScopes.removeAll()
        transcriptRows = []
        fileRows = []
        rebuildRows()
    }

    /// Tab / ⇧Tab over the chip row.
    public func cycleScope(by offset: Int) {
        setScope(scope.cycled(by: offset))
    }

    public func setScope(_ scope: SearchScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        expandedScopes.removeAll()
        rebuildRows()
    }

    public func setGroupFilter(_ filter: SearchGroupFilter) {
        guard filter != groupFilter else { return }
        groupFilter = filter
        rebuildRows()
    }

    /// Late transcript hits for the current query. Merged without moving the selection — the user
    /// may already be arrowing through the sessions that rendered on the first keystroke.
    public func setTranscriptRows(_ rows: [TranscriptRow]) {
        transcriptRows = rows
        rebuildRows(preservingSelection: true)
    }

    public func setFileRows(_ rows: [FileRow]) {
        fileRows = rows
        rebuildRows(preservingSelection: true)
    }

    private func rebuildRows(preservingSelection: Bool = false) {
        let previous = preservingSelection ? selectedIndex.map { rows[$0].identity } : nil
        rows = presentation == .anchored ? anchoredRows() : centredRows()

        if let previous, let index = rows.firstIndex(where: { $0.identity == previous }) {
            selectedIndex = index
        } else {
            selectedIndex = rows.firstIndex { $0.isSelectable }
        }
        chipBar?.update(scope: scope, filterTitle: groupFilter.title(in: state), theme: theme)
        reloadTable()
        layoutAnchoredIfNeeded()
    }

    /// ⇧⌘P: one flat run of sections, headers only when there is more than one to tell apart.
    private func centredRows() -> [Row] {
        var rows: [Row] = []
        let sections = dataSource.sections(for: query, limit: Self.resultLimit)
        for section in sections {
            // ⌘P is sessions-only; a lone "Sessions" header would be noise.
            if sections.count > 1 { rows.append(.header(title: section.title, detail: nil)) }
            rows.append(contentsOf: section.results.map(Row.result))
        }
        return rows
    }

    /// The toolbar overlay (2c.6): up to four sections, each headed and each truncated to a preview
    /// with a `Show N more…` tail while the `All` chip is lit.
    private func anchoredRows() -> [Row] {
        var rows: [Row] = []

        if scope.includesSessions {
            // The overlay matches contiguously; ⇧⌘P's `centredRows` keeps the fuzzy matcher.
            let hits = dataSource.search(query, limit: Self.resultLimit, matching: .substring)
                .filter { $0.item.kind == .session && groupFilter.admits($0.item.groupID) }
            appendSection(
                &rows, title: "Sessions", detail: nil, items: hits, scope: .sessions,
                previewLimit: Self.sessionPreviewLimit, row: Row.result)
        }
        if scope.includesTranscripts {
            let hits = transcriptRows.filter { admits($0.sessionID) }
            appendSection(
                &rows, title: "Transcripts", detail: hitCount(hits.count),
                items: hits, scope: .transcripts,
                previewLimit: Self.sectionPreviewLimit, row: Row.transcript)
        }
        if scope.includesFiles {
            let hits = fileRows.filter { admits($0.sessionID) }
            appendSection(
                &rows, title: "Files changed", detail: hitCount(hits.count),
                items: hits, scope: .filesChanged,
                previewLimit: Self.sectionPreviewLimit, row: Row.file)
        }
        if scope.includesActions, let action = newSessionAction() {
            rows.append(.header(title: "Actions", detail: nil))
            rows.append(.action(action))
        }
        return rows
    }

    private func appendSection<Item>(
        _ rows: inout [Row],
        title: String,
        detail: String?,
        items: [Item],
        scope sectionScope: SearchScope,
        previewLimit: Int,
        row: (Item) -> Row
    ) {
        guard !items.isEmpty else { return }
        // A narrowed chip, or an expanded section, shows everything it has.
        let truncates = scope == .all && !expandedScopes.contains(sectionScope)
        let shown = truncates ? Array(items.prefix(previewLimit)) : items
        rows.append(.header(title: title, detail: detail))
        rows.append(contentsOf: shown.map(row))
        if shown.count < items.count {
            rows.append(.more(sectionScope, remaining: items.count - shown.count))
        }
    }

    /// The `in: … ▾` filter, applied to a row that only carries a session id.
    private func admits(_ sessionID: SessionID) -> Bool {
        groupFilter.admits(state.sessions[sessionID]?.groupID)
    }

    private func hitCount(_ count: Int) -> String? {
        count > 0 ? "\(count) hit\(count == 1 ? "" : "s")" : nil
    }

    /// `＋ New session in <group> with prompt "…"` — 2c.6's Actions row. The group is the one the
    /// filter names, else the selected session's, else the first.
    private func newSessionAction() -> SearchAction? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let groupID: GroupID? = {
            if case .group(let id) = groupFilter { return id }
            if let selected = state.selection, let session = state.sessions[selected] {
                return session.groupID
            }
            return state.orderedGroups.first?.id
        }()
        guard let groupID, let group = state.groups[groupID] else { return nil }
        let shown = trimmed.count > 24 ? String(trimmed.prefix(24)) + "\u{2026}" : trimmed
        return SearchAction(
            kind: .newSessionWithPrompt,
            title: "\u{FF0B} New session in \(group.name) with prompt \u{201C}\(shown)\u{201D}",
            trailing: "\u{2318}\u{21A9}",
            groupID: groupID,
            prompt: trimmed)
    }

    /// The currently highlighted hit, when it is a session/group/command row.
    public var selectedResult: PaletteResult? {
        selectedIndex.flatMap { rows[$0].result }
    }

    /// What ↵ would do right now.
    public var selectedActivation: PaletteActivation? {
        selectedIndex.flatMap { rows[$0].activation }
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
        guard let activation = selectedActivation else { return }
        // "Show N more…" is not a destination: it grows its section and leaves the overlay up.
        if case .showMore(let scope) = activation {
            expandedScopes.insert(scope)
            rebuildRows(preservingSelection: true)
            return
        }
        onActivate?(activation)
        dismiss()
    }

    /// ⌘↵ — runs the Actions row whatever the selection is (2c.6 prints the shortcut on it).
    /// Returns `false` when the overlay has no action to run.
    @discardableResult
    public func activateActionRow() -> Bool {
        guard let index = rows.firstIndex(where: { if case .action = $0 { return true }; return false }),
            let activation = rows[index].activation
        else { return false }
        selectedIndex = index
        onActivate?(activation)
        dismiss()
        return true
    }

    /// Escape.
    public func dismiss() {
        detachFromAnchor()
        panel?.orderOut(nil)
        onDismiss?()
    }

    /// Whether the panel is on screen. The toolbar field asks before re-presenting, so that a
    /// keystroke updates the list instead of rebuilding the window.
    public var isPresented: Bool { panel?.isVisible ?? false }

    /// True while the panel itself is key — which is what a click on one of its rows does. The
    /// toolbar field's end-of-editing must not read that as "focus left the search".
    public var ownsKeyWindow: Bool { panel != nil && NSApp.keyWindow === panel }

    // MARK: Presentation

    /// Shows the panel, centred over `parent` (or on the main screen), with the query cleared.
    public func present(state: AppState, mode: PaletteDataSource.Mode? = nil, over parent: NSWindow? = nil) {
        detachFromAnchor()
        presentation = .centred
        update(state: state, mode: mode)
        query = ""
        rebuildRows()

        let panel = makePanelIfNeeded()
        applyPresentation()
        searchField?.stringValue = ""
        searchField?.placeholderString =
            self.mode == .sessions ? "Search sessions\u{2026}" : "Type a command or session\u{2026}"

        let frame = panelFrame(over: parent)
        panel.setFrame(frame, display: false)
        panel.makeKeyAndOrderFront(nil)
        if let searchField { panel.makeFirstResponder(searchField) }
    }

    /// Shows the panel under the toolbar's search field (design 2c.6), **without taking key**.
    ///
    /// The query is deliberately *not* cleared: the text lives in the toolbar field, and this is
    /// called again on every keystroke. Sends the panel to the back of the responder chain by never
    /// calling `makeKeyAndOrderFront` — `MainWindowController` forwards ↑/↓/↵/esc from the field.
    public func present(anchoredTo parent: NSWindow, state: AppState, mode: PaletteDataSource.Mode = .sessions) {
        let alreadyUp = presentation == .anchored && panel?.isVisible == true
        presentation = .anchored
        // This is called once per keystroke, and `update` re-folds every session's searchable text
        // (see `PaletteDataSource`). Fold on the way in, then only search.
        if !alreadyUp { update(state: state, mode: mode) }

        let panel = makePanelIfNeeded()
        applyPresentation()
        attach(to: parent)
        layoutAnchored()
        panel.orderFront(nil)
    }

    /// 2c.6: 560 pt wide, pinned 14 pt from the host's right edge and 44 pt below its top. Pure
    /// geometry on rects so it is testable with no window.
    static func anchoredFrame(host: NSRect, contentHeight: CGFloat) -> NSRect {
        let width = anchoredWidth
        let height = min(max(contentHeight, 120), 560)
        return NSRect(
            x: host.maxX - anchoredInsetRight - width,
            y: host.maxY - anchoredInsetTop - height,
            width: width,
            height: height)
    }

    /// The height the current rows want, including the list's own padding.
    var anchoredContentHeight: CGFloat {
        let rowsHeight = rows.reduce(CGFloat(0)) { total, row in
            total + Self.height(of: row, presentation: .anchored) + 2
        }
        // The chip bar and the footer hint bar bracket the list (2c.6).
        return rowsHeight + 16 + SearchChipBarView.height + SearchFooterView.height
    }

    private func layoutAnchored() {
        guard presentation == .anchored, let panel, let host = anchorWindow?.frame else { return }
        panel.setFrame(Self.anchoredFrame(host: host, contentHeight: anchoredContentHeight), display: true)
    }

    private func layoutAnchoredIfNeeded() {
        guard presentation == .anchored, panel?.isVisible == true else { return }
        layoutAnchored()
    }

    /// Swaps the panel between ⇧⌘P's shape (own field, no chrome) and 2c.6's (chip bar, key hints,
    /// accent border) without rebuilding anything.
    private func applyPresentation() {
        let anchored = presentation == .anchored
        searchField?.isHidden = anchored
        chipBar?.isHidden = !anchored
        footer?.isHidden = !anchored
        scrollTopToField?.isActive = !anchored
        scrollTopToChips?.isActive = anchored
        scrollBottomToEffect?.isActive = !anchored
        scrollBottomToFooter?.isActive = anchored
        panel?.becomesKeyOnlyIfNeeded = anchored
        effectView?.layer?.cornerRadius = anchored ? 12 : 10
        effectView?.layer?.borderWidth = anchored ? 1 : 0
        applyTheme()
    }

    /// A child window follows the parent when it *moves*, but not when it *resizes* — the top-right
    /// corner the overlay hangs from is exactly what a resize changes, so both are observed.
    private func attach(to parent: NSWindow) {
        guard let panel else { return }
        if anchorWindow === parent { return }
        detachFromAnchor()
        anchorWindow = parent
        parent.addChildWindow(panel, ordered: .above)
        let centre = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            let token = centre.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutAnchoredIfNeeded() }
            }
            anchorObservers.append(token)
        }
    }

    private func detachFromAnchor() {
        for token in anchorObservers { NotificationCenter.default.removeObserver(token) }
        anchorObservers.removeAll()
        if let panel, let anchorWindow { anchorWindow.removeChildWindow(panel) }
        anchorWindow = nil
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
        scrollView = scroll

        // 2c.6 brackets the list with a chip row and a key-hint row. Both are built here and simply
        // hidden in the centred presentation, so there is one panel and one table either way.
        let chips = SearchChipBarView(theme: theme)
        chips.translatesAutoresizingMaskIntoConstraints = false
        chips.onSelectScope = { [weak self] scope in self?.setScope(scope) }
        chipBar = chips

        let hints = SearchFooterView(theme: theme)
        hints.translatesAutoresizingMaskIntoConstraints = false
        footer = hints

        effect.addSubview(field)
        effect.addSubview(chips)
        effect.addSubview(scroll)
        effect.addSubview(hints)
        panel.contentView = effect
        // The list hangs off the field when the panel owns the query, and off the chip bar when the
        // toolbar field does (``applyPresentation``).
        let scrollTopToField = scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10)
        let scrollTopToChips = scroll.topAnchor.constraint(equalTo: chips.bottomAnchor, constant: 2)
        let scrollBottomToEffect = scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8)
        let scrollBottomToFooter = scroll.bottomAnchor.constraint(equalTo: hints.topAnchor)
        self.scrollTopToField = scrollTopToField
        self.scrollTopToChips = scrollTopToChips
        self.scrollBottomToEffect = scrollBottomToEffect
        self.scrollBottomToFooter = scrollBottomToFooter
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            chips.topAnchor.constraint(equalTo: effect.topAnchor),
            chips.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hints.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hints.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hints.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scrollTopToField,
            scrollBottomToEffect,
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
        ])

        self.panel = panel
        applyTheme()
        reloadTable()
        return panel
    }

    private func applyTheme() {
        effectView?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        // 2c.6's 1 pt accent hairline at 35 %.
        effectView?.layer?.borderColor = theme.accent.nsColor.withAlphaComponent(0.35).cgColor
        searchField?.font = Theme.Fonts.ui(theme.fontUI.title)
        chipBar?.update(scope: scope, filterTitle: groupFilter.title(in: state), theme: theme)
        footer?.apply(theme: theme)
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
        return Self.height(of: rows[row], presentation: presentation)
    }

    /// 2c.6's rows are single-line and tighter than ⇧⌘P's two-line ones.
    static func height(of row: Row, presentation: Presentation) -> CGFloat {
        switch row {
        case .header: 22
        case .more: 24
        case .result: presentation == .anchored ? 30 : 40
        case .transcript, .file, .action: 28
        }
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < rows.count && rows[row].isSelectable
    }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let title, let detail):
            let text = detail.map { "\(title) \u{00B7} \($0)" } ?? title
            let label = NSTextField(labelWithString: text.uppercased())
            label.font = Theme.Fonts.ui(theme.fontUI.caption, weight: .semibold)
            label.textColor = theme.foregroundDim.nsColor
            return padded(label, leading: 12, top: 4)
        case .result(let result):
            return presentation == .anchored
                ? SearchSessionRowView(result: result, state: state, theme: theme)
                : PaletteRowView(result: result, theme: theme)
        case .transcript(let hit):
            return SearchTranscriptRowView(hit: hit, theme: theme)
        case .file(let hit):
            return SearchFileRowView(hit: hit, theme: theme)
        case .action(let action):
            return SearchActionRowView(action: action, theme: theme)
        case .more(_, let remaining):
            let label = NSTextField(labelWithString: "Show \(remaining) more\u{2026}")
            label.font = Theme.Fonts.ui(theme.fontUI.body)
            label.textColor = theme.foregroundDim.nsColor
            return padded(label, leading: 12, top: 4)
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
