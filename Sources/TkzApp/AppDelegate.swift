// AppDelegate — opens `MainWindowController` (M2.2 / TKZ-18), the real window: sidebar, terminal,
// status bar, unified toolbar and the menu bar built from `ShortcutsTable`.
//
// `DevWindowController` (M1.6 / M1.10) stays reachable behind **`TKZMUX_DEV_WINDOW=1`**: it carries
// the TKZ-16 performance harness (`TKZMUX_DEV_SPAWN`, `TKZMUX_DEV_SWITCH_BENCH`, the snapshot
// sweeps, the heartbeat) that `docs/perf.md` and `docs/manual-checks.md` document command lines
// for. Losing it would invalidate the documented acceptance runs, so it is one env var away:
//
//   TKZMUX_DEV_WINDOW=1 TKZMUX_DEV_SPAWN=30 … swift run tkzmux    → the M1 dev window
//   swift run tkzmux                                              → the main window
//
// `TKZMUX_DEV_AUTOQUIT_MS` works on **both** paths and prints the active window's diagnostics line,
// so either window can be smoke-tested headlessly.

import AppKit
import Foundation
import TkzCore
import TkzTerminalRender
import TkzTerminalView
import os

/// Application delegate.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var renderContext: TerminalRenderContext?
    private var mainWindow: MainWindowController?
    private var devWindow: DevWindowController?
    private var fallbackWindow: NSWindow?
    private var store: AppStore?
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "app")

    /// Milliseconds after launch to print engine diagnostics and quit. Development only: it is how
    /// `swift run tkzmux` can be driven headlessly enough to prove that a window opened, a session
    /// spawned and frames were encoded.
    private static let autoQuitKey = "TKZMUX_DEV_AUTOQUIT_MS"
    /// Opens the M1 development window (and its perf harness) instead of the main window.
    private static let devWindowKey = "TKZMUX_DEV_WINDOW"

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let context = try TerminalRenderContext(theme: .default)
            renderContext = context
            if Self.wantsDevWindow {
                // Without a menu bar, NSApplication has nothing to match ⌘-key equivalents
                // against, so ⌘Q, ⌘M and ⌘W are simply dead (reported 2026-09-08).
                MainMenu.installDefault()
                let controller = DevWindowController(renderContext: context)
                devWindow = controller
                controller.showWindow()
            } else {
                let store = AppStore(state: Self.initialState())
                self.store = store
                let controller = MainWindowController(store: store, renderContext: context)
                mainWindow = controller
                // After the window: the menu's handlers capture the controller.
                controller.installMainMenu()
                controller.showWindow()
            }
        } catch {
            MainMenu.installDefault()
            logger.error("renderer unavailable: \(String(describing: error), privacy: .public)")
            showFallbackWindow(error)
        }
        scheduleAutoQuitIfRequested()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        devWindow?.shutdown()
        mainWindow?.shutdown()
    }

    /// `TKZMUX_DEV_WINDOW=1` (or `true`/`yes`).
    static var wantsDevWindow: Bool {
        guard let raw = ProcessInfo.processInfo.environment[devWindowKey]?.lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    /// The state the main window starts from: `AppState.fixture` (real sessions arrive in M3/M5),
    /// with the persisted window frame and sidebar visibility applied on top.
    static func initialState() -> AppState {
        var state = AppState.fixture
        MainWindowController.restoreChrome(into: &state, from: .standard)
        return state
    }

    /// No GPU (or no shaders): still show *something* rather than launching invisibly.
    private func showFallbackWindow(_ error: Error) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "tkzmux — renderer unavailable"
        let label = NSTextField(wrappingLabelWithString: String(describing: error))
        label.frame = window.contentLayoutRect.insetBy(dx: 16, dy: 16)
        label.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(label)
        window.center()
        window.makeKeyAndOrderFront(nil)
        fallbackWindow = window
    }

    private func scheduleAutoQuitIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment[AppDelegate.autoQuitKey],
              let milliseconds = Int(raw), milliseconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
            MainActor.assumeIsolated {
                let line = self.devWindow?.diagnosticsLine()
                    ?? self.mainWindow?.diagnosticsLine()
                    ?? "no window"
                FileHandle.standardError.write(Data("TKZMUX_DEV \(line)\n".utf8))
                NSApp.terminate(nil)
            }
        }
    }
}
