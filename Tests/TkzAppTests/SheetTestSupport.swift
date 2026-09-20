// SheetTestSupport — the two helpers every floating-sheet suite needs, and the reason for one of
// them, in the one place both suites can point at.
//
// **Never `performClick` a button in these tests, and never let a panel reach the screen.**
//
// Until 2026-09-16 the rebase sheet's panels were ordered front for real and a `performClick` on
// one of their buttons ended the whole test run as "passed" mid-way: `NSButtonCell.performClick`
// spins `nextEventMatchingMask:` to show the pressed state of a *visible* button, that first
// request for events starts HIToolbox's event-pulling thread, and from then on every incoming
// event wakes the main thread with `CFRunLoopStop(main)`. Harmless under `NSApplication.run`, but
// the test process's main run loop is `CFRunLoopRun()` inside Swift's async-main drain, which
// calls `exit(0)` the moment that loop stops — no summary line, and every test scheduled after
// that point silently never runs.
//
// So: every sheet suite stubs `orderFront` to `{ _ in }`, sets `dismissesWhenResigningKey = false`
// (suites run in parallel, and another panel taking key would correctly dismiss this one), and
// presses buttons with `click` below. This lived as a comment on `RebaseSheetControllerTests`
// until TKZ-70 added a second family of sheets; two copies of the trick is how the third one gets
// it wrong.

import AppKit
import Testing

@MainActor
enum SheetTestSupport {

    /// The button's action, without the event-loop spin `performClick` does for a visible window.
    static func click(_ button: NSButton) {
        _ = NSApp.sendAction(button.action!, to: button.target, from: button)
    }

    /// Polls up to `timeout` for a background hop (a fetch, a survey) to land. Returns as soon as
    /// the predicate holds, so the happy path costs milliseconds.
    static func settle(_ timeout: Duration = .seconds(2), _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
