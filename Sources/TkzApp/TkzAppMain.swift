import AppKit

/// Entry point shared by the `tkzmux` executable. Works both inside the hand-built .app
/// (Info.plist present) and via `swift run tkzmux` (no bundle → explicit activation policy).
@MainActor
public enum TkzAppMain {
    private static var delegate: AppDelegate?

    public static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.activate()
        app.run()
        exit(0)
    }
}
