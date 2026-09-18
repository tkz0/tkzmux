// TkzCore — the Kanban board (⇧⌘K): work written down once, handed to agents, and followed across
// four columns.
//
// A card is a prompt with a lifecycle. It can name a **group** ("any agent in this repo may take
// it") and an **agent** (one session row, "this one takes it"). An agent can be given any number of
// cards: it works them one at a time, in the order they sit in *To Do*, and takes the next one the
// moment its turn ends — that queue is what keeps it working.
//
// The split of labour is the store's usual one:
//
//   * everything here is a pure reducer — which card an agent takes next (`nextBoardDispatches`),
//     what a finished turn does to its card (`boardTurnEnded`, called from `applyHook`), what a
//     removed row or group leaves behind;
//   * the one side effect, pasting the card's prompt into the agent's pty, belongs to
//     `BoardDispatcher` in TkzApp, which calls `markBoardTaskDispatched` when it has done it.
//
// Kept on `AppState` like the activity feed and for the same reason: `Session.live` is never
// persisted, and a board has to survive a relaunch.

import Foundation

/// Identity of a card on the board.
public struct BoardTaskID: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// The board's four columns, in display order. Fixed: the dispatcher gives two of them a meaning
/// (`inProgress` = an agent has the prompt, `inReview` = its turn ended), so they are not labels
/// the user can rename out from under it.
public enum BoardColumn: String, Hashable, Sendable, Codable, CaseIterable {
    case todo, inProgress, inReview, done

    public var title: String {
        switch self {
        case .todo: "To Do"
        case .inProgress: "In Progress"
        case .inReview: "In Review"
        case .done: "Done"
        }
    }
}

/// One card.
public struct BoardTask: Hashable, Sendable, Codable, Identifiable {
    public var id: BoardTaskID
    /// The card's headline, and the first line of the prompt an agent gets.
    public var title: String
    /// The rest of the prompt. May be empty.
    public var notes: String
    public var column: BoardColumn
    /// Whose work this is. With no `assignee`, any Claude in the group may take the card.
    public var groupID: GroupID?
    /// The agent designated for the card, or the one that took it. Kept after the card leaves
    /// *In Progress*, so *In Review* and *Done* still say who did the work.
    public var assignee: SessionID?
    public var createdAt: Date
    /// When the prompt was last pasted into an agent. `nil` = never dispatched.
    public var dispatchedAt: Date?

    public init(
        id: BoardTaskID = .generate(),
        title: String,
        notes: String = "",
        column: BoardColumn = .todo,
        groupID: GroupID? = nil,
        assignee: SessionID? = nil,
        createdAt: Date,
        dispatchedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.column = column
        self.groupID = groupID
        self.assignee = assignee
        self.createdAt = createdAt
        self.dispatchedAt = dispatchedAt
    }

    /// What is pasted into the agent: the title, then the notes under a blank line.
    public var prompt: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? title : title + "\n\n" + notes
    }
}

/// One card an agent should be given now — `nextBoardDispatches`' answer.
public struct BoardDispatch: Hashable, Sendable {
    public var task: BoardTaskID
    public var session: SessionID
    /// The pane Claude runs in, where the prompt goes.
    public var terminal: TerminalID
    public var prompt: String
}

// MARK: - Reading

extension AppState {
    /// A column's cards, top to bottom. `board` is one flat array and a column's order is the
    /// array's: one truth, and a move is a remove and an insert.
    public func boardTasks(in column: BoardColumn) -> [BoardTask] {
        board.filter { $0.column == column }
    }

    public func boardTask(_ id: BoardTaskID) -> BoardTask? {
        board.first { $0.id == id }
    }

    /// Whether a row has a Claude in it at all — running, whatever it is doing. **Every such row
    /// is an agent for its group's cards.** An earlier rule made a row opt in first (some card had
    /// to name it), to keep hand-driven sessions out of it; in use that read as a bug — a group
    /// with an idle Claude in it said it had no agent (2026-09-18). The protection that is left
    /// is `reserved`, below.
    public func hasClaude(_ id: SessionID) -> Bool {
        guard let live = sessions[id]?.live, live.alive, !live.ended else { return false }
        return live.pid != nil || live.descriptor != nil
    }

