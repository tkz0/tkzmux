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
import ClaudeBridge
import Foundation
import Persistence
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
    private var autosaver: StateAutosaver?
    private var claude: ClaudeIntegration?
    private var git: GitIntegration?
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "app")

    /// Milliseconds after launch to print engine diagnostics and quit. Development only: it is how
    /// `swift run tkzmux` can be driven headlessly enough to prove that a window opened, a session
    /// spawned and frames were encoded.
    private static let autoQuitKey = "TKZMUX_DEV_AUTOQUIT_MS"
    /// Opens the M1 development window (and its perf harness) instead of the main window.
    private static let devWindowKey = "TKZMUX_DEV_WINDOW"
    private static let fixtureKey = "TKZMUX_FIXTURE"

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
                let restored = Self.restoreState()
                let store = AppStore(state: restored.state)
                self.store = store
                let controller = MainWindowController(store: store, renderContext: context)
                mainWindow = controller
                if let loaded = restored.loaded {
                    // The saver is created *after* the window so the window's own first mutations
                    // (a frame nudge from `setFrame`, say) are compared against the file we just
                    // read rather than written back to it.
                    let saver = StateAutosaver(
                        store: store, file: Self.stateFile, loaded: loaded)
                    saver.start()
                    autosaver = saver
                    if let notice = loaded.notice { controller.showNotice(notice) }
                    for warning in restored.warnings {
                        logger.warning("state.json: \(warning, privacy: .public)")
                    }
                }
                // After the window: the menu's handlers capture the controller.
                controller.installMainMenu()
                controller.showWindow()
                // M3: shim install, hook socket, descriptor watcher, usage + sidecar readers.
                // After the window because `TerminalViewHost` owns the directory the socket and
                // the shim live in; nothing here blocks the launch.
                if let host = controller.host as? TerminalViewHost {
                    // M5.2: snapshots whose row is gone (`Remove` while the app was not running,
                    // a hand-edited state.json) are deleted now. TKZ-29 left this to this ticket.
                    // Every leaf of every tab, not just the row ids: a `.ghsnap` belongs to a
                    // *terminal* (TKZ-36), and a background tab's panes have one on disk long
                    // before they are restored. On a file migrated from schema v1 this set is
                    // byte-identical to the old `sessions.keys`, which is the cheapest possible
                    // proof that the v1→v2 lift kept every snapshot addressable.
                    Self.housekeepSnapshots(
                        host.snapshots,
                        keeping: Set(
                            store.state.sessions.values.flatMap(\.terminalIDs).map(\.rawValue)))
                    let integration = ClaudeIntegration(
                        store: store, directory: host.tkzmuxDirectory,
                        installer: Self.makeShimInstaller(directory: host.tkzmuxDirectory))
                    controller.claude = integration
                    integration.start()
                    claude = integration
                }
                // M4: git status, PR lookup and port scanning for the rows the window shows.
                // After `claude`, so the Stop hook it installs reaches a coordinator that exists.
                let gitIntegration = GitIntegration(store: store)
                controller.git = gitIntegration
                git = gitIntegration
                // After the integration: every `claude --resume` must run through the shim the
                // installer just wrote, so the launch frame binds its pid.
                if restored.loaded != nil { controller.autoResumeIfEnabled() }
                // TKZ-32: the one-time statusline offer. Async so the launch is never blocked on a
                // modal, and last so `bin/tkzmux-hook` — the command it writes into settings.json —
                // is already on disk.
                DispatchQueue.main.async { controller.offerStatuslineIfNeeded() }
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
        claude?.stop()
        git?.stop()
        devWindow?.shutdown()
        mainWindow?.shutdown()
        // After `shutdown`, and synchronously: the debounced write for the last mutation before ⌘Q
        // has not fired yet, and `flush` re-projects from the store rather than trusting a change
        // set that was never delivered.
        autosaver?.flush()
    }

    /// `TKZMUX_DEV_WINDOW=1` (or `true`/`yes`).
    static var wantsDevWindow: Bool { isEnabled(devWindowKey) }

    /// `TKZMUX_FIXTURE=1` seeds the window with `AppState.fixture` instead of an empty state, so
    /// the sidebar can be compared against the design artboards (M2.3 / M2.4). Its rows are
    /// fabricated and deliberately not launchable — see `AppState.startup`.
    static var wantsFixture: Bool { isEnabled(fixtureKey) }

    private static func isEnabled(_ key: String) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[key]?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    static var stateFile: StateFile { .standard() }

    /// Deletes `.ghsnap` files no row in `state.json` claims, and stale temp files. Logged, never
    /// fatal: housekeeping that stops the launch would be worse than a stray file.
    static func housekeepSnapshots(_ snapshots: SnapshotStore, keeping ids: Set<String>) {
        do {
            let report = try snapshots.housekeep(liveSessionIDs: ids)
            if !report.removed.isEmpty || report.temporaries > 0 {
                Logger(subsystem: "se.tkz.tkzmux", category: "app")
                    .info("snapshot housekeeping: removed \(report.removed.count) orphaned, \(report.temporaries) temp files, \(report.reclaimedBytes) bytes")
            }
        } catch {
            Logger(subsystem: "se.tkz.tkzmux", category: "app")
                .error("snapshot housekeeping failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The shim installer for the real app, or nil when its resources cannot be found (a build
    /// with no `tkzmux-hook` next to the executable): the app still runs, hooks are just absent.
    static func makeShimInstaller(directory: URL) -> ShimInstaller? {
        let hook = ShimInstaller.standardHookBinary()
        guard FileManager.default.isExecutableFile(atPath: hook.path) else {
            Logger(subsystem: "se.tkz.tkzmux", category: "app")
                .warning("tkzmux-hook not found at \(hook.path, privacy: .public); shell integration disabled")
            return nil
        }
        do {
            return ShimInstaller(directory: directory, hookBinary: hook, resources: try ShimResources.bundled())
        } catch {
            Logger(subsystem: "se.tkz.tkzmux", category: "app")
                .error("shim resources unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    struct RestoredState {
        var state: AppState
        /// `nil` under `TKZMUX_FIXTURE`, where nothing is loaded and nothing may be saved.
        var loaded: LoadResult?
        var warnings: [String] = []
    }

    /// The state the main window starts from: `state.json` merged over one group for the home
    /// directory (M5.1 / TKZ-29). A missing or empty file leaves the startup group in place, so a
    /// first run and a run after a wiped state file look the same.
    ///
    /// `TKZMUX_FIXTURE` neither loads nor saves. Merging 40 fabricated, deliberately unlaunchable
    /// rows into the user's real groups — and then persisting them — would be worse than having no
    /// persistence at all in that mode.
    static func restoreState() -> RestoredState {
        guard !wantsFixture else { return RestoredState(state: .fixture, loaded: nil) }
        var state = AppState.startup(homeDirectory: NSHomeDirectory())
        let loaded = stateFile.load()
        let warnings = loaded.document?.state.apply(to: &state) ?? []
        return RestoredState(state: state, loaded: loaded, warnings: warnings)
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
