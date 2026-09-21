import AppKit
import Foundation
import Testing
import TkzCore

@testable import TkzApp

/// ⌘F's search overlay and the window controller's half of its wiring (design 2c.6).
///
/// The toolbar carried the field until the 2026-09-20 GUI pass; the overlay owns it now, so these
/// drive `CommandPaletteController` directly. The bug they still cover: a keystroke used to update
/// the palette's model without ever showing its panel, so every character went into a table nobody
/// could see. The assertions are therefore always about *both* halves — the rows and the window.
@MainActor
@Suite(.serialized)
struct SearchOverlayWiringTests {

    // MARK: Geometry

    /// It hung from the window's top-right corner until 2026-09-20, under a toolbar field that no
    /// longer exists. It is centred now, like the ⌘-hold cheat sheet's card.
    @Test func overlayIsCentredOnTheWindow() {
        let host = NSRect(x: 100, y: 200, width: 1240, height: 820)
        let frame = CommandPaletteController.searchFrame(host: host, contentHeight: 300)

        #expect(frame.width == 560)
        #expect(frame.height == 300)
        #expect(frame.midX == host.midX)
        #expect(frame.midY == host.midY)
    }

    /// An odd host width must not leave the panel on a half-pixel, which draws its 1 pt accent
    /// hairline blurred.
    @Test func theCentredFrameLandsOnWholePoints() {
        let host = NSRect(x: 0, y: 0, width: 1241, height: 823)
        let frame = CommandPaletteController.searchFrame(host: host, contentHeight: 301)
        #expect(frame.origin.x == frame.origin.x.rounded())
        #expect(frame.origin.y == frame.origin.y.rounded())
    }

    @Test func overlayHeightIsClampedToTheDesignsBounds() {
        let host = NSRect(x: 0, y: 0, width: 1240, height: 820)
        #expect(CommandPaletteController.searchFrame(host: host, contentHeight: 10).height == 120)
        #expect(CommandPaletteController.searchFrame(host: host, contentHeight: 4000).height == 560)
    }

    // MARK: Opening

