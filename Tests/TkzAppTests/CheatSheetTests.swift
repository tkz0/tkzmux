// CheatSheetTests — the ⌘-hold cheat sheet: hold ⌘ alone for two seconds and it appears.
//
// `CommandHoldDetector` carries no clock, so none of these sleep: the hold timer is "fired" by
// calling ``timerFired()``. `SelectionControllerTests` does the same with its double-click
// interval, and for the same reason — a test that waits two real seconds is a test nobody runs.
//
// The model half walks a menu built by `MainMenu.build`, which is pure and needs no key window.

import AppKit
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct CheatSheetTests {

    // MARK: Detector

    /// The gesture itself: ⌘ down, wait, card.
    @Test("Bare ⌘ held past the delay arms and then shows")
    func bareCommandShows() {
        var detector = CommandHoldDetector()
        #expect(detector.flagsChanged(commandHeld: true, commandOnly: true) == [.arm])
        #expect(detector.timerFired() == [.show])
        #expect(detector.isShowing)
    }

    @Test("⌘ released before the delay cancels, and a late timer does nothing")
    func releaseBeforeDelay() {
        var detector = CommandHoldDetector()
        #expect(detector.flagsChanged(commandHeld: true, commandOnly: true) == [.arm])
        #expect(detector.flagsChanged(commandHeld: false, commandOnly: false) == [.cancel])
        // The `DispatchSourceTimer` may already have been on its way to the main queue.
        #expect(detector.timerFired().isEmpty)
        #expect(!detector.isShowing)
    }

    @Test("⇧⌘ never arms: the gesture is the ⌘ key alone")
    func shiftCommandDoesNotArm() {
        var detector = CommandHoldDetector()
        #expect(detector.flagsChanged(commandHeld: true, commandOnly: false).isEmpty)
        #expect(detector.timerFired().isEmpty)
    }

    @Test("A key pressed while the card is up hides it")
    func keyDownHides() {
        var detector = CommandHoldDetector()
        _ = detector.flagsChanged(commandHeld: true, commandOnly: true)
        _ = detector.timerFired()
        #expect(detector.keyDown(commandHeld: true) == [.hide])
        #expect(!detector.isShowing)
    }

    /// ⌘P, then resting on ⌘, must not pop the card two seconds later.
    @Test("A chord does not re-arm while ⌘ stays down")
    func chordDoesNotReArm() {
        var detector = CommandHoldDetector()
        _ = detector.flagsChanged(commandHeld: true, commandOnly: true)
        _ = detector.timerFired()
        _ = detector.keyDown(commandHeld: true)

        #expect(detector.flagsChanged(commandHeld: true, commandOnly: true).isEmpty)
        #expect(detector.timerFired().isEmpty)
    }

    /// The reason ``flagsChanged`` takes two booleans rather than one. ⇧ going down and up again
    /// makes `commandOnly` false and then true, which a single-bit machine cannot tell apart from
    /// ⌘ being released and re-pressed — and would re-arm on.
    @Test("A modifier tapped mid-chord does not look like ⌘ being re-pressed")
    func modifierTapDoesNotReArm() {
        var detector = CommandHoldDetector()
        _ = detector.flagsChanged(commandHeld: true, commandOnly: true)
        _ = detector.keyDown(commandHeld: true)

        _ = detector.flagsChanged(commandHeld: true, commandOnly: false)   // ⇧ down, ⌘ still held
        #expect(detector.flagsChanged(commandHeld: true, commandOnly: true).isEmpty)  // ⇧ up
        #expect(detector.timerFired().isEmpty)
    }

    /// The monitor sees every key in the window, most of them ordinary typing. Those must not
    /// leave the gesture suppressed with ⌘ nowhere near the keyboard.
    @Test("Typing without ⌘ does not suppress the next hold")
    func plainTypingDoesNotSuppress() {
        var detector = CommandHoldDetector()
        #expect(detector.keyDown(commandHeld: false).isEmpty)

        #expect(detector.flagsChanged(commandHeld: true, commandOnly: true) == [.arm])
        #expect(detector.timerFired() == [.show])
    }

    @Test("Releasing ⌘ and pressing it again arms normally")
    func releaseThenPressArmsAgain() {
        var detector = CommandHoldDetector()
        _ = detector.flagsChanged(commandHeld: true, commandOnly: true)
        _ = detector.keyDown(commandHeld: true)
        _ = detector.flagsChanged(commandHeld: false, commandOnly: false)

        #expect(detector.flagsChanged(commandHeld: true, commandOnly: true) == [.arm])
        #expect(detector.timerFired() == [.show])
    }

    /// ⌘-Tab: the release lands while another app is active and no monitor of ours sees it.
    @Test("Losing key while the card is up hides it")
    func resignKeyHides() {
        var detector = CommandHoldDetector()
        _ = detector.flagsChanged(commandHeld: true, commandOnly: true)
        _ = detector.timerFired()
        #expect(detector.resignedKey() == [.hide])
    }

    /// Losing key must not leave the sheet permanently suppressed: the ⌘ release that would clear
    /// the suppression is exactly the event we never get.
    @Test("The gesture still works after coming back from another app")
    func resignKeyDoesNotWedge() {
        var detector = CommandHoldDetector()
        _ = detector.flagsChanged(commandHeld: true, commandOnly: true)
        _ = detector.keyDown(commandHeld: true)
        _ = detector.resignedKey()

        #expect(detector.flagsChanged(commandHeld: true, commandOnly: true) == [.arm])
        #expect(detector.timerFired() == [.show])
    }

    // MARK: Model

    static func makeMenu(overrides: [String: String] = [:]) -> NSMenu {
        _ = NSApplication.shared
        return MainMenu.build(
            shortcuts: ShortcutsTable.resolved(overrides: overrides),
            dispatcher: MenuDispatcher())
    }

    static func row(_ sections: [CheatSheetSection], _ title: String) -> CheatSheetRow? {
        sections.flatMap(\.rows).first { $0.title == title }
    }

    @Test("Sections follow the menu's own grouping and order")
    func sectionsMirrorTheMenu() {
        let sections = CheatSheetModel.sections(from: Self.makeMenu())
        // The application menu is titled with the app name; the rest are the real submenu titles.
        #expect(sections.map(\.title) == ["tkzmux", "File", "View", "Terminal", "Session", "Window"])
    }

    @Test("Bound commands are listed with the keys the menu carries")
    func rowsCarryTheBindings() {
        let sections = CheatSheetModel.sections(from: Self.makeMenu())
        #expect(Self.row(sections, "New Session\u{2026}")?.keys == "\u{2318}N")
        #expect(Self.row(sections, "Search Sessions\u{2026}")?.keys == "\u{2318}P")
        #expect(Self.row(sections, "Command Palette\u{2026}")?.keys == "\u{21E7}\u{2318}P")
        #expect(Self.row(sections, "Toggle Sidebar")?.keys == "\u{2318}B")
        #expect(Self.row(sections, "Settings\u{2026}")?.keys == "\u{2318},")
    }

    /// Nine menu items, one line.
    @Test("⌘1…⌘9 collapse to a single row")
    func selectSessionCollapses() {
        let sections = CheatSheetModel.sections(from: Self.makeMenu())
        let rows = sections.flatMap(\.rows)
        #expect(rows.filter { $0.title.hasPrefix("Select Session") }.count == 1)
        #expect(Self.row(sections, "Select Session n")?.keys == "\u{2318}1\u{2013}9")
    }

    /// The exclusion list is "has no key equivalent", not a hand-written set — so an action with no
    /// default binding drops out on its own.
    @Test("Commands with no binding are absent")
    func unboundCommandsAreOmitted() {
        let titles = CheatSheetModel.sections(from: Self.makeMenu()).flatMap(\.rows).map(\.title)
        #expect(!titles.contains("Next Session"))
        #expect(!titles.contains("Previous Session"))
        #expect(!titles.contains("Resume All in Group"))
    }

    /// Reading the menu rather than a private table is what buys this: the AppKit standards are
    /// ordinary menu items, so they are listed without anyone maintaining them.
    @Test("AppKit's own shortcuts are listed too")
    func standardShortcutsAppear() {
        let sections = CheatSheetModel.sections(from: Self.makeMenu())
        #expect(Self.row(sections, "Quit tkzmux")?.keys == "\u{2318}Q")
        #expect(Self.row(sections, "Hide Others")?.keys == "\u{2325}\u{2318}H")
        #expect(Self.row(sections, "Minimize")?.keys == "\u{2318}M")
    }

    @Test("A user override reaches the sheet")
    func overridesReachTheSheet() {
        let sections = CheatSheetModel.sections(
            from: Self.makeMenu(overrides: ["toggleSidebar": "ctrl+cmd+s"]))
        #expect(Self.row(sections, "Toggle Sidebar")?.keys == "\u{2303}\u{2318}S")
    }

    // MARK: Wiring

    @Test("The overlay is in the window, above everything, and passive")
    func overlayIsWired() {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }

        let overlay = harness.controller.cheatSheet.view
        #expect(overlay.isHidden)
        #expect(overlay.superview === harness.controller.chrome.view)
        // Passive: it must never take the keyboard or swallow a click.
        #expect(!overlay.acceptsFirstResponder)
        #expect(overlay.hitTest(NSPoint(x: 10, y: 10)) == nil)
        // The rows come from the live bindings.
        #expect(!CheatSheetModel.sections(from: harness.controller.buildMainMenu()).isEmpty)
    }

    /// The hold timer and the key monitor must not outlive the window.
    @Test("Shutdown puts the card away")
    func shutdownHidesTheCard() {
        let harness = MainWindowControllerTests.makeHarness()
        let cheatSheet = harness.controller.cheatSheet
        cheatSheet.flagsChanged(.command)      // arms the hold timer

        harness.tearDown()                     // calls `shutdown()`
        #expect(cheatSheet.view.isHidden)
    }
}
