// StatuslineConsentTests — the one place tkzmux edits a file the user owns, so the gate around it
// gets its own tests (TKZ-32).
//
// The sheet itself is an `NSAlert`, which never returns in a test process; `MainWindowController`
// exposes `confirmInstallStatusline` / `confirmRemoveStatusline` as the injection points, the same
// pattern "Remove Shell Integration" already uses.
import AppKit
import ClaudeBridge
import Foundation
import Testing
import TkzCore

@testable import TkzApp

@Suite @MainActor struct StatuslineConsentTests {
    /// A window controller wired to a `ClaudeIntegration` whose support directory is a temp dir
    /// with the real `tkzmux-hook` in `bin/`, plus a config dir holding `settings.json`.
    private struct Fixture {
        var harness: MainWindowControllerTests.Harness
        var support: URL
        var configDir: URL
        var settings: URL
        var installer: StatuslineInstaller
    }

    private func hookBinary() throws -> URL {
        if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            let candidate = bundle.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("tkzmux-hook")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        for argument in ProcessInfo.processInfo.arguments {
            guard let range = argument.range(of: ".xctest") else { continue }
            let products = URL(fileURLWithPath: String(argument[argument.startIndex..<range.upperBound]))
                .deletingLastPathComponent()
            let candidate = products.appendingPathComponent("tkzmux-hook")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func makeFixture(settingsJSON: String) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("tkzmux-consent-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let bin = support.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.copyItem(at: try hookBinary(), to: bin.appendingPathComponent("tkzmux-hook"))

        // The account's config dir has to be `<home>/.claude` for `Account.configDirectory(forKey:)`
        // to find it, so the fixture gives the integration its own fake home.
        let home = root.appendingPathComponent("home", isDirectory: true)
        let configDir = home.appendingPathComponent(".claude", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        let settings = configDir.appendingPathComponent("settings.json")
        try Data(settingsJSON.utf8).write(to: settings)

        let harness = MainWindowControllerTests.makeHarness()
        harness.controller.claude = ClaudeIntegration(
            store: harness.store, directory: support, home: home.path)
        // The fixture state already carries a `claude` account pointing at a directory that is not
        // this test's, and `ClaudeIntegration` deliberately does not overwrite an account the store
        // already knows. Point it at the fixture's config dir, and clear the selection so the
        // controller falls back to the primary account rather than the fixture row's.
        harness.store.update { state in
            state.selection = nil
            state.setAccount(
                Account(key: Account.defaultKey, configDir: configDir.path, label: "claude"))
        }
        return Fixture(
            harness: harness, support: support, configDir: configDir, settings: settings,
            installer: StatuslineInstaller(directory: support))
    }

    private let claudeHud = """
        {"model":"opus","statusLine":{"type":"command","command":"node ~/hud.js","refreshInterval":5}}
        """

    /// The offer is made once. Declining is an answer: the flag is recorded either way, so the app
    /// does not ask again on every launch.
    @Test func decliningIsRecordedAndWritesNothing() throws {
        let f = try makeFixture(settingsJSON: "{}")
        defer { f.harness.tearDown() }
        let before = try Data(contentsOf: f.settings)

        var asked = 0
        f.harness.controller.confirmInstallStatusline = { _ in asked += 1; return false }
        f.harness.controller.offerStatuslineIfNeeded()

        #expect(asked == 1)
        #expect(f.harness.store.state.statuslineOffered)
        #expect(try Data(contentsOf: f.settings) == before)

        // Asked once, never again.
        f.harness.controller.offerStatuslineIfNeeded()
        #expect(asked == 1)
    }

    @Test func acceptingInstallsTheStatusLine() throws {
        let f = try makeFixture(settingsJSON: "{}")
        defer { f.harness.tearDown() }

        f.harness.controller.confirmInstallStatusline = { _ in true }
        f.harness.controller.offerStatuslineIfNeeded()

        #expect(f.installer.detect(configDir: f.configDir.path) == .tkzmux)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: f.settings)) as? [String: Any]
        let command = (root?["statusLine"] as? [String: Any])?["command"] as? String
        #expect(command?.contains("tkzmux-hook") == true)
        #expect(command?.hasSuffix("statusline") == true)
    }

    /// The headline case: someone already running claude-hud must be *offered* the wrap, not
    /// skipped. Skipping `.other` would make the passthrough unreachable from the UI.
    @Test func anExistingStatusLineIsOfferedTheWrapAndShownTheBeforeAndAfter() throws {
        let f = try makeFixture(settingsJSON: claudeHud)
        defer { f.harness.tearDown() }

        var seen: StatuslineInstallPlan?
        f.harness.controller.confirmInstallStatusline = { plan in seen = plan; return true }
        f.harness.controller.offerStatuslineIfNeeded()

        #expect(seen?.producer == .other(command: "node ~/hud.js"))
        #expect(seen?.before?.contains("node ~/hud.js") == true)
        #expect(seen?.after.contains("tkzmux-hook") == true)
        #expect(f.installer.detect(configDir: f.configDir.path) == .tkzmux)
        // The wrapped command is kept so the producer can run it and put it back.
        let saved = try Data(contentsOf: f.installer.previousURL(accountKey: "claude"))
        #expect(String(data: saved, encoding: .utf8)?.contains("node ~/hud.js") == true)
    }

    /// Already ours: nothing to ask, and the flag is set so startup stops considering it.
    @Test func anAlreadyInstalledStatusLineIsNeverOffered() throws {
        let f = try makeFixture(settingsJSON: "{}")
        defer { f.harness.tearDown() }
        try f.installer.install(configDir: f.configDir.path, accountKey: "claude")

        var asked = false
        f.harness.controller.confirmInstallStatusline = { _ in asked = true; return true }
        f.harness.controller.offerStatuslineIfNeeded()

        #expect(!asked)
        #expect(f.harness.store.state.statuslineOffered)
    }

    /// The menu command is a toggle, and removing puts the original back exactly.
    @Test func theMenuCommandTogglesAndRestoresTheOriginal() throws {
        let f = try makeFixture(settingsJSON: claudeHud)
        defer { f.harness.tearDown() }
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: f.settings)) as? [String: Any]

        f.harness.controller.confirmInstallStatusline = { _ in true }
        f.harness.controller.statusLineIntegration()
        #expect(f.installer.detect(configDir: f.configDir.path) == .tkzmux)

        f.harness.controller.confirmRemoveStatusline = { true }
        f.harness.controller.statusLineIntegration()

        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: f.settings)) as? [String: Any]
        #expect(NSDictionary(dictionary: before ?? [:]) == NSDictionary(dictionary: after ?? [:]))
    }

    /// `Remove Shell Integration` deletes `bin/`, which is exactly where `settings.json` points, so
    /// it has to undo the statusline first or leave the user with a command that no longer exists.
    @Test func removingShellIntegrationUninstallsTheStatusLineFirst() throws {
        let f = try makeFixture(settingsJSON: claudeHud)
        defer { f.harness.tearDown() }
        f.harness.controller.confirmInstallStatusline = { _ in true }
        f.harness.controller.statusLineIntegration()
        #expect(f.installer.detect(configDir: f.configDir.path) == .tkzmux)

        f.harness.controller.confirmRemoveShellIntegration = { true }
        f.harness.controller.removeShellIntegration()

        #expect(f.installer.detect(configDir: f.configDir.path) == .other(command: "node ~/hud.js"))
    }

    // MARK: - A statusline pointing at somebody else's tkzmux-hook

    /// `settings.json` naming a `tkzmux-hook` from another build reads as installed while its
    /// sidecars go to that hook's own support directory — the quota band just stays empty, with no
    /// error anywhere (2026-09-11). The repair is silent and needs no consent: the user already
    /// agreed to tkzmux owning `statusLine` here, and only the binary named changes.
    @Test func aStaleHookIsRepairedWithoutAsking() throws {
        let f = try makeFixture(settingsJSON: claudeHud)
        defer { f.harness.tearDown() }
        f.harness.controller.confirmInstallStatusline = { _ in true }
        f.harness.controller.statusLineIntegration()
        let record = try Data(contentsOf: f.installer.previousURL(accountKey: "claude"))

        // Another build re-points it, keeping the rest of the object.
        try Data(
            """
            {"model":"opus","statusLine":{"type":"command",\
            "command":"/opt/elsewhere/support/bin/tkzmux-hook statusline","refreshInterval":5}}
            """.utf8
        ).write(to: f.settings)
        #expect(
            f.installer.detect(configDir: f.configDir.path)
                == .stale(command: "/opt/elsewhere/support/bin/tkzmux-hook statusline"))

        var asked = false
        f.harness.controller.confirmInstallStatusline = { _ in asked = true; return true }
        #expect(f.harness.controller.claude?.repairStaleStatuslines() == ["claude"])

        #expect(!asked)
        #expect(f.installer.detect(configDir: f.configDir.path) == .tkzmux)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: f.settings)) as? [String: Any]
        let statusLine = root?["statusLine"] as? [String: Any]
        #expect((statusLine?["command"] as? String)?.contains(f.support.path) == true)
        #expect(statusLine?["refreshInterval"] as? Int == 5, "the rest of the object is untouched")
        #expect(root?["model"] as? String == "opus")
        #expect(
            try Data(contentsOf: f.installer.previousURL(accountKey: "claude")) == record,
            "the record of what tkzmux replaced is not re-derived from a tkzmux command")

        // And the integration still comes off cleanly, back to claude-hud.
        f.harness.controller.confirmRemoveStatusline = { true }
        f.harness.controller.statusLineIntegration()
        #expect(f.installer.detect(configDir: f.configDir.path) == .other(command: "node ~/hud.js"))
    }

    /// A stale hook is installed, not absent: the offer must not treat it as a free slot and
    /// record tkzmux as the thing to restore.
    @Test func aStaleHookIsNeverOfferedAnInstall() throws {
        let f = try makeFixture(settingsJSON: """
            {"statusLine":{"type":"command","command":"/opt/elsewhere/bin/tkzmux-hook statusline"}}
            """)
        defer { f.harness.tearDown() }

        var asked = false
        f.harness.controller.confirmInstallStatusline = { _ in asked = true; return true }
        f.harness.controller.offerStatuslineIfNeeded()
        #expect(!asked)

        // The menu toggle reads it as on and takes the remove path rather than offering an install.
        var offeredRemoval = false
        f.harness.controller.confirmRemoveStatusline = { offeredRemoval = true; return true }
        f.harness.controller.statusLineIntegration()
        #expect(offeredRemoval)
        #expect(!asked)
        // Nothing was ever recorded for this account, so the removal refuses rather than guessing —
        // the existing `previousMissing` rule, now reachable through a stale hook too.
        #expect(
            f.installer.detect(configDir: f.configDir.path)
                == .stale(command: "/opt/elsewhere/bin/tkzmux-hook statusline"))
    }
}
