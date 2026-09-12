// MainMenu.swift — the application menu bar, built from `ShortcutsTable` (M2.2 / TKZ-18).
//
// An app built without an `.xcodeproj` and without a MainMenu.nib starts with **no menu bar at
// all**, and a missing menu bar is not merely cosmetic: `NSApplication` matches ⌘-key equivalents
// against the main menu *before* the responder chain, so with no menu there is nothing to match and
// ⌘Q, ⌘W, ⌘M and friends do nothing whatsoever. That is exactly what happened in the M1 dev window
// (reported 2026-09-08: "cmd-Q did not quit the app"), and it is invisible to a headless test —
// nothing here can be exercised without a real menu bar and a key window.
//
// **There is still no Edit menu, on purpose.** `TerminalInputController` declines ⌘ combinations so
// they reach the app, and `MouseController` implements ⌘C / ⌘V itself (through a local key monitor
// in `MainWindowController`) against the terminal's own selection and paste paths. An Edit menu
// claiming those key equivalents would win the match and route them to `copy:` / `paste:` on the
// first responder, which `TerminalMetalView` does not implement — **silently breaking copy and
// paste**. The Edit menu can only come back together with `copy:`/`paste:`/`selectAll:` on the
// view, in the same change; `MainMenuTests` guards the invariant meanwhile.
//
// The same collision is why "Close Window" carries no key equivalent: `closeTerminal` owns ⌘W
// (design.md → Decisions → Shortcuts, the cmux binding), and two items with the same equivalent
// are resolved by menu order, not by which one is enabled.
//
// Every binding comes from `ShortcutsTable.resolved(state:)` — the menu is a *view* of that table
// and invents nothing. `ShortcutsTable` is the app's whole vocabulary; the menu is the part of it
// that **acts**. An action with no handler in the dispatcher gets no item at all, because this menu
// is not read only by the menu bar: `CheatSheetModel` walks it, and the palette filters on the same
// `MenuDispatcher.canPerform` set, so a permanently-disabled item here became a dead row in ⇧⌘P and
// a dead chord on the ⌘-hold card (TKZ-53). A command the user can see is a command that runs.
//
// The ids stay in `ShortcutsTable` either way — they are the `state.json` override vocabulary — so
// registering a handler is the whole of restoring an item, here and in both other surfaces.

import AppKit
import TkzCore

// MARK: - Dispatcher

/// The single `target` behind every command item in the menu bar.
///
/// Menu items carry their `ShortcutAction` in `representedObject`, so one selector serves the whole
/// menu and the palette can dispatch the same ids (`PaletteDataSource` builds command rows with
/// `actionID == ShortcutAction.rawValue`). `validateMenuItem` disables anything with no handler.
@MainActor
public final class MenuDispatcher: NSObject, NSMenuItemValidation {
    private var handlers: [ShortcutAction: () -> Void] = [:]
    /// Checkmark providers for toggle-style actions ("Auto-resume Sessions on Launch"). Read on
    /// every validation, so the mark follows the store without any observer of its own.
    private var checkmarks: [ShortcutAction: () -> Bool] = [:]

