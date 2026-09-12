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

    /// `handlers` defaults to everything: since TKZ-53 the menu only carries actions the dispatcher
    /// can perform, so a menu built with no handlers has no command items at all. The tests that
    /// assert the *shape* of the menu want the whole vocabulary; the ones about filtering pass a
    /// narrower list on purpose.
    static func makeMenu(
        shortcuts: [ShortcutAction: Shortcut] = ShortcutsTable.defaults,
        handlers: [ShortcutAction] = ShortcutsTable.allActions
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
        #expect(items[.closeTerminal]?.keyEquivalent == "w")
        // ⌘W closes the focused pane and falls through to the row when it is the last one
        // (TKZ-36); ⇧⌘W is the unconditional one, which `docs/shortcuts.md` promised from M2.4.
        #expect(items[.closeTerminal]?.title == "Close Terminal")
        #expect(items[.closeSession]?.keyEquivalent == "w")
        #expect(items[.closeSession]?.keyEquivalentModifierMask == [.command, .shift])
        #expect(items[.newTerminal]?.keyEquivalent == "t")
        #expect(items[.splitVertically]?.keyEquivalent == "d")
        #expect(items[.splitHorizontally]?.keyEquivalentModifierMask == [.command, .shift])
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

    @Test("An item with a handler is enabled and runs it; one without has no item at all")
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

        // TKZ-53: an action with no handler is absent, not greyed out. `toggleSidebar` is the only
        // handler this dispatcher has, so it is the only command item in the whole menu.
        #expect(items[.settings] == nil)
        #expect(items.count == 1)

        // The validator still runs, and now only ever sees items it says yes to. An item built for
        // an action whose handler went away is still a no-op rather than a crash.
        let orphan = MainMenu.command(
            .settings, shortcuts: ShortcutsTable.defaults, dispatcher: dispatcher)
        #expect(dispatcher.validateMenuItem(orphan) == false)
        dispatcher.performShortcutAction(orphan)
        #expect(ran == 1)

        // Standard items (Quit, Minimize) are not the dispatcher's business.
        let quit = try #require(MainMenu.allItems(in: menu).first { $0.title.hasPrefix("Quit ") })
        #expect(dispatcher.validateMenuItem(quit))
    }

    @Test("A handlerless action is absent from the menu, and a handler brings it back")
    func handlerlessActionsAreAbsent() throws {
        // Everything but Settings…: the item, its separator neighbours and its chord all go.
        let (without, _) = Self.makeMenu(
            handlers: ShortcutsTable.allActions.filter { $0 != .settings })
        #expect(MainMenu.commandItems(in: without)[.settings] == nil)
        #expect(!MainMenu.allItems(in: without).contains { $0.title == ShortcutsTable.title(for: .settings) })

        let (with, _) = Self.makeMenu()
        let item = try #require(MainMenu.commandItems(in: with)[.settings])
        #expect(item.keyEquivalent == ",")
        #expect(item.keyEquivalentModifierMask == [.command])
    }

    @Test("No submenu is left with a leading, trailing or doubled separator")
    func separatorsStayTidy() {
        // The three still-unimplemented actions, dropped: View's ⌘I is alone under the menu's last
        // rule, so removing it would otherwise end the menu on a line with nothing after it.
        let wired = ShortcutsTable.allActions.filter {
            ![.settings, .notifications, .reloadConfig].contains($0)
        }
        let (menu, _) = Self.makeMenu(handlers: wired)
        for top in menu.items {
            guard let submenu = top.submenu else { continue }
            let items = submenu.items
            #expect(items.first?.isSeparatorItem != true, "\(submenu.title) starts on a separator")
            #expect(items.last?.isSeparatorItem != true, "\(submenu.title) ends on a separator")
            for (a, b) in zip(items, items.dropFirst()) {
                #expect(!(a.isSeparatorItem && b.isSeparatorItem), "\(submenu.title) has two in a row")
            }
            #expect(!items.isEmpty)
        }
        // The View menu is the one that loses its tail.
        let view = menu.items.first { $0.submenu?.title == "View" }?.submenu
        #expect(view?.items.last?.title == ShortcutsTable.title(for: .commandPalette))
    }

    @Test("The window controller wires the actions it can actually perform")
    func windowControllerHandlers() {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let dispatcher = harness.controller.dispatcher

        for action in [ShortcutAction.newSession, .searchSessions, .commandPalette, .toggleSidebar,
                       .jumpToNeedsYou, .nextSession, .previousSession, .closeTerminal,
                       .renameSession, .copyLastMessage, .showFirstPrompt, .removeShellIntegration,
                       .openFolder,
                       .statusLineIntegration, .resumeSession, .resumeAllInGroup,
                       .toggleAutoResume] {
            #expect(dispatcher.canPerform(action), "\(action.rawValue) should be wired")
        }
        for n in 1...9 {
            #expect(dispatcher.canPerform(.selectSession(n)))
        }
        // Deliberately not implemented yet (TKZ-55 / TKZ-35 / TKZ-56), and therefore not in the
        // menu, the palette or the cheat sheet either (TKZ-53).
        for action in [ShortcutAction.notifications, .settings, .reloadConfig] {
            #expect(dispatcher.canPerform(action) == false, "\(action.rawValue) is not implemented yet")
            #expect(MainMenu.commandItems(in: harness.controller.buildMainMenu())[action] == nil)
        }
        // The auto-resume toggle is the one checkmark item; it follows the store.
        #expect(dispatcher.checkmark(for: .toggleAutoResume) == false)
        harness.mutate { $0.setAutoResumeOnLaunch(true) }
        #expect(dispatcher.checkmark(for: .toggleAutoResume) == true)
        let item = MainMenu.commandItems(in: MainMenu.build(dispatcher: dispatcher))[.toggleAutoResume]!
        _ = dispatcher.validateMenuItem(item)
        #expect(item.state == .on)
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

    // MARK: About panel (M6.1 / TKZ-37)
    //
    // The panel itself cannot be asserted headlessly, so these check the two things that actually
    // broke: the item must reach the dispatcher (an `NSMenuItem.target` is *weak*, so a target
    // that nothing else retains leaves the item dead), and the options must be populated from
    // `AppVersion` rather than from `Info.plist`, which does not exist under `swift run`.

    @Test("About targets the dispatcher and is always enabled")
    func aboutItemIsWired() {
        let (menu, dispatcher) = Self.makeMenu()
        let appMenu = menu.items[0].submenu!
        let about = appMenu.items.first { $0.title == "About tkzmux" }

        #expect(about != nil)
        #expect(about?.action == #selector(MenuDispatcher.orderFrontAboutPanel(_:)))
        // Identity, not just non-nil: the weak target must be the dispatcher the menu retains.
        #expect(about?.target as? MenuDispatcher === dispatcher)
        // Not a ShortcutAction, so validation must leave it enabled rather than disable it for
        // having no handler.
        #expect(dispatcher.validateMenuItem(about!) == true)
    }

    @Test("About panel options come from AppVersion, not Info.plist")
    func aboutPanelOptionsArePopulated() {
        let version = AppVersion(infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "287",
            "TkzGhosttyCommit": "82232ecde55405559dec29c5466cb9e39938cb41",
        ])
        let options = MainMenu.aboutPanelOptions(appName: "tkzmux", version: version)

        #expect(options[.applicationName] as? String == "tkzmux")
        #expect(options[.applicationVersion] as? String == "1.2.3")
        #expect(options[.version] as? String == "287")

        let credits = options[.credits] as? NSAttributedString
        #expect(credits != nil)
        // The commit is the whole reason we don't use the stock panel: a bug report has to say
        // which libghostty-vt is inside.
        #expect(credits?.string.contains("82232ecde554") == true)
        #expect(credits?.string.contains("MIT") == true)
    }

    @Test("Building the menu installs the About options on the dispatcher")
    func buildPopulatesDispatcherOptions() {
        let (_, dispatcher) = Self.makeMenu()
        // Empty here would mean the panel silently falls back to Info.plist.
        #expect(dispatcher.aboutPanelOptions.isEmpty == false)
        #expect(dispatcher.aboutPanelOptions[.applicationName] as? String == "tkzmux")
    }
}