    /// The card `id` is working on, if any. One at a time: an agent with a card in *In Progress*
    /// is given nothing else.
    public func activeBoardTask(of id: SessionID) -> BoardTask? {
        board.first { $0.assignee == id && $0.column == .inProgress }
    }

    /// Every (card, agent) pair that should be dispatched right now: agents that are ready for a
    /// prompt, have nothing in progress and have a card waiting. Sidebar order, so two agents
    /// racing for one group card resolve the same way every time; a card is handed out once.
    ///
    /// `reserved` rows take their **own** cards but no unassigned group card: the dispatcher
    /// passes the row the user is in. A card that names a row was aimed at it on purpose; a group
    /// card pasted into the terminal someone is typing in would be appended to their half-written
    /// message and submitted with it.
    public func nextBoardDispatches(reserved: Set<SessionID> = []) -> [BoardDispatch] {
        guard board.contains(where: { $0.column == .todo }) else { return [] }
        var taken: Set<BoardTaskID> = []
        var out: [BoardDispatch] = []
        for session in orderedSessions where session.isReadyForBoardTask {
            guard activeBoardTask(of: session.id) == nil else { continue }
            let todo = boardTasks(in: .todo).filter { !taken.contains($0.id) }
            let own = todo.first { $0.assignee == session.id }
            let pick = own ?? (reserved.contains(session.id)
                ? nil : todo.first { $0.assignee == nil && $0.groupID == session.groupID })
            guard let pick, !pick.prompt.isEmpty else { continue }
            taken.insert(pick.id)
            out.append(
                BoardDispatch(
                    task: pick.id, session: session.id,
                    terminal: session.live?.claudeTerminal ?? session.focusedTerminalID,
                    prompt: pick.prompt))
        }
        return out
    }
}

extension Session {
    /// Whether a prompt pasted into this row now would land in an idle Claude's input box.
    ///
    /// Claude has to be *there* (a bound pid or descriptor, not a bare shell, not still starting,
    /// not exited) and *free*: not mid-turn, and not showing a permission prompt or a question —
    /// text pasted into one of those would answer it. A finished turn nobody has looked at yet
    /// (`doneUnattended`) is free: that is exactly the state a queue exists to use.
    public var isReadyForBoardTask: Bool {
        guard let live, live.alive, !live.ended, live.claudeStartup == nil else { return false }
        guard live.pid != nil || live.descriptor != nil else { return false }
        switch live.status {
        case .working: return false
        case .waiting(let reason): return reason == .doneUnattended
        case .idle: return true
        }
    }
}

// MARK: - Reducers

extension AppState {
    /// A new card at the bottom of `column`. An `assignee` brings its group with it.
    @discardableResult
    public mutating func addBoardTask(
        title: String,
        notes: String = "",
        column: BoardColumn = .todo,
        groupID: GroupID? = nil,
        assignee: SessionID? = nil,
        now: Date = Date()
    ) -> BoardTaskID {
        var task = BoardTask(title: title, notes: notes, column: column, createdAt: now)
        task.groupID = groupID.flatMap { groups[$0] != nil ? $0 : nil }
        if let assignee, let session = sessions[assignee] {
            task.assignee = assignee
            task.groupID = session.groupID
        }
        board.append(task)
        return task.id
    }

    public mutating func editBoardTask(_ id: BoardTaskID, title: String, notes: String) {
        guard let index = board.firstIndex(where: { $0.id == id }) else { return }
        board[index].title = title
        board[index].notes = notes
    }

    /// Sets or clears the card's group. An assignee from another group does not survive: a card
    /// that says "tkzmux" and is worked by an agent in another repo would be two truths.
    public mutating func setBoardTaskGroup(_ id: BoardTaskID, to groupID: GroupID?) {
        guard let index = board.firstIndex(where: { $0.id == id }) else { return }
        if let groupID, groups[groupID] == nil { return }
        board[index].groupID = groupID
        if let assignee = board[index].assignee, sessions[assignee]?.groupID != groupID {
            unassign(id)
        }
    }

