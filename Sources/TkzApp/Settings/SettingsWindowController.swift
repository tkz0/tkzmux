// SettingsWindowController.swift — ⌘, (design 7a–d).
//
// Owns the one Settings window: a real titled window with traffic lights, 720 × 560, centred over
// the main window the first time it opens, kept (never released) once built. The store is the only
// writer: a switch calls a reducer, the change set comes back through the observer, and the row is
// re-rendered from state — the same loop every other view runs, so a preference flipped anywhere
// else (View › Toggle Theme, a test) shows here without a special case.
//
// Two facts on the pages do not live in the store — which producer feeds each account's status
// line, and whether the shim is on disk — so `Actions` reads them on every render, and
// `windowDidBecomeKey` re-renders for the case where they changed while the window was behind.
//
// Everything with an alert behind it (`offerStatusline`, `removeStatusline`,
// `removeShellIntegration`) stays in `MainWindowController`, which already owns the consent flows
// and their test hooks; this controller only asks for them by account key.

import AppKit
import AgentBridge
import TkzCore

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    /// What the window needs from the rest of the app, as closures so the tests can stand in.
    struct Actions {
        var setShowSessionSpend: (Bool) -> Void = { _ in }
        var offerStatusline: (String) -> Void = { _ in }
        var removeStatusline: (String) -> Void = { _ in }
        var removeShellIntegration: () -> Void = {}
        var statuslineProducers: () -> [String: StatuslineProducer] = { [:] }
        var shellIntegrationInstalled: () -> Bool? = { nil }
        var shellIntegrationDirectory: () -> String? = { nil }
        /// TKZ-87: Codex's own consent-to-install hooks, and the agent-blind facts
        /// (`capabilitiesByAgent`, `hooksInstallRequiredAgents`, `agentDisplayNames`)
        /// `SettingsModel` needs to gate the status-line and hooks rows on the right adapters
        /// rather than on a hardcoded agent name.
        ///
        /// These snapshot as dictionaries rather than forward `AgentIntegration`'s own per-agent
        /// closures directly: `SettingsModel.Environment`'s matching properties are `@Sendable`
        /// (the whole `Environment` is `Sendable`), and a closure that captures this controller's
        /// `self` is not — `environment()` reads these once per render and closes over the plain,
        /// genuinely `Sendable` dictionaries instead.
        var offerCodexHooks: (String) -> Void = { _ in }
        var removeCodexHooks: (String) -> Void = { _ in }
        var hooksDetections: () -> [String: CodexHooksDetection] = { [:] }
        /// Matches `SettingsModel.Environment.capabilities`'s own default exactly (Claude's
        /// shipped capabilities, nothing for any other agent) — an unwired controller (most of
        /// this file's own tests, the dev window) must still draw today's Claude-only page rather
        /// than losing the status-line row because nothing populated this closure.
        var capabilitiesByAgent: () -> [AgentKind: AgentCapabilities] = {
            [.claude: [.hooks, .observation, .statusline, .transcriptUsage, .resume, .worktree]]
        }
        var hooksInstallRequiredAgents: () -> Set<AgentKind> = { [] }
        var agentDisplayNames: () -> [AgentKind: String] = { [:] }
        var installedShims: () -> [String] = { [] }
        /// The agents whose binary is on `PATH`, in the ＋ menu's own order. Empty by default, so
        /// an unwired controller draws no Agents page rather than one listing agents it cannot
        /// confirm are installed.
        var installedAgents: () -> [AgentKind] = { [] }
        /// Writes a group's agent. Wired to `MainWindowController.setGroupAgent`, **not** to
        /// `store.update` directly: that method also re-scopes the ＋ menu, which holds a value
        /// copy of the group and would otherwise keep resolving the old agent.
        var setGroupAgent: (GroupID, AgentKind) -> Void = { _, _ in }
    }

    var actions = Actions()

    var theme: Theme {
        didSet { if theme != oldValue { applyTheme() } }
    }

    /// Between `present` and the window closing, whichever way it closed.
    private(set) var isShown = false
    private(set) var page: SettingsPage = .general

    /// How the window comes to the front. Tests replace it: a window ordered front in the test
    /// process takes key from whatever else is running and, on this machine, has ended a run.
    var orderFront: (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }

    private let store: AppStore
    private var storeToken: AppStore.ObserverToken?
    private var window: SettingsWindow?
    private var view: SettingsView?

    init(store: AppStore, theme: Theme) {
        self.store = store
        self.theme = theme
        super.init()
        storeToken = store.addObserver { [weak self] change in
            guard let self, self.view != nil else { return }
            // `showSessionSpend` rides `sessions`, the theme its own flag, accounts `usage`,
            // everything else `chrome` — see the table above `ChangeSet`.
            if change.chrome || change.theme || change.usage || !change.sessions.isEmpty {
                self.render()
            }
        }
    }

    // MARK: Presentation

    /// Shows the window, centred over `anchor` (the main window's frame) the first time.
    func present(over anchor: NSRect?) {
        let window = makeWindowIfNeeded()
        render()
        if !isShown { place(window, over: anchor) }
        isShown = true
        orderFront(window)
    }

    func present(page: SettingsPage, over anchor: NSRect?) {
        self.page = page
        present(over: anchor)
    }

    /// One path out: `close()` on the window, which reports back through `SettingsWindow.onClose`.
    func close() {
        guard let window, isShown else { return }
        window.close()
    }

    func select(page: SettingsPage) {
        guard page != self.page else { return }
        self.page = page
        render()
    }

    // MARK: Rendering

    func render() {
        guard let view else { return }
        view.render(SettingsModel.make(state: store.state, environment: environment()), page: page)
    }

    private func environment() -> SettingsModel.Environment {
        // Snapshotted once per render into plain dictionaries — see the doc comment on
        // `Actions`'s own `capabilitiesByAgent` for why these cannot simply forward the
        // `AgentIntegration`-backed closures as the `@Sendable` closures `Environment` wants.
        let capabilities = actions.capabilitiesByAgent()
        let hooksRequired = actions.hooksInstallRequiredAgents()
        let names = actions.agentDisplayNames()
        return SettingsModel.Environment(
            statusline: actions.statuslineProducers(),
            shellInstalled: actions.shellIntegrationInstalled(),
            shellDirectory: actions.shellIntegrationDirectory(),
            installedShims: actions.installedShims(),
            agentDisplayName: { names[$0] ?? "the agent" },
            capabilities: { capabilities[$0] ?? [] },
            hooksInstallRequired: { hooksRequired.contains($0) },
            hooksDetection: actions.hooksDetections(),
            installedAgents: actions.installedAgents())
    }

    private func toggled(_ id: SettingsRow.ID, _ isOn: Bool) {
        switch id {
        case .autoResume: store.update { $0.setAutoResumeOnLaunch(isOn) }
        case .originCheck: store.update { $0.setCheckOriginPeriodically(isOn) }
        case .notifyOnDone: store.update { $0.setNotifyOnDone(isOn) }
        case .badgeDockIcon: store.update { $0.setBadgeDockIcon(isOn) }
        case .sessionSpend: actions.setShowSessionSpend(isOn)
        default: break
        }
    }

    private func pressed(_ id: SettingsRow.ID) {
        switch id {
        case .statusline(let accountKey):
            switch actions.statuslineProducers()[accountKey] ?? .none {
            case .tkzmux, .stale: actions.removeStatusline(accountKey)
            case .none, .other: actions.offerStatusline(accountKey)
            }
        case .hooks(let accountKey):
            let detection = actions.hooksDetections()[accountKey]
                ?? CodexHooksDetection(producer: .none, configTomlHasHooks: false, trust: .unknown)
            switch detection.producer {
            case .tkzmux, .stale: actions.removeCodexHooks(accountKey)
            case .none, .other: actions.offerCodexHooks(accountKey)
            }
        case .removeShell:
            actions.removeShellIntegration()
        default:
            return
        }
        // The consent flows report through notices and the store; the facts outside the store
        // are re-read here so a synchronous outcome shows at once.
        render()
    }

    private func picked(_ id: SettingsRow.ID, _ index: Int) {
        switch id {
        case .themePreset:
            let presets = Theme.Preset.allCases
            guard presets.indices.contains(index) else { return }
            store.update { $0.setThemePreset(presets[index]) }
        case .groupAgent(let groupID):
            // Indexes into the same list `SettingsModel.agents` built the popup's titles from, so
            // the two cannot drift apart.
            let installed = actions.installedAgents()
            guard installed.indices.contains(index) else { return }
            actions.setGroupAgent(groupID, installed[index])
        default:
            return
        }
    }

    // MARK: Window

    private func makeWindowIfNeeded() -> SettingsWindow {
        if let window { return window }

        let view = SettingsView(theme: theme)
        view.onSelectPage = { [weak self] page in self?.select(page: page) }
        view.onToggle = { [weak self] id, isOn in self?.toggled(id, isOn) }
        view.onButton = { [weak self] id in self?.pressed(id) }
        view.onPopup = { [weak self] id, index in self?.picked(id, index) }
        self.view = view

        let window = SettingsWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: SettingsView.Metrics.width, height: SettingsView.Metrics.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        window.title = "Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isExcludedFromWindowsMenu = true
        window.identifier = NSUserInterfaceItemIdentifier("tkzmux.settings")
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.contentView = view
        window.delegate = self
        window.onClose = { [weak self] in self?.isShown = false }
        self.window = window
        applyTheme()
        return window
    }

    private func place(_ window: NSWindow, over anchor: NSRect?) {
        guard let anchor else {
            window.center()
            return
        }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: (anchor.midX - size.width / 2).rounded(),
            y: (anchor.midY - size.height / 2).rounded()))
    }

    private func applyTheme() {
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = theme.windowBackground.nsColor
        view?.setTheme(theme)
    }

    // MARK: NSWindowDelegate

    /// Coming back to the window: the status line and shim facts may have moved meanwhile.
    func windowDidBecomeKey(_ notification: Notification) {
        render()
    }

    // MARK: Test access

    var windowForTesting: NSWindow? { window }
    var viewForTesting: SettingsView? { view }
}
