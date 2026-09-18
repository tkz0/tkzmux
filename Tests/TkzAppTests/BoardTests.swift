// BoardTests — the Kanban board in TkzApp: the words a card shows, the bytes an agent is sent, the
// dispatcher's timing, and the window wiring (the toolbar's calendar button, ⇧⌘K, selection, card menu).

import AppKit
import Foundation
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A repo group with two Claude rows, on top of whatever `base` holds.
@MainActor
private func seed(_ state: inout AppState) -> (group: GroupID, one: SessionID, two: SessionID) {
    let group = state.addGroup(name: "Alpha", repoRoot: "~/dev/alpha").id
    let one = state.createSession(groupID: group, cwd: "~/dev/alpha", title: "one").id
    let two = state.createSession(groupID: group, cwd: "~/dev/alpha", title: "two").id
    for id in [one, two] { state.setLive(LiveSessionState(pid: 7, status: .idle), for: id) }
    return (group, one, two)
}

// MARK: - Model

@Suite("Board model")
@MainActor
struct BoardModelTests {
    @Test("Four columns, in order, each with its cards")
    func columns() {
        var state = AppState()
        let (group, one, _) = seed(&state)
        state.addBoardTask(title: "a", notes: "n", assignee: one, now: t0)
        state.addBoardTask(title: "b", column: .done, now: t0)

        let columns = BoardModel.columns(state: state)
        #expect(columns.map(\.column) == BoardColumn.allCases)
        #expect(columns.map(\.cards.count) == [1, 0, 0, 1])
        let card = columns[0].cards[0]
        #expect(card.title == "a")
        #expect(card.group?.id == group)
        #expect(card.group?.name == "Alpha")
        #expect(card.agent?.title == "one")
        #expect(BoardModel.summary(columns) == "1 to do")
        #expect(BoardModel.summary(BoardModel.columns(state: AppState())) == "Nothing open")
    }

