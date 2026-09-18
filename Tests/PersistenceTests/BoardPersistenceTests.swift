// BoardPersistenceTests — the Kanban board in `state.json`: its own top-level key, no schema bump,
// column order kept, and cards that outlive the rows and groups they name.

import Foundation
import Testing
import TkzCore

@testable import Persistence

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A group, a row, and one card per interesting column.
private func makeState() -> (AppState, GroupID, SessionID) {
    var state = AppState()
    let group = state.addGroup(name: "Alpha", repoRoot: "~/dev/alpha")
    let row = state.createSession(groupID: group.id, cwd: "~/dev/alpha", title: "agent").id
    state.setLive(LiveSessionState(pid: 1, status: .idle), for: row)
    state.addBoardTask(title: "queued", notes: "two\nlines", assignee: row, now: t0)
    state.addBoardTask(title: "open", groupID: group.id, now: t0)
    state.addBoardTask(title: "shipped", column: .done, now: t0)
    return (state, group.id, row)
}

@Test func theBoardRoundTripsInOrder() throws {
    let (state, _, _) = makeState()
    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    var restored = AppState()
    let warnings = try StateFile.decode(data).state.apply(to: &restored)
    #expect(warnings.isEmpty)
    #expect(restored.board == state.board)
}

@Test func theBoardKeyIsTopLevelAndStaysAtSchemaVersion3() throws {
    let (state, _, _) = makeState()
    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
    #expect(object["schemaVersion"] == .number(3))
    if case .array(let cards)? = object["board"] {
        #expect(cards.count == 3)
    } else {
        Issue.record("board is not a top-level array")
    }
}

@Test func aFileWithNoBoardLoadsAsAnEmptyOne() throws {
    let (state, _, _) = makeState()
    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    var object = try JSONDecoder().decode([String: JSONValue].self, from: data)
    object["board"] = nil
    let stripped = try JSONEncoder().encode(object)
    var restored = AppState()
    try StateFile.decode(stripped).state.apply(to: &restored)
    #expect(restored.board.isEmpty)
    #expect(restored.sessions.count == 1)
}

/// A relaunch kills every pty, so no card is being worked on when the file is read back. The
/// card goes to In Review rather than To Do: To Do would paste its prompt a second time into
/// whatever auto-resume brings back.
@Test func aCardInProgressIsUpForReviewAfterARelaunch() throws {
    var (state, _, row) = makeState()
    let id = try #require(state.boardTasks(in: .todo).first?.id)
    let accepted = state.markBoardTaskDispatched(id, to: row, now: t0)
    #expect(accepted)

    var restored = AppState()
    PersistedState(state).apply(to: &restored)
    let card = try #require(restored.boardTask(id))
    #expect(card.column == .inReview)
    #expect(card.assignee == row)
    #expect(restored.nextBoardDispatches().allSatisfy { $0.task != id })
}

@Test func aCardOutlivesTheRowAndGroupItNames() throws {
    let (state, group, row) = makeState()
    var persisted = PersistedState(state)
    persisted.board.append(
        BoardTask(title: "orphan", groupID: .generate(), assignee: .generate(), createdAt: t0))

    var restored = AppState()
    let warnings = persisted.apply(to: &restored)
    #expect(warnings.isEmpty)
    #expect(restored.board.count == 4)
    let orphan = try #require(restored.board.last)
    #expect(orphan.title == "orphan")
    #expect(orphan.groupID == nil)
    #expect(orphan.assignee == nil)
    // The cards that named things which did come back keep them.
    #expect(restored.board.first?.assignee == row)
    #expect(restored.board.first?.groupID == group)
}
