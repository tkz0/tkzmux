import AppKit
import Foundation
import Testing
import TkzCore

@testable import TkzApp

/// The toolbar's "Search sessions…" field and the results overlay it opens (TKZ-52, design 2c.6).
///
/// The bug this covers: `onSearchChanged` used to update the palette's model without ever showing
/// its panel, so every keystroke went into a table nobody could see. The assertions below are
/// therefore always about *both* halves — the rows and the window.
@MainActor
@Suite(.serialized)
struct ToolbarSearchTests {

    // MARK: Geometry

    @Test func overlayHangsFromTheWindowsTopRightCorner() {
        let host = NSRect(x: 100, y: 200, width: 1240, height: 820)
        let frame = CommandPaletteController.anchoredFrame(host: host, contentHeight: 300)

        #expect(frame.width == 560)
        #expect(frame.height == 300)
        // 14 pt in from the right edge, 44 pt down from the top — design 2c.6.
        #expect(frame.maxX == host.maxX - 14)
        #expect(frame.maxY == host.maxY - 44)
    }

    @Test func overlayHeightIsClampedToTheDesignsBounds() {
        let host = NSRect(x: 0, y: 0, width: 1240, height: 820)
        #expect(CommandPaletteController.anchoredFrame(host: host, contentHeight: 10).height == 120)
        #expect(CommandPaletteController.anchoredFrame(host: host, contentHeight: 4000).height == 560)
    }

    // MARK: Typing

    @Test func typingShowsResultsOnTheFirstKeystroke() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller

        let changed = try #require(controller.toolbarController.onSearchChanged)
        changed("m")

