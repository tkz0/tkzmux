// MainMenu.swift — the application menu bar.
//
// An app built without an `.xcodeproj` and without a MainMenu.nib starts with **no menu bar at
// all**, and a missing menu bar is not merely cosmetic: `NSApplication` matches ⌘-key equivalents
// against the main menu *before* the responder chain, so with no menu there is nothing to match and
// ⌘Q, ⌘W, ⌘M and friends do nothing whatsoever. That is exactly what happened in the M1 dev window
// (reported 2026-09-08: "cmd-Q did not quit the app"), and it is invisible to a headless test —
// nothing here can be exercised without a real menu bar and a key window.
//
// Deliberately minimal for M1. **There is no Edit menu**: `TerminalInputController` declines ⌘
// combinations so they reach the app, and `MouseController` implements ⌘C / ⌘V itself against the
// terminal's own selection and paste paths. An Edit menu claiming those key equivalents would win
// the match and route them to `copy:` / `paste:` on the first responder, which the terminal view
// does not implement — silently breaking copy and paste. M2.2 replaces this file with the real menu
// built from `ShortcutsTable`, and should move ⌘C/⌘V to `copy:`/`paste:` on the view *in the same
// change* rather than adding the menu items first.
import AppKit

@MainActor
enum MainMenu {
    /// Builds and installs the menu bar. Safe to call more than once.
    static func install(appName: String = "tkzmux") {
        let main = NSMenu()

        // MARK: Application menu
        //
        // The first item's submenu is the application menu regardless of its title; AppKit
        // substitutes the process name for the title it displays.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())

        let hide = appMenu.addItem(withTitle: "Hide \(appName)",
                                   action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp

        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp

        let showAll = appMenu.addItem(withTitle: "Show All",
                                      action: #selector(NSApplication.unhideAllApplications(_:)),
                                      keyEquivalent: "")
        showAll.target = NSApp

        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "Quit \(appName)",
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        appItem.submenu = appMenu
        main.addItem(appItem)

        // MARK: Window menu
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        // ⌘W closes the *window*. M2 gives it the cmux meaning (close terminal) and moves
        // "close window" elsewhere; until the sidebar exists there is only one window, so this is
        // the honest binding.
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
