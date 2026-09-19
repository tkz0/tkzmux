// CodexHooksInstallerTests.
//
// The nested shape under test — `{"hooks": {"<Event>": [{"hooks": [{"type": "command",
// "command": …}]}]}}` — is not a guess: `Fixtures/codex/hooks-json-verified.json` is the exact
// document that was written to `$CODEX_HOME/hooks.json` and driven, with
// `--dangerously-bypass-hook-trust`, against a real logged-in codex-cli 0.155.0, and its `Stop`
// hook fired. A flatter shape (no group, or a group with no `hooks` wrapper) was tried in the same
// session and did not fire — see the installer's own header comment. Tests that need "an existing
// document" build on that fixture rather than retyping the shape by hand; only structurally
// unrelated fixtures (an unrelated top-level key, another tool's command, garbage text) are
// hand-written, because there is nothing to capture them from.
//
// Everything here is pure Swift-value manipulation against a temp directory; unlike the statusline
// installer's own tests, nothing here shells out to a built binary, because this installer never
// runs one.
import Foundation
import Testing

@testable import AgentBridge

private enum Fixtures {
    static var codexDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/AgentBridgeTests/CodexHooksInstallerTests.swift
            .deletingLastPathComponent()          // Tests/AgentBridgeTests
            .appendingPathComponent("Fixtures/codex")
    }

    /// The exact document verified to make Codex actually run a hook (see this file's header).
    static func hooksJSONVerified() throws -> String {
        try String(
            contentsOf: codexDirectory.appendingPathComponent("hooks-json-verified.json"),
            encoding: .utf8)
    }

    /// The support directory baked into `hooks-json-verified.json`'s command string. Only ever
    /// used to build an installer for read-only `detect` calls in these tests — never for
    /// `install`, which would try to create `codex-hooks/` underneath it, a path this test suite
    /// has no business writing to.
    static let verifiedSupportDirectory = URL(
        fileURLWithPath: "/Users/tester/Library/Application Support/tkzmux")
}

private enum Support {
    static func tempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkzmux-codex-hooks-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fresh `(support directory, codex home, installer)` triple, so tests never share state.
    static func makeInstaller(label: String) throws -> (support: URL, configDir: URL, installer: CodexHooksInstaller) {
        let support = try tempDirectory("support-\(label)")
        let configDir = try tempDirectory("home-\(label)")
        return (support, configDir, CodexHooksInstaller(directory: support))
    }

    static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// One group under one managed event, in the verified nested shape.
    static func group(command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command]]]
    }
}

