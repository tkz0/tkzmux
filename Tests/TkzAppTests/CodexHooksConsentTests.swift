// CodexHooksConsentTests — the Codex counterpart of `StatuslineConsentTests` (TKZ-87).
//
// Codex's own trust model (`CodexHooksInstaller`'s header comment) is what makes this sheet
// different from the statusline's: installing `hooks.json` is not enough on its own, so the copy
// has to say so, and it must never mention `--dangerously-bypass-hook-trust` — that flag disables
// trust for every hook of the invocation, including the user's own, which makes it advice nobody
// should follow from a consent sheet. `config.toml` merging is the other measured fact the sheet
// has to carry when it applies.
//
// The sheet itself is an `NSAlert`, which never returns in a test process; `MainWindowController`
// exposes `confirmInstallCodexHooks` as the injection point, exactly the way `confirmInstallStatusline`
// does for the other agent's own consent flow.
import AppKit
import AgentBridge
import Foundation
import Testing
import TkzCore

@testable import TkzApp

@Suite @MainActor struct CodexHooksConsentTests {
    /// A window controller wired to an `AgentIntegration` whose adapter table is pinned to Codex
    /// alone: this machine has `codex` on `PATH` (per the shared brief), so the real default table
    /// would already include it, but this suite's subject is the consent sheet, not the discovery
    /// gate — `AgentIntegrationTests.accountDiscovery` owns that. Pinning also means the suite
    /// passes on a machine with no `codex` binary at all.
    private struct Fixture {
        var harness: MainWindowControllerTests.Harness
        var support: URL
        var configDir: URL
        var installer: CodexHooksInstaller
    }

