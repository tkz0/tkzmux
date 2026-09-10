// StartupOverlayTests — the "Starting Claude…" overlay: its timing policy, its view, and the
// chrome that hosts it.
//
// `StartupOverlayPolicy` carries no clock, so nothing here sleeps: phases are asked for with two
// dates. The view is asserted structurally — hidden flags, layer strings, the animation key —
// with no window, the `PaneHeaderViewTests` way.

import AppKit
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct StartupOverlayTests {

    static let startedAt = Date(timeIntervalSince1970: 1_788_944_400)

    // MARK: Policy (pure)

    @Test("Before the delay: pending, with the moment to look again")
    func pendingBeforeTheDelay() {
        let start = Self.startedAt
        #expect(
            StartupOverlayPolicy.phase(startedAt: start, now: start)
                == .pending(showAt: start.addingTimeInterval(StartupOverlayPolicy.showDelay)))
        #expect(
            StartupOverlayPolicy.phase(startedAt: start, now: start.addingTimeInterval(1.999))
                == .pending(showAt: start.addingTimeInterval(StartupOverlayPolicy.showDelay)))
    }

    @Test("At the delay and until the give-up: visible, with the moment it expires")
    func visibleAfterTheDelay() {
        let start = Self.startedAt
        let expires = start.addingTimeInterval(StartupOverlayPolicy.giveUp)
        #expect(
            StartupOverlayPolicy.phase(
                startedAt: start, now: start.addingTimeInterval(StartupOverlayPolicy.showDelay))
                == .visible(expiresAt: expires))
        #expect(
            StartupOverlayPolicy.phase(startedAt: start, now: start.addingTimeInterval(60))
                == .visible(expiresAt: expires))
        #expect(
            StartupOverlayPolicy.phase(
                startedAt: start, now: start.addingTimeInterval(StartupOverlayPolicy.giveUp - 0.001))
                == .visible(expiresAt: expires))
    }

    @Test("At the give-up and after: expired")
    func expiredAtTheGiveUp() {
        let start = Self.startedAt
        #expect(
            StartupOverlayPolicy.phase(
                startedAt: start, now: start.addingTimeInterval(StartupOverlayPolicy.giveUp))
                == .expired)
        #expect(
            StartupOverlayPolicy.phase(startedAt: start, now: start.addingTimeInterval(3600))
                == .expired)
    }

    @Test("The delay is the two seconds that were asked for")
    func theDelayIsTwoSeconds() {
        #expect(StartupOverlayPolicy.showDelay == 2)
        #expect(StartupOverlayPolicy.giveUp > StartupOverlayPolicy.showDelay)
    }

    // MARK: View (structural)

    @Test("Hidden, unanimated and untouchable until shown")
    func hiddenByDefault() {
        let view = PaneStartupOverlayView(theme: .default)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        #expect(view.isHidden)
        #expect(!view.isShowing)
        #expect(!view.isSpinning)
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test("Showing sets the copy, the caption and one spin; hiding removes the spin")
    func showAndHide() {
        let view = PaneStartupOverlayView(theme: .default)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.show(PaneStartupModel(command: "claude -w feature"), theme: .default)
        view.layout()
        #expect(!view.isHidden)
        #expect(view.isShowing)
        #expect(view.isSpinning)
        #expect(view.titleText == "Starting Claude\u{2026}")
        #expect(view.captionText == "claude -w feature")
        // The same model again must not stack a second animation — and cannot, since the key is
        // fixed; what is asserted is that the view does not remove and re-add it either.
        view.show(PaneStartupModel(command: "claude -w feature"), theme: .default)
        #expect(view.isSpinning)

        view.hide()
        #expect(view.isHidden)
        #expect(!view.isShowing)
        #expect(!view.isSpinning)
        // Hiding twice is a no-op.
        view.hide()
        #expect(view.isHidden)
    }

    @Test("Showing after a hide spins again")
    func reshow() {
        let view = PaneStartupOverlayView(theme: .default)
        view.show(PaneStartupModel(command: "claude"), theme: .default)
        view.hide()
        view.show(PaneStartupModel(command: "claude"), theme: .default)
        #expect(view.isSpinning)
        #expect(!view.isHidden)
    }

    // MARK: Chrome

    @Test("The overlay covers exactly the terminal, under the header when there is one")
    func chromeFramesTheOverlayToTheContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let chrome = PaneChromeView(content: content, theme: .default)
        chrome.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        chrome.layout()
        #expect(chrome.startupOverlay.frame == content.frame)
        #expect(chrome.startupOverlay.frame == NSRect(x: 0, y: 0, width: 600, height: 400))

        chrome.setHeaderVisible(true)
        chrome.layout()
        #expect(chrome.startupOverlay.frame == content.frame)
        #expect(chrome.startupOverlay.frame.minY == PaneHeaderMetrics.height)

        // Above the terminal in the subview order: what the split container arranges is the
        // chrome, and the overlay must composite over its content.
        let order = chrome.subviews.map { ObjectIdentifier($0) }
        let contentIndex = order.firstIndex(of: ObjectIdentifier(content))
        let overlayIndex = order.firstIndex(of: ObjectIdentifier(chrome.startupOverlay))
        #expect(contentIndex != nil && overlayIndex != nil && contentIndex! < overlayIndex!)
    }

    @Test("setStartup shows for a model and hides for nil; focus dimming never touches it")
    func chromeSetStartup() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let chrome = PaneChromeView(content: content, theme: .default)
        chrome.setStartup(PaneStartupModel(command: "claude"))
        #expect(chrome.isShowingStartup)
        #expect(chrome.startupOverlay.captionText == "claude")

        chrome.setHeaderVisible(true)
        chrome.setFocused(false)
        #expect(content.alphaValue == PaneHeaderMetrics.inactiveContentAlpha)
        #expect(chrome.startupOverlay.alphaValue == 1)

        chrome.setStartup(nil)
        #expect(!chrome.isShowingStartup)
        #expect(chrome.startupOverlay.isHidden)
    }
}