@Suite struct CodexHooksInstallerDetectionTests {
    @Test func noFileIsNone() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "none")
        let detection = installer.detect(configDir: configDir.path)
        #expect(detection.producer == .none)
    }

    @Test func fullyInstalledIsTkzmux() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "ours")
        try installer.install(configDir: configDir.path, accountKey: "codex")
        let detection = installer.detect(configDir: configDir.path)
        #expect(detection.producer == .tkzmux)
        #expect(installer.isInstalled(configDir: configDir.path))
    }

    @Test func otherToolsHookIsOther() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "other")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        try Support.write(
            """
            {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/some-other-tool Stop"}]}]}}
            """, to: hooksPath)
        let detection = installer.detect(configDir: configDir.path)
        #expect(detection.producer == .other)
    }

    /// A `tkzmux-hook` command is present for a managed event, but it comes from a different
    /// support directory than this build's own — an old install, a `.build` binary, a second
    /// checkout.
    @Test func differentInstallPathIsStale() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "stale")
        let otherSupport = try Support.tempDirectory("stale-other-support")
        let otherInstaller = CodexHooksInstaller(directory: otherSupport)
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        var hooks: [String: Any] = [:]
        for event in CodexHooksInstaller.events {
            hooks[event] = [Support.group(command: otherInstaller.command(for: event))]
        }
        let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks])
        try data.write(to: hooksPath)

        let detection = installer.detect(configDir: configDir.path)
        guard case .stale(let paths) = detection.producer else {
            Issue.record("expected .stale, got \(detection.producer)")
            return
        }
        #expect(paths.contains(otherInstaller.hookBinary.path))
        #expect(!installer.isInstalled(configDir: configDir.path))
    }

    /// The verified fixture's own `Stop` entry, filled out with this installer's own commands for
    /// every other managed event (built programmatically, not retyped), must be recognised as
    /// fully ours — proving the group/hooks nesting is read correctly, not just written correctly.
    @Test func detectRecognizesTheVerifiedShapeAsOurs() throws {
        let configDir = try Support.tempDirectory("verified-detect-home")
        let installer = CodexHooksInstaller(directory: Fixtures.verifiedSupportDirectory)

        var doc = try #require(
            JSONSerialization.jsonObject(with: Data(Fixtures.hooksJSONVerified().utf8))
                as? [String: Any])
        var hooks = try #require(doc["hooks"] as? [String: Any])
        for event in CodexHooksInstaller.events where event != "Stop" {
            hooks[event] = [Support.group(command: installer.command(for: event))]
        }
        doc["hooks"] = hooks

        let hooksPath = configDir.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: doc).write(to: hooksPath)

        #expect(installer.detect(configDir: configDir.path).producer == .tkzmux)
    }

    @Test func configTomlHooksBlockIsReported() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "toml")
        let tomlPath = configDir.appendingPathComponent("config.toml")
        try Support.write(
            """
            [model]
            name = "example"

            [[hooks.Stop]]

            [[hooks.Stop.hooks]]
            type = "command"
            command = "notify-send done"
            """, to: tomlPath)
        let detection = installer.detect(configDir: configDir.path)
        #expect(detection.configTomlHasHooks)
    }

    @Test func noConfigTomlHooksBlockIsNotReported() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "toml-none")
        let tomlPath = configDir.appendingPathComponent("config.toml")
        try Support.write("[model]\nname = \"example\"\n", to: tomlPath)
        let detection = installer.detect(configDir: configDir.path)
        #expect(!detection.configTomlHasHooks)
    }

    /// The trust ledger is never parsed for its hash — only text-scanned for whether it mentions
    /// this account's `hooks.json` path at all. See `CodexHooksTrustState`'s own doc comment for
    /// why that is the most this installer will ever claim to know.
    @Test func trustLedgerTextScan() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "trust")
        #expect(installer.detect(configDir: configDir.path).trust == .unknown)

        let statePath = configDir.appendingPathComponent("hooks.state")
        try Support.write("{\"entries\": []}", to: statePath)
        #expect(installer.detect(configDir: configDir.path).trust == .doesNotMentionOurConfig)

        let hooksPath = CodexHooksInstaller.hooksPath(configDir: configDir.path)
        try Support.write("{\"entries\": [{\"source\": \"\(hooksPath)\"}]}", to: statePath)
        #expect(installer.detect(configDir: configDir.path).trust == .mentionsOurConfig)
    }
}

