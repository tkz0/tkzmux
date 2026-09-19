// SessionLauncherTests — M5.2: start, reopen, resume, close, remove, worktree refresh.
//
// Everything runs against `SpyTerminalHost`: what is asserted is which host call was made, with
// which cwd and env, and what the store says afterwards. Directories are real (a temp tree), so
// the "first directory that exists" rule is exercised against the file system rather than mocked.

import AppKit
import AgentBridge
import Foundation
import Synchronization
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct SessionLauncherTests {

    typealias Spy = MainWindowControllerTests.SpyTerminalHost

    /// A temp tree: `<base>/home`, `<base>/repo`, `<base>/repo/.claude/worktrees/wt`.
    struct Tree {
        let base: URL
        var home: String { base.appending(path: "home").path }
        var repo: String { base.appending(path: "repo").path }
        var worktree: String { base.appending(path: "repo/.claude/worktrees/wt").path }

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appending(path: "tkzmux-launcher-\(UUID().uuidString)", directoryHint: .isDirectory)
            for path in [home, repo, worktree] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
        }

        func tearDown() { try? FileManager.default.removeItem(at: base) }
    }

    @MainActor
    struct Harness {
        let tree: Tree
        let store: AppStore
        let host: Spy
        let launcher: SessionLauncher
        let group: GroupID

        func session(_ id: SessionID) -> Session? { store.state.sessions[id] }
    }

    static func makeHarness(
        adapters: [AgentKind: any AgentAdapter] = [.claude: ClaudeAdapter()]
    ) throws -> Harness {
        let tree = try Tree()
        var state = AppState()
        let group = state.addGroup(name: "repo", repoRoot: tree.repo)
        let store = AppStore(state: state)
        let host = Spy()
        let launcher = SessionLauncher(store: store, host: host, home: tree.home, adapters: adapters)
        return Harness(tree: tree, store: store, host: host, launcher: launcher, group: group.id)
    }

    // MARK: - The adapter seam

    /// Defined only here, never in production code — proves `environment(accountKey:bootCommand:)`
    /// and `resume(_:)` both go through whichever adapter the row's account names, rather than a
    /// literal `CLAUDE_CONFIG_DIR` or `claude --resume`.
    private struct StubTranscriptProvider: TranscriptProvider {
        func locate(conversationId: String, configDir: String, fileManager: FileManager) -> String? { nil }
        func summary(path: String) throws -> TranscriptSummary { TranscriptSummary() }
        func usage(conversationId: String, path: String, reader: TranscriptUsageReader) async -> SessionUsage? { nil }
        func searchIndex(path: String, existing: TranscriptIndex?) throws -> TranscriptIndex {
            try TranscriptIndex.build(path: path, existing: existing)
        }
    }

    private struct StubAdapter: AgentAdapter {
        static let kind = AgentKind(rawValue: "stub")
        var kind: AgentKind { Self.kind }
        var displayName: String { "Stub" }
        var binaryName: String { "stub-agent" }
        var capabilities: AgentCapabilities { [.resume] }

        func launchCommand(_ intent: LaunchIntent) -> String? {
            switch intent {
            case .resume(let conversationId): return "stub-agent --resume \(conversationId)"
            case .new: return "stub-agent"
            case .worktree, .prompt: return nil
            }
        }
        /// Its own variable name, `STUB_CONFIG_DIR` — proof that `SessionLauncher` no longer
        /// hard-codes `CLAUDE_CONFIG_DIR` for every account regardless of agent.
        func environment(configDir: String?) -> [String: String] {
            guard let configDir else { return [:] }
            return ["STUB_CONFIG_DIR": configDir]
        }
        func discoverAccounts(home: String, fileManager: FileManager) -> [Account] { [] }
        func accountLabels(home: String, fileManager: FileManager) -> [String: String] { [:] }
        func mapHook(_ payload: HookPayload) -> AgentEvent? { nil }
        func mapTerminalNotification(title: String, body: String) -> AgentEvent? { nil }
        func makeObservationWatcher(
            configDirs: [String], onEvent: @escaping @Sendable (ObservationEvent) -> Void
        ) -> (any AgentObservationWatcher)? { nil }
        var transcript: any TranscriptProvider { StubTranscriptProvider() }
        var hookInstall: HookInstallStrategy { .perInvocation }
        var shimScript: ShimResource { ShimResource(binaryName: "stub-agent", resourceName: "stub.sh") }
    }

    @Test("start: the account's environment comes from its own adapter, not a hard-coded CLAUDE_CONFIG_DIR")
    func startEnvironmentComesFromTheAdapter() throws {
        let h = try Self.makeHarness(adapters: [.claude: ClaudeAdapter(), StubAdapter.kind: StubAdapter()])
        defer { h.tree.tearDown() }
        h.store.update {
            $0.setAccount(Account(key: "stub-work", configDir: "/somewhere/stub", label: "Stub", agent: StubAdapter.kind))
        }
        let spec = NewSessionMenu.Launch(
            kind: .repoRoot, command: "", cwd: h.tree.repo, accountKey: "stub-work", groupID: h.group)
        _ = h.launcher.start(spec)
        #expect(h.host.opened.first?.env["STUB_CONFIG_DIR"] == "/somewhere/stub")
        #expect(h.host.opened.first?.env["CLAUDE_CONFIG_DIR"] == nil)
        // The generic re-export pair rides alongside the adapter's own variable, so the shell
        // wrapper can win the race against the user's rc files whatever the agent turns out to be.
        #expect(h.host.opened.first?.env["TKZMUX_ENV_STUB_CONFIG_DIR"] == "/somewhere/stub")
        #expect(h.host.opened.first?.env["TKZMUX_REEXPORT"] == "STUB_CONFIG_DIR")
    }

    @Test("resume: the boot command comes from the row's own adapter, not a literal claude --resume")
    func resumeCommandComesFromTheAdapter() throws {
        let h = try Self.makeHarness(adapters: [.claude: ClaudeAdapter(), StubAdapter.kind: StubAdapter()])
        defer { h.tree.tearDown() }
        let id = SessionID.generate()
        h.store.update { state in
            var session = Session(
                id: id, groupID: h.group, cwd: h.tree.repo, repoRoot: h.tree.repo,
                agent: StubAdapter.kind, accountKey: "stub-work", conversationId: "conv-1")
            session.live = nil
            state.sessions[id] = session
        }
        h.store.flush()
        #expect(h.launcher.resume(id) == .success(.resumed(conversationId: "conv-1")))
        #expect(h.host.bootCommands == ["stub-agent --resume conv-1"])
    }

    /// A restored row: in the store with no live state, as `state.json` hands it over.
    static func restoredRow(
        _ h: Harness, cwd: String? = nil, worktree: String? = nil, accountKey: String = "claude",
        conversationId: String? = "sid-1"
    ) -> SessionID {
        let id = SessionID.generate()
        h.store.update { state in
            var session = Session(
                id: id, groupID: h.group, cwd: cwd ?? h.tree.repo, repoRoot: h.tree.repo,
                worktreePath: worktree, isWorktree: worktree != nil,
                accountKey: accountKey, conversationId: conversationId)
            session.live = nil
            state.sessions[id] = session
        }
        h.store.flush()
        return id
    }

    // MARK: - Start

    @Test("start: the account's config dir and the boot command reach the child")
    func startEnvironment() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let spec = NewSessionMenu.Launch(
            kind: .worktree, command: "claude -w review", cwd: h.tree.repo, accountKey: "claude-work",
            groupID: h.group)
        let result = h.launcher.start(spec)
        h.store.flush()
        let id = try #require(try? result.get())
        let opened = try #require(h.host.opened.first)
        #expect(opened.id == id)
        #expect(opened.cwd == h.tree.repo)
        // No account in the store: derived from the key, `~/.<key>` under the launcher's home.
        #expect(opened.env["CLAUDE_CONFIG_DIR"] == h.tree.home + "/.claude-work")
        #expect(opened.env["TKZMUX_BOOT_COMMAND"] == "claude -w review")
        #expect(h.session(id)?.accountKey == "claude-work")
        #expect(h.session(id)?.status == .idle)
        #expect(h.store.state.selection == id)
    }

    @Test("start: a known account's configured dir wins over the derived one; the primary is pinned; none chosen = unset")
    func startKnownAccount() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        h.store.update { $0.setAccount(Account(key: "claude-work", configDir: "/somewhere/else", label: "Work")) }
        _ = h.launcher.start(NewSessionMenu.Launch(kind: .repoRoot, command: "claude", cwd: h.tree.repo, accountKey: "claude-work", groupID: h.group))
        _ = h.launcher.start(NewSessionMenu.Launch(kind: .repoRoot, command: "claude", cwd: h.tree.repo, accountKey: "claude", groupID: h.group))
        _ = h.launcher.start(NewSessionMenu.Launch(kind: .repoRoot, command: "claude", cwd: h.tree.repo, accountKey: nil, groupID: h.group))
        #expect(h.host.opened[0].env["CLAUDE_CONFIG_DIR"] == "/somewhere/else")
        #expect(h.host.opened[0].env["TKZMUX_ENV_CLAUDE_CONFIG_DIR"] == "/somewhere/else")
        #expect(h.host.opened[0].env["TKZMUX_REEXPORT"] == "CLAUDE_CONFIG_DIR")
        #expect(h.host.opened[1].env["CLAUDE_CONFIG_DIR"] == h.tree.home + "/.claude")
        #expect(h.host.opened[2].env["CLAUDE_CONFIG_DIR"] == nil)
        #expect(h.host.opened[2].env["TKZMUX_ENV_CLAUDE_CONFIG_DIR"] == nil)
        #expect(h.host.opened[2].env["TKZMUX_REEXPORT"] == nil)
    }

    @Test("reopen and resume always pin the row's recorded account, the primary included")
    func reopenPinsThePrimary() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = Self.restoredRow(h, accountKey: "claude", conversationId: "abc")
        #expect(h.launcher.resume(id) == .success(.resumed(conversationId: "abc")))
        // A row that ran on `~/.claude` must resume there even if the user's shell defaults
        // elsewhere — the recorded key is the truth, and the wrapper re-export enforces it.
        #expect(h.host.opened.first?.env["CLAUDE_CONFIG_DIR"] == h.tree.home + "/.claude")
        #expect(h.host.opened.first?.env["TKZMUX_ENV_CLAUDE_CONFIG_DIR"] == h.tree.home + "/.claude")
        #expect(h.host.opened.first?.env["TKZMUX_REEXPORT"] == "CLAUDE_CONFIG_DIR")
    }

    @Test("start: a missing directory fails before the host is asked")
    func startMissingDirectory() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let missing = h.tree.base.appending(path: "nope").path
        let result = h.launcher.start(NewSessionMenu.Launch(kind: .repoRoot, command: "claude", cwd: missing, accountKey: nil, groupID: h.group))
        #expect(result == .failure(.missingDirectory(missing)))
        #expect(h.host.opened.isEmpty)
        #expect(h.store.state.sessions.isEmpty)
    }

    // MARK: - Reopen

    @Test("reopen: a restored row comes back from its .ghsnap, in its directory, on its account")
    func reopenFromDisk() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = Self.restoredRow(h, accountKey: "claude-work")
        h.host.savedSnapshots[id] = Data("saved".utf8)

        let outcome = h.launcher.reopen(id)
        h.store.flush()
        #expect(outcome == .success(.reopened(directory: h.tree.repo, restoredContent: true)))
        let restored = try #require(h.host.restored.first)
        #expect(restored.id == id)
        #expect(restored.snapshot == Data("saved".utf8))
        #expect(restored.cwd == h.tree.repo)
        #expect(restored.env["CLAUDE_CONFIG_DIR"] == h.tree.home + "/.claude-work")
        #expect(h.host.opened.isEmpty)
        #expect(h.session(id)?.live?.shellPid == 4343)
        #expect(h.session(id)?.status == .idle)
        // Nothing typed: reopen is content + prompt, resume is the caller's decision.
        #expect(h.host.ran.isEmpty)

        // A second reopen is a no-op: the shell is there.
        #expect(h.launcher.reopen(id) == .success(.alreadyRunning))
        #expect(h.host.restored.count == 1)
    }

    @Test("reopen: no snapshot → a fresh shell; the live grid of a hung-up row wins over the disk")
    func reopenSources() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let fresh = Self.restoredRow(h)
        #expect(h.launcher.reopen(fresh) == .success(.reopened(directory: h.tree.repo, restoredContent: false)))
        #expect(h.host.opened.map(\.id) == [fresh])

        // The store lost `live` while the host still holds the grid (a stale event, a crash of the
        // bookkeeping): reopen prefers that live grid over anything on disk.
        h.store.update { $0.setLive(nil, for: fresh) }
        h.store.flush()
        #expect(h.session(fresh)?.live == nil)
        h.host.savedSnapshots[fresh] = Data("stale".utf8)
        #expect(h.launcher.reopen(fresh) == .success(.reopened(directory: h.tree.repo, restoredContent: true)))
        #expect(h.host.restored.last?.snapshot == Data("live:\(fresh.rawValue)".utf8))
    }

    @Test("reopen: a snapshot that fails to decode falls back to a fresh shell")
    func reopenBadSnapshot() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = Self.restoredRow(h)
        h.host.savedSnapshots[id] = Data("garbage".utf8)
        h.host.restoreError = TerminalHostError.unknownSession("bad")
        #expect(h.launcher.reopen(id) == .success(.reopened(directory: h.tree.repo, restoredContent: false)))
        #expect(h.host.opened.map(\.id) == [id])
        #expect(h.session(id)?.live != nil)
    }

    @Test("reopen: a worktree that is gone falls back to the repo root and clears the badge")
    func reopenLostWorktree() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let kept = Self.restoredRow(h, worktree: h.tree.worktree)
        #expect(h.launcher.reopen(kept) == .success(.reopened(directory: h.tree.worktree, restoredContent: false)))
        h.store.flush()
        #expect(h.session(kept)?.isWorktree == true)

        let lost = Self.restoredRow(h, worktree: h.tree.base.appending(path: "repo/.claude/worktrees/gone").path)
        #expect(h.launcher.reopen(lost) == .success(.reopened(directory: h.tree.repo, restoredContent: false)))
        h.store.flush()
        #expect(h.session(lost)?.isWorktree == false)
        #expect(h.session(lost)?.worktreePath?.hasSuffix("gone") == true, "the path is kept for the record")
        #expect(h.host.opened.last?.cwd == h.tree.repo)
    }

    @Test("reopen: every directory missing → a failure naming the first one tried, no row change")
    func reopenNothingExists() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let missing = h.tree.base.appending(path: "vanished").path
        let id = SessionID.generate()
        h.store.update { state in
            state.sessions[id] = Session(id: id, groupID: h.group, cwd: missing, repoRoot: missing, accountKey: "claude")
        }
        #expect(h.launcher.reopen(id) == .failure(.missingDirectory(missing)))
        #expect(h.host.opened.isEmpty && h.host.restored.isEmpty)
        #expect(h.session(id)?.live == nil)
    }

    @Test("reopen: a tilde cwd is expanded against the launcher's home")
    func reopenExpandsTilde() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = Self.restoredRow(h, cwd: "~")
        h.store.update { $0.sessions[id]?.repoRoot = nil }
        #expect(h.launcher.reopen(id) == .success(.reopened(directory: h.tree.home, restoredContent: false)))
        #expect(h.host.opened.first?.cwd == h.tree.home)
        #expect(h.session(id)?.cwd == "~", "the model keeps the path as written")
    }

    // MARK: - Resume

    @Test("resume: reopens the shell with claude --resume <id> as its boot command")
    func resumeRestoredRow() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = Self.restoredRow(h, worktree: h.tree.worktree, accountKey: "claude-work", conversationId: "abc-123")
        h.host.savedSnapshots[id] = Data("saved".utf8)

        let outcome = h.launcher.resume(id)
        h.store.flush()
        #expect(outcome == .success(.resumed(conversationId: "abc-123")))
        #expect(h.host.restored.first?.cwd == h.tree.worktree)
        #expect(h.host.restored.first?.env["CLAUDE_CONFIG_DIR"] == h.tree.home + "/.claude-work")
        // Handed to the shell it spawns, not typed in afterwards.
        #expect(h.host.bootCommands == ["claude --resume abc-123"])
        #expect(h.host.ran.isEmpty)
        #expect(h.store.state.selection == id)
        // The conversation id is untouched: SessionStart will confirm the same one.
        #expect(h.session(id)?.conversationId == "abc-123")
    }

    /// The regression this whole rebase was about: a boot command must reach only the row's
    /// focused pane. Putting it in the shared `reopen` environment instead would have run
    /// `claude --resume` in every pane's `.zlogin`, once per pane.
    @Test("resume: a split row's boot command reaches only the focused pane")
    func resumeSplitRowBootsOnlyTheFocusedPane() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = Self.restoredRow(h, conversationId: "abc-123")
        let first = TerminalID(uuid: id.uuid)
        h.store.update { _ = $0.splitPane(first, axis: .vertical) }
        h.store.flush()

        #expect(h.launcher.resume(id) == .success(.resumed(conversationId: "abc-123")))
        h.store.flush()
        #expect(h.host.opened.count == 2, "both panes get a shell")
        #expect(h.host.bootCommands == ["claude --resume abc-123"], "typed into exactly one pane")
    }

    /// The overlay's fact follows the boot command: wherever `TKZMUX_BOOT_COMMAND` goes, that
    /// pane is "starting Claude"; a shell that gets no command is not.
    @Test("start and resume record a Claude startup on the pane that got the boot command")
    func claudeStartupFollowsTheBootCommand() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let now = Date(timeIntervalSince1970: 1_788_944_400)

        // A new row with a command: its one pane.
        let started = try h.launcher.start(
            NewSessionMenu.Launch(kind: .worktree, command: "claude -w feature", cwd: h.tree.repo, accountKey: nil, groupID: h.group),
            now: now
        ).get()
        h.store.flush()
        #expect(
            h.session(started)?.live?.agentStartup
                == AgentStartup(
                    terminal: TerminalID(uuid: started.uuid), command: "claude -w feature",
                    startedAt: now))

        // A bare shell: nothing.
        let shell = try h.launcher.start(
            NewSessionMenu.Launch(kind: .shell, command: "", cwd: h.tree.repo, accountKey: nil, groupID: h.group), now: now
        ).get()
        h.store.flush()
        #expect(h.session(shell)?.live?.agentStartup == nil)

        // A split adds a shell, never a launch.
        let split = try h.launcher.addTerminal(to: started, splitting: .horizontal).get()
        h.store.flush()
        #expect(h.session(started)?.live?.agentStartup?.terminal == TerminalID(uuid: started.uuid))
        #expect(split != TerminalID(uuid: started.uuid))

        // A resume of a restored split row: the focused pane, and only it.
        let restored = Self.restoredRow(h, conversationId: "abc-123")
        let first = TerminalID(uuid: restored.uuid)
        var second: TerminalID?
        h.store.update { second = $0.splitPane(first, axis: .vertical) }
        h.store.flush()
        let focused = try #require(second)
        #expect(h.session(restored)?.focusedTerminalID == focused, "a split focuses the new pane")
        #expect(h.launcher.resume(restored) == .success(.resumed(conversationId: "abc-123")))
        h.store.flush()
        #expect(h.session(restored)?.live?.agentStartup?.terminal == focused)
        #expect(h.session(restored)?.live?.agentStartup?.command == "claude --resume abc-123")

        // A plain reopen carries no command, so it records nothing.
        let plain = Self.restoredRow(h, conversationId: nil)
        _ = h.launcher.reopen(plain)
        h.store.flush()
        #expect(h.session(plain)?.live?.agentStartup == nil)
    }

    /// The shell under `claude -w` never `cd`s: the command is typed in the main checkout and
    /// Claude chdirs into the worktree itself, so that pane's OSC 7 is stale by construction. A
    /// split from it must land where Claude is, like the pane header and git strip already do.
    @Test("split from the Claude pane starts in Claude's cwd, not the shell's stale OSC 7")
    func splitFromClaudePaneUsesClaudesCwd() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = try h.launcher.start(
            NewSessionMenu.Launch(kind: .worktree, command: "claude -w wt", cwd: h.tree.repo, accountKey: nil, groupID: h.group)
        ).get()
        let claudePane = TerminalID(uuid: id.uuid)
        h.store.update { state in
            state.updateLive(id) {
                $0.observation = AgentObservation(
                    pid: 99, conversationId: "s", configDir: h.tree.home + "/.claude", cwd: h.tree.worktree)
                $0.agentTerminal = claudePane
            }
            // What the shell reported: still the main checkout.
            state.setPaneCwd(claudePane, path: h.tree.repo)
        }
        h.store.flush()

        let split = try h.launcher.addTerminal(to: id, splitting: .horizontal).get()
        h.store.flush()
        #expect(h.host.opened.last?.terminal == split)
        #expect(h.host.opened.last?.cwd == h.tree.worktree)

        // A pane that is not running Claude keeps its own shell's answer.
        h.store.update { state in
            state.setPaneCwd(split, path: h.tree.home)
            state.focusPane(split)
        }
        h.store.flush()
        let again = try h.launcher.addTerminal(to: id, splitting: .vertical).get()
        #expect(h.host.opened.last?.terminal == again)
        #expect(h.host.opened.last?.cwd == h.tree.home)
    }

    @Test("resume: a row whose shell is already up gets the command typed directly")
    func resumeIntoLiveShell() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = Self.restoredRow(h, conversationId: "abc")
        _ = h.launcher.reopen(id)
        h.store.flush()
        #expect(h.launcher.resume(id) == .success(.resumed(conversationId: "abc")))
        // The one case that is still typed: this shell was already up and at its prompt, so it
        // has finished every `tcsetattr` its startup performs and the boot command is long spent.
        #expect(h.host.ran.map(\.command) == ["claude --resume abc"])
        #expect(h.host.bootCommands.isEmpty)
        #expect(h.host.opened.count == 1, "no second shell")
    }

    @Test("resume: Claude already running → nothing typed; no conversation → shell only")
    func resumeEdges() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let running = Self.restoredRow(h, conversationId: "abc")
        h.store.update { state in
            state.setLive(LiveSessionState(shellPid: 1), for: running)
            state.applyObservation(
                AgentObservation(pid: 9, conversationId: "abc", configDir: "/x/.claude", activity: .busy),
                alive: true, to: running)
        }
        #expect(h.launcher.resume(running) == .success(.agentRunning))
        #expect(h.host.ran.isEmpty)

        let shellOnly = Self.restoredRow(h, conversationId: nil)
        #expect(h.launcher.resume(shellOnly) == .success(.nothingToResume))
        #expect(h.host.opened.map(\.id) == [shellOnly])
        #expect(h.host.ran.isEmpty)

        #expect(h.launcher.resume(SessionID.generate()) == .failure(.unknownSession))
    }

    @Test("resumeAll: every resumable row in the group, selection untouched, failures reported")
    func resumeAllInGroup() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let a = Self.restoredRow(h, conversationId: "a")
        let b = Self.restoredRow(h, conversationId: "b")
        let noConversation = Self.restoredRow(h, conversationId: nil)
        let broken = SessionID.generate()
        let missing = h.tree.base.appending(path: "gone").path
        h.store.update { state in
            state.sessions[broken] = Session(id: broken, groupID: h.group, cwd: missing, repoRoot: missing,
                                             accountKey: "claude", conversationId: "c")
            state.select(noConversation)
        }
        h.store.flush()

        let outcome = h.launcher.resumeAll(in: h.group)
        h.store.flush()
        #expect(Set(outcome.resumed) == [a, b])
        #expect(outcome.failed.map(\.0) == [broken])
        #expect(outcome.failed.first?.1 == .missingDirectory(missing))
        #expect(Set(h.host.bootCommands) == ["claude --resume a", "claude --resume b"])
        #expect(h.store.state.selection == noConversation)
        #expect(h.session(noConversation)?.live == nil, "a row with nothing to resume is left alone")
    }

    // MARK: - Close / remove

    @Test("remove discards the row and its snapshot, whether or not the host ever held it")
    func remove() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = try #require(try? h.launcher.start(NewSessionMenu.Launch(
            kind: .shell, command: "", cwd: h.tree.repo, accountKey: nil, groupID: h.group)).get())
        h.store.flush()

        h.launcher.remove(id)
        h.store.flush()
        #expect(h.host.discarded == [id])
        #expect(h.session(id) == nil)

        let neverOpened = Self.restoredRow(h)
        h.host.savedSnapshots[neverOpened] = Data("x".utf8)
        h.launcher.remove(neverOpened)
        h.store.flush()
        #expect(h.host.discarded == [id, neverOpened])
        #expect(h.host.savedSnapshots[neverOpened] == nil, "the snapshot goes even for a row the host never held")
        #expect(h.session(neverOpened) == nil)
    }

    // MARK: - Worktree refresh

    @Test("after an exit the worktree list is re-read and a removed worktree loses its badge")
    func worktreeRefresh() async throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let kept = Self.restoredRow(h, worktree: h.tree.worktree)
        let gonePath = h.tree.base.appending(path: "repo/.claude/worktrees/gone").path
        let gone = Self.restoredRow(h, worktree: gonePath)
        // A row in another repo must not be touched by this repo's refresh.
        let elsewhere = SessionID.generate()
        h.store.update { state in
            state.sessions[elsewhere] = Session(
                id: elsewhere, groupID: h.group, cwd: "/other", repoRoot: "/other",
                worktreePath: "/other/.claude/worktrees/w", isWorktree: true, accountKey: "claude")
        }
        h.store.flush()

        let listedRepo = h.tree.repo
        let listedWorktree = h.tree.worktree
        var asked: [String] = []
        let recorder = Recorder()
        h.launcher.worktreeLister = { root in
            recorder.record(root)
            return [listedRepo, listedWorktree]
        }
        h.launcher.worktreeRefreshDelay = .milliseconds(10)
        var refreshed = 0
        h.launcher.onWorktreesRefreshed = { _, _ in refreshed += 1 }

        // Three exits in one repo → one git call.
        h.launcher.noteExit(gone)
        h.launcher.noteExit(kept)
        h.launcher.noteExit(gone)

        let deadline = ContinuousClock.now + .seconds(5)
        while refreshed == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        h.store.flush()
        asked = recorder.roots
        #expect(asked == [h.tree.repo])
        #expect(h.session(kept)?.isWorktree == true)
        #expect(h.session(gone)?.isWorktree == false)
        #expect(h.session(elsewhere)?.isWorktree == true)
    }

    /// A box for the lister closure, which is `@Sendable` and runs off the main actor. `Mutex`,
    /// as everywhere else in the codebase — never `@unchecked Sendable` (CLAUDE.md).
    final class Recorder: Sendable {
        private let storage = Mutex<[String]>([])
        var roots: [String] { storage.withLock { $0 } }
        func record(_ root: String) { storage.withLock { $0.append(root) } }
    }
}
