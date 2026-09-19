// AntigravityAdapterTests — the third adapter's own conformance, asserted against the facts
// measured off Antigravity CLI 1.2.7 and captured in `Fixtures/antigravity/`.
//
// Mirrors `CodexAdapterTests` case for case, including the negative assertions: a capability set is
// only worth testing if the things it does *not* claim are pinned too, because that is what stops a
// later edit quietly turning on a feature nobody measured.

import Foundation
import Testing
import TkzCore

@testable import AgentBridge

@Suite struct AntigravityAdapterTests {
    static func makeAdapter() -> AntigravityAdapter {
        AntigravityAdapter(supportDirectory: URL(fileURLWithPath: "/tmp/tkzmux-test"))
    }

    // MARK: Identity

    @Test("The kind, the display name and the binary are the measured ones")
    func identity() {
        let adapter = Self.makeAdapter()
        #expect(adapter.kind == .antigravity)
        #expect(adapter.kind.rawValue == "antigravity")
        #expect(adapter.displayName == "Antigravity")
        // The binary is `agy`. Not `antigravity` — and this matters beyond cosmetics: the shim is
        // installed under the binary's name so it can shadow it on PATH.
        #expect(adapter.binaryName == "agy")
        #expect(adapter.shimScript.binaryName == "agy")
        #expect(adapter.shimScript.resourceName == "agy.sh")
    }

    @Test("Antigravity is a known agent")
    func isKnown() {
        #expect(AgentKind.antigravity.isKnown)
        #expect(AgentKind.known.contains(.antigravity))
    }

    // MARK: Capabilities