    /// Designates an agent for the card (`nil` = nobody). The card follows the agent's group.
    /// Taking a card off the agent that is working on it sends it back to *To Do*: the new agent
    /// has not been given the prompt, and *In Progress* would claim it had.
    public mutating func assignBoardTask(_ id: BoardTaskID, to assignee: SessionID?) {
        guard let index = board.firstIndex(where: { $0.id == id }) else { return }
        guard board[index].assignee != assignee else { return }
        guard let assignee else { return unassign(id) }
        guard let session = sessions[assignee] else { return }
        if board[index].column == .inProgress { requeue(id) }
        // `requeue` moves the card, so it is looked up again rather than trusted at `index`.
        guard let index = board.firstIndex(where: { $0.id == id }) else { return }
        board[index].assignee = assignee
        board[index].groupID = session.groupID
    }

    /// Moves a card to `index` among `column`'s cards (`nil` or past the end = the bottom).
    public mutating func moveBoardTask(_ id: BoardTaskID, to column: BoardColumn, at index: Int? = nil) {
        guard let from = board.firstIndex(where: { $0.id == id }) else { return }
        var task = board.remove(at: from)
        task.column = column
        let peers = board.indices.filter { board[$0].column == column }
        if let index, index >= 0, index < peers.count {
            board.insert(task, at: peers[index])
        } else if let last = peers.last {
            board.insert(task, at: last + 1)
        } else {
            board.append(task)
        }
    }

    public mutating func removeBoardTask(_ id: BoardTaskID) {
        board.removeAll { $0.id == id }
    }

    /// The dispatcher pasted the card's prompt into `session`: the card is that agent's and is
    /// *In Progress*. Says no — and changes nothing — if the card has moved on or the agent has
    /// taken something else since the dispatcher decided.
    @discardableResult
    public mutating func markBoardTaskDispatched(
        _ id: BoardTaskID, to session: SessionID, now: Date = Date()
    ) -> Bool {
        guard let task = boardTask(id), task.column == .todo,
            task.assignee == nil || task.assignee == session,
            let row = sessions[session], activeBoardTask(of: session) == nil
        else { return false }
        moveBoardTask(id, to: .inProgress)
        guard let index = board.firstIndex(where: { $0.id == id }) else { return false }
        board[index].assignee = session
        board[index].groupID = row.groupID
        board[index].dispatchedAt = now
        return true
    }

    /// `Stop` on `session`: the turn that was working its card is over, so the card is up for
    /// review and the agent is free for the next one. Called by `applyHook`.
    mutating func boardTurnEnded(_ session: SessionID) {
        guard let task = activeBoardTask(of: session) else { return }
        moveBoardTask(task.id, to: .inReview)
    }

    /// A row is going away: its cards are nobody's, and the one it was working on is *To Do*
    /// again. Called by `removeSession`.
    mutating func boardSessionRemoved(_ session: SessionID) {
        // By id, not by index: un-assigning the card in progress moves it.
        for id in board.filter({ $0.assignee == session }).map(\.id) { unassign(id) }
    }

    /// A group is going away: its cards keep their text and lose the label — or follow the rows to
    /// `destination`. Called by `removeGroup`.
    mutating func boardGroupRemoved(_ group: GroupID, reassignedTo destination: GroupID?) {
        for index in board.indices where board[index].groupID == group {
            board[index].groupID = destination
        }
    }

    private mutating func unassign(_ id: BoardTaskID) {
        guard let index = board.firstIndex(where: { $0.id == id }) else { return }
        board[index].assignee = nil
        if board[index].column == .inProgress { requeue(id) }
    }

    /// Back to the bottom of *To Do*, as never dispatched.
    private mutating func requeue(_ id: BoardTaskID) {
        guard let index = board.firstIndex(where: { $0.id == id }) else { return }
        board[index].dispatchedAt = nil
        moveBoardTask(id, to: .todo)
    }
}
