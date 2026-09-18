// SettingsWindowTests — ⌘, (design 7a–d).
//
// The window is real and **never ordered front**: `orderFront` is replaced by a recorder, so the
// test process keeps whatever key window it had. Controls are driven through their test hooks
// (`toggleForTesting`, `sendAction`), never `performClick` — a click on an on-screen button has
// ended a Swift Testing run on this machine before.

import AppKit
import ClaudeBridge
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
        #expect(SettingsPage.allCases.map(\.title) == ["General", "Shell", "Appearance"])
        let model = SettingsModel.make(state: .fixture)
        #expect(model.sections(for: .general).map(\.caption) == ["On launch", "Git", "Notifications", "Status bar"])
        #expect(model.sections(for: .shell).map(\.caption) == ["Shell integration"])
        #expect(model.sections(for: .appearance).map(\.caption) == ["Theme"])
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
        #expect(both.map(\.title) == ["Status line integration \u{00B7} Private", "Status line integration \u{00B7} Work"])
        #expect(both[0].control == .button(title: "Remove\u{2026}", destructive: false))
        #expect(both[1].control == .button(title: "Configure\u{2026}", destructive: false))
        #expect(both[1].detail.contains("keeps running"))
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
        #expect(view.navRowsForTesting.count == 3)
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
