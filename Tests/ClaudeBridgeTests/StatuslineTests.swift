// StatuslineTests — the producer (`tkzmux-hook statusline`) and the settings rewriter, driven as
// real processes, plus `StatuslineInstaller` against a temp config directory (TKZ-32).
//
// No test here touches the real HOME, `~/.claude`, or the real tkzmux application-support
// directory: the binary finds its own directory through `TKZMUX_SUPPORT_DIR`, which exists as this
// seam and as an escape hatch.
import Foundation
import Testing

@testable import ClaudeBridge

enum StatuslineTestSupport {
    enum Failure: Error { case binaryNotFound }

    /// The built `tkzmux-hook`, found the same way `HookBinaryTests` finds it.
    static func hookBinary() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["TKZMUX_HOOK_BIN"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
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
        throw Failure.binaryNotFound
    }

    static func tempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkzmux-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies the built hook into `<support>/bin/tkzmux-hook`, which is where an installed tkzmux
    /// has it and where `StatuslineInstaller` looks.
    static func installHook(into support: URL) throws -> URL {
        let bin = support.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let destination = bin.appendingPathComponent("tkzmux-hook")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: try hookBinary(), to: destination)
        return destination
    }

    static func environment(_ overrides: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("TKZMUX_") || key == "CLAUDE_CONFIG_DIR" {
            env.removeValue(forKey: key)
        }
        for (key, value) in overrides { env[key] = value }
        return env
    }

    @discardableResult
    static func run(
        _ binary: URL, _ arguments: [String], stdin: String = "", environment: [String: String]
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        DispatchQueue.global().async {
            if !stdin.isEmpty { input.fileHandleForWriting.write(Data(stdin.utf8)) }
            try? input.fileHandleForWriting.close()
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: out, encoding: .utf8) ?? "",
            String(data: err, encoding: .utf8) ?? ""
        )
    }

    /// A payload carrying every field the producer maps, in the shapes Claude Code actually sends
    /// (verified against its docs and a live capture on 2026-09-09).
    static let fullPayload = """
        {
          "session_id": "abc-123_XYZ",
          "session_name": "pricing work",
          "cwd": "/Users/x/dev/repo",
          "model": { "id": "claude-opus-5", "display_name": "Opus 5" },
          "workspace": {
            "current_dir": "/Users/x/dev/repo",
            "project_dir": "/Users/x/dev/repo",
            "git_worktree": "pricing",
            "repo": { "host": "github.com", "owner": "tkz0", "name": "tkzmux" }
          },
          "cost": { "total_cost_usd": 1.50 },
          "context_window": { "used_percentage": 62.4, "context_window_size": 200000 },
          "rate_limits": {
            "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
            "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
          },
          "pr": {
            "number": 412, "url": "https://github.com/tkz0/tkzmux/pull/412",
            "review_state": "approved"
          },
          "worktree": { "name": "pricing", "path": "/w/pricing" }
        }
        """

    static func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

@Suite struct StatuslineProducerTests {
    private func runProducer(
        support: URL, configDir: String = "/tmp/fakehome/.claude", stdin: String
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try StatuslineTestSupport.run(
            try StatuslineTestSupport.hookBinary(), ["statusline"], stdin: stdin,
            environment: StatuslineTestSupport.environment([
                "TKZMUX_SUPPORT_DIR": support.path, "CLAUDE_CONFIG_DIR": configDir,
            ]))
    }