    @Test("The status line says where a To Do card stands")
    func todoStatus() throws {
        var state = AppState()
        let (group, one, two) = seed(&state)
        let first = state.addBoardTask(title: "first", assignee: one, now: t0)
        let second = state.addBoardTask(title: "second", assignee: one, now: t0)
        let open = state.addBoardTask(title: "open", groupID: group, now: t0)
        let loose = state.addBoardTask(title: "loose", now: t0)

        func text(_ id: BoardTaskID) throws -> String {
            BoardModel.card(try #require(state.boardTask(id)), state: state).status.text
        }
        #expect(try text(first) == "Sending to one\u{2026}")
        #expect(try text(open) == "Open to Alpha agents")
        #expect(try text(loose) == "Unassigned")

        state.markBoardTaskDispatched(first, to: one, now: t0)
        #expect(try text(second) == "Queued for one")
        #expect(try text(first) == "In progress")

        state.sessions[one]?.live?.status = .working
        #expect(try text(first) == "Working")
        state.sessions[one]?.live?.status = .waiting(.permission)
        state.sessions[one]?.live?.attention = true
        #expect(try text(first) == "Needs you")

        // A row with no Claude in it cannot take its card yet, and the card says so.
        let parked = state.addBoardTask(title: "parked", assignee: two, now: t0)
        state.sessions[two]?.live = nil
        #expect(try text(parked) == "Waiting for Claude in two")
    }

    /// Reported 2026-09-18: a group with a Claude running in it said it had no agent, because a
    /// row used to count only once a card had named it.
    @Test("A group card says what its group can do for it right now")
    func groupStatus() throws {
        var state = AppState()
        let (group, one, two) = seed(&state)
        let id = state.addBoardTask(title: "open", groupID: group, now: t0)
        func status() throws -> BoardModel.Status {
            BoardModel.card(try #require(state.boardTask(id)), state: state).status
        }
        // Two idle Claudes, no card has ever named either: they are agents all the same.
        #expect(try status().text == "Open to Alpha agents")

        for row in [one, two] { state.sessions[row]?.live?.status = .working }
        #expect(try status().text == "Waiting for a free agent in Alpha")

        // Rows, but only bare shells in them.
        for row in [one, two] { state.setLive(LiveSessionState(status: .idle), for: row) }
        #expect(try status().text == "No Claude running in Alpha")
        #expect(try status().tone == .attention)
    }
}

// MARK: - Dispatcher

@Suite("Board dispatcher")
@MainActor
struct BoardDispatcherTests {
    @Test("A prompt is one bracketed paste with nothing in it that could close the bracket")
    func pasteBytes() {
        let esc = "\u{1B}"
        let bytes = BoardDispatcher.pasteBytes(for: "one\ntwo\r\nthree\(esc)[201~\u{07}\tend")
        #expect(String(decoding: bytes, as: UTF8.self) == "\(esc)[200~one\rtwo\rthree[201~\tend\(esc)[201~")
    }

    /// Polls until `predicate`, flushing the store so observers run. The deadline is generous on
    /// purpose: a dispatch is three hops on the main actor (delivery, settle timer, ↵ timer), and
    /// under the full target every `@MainActor` suite is queueing on it too. It returns the moment
    /// the predicate holds, so the slack costs nothing when things are quick.
    private func settle(_ store: AppStore, until predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            store.flush()
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    @Test("A free agent is pasted its card, then ↵, and the card is In Progress")
    func dispatches() async throws {
        var state = AppState()
        let (_, one, _) = seed(&state)
        let store = AppStore(state: state)
        let host = MainWindowControllerTests.SpyTerminalHost()
        let terminal = try #require(store.state.sessions[one]?.focusedTerminalID)
        _ = try host.open(terminal, session: one, cwd: "/", env: [:], size: TerminalSize(rows: 24, cols: 80))

        let dispatcher = BoardDispatcher(store: store, host: host)
        dispatcher.settleDelay = .milliseconds(1)
        dispatcher.submitDelay = .milliseconds(1)
        var announced: [BoardDispatch] = []
        dispatcher.onDispatched = { announced.append($0) }

        let first = store.updating { $0.addBoardTask(title: "first", notes: "with notes", assignee: one, now: t0) }
        let second = store.updating { $0.addBoardTask(title: "second", assignee: one, now: t0) }

        try #require(await settle(store) { host.wrote.count == 2 })
        #expect(host.wrote.map(\.id) == [terminal, terminal])
        #expect(host.wrote.map(\.data) == [BoardDispatcher.pasteBytes(for: "first\n\nwith notes"), Data([0x0D])])
        #expect(store.state.boardTask(first)?.column == .inProgress)
        #expect(store.state.boardTask(second)?.column == .todo)
        #expect(announced.map(\.task) == [first])

        // The turn ends: the first card is up for review and the queue moves on by itself.
        store.update { $0.applyHook(.init(kind: .stop), to: one, now: t0) }
        try #require(await settle(store) { host.wrote.count == 4 })
        #expect(host.wrote.suffix(2).map(\.data) == [BoardDispatcher.pasteBytes(for: "second"), Data([0x0D])])
        #expect(store.state.boardTask(first)?.column == .inReview)
        #expect(store.state.boardTask(second)?.column == .inProgress)
    }

    @Test("An agent that stops being free during the settle delay gets nothing")
    func settleRechecks() async throws {
        var state = AppState()
        let (_, one, _) = seed(&state)
        let store = AppStore(state: state)
        let host = MainWindowControllerTests.SpyTerminalHost()
        let terminal = try #require(store.state.sessions[one]?.focusedTerminalID)
        _ = try host.open(terminal, session: one, cwd: "/", env: [:], size: TerminalSize(rows: 24, cols: 80))

        let dispatcher = BoardDispatcher(store: store, host: host)
        dispatcher.settleDelay = .milliseconds(60)
        let id = store.updating { $0.addBoardTask(title: "a", assignee: one, now: t0) }
        store.flush()
        // A permission prompt comes up before the delay runs out.
        store.update { $0.sessions[one]?.live?.status = .waiting(.permission) }
        store.flush()

        try await Task.sleep(for: .milliseconds(150))
        store.flush()
        #expect(host.wrote.isEmpty)
        #expect(store.state.boardTask(id)?.column == .todo)
    }

    @Test("A group card skips the row the user is in, and goes once they have left it")
    func reservedRow() async throws {
        var state = AppState()
        let (group, one, two) = seed(&state)
        // Only `one` has a terminal, so it is the only row a card could be written to.
        state.setLive(LiveSessionState(status: .idle), for: two)
        let store = AppStore(state: state)
        let host = MainWindowControllerTests.SpyTerminalHost()
        let terminal = try #require(store.state.sessions[one]?.focusedTerminalID)
        _ = try host.open(terminal, session: one, cwd: "/", env: [:], size: TerminalSize(rows: 24, cols: 80))

        let dispatcher = BoardDispatcher(store: store, host: host)
        dispatcher.settleDelay = .milliseconds(1)
        dispatcher.submitDelay = .milliseconds(1)
        var userIsIn: Set<SessionID> = [one]
        dispatcher.reserved = { userIsIn }

        let id = store.updating { $0.addBoardTask(title: "open", groupID: group, now: t0) }
        store.flush()
        try await Task.sleep(for: .milliseconds(80))
        store.flush()
        #expect(host.wrote.isEmpty)
        #expect(store.state.boardTask(id)?.column == .todo)

        // They open the board (or pick another row). Nothing in the store changed, so whoever
        // changed what is on screen says so.
        userIsIn = []
        dispatcher.evaluate()
        try #require(await settle(store) { host.wrote.count == 2 })
        #expect(store.state.boardTask(id)?.column == .inProgress)
        #expect(store.state.boardTask(id)?.assignee == one)
    }

    @Test("Nothing is written to a terminal the host does not hold")
    func needsATerminal() async throws {
        var state = AppState()
        let (_, one, _) = seed(&state)
        let store = AppStore(state: state)
        let host = MainWindowControllerTests.SpyTerminalHost()
        let dispatcher = BoardDispatcher(store: store, host: host)
        dispatcher.settleDelay = .milliseconds(1)
        let id = store.updating { $0.addBoardTask(title: "a", assignee: one, now: t0) }
        store.flush()
        try await Task.sleep(for: .milliseconds(60))
        #expect(host.wrote.isEmpty)
        #expect(store.state.boardTask(id)?.column == .todo)
    }
}

// MARK: - Window

@Suite("Board window wiring")
@MainActor
struct BoardWindowTests {
    @Test("⇧⌘K is Show Board, in the table and wired")
    func shortcut() {
        #expect(ShortcutsTable.defaults[.showBoard] == Shortcut("k", [.shift, .command]))
        #expect(ShortcutsTable.title(for: .showBoard) == "Show Board")
        #expect(ShortcutsTable.allActions.contains(.showBoard))
        // No other default sits on the chord.
        let chord = Shortcut("k", [.shift, .command])
        #expect(ShortcutsTable.defaults.filter { $0.value == chord }.map(\.key) == [.showBoard])

        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        #expect(harness.controller.dispatcher.canPerform(.showBoard))
    }

    @Test("The calendar button sits right after >_ and toggles the board")
    func toolbarButton() {
        #expect(MainToolbarController.ViewButton.board.rawValue == MainToolbarController.ViewButton.terminal.rawValue + 1)
        // A symbol, not a text glyph: the segment carries an image and an empty label. The two
        // splits are symbols as well, at the same point size, so all three are one height.
        let board = MainToolbarController.ViewButton.board
        #expect(board.symbolName == "calendar")
        let symbols = MainToolbarController.ViewButton.allCases.filter { $0.symbolName != nil }
        #expect(symbols == [.board, .splitV, .splitH])
        for button in MainToolbarController.ViewButton.allCases {
            let image = MainToolbarController.symbolImage(for: button, isDark: true)
            // Exactly one of the two: a segment with both would draw both.
            #expect((image != nil) == symbols.contains(button), "\(button)")
            #expect(button.glyph(isDark: true).isEmpty == symbols.contains(button), "\(button)")
            #expect(image?.isTemplate ?? true, "\(button)")
        }

        // Asked of the delegate directly: a toolbar only vends its items once it is on screen.
        let toolbar = MainToolbarController()
        let item = toolbar.toolbar(
            toolbar.toolbar, itemForItemIdentifier: .tkzViewCluster, willBeInsertedIntoToolbar: true)
        let control = item?.view as? NSSegmentedControl
        for button in symbols {
            #expect(control?.image(forSegment: button.rawValue) != nil, "\(button)")
            #expect(control?.label(forSegment: button.rawValue)?.isEmpty == true, "\(button)")
        }
        #expect(control?.image(forSegment: MainToolbarController.ViewButton.terminal.rawValue) == nil)

        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        #expect(!controller.board.isShown)
        controller.toolbarController.activate(.board)
        #expect(controller.board.isShown)
        controller.toolbarController.activate(.board)
        #expect(!controller.board.isShown)
    }

    @Test("The board and the changes viewer are never up together; Esc closes the board")
    func oneOverlay() {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        _ = controller.dispatcher.perform(.showBoard)
        #expect(controller.board.isShown)
        #expect(!controller.changes.isShown)
        controller.board.view.cancelOperation(nil)
        #expect(!controller.board.isShown)
    }

    @Test("Picking a row in the sidebar closes the board; an agent chip jumps to its row")
    func selectionCloses() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let rows = harness.store.state.orderedSessions
        let target = try #require(rows.first { $0.id != harness.store.state.selection })

        controller.toggleBoard()
        harness.store.update { $0.select(target.id) }
        harness.store.flush()
        #expect(!controller.board.isShown)

        let other = try #require(rows.first { $0.id != target.id })
        controller.toggleBoard()
        controller.board.view.onOpenAgent?(other.id)
        harness.store.flush()
        #expect(harness.store.state.selection == other.id)
        #expect(!controller.board.isShown)
    }

    /// Reported 2026-09-18: with the board up, clicking the agent in the sidebar did nothing. The
    /// row was already selected, so the store saw no selection change and the board never heard.
    @Test("Clicking the row that is already selected goes to it")
    func clickingTheSelectedRow() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let selected = try #require(harness.store.state.selection)

        controller.toggleBoard()
        #expect(controller.board.isShown)
        controller.sidebar.sessionRowClicked(selected)
        harness.store.flush()
        #expect(!controller.board.isShown)
        #expect(harness.store.state.selection == selected)
    }

    @Test("The board reserves the row the user is in, and no row while it is up")
    func reservedFollowsTheBoard() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let selected = try #require(harness.store.state.selection)
        #expect(controller.boardDispatcher.reserved() == [selected])
        controller.toggleBoard()
        #expect(controller.boardDispatcher.reserved().isEmpty)
        controller.toggleBoard()
        #expect(controller.boardDispatcher.reserved() == [selected])
    }

