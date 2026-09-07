import AppKit

/// Application delegate. M0.1 opens one empty window; M2.2 replaces it with MainWindowController.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "tkzmux"
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
