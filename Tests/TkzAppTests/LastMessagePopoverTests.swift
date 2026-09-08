// LastMessagePopoverTests — M3.4 (TKZ-24).
//
// `NSPopover.show(relativeTo:of:)` needs the anchor view attached to a real window (an unattached
// view has no window server connection to anchor against), so — like `SidebarViewControllerTests` —
// these put the anchor in an offscreen, never-ordered-front `NSWindow`. Nothing here is rasterised;
// the assertions are all `isShown` / `close()` and the provider plumbing.

import AppKit
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct LastMessagePopoverTests {
    static func makeAnchor() -> (window: NSWindow, view: NSView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        window.contentView = view
        window.layoutIfNeeded()
        // `NSPopover.show` needs the anchor attached to a window with a live window-server
        // connection; a never-ordered window leaves `isShown` permanently false. Far off the visible
        // screen area keeps it out of the way without needing `.borderless` alone to carry it.
        window.orderFront(nil)
        return (window, view)
    }

    @Test func showsAndClosesHeadlessly() {
        let (_, anchor) = Self.makeAnchor()
        let popover = LastMessagePopover(theme: .default)
        #expect(popover.isShown == false)
        popover.show(message: "Done — the failing test now passes.", relativeTo: anchor.bounds, of: anchor)
        #expect(popover.isShown == true)
        popover.close()
        #expect(popover.isShown == false)
    }

    @Test func emptyMessageShowsNothing() {
        let (_, anchor) = Self.makeAnchor()
        let popover = LastMessagePopover(theme: .default)
        popover.show(message: "", relativeTo: anchor.bounds, of: anchor)
        #expect(popover.isShown == false)
    }

    @Test func repeatedShowsDoNotLeaveTheHiddenStateOn() {
        let (_, anchor) = Self.makeAnchor()
        let popover = LastMessagePopover(theme: .default)
        popover.show(message: "first", relativeTo: anchor.bounds, of: anchor)
        popover.show(message: "second", relativeTo: anchor.bounds, of: anchor)
        #expect(popover.isShown == true)
        popover.close()
    }

    // MARK: - The sidebar's default provider

    static func harness(_ state: AppState) -> (controller: SidebarViewController, window: NSWindow) {
        _ = NSApplication.shared
        let store = AppStore(state: state)
        let controller = SidebarViewController(store: store, theme: .default)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SidebarMetrics.sidebarWidth, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.frame = window.contentLayoutRect
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        // `NSPopover.show` needs a live window-server connection to actually show — see
        // `makeAnchor()` above.
        window.orderFront(nil)
        return (controller, window)
    }

    @Test func defaultProviderReturnsTheSessionsLastStopMessage() {
        var state = AppState.fixture
        // Session 1 is the fixture's `waiting(.doneUnattended)` row, with a 4 KiB-capped message.
        let id = Fixture.sessionID(1)
        let message = String(repeating: "x", count: 4096)
        state.sessions[id]?.live?.lastStopMessage = message
        let (controller, _) = Self.harness(state)
        #expect(controller.lastMessageProvider == nil)
        #expect(controller.lastMessagePopover.isShown == false)
        controller.showLastMessage(for: id)
        #expect(controller.lastMessagePopover.isShown == true)
    }

    @Test func customProviderOverridesTheDefault() {
        let state = AppState.fixture
        let id = Fixture.sessionID(1)
        let (controller, _) = Self.harness(state)
        var seen: SessionID?
        controller.lastMessageProvider = { requested in
            seen = requested
            return "overridden"
        }
        controller.showLastMessage(for: id)
        #expect(seen == id)
        #expect(controller.lastMessagePopover.isShown == true)
    }

    @Test func emptyLastMessageShowsNothingViaTheController() {
        var state = AppState.fixture
        let id = Fixture.sessionID(1)
        state.sessions[id]?.live?.lastStopMessage = ""
        let (controller, _) = Self.harness(state)
        controller.showLastMessage(for: id)
        #expect(controller.lastMessagePopover.isShown == false)
    }

    // MARK: - SessionRowView's click routing

    /// A click on the status dot is handled by `onStatusDotClick`, and only that; a click
    /// elsewhere on the row must fall through to `NSTableView`'s own selection handling — so
    /// `onStatusDotClick` must not fire, and the event must reach `super.mouseDown`.
    @Test func clickOnTheDotFiresTheHandlerAndClickElsewhereFallsThrough() {
        let row = SessionRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        row.configure(SidebarSessionRowModel(title: "t", status: .waiting), theme: .default)

        var handledCount = 0
        row.onStatusDotClick = { handledCount += 1; return true }

        func click(at point: NSPoint) {
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            row.mouseDown(with: event)
        }

        // `NSEvent.locationInWindow` is `mouseDown`'s window-space input; `row` has no window here,
        // so `convert(_:from: nil)` treats it as already in the view's own coordinate space —
        // exactly the dot's centre.
        click(at: NSPoint(x: row.statusDot.frame.midX, y: row.statusDot.frame.midY))
        #expect(handledCount == 1)

        // Well clear of the dot's hit-test slop, over the title text.
        click(at: NSPoint(x: 120, y: 30))
        #expect(handledCount == 1)  // unchanged — this click fell through instead
    }

    @Test func onStatusDotClickReturningFalseAlsoFallsThrough() {
        let row = SessionRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        row.configure(SidebarSessionRowModel(title: "t", status: .idle), theme: .default)
        var handledCount = 0
        row.onStatusDotClick = { handledCount += 1; return false }
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: row.statusDot.frame.midX, y: row.statusDot.frame.midY),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
        row.mouseDown(with: event)  // must not crash falling through with no window/table
        #expect(handledCount == 1)
    }
}
