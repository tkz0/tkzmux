// RunDevServerTests — the launcher half of the toolbar's ▶ Run.
//
// Against `SpyTerminalHost`, like `SessionLauncherTests`: what matters is which pane was opened,
// in which directory, with which boot command — and that the agent's pane is left alone.

import Foundation
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct RunDevServerTests {
    typealias Harness = SessionLauncherTests.Harness

    /// A live worktree row: reopened, so it has a shell in its one pane.
    private func worktreeRow(_ h: Harness) throws -> SessionID {
        let id = SessionLauncherTests.restoredRow(h, worktree: h.tree.worktree, conversationId: nil)
        _ = try h.launcher.reopen(id).get()
        h.store.flush()
        return id
    }

    @Test("run: a worktree row runs in the worktree, not the main checkout, as a boot command")
    func runsInTheWorktree() throws {
        let h = try SessionLauncherTests.makeHarness()
        defer { h.tree.tearDown() }
        let id = try worktreeRow(h)
        let agentPane = try #require(h.session(id)?.focusedTerminalID)
        let directory = try #require(h.session(id)).runDirectory(gitToplevel: nil)
        #expect(directory == h.tree.worktree)

        let pane = try h.launcher.runDevServer("pnpm dev", in: directory, for: id).get()
        h.store.flush()

        let opened = try #require(h.host.opened.last)
        #expect(opened.terminal == pane)
        #expect(opened.cwd == h.tree.worktree)
        #expect(opened.cwd != h.tree.repo)
        #expect(opened.env["TKZMUX_BOOT_COMMAND"] == "pnpm dev")

        let session = try #require(h.session(id))
        #expect(session.live?.runPane == RunPane(terminal: pane, command: "pnpm dev", running: true))
        // Stacked under the pane it split, and the keyboard stays where the user was typing.
        #expect(session.terminalIDs == [agentPane, pane])
        #expect(session.focusedTerminalID == agentPane)
        // A dev server is not an agent launch: no "Starting Claude…" overlay.
        #expect(session.live?.agentStartup == nil)
        #expect(session.live?.panePids[pane] == 4242)
    }

    @Test("stop: Ctrl-C to the run pane only, and only while it is running")
    func stopSendsCtrlC() throws {
        let h = try SessionLauncherTests.makeHarness()
        defer { h.tree.tearDown() }
        let id = try worktreeRow(h)
        h.launcher.stopDevServer(id)
        #expect(h.host.wrote.isEmpty, "nothing running, nothing sent")

        let pane = try h.launcher.runDevServer("pnpm dev", in: h.tree.worktree, for: id).get()
        h.store.flush()
        h.launcher.stopDevServer(id)
        #expect(h.host.wrote.count == 1)
        #expect(h.host.wrote.first?.id == pane)
        #expect(h.host.wrote.first?.data == Data([0x03]))

        // Returned (the OSC 9;4 remove): a second Stop has nothing to interrupt.
        h.store.update { $0.runPaneReturned(pane) }
        h.store.flush()
        h.launcher.stopDevServer(id)
        #expect(h.host.wrote.count == 1)
    }

    @Test("run again: the same leaf is respawned with the new command, no second split")
    func runAgainRespawnsInPlace() throws {
        let h = try SessionLauncherTests.makeHarness()
        defer { h.tree.tearDown() }
        let id = try worktreeRow(h)
        let pane = try h.launcher.runDevServer("pnpm dev", in: h.tree.worktree, for: id).get()
        h.store.update { $0.runPaneReturned(pane) }
        h.store.flush()

        let again = try h.launcher.runDevServer("pnpm dev:web", in: h.tree.worktree, for: id).get()
        h.store.flush()
        #expect(again == pane)
        #expect(h.session(id)?.terminalCount == 2)
        #expect(h.host.opened.last?.terminal == pane)
        #expect(h.host.opened.last?.env["TKZMUX_BOOT_COMMAND"] == "pnpm dev:web")
        #expect(h.session(id)?.live?.runPane == RunPane(terminal: pane, command: "pnpm dev:web", running: true))
    }

    /// Switching task while one runs: the respawn hangs the old shell up (and its server with it).
    @Test("run another task while one is running: respawned in place too")
    func switchWhileRunning() throws {
        let h = try SessionLauncherTests.makeHarness()
        defer { h.tree.tearDown() }
        let id = try worktreeRow(h)
        let pane = try h.launcher.runDevServer("pnpm dev", in: h.tree.worktree, for: id).get()
        h.store.flush()
        let again = try h.launcher.runDevServer("pnpm dev:api", in: h.tree.worktree, for: id).get()
        h.store.flush()
        #expect(again == pane)
        #expect(h.session(id)?.terminalCount == 2)
        #expect(h.session(id)?.live?.runPane?.command == "pnpm dev:api")
    }

    /// The user closed the run pane: the next ▶ splits afresh rather than reviving a dead id.
    @Test("run after the run pane was closed: a new split")
    func runAfterClose() throws {
        let h = try SessionLauncherTests.makeHarness()
        defer { h.tree.tearDown() }
        let id = try worktreeRow(h)
        let first = try h.launcher.runDevServer("pnpm dev", in: h.tree.worktree, for: id).get()
        h.launcher.closeTerminal(first)
        h.store.flush()
        #expect(h.session(id)?.live?.runPane == nil)

        let second = try h.launcher.runDevServer("pnpm dev", in: h.tree.worktree, for: id).get()
        #expect(second != first)
        #expect(h.session(id)?.terminalCount == 2)
    }

    @Test("run: a directory that is gone fails without splitting")
    func missingDirectory() throws {
        let h = try SessionLauncherTests.makeHarness()
        defer { h.tree.tearDown() }
        let id = try worktreeRow(h)
        let missing = h.tree.base.appending(path: "gone").path
        #expect(h.launcher.runDevServer("pnpm dev", in: missing, for: id) == .failure(.missingDirectory(missing)))
        #expect(h.session(id)?.terminalCount == 1)
    }

    @Test("run: a failed spawn takes its split back out")
    func spawnFailure() throws {
        let h = try SessionLauncherTests.makeHarness()
        defer { h.tree.tearDown() }
        let id = try worktreeRow(h)
        h.host.openError = TerminalHostError.unknownSession("boom")
        guard case .failure = h.launcher.runDevServer("pnpm dev", in: h.tree.worktree, for: id) else {
            Issue.record("expected a failure")
            return
        }
        h.store.flush()
        #expect(h.session(id)?.terminalCount == 1)
        #expect(h.session(id)?.live?.runPane == nil)
    }
}