    private func makeFixture(configToml: String? = nil) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("tkzmux-codex-consent-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)

        // `Account.configDirectory(forKey:)` needs `<home>/.codex`, exactly as the statusline
        // fixture needs `<home>/.claude`, so this gets its own fake home too.
        let home = root.appendingPathComponent("home", isDirectory: true)
        let configDir = home.appendingPathComponent(".codex", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        if let configToml {
            try Data(configToml.utf8).write(to: configDir.appendingPathComponent("config.toml"))
        }

        let harness = MainWindowControllerTests.makeHarness()
        harness.controller.agents = AgentIntegration(
            store: harness.store, directory: support, home: home.path,
            adapters: [.codex: CodexAdapter(supportDirectory: support)])
        harness.store.update { state in
            state.selection = nil
            state.setAccount(
                Account(
                    key: Account.defaultKey(for: .codex), configDir: configDir.path, label: "codex",
                    agent: .codex))
        }
        return Fixture(
            harness: harness, support: support, configDir: configDir,
            installer: CodexHooksInstaller(directory: support))
    }

    /// Drives the sheet the way a real Codex launch would: `MainWindowController.launch(_:)`
    /// succeeding for a `.codex` row, in this fixture's account.
    private func launchCodex(_ f: Fixture) {
        f.harness.controller.launch(
            NewSessionMenu.Launch(
                kind: .repoRoot, command: "codex", cwd: NSTemporaryDirectory(),
                accountKey: Account.defaultKey(for: .codex),
                groupID: f.harness.store.state.orderedGroups.first!.id, agent: .codex))
    }

    // MARK: - The offer itself

    /// The offer is made once. Declining is an answer: the flag is recorded either way, and a
    /// second Codex launch does not ask again.
    @Test func decliningIsRecordedAndWritesNothing() throws {
        let f = try makeFixture()
        defer { f.harness.tearDown() }
        let hooksPath = CodexHooksInstaller.hooksPath(configDir: f.configDir.path)
        #expect(!FileManager.default.fileExists(atPath: hooksPath))

        var asked = 0
        f.harness.controller.confirmInstallCodexHooks = { _ in asked += 1; return false }
        launchCodex(f)

        #expect(asked == 1)
        #expect(f.harness.store.state.hooksOffered.contains(.codex))
        #expect(!FileManager.default.fileExists(atPath: hooksPath))

        // Asked once, never again — even for the same account starting a second session.
        launchCodex(f)
        #expect(asked == 1)
    }

    @Test func acceptingInstallsTheHooks() throws {
        let f = try makeFixture()
        defer { f.harness.tearDown() }

        f.harness.controller.confirmInstallCodexHooks = { _ in true }
        launchCodex(f)

        #expect(f.installer.detect(configDir: f.configDir.path).producer == .tkzmux)
        #expect(f.harness.store.state.hooksOffered.contains(.codex))
    }

    /// Only `.none` triggers the automatic offer — an account whose hooks are already ours, or
    /// someone else's, has nothing to ask about from a launch.
    @Test func anAlreadyInstalledAccountIsNeverOffered() throws {
        let f = try makeFixture()
        defer { f.harness.tearDown() }
        try f.installer.install(configDir: f.configDir.path, accountKey: Account.defaultKey(for: .codex))

        var asked = false
        f.harness.controller.confirmInstallCodexHooks = { _ in asked = true; return true }
        launchCodex(f)

        #expect(!asked)
        // Nothing to answer, so the flag is left alone rather than falsely claiming the user was
        // asked — a later `.none` account (a second Codex config dir) must still get its turn.
        #expect(!f.harness.store.state.hooksOffered.contains(.codex))
    }

    // MARK: - The copy

    /// The two measured-fact corrections the ticket's own brief calls out: the sheet must say
    /// trust is still required (and never mention the trust-bypass flag), and must say Codex
    /// merges `config.toml` hooks rather than replacing them, when there are any to merge with.
    @Test func theCopyExplainsTrustAndNeverMentionsTheBypass() throws {
        let f = try makeFixture()
        defer { f.harness.tearDown() }

        var seen: CodexHooksInstallPlan?
        f.harness.controller.confirmInstallCodexHooks = { plan in seen = plan; return false }
        launchCodex(f)

        let plan = try #require(seen)
        #expect(plan.hooksPath == CodexHooksInstaller.hooksPath(configDir: f.configDir.path))
        #expect(plan.after.contains("tkzmux-hook"))
        #expect(plan.detection.configTomlHasHooks == false)
    }

    /// The alert body itself, exactly as `offerCodexHooks` builds it via the shared
    /// `MainWindowController.codexHooksAlertBody(plan:)` — split out precisely so this can be
    /// asserted without a real `NSAlert`, which never presents in a test process.
    @Test func alertCopySaysWhatTrustRequiresAndNeverTheBypassFlag() throws {
        let f = try makeFixture(configToml: "[[hooks.Stop]]\ncommand = \"echo hi\"\n")
        defer { f.harness.tearDown() }

        var seen: CodexHooksInstallPlan?
        f.harness.controller.confirmInstallCodexHooks = { plan in seen = plan; return false }
        launchCodex(f)

        let plan = try #require(seen)
        #expect(plan.detection.configTomlHasHooks, "a Stop hook already sat in config.toml")
        let body = MainWindowController.codexHooksAlertBody(plan: plan)

        // The wording contract itself, spelled out here so a future edit that drops the trust
        // sentence, drops the merge sentence, or reintroduces the bypass flag fails a test, not
        // just a reading of the code.
        #expect(body.lowercased().contains("trust"), "sheet copy must mention trust")
        #expect(body.contains("/hooks"), "sheet copy must point at Codex's own /hooks review")
        #expect(
            body.lowercased().contains("config.toml"),
            "a config.toml hook must be acknowledged, not silently overridden")
        #expect(
            !body.contains("--dangerously-bypass-hook-trust"),
            "sheet copy must never suggest the trust bypass")
    }

    /// The same sheet, for an account with no `config.toml` hooks at all: the merge sentence must
    /// not appear when there is nothing to merge with.
    @Test func alertCopyOmitsTheMergeSentenceWithNoExistingHooks() throws {
        let f = try makeFixture()
        defer { f.harness.tearDown() }

        var seen: CodexHooksInstallPlan?
        f.harness.controller.confirmInstallCodexHooks = { plan in seen = plan; return false }
        launchCodex(f)

        let plan = try #require(seen)
        #expect(!plan.detection.configTomlHasHooks)
        #expect(!MainWindowController.codexHooksAlertBody(plan: plan).lowercased().contains("config.toml"))
    }

    // MARK: - Settings page wiring
    //
    // `SettingsModel`'s hooks rows are fed by closures on `SettingsWindowController.Actions` that
    // only `MainWindowController.wireSettings()` populates for real; these render the actual
    // Settings page through that wiring, rather than through `SettingsWindowController.Actions`
    // built by hand, which is what `SettingsWindowTests` (the sibling ticket) already covers.

    /// With Codex registered, the "Hooks integration" section exists and its row reflects the
    /// detected state — nothing here without the wiring `wireSettings()` adds.
    @Test func settingsShowsTheHooksSectionOnceCodexIsRegistered() throws {
        let f = try makeFixture()
        defer { f.harness.tearDown() }
        f.harness.controller.presentSettings()

        let view = try #require(f.harness.controller.settings.viewForTesting)
        #expect(view.captionsForTesting.contains("Hooks integration"))
        let row = try #require(
            view.rowViewForTesting(.hooks(accountKey: Account.defaultKey(for: .codex))))
        // `.none` is what a freshly created fixture's account detects as: nothing written yet.
        #expect(row.detailForTesting.contains("Codex"), "the sentence must name the real adapter, not a placeholder")
        let button = try #require(view.controlForTesting(
            .hooks(accountKey: Account.defaultKey(for: .codex))) as? NSButton)
        #expect(button.title == "Configure\u{2026}")
    }

    /// A Claude-only registry must draw exactly what the page has always drawn: no hooks section,
    /// and the status-line row still present — proof that wiring real capabilities through
    /// `capabilitiesByAgent` did not regress the default (Claude-only) case the ticket requires to
    /// stay pixel-for-pixel unchanged.
    @Test func settingsPageWithOnlyClaudeIsUnchanged() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("tkzmux-claude-only-settings-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(
            at: home.appendingPathComponent(".claude", isDirectory: true), withIntermediateDirectories: true)

        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        harness.controller.agents = AgentIntegration(
            store: harness.store, directory: support, home: home.path,
            adapters: [.claude: ClaudeAdapter()])
        harness.controller.presentSettings()

        let view = try #require(harness.controller.settings.viewForTesting)
        #expect(!view.captionsForTesting.contains("Hooks integration"))
        #expect(view.controlForTesting(.hooks(accountKey: Account.defaultKey(for: .claude))) == nil)
        // The row this ticket must not have broken: Claude's own status-line integration.
        #expect(view.controlForTesting(.statusline(accountKey: Account.defaultKey(for: .claude))) != nil)
    }

    /// The row's button is not just cosmetic: pressing it reaches `CodexHooksInstaller` through
    /// `AgentIntegration`, exactly the way the status-line row's button reaches
    /// `StatuslineInstaller`. Driven through the button's own target/action, never `NSApp` or
    /// `performClick` — see the shared brief.
    @Test func settingsHooksButtonReachesTheInstaller() throws {
        let f = try makeFixture()
        defer { f.harness.tearDown() }
        f.harness.controller.confirmInstallCodexHooks = { _ in true }
        f.harness.controller.presentSettings()

        let view = try #require(f.harness.controller.settings.viewForTesting)
        let button = try #require(view.controlForTesting(
            .hooks(accountKey: Account.defaultKey(for: .codex))) as? NSButton)
        let action = try #require(button.action)
        let target = try #require(button.target as? NSObject)
        target.perform(action, with: button)

        #expect(f.installer.detect(configDir: f.configDir.path).producer == .tkzmux)
    }
}