    /// The whole mapping in one pass. Three of these differ from `SessionSidecar`'s shape and are
    /// translated by the producer rather than the reader: `workspace.repo` and `worktree` are
    /// objects on the wire but strings in the model, and `pr` arrives in Claude Code's
    /// `review_state` vocabulary while `PRInfo` is `gh`-shaped.
    @Test func writesBothSidecarsWithEveryFieldMapped() throws {
        let support = try StatuslineTestSupport.tempDirectory("producer")
        let result = try runProducer(support: support, stdin: StatuslineTestSupport.fullPayload)
        #expect(result.exitCode == 0)

        let statusline = support.appendingPathComponent("statusline")
        let usage = try StatuslineTestSupport.json(
            at: statusline.appendingPathComponent("usage-claude.json"))
        // Epoch seconds on the wire, ISO-8601 in the sidecar — that is what `UsageWindow` decodes.
        let fiveHour = usage["five_hour"] as? [String: Any]
        #expect(fiveHour?["used_percentage"] as? Int == 24)
        #expect(fiveHour?["resets_at"] as? String == "2025-02-01T16:00:00.000Z")
        #expect((usage["seven_day"] as? [String: Any])?["used_percentage"] as? Int == 41)
        #expect((usage["account"] as? [String: Any])?["key"] as? String == "claude")

        let context = try StatuslineTestSupport.json(
            at: statusline.appendingPathComponent("context-abc-123_XYZ.json"))
        #expect(context["session_id"] as? String == "abc-123_XYZ")
        #expect(context["account_key"] as? String == "claude")
        #expect(context["context_used_percentage"] as? Int == 62)
        #expect(context["session_name"] as? String == "pricing work")
        #expect((context["model"] as? [String: Any])?["display_name"] as? String == "Opus 5")
        #expect((context["workspace"] as? [String: Any])?["repo"] as? String == "tkz0/tkzmux")
        #expect(context["worktree"] as? String == "pricing")
        #expect(context["cost"] as? Double == 1.50)

        let pr = context["pr"] as? [String: Any]
        #expect(pr?["number"] as? Int == 412)
        #expect(pr?["state"] as? String == "OPEN")
        #expect(pr?["isDraft"] as? Bool == false)
        #expect(pr?["reviewDecision"] as? String == "APPROVED")
    }

    @Test func reviewStateMapsOntoTheGhVocabulary() throws {
        let cases: [(String, String?, Bool)] = [
            ("approved", "APPROVED", false),
            ("changes_requested", "CHANGES_REQUESTED", false),
            ("pending", "REVIEW_REQUIRED", false),
            ("draft", nil, true),
        ]
        for (wire, decision, isDraft) in cases {
            let support = try StatuslineTestSupport.tempDirectory("pr-\(wire)")
            let payload = StatuslineTestSupport.fullPayload
                .replacingOccurrences(of: "\"review_state\": \"approved\"",
                                      with: "\"review_state\": \"\(wire)\"")
            _ = try runProducer(support: support, stdin: payload)
            let context = try StatuslineTestSupport.json(
                at: support.appendingPathComponent("statusline/context-abc-123_XYZ.json"))
            let pr = context["pr"] as? [String: Any]
            #expect(pr?["reviewDecision"] as? String == decision, "review_state \(wire)")
            #expect(pr?["isDraft"] as? Bool == isDraft, "review_state \(wire)")
        }
    }

