// MainWindowLaunchTests — M2.5 (TKZ-43): the window actually starting a session.
//
// Everything here runs against `SpyTerminalHost` (see `MainWindowControllerTests`): a real
// `TerminalViewHost` would spawn shells and write `.ghsnap` files into the developer's
// Application Support directory. What is asserted is the *wiring* — which host call was made with
// which arguments, and what the store looks like afterwards — because that is the whole of this
// ticket. The one thing a spy cannot prove (that a command written after `open` is not swallowed
// by zsh's `tcsetattr`) is proved against a real pty in `PtyTests`.

import AppKit
import Foundation
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct MainWindowLaunchTests {

    typealias Harness = MainWindowControllerTests.Harness

    /// An empty window over a group rooted at a directory that really exists.
    static func makeHarness(
        repoRoot: String = NSTemporaryDirectory()
    ) -> (harness: Harness, groupID: GroupID) {
        var state = AppState()
        let group = state.addGroup(name: "Scratch", repoRoot: repoRoot)
        let harness = MainWindowControllerTests.makeHarness(state)
        return (harness, group.id)
    }

    static func launch(
        _ kind: NewSessionMenu.Launch.Kind = .repoRoot,
        command: String = "claude",
        cwd: String,
        accountKey: String? = nil,
        group: GroupID
    ) -> NewSessionMenu.Launch {
        NewSessionMenu.Launch(
            kind: kind, command: command, cwd: cwd, accountKey: accountKey, groupID: group)
    }

    // MARK: - The happy path

    @Test("A launch opens a pty, creates a live row and selects it")
    func launchOpensAndSelects() {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }

        harness.controller.launch(
            Self.launch(cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()

        let opened = try! #require(harness.host.opened.first)
        #expect(harness.host.opened.count == 1)

        let session = try! #require(harness.store.state.sessions[opened.id])
        #expect(session.groupID == group)
        #expect(session.live?.shellPid == 4242)
        // Without live state `Session.status` falls back to `.exited` and a new row draws as dead.
        #expect(session.status == .idle)
        #expect(harness.store.state.selection == opened.id)
        // Selection is what shows a session; the launcher must not call `show` itself.
        #expect(harness.host.lastShown == .some(opened.id))
    }

    @Test("The command rides in on the spawn environment, never typed into the pty")
    func commandGoesThroughTheBootCommand() {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }

        harness.controller.launch(
            Self.launch(command: "claude --permission-mode plan", cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()

        let opened = try! #require(harness.host.opened.first)
        #expect(opened.env["TKZMUX_BOOT_COMMAND"] == "claude --permission-mode plan")
        #expect(harness.host.ran.isEmpty, "nothing is typed into a shell that is still starting")
    }

    @Test("A shell launch opens a pty and types nothing into it")
    func shellLaunchTypesNothing() {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }

        harness.controller.launch(
            Self.launch(.shell, command: "", cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()

        #expect(harness.host.opened.count == 1)
        #expect(harness.host.ran.isEmpty)
    }

    // MARK: - Paths

    @Test("The tilde is expanded for the spawn and kept verbatim in the model")
    func tildeIsExpandedOnlyForTheSpawn() {
        let (harness, group) = Self.makeHarness(repoRoot: "~")
        defer { harness.tearDown() }

        harness.controller.launch(Self.launch(cwd: "~", group: group))
        harness.store.flush()

        let opened = try! #require(harness.host.opened.first)
        #expect(opened.cwd == NSHomeDirectory())
        // `state.json` (M5.1) persists `cwd`, and the sidebar shows it: one spelling, as written.
        #expect(harness.store.state.sessions[opened.id]?.cwd == "~")
    }

    @Test("A launch into a directory that does not exist never reaches the host")
    func missingDirectoryFailsBeforeSpawning() {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        var failures: [String] = []
        harness.controller.onLaunchFailure = { failures.append($0) }

        let missing = NSTemporaryDirectory() + "tkzmux-does-not-exist-\(UUID().uuidString)"
        harness.controller.launch(Self.launch(cwd: missing, group: group))
        harness.store.flush()

        // The pty shim ignores `chdir`'s return value, so the spawn would have *succeeded* in the
        // wrong directory. Validating up front is the only way this fails visibly.
        #expect(harness.host.opened.isEmpty)
        #expect(harness.store.state.sessions.isEmpty)
        #expect(failures.count == 1)
    }

    @Test("A spawn failure leaves no row behind")
    func spawnFailureLeavesNoRow() {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        var failures: [String] = []
        harness.controller.onLaunchFailure = { failures.append($0) }
        harness.host.openError = TerminalHostError.sessionNotAlive("nope")

        harness.controller.launch(Self.launch(cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()

        #expect(harness.store.state.sessions.isEmpty)
        #expect(harness.store.state.selection == nil)
        #expect(failures.count == 1)
    }

    // MARK: - Accounts

    @Test("CLAUDE_CONFIG_DIR follows the chosen account, the primary included; unchosen = unset")
    func accountConfigDirectory() {
        var state = AppState()
        let group = state.addGroup(name: "Scratch", repoRoot: NSTemporaryDirectory())
        state.setAccount(Account(key: "claude-work", configDir: "/tmp/alt", label: "Alt"))
        state.setAccount(Account(key: Account.defaultKey, configDir: "/tmp/primary", label: "Main"))
        let harness = MainWindowControllerTests.makeHarness(state)
        defer { harness.tearDown() }

        harness.controller.launch(
            Self.launch(cwd: NSTemporaryDirectory(), accountKey: "claude-work", group: group.id))
        harness.controller.launch(
            Self.launch(cwd: NSTemporaryDirectory(), accountKey: Account.defaultKey, group: group.id))
        harness.controller.launch(
            Self.launch(cwd: NSTemporaryDirectory(), accountKey: nil, group: group.id))
        harness.store.flush()

        #expect(harness.host.opened.count == 3)
        // The key is a basename; the child needs the directory.
        #expect(harness.host.opened[0].env["CLAUDE_CONFIG_DIR"] == "/tmp/alt")
        // The wrapper re-exports this one after the user's rc files, so a rc cannot override it.
        #expect(harness.host.opened[0].env["TKZMUX_CLAUDE_CONFIG_DIR"] == "/tmp/alt")
        // An explicitly chosen primary account is pinned too (M5.2 GUI pass: the user's
        // environment may default to another account).
        #expect(harness.host.opened[1].env["CLAUDE_CONFIG_DIR"] == "/tmp/primary")
        // No account chosen: the environment decides, and the launch frame reports what it chose.
        #expect(harness.host.opened[2].env["CLAUDE_CONFIG_DIR"] == nil)
    }

    // MARK: - Closing

    @Test("⌘W removes the session: row, shell and snapshot")
    func closeRemovesTheSession() {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        harness.controller.launch(Self.launch(cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()
        let id = try! #require(harness.host.opened.first?.id)
        harness.host.savedSnapshots[id] = Data("x".utf8)

        harness.controller.dispatcher.perform(.closeTerminal)
        harness.store.flush()

        // There is no "closed but kept" row (decision 2026-09-08): a terminal cannot be exited.
        #expect(harness.host.discarded == [id])
        #expect(harness.host.savedSnapshots[id] == nil)
        #expect(harness.store.state.sessions[id] == nil)
        #expect(harness.store.state.selection == nil)
    }

    @Test("An OSC 7 from the shell retitles the row; a foreign host is ignored")
    func pwdEventRetitlesTheRow() async throws {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        harness.controller.launch(Self.launch(.shell, command: "", cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()
        let id = try #require(harness.host.opened.first?.id)

        harness.host.emit(.pwd("file://localhost/Users/someone/dev/toolbox%20two"), for: id)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            harness.store.flush()
            if harness.store.state.sessions[id]?.live?.shellCwd != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.store.state.sessions[id]?.live?.shellCwd == "/Users/someone/dev/toolbox two")
        #expect(harness.store.state.sessions[id]?.displayTitle == "toolbox two")

        harness.host.emit(.pwd("file://elsewhere.example/nope"), for: id)
        try await Task.sleep(for: .milliseconds(50))
        harness.store.flush()
        #expect(harness.store.state.sessions[id]?.displayTitle == "toolbox two", "another host's path is not ours")
    }

    @Test("⌘W with nothing selected does nothing")
    func closeTerminalWithoutSelection() {
        let (harness, _) = Self.makeHarness()
        defer { harness.tearDown() }

        harness.controller.dispatcher.perform(.closeTerminal)
        harness.store.flush()

        #expect(harness.host.discarded.isEmpty)
    }

    @Test("An exiting shell removes its row, as a terminal tab closes when its shell ends")
    func exitEventRemovesTheRow() async throws {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        harness.controller.launch(Self.launch(cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()
        let id = try #require(harness.host.opened.first?.id)

        harness.host.emit(.exited(.exited(code: 0)), for: id)

        // The pump is a `Task`: poll rather than sleep a fixed amount, so a busy main actor slows
        // the test down instead of failing it.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            harness.store.flush()
            if harness.store.state.sessions[id] == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.store.state.sessions[id] == nil)
        #expect(harness.host.discarded == [id])
    }
}