    @Test("Capabilities are exactly what was measured — positively and negatively")
    func capabilities() {
        let capabilities = Self.makeAdapter().capabilities
        #expect(capabilities.contains(.hooks))
        #expect(capabilities.contains(.resume))
        // Measured absences, each with a reason in the adapter's own doc comment. A later edit
        // turning any of these on has to come with a fixture.
        #expect(!capabilities.contains(.observation), "writes no per-pid descriptor file")
        #expect(!capabilities.contains(.statusline), "no status-line mechanism")
        #expect(!capabilities.contains(.worktree), "no worktree flag in `agy --help`")
        #expect(
            !capabilities.contains(.transcriptUsage),
            "records no token or cost accounting anywhere — see the fixtures README")
    }

    // MARK: Launch commands

    @Test("Every launch intent resolves to the measured flag, including the ones that resolve to nil")
    func launchCommands() {
        let adapter = Self.makeAdapter()
        #expect(adapter.launchCommand(.new) == "agy")
        // `--conversation`, never `--continue`: the latter reopens the most recent conversation and
        // ignores the id, so it would resume the wrong one whenever the newest is not this row's.
        #expect(adapter.launchCommand(.resume(conversationId: "abc-123")) == "agy --conversation 'abc-123'")
        // `--prompt-interactive`, never `--prompt`: `--prompt`/`-p` is an alias for `--print`,
        // which runs one turn non-interactively and exits, leaving a dead pty.
        #expect(adapter.launchCommand(.prompt("hello")) == "agy --prompt-interactive 'hello'")
        let command = adapter.launchCommand(.prompt("hi"))
        #expect(command?.contains("--print") == false)
        // No worktree flag exists, so there is no command line to invent for that intent.
        #expect(adapter.launchCommand(.worktree(name: nil)) == nil)
        #expect(adapter.launchCommand(.worktree(name: "review")) == nil)
    }

    @Test("A prompt containing a single quote cannot break out of its own quoting")
    func promptQuotingIsInjectionSafe() {
        let adapter = Self.makeAdapter()
        let command = adapter.launchCommand(.prompt("it's; rm -rf /"))
        #expect(command == #"agy --prompt-interactive 'it'\''s; rm -rf /'"#)
        // The same treatment for a conversation id, which also lands in a command line.
        #expect(
            adapter.launchCommand(.resume(conversationId: "a'b"))
                == #"agy --conversation 'a'\''b'"#)
    }

    // MARK: Environment

    @Test("The environment is always empty, because no variable relocates the config dir")
    func environmentIsAlwaysEmpty() {
        let adapter = Self.makeAdapter()
        // Ten candidates were tested against a pristine HOME during the measurement spike and none
        // moved the tree; only HOME itself does, and tkzmux must not rewrite a child's HOME. So
        // there is no variable to export — for *any* config dir, not merely for nil.
        #expect(adapter.environment(configDir: nil).isEmpty)
        #expect(adapter.environment(configDir: "/Users/tester/.gemini").isEmpty)
        #expect(adapter.environment(configDir: "/somewhere/else").isEmpty)
    }

    // MARK: Accounts

    @Test("The config dir is ~/.gemini, and the key does not match its basename")
    func configDirectoryIsNotDerivedFromTheKey() throws {
        let adapter = Self.makeAdapter()
        let home = "/Users/tester"
        #expect(adapter.configDirectory(forAccountKey: "antigravity", home: home) == "/Users/tester/.gemini")
        // This is the whole reason the protocol requirement exists: the generic rule would send a
        // restored row's resume to a directory that does not exist.
        #expect(Account.configDirectory(forKey: "antigravity", home: home) == "/Users/tester/.antigravity")
        // A key this agent does not own gets nothing, rather than a path built from someone else's.
        #expect(adapter.configDirectory(forAccountKey: "claude", home: home) == nil)
        #expect(adapter.configDirectory(forAccountKey: "gemini", home: home) == nil)
    }

    @Test("Discovery is gated on the binary, so a stale ~/.gemini alone produces no account")
    func discoveryIsGatedOnThePath() throws {
        let adapter = Self.makeAdapter()
        let home = try ShimTestSupport.makeTempDirectory("antigravity-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let configDir = home.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // `~/.gemini` also survives on a machine that last ran the CLI Antigravity replaced, so
        // without the gate every such machine would grow a phantom account.
        #expect(adapter.discoverAccounts(home: home.path, fileManager: .default, searchPath: nil).isEmpty)
        #expect(
            adapter.discoverAccounts(
                home: home.path, fileManager: .default, searchPath: "/nowhere:/also-nowhere"
            ).isEmpty)

        // With the binary reachable, exactly one account — Antigravity cannot be pointed at a
        // second config dir, so there is never more than one.
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agy = bin.appendingPathComponent("agy")
        try Data("#!/bin/sh\n".utf8).write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)

        let accounts = adapter.discoverAccounts(
            home: home.path, fileManager: .default, searchPath: bin.path)
        #expect(accounts.count == 1)
        let account = try #require(accounts.first)
        #expect(account.key == "antigravity")
        #expect(account.agent == .antigravity)
        #expect(account.configDir == configDir.path)
    }

    @Test("A machine with the binary but no config dir yet gets no account either")
    func noConfigDirectoryMeansNoAccount() throws {
        let adapter = Self.makeAdapter()
        let home = try ShimTestSupport.makeTempDirectory("antigravity-home-empty")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agy = bin.appendingPathComponent("agy")
        try Data("#!/bin/sh\n".utf8).write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)

        // Installed but never run: inventing an account would put a resume on a directory that is
        // not there.
        #expect(adapter.discoverAccounts(home: home.path, fileManager: .default, searchPath: bin.path).isEmpty)
    }

    @Test("There are no account labels to read")
    func accountLabelsAreEmpty() {
        // No file anywhere lets a human name an account, and with one account per machine there is
        // nothing to disambiguate.
        #expect(Self.makeAdapter().accountLabels(home: "/Users/tester", fileManager: .default).isEmpty)
    }

    // MARK: The honest nils

    @Test("No observation watcher and no terminal-notification mapping")
    func measuredAbsences() {
        let adapter = Self.makeAdapter()
        #expect(adapter.makeObservationWatcher(configDirs: ["/tmp"], onEvent: { _ in }) == nil)
        // Measured, not merely unmeasured: a recorded pty session carried no OSC 9 at all.
        #expect(adapter.mapTerminalNotification(title: "Antigravity", body: "done") == nil)
    }

    @Test("Hooks are installed into a file, not injected per invocation")
    func hookInstallStrategy() {
        guard case .installed(let installer) = Self.makeAdapter().hookInstall else {
            Issue.record("Antigravity has no per-invocation settings flag; hooks must be installed")
            return
        }
        #expect(installer is AntigravityHooksInstaller)
    }

    @Test("The transcript provider reports no usage, matching the missing capability")
    func transcriptReportsNoUsage() async {
        let adapter = Self.makeAdapter()
        let usage = await adapter.transcript.usage(
            conversationId: "x", path: "/nonexistent",
            reader: TranscriptUsageReader(cacheDirectory: NSTemporaryDirectory()))
        #expect(usage == nil)
    }
}