@Suite struct CodexHooksInstallerInstallTests {
    @Test func installCreatesEveryManagedEvent() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "create")
        try installer.install(configDir: configDir.path, accountKey: "codex")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        let text = Support.read(hooksPath)
        #expect(text != nil)
        let json = try #require(JSONSerialization.jsonObject(with: Data(text!.utf8)) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: Any])
        for event in CodexHooksInstaller.events {
            let groups = try #require(hooks[event] as? [[String: Any]])
            #expect(groups.count == 1)
            let entries = try #require(groups[0]["hooks"] as? [[String: Any]])
            #expect(entries.count == 1)
            #expect(entries[0]["command"] as? String == installer.command(for: event))
            #expect(entries[0]["type"] as? String == "command")
        }
    }

    /// The verified fixture's own `Stop` group *is* a `tkzmux-hook Stop` command, just from
    /// another install's support directory. Replaying its exact shape (substituting only the
    /// event name in the command string it already proved makes Codex run a hook) across all
    /// eight managed events builds a realistic "this whole file moved" scenario, and installing
    /// over it must repoint every group's entry in place rather than duplicate it — exercising the
    /// group/hooks nesting inside `repair` against the real captured shape, not a hand-written one.
    @Test func installRepairsTheVerifiedFixtureShapeAcrossEveryEvent() throws {
        let (support, configDir, installer) = try Support.makeInstaller(label: "repair-verified")
        let hooksPath = configDir.appendingPathComponent("hooks.json")

        let fixtureDoc = try #require(
            JSONSerialization.jsonObject(with: Data(Fixtures.hooksJSONVerified().utf8))
                as? [String: Any])
        let fixtureHooks = try #require(fixtureDoc["hooks"] as? [String: Any])
        let stopGroup = try #require((fixtureHooks["Stop"] as? [[String: Any]])?.first)
        let stopEntries = try #require(stopGroup["hooks"] as? [[String: Any]])
        let templateCommand = try #require(stopEntries.first?["command"] as? String)
        #expect(templateCommand.hasSuffix(" Stop"))

        var hooks: [String: Any] = [:]
        for event in CodexHooksInstaller.events {
            let eventCommand = String(templateCommand.dropLast("Stop".count)) + event
            hooks[event] = [Support.group(command: eventCommand)]
        }
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: hooksPath)

        guard case .stale = installer.detect(configDir: configDir.path).producer else {
            Issue.record("expected the replayed verified shape to detect as .stale before install")
            return
        }

        try installer.install(configDir: configDir.path, accountKey: "codex")

        #expect(installer.detect(configDir: configDir.path).producer == .tkzmux)
        let previous = support.appendingPathComponent("codex-hooks/previous-codex.json")
        #expect(!FileManager.default.fileExists(atPath: previous.path))

        let json = try #require(
            JSONSerialization.jsonObject(with: Data(Support.read(hooksPath)!.utf8)) as? [String: Any])
        let resultHooks = try #require(json["hooks"] as? [String: Any])
        let stopGroups = try #require(resultHooks["Stop"] as? [[String: Any]])
        #expect(stopGroups.count == 1)
        let entries = try #require(stopGroups[0]["hooks"] as? [[String: Any]])
        #expect(entries.first?["command"] as? String == installer.command(for: "Stop"))
    }

    /// A real third party's hook (not a `tkzmux-hook` invocation at all) must survive install as
    /// its own sibling group alongside ours — the counterpart to the fixture-based stale/repair
    /// test above, which exercises the other branch of the same nested lookup.
    @Test func appendsANewGroupAlongsideAThirdPartyHook() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "append-third-party")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        try Support.write(
            """
            {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "notify-send done"}]}]}}
            """, to: hooksPath)

        try installer.install(configDir: configDir.path, accountKey: "codex")

        let json = try #require(
            JSONSerialization.jsonObject(with: Data(Support.read(hooksPath)!.utf8)) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: Any])
        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stopGroups.count == 2)

        let firstEntries = try #require(stopGroups[0]["hooks"] as? [[String: Any]])
        #expect(firstEntries.first?["command"] as? String == "notify-send done")

        let secondEntries = try #require(stopGroups[1]["hooks"] as? [[String: Any]])
        #expect(secondEntries.first?["command"] as? String == installer.command(for: "Stop"))
    }

    /// Every unrelated top-level key survives install untouched.
    @Test func preservesUnrelatedTopLevelKeys() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "unrelated")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        try Support.write(
            """
            {"someFutureSetting": {"nested": [1, 2, 3]}}
            """, to: hooksPath)

        try installer.install(configDir: configDir.path, accountKey: "codex")

        let json = try #require(
            JSONSerialization.jsonObject(with: Data(Support.read(hooksPath)!.utf8)) as? [String: Any])
        let nested = try #require((json["someFutureSetting"] as? [String: Any])?["nested"] as? [Int])
        #expect(nested == [1, 2, 3])
        #expect(json["hooks"] != nil)
    }

    /// Installing twice must not duplicate entries.
    @Test func installTwiceIsIdempotent() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "idempotent")
        try installer.install(configDir: configDir.path, accountKey: "codex")
        try installer.install(configDir: configDir.path, accountKey: "codex")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(Support.read(hooksPath)!.utf8)) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: Any])
        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stopGroups.count == 1)
    }

    /// A stale entry (ours, but from a different support directory) is repointed in place by
    /// `install`, not duplicated, and does not touch the previous-record machinery.
    @Test func installRepairsAStaleEntry() throws {
        let (support, configDir, installer) = try Support.makeInstaller(label: "repair")
        let otherSupport = try Support.tempDirectory("repair-other-support")
        let otherInstaller = CodexHooksInstaller(directory: otherSupport)
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        var hooks: [String: Any] = [:]
        for event in CodexHooksInstaller.events {
            hooks[event] = [Support.group(command: otherInstaller.command(for: event))]
        }
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: hooksPath)

        try installer.install(configDir: configDir.path, accountKey: "codex")

        #expect(installer.detect(configDir: configDir.path).producer == .tkzmux)
        let previous = support.appendingPathComponent("codex-hooks/previous-codex.json")
        #expect(!FileManager.default.fileExists(atPath: previous.path))

        let json = try #require(
            JSONSerialization.jsonObject(with: Data(Support.read(hooksPath)!.utf8)) as? [String: Any])
        let stopGroups = try #require((json["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stopGroups.count == 1)
        let entries = try #require(stopGroups[0]["hooks"] as? [[String: Any]])
        #expect(entries.first?["command"] as? String == installer.command(for: "Stop"))
    }

    /// Malformed JSON: refuse to write rather than clobber something that could not be parsed.
    @Test func malformedHooksJSONIsRefused() throws {
        let (support, configDir, installer) = try Support.makeInstaller(label: "malformed")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        let garbage = "{not valid json at all"
        try Support.write(garbage, to: hooksPath)

        #expect(throws: CodexHooksInstallerError.hooksFileUnusable(path: hooksPath.path)) {
            try installer.install(configDir: configDir.path, accountKey: "codex")
        }

        #expect(Support.read(hooksPath) == garbage)
        let previous = support.appendingPathComponent("codex-hooks/previous-codex.json")
        #expect(!FileManager.default.fileExists(atPath: previous.path))
    }

    /// A managed event whose existing value is not an array of groups is just as unusable as a
    /// syntax error — this installer has no safe way to append to it.
    @Test func nonArrayEventValueIsRefused() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "nonarray")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        try Support.write(
            """
            {"hooks": {"Stop": "not-an-array"}}
            """, to: hooksPath)

        #expect(throws: CodexHooksInstallerError.hooksFileUnusable(path: hooksPath.path)) {
            try installer.install(configDir: configDir.path, accountKey: "codex")
        }
    }

    /// A group whose own `hooks` value is not an array is refused the same way — this installer
    /// only ever reads or writes entries through that array.
    @Test func nonArrayGroupHooksValueIsRefused() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "nonarray-group")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        try Support.write(
            """
            {"hooks": {"Stop": [{"hooks": "not-an-array"}]}}
            """, to: hooksPath)

        #expect(throws: CodexHooksInstallerError.hooksFileUnusable(path: hooksPath.path)) {
            try installer.install(configDir: configDir.path, accountKey: "codex")
        }
    }
}

