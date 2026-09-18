// ActivityFeedModelTests — which rows the ⌘I feed lists, from a state and a query, no window.

import Foundation
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite struct ActivityFeedModelTests {
    let now = Fixture.now

    struct World {
        var state: AppState
        var alpha: SessionID
        var beta: SessionID
        var gamma: SessionID
    }

    /// Three live rows: alpha finished twice and then exited, beta needs permission, gamma is
    /// working since 63 minutes ago.
    func makeWorld() -> World {
        var state = AppState()
        let northwind = state.addGroup(name: "Northwind")
        let toolbox = state.addGroup(name: "Toolbox")
        let alpha = state.createSession(groupID: northwind.id, cwd: "/tmp/alpha", title: "review").id
        let beta = state.createSession(groupID: northwind.id, cwd: "/tmp/beta", title: "billing").id
        let gamma = state.createSession(groupID: toolbox.id, cwd: "/tmp/gamma", title: "docs").id
        for id in [alpha, beta, gamma] { state.setLive(LiveSessionState(status: .idle), for: id) }

        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "First pass done.\nSee the diff."), to: alpha, now: now)
        state.applyEvent(.init(kind: .promptSubmitted), to: alpha, now: now.addingTimeInterval(60))
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "Refactored the websocket reconnect.\n\nTests are green.\nShip it."), to: alpha, now: now.addingTimeInterval(120))
        state.applyEvent(.init(kind: .sessionEnd(exited: true), reason: "prompt_input_exit"), to: alpha, now: now.addingTimeInterval(180))

        state.applyEvent(
            .init(kind: .attention(.permission), message: "Claude needs your permission to use Bash"),
            to: beta, now: now.addingTimeInterval(30))

        state.applyObservation(
            AgentObservation(pid: 9, conversationId: "g", configDir: "~/.claude", activity: .busy,
                              statusUpdatedAt: now.addingTimeInterval(-63 * 60)),
            alive: true, to: gamma, now: now)
        return World(state: state, alpha: alpha, beta: beta, gamma: gamma)
    }

    func rows(_ world: World, query: String = "", expanded: Set<SessionID> = []) -> [ActivityFeedModel.Row] {
        ActivityFeedModel.rows(state: world.state, query: query, expanded: expanded, now: now.addingTimeInterval(600))
    }

    @Test func workingRowsArePinnedFirstWithTheirElapsedTime() throws {
        let world = makeWorld()
        let list = rows(world)
        guard case .working(let working)? = list.first else { Issue.record("no pinned row"); return }
        #expect(working.sessionID == world.gamma)
        #expect(working.title == "docs")
        #expect(working.groupName == "Toolbox")
        #expect(working.elapsed == "1h 13m")
        #expect(ActivityWorkingRowView.trailingText(working) == "working \u{00B7} 1h 13m")
    }

    @Test func oneThreadPerRowNewestHeadFirst() throws {
        let world = makeWorld()
        let threads = rows(world).compactMap { row -> ActivityFeedModel.ThreadRow? in
            if case .thread(let t) = row { return t }
            return nil
        }
        #expect(threads.map(\.sessionID) == [world.alpha, world.beta])
        let alpha = try #require(threads.first)
        // The exit never heads the thread: the newest Stop does, with the marker.
        #expect(alpha.head.kind == .stop(message: "Refactored the websocket reconnect.\n\nTests are green.\nShip it."))
        #expect(alpha.head.preview == "Refactored the websocket reconnect.\nTests are green.")
        #expect(alpha.ended)
        #expect(alpha.olderCount == 2)
        #expect(alpha.unread, "the second Stop was never looked at")
        #expect(ActivityThreadRowView.metaText(alpha, age: "8m") == "Northwind \u{00B7} 8m \u{00B7} ended")
        #expect(ActivityThreadRowView.olderText(alpha) == "+2 older")

        let beta = try #require(threads.last)
        #expect(beta.head.kind == .needsYou(reason: .permission, message: "Claude needs your permission to use Bash"))
        #expect(!beta.ended)
        #expect(beta.olderCount == 0)
        #expect(ActivityFeedModel.kindLabel(beta.head.kind) == "NEEDS YOU \u{00B7} permission")
    }

    @Test func anExitAloneHeadsItsThreadAndNeverBoldsIt() throws {
        var world = makeWorld()
        let delta = world.state.createSession(groupID: world.state.orderedGroups[0].id, cwd: "/tmp/delta").id
        world.state.setLive(LiveSessionState(status: .idle), for: delta)
        world.state.applyEvent(.init(kind: .sessionEnd(exited: true), reason: "other"), to: delta, now: now.addingTimeInterval(500))
        let thread = try #require(rows(world).compactMap { row -> ActivityFeedModel.ThreadRow? in
            if case .thread(let t) = row, t.sessionID == delta { return t }
            return nil
        }.first)
        #expect(thread.head.kind == .sessionEnded(reason: "other"))
        #expect(!thread.ended)
        #expect(!thread.unread)
        #expect(ActivityFeedModel.kindLabel(thread.head.kind) == "ENDED \u{00B7} other")
    }

    @Test func anExpandedThreadListsItsOlderEntriesNewestFirst() {
        let world = makeWorld()
        let list = rows(world, expanded: [world.alpha])
        let folded = list.compactMap { row -> ActivityEvent.Kind? in
            if case .folded(let f) = row { return f.event.kind }
            return nil
        }
        #expect(folded == [.sessionEnded(reason: "prompt_input_exit"), .stop(message: "First pass done.\nSee the diff.")])
        // Folded rows sit directly under their thread.
        if case .thread(let t) = list[1] { #expect(t.sessionID == world.alpha && t.expanded) } else { Issue.record("thread expected") }
        if case .folded = list[2] {} else { Issue.record("folded expected") }
    }

    @Test func theFilterMatchesTitleGroupAndMessageContiguously() {
        let world = makeWorld()
        func ids(_ query: String) -> [SessionID] { rows(world, query: query).compactMap(\.sessionID) }

        #expect(ids("bill") == [world.beta])
        #expect(ids("toolbox") == [world.gamma], "a working row is filtered by its group too")
        #expect(ids("northwind") == [world.alpha, world.beta])
        // A word from the message, beyond the two preview lines.
        #expect(ids("ship it") == [world.alpha])
        // A word from an older entry of the thread.
        #expect(ids("first pass") == [world.alpha])
        // Contiguous only: a subsequence is not a hit.
        #expect(ids("rvw").isEmpty)
        #expect(ids("bsh").isEmpty)
        if case .empty(let text)? = rows(world, query: "zzz").first { #expect(text == ActivityFeedModel.noMatchText) } else { Issue.record("empty row expected") }
    }

    @Test func highlightRangesLandOnTheTitleAndThePreview() throws {
        let world = makeWorld()
        let list = rows(world, query: "websocket")
        guard case .thread(let alpha)? = list.first(where: { $0.sessionID == world.alpha }) else { Issue.record("alpha missing"); return }
        #expect(alpha.titleRanges.isEmpty, "the title did not match")
        #expect(alpha.previewRanges.count == 1)
        #expect(alpha.head.preview[try #require(alpha.previewRanges.first)] == "websocket")

        let byTitle = rows(world, query: "rev")
        guard case .thread(let hit)? = byTitle.first(where: { $0.sessionID == world.alpha }) else { Issue.record("alpha missing"); return }
        #expect(hit.titleRanges.count == 1)
        #expect(hit.head.sessionTitle[try #require(hit.titleRanges.first)] == "rev")
    }

    @Test func anEmptyLogSaysSo() {
        let state = AppState.fixture
        let list = ActivityFeedModel.rows(state: state, query: "", expanded: [], now: now)
        // The fixture has working rows pinned; drop them and only the empty line remains.
        let threads = list.filter { if case .thread = $0 { return true }; return false }
        #expect(threads.isEmpty)
        var quiet = AppState()
        _ = quiet.addGroup(name: "g")
        if case .empty(let text)? = ActivityFeedModel.rows(state: quiet, query: "", expanded: [], now: now).first {
            #expect(text == ActivityFeedModel.emptyText)
        } else {
            Issue.record("empty row expected")
        }
    }

    @Test func rowHeightsFollowThePreview() {
        let world = makeWorld()
        for row in rows(world, expanded: [world.alpha]) {
            switch row {
            case .working: #expect(ActivityFeedController.height(of: row) == 32)
            case .thread(let t): #expect(ActivityFeedController.height(of: row) == (t.head.preview.isEmpty ? 40 : 64))
            case .folded(let f): #expect(ActivityFeedController.height(of: row) == (f.event.preview.isEmpty ? 26 : 44))
            case .empty: #expect(ActivityFeedController.height(of: row) == 40)
            }
        }
    }
}
