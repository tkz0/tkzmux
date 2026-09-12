// ThemeToggleTests — the dark/light toggle, end to end on the AppKit side.
//
// The fan-out has one owner (`MainWindowController.setTheme`) and one trigger (`ChangeSet.theme`).
// These tests pin both, plus the two collaborators that are easy to forget because they have no
// `setTheme` of their own: the tab strip and the panes of *background* tabs.
import AppKit
import Testing
import TkzCore
@testable import TkzApp

@MainActor
@Suite struct ThemeToggleTests {
    private static func makeHarness(_ state: AppState = .fixture) -> MainWindowControllerTests.Harness {
        MainWindowControllerTests.makeHarness(state)
    }

    private static func components(_ color: CGColor?) -> (r: Double, g: Double, b: Double)? {
        guard let parts = color?.components, parts.count >= 3 else { return nil }
        return (Double(parts[0]), Double(parts[1]), Double(parts[2]))
    }

    private static func expectMatches(
        _ color: CGColor?, _ token: RGB, _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let actual = components(color) else {
            Issue.record("\(label) has no colour components", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(actual.r - token.r) < 0.01, "\(label) red", sourceLocation: sourceLocation)
        #expect(abs(actual.g - token.g) < 0.01, "\(label) green", sourceLocation: sourceLocation)
        #expect(abs(actual.b - token.b) < 0.01, "\(label) blue", sourceLocation: sourceLocation)
    }

    // MARK: The command

    @Test("Toggling writes the store, and the store is the only writer")
    func toggleGoesThroughTheStore() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        #expect(harness.store.state.themePreset == Theme.default.preset)

        harness.controller.toggleTheme()
        harness.store.flush()
        #expect(harness.store.state.themePreset == .light)

        harness.controller.toggleTheme()
        harness.store.flush()
        #expect(harness.store.state.themePreset == Theme.default.preset)
    }

    @Test("The same command is reachable from the menu and the palette")
    func theCommandIsWiredToTheDispatcher() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.controller.dispatcher.perform(.toggleTheme)
        harness.store.flush()
        #expect(harness.store.state.themePreset == .light)
    }

    // MARK: The fan-out

    @Test("A theme change re-tints the window and every piece of chrome")
    func theFanOutReachesEveryCollaborator() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let light = Theme.light

        #expect(harness.window.appearance?.name == .darkAqua)

        harness.mutate { $0.setThemePreset(.light) }

        // The window first: every system control and visual-effect view resolves from this.
        #expect(harness.window.appearance?.name == .aqua)
        Self.expectMatches(harness.window.backgroundColor.cgColor, light.windowBackground, "window background")

        Self.expectMatches(harness.controller.sidebar.view.layer?.backgroundColor,
                           light.sidebarBackground, "sidebar")
        #expect(harness.controller.toolbarController.theme == light)
        #expect(harness.controller.statusBar.theme == light)
        #expect(harness.controller.palette.theme == light)
        #expect(harness.controller.promptCard.theme == light)
        #expect(harness.controller.paneContainer.theme == light)
        Self.expectMatches(harness.controller.detail.view.layer?.backgroundColor,
                           light.terminalBackground, "detail background")
    }

    /// `DetailViewController.setTheme` does not reach the tab strip — `TabStripView` has no setter
    /// and takes a theme only through `configure(_:theme:)`. Without an explicit re-configure the
    /// strip keeps the old colours until the next tab change.
    @Test("The tab strip is re-themed, not left until the next tab change")
    func theTabStripFollows() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.mutate { $0.setThemePreset(.light) }

        Self.expectMatches(harness.controller.detail.tabStrip.layer?.backgroundColor,
                           Theme.light.sidebarBackground, "tab strip")
    }

    /// `PaneContainerView.apply(theme:)` walks only the panes that are on screen, but the
    /// controller keeps chrome for background tabs and hidden zoom siblings too. Those must not
    /// come back wearing the old theme.
    @Test("A pane that is not on screen is re-themed too")
    func backgroundPanesFollow() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        let session = try #require(harness.store.state.sessions.values.first)
        harness.mutate { $0.select(session.id) }
        harness.controller.addTerminal(splitting: .vertical)
        harness.store.flush()
        harness.layout()

        // Every pane the controller knows about, on screen or not.
        let panes = harness.controller.panes
        try #require(!panes.isEmpty)

        harness.mutate { $0.setThemePreset(.light) }

        for (id, pane) in panes {
            #expect(pane.chrome.theme == Theme.light, "pane \(id.rawValue) kept the old theme")
        }
    }

    @Test("Toggling back restores the dark chrome exactly")
    func theToggleIsInvolutive() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.mutate { $0.setThemePreset(.light) }
        harness.mutate { $0.setThemePreset(Theme.default.preset) }

        #expect(harness.window.appearance?.name == .darkAqua)
        Self.expectMatches(harness.controller.sidebar.view.layer?.backgroundColor,
                           Theme.default.sidebarBackground, "sidebar")
        #expect(harness.controller.statusBar.theme == Theme.default)
    }

    // MARK: Launch

    /// The no-dark-flash test. A controller built over a store that already carries the light
    /// preset must come up light — with no `setTheme` call in between, because the window's
    /// appearance and every session's palette are fixed at construction.
    @Test("A restored light preset is already applied on the first frame")
    func theRestoredPresetIsLiveBeforeTheFirstFrame() {
        _ = NSApplication.shared
        var state = AppState.fixture
        state.setThemePreset(.light)
        let store = AppStore(state: state)
        let host = MainWindowControllerTests.SpyTerminalHost()
        let view = MainWindowControllerTests.FakeTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        // No `theme:` argument: exactly what `AppDelegate` does.
        let controller = MainWindowController(store: store, host: host, terminalView: view)
        defer {
            controller.shutdown()
            controller.window.orderOut(nil)
        }
        controller.window.contentView?.layoutSubtreeIfNeeded()

        #expect(controller.window.appearance?.name == .aqua)
        #expect(controller.statusBar.theme == .light)
        Self.expectMatches(controller.sidebar.view.layer?.backgroundColor,
                           Theme.light.sidebarBackground, "sidebar")
    }

    /// A `chrome` delivery must not drag the whole re-tint along with it — that is the reason the
    /// preset got its own bucket instead of riding `chrome`.
    @Test("An unrelated chrome change does not re-theme anything")
    func chromeChangesDoNotReTheme() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.mutate { $0.setSidebarVisible(false) }

        #expect(harness.window.appearance?.name == .darkAqua)
        #expect(harness.controller.statusBar.theme == Theme.default)
    }
}
