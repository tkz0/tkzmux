// AppDelegate — M1.6 (TKZ-12) opens the development terminal window; M2.2 replaces it with
// MainWindowController (sidebar + status bar + the real TerminalHost).

import AppKit
import Foundation
import TkzCore
import TkzTerminalView
import os

/// Application delegate.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var renderContext: TerminalRenderContext?
    private var devWindow: DevWindowController?
    private var fallbackWindow: NSWindow?
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "app")

    /// Milliseconds after launch to print engine diagnostics and quit. Development only: it is how
    /// `swift run tkzmux` can be driven headlessly enough to prove that a window opened, a session
    /// spawned and frames were encoded.
    private static let autoQuitKey = "TKZMUX_DEV_AUTOQUIT_MS"

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let context = try TerminalRenderContext(theme: .default)
            let controller = DevWindowController(renderContext: context)
            renderContext = context
            devWindow = controller
            controller.showWindow()
        } catch {
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
                let line = self.devWindow?.diagnosticsLine() ?? "no dev window"
                FileHandle.standardError.write(Data("TKZMUX_DEV \(line)\n".utf8))
                NSApp.terminate(nil)
            }
        }
    }
}
