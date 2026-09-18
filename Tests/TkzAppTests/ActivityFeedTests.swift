// ActivityFeedTests — ⌘I through the running window: the panel is built and sized but never
// ordered front (`keepOffScreen` stubs `orderFront`), keys are driven through the controller's
// own entry points, and the context menu item's action is sent, never clicked.

import AppKit
import Foundation
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite("Activity feed", .serialized)
struct ActivityFeedTests {
    static let now = Fixture.now

    @MainActor struct World {
        var harness: MainWindowControllerTests.Harness
        var alpha: SessionID
        var beta: SessionID
        var feed: ActivityFeedController { harness.controller.activityFeed }
    }

    /// The fixture's first two rows, given live state and one entry each while nobody looks. The
    /// fixture's own live states are stripped first: its working rows would otherwise be pinned
    /// above the threads, and its NEEDS YOU rows are not what these tests are about.
    static func makeWorld() -> World {
        var state = AppState.fixture
        for id in state.sessions.keys { state.setLive(nil, for: id) }
        state.select(nil)
        let harness = MainWindowControllerTests.makeHarness(state)
        let alpha = Fixture.sessionID(0)
        let beta = Fixture.sessionID(1)
        harness.mutate { state in
            for id in [alpha, beta] { state.setLive(LiveSessionState(status: .idle), for: id) }
            state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "alpha finished"), to: alpha, now: now)
            state.applyEvent(
                .init(kind: .attention(.permission), message: "Bash?"),
                to: beta, now: now.addingTimeInterval(1))
        }
        harness.controller.activityFeed.now = { now.addingTimeInterval(120) }
        return World(harness: harness, alpha: alpha, beta: beta)
    }

    @Test("⌘I presents the panel over the terminal and ⌘I again takes it down")
    func toggle() throws {
        let world = Self.makeWorld()
        defer { world.harness.tearDown() }
        var ordered: [NSWindow] = []
        world.feed.orderFront = { ordered.append($0) }

        world.harness.controller.dispatcher.perform(.notifications)
        let panel = try #require(world.feed.panelForTesting)
        #expect(ordered.count == 1 && ordered.first === panel)
        #expect(world.feed.isShown)
        #expect(panel.frame.width == ActivityFeedController.width)
        #expect(world.feed.rowsForTesting.count == 2)
        // Newest first: beta's prompt came after alpha's Stop.
        #expect(world.feed.rowsForTesting.map(\.sessionID) == [world.beta, world.alpha])
        #expect(world.feed.selectedIndexForTesting == 0)

        world.harness.controller.dispatcher.perform(.notifications)
        #expect(!world.feed.isShown)
        #expect(ordered.count == 1, "taking it down orders nothing front")
    }

    @Test("↓ then ↵ selects that row in the store, marks its thread read, and closes the panel")
    func activate() throws {
        let world = Self.makeWorld()
        defer { world.harness.tearDown() }
        world.feed.present(over: nil)
        #expect(world.harness.store.state.activity.map(\.unread) == [true, true])

        world.feed.moveSelection(by: 1)
        #expect(world.feed.selectedIndexForTesting == 1)
        world.feed.moveSelection(by: 1)
        #expect(world.feed.selectedIndexForTesting == 1, "no wraparound")
        world.feed.activateSelection()
        world.harness.store.flush()

        #expect(!world.feed.isShown)
        #expect(world.harness.store.state.selection == world.alpha)
        #expect(world.harness.store.state.activity.map(\.unread) == [false, true])
    }

    @Test("esc closes; typing filters; → and ← fold the selected thread")
    func keysAndFilter() throws {
        let world = Self.makeWorld()
        defer { world.harness.tearDown() }
        // A second Stop on alpha so it has something to fold.
        world.harness.mutate { state in
            state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "alpha again"), to: world.alpha, now: Self.now.addingTimeInterval(5))
        }
        world.feed.present(over: nil)
        #expect(world.feed.rowsForTesting.map(\.sessionID) == [world.alpha, world.beta])

        world.feed.setSelectedThreadExpanded(true)
        #expect(world.feed.expandedForTesting == [world.alpha])
        #expect(world.feed.rowsForTesting.count == 3)
        if case .folded(let folded) = world.feed.rowsForTesting[1] {
            #expect(folded.event.kind == .stop(message: "alpha finished"))
        } else {
            Issue.record("the folded entry should follow its thread")
        }
        world.feed.moveSelection(by: 1)  // onto the folded row
        world.feed.setSelectedThreadExpanded(false)
        #expect(world.feed.expandedForTesting.isEmpty)
        #expect(world.feed.selectedIndexForTesting == 0, "folding lands on the thread")

        world.feed.updateQuery("bash")
        #expect(world.feed.rowsForTesting.map(\.sessionID) == [world.beta])
        world.feed.updateQuery("")
        #expect(world.feed.rowsForTesting.count == 2)

        let field = try #require(world.feed.searchFieldForTesting)
        let editor = NSTextView()
        #expect(world.feed.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
        #expect(world.feed.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveWordRight(_:))) == false, "⌥→ stays with the caret")
        #expect(world.feed.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!world.feed.isShown)
    }

    @Test("Mark as Unread from the context menu raises the thread again")
    func markUnread() throws {
        let world = Self.makeWorld()
        defer { world.harness.tearDown() }
        world.harness.mutate { $0.select(world.beta) }
        #expect(world.harness.store.state.activity.map(\.unread) == [true, false])
        world.feed.present(over: nil)

        // A working row and an empty row offer no menu; a thread offers one item.
        let menu = try #require(world.feed.contextMenuForTesting(row: 0))
        let item = try #require(menu.items.first)
        #expect(item.title == "Mark as Unread")
        #expect(item.isEnabled, "beta is read, so it can be marked unread")
        _ = item.target?.perform(item.action, with: item)
        world.harness.store.flush()
        #expect(world.harness.store.state.activity.map(\.unread) == [true, true])

        let again = try #require(world.feed.contextMenuForTesting(row: 0)?.items.first)
        #expect(!again.isEnabled, "already unread")
        #expect(world.feed.contextMenuForTesting(row: 5) == nil)
    }

    @Test("A new entry arriving while the panel is up is drawn, and the selection stays on its row")
    func liveUpdate() throws {
        let world = Self.makeWorld()
        defer { world.harness.tearDown() }
        world.feed.present(over: nil)
        world.feed.moveSelection(by: 1)  // alpha
        let gamma = Fixture.sessionID(2)
        world.harness.mutate { state in
            state.setLive(LiveSessionState(status: .idle), for: gamma)
            state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "gamma too"), to: gamma, now: Self.now.addingTimeInterval(30))
        }
        #expect(world.feed.rowsForTesting.map(\.sessionID) == [gamma, world.beta, world.alpha])
        #expect(world.feed.selectedIndexForTesting == 2, "still alpha")
    }
}
