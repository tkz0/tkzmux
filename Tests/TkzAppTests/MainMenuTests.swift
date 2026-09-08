// MainMenuTests — M2.2 (TKZ-18), the menu bar.
//
// The menu is the one part of the app that cannot be exercised without a real key window, so these
// tests assert its *shape* instead: that every `ShortcutAction` is present with the binding
// `ShortcutsTable` gives it, that ⌘Q is `NSApplication.terminate(_:)` on `NSApp` (asserted, never
// invoked — calling it would end the test process), that no two items fight over one key
// equivalent, and that there is **no Edit menu**.
//
// That last one is a regression guard, not a stylistic preference: ⌘C/⌘V are handled by
// `MouseController` through a local event monitor that runs *before* menu matching. An Edit menu
// would win the match and send `copy:`/`paste:` to a first responder that does not implement them,
// silently breaking copy and paste. See the header of `MainMenu.swift`.

import AppKit
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct MainMenuTests {

    static func makeMenu(
        shortcuts: [ShortcutAction: Shortcut] = ShortcutsTable.defaults,
        handlers: [ShortcutAction] = []
    ) -> (NSMenu, MenuDispatcher) {
        _ = NSApplication.shared
        let dispatcher = MenuDispatcher()
        for action in handlers { dispatcher.setHandler(action) {} }
        return (MainMenu.build(shortcuts: shortcuts, dispatcher: dispatcher), dispatcher)
    }

    // MARK: - Coverage

    @Test("Every action in ShortcutsTable has a menu item")
    func everyActionPresent() {
        let (menu, _) = Self.makeMenu()
        let items = MainMenu.commandItems(in: menu)
        for action in ShortcutsTable.allActions {
            #expect(items[action] != nil, "missing menu item for \(action.rawValue)")
            #expect(items[action]?.title == ShortcutsTable.title(for: action))
        }
        #expect(items.count == ShortcutsTable.allActions.count)
    }

    @Test("Key equivalents and modifier masks come from ShortcutsTable")
    func bindingsMatchTable() throws {
        let (menu, _) = Self.makeMenu()
        let items = MainMenu.commandItems(in: menu)

        for (action, shortcut) in ShortcutsTable.defaults {
            let item = try #require(items[action], "no item for \(action.rawValue)")
            #expect(item.keyEquivalent == shortcut.keyEquivalent)
            #expect(item.keyEquivalentModifierMask == shortcut.modifierMask)
        }

        // Spot-check the design's spelling directly, so a broken table cannot pass by agreeing
        // with itself: ⌘N, ⇧⌘P, ⌘B, ⇧⌘W, ⌘1, ⇧⌘,
        #expect(items[.newSession]?.keyEquivalent == "n")
        #expect(items[.newSession]?.keyEquivalentModifierMask == [.command])
        #expect(items[.commandPalette]?.keyEquivalent == "p")
        #expect(items[.commandPalette]?.keyEquivalentModifierMask == [.command, .shift])
        #expect(items[.toggleSidebar]?.keyEquivalent == "b")
        #expect(items[.closeSession]?.keyEquivalentModifierMask == [.command, .shift])
        #expect(items[.selectSession(1)]?.keyEquivalent == "1")
        #expect(items[.reloadConfig]?.keyEquivalent == ",")
        #expect(items[.reloadConfig]?.keyEquivalentModifierMask == [.command, .shift])
        // nextSession/previousSession have no cmux default and must stay unbound.
        #expect(items[.nextSession]?.keyEquivalent == "")
    }

    @Test("A user override in AppState reaches the menu")
    func overrideReachesMenu() throws {
        var state = AppState()
        state.shortcuts = ["toggleSidebar": "shift+cmd+e"]
        let (menu, _) = Self.makeMenu(shortcuts: ShortcutsTable.resolved(state: state))
        let item = try #require(MainMenu.commandItems(in: menu)[.toggleSidebar])
        #expect(item.keyEquivalent == "e")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
    }

    // MARK: - Collisions

    @Test("No two items claim the same key equivalent")
    func noDuplicateKeyEquivalents() {
        let (menu, _) = Self.makeMenu()
        var seen: [String: String] = [:]
        for item in MainMenu.allItems(in: menu) where !item.keyEquivalent.isEmpty {
            let key = "\(item.keyEquivalent)/\(item.keyEquivalentModifierMask.rawValue)"
            #expect(seen[key] == nil, "\(item.title) collides with \(seen[key] ?? "") on \(key)")
            seen[key] = item.title
        }
    }

    @Test("Close Window keeps its item but not ⌘W — that binding is Close Terminal's")
    func closeWindowHasNoKeyEquivalent() throws {
        let (menu, _) = Self.makeMenu()
        let closeWindow = try #require(
            MainMenu.allItems(in: menu).first { $0.title == "Close Window" })
        #expect(closeWindow.keyEquivalent == "")
        #expect(closeWindow.action == #selector(NSWindow.performClose(_:)))
        let closeTerminal = try #require(MainMenu.commandItems(in: menu)[.closeTerminal])
        #expect(closeTerminal.keyEquivalent == "w")
        #expect(closeTerminal.keyEquivalentModifierMask == [.command])
    }

    // MARK: - The Edit-menu trap

    @Test("There is no Edit menu and nothing routes copy:/paste:/selectAll:")
    func noEditMenu() {
        let (menu, _) = Self.makeMenu()
        #expect(menu.items.allSatisfy { $0.submenu?.title != "Edit" })
        let forbidden: [Selector] = [
            #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)),
            #selector(NSText.cut(_:)),
        ]
        for item in MainMenu.allItems(in: menu) {
            #expect(item.action.map { forbidden.contains($0) } != true, "\(item.title) routes an Edit action")
        }
        // And no item claims ⌘C or ⌘V, whatever it is called.
        for item in MainMenu.allItems(in: menu)
        where item.keyEquivalentModifierMask == [.command] {
            #expect(item.keyEquivalent != "c")
            #expect(item.keyEquivalent != "v")
        }
    }

    // MARK: - Standard items

    @Test("⌘Q terminates the application")
    func quitItem() throws {
        let (menu, _) = Self.makeMenu()
        let quit = try #require(MainMenu.allItems(in: menu).first { $0.title.hasPrefix("Quit ") })
        // Asserted, never sent: performing it would end the test process.
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
        #expect(quit.target === NSApp)
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == [.command])
    }

    @Test("⌘M minimizes and the Window menu is the one AppKit is told about")
    func windowMenu() throws {
        let (menu, _) = Self.makeMenu()
        let minimize = try #require(MainMenu.allItems(in: menu).first { $0.title == "Minimize" })
        #expect(minimize.action == #selector(NSWindow.performMiniaturize(_:)))
        #expect(minimize.keyEquivalent == "m")

        MainMenu.install(menu)
        #expect(NSApp.mainMenu === menu)
        #expect(NSApp.windowsMenu?.title == "Window")
    }

    // MARK: - Dispatch and enablement

    @Test("An item with a handler is enabled and runs it; one without is disabled")
    func dispatchAndValidation() throws {
        _ = NSApplication.shared
        let dispatcher = MenuDispatcher()
        var ran = 0
        dispatcher.setHandler(.toggleSidebar) { ran += 1 }
        let menu = MainMenu.build(dispatcher: dispatcher)
        let items = MainMenu.commandItems(in: menu)

        let wired = try #require(items[.toggleSidebar])
        #expect(dispatcher.validateMenuItem(wired))
        #expect(wired.target === dispatcher)
        #expect(wired.action == #selector(MenuDispatcher.performShortcutAction(_:)))
        dispatcher.performShortcutAction(wired)
        #expect(ran == 1)

        let unwired = try #require(items[.settings])
        #expect(dispatcher.validateMenuItem(unwired) == false)
        dispatcher.performShortcutAction(unwired)   // no handler: a no-op, not a crash
        #expect(ran == 1)

        // Standard items (Quit, Minimize) are not the dispatcher's business.
        let quit = try #require(MainMenu.allItems(in: menu).first { $0.title.hasPrefix("Quit ") })
        #expect(dispatcher.validateMenuItem(quit))
    }

    @Test("The window controller wires the actions it can actually perform")
    func windowControllerHandlers() {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let dispatcher = harness.controller.dispatcher

        for action in [ShortcutAction.newSession, .searchSessions, .commandPalette, .toggleSidebar,
                       .jumpToNeedsYou, .nextSession, .previousSession, .closeTerminal,
                       .renameSession, .copyLastMessage, .removeShellIntegration] {
            #expect(dispatcher.canPerform(action), "\(action.rawValue) should be wired")
        }
        for n in 1...9 {
            #expect(dispatcher.canPerform(.selectSession(n)))
        }
        // Present in the menu, deliberately not implemented yet. `closeSession` (remove the row) is
        // M5.2's; the rest are M3/M4/Later.
        for action in [ShortcutAction.closeSession, .notifications,
                       .settings, .openFolder, .reloadConfig] {
            #expect(dispatcher.canPerform(action) == false, "\(action.rawValue) is not implemented yet")
        }
    }

    @Test("⌘B through the menu dispatcher toggles the real sidebar")
    func toggleSidebarThroughMenu() {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }

        harness.controller.dispatcher.perform(.toggleSidebar)
        harness.store.flush()
        harness.layout()
        #expect(harness.store.state.sidebarVisible == false)
        #expect(harness.controller.splitViewController.splitViewItems[0].isCollapsed)
    }
}
