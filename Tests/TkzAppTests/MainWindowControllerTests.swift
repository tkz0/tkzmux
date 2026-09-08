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
        struct Opened: Equatable {
            var id: SessionID
            var cwd: String
            var env: [String: String]
        }

        private(set) var shown: [SessionID?] = []
        private(set) var closed: [(id: SessionID, signal: Int32)] = []
        private(set) var opened: [Opened] = []
        private(set) var ran: [(id: SessionID, command: String)] = []
        /// Set to make the next `open` throw, so the failure path can be asserted.
        var openError: (any Error)?
        let events: AsyncStream<(SessionID, TerminalEvent)>
        private let continuation: AsyncStream<(SessionID, TerminalEvent)>.Continuation

        init() {
            var escapee: AsyncStream<(SessionID, TerminalEvent)>.Continuation!
            events = AsyncStream { escapee = $0 }
            continuation = escapee
        }

        func open(_ id: SessionID, cwd: String, env: [String: String], size: TerminalSize) throws -> pid_t {
            if let openError { throw openError }
            opened.append(Opened(id: id, cwd: cwd, env: env))
            return 4242
        }
        func run(_ id: SessionID, command: String) { ran.append((id, command)) }
        /// Records synchronously rather than inheriting the protocol's 2 s delayed default — the
        /// point of the assertion is *that the call arrives here at all* (a `runWhenReady` living
        /// only in a protocol extension would be statically dispatched on `any TerminalHost` and
        /// never reach a conformer's override).
        func runWhenReady(_ id: SessionID, command: String) { run(id, command: command) }
        private(set) var visibleSessionID: SessionID?
        func show(_ id: SessionID?) {
            shown.append(id)
            // The real host attaches nothing for an id it has never opened, which is what a row
            // restored from `state.json` looks like. The spy has to model that, or the window's
            // empty-state logic would be tested against a host that can show anything.
            visibleSessionID = id.flatMap { candidate in
                opened.contains { $0.id == candidate } ? candidate : nil
            }
        }
        func resize(_ id: SessionID, _ size: TerminalSize) {}
        func close(_ id: SessionID, signal: Int32) { closed.append((id, signal)) }
        func snapshot(_ id: SessionID) throws -> Data { Data() }
        func restore(_ id: SessionID, from: Data, cwd: String, env: [String: String]) throws -> pid_t { 0 }

        /// Pushes an event as if a child had produced it.
        func emit(_ event: TerminalEvent, for id: SessionID) { continuation.yield((id, event)) }

        var lastShown: SessionID?? { shown.last }
        var closedIDs: [SessionID] { closed.map(\.id) }
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
            window.orderOut(nil)
        }
    }

    static func makeHarness(_ state: AppState = .fixture) -> Harness {
        _ = NSApplication.shared
        let store = AppStore(state: state)
        let host = SpyTerminalHost()
        let view = FakeTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let controller = MainWindowController(
            store: store, host: host, terminalView: view, theme: .default)
        let harness = Harness(
            store: store, controller: controller, host: host, terminalView: view)
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
        // The real, laid-out **divider position** — not the constant it was asked for. With a
        // plain split item the sidebar view *is* the column, so the two agree at 300; the old
        // `sidebarWithViewController:` flavour put a glass container with an 8 pt inset between
        // them, which is exactly the rounded, inset sidebar artboard 2c does not draw.
        #expect(abs(harness.controller.sidebarWidthForRestore - 300) < 1)
        #expect(abs(sidebar.viewController.view.frame.width - 300) < 1)
        // AppKit still puts a plain `_NSSplitViewItemViewWrapper` between them; what must be gone
        // is the visual-effect container.
        var ancestor = sidebar.viewController.view.superview
        while let view = ancestor, view !== harness.controller.splitViewController.splitView {
            #expect(!(view is NSVisualEffectView), "no glass container between the split view and the sidebar")
            ancestor = view.superview
        }
        #expect(harness.controller.splitViewController.splitViewItems[1].canCollapse == false)
    }

    @Test("The terminal starts below the titlebar, not underneath it")
    func terminalRespectsTheSafeArea() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        harness.layout()
        let detail = harness.controller.detail

        // The content view stops at the titlebar — the window is not `.fullSizeContentView`, so
        // the titlebar keeps its own material (the glass behind the ＋ menu and the search field)
        // and the terminal fills the content from its top edge. The pin is still on the safe-area
        // guide, which is what kept the grid out from under the toolbar when the content *did*
        // extend up there (M2.5); today the guide coincides with the top edge.
        let contentHeight = harness.window.contentView?.frame.height ?? 0
        #expect(abs(harness.window.frame.height - contentHeight - 52) < 1,
                "titlebar + unified toolbar own their 52 pt; the content sits below them")
        #expect(detail.view.safeAreaInsets.top == 0)
        #expect(abs(detail.terminalContainer.frame.maxY - detail.view.bounds.height) < 1)
        // The empty state rides inside the container, so it is inset by construction.
        #expect(detail.emptyState.frame.height == detail.terminalContainer.frame.height)
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
        // The titlebar keeps its native material — that is the glass behind the toolbar items —
        // and draws the design's 1 pt bottom border. A transparent titlebar over full-size
        // content showed a flat strip of window background instead (reported 2026-09-08).
        #expect(harness.window.titlebarAppearsTransparent == false)
        #expect(harness.window.styleMask.contains(.fullSizeContentView) == false)
        #expect(harness.window.titlebarSeparatorStyle == .line)
        // A dark preset must put the window in `.darkAqua`, or the titlebar material and the
        // toolbar come up light over dark content.
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

    @Test("The sidebar is a flat themed column, not a glass wrapper")
    func sidebarAppearance() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        // Artboard 2c draws the sidebar as a flat column on `sidebarBackground` with a 1 pt border
        // against the terminal. A `sidebarWithViewController:` item on macOS 26 wrapped it in an
        // `NSContainerConcentricGlassEffectView` — rounded corners, an 8 pt inset and a vibrancy
        // backdrop (reported 2026-09-08). With a plain item the view inherits the window's dark
        // appearance directly and paints its own themed background.
        let container = harness.controller.sidebar.view
        #expect(container.effectiveAppearance.name == .darkAqua)
        #expect(!(container.superview is NSVisualEffectView))
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
        #expect(abs(harness.controller.sidebarWidthForRestore - 300) < 1)
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
        // The row has to have a terminal behind it: from M5.1 a row can exist in the store with no
        // surface (that is what a restored `state.json` row is), and the window shows the empty
        // state for those rather than focusing a grid that is not there.
        _ = try harness.host.open(
            target, cwd: "/tmp", env: [:], size: TerminalSize(rows: 24, cols: 80))
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
        _ = try harness.host.open(
            expected, cwd: "/tmp", env: [:], size: TerminalSize(rows: 24, cols: 80))

        // ⌘1 — the sidebar's own command, exactly what the menu dispatches.
        harness.controller.dispatcher.perform(.selectSession(1))
        harness.store.flush()
        harness.layout()

        #expect(harness.store.state.selection == expected)
        #expect(harness.host.lastShown == .some(expected))
        #expect(harness.window.firstResponder === harness.terminalView)
    }

    @Test("The empty state follows the host's surface, not the selection")
    func emptyState() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        // Every fixture row is selectable but has never been opened on the host — exactly the shape
        // of a row restored from `state.json` (M5.1). The detail half must say so rather than show
        // a blank grid.
        #expect(harness.controller.detail.emptyState.isHidden == false)
        #expect(harness.terminalView.isHidden)
        #expect(harness.controller.detail.emptyStateMessage == EmptyStateView.notRunningMessage)

        harness.mutate { $0.select(nil) }
        #expect(harness.controller.detail.emptyState.isHidden == false)
        #expect(harness.terminalView.isHidden)
        #expect(harness.host.lastShown == .some(nil))
        #expect(harness.controller.detail.emptyStateMessage == EmptyStateView.noSelectionMessage)
        #expect(EmptyStateView.noSelectionMessage == "No session selected \u{00B7} \u{2318}N")

        // A row the host has actually opened shows the terminal.
        let target = try #require(harness.store.state.orderedSessions.first?.id)
        _ = try harness.host.open(target, cwd: "/tmp", env: [:], size: TerminalSize(rows: 24, cols: 80))
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

    // MARK: - New group

    @Test("A chosen folder becomes a group named after it, rooted there, exactly once")
    func createGroupFromFolder() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let before = harness.store.state.groups.count

        let folder = URL(fileURLWithPath: "/tmp/tkzmux-tests/Some Repo", isDirectory: true)
        let id = try #require(harness.controller.createGroup(from: folder))
        let group = try #require(harness.store.state.groups[id])
        #expect(group.name == "Some Repo")
        #expect(group.repoRoot == "/tmp/tkzmux-tests/Some Repo")
        #expect(harness.store.state.groups.count == before + 1)

        // The same folder again is the same group, not a duplicate.
        #expect(harness.controller.createGroup(from: folder) == id)
        #expect(harness.store.state.groups.count == before + 1)
    }

    @Test("The sidebar's ＋ New group footer reaches the window controller")
    func newGroupFooterIsWired() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        #expect(harness.controller.sidebar.onNewGroup != nil)
        #expect(harness.controller.sidebar.newGroupFooter.onNewGroup != nil)
    }

    // MARK: - Chrome persistence

    @Test("A stored frame places the window at launch")
    func frameAppliedAtLaunch() {
        var state = AppState.fixture
        state.windowFrame = NSRect(x: 60, y: 40, width: 1000, height: 700)
        let harness = Self.makeHarness(state)
        defer { harness.tearDown() }

        #expect(harness.window.frame.size == NSSize(width: 1000, height: 700))
    }

    @Test("A stored sidebar width is applied at launch and reading it back is a fixed point")
    func sidebarWidthRestored() {
        var state = AppState.fixture
        state.sidebarWidth = 380
        let harness = Self.makeHarness(state)
        defer { harness.tearDown() }

        #expect(harness.controller.restoredSidebarWidth == 380)
        #expect(harness.controller.sidebarWidthForRestore == 380)

        // The loop that must not oscillate: the store places the divider, layout is read back, and
        // the store places it again on the next launch. Reading the settled width must therefore
        // change nothing at all — any discrepancy moves the sidebar a little on every launch until
        // it hits a limit, which is what recording the 8 pt-narrower inner view did.
        harness.controller.recordSidebarWidth()
        harness.store.flush()
        #expect(harness.store.state.sidebarWidth == 380)
        #expect(harness.controller.sidebarWidthForRestore == 380)

        // A store-driven change (what a restore from `state.json` is) reaches the split view.
        harness.mutate { $0.sidebarWidth = 420 }
        #expect(harness.controller.sidebarWidthForRestore == 420)
    }

    @Test("An unrelated store change never re-places the sidebar divider")
    func unrelatedChromeChangeLeavesTheDividerAlone() {
        // The reported bug: drag the sidebar wider, release, and it snaps back. Both
        // `applySidebarVisible` and `applySidebarWidth` used to re-issue `setPosition` on *every*
        // `chrome` delivery, so any unrelated mutation — a preset edit, a window move — threw away
        // the width the user had just dragged to.
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let before = harness.controller.splitViewController.appliedWidthCount

        harness.mutate { $0.windowFrame = NSRect(x: 30, y: 40, width: 1100, height: 720) }
        harness.mutate { _ = $0.addPreset(Preset(name: "p", command: "claude")) }
        harness.mutate { $0.shortcuts["x"] = "cmd+x" }

        #expect(harness.controller.splitViewController.appliedWidthCount == before)
    }

    @Test("A width that came from the store is applied exactly once")
    func storeDrivenWidthIsAppliedOnce() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let before = harness.controller.splitViewController.appliedWidthCount

        harness.mutate { $0.sidebarWidth = 420 }
        #expect(harness.controller.sidebarWidthForRestore == 420)
        #expect(harness.controller.splitViewController.appliedWidthCount == before + 1)

        // Re-delivering the same value must not touch the divider again.
        harness.mutate { $0.shortcuts["y"] = "cmd+y" }
        #expect(harness.controller.splitViewController.appliedWidthCount == before + 1)
    }

    @Test("A nonsense stored width degrades to the design default")
    func sidebarWidthGarbage() {
        var state = AppState.fixture
        state.sidebarWidth = 4
        let harness = Self.makeHarness(state)
        defer { harness.tearDown() }
        #expect(harness.controller.restoredSidebarWidth == MainWindowController.sidebarWidth)
        #expect(harness.controller.sidebarWidthForRestore == MainWindowController.sidebarWidth)
    }

    @Test("A dragged width survives layout — the seeding constraint must not re-assert itself")
    func draggedWidthSurvivesLayout() {
        // The reported bug, as close as a headless test gets to a mouse: place the divider the way
        // a drag does and lay out again. With the width constraint still active this read 300 no
        // matter what was asked for, which on screen is "drag it, let go, it snaps back".
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.controller.splitViewController.splitView.setPosition(380, ofDividerAt: 0)
        harness.layout()
        #expect(harness.controller.sidebarWidthForRestore == 380)
        harness.layout()
        #expect(harness.controller.sidebarWidthForRestore == 380)

        // …and the settled value is what gets recorded, so the next launch comes back to it.
        harness.controller.recordSidebarWidth()
        harness.store.flush()
        #expect(harness.store.state.sidebarWidth == 380)
    }

    @Test("A notice takes over the status strip and then gives it back")
    func statusNotice() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.controller.showNotice("Restored sidebar from backup", for: .seconds(60))
        #expect(harness.controller.statusBar.model.notice == "Restored sidebar from backup")
        #expect(harness.controller.statusBar.currentSegments.count == 1)
        #expect(harness.controller.statusBar.currentSegments.first?.plainText
            == "Restored sidebar from backup")
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

        // What the picture shows: the status strip, the window/terminal grounds, and — since the
        // sidebar became a plain split item — the sidebar column itself, rows, summary strip and
        // the ＋ New group footer included. (The old `sidebarWithViewController:` flavour wrapped
        // it in an `NSVisualEffectView`, which has no offscreen content and painted a flat
        // fallback.) The titlebar and its material are not part of the content view, so they are
        // never in this picture; the user is the verifier for those.

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