    /// Options handed to the standard About panel, filled in by `MainMenu.build`.
    ///
    /// `orderFrontStandardAboutPanel(_:)` with no options reads `Info.plist` — which does not
    /// exist under `swift run tkzmux`, so the stock panel would show an empty version there, and
    /// even inside the `.app` it knows nothing about libghostty-vt. Every field is passed
    /// explicitly instead; see `MainMenu.aboutPanelOptions(appName:version:)`.
    public var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] = [:]

    public override init() { super.init() }

    public func setHandler(_ action: ShortcutAction, _ body: @escaping () -> Void) {
        handlers[action] = body
    }

    /// Makes `action`'s item show a checkmark whenever `isOn` returns true.
    public func setCheckmark(_ action: ShortcutAction, _ isOn: @escaping () -> Bool) {
        checkmarks[action] = isOn
    }

    /// The current checkmark state, or nil for an action that has none.
    public func checkmark(for action: ShortcutAction) -> Bool? { checkmarks[action]?() }

    public func canPerform(_ action: ShortcutAction) -> Bool { handlers[action] != nil }

    /// Every action with a handler right now — what `MainMenu.build` makes items for, and what the
    /// palette lists as command rows (`CommandPaletteController.performableCommands`).
    public var performableActions: Set<ShortcutAction> { Set(handlers.keys) }

    /// Runs the action, if it has a handler. Returns whether anything ran.
    @discardableResult
    public func perform(_ action: ShortcutAction) -> Bool {
        guard let handler = handlers[action] else { return false }
        handler()
        return true
    }

    /// "About tkzmux". Not a `ShortcutAction`: it is never bound, never disabled, and the
    /// dispatcher is simply the retained target that an `NSMenuItem`'s weak `target` needs.
    ///
    /// `NSApplication.shared` rather than `NSApp`: the latter is an implicitly-unwrapped global
    /// that is **nil until something touches `.shared`**, and this method is reachable from a test
    /// that never brings the application up.
    @objc public func orderFrontAboutPanel(_ sender: Any?) {
        NSApplication.shared.orderFrontStandardAboutPanel(options: aboutPanelOptions)
    }

    @objc public func performShortcutAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String else { return }
        perform(ShortcutAction(raw))
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performShortcutAction(_:)) else { return true }
        guard let raw = menuItem.representedObject as? String else { return false }
        let action = ShortcutAction(raw)
        if let isOn = checkmarks[action] { menuItem.state = isOn() ? .on : .off }
        return canPerform(action)
    }
}

// MARK: - Menu

@MainActor
public enum MainMenu {

