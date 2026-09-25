// The window controller's half of ▶ Run: detection in the row's own checkout, the
// remembered command shared by every row of a group, and the OSC 9;4 marker flipping ■ back to ▶.

import AppKit
import Foundation
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct RunDevServerWiringTests {
    /// `<base>/repo` and `<base>/repo/.claude/worktrees/wt`, each with its own `package.json` —
    /// the worktree's has a script the main checkout does not, which is how a test can tell which
    /// of the two was read.
    struct Repo {
        let base: URL
        var repo: String { base.appending(path: "repo").path }
        var worktree: String { base.appending(path: "repo/.claude/worktrees/wt").path }

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appending(path: "tkzmux-run-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
            try #"{"packageManager":"pnpm@9","scripts":{"dev":"vite","build":"vite build"}}"#
                .write(toFile: repo + "/package.json", atomically: true, encoding: .utf8)
            try #"{"packageManager":"pnpm@9","scripts":{"dev":"vite","dev:web":"vite --port 3001"}}"#
                .write(toFile: worktree + "/package.json", atomically: true, encoding: .utf8)
        }

        func tearDown() { try? FileManager.default.removeItem(at: base) }
    }

    private func start(
        _ harness: MainWindowControllerTests.Harness, in cwd: String, group: GroupID
    ) throws -> SessionID {
        harness.controller.launch(
            MainWindowLaunchTests.launch(.shell, command: "", cwd: cwd, group: group))
        harness.store.flush()
        return try #require(harness.store.state.selection)
    }

    private func settle(
        _ harness: MainWindowControllerTests.Harness, until predicate: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            harness.store.flush()
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test("the worktree row detects its own scripts and runs pnpm dev in the worktree")
    func worktreeRowRunsInItsWorktree() throws {
        let repo = try Repo()
        defer { repo.tearDown() }
        let (harness, group) = MainWindowLaunchTests.makeHarness(repoRoot: repo.repo)
        defer { harness.tearDown() }
        let id = try start(harness, in: repo.worktree, group: group)
        harness.store.update { state in
            state.sessions[id]?.worktreePath = repo.worktree
            state.sessions[id]?.isWorktree = true
        }
        harness.store.flush()

        let model = try #require(harness.controller.runButtonModel(refresh: true))
        #expect(model.command == "pnpm dev")
        #expect(model.tasks.map(\.command).contains("pnpm dev:web"), "the worktree's package.json, not the repo's")
        #expect(!model.tasks.map(\.command).contains("pnpm build"))

        harness.controller.toggleDevServer()
        harness.store.flush()
        let opened = try #require(harness.host.opened.last)
        #expect(opened.cwd == repo.worktree)
        #expect(opened.env["TKZMUX_BOOT_COMMAND"] == "pnpm dev")
        #expect(harness.controller.runButtonModel()?.running == "pnpm dev")
    }

    @Test("■ sends Ctrl-C; the boot command's remove marker turns it back into ▶")
    func stopAndTheRemoveMarker() async throws {
        let repo = try Repo()
        defer { repo.tearDown() }
        let (harness, group) = MainWindowLaunchTests.makeHarness(repoRoot: repo.repo)
        defer { harness.tearDown() }
        let id = try start(harness, in: repo.repo, group: group)

        harness.controller.toggleDevServer()
        harness.store.flush()
        let pane = try #require(harness.store.state.sessions[id]?.live?.runPane?.terminal)

        harness.controller.toggleDevServer()   // ■
        #expect(harness.host.wrote.last?.id == pane)
        #expect(harness.host.wrote.last?.data == Data([0x03]))
        #expect(harness.controller.runButtonModel()?.isRunning == true, "still ■ until the shell says so")

        harness.host.emit(.progress(state: .remove, value: nil), forTerminal: pane)
        let stopped = await settle(harness) {
            harness.store.state.sessions[id]?.live?.runPane?.running == false
        }
        #expect(stopped)
        #expect(harness.controller.runButtonModel()?.isRunning == false)
        #expect(harness.store.state.sessions[id]?.terminalIDs.contains(pane) == true, "the logs stay")
    }

    @Test("a ▾ pick is remembered for the group: another row of the repo runs it too")
    func pickIsRememberedForTheGroup() throws {
        let repo = try Repo()
        defer { repo.tearDown() }
        let (harness, group) = MainWindowLaunchTests.makeHarness(repoRoot: repo.repo)
        defer { harness.tearDown() }
        let first = try start(harness, in: repo.worktree, group: group)

        harness.controller.toolbarController.onRunTask?("pnpm dev:web")
        harness.store.flush()
        #expect(harness.store.state.groups[group]?.runCommand == "pnpm dev:web")
        #expect(harness.store.state.sessions[first]?.live?.runPane?.command == "pnpm dev:web")

        // Another row of the same repo — the main checkout, which has no `dev:web` of its own.
        let second = try start(harness, in: repo.repo, group: group)
        #expect(second != first)
        let model = try #require(harness.controller.runButtonModel(refresh: true))
        #expect(model.command == "pnpm dev:web")
        #expect(model.remembered == "pnpm dev:web")

        harness.controller.toolbarController.onResetRunCommand?()
        harness.store.flush()
        #expect(harness.store.state.groups[group]?.runCommand == nil)
        #expect(harness.controller.runButtonModel()?.command == "pnpm dev")
    }

    @Test("Custom Command… runs and remembers what was typed; cancel does nothing")
    func customCommand() throws {
        let repo = try Repo()
        defer { repo.tearDown() }
        let (harness, group) = MainWindowLaunchTests.makeHarness(repoRoot: repo.repo)
        defer { harness.tearDown() }
        _ = try start(harness, in: repo.repo, group: group)

        var offered: String??
        harness.controller.runCommandPrompt = { current in
            offered = current
            return nil
        }
        harness.controller.chooseCustomRunCommand()
        #expect(offered == .some("pnpm dev"))
        #expect(harness.store.state.groups[group]?.runCommand == nil)

        harness.controller.runCommandPrompt = { _ in "  dotnet watch run --project src/Api  " }
        harness.controller.chooseCustomRunCommand()
        harness.store.flush()
        #expect(harness.store.state.groups[group]?.runCommand == "dotnet watch run --project src/Api")
        #expect(harness.host.opened.last?.env["TKZMUX_BOOT_COMMAND"] == "dotnet watch run --project src/Api")
    }

    @Test("⌃⌘R is in the Session menu")
    func shortcut() {
        #expect(ShortcutsTable.defaults[.runDevServer] == Shortcut("r", [.control, .command]))
        #expect(ShortcutsTable.allActions.contains(.runDevServer))
        #expect(ShortcutsTable.title(for: .runDevServer) == "Run / Stop Dev Server")
    }
}
