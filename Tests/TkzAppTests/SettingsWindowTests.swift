// SettingsWindowTests — ⌘, (design 7a–d).
//
// The window is real and **never ordered front**: `orderFront` is replaced by a recorder, so the
// test process keeps whatever key window it had. Controls are driven through their test hooks
// (`toggleForTesting`, `sendAction`), never `performClick` — a click on an on-screen button has
// ended a Swift Testing run on this machine before.

import AppKit
import AgentBridge
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct SettingsWindowTests {

    @MainActor
    final class Recorder {
        var orderedFront: [NSWindow] = []
        var spend: [Bool] = []
        var offered: [String] = []
        var removed: [String] = []
        var shellRemovals = 0
    }

    static func makeController(
        _ state: AppState = .fixture,
        statusline: [String: StatuslineProducer] = [:],
        shellInstalled: Bool? = nil
    ) -> (AppStore, SettingsWindowController, Recorder) {
        _ = NSApplication.shared
        let store = AppStore(state: state)
        let controller = SettingsWindowController(store: store, theme: .default)
        let recorder = Recorder()
        controller.orderFront = { recorder.orderedFront.append($0) }
        controller.actions = SettingsWindowController.Actions(
            setShowSessionSpend: { recorder.spend.append($0) },
            offerStatusline: { recorder.offered.append($0) },
            removeStatusline: { recorder.removed.append($0) },
            removeShellIntegration: { recorder.shellRemovals += 1 },
            statuslineProducers: { statusline },
            shellIntegrationInstalled: { shellInstalled },
            shellIntegrationDirectory: { "~/Library/Application Support/tkzmux-test" })
        return (store, controller, recorder)
    }

    static func keyEvent(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    // MARK: - Model

    @Test("Only pages with a setting behind them exist, in the artboard's order")
    func pages() {
        // `allCases` is the draw order; membership is the model's, which is why the nav column
        // iterates `model.pages` rather than this list.
        #expect(SettingsPage.allCases.map(\.title) == ["General", "Agents", "Shell", "Appearance"])
        let model = SettingsModel.make(state: .fixture)
        #expect(model.sections(for: .general).map(\.caption) == ["On launch", "Git", "Notifications", "Status bar"])
        #expect(model.sections(for: .shell).map(\.caption) == ["Shell integration"])
        #expect(model.sections(for: .appearance).map(\.caption) == ["Theme"])
        // Nothing wired an installed-agent list, so there is no Agents page at all — a popup with
        // one choice is not a setting.
        #expect(model.pages[.agents] == nil)
    }

    // MARK: - Agents page

    @Test("The Agents page lists one row per group, naming the agent its sessions will start")
    func agentsPageListsOneRowPerGroup() throws {
        var state = AppState.fixture
        let groups = state.orderedGroups
        state.setGroupAgent(groups[0].id, agent: .codex)

        let model = SettingsModel.make(
            state: state,
            environment: .init(
                agentDisplayName: { $0 == .codex ? "Codex" : "Claude" },
                installedAgents: [.claude, .codex]))

        let sections = model.sections(for: .agents)
        #expect(sections.map(\.caption) == ["Default agent per group"])
        let rows = try #require(sections.first?.rows)
        #expect(rows.count == groups.count, "one row per group, in sidebar order")
        #expect(rows.map(\.title) == groups.map(\.name))

        // The group that chose Codex shows Codex selected; the rest resolve to Claude.
        #expect(rows[0].control == .popup(titles: ["Claude", "Codex"], selected: 1))
        #expect(rows[0].detail.contains("start Codex"))
        #expect(rows[1].control == .popup(titles: ["Claude", "Codex"], selected: 0))
        #expect(rows[1].detail.contains("start Claude"))
        // Every row names its target the way every other Settings row does.
        #expect(rows.allSatisfy { !$0.detail.isEmpty })
    }

    /// A picker with one choice is not a setting, so the page is omitted rather than drawn with a
    /// popup nobody can move. Same rule the Hooks section follows.
    @Test("The Agents page is omitted with fewer than two installed agents, or with no groups")
    func agentsPageIsOmittedWhenItWouldBeAChoiceOfOne() {
        let oneAgent = SettingsModel.make(
            state: .fixture, environment: .init(installedAgents: [.claude]))
        #expect(oneAgent.pages[.agents] == nil)

        let noGroups = SettingsModel.make(
            state: AppState(), environment: .init(installedAgents: [.claude, .codex]))
        #expect(noGroups.pages[.agents] == nil)
    }

    /// A group pinned to an agent this machine does not have shows what will *really* run, and says
    /// why — the same honesty rule the ＋ menu's `agentMissing` row follows.
    @Test("A group naming an uninstalled agent shows the fallback and says so")
    func agentsPageNamesAnUninstalledChoice() throws {
        var state = AppState.fixture
        let group = state.orderedGroups[0]
        state.setGroupAgent(group.id, agent: AgentKind(rawValue: "aider"))

        let model = SettingsModel.make(
            state: state,
            environment: .init(
                agentDisplayName: { kind in
                    switch kind {
                    case .codex: "Codex"
                    case .claude: "Claude"
                    default: "Aider"
                    }
                },
                installedAgents: [.claude, .codex]))

        let row = try #require(model.sections(for: .agents).first?.rows.first)
        #expect(row.control == .popup(titles: ["Claude", "Codex"], selected: 0))
        #expect(row.detail.contains("start Claude"))
        #expect(row.detail.contains("Aider is not installed"))
    }

    @Test("Every switch reads the store, and every row has a sentence")
    func rowsFollowState() {
        var state = AppState.fixture
        state.setAutoResumeOnLaunch(true)
        state.setCheckOriginPeriodically(true)
        state.setNotifyOnDone(false)
        state.setShowSessionSpend(false)
        state.setThemePreset(.light)
        let model = SettingsModel.make(state: state)
        let rows = Dictionary(
            uniqueKeysWithValues: model.pages.values.flatMap { $0 }.flatMap(\.rows).map { ($0.id, $0) })

        #expect(rows[.autoResume]?.control == .toggle(isOn: true))
        #expect(rows[.originCheck]?.control == .toggle(isOn: true))
        #expect(rows[.notifyOnDone]?.control == .toggle(isOn: false))
        #expect(rows[.sessionSpend]?.control == .toggle(isOn: false))
        #expect(rows[.themePreset]?.control == .popup(titles: ["Midnight indigo", "Light"], selected: 1))
        #expect(rows[.removeShell]?.control == .button(title: "Remove\u{2026}", destructive: true))
        for row in rows.values {
            #expect(!row.detail.isEmpty, "\(row.id) has no sentence")
            #expect(!row.title.isEmpty)
        }
        // The real interval, not the artboard's.
        #expect(rows[.originCheck]?.detail.contains("5 min") == true)
    }

    @Test("Status line: one row per account, the default first, named only when there are several")
    func statuslineRows() {
        var state = AppState.fixture
        state.accounts = [
            Account.defaultKey(for: .claude): Account(key: Account.defaultKey(for: .claude), configDir: "/h/.claude", label: "Private"),
        ]
        let single = SettingsModel.statuslineRows(state: state, environment: .init())
        #expect(single.map(\.title) == ["Status line integration"])
        #expect(single.first?.control == .button(title: "Configure\u{2026}", destructive: false))
        #expect(single.first?.detail.contains("/h/.claude/settings.json") == true)

        state.setAccount(Account(key: "claude-work", configDir: "/h/.claude-work", label: "Work"))
        let environment = SettingsModel.Environment(statusline: [
            Account.defaultKey(for: .claude): .tkzmux,
            "claude-work": .other(command: "node hud.js"),
        ])
        let both = SettingsModel.statuslineRows(state: state, environment: environment)
        #expect(both.map(\.id) == [.statusline(accountKey: Account.defaultKey(for: .claude)), .statusline(accountKey: "claude-work")])
        #expect(both.map(\.title) == [
            "Status line integration \u{00B7} Private (claude)",
            "Status line integration \u{00B7} Work (claude-work)",
        ])
        #expect(both[0].control == .button(title: "Remove\u{2026}", destructive: false))
        #expect(both[1].control == .button(title: "Configure\u{2026}", destructive: false))
        #expect(both[1].detail.contains("keeps running"))
    }

    /// Two config dirs signed into the same organisation resolve to the same label — the reason
    /// the row names an account by key as well. Without it these two rows are the same sentence
    /// twice, distinguishable only by a path buried in the body text.
    @Test("Status line: two accounts sharing a label still get titles that tell them apart")
    func statuslineRowsDisambiguateASharedLabel() {
        var state = AppState.fixture
        state.accounts = [
            Account.defaultKey(for: .claude): Account(
                key: Account.defaultKey(for: .claude), configDir: "/h/.claude", label: "Acme Inc"),
            "claude-alt": Account(key: "claude-alt", configDir: "/h/.claude-alt", label: "Acme Inc"),
        ]
        let rows = SettingsModel.statuslineRows(state: state, environment: .init())
        #expect(rows.map(\.title) == [
            "Status line integration \u{00B7} Acme Inc (claude)",
            "Status line integration \u{00B7} Acme Inc (claude-alt)",
        ])
        #expect(Set(rows.map(\.title)).count == rows.count)
    }

    /// The other half of the same rule: an account nobody has named is its key, and the key is not
    /// then printed twice.
    @Test("Status line: an unnamed account is titled by its key alone")
    func statuslineRowsNameAnUnnamedAccountByItsKey() {
        var state = AppState.fixture
        state.accounts = [
            Account.defaultKey(for: .claude): Account(
                key: Account.defaultKey(for: .claude), configDir: "/h/.claude", label: "claude"),
            "claude-alt": Account(key: "claude-alt", configDir: "/h/.claude-alt", label: "claude-alt"),
        ]
        let rows = SettingsModel.statuslineRows(state: state, environment: .init())
        #expect(rows.map(\.title) == [
            "Status line integration \u{00B7} claude",
            "Status line integration \u{00B7} claude-alt",
        ])
    }

    @Test("Statusline sentence names whichever agent the environment says, not a hard-coded product")
    func statuslineNamesTheGivenAgent() {
        var state = AppState.fixture
        state.accounts = [
            Account.defaultKey(for: .claude): Account(key: Account.defaultKey(for: .claude), configDir: "/h/.claude", label: "Private"),
        ]
        let environment = SettingsModel.Environment(agentDisplayName: { _ in "Stub Agent" })
        let rows = SettingsModel.statuslineRows(state: state, environment: environment)
        #expect(rows.first?.detail.contains("Let Stub Agent write its usage") == true)
    }

    @Test("Status line: gated on the .statusline capability, not on the agent's name")
    func statuslineGatesOnCapability() {
        var state = AppState.fixture
        state.accounts = [
            Account.defaultKey(for: .claude): Account(key: Account.defaultKey(for: .claude), configDir: "/h/.claude", label: "Private"),
            "codex": Account(key: "codex", configDir: "/h/.codex", label: "Codex", agent: .codex),
        ]
        // The default capability table (no real adapters wired) grants `.statusline` to Claude
        // alone — today's shipped behaviour — so the Codex account here gets no row.
        let defaultEnv = SettingsModel.statuslineRows(state: state, environment: .init())
        #expect(defaultEnv.map(\.id) == [.statusline(accountKey: Account.defaultKey(for: .claude))])

        // The row-builder itself does not know "Claude" — handing it a capability table where
        // *nobody* has `.statusline` hides even the Claude row, and one where Codex also has it
        // shows both. Either way proves the gate reads `environment.capabilities`, not the agent.
        let nobody = SettingsModel.statuslineRows(
            state: state, environment: .init(capabilities: { _ in [] }))
        #expect(nobody.isEmpty)

        let everybody = SettingsModel.statuslineRows(
            state: state, environment: .init(capabilities: { _ in [.statusline] }))
        #expect(Set(everybody.map(\.id)) == [
            .statusline(accountKey: Account.defaultKey(for: .claude)), .statusline(accountKey: "codex"),
        ])
    }

    @Test("Hooks: only for an agent whose hooks need installing with consent, never for Claude")
    func hooksRowsGateOnHookInstallRequired() {
        var state = AppState.fixture
        state.accounts = [
            Account.defaultKey(for: .claude): Account(key: Account.defaultKey(for: .claude), configDir: "/h/.claude", label: "Private"),
            "codex": Account(key: "codex", configDir: "/h/.codex", label: "Codex", agent: .codex),
        ]
        // No wiring at all: no row for anybody, Codex included — the asymmetry only shows up once
        // something actually claims the capability.
        #expect(SettingsModel.hooksRows(state: state, environment: .init()).isEmpty)

        let environment = SettingsModel.Environment(hooksInstallRequired: { $0 == .codex })
        let rows = SettingsModel.hooksRows(state: state, environment: environment)
        #expect(rows.map(\.id) == [.hooks(accountKey: "codex")])
        #expect(rows[0].title == "Hooks integration")
        #expect(rows[0].control == .button(title: "Configure\u{2026}", destructive: false))
        #expect(rows[0].detail.contains("/h/.codex/hooks.json"))
        #expect(rows[0].detail.contains("Edits it only after you confirm"))

        // Even if Claude were (hypothetically) handed to `hooksInstallRequired`, a second account
        // still only names an account when there is more than one — same rule as `statuslineRows`.
        state.setAccount(Account(key: "codex-work", configDir: "/h/.codex-work", label: "Work", agent: .codex))
        let both = SettingsModel.hooksRows(state: state, environment: environment)
        #expect(both.map(\.title) == [
            "Hooks integration \u{00B7} Codex (codex)",
            "Hooks integration \u{00B7} Work (codex-work)",
        ])
    }

    @Test("Hooks: producer states read the same way status line's do, plus config.toml's overlap")
    func hooksRowsProducerStates() {
        var state = AppState.fixture
        state.accounts = ["codex": Account(key: "codex", configDir: "/h/.codex", label: "Codex", agent: .codex)]
        let base = SettingsModel.Environment(hooksInstallRequired: { $0 == .codex })

        let none = SettingsModel.hooksRows(state: state, environment: base)
        #expect(none[0].control == .button(title: "Configure\u{2026}", destructive: false))
        #expect(none[0].detail.contains("relay session events to tkzmux"))
        #expect(!none[0].detail.contains("config.toml"))

        var withConfigToml = base
        withConfigToml.hooksDetection = ["codex": AgentBridge.CodexHooksDetection(
            producer: .none, configTomlHasHooks: true, trust: .unknown)]
        let noneWithToml = SettingsModel.hooksRows(state: state, environment: withConfigToml)
        #expect(noneWithToml[0].detail.contains("config.toml"))
        #expect(noneWithToml[0].detail.contains("alongside them"))

        var other = base
        other.hooksDetection = ["codex": AgentBridge.CodexHooksDetection(
            producer: .other, configTomlHasHooks: false, trust: .unknown)]
        let otherRows = SettingsModel.hooksRows(state: state, environment: other)
        #expect(otherRows[0].control == .button(title: "Configure\u{2026}", destructive: false))
        #expect(otherRows[0].detail.contains("alongside the hooks already there"))

        var stale = base
        stale.hooksDetection = ["codex": AgentBridge.CodexHooksDetection(
            producer: .stale(paths: ["/old/tkzmux-hook"]), configTomlHasHooks: false, trust: .unknown)]
        let staleRows = SettingsModel.hooksRows(state: state, environment: stale)
        #expect(staleRows[0].control == .button(title: "Remove\u{2026}", destructive: false))
        #expect(staleRows[0].detail.contains("repointed at launch"))
    }

    @Test("Hooks: the trust sentence never suggests bypassing trust")
    func hooksRowsTrustSentence() {
        var state = AppState.fixture
        state.accounts = ["codex": Account(key: "codex", configDir: "/h/.codex", label: "Codex", agent: .codex)]
        var environment = SettingsModel.Environment(hooksInstallRequired: { $0 == .codex })

        environment.hooksDetection = ["codex": AgentBridge.CodexHooksDetection(
            producer: .tkzmux, configTomlHasHooks: false, trust: .mentionsOurConfig)]
        let mentions = SettingsModel.hooksRows(state: state, environment: environment)
        #expect(mentions[0].detail.contains("trust ledger already mentions this file"))
        #expect(mentions[0].control == .button(title: "Remove\u{2026}", destructive: false))

        environment.hooksDetection = ["codex": AgentBridge.CodexHooksDetection(
            producer: .tkzmux, configTomlHasHooks: false, trust: .doesNotMentionOurConfig)]
        let notTrusted = SettingsModel.hooksRows(state: state, environment: environment)
        #expect(notTrusted[0].detail.contains("has not trusted this yet"))
        #expect(notTrusted[0].detail.contains("/hooks"))

        environment.hooksDetection = ["codex": AgentBridge.CodexHooksDetection(
            producer: .tkzmux, configTomlHasHooks: false, trust: .unknown)]
        let unknown = SettingsModel.hooksRows(state: state, environment: environment)
        #expect(unknown[0].detail.contains("cannot tell whether"))

        for rows in [mentions, notTrusted, unknown] {
            #expect(!rows[0].detail.contains("bypass"))
        }
    }

    @Test("General only grows a Hooks integration section when there is a row for it")
    func hooksSectionOmittedWhenEmpty() {
        #expect(SettingsModel.make(state: .fixture).sections(for: .general).map(\.caption)
            == ["On launch", "Git", "Notifications", "Status bar"])

        var state = AppState.fixture
        state.accounts["codex"] = Account(key: "codex", configDir: "/h/.codex", label: "Codex", agent: .codex)
        let environment = SettingsModel.Environment(hooksInstallRequired: { $0 == .codex })
        let sections = SettingsModel.make(state: state, environment: environment).sections(for: .general)
        #expect(sections.map(\.caption) == ["On launch", "Git", "Notifications", "Status bar", "Hooks integration"])
    }

    @Test("Shell page names the installed shims when it knows them")
    func shellRowNamesShims() {
        let generic = SettingsModel.make(state: .fixture).sections(for: .shell)[0].rows[0]
        #expect(generic.detail.contains("Each installed agent's shim"))

        let one = SettingsModel.make(
            state: .fixture, environment: .init(installedShims: ["claude"])
        ).sections(for: .shell)[0].rows[0]
        #expect(one.detail.contains("The `claude` shim"))

        let two = SettingsModel.make(
            state: .fixture, environment: .init(installedShims: ["claude", "codex"])
        ).sections(for: .shell)[0].rows[0]
        #expect(two.detail.contains("The `claude` and `codex` shims"))
    }

    @Test("Shell page: the chip says what is on disk, and the sentence names the directory")
    func shellStatus() {
        let none = SettingsModel.make(state: .fixture).sections(for: .shell)[0].rows
        #expect(none[0].control == .status(text: "Unavailable", active: false))
        #expect(none[0].detail.contains("~/Library/Application Support/tkzmux"))

        let on = SettingsModel.make(
            state: .fixture, environment: .init(shellInstalled: true, shellDirectory: "/x")
        ).sections(for: .shell)[0].rows
        #expect(on[0].control == .status(text: "Active", active: true))
        #expect(on[0].detail.contains("/x"))

        let off = SettingsModel.make(state: .fixture, environment: .init(shellInstalled: false))
            .sections(for: .shell)[0].rows
        #expect(off[0].control == .status(text: "Not installed", active: false))
        #expect(off[1].detail.contains("next launch"))
    }

    // MARK: - Window

    @Test("Presenting builds a titled, closable, fixed-size window once and hands it to orderFront")
    func presentBuildsTheWindow() throws {
        let (_, controller, recorder) = Self.makeController()
        #expect(controller.windowForTesting == nil)
        controller.present(over: NSRect(x: 100, y: 100, width: 1000, height: 800))
        let window = try #require(controller.windowForTesting)
        defer { controller.close() }

        #expect(controller.isShown)
        #expect(recorder.orderedFront.count == 1)
        #expect(window is SettingsWindow)
        #expect(window.title == "Settings")
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.titled))
        #expect(!window.styleMask.contains(.resizable))
        #expect(!window.styleMask.contains(.miniaturizable))
        #expect(window.isReleasedWhenClosed == false)
        #expect(window.frame.size == NSSize(width: SettingsView.Metrics.width, height: SettingsView.Metrics.height))
        // Centred over the anchor.
        #expect(abs(window.frame.midX - 600) <= 1)
        #expect(abs(window.frame.midY - 500) <= 1)

        controller.present(over: nil)
        #expect(controller.windowForTesting === window, "one window, reused")
        #expect(recorder.orderedFront.count == 2)

        let view = try #require(controller.viewForTesting)
        // Every page has a nav row built once; the ones the model has nothing for are hidden
        // rather than rebuilt, so the column never reflows when a page appears or goes away.
        #expect(view.navRowsForTesting.count == 4)
        #expect(view.navRowsForTesting[.agents]?.isHidden == true, "no Agents page without agents")
        #expect(view.navRowsForTesting[.general]?.isHidden == false)
        #expect(view.navRowsForTesting[.general]?.isSelected == true)
        #expect(view.captionsForTesting == ["On launch", "Git", "Notifications", "Status bar"])
    }

    @Test("A switch writes the store; the store writes the switch")
    func switchesRoundTrip() throws {
        let (store, controller, recorder) = Self.makeController()
        controller.present(over: nil)
        defer { controller.close() }
        let view = try #require(controller.viewForTesting)

        let autoResume = try #require(view.controlForTesting(.autoResume) as? ThemedSwitch)
        #expect(autoResume.isOn == store.state.autoResumeOnLaunch)
        autoResume.toggleForTesting()
        store.flush()
        #expect(store.state.autoResumeOnLaunch == !AppState.fixture.autoResumeOnLaunch)

        let origin = try #require(view.controlForTesting(.originCheck) as? ThemedSwitch)
        origin.toggleForTesting()
        store.flush()
        #expect(store.state.checkOriginPeriodically == true)

        // The spend switch goes through the window controller, which also refreshes usage.
        let spend = try #require(view.controlForTesting(.sessionSpend) as? ThemedSwitch)
        #expect(spend.isOn == true)
        spend.toggleForTesting()
        #expect(recorder.spend == [false])

        // The other direction: a change made elsewhere lands on the row, in place.
        let notify = try #require(view.controlForTesting(.notifyOnDone) as? ThemedSwitch)
        #expect(notify.isOn == true)
        store.update { $0.setNotifyOnDone(false) }
        store.flush()
        #expect(notify.isOn == false)
        #expect(view.controlForTesting(.notifyOnDone) === notify, "updated, not rebuilt")
    }

    @Test("The theme popup selects a preset, and follows the store")
    func themePopup() throws {
        let (store, controller, _) = Self.makeController()
        controller.present(page: .appearance, over: nil)
        defer { controller.close() }
        let view = try #require(controller.viewForTesting)
        #expect(view.navRowsForTesting[.appearance]?.isSelected == true)
        #expect(view.captionsForTesting == ["Theme"])

        let popup = try #require(view.controlForTesting(.themePreset) as? NSPopUpButton)
        #expect(popup.itemTitles == ["Midnight indigo", "Light"])
        #expect(popup.indexOfSelectedItem == 0)

        popup.selectItem(at: 1)
        _ = NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        store.flush()
        #expect(store.state.themePreset == .light)

        store.update { $0.setThemePreset(.midnightIndigo) }
        store.flush()
        #expect(popup.indexOfSelectedItem == 0)
    }

    @Test("Shell and status line buttons reach the window controller's flows by account")
    func buttonsReachTheFlows() throws {
        var state = AppState.fixture
        state.accounts = [
            Account.defaultKey(for: .claude): Account(key: Account.defaultKey(for: .claude), configDir: "/h/.claude", label: "Private"),
            "claude-work": Account(key: "claude-work", configDir: "/h/.claude-work", label: "Work"),
        ]
        let (_, controller, recorder) = Self.makeController(
            state, statusline: [Account.defaultKey(for: .claude): .tkzmux], shellInstalled: true)
        controller.present(over: nil)
        defer { controller.close() }
        let view = try #require(controller.viewForTesting)

        let remove = try #require(view.controlForTesting(.statusline(accountKey: Account.defaultKey(for: .claude))) as? NSButton)
        #expect(remove.title == "Remove\u{2026}")
        _ = NSApp.sendAction(remove.action!, to: remove.target, from: remove)
        #expect(recorder.removed == [Account.defaultKey(for: .claude)])

        let configure = try #require(view.controlForTesting(.statusline(accountKey: "claude-work")) as? NSButton)
        #expect(configure.title == "Configure\u{2026}")
        _ = NSApp.sendAction(configure.action!, to: configure.target, from: configure)
        #expect(recorder.offered == ["claude-work"])

        controller.select(page: .shell)
        let chip = try #require(view.controlForTesting(.shellStatus) as? StatusChipView)
        #expect(chip.textForTesting == "Active")
        #expect(chip.isActiveForTesting)
        let removeShell = try #require(view.controlForTesting(.removeShell) as? NSButton)
        _ = NSApp.sendAction(removeShell.action!, to: removeShell.target, from: removeShell)
        #expect(recorder.shellRemovals == 1)
    }

    @Test("⌘W and Escape close the window through its own key handling")
    func keysClose() throws {
        let (_, controller, _) = Self.makeController()
        controller.present(over: nil)
        let window = try #require(controller.windowForTesting)

        let commandW = Self.keyEvent("w", keyCode: 13, flags: .command, window: window)
        #expect(SettingsWindow.closes(commandW))
        #expect(window.performKeyEquivalent(with: commandW))
        #expect(!controller.isShown)

        controller.present(over: nil)
        #expect(controller.isShown)
        let escape = Self.keyEvent("\u{1B}", keyCode: 53, flags: [], window: window)
        #expect(SettingsWindow.closes(escape))
        window.keyDown(with: escape)
        #expect(!controller.isShown)

        // Caps Lock is not a chord; a shifted W is something else.
        #expect(SettingsWindow.closes(Self.keyEvent("w", keyCode: 13, flags: [.command, .capsLock], window: window)))
        #expect(!SettingsWindow.closes(Self.keyEvent("W", keyCode: 13, flags: [.command, .shift], window: window)))
        #expect(!SettingsWindow.closes(Self.keyEvent("w", keyCode: 13, flags: [], window: window)))
    }

    @Test("The theme reaches the window and its rows")
    func themeFollows() throws {
        let (_, controller, _) = Self.makeController()
        controller.present(over: nil)
        defer { controller.close() }
        let window = try #require(controller.windowForTesting)
        #expect(window.appearance?.name == .darkAqua)
        controller.theme = .light
        #expect(window.appearance?.name == .aqua)
        #expect(window.backgroundColor == Theme.light.windowBackground.nsColor)
    }

    // MARK: - Through the main window

    @Test("⌘, is wired, and the six old toggles are no longer commands anywhere")
    func throughTheMainWindow() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let recorder = Recorder()
        controller.settings.orderFront = { recorder.orderedFront.append($0) }

        #expect(controller.dispatcher.canPerform(.settings))
        #expect(MainMenu.commandItems(in: controller.buildMainMenu())[.settings]?.keyEquivalent == ",")
        for raw in ["toggleAutoResume", "toggleSessionSpend", "toggleOriginCheck",
                    "toggleDoneNotification", "statusLineIntegration", "removeShellIntegration"] {
            #expect(!controller.dispatcher.canPerform(ShortcutAction(raw)), "\(raw) is a Settings row now")
            #expect(!ShortcutsTable.allActions.contains(ShortcutAction(raw)))
        }

        #expect(controller.dispatcher.perform(.settings))
        #expect(controller.settings.isShown)
        #expect(recorder.orderedFront.count == 1)
        // Not key in the test process, so the pane commands stay enabled.
        #expect(controller.dispatcher.isEnabled(.closeTerminal))

        // The spend switch flows through the controller's own setter.
        let view = try #require(controller.settings.viewForTesting)
        let spend = try #require(view.controlForTesting(.sessionSpend) as? ThemedSwitch)
        spend.toggleForTesting()
        harness.store.flush()
        #expect(harness.store.state.showSessionSpend == false)

        // View › Toggle Theme re-themes the open window.
        controller.toggleTheme()
        harness.store.flush()
        #expect(controller.settings.windowForTesting?.appearance?.name == .aqua)
        #expect((view.controlForTesting(.themePreset) as? NSPopUpButton) == nil, "General is the open page")
        controller.settings.select(page: .appearance)
        #expect((view.controlForTesting(.themePreset) as? NSPopUpButton)?.indexOfSelectedItem == 1)

        // `shutdown()` closes it with everything else.
        controller.shutdown()
        #expect(!controller.settings.isShown)
    }
}
