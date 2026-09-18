// BoardController — opens, feeds and closes the Kanban board (⇧⌘K, the toolbar's calendar button).
//
// Shaped like `ChangesViewerController`: the view is a subview laid over the terminal container,
// hidden until `present()`, and `onDismiss` is how the window controller learns to hand the
// keyboard back to the terminal.
//
// Unlike the feed and the changes viewer, this controller *does* write the store — adding, editing,
// moving and assigning cards are all one-line reducers with nothing to ask the window about. The
// two things that reach outside the board go through closures: jumping to an agent's row
// (`onOpenSession`) and starting a new agent for a card (`onStartAgent`), which needs the
// launcher.

import AppKit
import TkzCore

@MainActor
final class BoardController: NSObject, NSPopoverDelegate {
    let view: BoardView
    private let store: AppStore

    /// Esc, ✕, the chord again, a row selected in the sidebar.
    var onDismiss: (() -> Void)?
    /// The agent chip on a card: select that row. The window controller dismisses the board.
    var onOpenSession: ((SessionID) -> Void)?
    /// *Start New Agent* on a card: launch a Claude in the card's group and give it the card.
    var onStartAgent: ((BoardTaskID) -> Void)?
    /// How a popover comes on screen. Tests replace it: a popover needs a window on screen.
    var showPopover: (NSPopover, NSView) -> Void = { popover, anchor in
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    var theme: Theme {
        didSet { if theme != oldValue { view.apply(theme: theme) } }
    }

    var isShown: Bool { !view.isHidden }

    private var token: AppStore.ObserverToken?
    private var popover: NSPopover?
    private(set) var editor: BoardTaskEditor?

    init(store: AppStore, theme: Theme) {
        self.store = store
        self.theme = theme
        self.view = BoardView(theme: theme)
        super.init()
        view.isHidden = true
        view.onEscape = { [weak self] in self?.dismiss() }
        view.onAdd = { [weak self] column, anchor in self?.presentEditor(adding: column, from: anchor) }
        view.onEdit = { [weak self] id, anchor in self?.presentEditor(editing: id, from: anchor) }
        view.menuForCard = { [weak self] id in self?.menu(for: id) }
        view.onDrop = { [weak self] id, column, index in
            self?.store.update { $0.moveBoardTask(id, to: column, at: index) }
        }
        view.onOpenAgent = { [weak self] id in self?.onOpenSession?(id) }

        token = store.addObserver { [weak self] change in
            guard let self, self.isShown else { return }
            // Cards print their group's name and their agent's title and dot, so a rename or a
            // status flip redraws too. Cheap: four columns of a handful of cards.
            if change.board || change.structure || !change.sessions.isEmpty || !change.groups.isEmpty {
                self.render()
            }
        }
    }

    // MARK: Presentation

    func toggle() {
        if isShown { dismiss() } else { present() }
    }

    func present() {
        render()
        view.isHidden = false
        view.takeKeyboard()
    }

    func dismiss() {
        guard isShown else { return }
        closeEditor()
        view.isHidden = true
        onDismiss?()
    }

    private func render() {
        view.configure(BoardModel.columns(state: store.state))
    }

    // MARK: Editor

    func presentEditor(adding column: BoardColumn, from anchor: NSView) {
        // A new card defaults to the selected row's group: that is the repo the user is in.
        let group = store.state.selectedSession?.groupID
        let draft = BoardTaskEditor.Draft(title: "", notes: "", groupID: group, assignee: nil)
        presentEditor(heading: "New task in \(column.title)", draft: draft, from: anchor) { [weak self] draft in
            self?.store.update {
                $0.addBoardTask(
                    title: draft.title, notes: draft.notes, column: column,
                    groupID: draft.groupID, assignee: draft.assignee)
            }
        }
    }

    func presentEditor(editing id: BoardTaskID, from anchor: NSView) {
        guard let task = store.state.boardTask(id) else { return }
        let draft = BoardTaskEditor.Draft(
            title: task.title, notes: task.notes, groupID: task.groupID, assignee: task.assignee)
        presentEditor(heading: "Edit task", draft: draft, from: anchor) { [weak self] draft in
            self?.store.update {
                $0.editBoardTask(id, title: draft.title, notes: draft.notes)
                $0.setBoardTaskGroup(id, to: draft.groupID)
                $0.assignBoardTask(id, to: draft.assignee)
            }
        }
    }

    private func presentEditor(
        heading: String, draft: BoardTaskEditor.Draft, from anchor: NSView,
        save: @escaping (BoardTaskEditor.Draft) -> Void
    ) {
        closeEditor()
        let editor = BoardTaskEditor(
            heading: heading, draft: draft, choices: BoardTaskEditor.Choices(state: store.state))
        editor.onSave = { [weak self] draft in
            save(draft)
            self?.closeEditor()
        }
        editor.onCancel = { [weak self] in self?.closeEditor() }

        let popover = NSPopover()
        popover.contentViewController = editor
        popover.behavior = .semitransient
        popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        popover.delegate = self
        self.popover = popover
        self.editor = editor
        showPopover(popover, anchor)
    }

    private func closeEditor() {
        popover?.close()
        popover = nil
        editor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        popover = nil
        editor = nil
        // Esc in the popover must not leave the keyboard nowhere: the next Esc closes the board.
        if isShown { view.takeKeyboard() }
    }

    // MARK: Card menu

    /// The `⋮` / right-click menu: edit, agent, group, move, delete. Built per click from the
    /// store, so it always lists the rows and groups that exist now.
    func menu(for id: BoardTaskID) -> NSMenu? {
        let state = store.state
        guard let task = state.boardTask(id) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(item("Edit\u{2026}") { [weak self] in
            guard let self,
                let anchor = self.view.columnViews.flatMap(\.cardViews).first(where: { $0.card?.id == id })
            else { return }
            self.presentEditor(editing: id, from: anchor)
        })
        menu.addItem(.separator())

        // Agent
        let agents = NSMenu()
        agents.autoenablesItems = false
        let nobody = item(task.groupID == nil ? "Nobody" : "Any Agent in the Group") { [weak self] in
            self?.store.update { $0.assignBoardTask(id, to: nil) }
        }
        nobody.state = task.assignee == nil ? .on : .off
        agents.addItem(nobody)
        let candidates = task.groupID.map { state.sessions(in: $0) } ?? state.orderedSessions
        if !candidates.isEmpty { agents.addItem(.separator()) }
        for session in candidates {
            let title = task.groupID == nil
                ? "\(session.displayTitle) \u{2014} \(state.groups[session.groupID]?.name ?? "")"
                : session.displayTitle
            let row = item(title) { [weak self] in
                self?.store.update { $0.assignBoardTask(id, to: session.id) }
            }
            row.state = task.assignee == session.id ? .on : .off
            agents.addItem(row)
        }
        agents.addItem(.separator())
        let group = task.groupID.flatMap { state.groups[$0] }
        let start = item(group.map { "Start New Agent in \($0.name)" } ?? "Start New Agent") { [weak self] in
            self?.onStartAgent?(id)
        }
        // A new agent is a `claude` in the group's repo; a card with no group has nowhere to go.
        start.isEnabled = group?.repoRoot != nil
        if group == nil { start.toolTip = "Give the card a group first" }
        agents.addItem(start)
        menu.addItem(submenu("Agent", agents))

        // Group
        let groups = NSMenu()
        groups.autoenablesItems = false
        let none = item("No Group") { [weak self] in
            self?.store.update { $0.setBoardTaskGroup(id, to: nil) }
        }
        none.state = task.groupID == nil ? .on : .off
        groups.addItem(none)
        if !state.groups.isEmpty { groups.addItem(.separator()) }
        for candidate in state.orderedGroups {
            let row = item(candidate.name) { [weak self] in
                self?.store.update { $0.setBoardTaskGroup(id, to: candidate.id) }
            }
            row.state = task.groupID == candidate.id ? .on : .off
            groups.addItem(row)
        }
        menu.addItem(submenu("Group", groups))

        // Move
        let moves = NSMenu()
        moves.autoenablesItems = false
        for column in BoardColumn.allCases {
            let row = item(column.title) { [weak self] in
                self?.store.update { $0.moveBoardTask(id, to: column) }
            }
            row.state = task.column == column ? .on : .off
            row.isEnabled = task.column != column
            moves.addItem(row)
        }
        menu.addItem(submenu("Move To", moves))

        menu.addItem(.separator())
        menu.addItem(item("Delete") { [weak self] in
            self?.store.update { $0.removeBoardTask(id) }
        })
        return menu
    }

    private func item(_ title: String, _ body: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuAction(body: body)
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.body()
    }

    /// A closure in a box, because `representedObject` is `Any?` and wants an object.
    private final class MenuAction {
        let body: @MainActor () -> Void
        init(body: @escaping @MainActor () -> Void) { self.body = body }
    }
}