@Suite struct CodexHooksInstallerUninstallTests {
    /// Install then uninstall restores the file byte-for-byte, including an unrelated top-level
    /// key and a user's own `Stop` hook.
    @Test func roundTripRestoresByteForByte() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "roundtrip")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        let original = """
            {
              "unrelatedTopLevelKey": true,
              "hooks": {
                "Stop": [
                  {
                    "hooks": [
                      {
                        "type": "command",
                        "command": "notify-send done"
                      }
                    ]
                  }
                ]
              }
            }
            """
        try Support.write(original, to: hooksPath)

        try installer.install(configDir: configDir.path, accountKey: "codex")
        #expect(Support.read(hooksPath) != original)

        try installer.uninstall(configDir: configDir.path, accountKey: "codex")
        #expect(Support.read(hooksPath) == original)
    }

    /// When there was no file at all, uninstall removes the one install created.
    @Test func roundTripRemovesAFileItCreated() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "roundtrip-created")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        try installer.install(configDir: configDir.path, accountKey: "codex")
        #expect(FileManager.default.fileExists(atPath: hooksPath.path))

        try installer.uninstall(configDir: configDir.path, accountKey: "codex")
        #expect(!FileManager.default.fileExists(atPath: hooksPath.path))
    }

    /// A user's own hook for an event we also hook survives both install and uninstall, as its own
    /// group, untouched.
    @Test func userHookSurvivesInstallAndUninstall() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "survives")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        let original = """
            {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "notify-send done"}]}]}}
            """
        try Support.write(original, to: hooksPath)

        try installer.install(configDir: configDir.path, accountKey: "codex")
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(Support.read(hooksPath)!.utf8)) as? [String: Any])
        let stopGroups = try #require((json["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stopGroups.count == 2)

        try installer.uninstall(configDir: configDir.path, accountKey: "codex")
        #expect(Support.read(hooksPath) == original)
    }

    @Test func uninstallWithoutInstallThrowsNotInstalled() throws {
        let (_, configDir, installer) = try Support.makeInstaller(label: "not-installed")
        #expect(throws: CodexHooksInstallerError.notInstalled) {
            try installer.uninstall(configDir: configDir.path, accountKey: "codex")
        }
    }

    /// Ours on disk, but the companion record is gone: refuse rather than guess what to restore.
    @Test func uninstallWithoutPreviousRecordThrows() throws {
        let (support, configDir, installer) = try Support.makeInstaller(label: "missing-record")
        try installer.install(configDir: configDir.path, accountKey: "codex")
        let previous = support.appendingPathComponent("codex-hooks/previous-codex.json")
        try FileManager.default.removeItem(at: previous)

        #expect(throws: CodexHooksInstallerError.previousMissing(path: previous.path)) {
            try installer.uninstall(configDir: configDir.path, accountKey: "codex")
        }
    }
}