    /// Builds the whole menu bar. Pure: it touches no global state, so a test can build one and
    /// walk it without installing it.
    public static func build(
        appName: String = "tkzmux",
        shortcuts: [ShortcutAction: Shortcut] = ShortcutsTable.defaults,
        dispatcher: MenuDispatcher
    ) -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu(applicationMenu(appName: appName, shortcuts: shortcuts, dispatcher: dispatcher)))
        main.addItem(submenu(fileMenu(shortcuts: shortcuts, dispatcher: dispatcher)))
        main.addItem(submenu(viewMenu(shortcuts: shortcuts, dispatcher: dispatcher)))
        main.addItem(submenu(terminalMenu(shortcuts: shortcuts, dispatcher: dispatcher)))
        main.addItem(submenu(sessionMenu(shortcuts: shortcuts, dispatcher: dispatcher)))
        main.addItem(submenu(windowMenu()))

        return main
    }

    /// Installs a built menu. Safe to call more than once.
    public static func install(_ menu: NSMenu) {
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.items.first { $0.submenu?.title == "Window" }?.submenu
    }

    /// Convenience for a default menu with no window behind it (the dev window and the
    /// renderer-unavailable path). Its dispatcher has no handlers, so the menu is About / Hide /
    /// Show All / Quit / Window and nothing else — which is honest: there is no
    /// `MainWindowController` on either path, so none of the commands could have run. ⌘Q, ⌘M and
    /// ⌘W still work, because those are AppKit's own items and never go through the dispatcher.
    @discardableResult
    public static func installDefault(appName: String = "tkzmux") -> MenuDispatcher {
        let dispatcher = MenuDispatcher()
        install(build(appName: appName, dispatcher: dispatcher))
        return dispatcher
    }

    // MARK: Menus

    private static func applicationMenu(
        appName: String, shortcuts: [ShortcutAction: Shortcut], dispatcher: MenuDispatcher
    ) -> NSMenu {
        // The first item's submenu is the application menu regardless of its title; AppKit
        // substitutes the process name for the title it displays.
        let menu = NSMenu(title: appName)
        dispatcher.aboutPanelOptions = aboutPanelOptions(appName: appName)
        let about = menu.addItem(withTitle: "About \(appName)",
                                 action: #selector(MenuDispatcher.orderFrontAboutPanel(_:)),
                                 keyEquivalent: "")
        about.target = dispatcher
        menu.addItem(.separator())
        addCommand(.settings, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.reloadConfig, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.toggleAutoResume, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.statusLineIntegration, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.removeShellIntegration, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        menu.addItem(.separator())

        let hide = menu.addItem(withTitle: "Hide \(appName)",
                                action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp

        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp

        let showAll = menu.addItem(withTitle: "Show All",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: "")
        showAll.target = NSApp

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit \(appName)",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        tidySeparators(menu)
        return menu
    }

    private static func fileMenu(
        shortcuts: [ShortcutAction: Shortcut], dispatcher: MenuDispatcher
    ) -> NSMenu {
        let menu = NSMenu(title: "File")
        addCommand(.newSession, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.openFolder, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        menu.addItem(.separator())
        addCommand(.closeTerminal, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.closeSession, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        tidySeparators(menu)
        return menu
    }

    /// Panes and tabs (TKZ-36). A submenu of its own rather than more rows in View, because these
    /// are the terminal's verbs, and `MainMenuTests` requires every action to have an item
    /// somewhere — the menu is meant to be an honest inventory of what the app can do.
    private static func terminalMenu(
        shortcuts: [ShortcutAction: Shortcut], dispatcher: MenuDispatcher
    ) -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        addCommand(.newTerminal, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        menu.addItem(.separator())
        addCommand(.splitVertically, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.splitHorizontally, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        menu.addItem(.separator())
        addCommand(.focusPaneLeft, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.focusPaneRight, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.focusPaneUp, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.focusPaneDown, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        menu.addItem(.separator())
        addCommand(.equalizeSplits, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.zoomPane, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        menu.addItem(.separator())
        addCommand(.previousTab, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.nextTab, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        tidySeparators(menu)
        return menu
    }

    private static func viewMenu(
        shortcuts: [ShortcutAction: Shortcut], dispatcher: MenuDispatcher
    ) -> NSMenu {
        let menu = NSMenu(title: "View")
        addCommand(.toggleSidebar, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.toggleTheme, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        menu.addItem(.separator())
        addCommand(.searchSessions, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.commandPalette, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        menu.addItem(.separator())
        addCommand(.notifications, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        tidySeparators(menu)
        return menu
    }

    private static func sessionMenu(
        shortcuts: [ShortcutAction: Shortcut], dispatcher: MenuDispatcher
    ) -> NSMenu {
        let menu = NSMenu(title: "Session")
        addCommand(.resumeSession, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.resumeAllInGroup, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        menu.addItem(.separator())
        addCommand(.renameSession, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.jumpToNeedsYou, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.copyLastMessage, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.showFirstPrompt, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        menu.addItem(.separator())
        addCommand(.previousSession, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        addCommand(.nextSession, to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        menu.addItem(.separator())
        for n in 1...9 {
            addCommand(.selectSession(n), to: menu, shortcuts: shortcuts, dispatcher: dispatcher)
        }
        tidySeparators(menu)
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        // **No key equivalent**: ⌘W belongs to `closeTerminal`. Two items with the same
        // equivalent are resolved by menu order, and the window's would shadow it.
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "")
        return menu
    }

    // MARK: Item construction

    /// Adds `action`'s item, or nothing at all when the dispatcher has no handler for it.
    ///
    /// Absent rather than disabled: this menu is the app's only description of what it can do, and
    /// two other surfaces read it back — `CheatSheetModel` walks the built menu, and the palette
    /// filters command rows on the same `canPerform` set. An item that can never fire therefore
    /// showed up three times over as something the user could choose and nothing would happen
    /// (TKZ-53). Register a handler and the item comes back everywhere at once.
    private static func addCommand(
        _ action: ShortcutAction, to menu: NSMenu,
        shortcuts: [ShortcutAction: Shortcut], dispatcher: MenuDispatcher
    ) {
        guard dispatcher.canPerform(action) else { return }
        menu.addItem(command(action, shortcuts: shortcuts, dispatcher: dispatcher))
    }

    /// Drops leading, trailing and doubled separators, once a submenu has been filtered.
    ///
    /// The rules are written next to the items they group, so a filtered-out item leaves its rule
    /// behind: View's ⌘I is the only thing under its last separator, and losing it would end the
    /// menu on a line with nothing after it.
    private static func tidySeparators(_ menu: NSMenu) {
        var keep: [NSMenuItem] = []
        for item in menu.items {
            if item.isSeparatorItem, keep.last.map(\.isSeparatorItem) ?? true { continue }
            keep.append(item)
        }
        while keep.last?.isSeparatorItem == true { keep.removeLast() }
        guard keep.count != menu.items.count else { return }
        menu.removeAllItems()
        for item in keep { menu.addItem(item) }
    }

    /// One command item: title and binding from `ShortcutsTable`, `representedObject` = the action
    /// id, target = the dispatcher. Whether it is *present* is ``addCommand(_:to:shortcuts:dispatcher:)``'s
    /// job; `MenuDispatcher.validateMenuItem` still runs, and now only ever returns true for it.
    static func command(
        _ action: ShortcutAction,
        shortcuts: [ShortcutAction: Shortcut],
        dispatcher: MenuDispatcher
    ) -> NSMenuItem {
        let shortcut = shortcuts[action]
        let item = NSMenuItem(
            title: ShortcutsTable.title(for: action),
            action: #selector(MenuDispatcher.performShortcutAction(_:)),
            keyEquivalent: shortcut?.keyEquivalent ?? "")
        item.keyEquivalentModifierMask = shortcut?.modifierMask ?? []
        item.representedObject = action.rawValue
        item.target = dispatcher
        item.identifier = NSUserInterfaceItemIdentifier("tkzmux.menu.\(action.rawValue)")
        return item
    }

    // MARK: About panel (M6.1 / TKZ-37)

    /// Everything the standard About panel should show, taken from `AppVersion` rather than from
    /// `Info.plist` — see `MenuDispatcher.aboutPanelOptions`. `.applicationVersion` is the
    /// marketing version, `.version` the build number AppKit renders in parentheses after it.
    public static func aboutPanelOptions(
        appName: String = AppVersion.productName,
        version: AppVersion = .current
    ) -> [NSApplication.AboutPanelOptionKey: Any] {
        [
            .applicationName: appName,
            .applicationVersion: version.marketingVersion,
            .version: version.build,
            .credits: aboutCredits(version),
        ]
    }

    /// The credits block: which libghostty-vt is inside, and the two licences that matter.
    /// Short on purpose — the panel is not a documentation surface.
    private static func aboutCredits(_ version: AppVersion) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let text = """
            libghostty-vt \(version.shortGhosttyCommit)
            MIT License.
            Terminal emulation by libghostty-vt, from Ghostty — MIT License.
            """
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = menu.title
        item.submenu = menu
        return item
    }

    // MARK: Introspection (tests, and the palette's "what is bound to what")

    /// Every command item in `menu`, keyed by its action. Walks submenus.
    public static func commandItems(in menu: NSMenu) -> [ShortcutAction: NSMenuItem] {
        var out: [ShortcutAction: NSMenuItem] = [:]
        for item in allItems(in: menu) {
            guard item.action == #selector(MenuDispatcher.performShortcutAction(_:)),
                  let raw = item.representedObject as? String else { continue }
            out[ShortcutAction(raw)] = item
        }
        return out
    }

    /// Depth-first list of every item in the menu bar, separators included.
    public static func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            [item] + (item.submenu.map { allItems(in: $0) } ?? [])
        }
    }
}
