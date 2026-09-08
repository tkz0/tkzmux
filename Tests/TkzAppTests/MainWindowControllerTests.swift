// MainWindowControllerTests — M2.2 (TKZ-18), the assembled window.
//
// Everything here runs in a real `NSWindow` that is **never ordered front**: the window is created
// by the controller, laid out, and asserted on. That is the only way to check the split view's
// geometry — `minimumThickness` alone tells you nothing about the width the sidebar actually got.
//
// The terminal half is a spy: `SpyTerminalHost` records `show(_:)` calls, and the surface is a
// plain focusable `NSView` instead of a `TerminalMetalView`. Two reasons: a real
// `TerminalViewHost` writes `.ghsnap` files into `~/Library/Application Support/tkzmux` (shared
// agent brief, hard rule 8), and "show was called with this id" is not observable on the real host
// when no session has been opened. `UserDefaults` is likewise a throwaway suite.
//
// AppKit is `@MainActor` and the store delivers on the main queue, so the suite is serialised.

import AppKit
import Foundation
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct MainWindowControllerTests {

    // MARK: - Doubles

    /// Records what the window asked of the terminal half.
    @MainActor
    final class SpyTerminalHost: TerminalHost {
        private(set) var shown: [SessionID?] = []
        private(set) var closed: [SessionID] = []
        let events: AsyncStream<(SessionID, TerminalEvent)>
        private let continuation: AsyncStream<(SessionID, TerminalEvent)>.Continuation

        init() {
            var escapee: AsyncStream<(SessionID, TerminalEvent)>.Continuation!
            events = AsyncStream { escapee = $0 }
            continuation = escapee
        }

        func open(_ id: SessionID, cwd: String, env: [String: String], size: TerminalSize) throws -> pid_t { 0 }
        func run(_ id: SessionID, command: String) {}
        func show(_ id: SessionID?) { shown.append(id) }
        func resize(_ id: SessionID, _ size: TerminalSize) {}
        func close(_ id: SessionID, signal: Int32) { closed.append(id) }
        func snapshot(_ id: SessionID) throws -> Data { Data() }
        func restore(_ id: SessionID, from: Data, cwd: String, env: [String: String]) throws -> pid_t { 0 }

        var lastShown: SessionID?? { shown.last }
    }

    /// Stands in for `TerminalMetalView`: focusable, layer-backed, nothing else.
    final class FakeTerminalView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    // MARK: - Harness

    @MainActor
    struct Harness {
        let store: AppStore
        let controller: MainWindowController
        let host: SpyTerminalHost
        let terminalView: FakeTerminalView
        let defaults: UserDefaults
        let suiteName: String

        var window: NSWindow { controller.window }
        var sidebarItem: NSSplitViewItem { controller.splitViewController.splitViewItems[0] }

        /// Applies a store mutation and delivers its change set synchronously.
        func mutate(_ body: (inout AppState) -> Void) {
            store.update(body)
            store.flush()
            layout()
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func tearDown() {
            controller.shutdown()
            defaults.removePersistentDomain(forName: suiteName)
            window.orderOut(nil)
        }
    }

    static func makeHarness(_ state: AppState = .fixture) -> Harness {
        _ = NSApplication.shared
        let suiteName = "tkzmux.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = AppStore(state: state)
        let host = SpyTerminalHost()
        let view = FakeTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let controller = MainWindowController(
            store: store, host: host, terminalView: view, theme: .default, defaults: defaults)
        let harness = Harness(
            store: store, controller: controller, host: host, terminalView: view,
            defaults: defaults, suiteName: suiteName)
        harness.layout()
        return harness
    }

    // MARK: - Structure

    @Test("The window is a split view: sidebar 300 pt, min 240, collapsible")
    func splitGeometry() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        #expect(harness.controller.splitViewController.splitViewItems.count == 2)
        let sidebar = harness.sidebarItem
        #expect(sidebar.canCollapse)
        #expect(sidebar.minimumThickness == 240)
        #expect(sidebar.viewController === harness.controller.sidebar)
        // The real, laid-out width — not the constant it was asked for.
        #expect(abs(sidebar.viewController.view.frame.width - 300) < 1)
        #expect(harness.controller.splitViewController.splitViewItems[1].canCollapse == false)
    }

    @Test("The status bar is pinned along the bottom at exactly 30 pt")
    func statusBarHeight() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        let bar = harness.controller.statusBar
        #expect(bar.frame.height == 30)
        #expect(StatusBarView.height == 30)
        // Bottom of the detail half, full width.
        let detail = harness.controller.detail.view
        #expect(bar.superview === detail)
        #expect(abs(bar.frame.minY - 0) < 0.5)
        #expect(abs(bar.frame.width - detail.frame.width) < 0.5)
        // And the terminal sits directly on top of it.
        #expect(abs(harness.controller.detail.terminalContainer.frame.minY - bar.frame.maxY) < 0.5)
    }

    @Test("The window wears the unified toolbar with no title")
    func toolbarAttached() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        #expect(harness.window.toolbar === harness.controller.toolbarController.toolbar)
        #expect(harness.window.toolbarStyle == .unified)
        #expect(harness.window.titleVisibility == .hidden)
        #expect(harness.window.titlebarAppearsTransparent)
        #expect(harness.window.styleMask.contains(.fullSizeContentView))
        // A dark preset must put the window in `.darkAqua`, or the sidebar's visual-effect
        // backing and the toolbar come up light behind dark rows.
        #expect(harness.window.appearance?.name == .darkAqua)
    }

    @Test("The toolbar title follows the selection")
    func toolbarTitle() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        let session = harness.store.state.selectedSession
        let group = session.flatMap { harness.store.state.groups[$0.groupID] }
        #expect(harness.controller.toolbarController.plainTitle
            == "\(session?.displayTitle ?? "") \u{2014} \(group?.name ?? "")")

        harness.mutate { $0.select(nil) }
        #expect(harness.controller.toolbarController.plainTitle == "No session")
    }

    @Test("The sidebar stays dark inside the system's glass wrapper")
    func sidebarAppearance() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        // macOS 26 wraps a `sidebarWithViewController:` item in an
        // `NSContainerConcentricGlassEffectView` (and insets it by 8 pt). Two things have to
        // survive that: the window's dark appearance must reach the sidebar as *vibrant dark* —
        // otherwise the glass is milk-white behind dark rows — and the container's own themed
        // background must not be replaced by the effect view's.
        let container = harness.controller.sidebar.view
        #expect(container.effectiveAppearance.name == .vibrantDark)
        let background = try #require(container.layer?.backgroundColor)
        let expected = Theme.default.sidebarBackground
        let components = try #require(background.components)
        #expect(abs(components[0] - expected.r) < 0.01)
        #expect(abs(components[1] - expected.g) < 0.01)
        #expect(abs(components[2] - expected.b) < 0.01)
    }

    // MARK: - Sidebar collapse (⌘B)

    @Test("Toggling the sidebar collapses it and round-trips through the store")
    func toggleSidebar() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        #expect(harness.store.state.sidebarVisible)
        #expect(harness.sidebarItem.isCollapsed == false)

        harness.controller.toggleSidebar()
        harness.store.flush()
        harness.layout()
        #expect(harness.store.state.sidebarVisible == false)
        #expect(harness.sidebarItem.isCollapsed)

        harness.controller.toggleSidebar()
        harness.store.flush()
        harness.layout()
        #expect(harness.store.state.sidebarVisible)
        #expect(harness.sidebarItem.isCollapsed == false)
        #expect(abs(harness.sidebarItem.viewController.view.frame.width - 300) < 1)
    }

    @Test("A store-driven visibility change reaches the split item")
    func storeDrivesCollapse() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.mutate { $0.setSidebarVisible(false) }
        #expect(harness.sidebarItem.isCollapsed)
        harness.mutate { $0.setSidebarVisible(true) }
        #expect(harness.sidebarItem.isCollapsed == false)
    }

    @Test("A divider drag that collapses the sidebar is reported back to the store")
    func dragCollapseReachesStore() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        // Collapse the item directly, as a drag would, and let the split view report.
        harness.sidebarItem.isCollapsed = true
        harness.controller.splitViewController.splitViewDidResizeSubviews(
            Notification(name: NSSplitView.didResizeSubviewsNotification,
                         object: harness.controller.splitViewController.splitView))
        harness.store.flush()
        #expect(harness.store.state.sidebarVisible == false)
    }

    // MARK: - Selection drives the terminal

    @Test("Selecting a session shows it and gives the terminal the keyboard")
    func selectionShowsAndFocuses() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        let target = try #require(harness.store.state.orderedSessions.last?.id)
        harness.mutate { $0.select(target) }

        #expect(harness.host.lastShown == .some(target))
        #expect(harness.window.firstResponder === harness.terminalView)
        #expect(harness.terminalView.isHidden == false)
    }

    @Test("Sidebar selection is the same path: it goes through the store to show()")
    func sidebarSelectionShows() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        // Start from nothing selected, so the ⌘1 below is a real change and not a no-op.
        harness.mutate { $0.select(nil) }
        let expected = try #require(SidebarRowAdapter.session(atVisibleIndex: 1, in: harness.store.state))

        // ⌘1 — the sidebar's own command, exactly what the menu dispatches.
        harness.controller.dispatcher.perform(.selectSession(1))
        harness.store.flush()
        harness.layout()

        #expect(harness.store.state.selection == expected)
        #expect(harness.host.lastShown == .some(expected))
        #expect(harness.window.firstResponder === harness.terminalView)
    }

    @Test("Empty state appears when nothing is selected and disappears when something is")
    func emptyState() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        #expect(harness.controller.detail.emptyState.isHidden)

        harness.mutate { $0.select(nil) }
        #expect(harness.controller.detail.emptyState.isHidden == false)
        #expect(harness.terminalView.isHidden)
        #expect(harness.host.lastShown == .some(nil))
        #expect(EmptyStateView.message == "No session selected \u{00B7} \u{2318}N")

        let target = try #require(harness.store.state.orderedSessions.first?.id)
        harness.mutate { $0.select(target) }
        #expect(harness.controller.detail.emptyState.isHidden)
        #expect(harness.terminalView.isHidden == false)
    }

    // MARK: - Status bar contents

    @Test("The status bar is derived from the selected session")
    func statusModel() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        let session = try #require(harness.store.state.selectedSession)
        let model = harness.controller.statusBar.model
        #expect(model.branch == session.live?.git?.branch)
        #expect(model.diffAdded == session.live?.git?.insertions)
        #expect(model.diffFiles == session.live?.git?.changedFiles)

        harness.mutate { $0.select(nil) }
        #expect(harness.controller.statusBar.model == .empty)
    }

    @Test("A git refresh on the selected session re-renders the strip")
    func statusFollowsSessionChange() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        let id = try #require(harness.store.state.selection)
        harness.mutate { state in
            state.updateLive(id) { $0.git = GitSummary(branch: "tkz-18", insertions: 5, deletions: 1) }
        }
        #expect(harness.controller.statusBar.model.branch == "tkz-18")
        #expect(harness.controller.statusBar.model.diffAdded == 5)
    }

    // MARK: - Chrome persistence

    @Test("Window frame and sidebar visibility survive a save/restore round-trip")
    func chromeRoundTrip() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.mutate { state in
            state.windowFrame = NSRect(x: 120, y: 90, width: 1000, height: 700)
            state.setSidebarVisible(false)
        }
        harness.controller.saveChrome()

        // What the store ended up with is the truth: AppKit constrains a window to the screen it
        // lands on, and `windowDidResize` writes the constrained frame back. The round trip is
        // "whatever the window really has comes back", not "whatever we asked for".
        var restored = AppState.fixture
        MainWindowController.restoreChrome(into: &restored, from: harness.defaults)
        #expect(restored.windowFrame != nil)
        #expect(restored.windowFrame == harness.store.state.windowFrame)
        #expect(restored.windowFrame == harness.window.frame)
        #expect(restored.sidebarVisible == false)
    }

    @Test("ChromeDefaults round-trips an arbitrary frame with no window involved")
    func chromeDefaultsRoundTrip() {
        let suiteName = "tkzmux.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var saved = AppState()
        saved.windowFrame = NSRect(x: 120, y: 90, width: 1100, height: 760)
        saved.setSidebarVisible(false)
        ChromeDefaults.save(saved, to: defaults)

        var restored = AppState()
        ChromeDefaults.load(into: &restored, from: defaults)
        #expect(restored.windowFrame == saved.windowFrame)
        #expect(restored.sidebarVisible == false)

        // A nil frame clears the key rather than writing a zero rect.
        saved.windowFrame = nil
        ChromeDefaults.save(saved, to: defaults)
        var cleared = AppState()
        ChromeDefaults.load(into: &cleared, from: defaults)
        #expect(cleared.windowFrame == nil)
    }

    @Test("A stored frame places the window at launch")
    func frameAppliedAtLaunch() {
        var state = AppState.fixture
        state.windowFrame = NSRect(x: 60, y: 40, width: 1000, height: 700)
        let harness = Self.makeHarness(state)
        defer { harness.tearDown() }

        #expect(harness.window.frame.size == NSSize(width: 1000, height: 700))
    }

    @Test("Unparsable defaults leave the state alone")
    func chromeGarbage() {
        let suiteName = "tkzmux.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not a rect", forKey: ChromeDefaults.frameKey)

        var state = AppState()
        MainWindowController.restoreChrome(into: &state, from: defaults)
        #expect(state.windowFrame == nil)
        #expect(state.sidebarVisible)
    }

    // MARK: - Rendering

    @Test("The assembled window rasterises offscreen")
    func rendersOffscreen() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        harness.layout()

        let root = try #require(harness.window.contentView)
        root.wantsLayer = true
        let bounds = root.bounds
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let ctx = graphics.cgContext
        ctx.scaleBy(x: scale, y: scale)
        try #require(root.layer).render(in: ctx)

        // What the picture can and cannot show: the status strip and the window/terminal grounds
        // are real, the sidebar column is **not**. `NSSplitViewItem(sidebarWithViewController:)`
        // wraps the sidebar in an `NSVisualEffectView`, which has no offscreen content — it paints
        // a flat fallback and the rows' layers are not in the captured tree at all (design.md →
        // *Testing without UI*). `SidebarViewControllerTests.sidebarRendersOffscreen` is where the
        // rows themselves are proved to draw; rendering that layer *into this context* only
        // repaints the whole canvas, so it is deliberately not done here.

        let data = try #require(rep.bitmapData)
        var distinct = Set<UInt32>()
        let pixels = rep.pixelsWide * rep.pixelsHigh
        for index in stride(from: 0, to: pixels * 4, by: 4 * 37) {
            let value = UInt32(data[index]) << 16 | UInt32(data[index + 1]) << 8 | UInt32(data[index + 2])
            distinct.insert(value)
        }
        #expect(distinct.count > 4)

        if let png = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tkzmux-mainwindow-\(UUID().uuidString).png")
            try? png.write(to: url)
            print("main window render: \(url.path)")
        }
    }

    @Test("The diagnostics line names the frame, the sidebar and the selection")
    func diagnostics() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let line = harness.controller.diagnosticsLine()
        #expect(line.hasPrefix("main window: frame="))
        #expect(line.contains("sidebar=visible"))
        #expect(line.contains("sessions=\(harness.store.state.sessions.count)"))
    }

}
