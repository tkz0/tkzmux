// ClaudeAdapterTests — TKZ-82: the first conformer to the `AgentAdapter` seam.
//
// Nothing here is new logic (see `ClaudeAdapter.swift`'s own header), so these tests are mostly
// about the wiring: does each `LaunchIntent` turn into the command line Claude actually expects, is
// the empty-environment case genuinely empty, and does the ported account discovery still behave
// exactly like the `TkzApp.ClaudeIntegration` code it replaces.

import Foundation
import Testing

@testable import AgentBridge

@Suite struct ClaudeAdapterTests {
    // MARK: - launchCommand

    @Test func newIsThePlainBinary() {
        #expect(ClaudeAdapter().launchCommand(.new) == "claude")
    }

    @Test func worktreeWithNoNameOmitsTheFlagsArgument() {
        #expect(ClaudeAdapter().launchCommand(.worktree(name: nil)) == "claude -w")
    }

    @Test func worktreeWithANameDiffersFromNoName() {
        let named = ClaudeAdapter().launchCommand(.worktree(name: "pricing"))
        let unnamed = ClaudeAdapter().launchCommand(.worktree(name: nil))
        #expect(named == "claude -w pricing")
        #expect(named != unnamed)
    }

    @Test func resumeCarriesTheConversationId() {
        #expect(
            ClaudeAdapter().launchCommand(.resume(conversationId: "abc-123"))
                == "claude --resume abc-123")
    }

    @Test func promptIsQuoted() {
        #expect(ClaudeAdapter().launchCommand(.prompt("fix the bug")) == "claude 'fix the bug'")
    }

    /// The one case that actually matters: a prompt containing a single quote must not be able to
    /// break out of the quoting and inject shell syntax.
    @Test func promptContainingASingleQuoteIsQuotedSafely() {
        let command = ClaudeAdapter().launchCommand(.prompt("it's broken"))
        // /bin/sh reads this as three concatenated pieces — 'it', an escaped quote, 's broken' —
        // which reassemble to the original text rather than letting the quote break out.
        #expect(command == "claude 'it'\\''s broken'")
    }

    // MARK: - environment(configDir:)

    @Test func environmentWithNoConfigDirIsGenuinelyEmpty() {
        let env = ClaudeAdapter().environment(configDir: nil)
        #expect(env.isEmpty)
    }

    @Test func environmentWithAConfigDirSetsOnlyThatVariable() {
        let env = ClaudeAdapter().environment(configDir: "/Users/x/.claude-work")
        #expect(env == ["CLAUDE_CONFIG_DIR": "/Users/x/.claude-work"])
    }

    // MARK: - capabilities

    @Test func capabilitiesIncludeEverything() {
        let capabilities = ClaudeAdapter().capabilities
        #expect(capabilities.contains(.hooks))
        #expect(capabilities.contains(.observation))
        #expect(capabilities.contains(.statusline))
        #expect(capabilities.contains(.transcriptUsage))
        #expect(capabilities.contains(.resume))
        #expect(capabilities.contains(.worktree))
    }

    // MARK: - discoverAccounts / accountLabels

    /// A temp `home` with `~/.claude`, `~/.claude-work` (carrying a `sessions` marker) and a decoy
    /// file that merely starts with `.claude-` but is not a directory.
    private func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeAdapterTests-\(UUID().uuidString)")
            .path
        let fm = FileManager.default
        try fm.createDirectory(atPath: (home as NSString).appendingPathComponent(".claude"),
            withIntermediateDirectories: true)
        let work = (home as NSString).appendingPathComponent(".claude-work")
        try fm.createDirectory(
            atPath: (work as NSString).appendingPathComponent("sessions"),
            withIntermediateDirectories: true)
        // A decoy: starts with the right prefix but is a plain file, not a directory with markers.
        fm.createFile(
            atPath: (home as NSString).appendingPathComponent(".claude-decoy"), contents: Data())
        return home
    }

    @Test func discoversThePrimaryAndMarkedSecondaryAccountsOnly() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let accounts = ClaudeAdapter().discoverAccounts(home: home, fileManager: .default)
        let keys = Set(accounts.map(\.key))
        #expect(keys == ["claude", "claude-work"])
        #expect(accounts.allSatisfy { $0.agent == .claude })
        let primary = accounts.first { $0.key == "claude" }
        #expect(primary?.configDir == (home as NSString).appendingPathComponent(".claude"))
    }

    @Test func accountLabelsOverlaysNamesAndSkipsAMalformedEntry() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let json = """
            {"labels": {"claude": "Personal", "claude-work": 42, "claude-blank": "   "}}
            """
        try json.write(
            toFile: (home as NSString).appendingPathComponent(".claude/dash-accounts.json"),
            atomically: true, encoding: .utf8)

        let labels = ClaudeAdapter().accountLabels(home: home, fileManager: .default)
        // A non-string value (`claude-work: 42`) and a blank-after-trim value (`claude-blank`) must
        // not throw and must not appear in the overlay.
        #expect(labels == ["claude": "Personal"])

        let accounts = ClaudeAdapter().discoverAccounts(home: home, fileManager: .default)
        #expect(accounts.first { $0.key == "claude" }?.label == "Personal")
        #expect(accounts.first { $0.key == "claude-work" }?.label == "claude-work")
        // Which of the two names a human wrote is what decides whether a usage snapshot may later
        // replace it, so the overlay hit has to be recorded and not just applied.
        #expect(accounts.first { $0.key == "claude" }?.labelIsConfigured == true)
        #expect(accounts.first { $0.key == "claude-work" }?.labelIsConfigured == false)
    }

    @Test func aMissingLabelsFileYieldsNoOverlayRatherThanThrowing() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(ClaudeAdapter().accountLabels(home: home, fileManager: .default).isEmpty)
    }

    // MARK: - isInstalled

    @Test func isInstalledFindsAnExecutableClaudeOnPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeAdapterTests-bin-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let binary = (dir as NSString).appendingPathComponent("claude")
        FileManager.default.createFile(atPath: binary, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)

        #expect(ClaudeAdapter().isInstalled(path: dir))
    }

    @Test func isInstalledIgnoresANonExecutableFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeAdapterTests-bin-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let binary = (dir as NSString).appendingPathComponent("claude")
        FileManager.default.createFile(atPath: binary, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary)

        #expect(!ClaudeAdapter().isInstalled(path: dir))
    }
}