        #expect(controller.palette.isPresented, "the panel must actually be on screen")
        #expect(!controller.palette.results.isEmpty)
        #expect(controller.palette.presentation == .anchored)
        // Every hit is a session: the toolbar field is ⌘P's surface, not the command palette.
        #expect(controller.palette.results.allSatisfy { $0.item.kind == .session })
    }

    @Test func theQuerySurvivesEveryKeystroke() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let changed = try #require(harness.controller.toolbarController.onSearchChanged)

        // Re-presenting per character must not reset the query the way ⇧⌘P's `present` does.
        for query in ["m", "ma", "mai", "main"] { changed(query) }
        #expect(harness.controller.palette.query == "main")
        #expect(!harness.controller.palette.results.isEmpty)
    }

    @Test func clearingTheFieldClosesTheOverlay() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        _ = controller.window.toolbar?.items
        let changed = try #require(controller.toolbarController.onSearchChanged)

        controller.toolbarController.searchField?.stringValue = "main"
        changed("main")
        #expect(controller.palette.isPresented)

        // ...but the caret stays put. Backspacing to empty and typing again must keep going into
        // the field, not into the terminal (GUI pass 2026-09-11), so closing the overlay must not
        // move the first responder and must not empty the field on the user's behalf.
        let responderBefore = controller.window.firstResponder
        controller.toolbarController.searchField?.stringValue = ""
        changed("")
        #expect(!controller.palette.isPresented, "nothing may be left floating")
        #expect(controller.window.firstResponder === responderBefore)

        changed("ma")
        #expect(controller.palette.isPresented, "typing again reopens it")
    }

    @Test func emptyingTheFieldDropsTheSectionsItWasShowing() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let changed = try #require(controller.toolbarController.onSearchChanged)

        changed("main")
        let session = try #require(controller.palette.results.first?.item.sessionID)
        controller.palette.setTranscriptRows([
            TranscriptRow(
                sessionID: session, sessionTitle: "s", turn: 1, kind: .user, excerpt: "main",
                matchRanges: [], at: nil)
        ])
        #expect(!controller.palette.transcriptRows.isEmpty)

        changed("")
        #expect(controller.palette.transcriptRows.isEmpty, "stale hits must not survive a reopen")
        #expect(controller.palette.fileRows.isEmpty)
    }

    @Test func theOverlayMatchesContiguouslyRatherThanFuzzily() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let changed = try #require(controller.toolbarController.onSearchChanged)

        // The fixture has no session containing "almi"; a subsequence matcher would still find
        // rows whose text has an a, an l, an m and an i somewhere (GUI pass 2026-09-11).
        changed("almi")
        #expect(
            controller.palette.results.isEmpty,
            "scattered letters are not a hit: \(controller.palette.results.map(\.item.title))")

        // A real substring still lands.
        let title = try #require(harness.store.state.orderedSessions.first?.displayTitle)
        let needle = String(title.prefix(4))
        changed(needle)
        #expect(controller.palette.results.contains { $0.item.title.lowercased().contains(needle.lowercased()) })
    }

    @Test func onlyEscapeAndAnActivationHandTheKeyboardBack() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        _ = controller.window.toolbar?.items
        let changed = try #require(controller.toolbarController.onSearchChanged)

        controller.toolbarController.searchField?.stringValue = "main"
        changed("main")

        // Closing the overlay is not ending the search: the field keeps what the user typed.
        controller.closeSearchOverlay()
        #expect(!controller.palette.isPresented)
        #expect(controller.toolbarController.searchField?.stringValue == "main")

        controller.endSearch()
        #expect(controller.toolbarController.searchField?.stringValue == "")
    }

    @Test func escapeClosesTheOverlayAndEmptiesTheField() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        _ = controller.window.toolbar?.items  // vend the items so the field exists
        let changed = try #require(controller.toolbarController.onSearchChanged)
        let cancel = try #require(controller.toolbarController.onSearchCancel)

        controller.toolbarController.searchField?.stringValue = "main"
        changed("main")
        #expect(controller.palette.isPresented)

        cancel()
        #expect(!controller.palette.isPresented)
        #expect(controller.toolbarController.searchField?.stringValue == "")
    }

    // MARK: Arrows and Return

    @Test func arrowsMoveTheSelectionAndReturnActivatesIt() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let changed = try #require(controller.toolbarController.onSearchChanged)
        let move = try #require(controller.toolbarController.onSearchMove)
        let submit = try #require(controller.toolbarController.onSearchSubmit)

        changed("m")
        // The overlay leads with a "Sessions" header, so the first selection is the row under it.
        let first = try #require(controller.palette.selectedIndex)
        #expect(controller.palette.rows[first].isSelectable)
        let firstID = controller.palette.selectedResult?.item.sessionID

        move(1)
        #expect(controller.palette.selectedIndex == first + 1)
        #expect(controller.palette.selectedResult?.item.sessionID != firstID)
        move(-1)
        #expect(controller.palette.selectedIndex == first)

        let target = try #require(controller.palette.selectedResult?.item.sessionID)
        submit("m")
        #expect(harness.store.state.selection == target)
        #expect(!controller.palette.isPresented)
    }

    @Test func returnWithNoOverlayDoesNothing() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let before = harness.store.state.selection
        let submit = try #require(harness.controller.toolbarController.onSearchSubmit)
        submit("whatever")
        #expect(harness.store.state.selection == before)
    }

    // MARK: The field's editor commands

    @Test func theFieldRelaysTheListKeysAndConsumesThem() throws {
        let controller = MainToolbarController()
        let field = NSSearchField()
        let editor = NSTextView()
        var moves: [Int] = []
        var scopes: [Int] = []
        var cancelled = 0
        var submitted: [String] = []
        controller.onSearchMove = { moves.append($0) }
        controller.onSearchCycleScope = { scopes.append($0); return true }
        controller.onSearchCancel = { cancelled += 1 }
        controller.onSearchSubmit = { submitted.append($0) }
        field.stringValue = "web"

        func send(_ selector: Selector) -> Bool {
            controller.control(field, textView: editor, doCommandBy: selector)
        }

        #expect(send(#selector(NSResponder.moveDown(_:))))
        #expect(send(#selector(NSResponder.moveUp(_:))))
        #expect(moves == [1, -1])
        // Tab must be consumed, or the caret leaves the field instead of cycling the scope chips.
        #expect(send(#selector(NSResponder.insertTab(_:))))
        #expect(send(#selector(NSResponder.insertBacktab(_:))))
        #expect(scopes == [1, -1])
        // ← / → do the same as ⇥ / ⇧⇥ while the overlay is up.
        #expect(send(#selector(NSResponder.moveRight(_:))))
        #expect(send(#selector(NSResponder.moveLeft(_:))))
        #expect(scopes == [1, -1, 1, -1])
        #expect(send(#selector(NSResponder.cancelOperation(_:))))
        #expect(cancelled == 1)
        #expect(send(#selector(NSResponder.insertNewline(_:))))
        #expect(submitted == ["web"])
        // Editing keys still belong to the field editor.
        #expect(!send(#selector(NSResponder.deleteBackward(_:))))
        #expect(!send(#selector(NSResponder.moveWordLeft(_:))), "⌥← still moves the caret")
    }

    @Test func arrowsMoveTheCaretWhenThereIsNoOverlay() throws {
        let controller = MainToolbarController()
        let field = NSSearchField()
        let editor = NSTextView()
        // The window controller answers `false` when the overlay is down; the field must then let
        // the key through so ← and → still move the caret in the query being typed.
        controller.onSearchCycleScope = { _ in false }

        #expect(!controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(!controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
        // Tab is consumed regardless: letting it through takes the caret out of the field.
        #expect(controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    }

    @Test func theArrowsCycleTheChipsThroughTheWholeStack() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let changed = try #require(controller.toolbarController.onSearchChanged)
        let cycle = try #require(controller.toolbarController.onSearchCycleScope)

        // No overlay yet: the arrows are the field editor's.
        #expect(!cycle(1))

        changed("m")
        #expect(cycle(1))
        #expect(controller.palette.scope == .sessions)
        #expect(cycle(-1))
        #expect(controller.palette.scope == .all)
        #expect(cycle(-1))
        #expect(controller.palette.scope == .filesChanged, "the chips wrap")
    }

    // MARK: ⌘P's fallback (acceptance: works with the sidebar hidden)

    @Test func commandPFallsBackToTheCentredPaletteWithoutTheToolbarItem() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        harness.controller.window.toolbar = nil

        harness.controller.beginSearch()
        #expect(harness.controller.palette.isPresented)
        #expect(harness.controller.palette.presentation == .centred)
        harness.controller.palette.dismiss()
    }
}