    /// The whole point of the GUI pass: ⌘F is the only way in, and it must open the *overlay* —
    /// sections, chips and all — not ⇧⌘P's flat list.
    @Test func commandFOpensTheAnchoredOverlayWithItsOwnField() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.beginSearch()
        #expect(controller.palette.isPresented)
        #expect(controller.palette.presentation == .search)
        #expect(controller.palette.query == "")
        let field = try #require(controller.palette.searchFieldForTesting)
        #expect(!field.isHidden, "with no toolbar field left, the overlay has to draw its own")
        #expect(field.placeholderString == CommandPaletteController.searchPlaceholder)
        controller.palette.dismiss()
    }

    /// ⌘F pressed again while the overlay is up must not throw the query away.
    @Test func reopeningKeepsWhatWasTyped() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.beginSearch()
        controller.palette.typeForTesting("main")
        controller.beginSearch()
        #expect(controller.palette.query == "main")
        #expect(controller.palette.searchFieldForTesting?.stringValue == "main")
        controller.palette.dismiss()
    }

    // MARK: Typing

    @Test func typingShowsResultsOnTheFirstKeystroke() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.beginSearch()
        controller.palette.typeForTesting("m")

        #expect(controller.palette.isPresented, "the panel must actually be on screen")
        #expect(!controller.palette.results.isEmpty)
        #expect(controller.palette.presentation == .search)
        // Every hit is a session: ⌘F's surface is not the command palette.
        #expect(controller.palette.results.allSatisfy { $0.item.kind == .session })
        controller.endSearch()
    }

    @Test func theQuerySurvivesEveryKeystroke() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.beginSearch()
        for query in ["m", "ma", "mai", "main"] { controller.palette.typeForTesting(query) }
        #expect(controller.palette.query == "main")
        #expect(!controller.palette.results.isEmpty)
        controller.endSearch()
    }

    /// Backspacing to empty drops the sections that had to be read, but leaves the overlay up with
    /// the caret in its field — the user is mid-edit, and the next character has to land in the box.
    @Test func emptyingTheFieldDropsTheSectionsItWasShowing() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.beginSearch()
        controller.palette.typeForTesting("main")
        let session = try #require(controller.palette.results.first?.item.sessionID)
        controller.palette.setTranscriptRows([
            TranscriptRow(
                sessionID: session, sessionTitle: "s", turn: 1, kind: .user, excerpt: "main",
                matchRanges: [], at: nil)
        ])
        #expect(!controller.palette.transcriptRows.isEmpty)

        controller.palette.typeForTesting("")
        #expect(controller.palette.transcriptRows.isEmpty, "stale hits must not survive a retype")
        #expect(controller.palette.fileRows.isEmpty)
        #expect(controller.palette.isPresented, "the caret stays in the field")
        controller.endSearch()
    }

    @Test func theOverlayMatchesContiguouslyRatherThanFuzzily() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        controller.beginSearch()

        // The fixture has no session containing "almi"; a subsequence matcher would still find
        // rows whose text has an a, an l, an m and an i somewhere (GUI pass 2026-09-11).
        controller.palette.typeForTesting("almi")
        #expect(
            controller.palette.results.isEmpty,
            "scattered letters are not a hit: \(controller.palette.results.map(\.item.title))")

        // A real substring still lands.
        let title = try #require(harness.store.state.orderedSessions.first?.displayTitle)
        let needle = String(title.prefix(4))
        controller.palette.typeForTesting(needle)
        #expect(controller.palette.results.contains { $0.item.title.lowercased().contains(needle.lowercased()) })
        controller.endSearch()
    }

    @Test func closingTheOverlayIsNotEndingTheSearch() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.beginSearch()
        controller.palette.typeForTesting("main")

        // Closing drops what was on screen; the text is the overlay's own, so it goes with it.
        controller.closeSearchOverlay()
        #expect(!controller.palette.isPresented)
        #expect(controller.palette.transcriptRows.isEmpty)

        controller.endSearch()
        #expect(!controller.palette.isPresented)
    }

    // MARK: Arrows and Return

    @Test func arrowsMoveTheSelectionAndReturnActivatesIt() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.beginSearch()
        controller.palette.typeForTesting("m")
        // The overlay leads with a "Sessions" header, so the first selection is the row under it.
        let first = try #require(controller.palette.selectedIndex)
        #expect(controller.palette.rows[first].isSelectable)
        let firstID = controller.palette.selectedResult?.item.sessionID

        controller.palette.moveSelection(by: 1)
        #expect(controller.palette.selectedIndex == first + 1)
        #expect(controller.palette.selectedResult?.item.sessionID != firstID)
        controller.palette.moveSelection(by: -1)
        #expect(controller.palette.selectedIndex == first)

        let target = try #require(controller.palette.selectedResult?.item.sessionID)
        controller.palette.activateSelection()
        #expect(harness.store.state.selection == target)
        #expect(!controller.palette.isPresented)
    }

    // MARK: The field's editor commands

    @Test func theOverlaysFieldRelaysTheListKeysAndConsumesThem() throws {
        let controller = Self.overlayController()
        let field = try #require(controller.searchFieldForTesting)
        let editor = NSTextView()
        controller.typeForTesting("m")

        func send(_ selector: Selector) -> Bool {
            controller.control(field, textView: editor, doCommandBy: selector)
        }

        let first = try #require(controller.selectedIndex)
        #expect(send(#selector(NSResponder.moveDown(_:))))
        #expect(controller.selectedIndex == first + 1)
        #expect(send(#selector(NSResponder.moveUp(_:))))
        #expect(controller.selectedIndex == first)

        // ⇥ must be consumed, or the caret leaves the field instead of cycling the scope chips.
        #expect(send(#selector(NSResponder.insertTab(_:))))
        #expect(controller.scope == .sessions)
        #expect(send(#selector(NSResponder.insertBacktab(_:))))
        #expect(controller.scope == .all)
        // ← / → do the same as ⇥ / ⇧⇥ in the overlay.
        #expect(send(#selector(NSResponder.moveRight(_:))))
        #expect(controller.scope == .sessions)
        #expect(send(#selector(NSResponder.moveLeft(_:))))
        #expect(controller.scope == .all)

        // Editing keys still belong to the field editor.
        #expect(!send(#selector(NSResponder.deleteBackward(_:))))
        #expect(!send(#selector(NSResponder.moveWordLeft(_:))), "⌥← still moves the caret")

        #expect(send(#selector(NSResponder.cancelOperation(_:))))
        #expect(!controller.isPresented)
    }

    /// ⇧⌘P draws no chips, so ← and → there are the field editor's — they move the caret through
    /// the query being typed.
    @Test func arrowsMoveTheCaretInTheCentredPalette() throws {
        _ = NSApplication.shared
        let controller = CommandPaletteController(state: .fixture, mode: .all)
        controller.present(state: .fixture)
        let field = try #require(controller.searchFieldForTesting)
        let editor = NSTextView()

        #expect(!controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(!controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
        #expect(controller.scope == .all)
        // ⇥ is consumed regardless: letting it through takes the caret out of the field.
        #expect(controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        controller.dismiss()
    }

    @Test func theArrowsCycleTheChipsThroughTheWholeStack() throws {
        let controller = Self.overlayController()
        controller.typeForTesting("m")

        controller.cycleScope(by: 1)
        #expect(controller.scope == .sessions)
        controller.cycleScope(by: -1)
        #expect(controller.scope == .all)
        controller.cycleScope(by: -1)
        #expect(controller.scope == .filesChanged, "the chips wrap")
        controller.dismiss()
    }

    /// A controller already in the overlay's presentation, hung from a throwaway window.
    static func overlayController() -> CommandPaletteController {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.borderless], backing: .buffered, defer: true)
        let controller = CommandPaletteController(state: .fixture, mode: .sessions)
        controller.presentSearch(over: window, state: .fixture)
        return controller
    }
}
