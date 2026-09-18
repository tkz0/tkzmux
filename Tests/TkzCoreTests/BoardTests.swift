// BoardTests — the Kanban board's reducers: who takes which card, what a finished turn does to it,
// and what a removed row or group leaves behind.

import Foundation
import Testing

@testable import TkzCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// One repo group with two rows that have a Claude in them, and a second group with one.
private struct World {
    var state = AppState()
    let alpha: GroupID
    let beta: GroupID
    let one: SessionID
    let two: SessionID
    let other: SessionID

    init() {
        alpha = state.addGroup(name: "Alpha", repoRoot: "~/dev/alpha").id
        beta = state.addGroup(name: "Beta", repoRoot: "~/dev/beta").id
        one = state.createSession(groupID: alpha, cwd: "~/dev/alpha", title: "one").id
        two = state.createSession(groupID: alpha, cwd: "~/dev/alpha", title: "two").id
        other = state.createSession(groupID: beta, cwd: "~/dev/beta", title: "other").id
        for id in [one, two, other] {
            state.setLive(LiveSessionState(pid: 100, status: .idle), for: id)
        }
    }
}

@Suite("Board")
struct BoardTests {
    // MARK: Cards

    @Test("A card's prompt is its title, then its notes under a blank line")
    func prompt() {
        #expect(BoardTask(title: " Fix the flake ", createdAt: t0).prompt == "Fix the flake")
        #expect(
            BoardTask(title: "Fix the flake", notes: "It is in PromptCardTests.\n", createdAt: t0).prompt
                == "Fix the flake\n\nIt is in PromptCardTests.")
    }

    @Test("An assignee brings its group; an unknown group is dropped")
    func adding() {
        var w = World()
        let a = w.state.addBoardTask(title: "a", assignee: w.other, now: t0)
        let b = w.state.addBoardTask(title: "b", groupID: GroupID.generate(), now: t0)
        #expect(w.state.boardTask(a)?.groupID == w.beta)
        #expect(w.state.boardTask(b)?.groupID == nil)
        #expect(w.state.boardTasks(in: .todo).map(\.title) == ["a", "b"])
    }

    @Test("A move lands at an index among the column's other cards")
    func moving() {
        var w = World()
        let ids = ["a", "b", "c"].map { w.state.addBoardTask(title: $0, now: t0) }
        w.state.moveBoardTask(ids[2], to: .todo, at: 0)
        #expect(w.state.boardTasks(in: .todo).map(\.title) == ["c", "a", "b"])
        w.state.moveBoardTask(ids[0], to: .done)
        w.state.moveBoardTask(ids[1], to: .done, at: 0)
        #expect(w.state.boardTasks(in: .done).map(\.title) == ["b", "a"])
        #expect(w.state.boardTasks(in: .todo).map(\.title) == ["c"])
        w.state.moveBoardTask(ids[2], to: .done, at: 99)
        #expect(w.state.boardTasks(in: .done).map(\.title) == ["b", "a", "c"])
    }

    @Test("Changing the group drops an agent from another group")
    func regrouping() {
        var w = World()
        let id = w.state.addBoardTask(title: "a", assignee: w.one, now: t0)
        w.state.setBoardTaskGroup(id, to: w.beta)
        #expect(w.state.boardTask(id)?.assignee == nil)
        #expect(w.state.boardTask(id)?.groupID == w.beta)
    }

    // MARK: Who takes what

    @Test("An agent takes its own cards in To Do order, one at a time")
    func ownQueue() throws {
        var w = World()
        let first = w.state.addBoardTask(title: "first", assignee: w.one, now: t0)
        let second = w.state.addBoardTask(title: "second", assignee: w.one, now: t0)

        let dispatch = try #require(w.state.nextBoardDispatches().first)
        #expect(dispatch.task == first)
        #expect(dispatch.session == w.one)
        #expect(dispatch.prompt == "first")
        #expect(dispatch.terminal == w.state.sessions[w.one]?.focusedTerminalID)

        let accepted = w.state.markBoardTaskDispatched(first, to: w.one, now: t0)
        #expect(accepted)
        #expect(w.state.boardTask(first)?.column == .inProgress)
        // One at a time: the second card waits for the first one's turn to end.
        #expect(w.state.nextBoardDispatches().isEmpty)

        w.state.applyHook(.init(kind: .stop, lastAssistantMessage: "done"), to: w.one, now: t0)
        #expect(w.state.boardTask(first)?.column == .inReview)
        #expect(w.state.boardTask(first)?.assignee == w.one)
        #expect(w.state.nextBoardDispatches().map(\.task) == [second])
    }

    /// The rule that replaced "a row has to be named by a card first" (2026-09-18): a group with an
    /// idle Claude in it has an agent, with nothing to set up.
    @Test("A group card is taken by any Claude in that group, and only in that group")
    func groupPickup() {
        var w = World()
        let open = w.state.addBoardTask(title: "open", groupID: w.alpha, now: t0)
        let next = w.state.nextBoardDispatches()
        #expect(next.map(\.task) == [open])
        #expect(next.map(\.session) == [w.one])   // sidebar order; never `other`, which is in Beta

        w.state.markBoardTaskDispatched(open, to: w.one, now: t0)
        #expect(w.state.boardTask(open)?.assignee == w.one)
        #expect(w.state.nextBoardDispatches().isEmpty)
    }

    @Test("A row's own card comes before its group's")
    func ownBeforeGroup() {
        var w = World()
        let open = w.state.addBoardTask(title: "open", groupID: w.alpha, now: t0)
        let own = w.state.addBoardTask(title: "own", assignee: w.one, now: t0)
        let next = w.state.nextBoardDispatches()
        #expect(next.first { $0.session == w.one }?.task == own)
        #expect(next.first { $0.session == w.two }?.task == open)
    }

    /// The row the user is in: a group card pasted there would land in what they are typing.
    @Test("A reserved row takes its own cards but no group card")
    func reserved() {
        var w = World()
        let open = w.state.addBoardTask(title: "open", groupID: w.alpha, now: t0)
        #expect(w.state.nextBoardDispatches(reserved: [w.one]).map(\.session) == [w.two])
        #expect(w.state.nextBoardDispatches(reserved: [w.one, w.two]).isEmpty)

        let own = w.state.addBoardTask(title: "own", assignee: w.one, now: t0)
        let next = w.state.nextBoardDispatches(reserved: [w.one, w.two])
        #expect(next.map(\.task) == [own])
        #expect(w.state.boardTask(open)?.column == .todo)
    }

    @Test("A bare shell is not an agent")
    func shellsAreNotAgents() {
        var w = World()
        w.state.addBoardTask(title: "open", groupID: w.alpha, now: t0)
        for id in [w.one, w.two] { w.state.setLive(LiveSessionState(status: .idle), for: id) }
        #expect(!w.state.hasClaude(w.one))
        #expect(w.state.hasClaude(w.other))
        #expect(w.state.nextBoardDispatches().isEmpty)
    }

    @Test("Two free agents never get the same group card")
    func noDoubleHandout() {
        var w = World()
        let a = w.state.addBoardTask(title: "a", groupID: w.alpha, now: t0)
        let b = w.state.addBoardTask(title: "b", groupID: w.alpha, now: t0)
        let next = w.state.nextBoardDispatches()
        #expect(next.map(\.task) == [a, b])
        #expect(Set(next.map(\.session)) == [w.one, w.two])
    }

    @Test("A card goes only to a Claude that is there and free")
    func readiness() {
        var w = World()
        w.state.addBoardTask(title: "a", assignee: w.one, now: t0)

        let cases: [(LiveSessionState?, Bool, Comment)] = [
            (LiveSessionState(pid: 1, status: .idle), true, "idle"),
            (LiveSessionState(pid: 1, status: .waiting(.doneUnattended)), true, "a finished turn nobody looked at"),
            (nil, false, "no shell"),
            (LiveSessionState(status: .idle), false, "a bare shell"),
            (LiveSessionState(pid: 1, status: .working), false, "mid-turn"),
            (LiveSessionState(pid: 1, status: .waiting(.permission)), false, "a permission prompt"),
            (LiveSessionState(pid: 1, status: .waiting(.elicitation)), false, "a question"),
            (LiveSessionState(pid: 1, status: .idle, ended: true), false, "Claude exited"),
            (LiveSessionState(pid: 1, status: .idle, alive: false), false, "the pty is gone"),
        ]
        for (live, expected, comment) in cases {
            w.state.sessions[w.one]?.live = live
            #expect(w.state.nextBoardDispatches().isEmpty != expected, comment)
        }
    }

    @Test("A dispatch is refused once the card or the agent has moved on")
    func staleDispatch() {
        var w = World()
        let a = w.state.addBoardTask(title: "a", assignee: w.one, now: t0)
        let b = w.state.addBoardTask(title: "b", assignee: w.one, now: t0)
        let wrongAgent = w.state.markBoardTaskDispatched(a, to: w.two)
        #expect(!wrongAgent)   // it is `one`'s card
        let taken = w.state.markBoardTaskDispatched(a, to: w.one)
        #expect(taken)
        let whileBusy = w.state.markBoardTaskDispatched(b, to: w.one)
        #expect(!whileBusy)   // `one` is busy with `a`
        w.state.moveBoardTask(b, to: .done)
        w.state.applyHook(.init(kind: .stop), to: w.one, now: t0)
        let afterDone = w.state.markBoardTaskDispatched(b, to: w.one)
        #expect(!afterDone)   // no longer in To Do
    }

    // MARK: What removal leaves behind

    @Test("Re-assigning the card in progress sends it back to To Do for the new agent")
    func reassignInProgress() {
        var w = World()
        let a = w.state.addBoardTask(title: "a", assignee: w.one, now: t0)
        w.state.markBoardTaskDispatched(a, to: w.one, now: t0)
        w.state.assignBoardTask(a, to: w.two)
        let task = w.state.boardTask(a)
        #expect(task?.column == .todo)
        #expect(task?.assignee == w.two)
        #expect(task?.dispatchedAt == nil)
    }

    @Test("Removing a row un-assigns its cards and re-queues the one in progress")
    func removingASession() {
        var w = World()
        let active = w.state.addBoardTask(title: "active", assignee: w.one, now: t0)
        let queued = w.state.addBoardTask(title: "queued", assignee: w.one, now: t0)
        let reviewed = w.state.addBoardTask(title: "reviewed", column: .inReview, assignee: w.one, now: t0)
        w.state.markBoardTaskDispatched(active, to: w.one, now: t0)

        w.state.removeSession(w.one)
        #expect(w.state.board.allSatisfy { $0.assignee == nil })
        #expect(w.state.board.allSatisfy { $0.groupID == w.alpha })
        #expect(w.state.boardTask(active)?.column == .todo)
        #expect(w.state.boardTask(queued)?.column == .todo)
        #expect(w.state.boardTask(reviewed)?.column == .inReview)
    }

    @Test("Removing a group keeps its cards and drops the label")
    func removingAGroup() {
        var w = World()
        let a = w.state.addBoardTask(title: "a", groupID: w.alpha, now: t0)
        let b = w.state.addBoardTask(title: "b", assignee: w.other, now: t0)
        w.state.removeGroup(w.alpha)
        #expect(w.state.boardTask(a)?.groupID == nil)
        w.state.removeGroup(w.beta, reassignTo: GroupID.generate())   // unknown: rows are removed
        #expect(w.state.boardTask(b)?.groupID == nil)
        #expect(w.state.boardTask(b)?.assignee == nil)
    }

    @Test("Rows moved to another group take their group's cards with them")
    func reassigningAGroup() {
        var w = World()
        let a = w.state.addBoardTask(title: "a", assignee: w.one, now: t0)
        w.state.removeGroup(w.alpha, reassignTo: w.beta)
        #expect(w.state.boardTask(a)?.groupID == w.beta)
        #expect(w.state.boardTask(a)?.assignee == w.one)
    }

    // MARK: Change sets

    @Test("A card change is `board` and nothing else")
    func changeSet() {
        let w = World()
        var new = w.state
        new.addBoardTask(title: "a", assignee: w.one, now: t0)
        #expect(ChangeSet.diff(from: w.state, to: new) == ChangeSet(board: true))
    }
}