    @Test("The board draws the store's cards and follows changes while it is up")
    func rendering() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let row = try #require(harness.store.state.orderedSessions.first)
        harness.store.update { $0.addBoardTask(title: "first", assignee: row.id, now: t0) }
        controller.toggleBoard()

        let todo = try #require(controller.board.view.columnViews.first { $0.column == .todo })
        #expect(todo.cardViews.map { $0.card?.title } == ["first"])

        harness.store.update { $0.addBoardTask(title: "second", now: t0) }
        harness.store.flush()
        #expect(todo.cardViews.map { $0.card?.title } == ["first", "second"])

        // A drop is a move: "second" to the top of Done.
        let second = try #require(todo.cardViews.last?.card?.id)
        controller.board.view.onDrop?(second, .done, 0)
        harness.store.flush()
        #expect(todo.cardViews.count == 1)
        #expect(harness.store.state.boardTask(second)?.column == .done)
    }

    @Test("The card menu assigns, regroups, moves and deletes")
    func cardMenu() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let store = harness.store
        let board = harness.controller.board
        let group = try #require(store.state.orderedGroups.first { !store.state.sessions(in: $0.id).isEmpty })
        let row = try #require(store.state.sessions(in: group.id).first)
        let id = store.updating { $0.addBoardTask(title: "a", groupID: group.id, now: t0) }

        func pick(_ path: [String]) throws {
            var menu = try #require(board.menu(for: id))
            for (depth, title) in path.enumerated() {
                let item = try #require(menu.items.first { $0.title == title }, "no \(title)")
                if depth == path.count - 1 {
                    _ = item.target?.perform(item.action, with: item)
                } else {
                    menu = try #require(item.submenu)
                }
            }
        }

        try pick(["Agent", row.displayTitle])
        #expect(store.state.boardTask(id)?.assignee == row.id)
        try pick(["Agent", "Any Agent in the Group"])
        #expect(store.state.boardTask(id)?.assignee == nil)
        try pick(["Move To", "In Review"])
        #expect(store.state.boardTask(id)?.column == .inReview)
        try pick(["Group", "No Group"])
        #expect(store.state.boardTask(id)?.groupID == nil)
        // No group, nowhere to start a Claude.
        let agents = try #require(board.menu(for: id)?.items.first { $0.title == "Agent" }?.submenu)
        #expect(agents.items.last?.title == "Start New Agent")
        #expect(agents.items.last?.isEnabled == false)
        try pick(["Delete"])
        #expect(store.state.boardTask(id) == nil)
    }

    @Test("Start New Agent launches claude -w in the card's group and hands it the card")
    func startAgent() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let store = harness.store
        let controller = harness.controller
        let group = try #require(store.state.orderedGroups.first { $0.repoRoot != nil })
        // The launcher checks the directory exists; the fixture's repos do not.
        let root = NSTemporaryDirectory()
        store.update { $0.setGroupRepoRoot(group.id, path: root) }
        let id = store.updating { $0.addBoardTask(title: "a", groupID: group.id, now: t0) }
        let before = Set(store.state.sessions.keys)

        controller.toggleBoard()
        controller.board.onStartAgent?(id)
        store.flush()

        let created = try #require(Set(store.state.sessions.keys).subtracting(before).first)
        #expect(store.state.sessions[created]?.groupID == group.id)
        #expect(harness.host.bootCommands.last == "claude -w")
        #expect(store.state.boardTask(id)?.assignee == created)
        // The launch selected the new row, which would normally close the board. It stays.
        #expect(store.state.selection == created)
        #expect(controller.board.isShown)
    }
}

