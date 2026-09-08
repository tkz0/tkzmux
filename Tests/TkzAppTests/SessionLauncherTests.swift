// SessionLauncherTests — M5.2 (TKZ-30): start, reopen, resume, close, remove, worktree refresh.
//
// Everything runs against `SpyTerminalHost`: what is asserted is which host call was made, with
// which cwd and env, and what the store says afterwards. Directories are real (a temp tree), so
// the "first directory that exists" rule is exercised against the file system rather than mocked.

import AppKit
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

    static func makeHarness() throws -> Harness {
        let tree = try Tree()
        var state = AppState()
        let group = state.addGroup(name: "repo", repoRoot: tree.repo)
        let store = AppStore(state: state)
        let host = Spy()
        let launcher = SessionLauncher(store: store, host: host, home: tree.home)
        return Harness(tree: tree, store: store, host: host, launcher: launcher, group: group.id)
    }

    /// A restored row: in the store with no live state, as `state.json` hands it over.
    static func restoredRow(
        _ h: Harness, cwd: String? = nil, worktree: String? = nil, accountKey: String = "claude",
        claudeSessionId: String? = "sid-1"
    ) -> SessionID {
        let id = SessionID.generate()
        h.store.update { state in
            var session = Session(
                id: id, groupID: h.group, cwd: cwd ?? h.tree.repo, repoRoot: h.tree.repo,
                worktreePath: worktree, isWorktree: worktree != nil,
                accountKey: accountKey, claudeSessionId: claudeSessionId)
            session.live = nil
            state.sessions[id] = session
        }
        h.store.flush()
        return id
    }

    // MARK: - Start

    @Test("start: the account's config dir and the preset's env reach the child")
    func startEnvironment() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let spec = NewSessionMenu.Launch(
            kind: .preset, command: "claude -w review", cwd: h.tree.repo, accountKey: "claude-work",
            groupID: h.group, env: ["TKZ_TEST": "1"])
        let result = h.launcher.start(spec)
        h.store.flush()
        let id = try #require(try? result.get())
        let opened = try #require(h.host.opened.first)
        #expect(opened.id == id)
        #expect(opened.cwd == h.tree.repo)
        // No account in the store: derived from the key, `~/.<key>` under the launcher's home.
        #expect(opened.env["CLAUDE_CONFIG_DIR"] == h.tree.home + "/.claude-work")
        #expect(opened.env["TKZ_TEST"] == "1")
        #expect(h.host.ran.first?.command == "claude -w review")
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
        #expect(h.host.opened[0].env["TKZMUX_CLAUDE_CONFIG_DIR"] == "/somewhere/else")
        #expect(h.host.opened[1].env["CLAUDE_CONFIG_DIR"] == h.tree.home + "/.claude")
        #expect(h.host.opened[2].env["CLAUDE_CONFIG_DIR"] == nil)
        #expect(h.host.opened[2].env["TKZMUX_CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test("reopen and resume always pin the row's recorded account, the primary included")
    func reopenPinsThePrimary() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = Self.restoredRow(h, accountKey: "claude", claudeSessionId: "abc")
        #expect(h.launcher.resume(id) == .success(.resumed(claudeSessionId: "abc")))
        // A row that ran on `~/.claude` must resume there even if the user's shell defaults
        // elsewhere — the recorded key is the truth, and the wrapper re-export enforces it.
        #expect(h.host.opened.first?.env["CLAUDE_CONFIG_DIR"] == h.tree.home + "/.claude")
        #expect(h.host.opened.first?.env["TKZMUX_CLAUDE_CONFIG_DIR"] == h.tree.home + "/.claude")
    }

    @Test("start: a preset env may override the account's config dir, on purpose")
    func presetEnvOverrides() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        _ = h.launcher.start(NewSessionMenu.Launch(
            kind: .preset, command: "claude", cwd: h.tree.repo, accountKey: "claude-work",
            groupID: h.group, env: ["CLAUDE_CONFIG_DIR": "/custom"]))
        #expect(h.host.opened[0].env["CLAUDE_CONFIG_DIR"] == "/custom")
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

    @Test("resume: reopens the shell and types claude --resume <id> through the readiness path")
    func resumeRestoredRow() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = Self.restoredRow(h, worktree: h.tree.worktree, accountKey: "claude-work", claudeSessionId: "abc-123")
        h.host.savedSnapshots[id] = Data("saved".utf8)

        let outcome = h.launcher.resume(id)
        h.store.flush()
        #expect(outcome == .success(.resumed(claudeSessionId: "abc-123")))
        #expect(h.host.restored.first?.cwd == h.tree.worktree)
        #expect(h.host.restored.first?.env["CLAUDE_CONFIG_DIR"] == h.tree.home + "/.claude-work")
        #expect(h.host.ran.map(\.command) == ["claude --resume abc-123"])
        #expect(h.store.state.selection == id)
        // The conversation id is untouched: SessionStart will confirm the same one.
        #expect(h.session(id)?.claudeSessionId == "abc-123")
    }

    @Test("resume: a row whose shell is already up gets the command typed directly")
    func resumeIntoLiveShell() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let id = Self.restoredRow(h, claudeSessionId: "abc")
        _ = h.launcher.reopen(id)
        h.store.flush()
        #expect(h.launcher.resume(id) == .success(.resumed(claudeSessionId: "abc")))
        #expect(h.host.ran.map(\.command) == ["claude --resume abc"])
        #expect(h.host.opened.count == 1, "no second shell")
    }

    @Test("resume: Claude already running → nothing typed; no conversation → shell only")
    func resumeEdges() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let running = Self.restoredRow(h, claudeSessionId: "abc")
        h.store.update { state in
            state.setLive(LiveSessionState(shellPid: 1), for: running)
            state.applyDescriptor(
                ClaudeSessionInfo(configDir: "/x/.claude", pid: 9, sessionId: "abc", status: .busy),
                alive: true, to: running)
        }
        #expect(h.launcher.resume(running) == .success(.claudeRunning))
        #expect(h.host.ran.isEmpty)

        let shellOnly = Self.restoredRow(h, claudeSessionId: nil)
        #expect(h.launcher.resume(shellOnly) == .success(.nothingToResume))
        #expect(h.host.opened.map(\.id) == [shellOnly])
        #expect(h.host.ran.isEmpty)

        #expect(h.launcher.resume(SessionID.generate()) == .failure(.unknownSession))
    }

    @Test("resumeAll: every resumable row in the group, selection untouched, failures reported")
    func resumeAllInGroup() throws {
        let h = try Self.makeHarness()
        defer { h.tree.tearDown() }
        let a = Self.restoredRow(h, claudeSessionId: "a")
        let b = Self.restoredRow(h, claudeSessionId: "b")
        let noConversation = Self.restoredRow(h, claudeSessionId: nil)
        let broken = SessionID.generate()
        let missing = h.tree.base.appending(path: "gone").path
        h.store.update { state in
            state.sessions[broken] = Session(id: broken, groupID: h.group, cwd: missing, repoRoot: missing,
                                             accountKey: "claude", claudeSessionId: "c")
            state.select(noConversation)
        }
        h.store.flush()

        let outcome = h.launcher.resumeAll(in: h.group)
        h.store.flush()
        #expect(Set(outcome.resumed) == [a, b])
        #expect(outcome.failed.map(\.0) == [broken])
        #expect(outcome.failed.first?.1 == .missingDirectory(missing))
        #expect(Set(h.host.ran.map(\.command)) == ["claude --resume a", "claude --resume b"])
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