@Suite struct CodexHooksInstallerPreviousRecordTests {
    /// `install` writes `previous-<accountKey>.json` before touching `hooks.json`, and it records
    /// the literal absence sentinel when there was no file — not a reconstruction.
    @Test func recordsAbsenceWhenNoFileExisted() throws {
        let (support, configDir, installer) = try Support.makeInstaller(label: "absence")
        try installer.install(configDir: configDir.path, accountKey: "codex")
        let previous = support.appendingPathComponent("codex-hooks/previous-codex.json")
        #expect(Support.read(previous)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null")
    }

    /// `install` writes the previous document byte-for-byte into the record.
    @Test func recordsTheRealPriorDocument() throws {
        let (support, configDir, installer) = try Support.makeInstaller(label: "real-record")
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        let original = """
            {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "notify-send done"}]}]}}
            """
        try Support.write(original, to: hooksPath)
        try installer.install(configDir: configDir.path, accountKey: "codex")

        let previous = support.appendingPathComponent("codex-hooks/previous-codex.json")
        #expect(Support.read(previous) == original)
    }

    /// The protection this all exists for: a record naming a real previous document must never be
    /// traded down for one naming an absence. Simulated here without a first real install, so the
    /// only thing under test is `shouldRecord`'s refusal, not the surrounding install machinery.
    @Test func neverTradesARealRecordDownToAnAbsence() throws {
        let (support, configDir, installer) = try Support.makeInstaller(label: "no-trade-down")
        let codexHooksDir = support.appendingPathComponent("codex-hooks")
        try FileManager.default.createDirectory(at: codexHooksDir, withIntermediateDirectories: true)
        let previous = codexHooksDir.appendingPathComponent("previous-codex.json")
        let realPriorDocument = """
            {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "some-real-tool Stop"}]}]}}
            """
        try Support.write(realPriorDocument, to: previous)

        // hooks.json itself does not exist right now, so a naive install would try to record
        // "null" (absence) over the real record above. It must not.
        try installer.install(configDir: configDir.path, accountKey: "codex")

        #expect(Support.read(previous) == realPriorDocument)
    }
}