    /// A session id becomes part of a filename, so it is validated rather than escaped.
    @Test func aSessionIdThatIsNotAPlainIdentifierWritesNothing() throws {
        let support = try StatuslineTestSupport.tempDirectory("traversal")
        let payload = StatuslineTestSupport.fullPayload
            .replacingOccurrences(of: "\"abc-123_XYZ\"", with: "\"../../etc/pwned\"")
        _ = try runProducer(support: support, stdin: payload)

        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: support.appendingPathComponent("statusline").path)) ?? []
        #expect(!entries.contains { $0.hasPrefix("context-") })
        #expect(entries.contains("usage-claude.json"), "the usage sidecar is unaffected")
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("etc").path))
    }

    /// A payload with no quota at all — every session before its first API response — writes only
    /// the context sidecar. `rate_limits` is also absent for anyone not on a Claude.ai plan.
    @Test func aPayloadWithoutRateLimitsWritesOnlyContext() throws {
        let support = try StatuslineTestSupport.tempDirectory("noquota")
        let payload = """
            {"session_id":"s1","model":{"display_name":"Opus 5"},
             "context_window":{"used_percentage":null}}
            """
        _ = try runProducer(support: support, stdin: payload)
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: support.appendingPathComponent("statusline").path)) ?? []
        #expect(entries == ["context-s1.json"])
        // A null percentage is omitted rather than written as 0.
        let context = try StatuslineTestSupport.json(
            at: support.appendingPathComponent("statusline/context-s1.json"))
        #expect(context["context_used_percentage"] == nil)
    }

    @Test func theSecondIdenticalRunIsThrottled() throws {
        let support = try StatuslineTestSupport.tempDirectory("throttle")
        _ = try runProducer(support: support, stdin: StatuslineTestSupport.fullPayload)
        let path = support.appendingPathComponent("statusline/usage-claude.json").path
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date

        _ = try runProducer(support: support, stdin: StatuslineTestSupport.fullPayload)
        let after = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        #expect(before == after)
    }

    /// …but a changed percentage is written straight through, throttle or not.
    @Test func aChangedReadingIsNotThrottled() throws {
        let support = try StatuslineTestSupport.tempDirectory("throttle-change")
        _ = try runProducer(support: support, stdin: StatuslineTestSupport.fullPayload)
        let changed = StatuslineTestSupport.fullPayload
            .replacingOccurrences(of: "\"used_percentage\": 23.5", with: "\"used_percentage\": 44")
        _ = try runProducer(support: support, stdin: changed)

        let usage = try StatuslineTestSupport.json(
            at: support.appendingPathComponent("statusline/usage-claude.json"))
        #expect((usage["five_hour"] as? [String: Any])?["used_percentage"] as? Int == 44)
    }

    @Test func eachConfigDirGetsItsOwnUsageSidecar() throws {
        let support = try StatuslineTestSupport.tempDirectory("accounts")
        _ = try runProducer(
            support: support, configDir: "/tmp/h/.claude", stdin: StatuslineTestSupport.fullPayload)
        _ = try runProducer(
            support: support, configDir: "/tmp/h/.claude-work",
            stdin: StatuslineTestSupport.fullPayload)

        let entries = Set((try? FileManager.default.contentsOfDirectory(
            atPath: support.appendingPathComponent("statusline").path)) ?? [])
        #expect(entries.contains("usage-claude.json"))
        #expect(entries.contains("usage-claude-work.json"))
    }

    // MARK: Hand-off — the one thing that must never break

    /// The hard invariant: whatever happens to the sidecars, the user's own statusline still runs.
    /// A wrapped command's stdout, its stdin and its exit status all pass through untouched.
    @Test func theWrappedCommandSeesTheSameBytesAndItsOutputPassesThrough() throws {
        let support = try StatuslineTestSupport.tempDirectory("handoff")
        let statusline = support.appendingPathComponent("statusline", isDirectory: true)
        try FileManager.default.createDirectory(at: statusline, withIntermediateDirectories: true)
        let captured = support.appendingPathComponent("child.stdin")
        try writePrevious(
            "cat > '\(captured.path)'; printf 'WRAPPED\\n'; exit 7",
            to: statusline.appendingPathComponent("previous-claude.json"))

        let result = try runProducer(support: support, stdin: StatuslineTestSupport.fullPayload)

        #expect(result.stdout == "WRAPPED\n")
        #expect(result.exitCode == 7, "the wrapped command's exit status is the statusline's")
        let seen = try String(contentsOf: captured, encoding: .utf8)
        #expect(seen == StatuslineTestSupport.fullPayload)
    }

    /// A command with the nested quoting a real statusline has — this is why the previous command
    /// lives in a companion file rather than being spliced into our own command string.
    @Test func aCommandWithNestedQuotesSurvives() throws {
        let support = try StatuslineTestSupport.tempDirectory("quotes")
        let statusline = support.appendingPathComponent("statusline", isDirectory: true)
        try FileManager.default.createDirectory(at: statusline, withIntermediateDirectories: true)
        try writePrevious(
            #"bash -c 'printf "%s\n" "it'"'"'s fine"'"#,
            to: statusline.appendingPathComponent("previous-claude.json"))

        let result = try runProducer(support: support, stdin: StatuslineTestSupport.fullPayload)
        #expect(result.stdout == "it's fine\n")
    }

    /// An unparseable payload must not stop the hand-off — a crash here blanks the statusline.
    @Test func garbageOnStdinStillRunsTheWrappedCommand() throws {
        let support = try StatuslineTestSupport.tempDirectory("garbage")
        let statusline = support.appendingPathComponent("statusline", isDirectory: true)
        try FileManager.default.createDirectory(at: statusline, withIntermediateDirectories: true)
        try writePrevious(
            "printf 'STILL-RAN\\n'", to: statusline.appendingPathComponent("previous-claude.json"))

        let result = try runProducer(support: support, stdin: "not json at all")
        #expect(result.stdout == "STILL-RAN\n")
        #expect(result.exitCode == 0)
    }

    /// With nothing wrapped, tkzmux prints its own plain line rather than nothing at all — an empty
    /// statusline would look like a broken install.
    @Test func withNoPreviousCommandItPrintsItsOwnLine() throws {
        let support = try StatuslineTestSupport.tempDirectory("fallback")
        let result = try runProducer(support: support, stdin: StatuslineTestSupport.fullPayload)
        #expect(result.stdout == "Opus 5 · repo · 62%\n")
    }

    /// `{"statusLine": null}` records "there was nothing here" — the file exists, the command does
    /// not, and the fallback line is right.
    @Test func aRecordedAbsenceIsNotACommand() throws {
        let support = try StatuslineTestSupport.tempDirectory("absent")
        let statusline = support.appendingPathComponent("statusline", isDirectory: true)
        try FileManager.default.createDirectory(at: statusline, withIntermediateDirectories: true)
        try Data(#"{"statusLine": null}"#.utf8).write(
            to: statusline.appendingPathComponent("previous-claude.json"))

        let result = try runProducer(support: support, stdin: StatuslineTestSupport.fullPayload)
        #expect(result.stdout == "Opus 5 · repo · 62%\n")
        #expect(result.exitCode == 0)
    }

    private func writePrevious(_ command: String, to url: URL) throws {
        let document = ["statusLine": ["type": "command", "command": command]]
        try JSONSerialization.data(withJSONObject: document).write(to: url)
    }
}

