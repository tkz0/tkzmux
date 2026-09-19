// MainWindowLaunchTests — M2.5: the window actually starting a session.
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
    ///
    /// The real home, not the shared harness's empty one: this suite is about directories — a
    /// `~` has to expand to somewhere that exists, or the launch it asserts on fails and puts a
    /// modal alert up in the middle of the test run.
    static func makeHarness(
        repoRoot: String = NSTemporaryDirectory()
    ) -> (harness: Harness, groupID: GroupID) {
        var state = AppState()
        let group = state.addGroup(name: "Scratch", repoRoot: repoRoot)
        let harness = MainWindowControllerTests.makeHarness(state, home: NSHomeDirectory())
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
        state.setAccount(Account(key: Account.defaultKey(for: .claude), configDir: "/tmp/primary", label: "Main"))
        let harness = MainWindowControllerTests.makeHarness(state)
        defer { harness.tearDown() }

        harness.controller.launch(
            Self.launch(cwd: NSTemporaryDirectory(), accountKey: "claude-work", group: group.id))
        harness.controller.launch(
            Self.launch(cwd: NSTemporaryDirectory(), accountKey: Account.defaultKey(for: .claude), group: group.id))
        harness.controller.launch(
            Self.launch(cwd: NSTemporaryDirectory(), accountKey: nil, group: group.id))
        harness.store.flush()

        #expect(harness.host.opened.count == 3)
        // The key is a basename; the child needs the directory.
        #expect(harness.host.opened[0].env["CLAUDE_CONFIG_DIR"] == "/tmp/alt")
        // The wrapper re-exports this one after the user's rc files, so a rc cannot override it
        // (TKZ-84 generalized the single hard-coded variable into this name/value pair).
        #expect(harness.host.opened[0].env["TKZMUX_ENV_CLAUDE_CONFIG_DIR"] == "/tmp/alt")
        #expect(harness.host.opened[0].env["TKZMUX_REEXPORT"] == "CLAUDE_CONFIG_DIR")
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

    // MARK: - "Starting Claude…"

    /// The overlay's edge, driven by hand: the launch records the fact, the window shows nothing
    /// until two seconds have passed, and the moment the store says Claude is up the pane is
    /// clear again. `applyStartupOverlay(now:)` takes the clock so nothing here sleeps.
    @Test("The overlay waits two seconds, then shows on the boot pane until Claude is up")
    func startupOverlayFollowsTheClockAndTheStore() throws {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        harness.controller.launch(
            Self.launch(.worktree, command: "claude -w feature", cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()
        harness.layout()
        let id = try #require(harness.host.opened.first?.id)
        let terminal = TerminalID(uuid: id.uuid)
        let startedAt = try #require(harness.store.state.sessions[id]?.live?.agentStartup?.startedAt)
        let pane = try #require(harness.controller.panes[terminal])

        // Right after the launch: pending, nothing on screen.
        #expect(!pane.chrome.isShowingStartup)
        harness.controller.applyStartupOverlay(now: startedAt.addingTimeInterval(1))
        #expect(!pane.chrome.isShowingStartup)

        // The timer's moment: visible, with the command as its caption.
        harness.controller.applyStartupOverlay(now: startedAt.addingTimeInterval(2))
        #expect(pane.chrome.isShowingStartup)
        #expect(pane.chrome.startupOverlay.captionText == "claude -w feature")
        #expect(pane.chrome.startupOverlay.isSpinning)

        // Claude is up: the delivery that carries it hides the overlay.
        harness.mutate { $0.applyEvent(.init(kind: .sessionStart, conversationId: "s"), to: id) }
        #expect(harness.store.state.sessions[id]?.live?.agentStartup == nil)
        #expect(!pane.chrome.isShowingStartup)
        #expect(!pane.chrome.startupOverlay.isSpinning)
    }

    /// The reported bug, from the pane's side. Codex can report through none of the three
    /// store-side signals that clear `agentStartup` — no descriptor file, no hook until the user
    /// has trusted it in Codex, and a boot command that never returns — so before this the spinner
    /// sat for the full two minutes on top of Codex's own interactive startup prompt.
    ///
    /// The pane answers instead: the moment the terminal reports the input modes a full-screen
    /// program switches on, the overlay goes away even though the store still knows nothing.
    @Test("A pane showing the agent's own UI hides the overlay, with no store signal at all")
    func theAgentsOwnUIEndsTheOverlayWithoutAStoreSignal() throws {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        harness.controller.launch(
            Self.launch(command: "codex", cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()
        harness.layout()
        let id = try #require(harness.host.opened.first?.id)
        let terminal = TerminalID(uuid: id.uuid)
        let startedAt = try #require(harness.store.state.sessions[id]?.live?.agentStartup?.startedAt)
        let pane = try #require(harness.controller.panes[terminal])

        // A shell at its prompt is not the agent: past the delay, the spinner is up.
        harness.host.inputModesByTerminal[terminal] = .nothingSet
        harness.controller.applyStartupOverlay(now: startedAt.addingTimeInterval(2))
        #expect(pane.chrome.isShowingStartup)

        // Codex's TUI initialises: focus reporting on, kitty keyboard flags pushed.
        harness.host.inputModesByTerminal[terminal] = TerminalInputModes(
            alternateScreen: false, focusReporting: true, kittyKeyboardFlags: 5)
        harness.controller.applyStartupOverlay(now: startedAt.addingTimeInterval(3))
        #expect(!pane.chrome.isShowingStartup, "the spinner covered Codex's own startup prompt")
        #expect(!pane.chrome.startupOverlay.isSpinning)

        // The store fact is deliberately untouched: it is what places an arriving launch frame.
        #expect(harness.store.state.sessions[id]?.live?.agentStartup != nil)

        // And it never comes back while the agent is on screen, however long the launch sits.
        harness.controller.applyStartupOverlay(now: startedAt.addingTimeInterval(60))
        #expect(!pane.chrome.isShowingStartup)
    }

    @Test("An agent already up before the delay never flashes the spinner at all")
    func anAgentUpBeforeTheDelayNeverShowsTheOverlay() throws {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        harness.controller.launch(
            Self.launch(command: "codex", cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()
        harness.layout()
        let id = try #require(harness.host.opened.first?.id)
        let terminal = TerminalID(uuid: id.uuid)
        let startedAt = try #require(harness.store.state.sessions[id]?.live?.agentStartup?.startedAt)
        let pane = try #require(harness.controller.panes[terminal])

        // Both agents reach this within milliseconds, well inside the two-second delay.
        harness.host.inputModesByTerminal[terminal] = TerminalInputModes(
            alternateScreen: false, focusReporting: true, kittyKeyboardFlags: 5)
        for offset in [0.0, 1.0, 2.0, 5.0] {
            harness.controller.applyStartupOverlay(now: startedAt.addingTimeInterval(offset))
            #expect(!pane.chrome.isShowingStartup, "flashed a spinner at +\(offset)s")
        }
    }

    /// The counterweight: a pane that has not entered a full-screen mode still gets the spinner,
    /// which is what a launch doing slow work before its UI appears looks like.
    @Test("A pane still at a shell prompt keeps the overlay until the give-up")
    func aShellPromptKeepsTheOverlay() throws {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        // A real registry, over a directory of this test's own, so the headline's adapter lookup
        // is exercised rather than falling through to "the agent" the way an unwired harness does.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        harness.controller.agents = AgentIntegration(
            store: harness.store, directory: root, home: root.path)
        harness.controller.launch(
            Self.launch(.worktree, command: "claude -w feature", cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()
        harness.layout()
        let id = try #require(harness.host.opened.first?.id)
        let terminal = TerminalID(uuid: id.uuid)
        let startedAt = try #require(harness.store.state.sessions[id]?.live?.agentStartup?.startedAt)
        let pane = try #require(harness.controller.panes[terminal])

        harness.host.inputModesByTerminal[terminal] = .nothingSet
        harness.controller.applyStartupOverlay(now: startedAt.addingTimeInterval(2))
        #expect(pane.chrome.isShowingStartup)
        harness.controller.applyStartupOverlay(now: startedAt.addingTimeInterval(90))
        #expect(pane.chrome.isShowingStartup)
        #expect(pane.chrome.startupOverlay.captionText == "claude -w feature")
        // And it names the row's own agent rather than falling back to "the agent".
        #expect(pane.chrome.startupOverlay.titleText == "Starting Claude\u{2026}")
    }

    @Test("A shell launch never shows the overlay, however long it sits")
    func shellLaunchShowsNoOverlay() throws {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        harness.controller.launch(
            Self.launch(.shell, command: "", cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()
        harness.layout()
        let id = try #require(harness.host.opened.first?.id)
        #expect(harness.store.state.sessions[id]?.live?.agentStartup == nil)
        let pane = try #require(harness.controller.panes[TerminalID(uuid: id.uuid)])
        harness.controller.applyStartupOverlay(now: Date().addingTimeInterval(3600))
        #expect(!pane.chrome.isShowingStartup)
    }

    /// The failure case: `claude: command not found` and the prompt is back. `.zlogin` reports
    /// the boot command's return as OSC 9;4 *remove*, and that — from the boot pane, not from
    /// any other — ends the launch.
    @Test("An OSC 9;4 remove from the boot pane ends the launch; from another pane it does not")
    func progressRemoveEndsTheLaunch() async throws {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        harness.controller.launch(
            Self.launch(command: "claude", cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()
        let id = try #require(harness.host.opened.first?.id)
        let boot = TerminalID(uuid: id.uuid)

        // Another pane's report is not about this launch.
        let other = try harness.controller.launcher.addTerminal(to: id, splitting: .horizontal).get()
        harness.store.flush()
        harness.host.emit(.progress(state: .remove, value: nil), forTerminal: other)
        try await Task.sleep(for: .milliseconds(50))
        harness.store.flush()
        #expect(harness.store.state.sessions[id]?.live?.agentStartup?.terminal == boot)

        // Neither is the "indeterminate" that opens the bracket.
        harness.host.emit(.progress(state: .indeterminate, value: nil), forTerminal: boot)
        try await Task.sleep(for: .milliseconds(50))
        harness.store.flush()
        #expect(harness.store.state.sessions[id]?.live?.agentStartup?.terminal == boot)

        harness.host.emit(.progress(state: .remove, value: nil), forTerminal: boot)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            harness.store.flush()
            if harness.store.state.sessions[id]?.live?.agentStartup == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.store.state.sessions[id]?.live?.agentStartup == nil)
    }

    @Test("Once the give-up passes, the launch is forgotten")
    func giveUpForgetsTheLaunch() async throws {
        let (harness, group) = Self.makeHarness()
        defer { harness.tearDown() }
        harness.controller.launch(
            Self.launch(command: "claude", cwd: NSTemporaryDirectory(), group: group))
        harness.store.flush()
        harness.layout()
        let id = try #require(harness.host.opened.first?.id)
        let startedAt = try #require(harness.store.state.sessions[id]?.live?.agentStartup?.startedAt)

        harness.controller.applyStartupOverlay(
            now: startedAt.addingTimeInterval(StartupOverlayPolicy.giveUp))
        // The write rides the timer, one run-loop turn away.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            harness.store.flush()
            if harness.store.state.sessions[id]?.live?.agentStartup == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.store.state.sessions[id]?.live?.agentStartup == nil)
        let pane = try #require(harness.controller.panes[TerminalID(uuid: id.uuid)])
        #expect(!pane.chrome.isShowingStartup)
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
