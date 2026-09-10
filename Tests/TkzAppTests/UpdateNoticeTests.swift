// UpdateNoticeTests — the card itself, and the sidebar showing it (TKZ-50).
//
// Three layers, bottom up: `SidebarRowAdapter.updateNotice(for:)` words the card per phase;
// `UpdateNoticeView` rasterises it headlessly on every preset (the same bitmap harness as
// `SidebarRowViewTests`); `SidebarViewController` shows it, moves the list up by exactly its
// height, and hides it again on `✕` — which is a store write, so it survives a relaunch.

import AppKit
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct UpdateNoticeTests {
    static let update = AvailableUpdate(version: "9.9.9", releaseURL: "https://github.com/tkz0/tkzmux/releases/tag/v9.9.9")

    static func state(phase: UpgradePhase = .idle, capable: Bool = true, dismissed: String? = nil) -> AppState {
        var state = AppState()
        state.setAvailableUpdate(update)
        state.setUpgradePhase(phase)
        state.setCanUpgradeInPlace(capable)
        if let dismissed { state.dismissUpdate(version: dismissed) }
        return state
    }

    // MARK: Adapter

    @Test("No release, or a dismissed one, means no card")
    func hiddenCases() {
        #expect(SidebarRowAdapter.updateNotice(for: AppState()) == nil)
        #expect(SidebarRowAdapter.updateNotice(for: Self.state(dismissed: "9.9.9")) == nil)
        #expect(SidebarRowAdapter.updateNotice(for: Self.state(dismissed: "9.9.8")) != nil)
    }

    @Test("Wording per phase; the release link is always there; brew only when capable")
    func wording() throws {
        let idle = try #require(SidebarRowAdapter.updateNotice(for: Self.state()))
        #expect(idle.title == "Update available \u{2014} v9.9.9")
        #expect(idle.runs.map(\.action) == [.upgrade, .openReleasePage])
        #expect(idle.showsClose)

        let linkOnly = try #require(SidebarRowAdapter.updateNotice(for: Self.state(capable: false)))
        #expect(linkOnly.runs.map(\.action) == [.openReleasePage])

        let running = try #require(SidebarRowAdapter.updateNotice(for: Self.state(phase: .running(step: "upgrade"))))
        #expect(running.title == "Updating to v9.9.9\u{2026}")
        #expect(running.runs.map(\.text) == ["Running brew upgrade"])
        #expect(running.runs.map(\.action) == [nil])
        #expect(!running.showsClose)

        let ready = try #require(SidebarRowAdapter.updateNotice(for: Self.state(phase: .restartReady(installed: "9.9.9"))))
        #expect(ready.title == "Update installed \u{2014} v9.9.9")
        #expect(ready.runs.map(\.action) == [.restart, .openReleasePage])
        #expect(ready.runs.first?.text == "Restart to update")
        // The bundle is already swapped: there is nothing to dismiss, only a restart to do.
        #expect(!ready.showsClose)

        let notYet = try #require(SidebarRowAdapter.updateNotice(for: Self.state(phase: .notInHomebrewYet)))
        #expect(notYet.runs.map(\.action) == [nil, .retry, .openReleasePage])

        let failed = try #require(SidebarRowAdapter.updateNotice(for: Self.state(phase: .failed(reason: "boom"))))
        #expect(failed.title == "Update failed")
        #expect(failed.runs.map(\.action) == [.showLog, .retry, .openReleasePage])
        // Every variant links to the release page.
        for model in [idle, linkOnly, ready, notYet, failed] {
            #expect(model.runs.contains { $0.action == .openReleasePage })
        }
    }

    // MARK: View

    static func makeView(_ model: UpdateNoticeModel, theme: Theme = .default, width: CGFloat = SidebarMetrics.sidebarWidth) -> UpdateNoticeView {
        let view = UpdateNoticeView(frame: NSRect(x: 0, y: 0, width: width, height: UpdateNoticeView.height))
        view.configure(model, theme: theme)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test("Every phase renders something on every preset, at 1x and 2x, deterministically")
    func rendersEverywhere() throws {
        let phases: [UpgradePhase] = [.idle, .running(step: "update"), .restartReady(installed: "9.9.9"), .notInHomebrewYet, .failed(reason: "x")]
        for theme in Theme.allPresets {
            for phase in phases {
                let model = try #require(SidebarRowAdapter.updateNotice(for: Self.state(phase: phase)))
                let view = Self.makeView(model, theme: theme)
                for scale in [CGFloat(1), 2] {
                    view.setContentsScale(scale)
                    let rep = try SidebarRowViewTests.render(view, scale: scale)
                    #expect(try SidebarRowViewTests.isNonBlank(rep), "\(theme.preset) \(phase) @\(scale)x")
                }
                let again = Self.makeView(model, theme: theme)
                view.setContentsScale(2)
                again.setContentsScale(2)
                #expect(try SidebarRowViewTests.pixels(SidebarRowViewTests.render(view, scale: 2))
                    == SidebarRowViewTests.pixels(SidebarRowViewTests.render(again, scale: 2)))
            }
        }
    }

    @Test("One hit target per link, the ✕ only when the model says so, tokens not literals")
    func hitTargetsAndTokens() throws {
        let idle = try #require(SidebarRowAdapter.updateNotice(for: Self.state()))
        let view = Self.makeView(idle)
        #expect(view.runHitButtons.count == 2)
        #expect(view.runTextLayers.count == 3)   // run · run
        #expect(!view.closeButton.isHidden)
        #expect(view.closeButtonFrame.width > 0)
        // Buttons sit over their run, inside the card, left to right.
        let frames = view.runHitButtons.map(\.frame)
        #expect(frames.allSatisfy { view.cardFrame.contains($0.insetBy(dx: 0, dy: 3)) })
        #expect(frames[0].maxX <= frames[1].minX)
        #expect(view.titleTextLayer.string as? String == idle.title)

        let running = try #require(SidebarRowAdapter.updateNotice(for: Self.state(phase: .running(step: "update"))))
        view.configure(running, theme: .default)
        view.layoutSubtreeIfNeeded()
        #expect(view.runHitButtons.isEmpty)
        #expect(view.closeButton.isHidden)

        // Title colour is the preset's foreground token, so 1b Light differs from 2c.
        let dark = Self.makeView(idle, theme: .midnightIndigo)
        let light = Self.makeView(idle, theme: .light)
        #expect(SidebarRowViewTests.approxEqual(
            SidebarRowViewTests.components(dark.titleTextLayer.foregroundColor),
            SidebarRowViewTests.components(Theme.midnightIndigo.foreground.cgColor)))
        #expect(!SidebarRowViewTests.approxEqual(
            SidebarRowViewTests.components(dark.titleTextLayer.foregroundColor),
            SidebarRowViewTests.components(light.titleTextLayer.foregroundColor)))
    }

    @Test("Clicks route: a link to onAction with its action, the ✕ to onDismiss")
    func clicks() throws {
        let failed = try #require(SidebarRowAdapter.updateNotice(for: Self.state(phase: .failed(reason: "x"))))
        let view = Self.makeView(failed)
        var actions: [UpdateAction] = []
        var dismissed = 0
        view.onAction = { actions.append($0) }
        view.onDismiss = { dismissed += 1 }
        for button in view.runHitButtons { button.performClick(nil) }
        view.closeButton.performClick(nil)
        #expect(actions == [.showLog, .retry, .openReleasePage])
        #expect(dismissed == 1)
    }

    @Test("At the minimum width the runs clip instead of overflowing the card")
    func narrow() throws {
        let notYet = try #require(SidebarRowAdapter.updateNotice(for: Self.state(phase: .notInHomebrewYet)))
        let view = Self.makeView(notYet, width: SidebarMetrics.sidebarMinWidth)
        let card = view.cardFrame
        for layer in view.runTextLayers where !layer.isHidden {
            #expect(layer.frame.maxX <= card.maxX + 0.5)
        }
        #expect(view.titleTextLayer.frame.maxX <= view.closeButtonFrame.minX)
    }

    // MARK: Sidebar

    @Test("The sidebar shows the card, moves the list up by its height, and hides it on ✕ for good")
    func sidebarShowsAndDismisses() throws {
        let harness = SidebarViewControllerTests.makeHarness()
        let notice = harness.controller.updateNoticeView
        let footer = harness.controller.newGroupFooter
        #expect(notice.isHidden)
        harness.window.layoutIfNeeded()
        let listBottomBefore = harness.controller.scrollView.frame.minY
        #expect(abs(listBottomBefore - footer.frame.maxY) < 0.5)

        harness.mutate { $0.setAvailableUpdate(Self.update) }
        harness.controller.view.layoutSubtreeIfNeeded()
        #expect(!notice.isHidden)
        #expect(abs(notice.frame.minY - footer.frame.maxY) < 0.5)
        #expect(abs(notice.frame.height - SidebarMetrics.updateNoticeHeight) < 0.5)
        #expect(abs(harness.controller.scrollView.frame.minY - (listBottomBefore + SidebarMetrics.updateNoticeHeight)) < 0.5)
        #expect(notice.currentModel.title == "Update available \u{2014} v9.9.9")
        // No row was touched for it.
        harness.outline.resetCounters()

        // A phase change re-words the card in place.
        harness.mutate { $0.setUpgradePhase(.failed(reason: "x")) }
        #expect(notice.currentModel.title == "Update failed")
        #expect(harness.outline.reloadedRowCount == 0)

        // ✕ while failed: a store write, the card goes, the list comes back down — and the failed
        // phase goes with it, so the next release's card does not start out saying "failed".
        notice.onDismiss?()
        harness.store.flush()
        harness.controller.view.layoutSubtreeIfNeeded()
        #expect(notice.isHidden)
        #expect(harness.store.state.dismissedUpdateVersion == "9.9.9")
        #expect(harness.store.state.update.phase == .idle)
        #expect(abs(harness.controller.scrollView.frame.minY - listBottomBefore) < 0.5)

        // The same version again stays hidden; a newer one shows.
        harness.mutate { $0.setAvailableUpdate(Self.update) }
        #expect(notice.isHidden)
        harness.mutate { $0.setAvailableUpdate(AvailableUpdate(version: "9.9.10", releaseURL: "x")) }
        #expect(!notice.isHidden)
        #expect(notice.currentModel.title == "Update available \u{2014} v9.9.10")
    }

    @Test("Card links reach the assembler through onUpdateAction")
    func actionRouting() {
        let harness = SidebarViewControllerTests.makeHarness()
        var received: [UpdateAction] = []
        harness.controller.onUpdateAction = { received.append($0) }
        harness.mutate { $0.setAvailableUpdate(Self.update); $0.setCanUpgradeInPlace(true) }
        let notice = harness.controller.updateNoticeView
        for button in notice.runHitButtons { button.performClick(nil) }
        #expect(received == [.upgrade, .openReleasePage])
    }
}