@Suite struct StatuslineSettingsRewriteTests {
    private let settings = """
        {
          "permissions": { "allow": ["Bash(ls:*)"], "deny": [] },
          "statusLine": {
            "type": "command",
            "command": "bash -c 'echo hi'",
            "refreshInterval": 5,
            "padding": 2
          },
          "model": "opus",
          "someNumber": 1.50
        }
        """

    private func rewrite(_ arguments: [String], bin: String = "/opt/tkzmux bin") throws
        -> (exitCode: Int32, stdout: String, stderr: String)
    {
        try StatuslineTestSupport.run(
            try StatuslineTestSupport.hookBinary(), ["statusline-settings"] + arguments,
            environment: StatuslineTestSupport.environment(["TKZMUX_BIN": bin]))
    }

    /// The reason the rewrite goes through the hook's own parser rather than `JSONSerialization`:
    /// settings.json is a file the user reads and diffs, so key order and number source text have
    /// to survive a round trip untouched.
    @Test func aRoundTripPreservesEveryUnrelatedKeyItsOrderAndItsFormatting() throws {
        let directory = try StatuslineTestSupport.tempDirectory("rewrite")
        let path = directory.appendingPathComponent("settings.json")
        try Data(settings.utf8).write(to: path)

        let installed = try rewrite([path.path, "install", "-"])
        #expect(installed.exitCode == 0)
        try Data(installed.stdout.utf8).write(to: path)

        let saved = directory.appendingPathComponent("previous.json")
        try Data(#"""
            {"statusLine":{"type":"command","command":"bash -c 'echo hi'","refreshInterval":5,"padding":2}}
            """#.utf8).write(to: saved)
        let restored = try rewrite([path.path, "uninstall", saved.path])
        #expect(restored.exitCode == 0)

        let before = try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any]
        let after = try JSONSerialization.jsonObject(with: Data(restored.stdout.utf8)) as? [String: Any]
        #expect(NSDictionary(dictionary: before ?? [:]) == NSDictionary(dictionary: after ?? [:]))
        #expect(restored.stdout.contains("\"someNumber\": 1.50"), "1.50 must not become 1.5")
        // Key order, which JSONSerialization would have lost.
        let keys = ["permissions", "statusLine", "model", "someNumber"]
        var cursor = restored.stdout.startIndex
        for key in keys {
            guard let found = restored.stdout.range(of: "\"\(key)\"", range: cursor..<restored.stdout.endIndex)
            else { Issue.record("\(key) out of order"); return }
            cursor = found.upperBound
        }
    }

    @Test func installKeepsRefreshIntervalAndPadding() throws {
        let directory = try StatuslineTestSupport.tempDirectory("keep")
        let path = directory.appendingPathComponent("settings.json")
        try Data(settings.utf8).write(to: path)

        let result = try rewrite([path.path, "install", "-"])
        let root = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        let statusLine = root?["statusLine"] as? [String: Any]
        #expect(statusLine?["refreshInterval"] as? Int == 5)
        #expect(statusLine?["padding"] as? Int == 2)
        #expect(statusLine?["command"] as? String == "\"/opt/tkzmux bin/tkzmux-hook\" statusline")
    }

    /// A settings.json that does not exist yet is an empty document, not an error.
    @Test func installIntoAMissingSettingsFileProducesAWholeDocument() throws {
        let directory = try StatuslineTestSupport.tempDirectory("missing")
        let result = try rewrite([directory.appendingPathComponent("settings.json").path, "install", "-"])
        #expect(result.exitCode == 0)
        let root = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        #expect((root?["statusLine"] as? [String: Any])?["type"] as? String == "command")
    }

    @Test func uninstallingARecordedAbsenceRemovesTheKeyEntirely() throws {
        let directory = try StatuslineTestSupport.tempDirectory("remove-key")
        let path = directory.appendingPathComponent("settings.json")
        try Data(settings.utf8).write(to: path)
        let saved = directory.appendingPathComponent("previous.json")
        try Data(#"{"statusLine": null}"#.utf8).write(to: saved)

        let result = try rewrite([path.path, "uninstall", saved.path])
        let root = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        #expect(root?["statusLine"] == nil)
        #expect(root?["model"] as? String == "opus")
    }

    /// Every failure prints nothing, so a caller can never write a truncated settings file.
    @Test func everyFailurePathIsSilentAndNonZero() throws {
        let directory = try StatuslineTestSupport.tempDirectory("failures")
        let broken = directory.appendingPathComponent("broken.json")
        try Data("{ this is not json".utf8).write(to: broken)

        let invalid = try rewrite([broken.path, "install", "-"])
        #expect(invalid.exitCode == 1)
        #expect(invalid.stdout.isEmpty)

        let noCompanion = try rewrite([
            directory.appendingPathComponent("settings.json").path, "uninstall",
            directory.appendingPathComponent("nope.json").path,
        ])
        #expect(noCompanion.exitCode == 1)
        #expect(noCompanion.stdout.isEmpty)

        let unknownMode = try rewrite([broken.path, "wat", "-"])
        #expect(unknownMode.exitCode == 1)
        #expect(unknownMode.stdout.isEmpty)
    }
}

@Suite struct StatuslineInstallerTests {
    /// Builds a support directory with the real hook in `bin/`, plus a config dir holding
    /// `settings.json` with the given contents (or none).
    private func fixture(_ label: String, settings: String?) throws -> (
        installer: StatuslineInstaller, support: URL, configDir: String
    ) {
        let root = try StatuslineTestSupport.tempDirectory(label)
        let support = root.appendingPathComponent("support", isDirectory: true)
        _ = try StatuslineTestSupport.installHook(into: support)
        let configDir = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if let settings {
            try Data(settings.utf8).write(to: configDir.appendingPathComponent("settings.json"))
        }
        return (StatuslineInstaller(directory: support), support, configDir.path)
    }

    private let claudeHud = """
        {
          "model": "opus",
          "statusLine": { "type": "command", "command": "node ~/hud.js", "refreshInterval": 5 }
        }
        """

    @Test func detectsNothingAnExistingCommandAndOurOwn() throws {
        let empty = try fixture("detect-none", settings: "{}")
        #expect(empty.installer.detect(configDir: empty.configDir) == .none)

        let other = try fixture("detect-other", settings: claudeHud)
        #expect(other.installer.detect(configDir: other.configDir) == .other(command: "node ~/hud.js"))

        try other.installer.install(configDir: other.configDir, accountKey: "claude")
        #expect(other.installer.detect(configDir: other.configDir) == .tkzmux)
        #expect(other.installer.isInstalled(configDir: other.configDir))
    }

    /// A config dir with no settings.json at all — the clean-machine case.
    @Test func installsIntoAConfigDirWithNoSettingsFile() throws {
        let f = try fixture("install-bare", settings: nil)
        #expect(f.installer.detect(configDir: f.configDir) == .none)
        try f.installer.install(configDir: f.configDir, accountKey: "claude")
        #expect(f.installer.detect(configDir: f.configDir) == .tkzmux)

        // …and undoing it leaves no `statusLine` behind, rather than an empty one.
        try f.installer.uninstall(configDir: f.configDir, accountKey: "claude")
        let root = try StatuslineTestSupport.json(
            at: URL(fileURLWithPath: StatuslineInstaller.settingsPath(configDir: f.configDir)))
        #expect(root["statusLine"] == nil)
    }

    /// The headline promise: whatever was there comes back exactly.
    @Test func uninstallRestoresThePreviousCommandVerbatim() throws {
        let f = try fixture("round-trip", settings: claudeHud)
        let path = URL(fileURLWithPath: StatuslineInstaller.settingsPath(configDir: f.configDir))
        let before = try Data(contentsOf: path)

        try f.installer.install(configDir: f.configDir, accountKey: "claude")
        try f.installer.uninstall(configDir: f.configDir, accountKey: "claude")

        let after = try Data(contentsOf: path)
        let a = try JSONSerialization.jsonObject(with: before) as? [String: Any] ?? [:]
        let b = try JSONSerialization.jsonObject(with: after) as? [String: Any] ?? [:]
        #expect(NSDictionary(dictionary: a) == NSDictionary(dictionary: b))
        #expect(f.installer.detect(configDir: f.configDir) == .other(command: "node ~/hud.js"))
    }

    /// Refuses rather than clobbering a change the user made after the install.
    @Test func uninstallRefusesWhenTheCommandIsNoLongerOurs() throws {
        let f = try fixture("rewired", settings: claudeHud)
        try f.installer.install(configDir: f.configDir, accountKey: "claude")
        try Data(#"{"statusLine":{"type":"command","command":"something else"}}"#.utf8)
            .write(to: URL(fileURLWithPath: StatuslineInstaller.settingsPath(configDir: f.configDir)))

        #expect(throws: StatuslineInstallerError.notInstalled) {
            try f.installer.uninstall(configDir: f.configDir, accountKey: "claude")
        }
    }

    /// A missing companion file is *lost state*, not evidence there was nothing here. Deleting the
    /// key on that basis would silently throw away the user's own statusline.
    @Test func uninstallRefusesWhenTheSavedCommandIsGone() throws {
        let f = try fixture("lost", settings: claudeHud)
        try f.installer.install(configDir: f.configDir, accountKey: "claude")
        try FileManager.default.removeItem(at: f.installer.previousURL(accountKey: "claude"))

        #expect(throws: (any Error).self) {
            try f.installer.uninstall(configDir: f.configDir, accountKey: "claude")
        }
        #expect(f.installer.detect(configDir: f.configDir) == .tkzmux, "settings.json is untouched")
    }

    /// Two config dirs are installed and undone independently.
    @Test func twoAccountsGetTwoCompanionFiles() throws {
        let f = try fixture("two", settings: claudeHud)
        let second = URL(fileURLWithPath: f.configDir)
            .deletingLastPathComponent().appendingPathComponent(".claude-work", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: second.appendingPathComponent("settings.json"))

        try f.installer.install(configDir: f.configDir, accountKey: "claude")
        try f.installer.install(configDir: second.path, accountKey: "claude-work")

        #expect(FileManager.default.fileExists(
            atPath: f.installer.previousURL(accountKey: "claude").path))
        #expect(FileManager.default.fileExists(
            atPath: f.installer.previousURL(accountKey: "claude-work").path))

        try f.installer.uninstall(configDir: f.configDir, accountKey: "claude")
        #expect(f.installer.detect(configDir: f.configDir) == .other(command: "node ~/hud.js"))
        #expect(f.installer.detect(configDir: second.path) == .tkzmux, "the other account is untouched")
    }

    /// The consent sheet's before/after, built without writing anything.
    @Test func planDescribesTheChangeAndWritesNothing() throws {
        let f = try fixture("plan", settings: claudeHud)
        let path = URL(fileURLWithPath: StatuslineInstaller.settingsPath(configDir: f.configDir))
        let before = try Data(contentsOf: path)

        let plan = try f.installer.plan(configDir: f.configDir, accountKey: "claude")
        #expect(plan.producer == .other(command: "node ~/hud.js"))
        #expect(plan.before?.contains("node ~/hud.js") == true)
        #expect(plan.after.contains("tkzmux-hook"))
        #expect(plan.after.contains("\"refreshInterval\""), "an existing refresh interval is kept")
        #expect(try Data(contentsOf: path) == before)
    }

    @Test func planReportsNoPreviousCommandWhenThereIsNone() throws {
        let f = try fixture("plan-bare", settings: "{}")
        let plan = try f.installer.plan(configDir: f.configDir, accountKey: "claude")
        #expect(plan.producer == .none)
        #expect(plan.before == nil)
    }
}
