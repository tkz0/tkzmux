// CodexAdapterTests — TKZ-86 part 1: the second conformer to the `AgentAdapter` seam.
//
// Every fact asserted here is either a direct translation of the ticket's measured facts (launch
// commands, environment variable, capabilities) or the one deliberate design choice this adapter
// makes differently from the other supported agent's own: gating account discovery on the binary
// actually being on `PATH`. See `CodexAdapter.swift`'s own header for why.
import Foundation
import Testing

@testable import AgentBridge

@Suite struct CodexAdapterTests {
    private func makeAdapter() -> CodexAdapter {
        CodexAdapter(supportDirectory: FileManager.default.temporaryDirectory)
    }

    // MARK: - launchCommand

    @Test func newIsThePlainBinary() {
        #expect(makeAdapter().launchCommand(.new) == "codex")
    }

    @Test func resumeCarriesTheConversationId() {
        #expect(makeAdapter().launchCommand(.resume(conversationId: "abc-123")) == "codex resume abc-123")
    }

    @Test func promptIsQuoted() {
        #expect(makeAdapter().launchCommand(.prompt("fix the bug")) == "codex 'fix the bug'")
    }

    /// The one case that actually matters: a prompt containing a single quote must not be able to
    /// break out of the quoting and inject shell syntax.
    @Test func promptContainingASingleQuoteIsQuotedSafely() {
        let command = makeAdapter().launchCommand(.prompt("it's broken"))
        #expect(command == "codex 'it'\\''s broken'")
    }

    /// Codex has no worktree flag of its own, so this intent has no command line at all — `nil`,
    /// not a guessed flag.
    @Test func worktreeIntentReturnsNil() {
        #expect(makeAdapter().launchCommand(.worktree(name: nil)) == nil)
        #expect(makeAdapter().launchCommand(.worktree(name: "pricing")) == nil)
    }

    // MARK: - environment(configDir:)

    @Test func environmentWithNoConfigDirIsGenuinelyEmpty() {
        #expect(makeAdapter().environment(configDir: nil).isEmpty)
    }

    @Test func environmentWithAConfigDirSetsOnlyCodexHome() {
        let env = makeAdapter().environment(configDir: "/Users/x/.codex-work")
        #expect(env == ["CODEX_HOME": "/Users/x/.codex-work"])
    }

    // MARK: - capabilities

    @Test func capabilitiesAreExactlyHooksTranscriptUsageAndResume() {
        let capabilities = makeAdapter().capabilities
        #expect(capabilities.contains(.hooks))
        #expect(capabilities.contains(.transcriptUsage))
        #expect(capabilities.contains(.resume))
        #expect(!capabilities.contains(.observation))
        #expect(!capabilities.contains(.worktree))
        #expect(!capabilities.contains(.statusline))
    }

    // MARK: - mapTerminalNotification / makeObservationWatcher

    @Test func terminalNotificationIsNeverClassified() {
        #expect(makeAdapter().mapTerminalNotification(title: "Codex", body: "done") == nil)
    }

    @Test func noObservationWatcher() {
        #expect(makeAdapter().makeObservationWatcher(configDirs: [], onEvent: { _ in }) == nil)
    }

    // MARK: - accountLabels

    @Test func accountLabelsAreAlwaysEmpty() {
        #expect(makeAdapter().accountLabels(home: "/Users/x", fileManager: .default).isEmpty)
    }

    // MARK: - discoverAccounts, gated on PATH

    /// A temp `home` with `~/.codex`, `~/.codex-work` (carrying `config.toml`) and a decoy
    /// directory that starts with `.codex-` but has neither marker file.
    private func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAdapterTests-\(UUID().uuidString)").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: (home as NSString).appendingPathComponent(".codex"),
            withIntermediateDirectories: true)
        let work = (home as NSString).appendingPathComponent(".codex-work")
        try fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        fm.createFile(
            atPath: (work as NSString).appendingPathComponent("config.toml"), contents: Data())
        let decoy = (home as NSString).appendingPathComponent(".codex-decoy")
        try fm.createDirectory(atPath: decoy, withIntermediateDirectories: true)
        return home
    }

    /// A `PATH` directory containing an executable `codex`, for the "installed" half of the gate.
    private func makeBinDirWithCodex() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAdapterTests-bin-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let binary = (dir as NSString).appendingPathComponent("codex")
        FileManager.default.createFile(atPath: binary, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
        return dir
    }

    @Test func discoversAccountsWhenCodexIsOnPath() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let bin = try makeBinDirWithCodex()
        defer { try? FileManager.default.removeItem(atPath: bin) }

        let accounts = makeAdapter().discoverAccounts(home: home, fileManager: .default, searchPath: bin)
        let keys = Set(accounts.map(\.key))
        #expect(keys == ["codex", "codex-work"])
        #expect(accounts.allSatisfy { $0.agent == .codex })
        #expect(accounts.first { $0.key == "codex-work" }?.configDir
            == (home as NSString).appendingPathComponent(".codex-work"))
    }

    /// The gate is the point: a `PATH` with no `codex` on it at all must yield nothing, even though
    /// `~/.codex` and `~/.codex-work` are sitting right there on disk — a leftover config directory
    /// from an agent nobody has installed must not produce a phantom account.
    @Test func discoversNothingWhenCodexIsNotOnPath() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let emptyBin = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAdapterTests-empty-bin-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: emptyBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: emptyBin) }

        let accounts = makeAdapter().discoverAccounts(home: home, fileManager: .default, searchPath: emptyBin)
        #expect(accounts.isEmpty)
    }

    @Test func decoyDirectoryWithNoMarkerFileIsSkipped() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let bin = try makeBinDirWithCodex()
        defer { try? FileManager.default.removeItem(atPath: bin) }

        let accounts = makeAdapter().discoverAccounts(home: home, fileManager: .default, searchPath: bin)
        #expect(!accounts.map(\.key).contains("codex-decoy"))
    }
}