// MARK: - Editor

@Suite("Board task editor")
@MainActor
struct BoardTaskEditorTests {
    @Test("Adding from a column opens the editor and Save writes the card")
    func addFlow() throws {
        var state = AppState()
        let (group, one, _) = seed(&state)
        state.select(one)
        let store = AppStore(state: state)
        let board = BoardController(store: store, theme: .default)
        board.showPopover = { _, _ in }
        board.present()

        board.view.onAdd?(.todo, board.view)
        let editor = try #require(board.editor)
        _ = editor.view
        // The selected row's group is the default: that is the repo the user is in.
        #expect(editor.currentDraft.groupID == group)
        #expect(editor.currentDraft.assignee == nil)

        editor.onSave?(.init(title: "Write the docs", notes: "All of them", groupID: group, assignee: one))
        #expect(board.editor == nil)
        let card = try #require(store.state.boardTasks(in: .todo).first)
        #expect(card.title == "Write the docs")
        #expect(card.notes == "All of them")
        #expect(card.assignee == one)
    }

    @Test("Editing rewrites the card, its group and its agent")
    func editFlow() throws {
        var state = AppState()
        let (_, one, two) = seed(&state)
        let id = state.addBoardTask(title: "old", assignee: one, now: t0)
        let store = AppStore(state: state)
        let board = BoardController(store: store, theme: .default)
        board.showPopover = { _, _ in }
        board.present()

        board.view.onEdit?(id, board.view)
        let editor = try #require(board.editor)
        _ = editor.view
        #expect(editor.currentDraft.title == "old")
        #expect(editor.currentDraft.assignee == one)

        var draft = editor.currentDraft
        draft.title = "new"
        draft.assignee = two
        editor.onSave?(draft)
        #expect(store.state.boardTask(id)?.title == "new")
        #expect(store.state.boardTask(id)?.assignee == two)
    }
}
