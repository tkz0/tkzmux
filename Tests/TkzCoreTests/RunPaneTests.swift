// The ▶ Run button's state: which pane is running the dev server, whether its command
// is still going, and the command the group remembers for every row in it.

import Foundation
import Testing

@testable import TkzCore

@Suite struct RunPaneTests {
    /// A group on a repo, one live row in it split into agent pane + run pane.
    private func makeState(repoRoot: String? = "/repo") -> (AppState, SessionID, TerminalID) {
        var state = AppState()
        let group = state.addGroup(name: "G", repoRoot: repoRoot)
        let session = state.createSession(groupID: group.id, cwd: "/repo")
        state.sessions[session.id]?.live = LiveSessionState()
        let agentPane = state.sessions[session.id]!.focusedTerminalID
        let runPane = state.splitPane(agentPane, axis: .vertical)!
        return (state, session.id, runPane)
    }

    // MARK: Run pane

    @Test func beginMarksThePaneRunning() {
        var (state, id, pane) = makeState()
        #expect(state.sessions[id]?.live?.runPane == nil)
        state.beginRunPane(id, terminal: pane, command: "pnpm dev")
        #expect(state.sessions[id]?.live?.runPane == RunPane(terminal: pane, command: "pnpm dev", running: true))
    }

    /// The boot command's OSC 9;4 *remove*: Ctrl-C, a crash, or the server exiting by itself. The
    /// pane stays — its logs are what the user wants to read — and ▶ comes back.
    @Test func theCommandReturningStopsItButKeepsThePane() {
        var (state, id, pane) = makeState()
        state.beginRunPane(id, terminal: pane, command: "pnpm dev")
        state.runPaneReturned(pane)
        #expect(state.sessions[id]?.live?.runPane == RunPane(terminal: pane, command: "pnpm dev", running: false))
    }

    /// A remove marker from any other pane — the agent's own boot command returning — is not this.
    @Test func anotherPaneReturningIsIgnored() {
        var (state, id, pane) = makeState()
        state.beginRunPane(id, terminal: pane, command: "pnpm dev")
        let agentPane = state.sessions[id]!.terminalIDs.first { $0 != pane }!
        state.runPaneReturned(agentPane)
        #expect(state.sessions[id]?.live?.runPane?.running == true)
    }

    @Test func closingThePaneForgetsIt() {
        var (state, id, pane) = makeState()
        state.beginRunPane(id, terminal: pane, command: "pnpm dev")
        let closed = state.closePane(pane)
        #expect(closed)
        #expect(state.sessions[id]?.live?.runPane == nil)
    }

    /// Running again respawns the same leaf: `begin` on it again is running with the new command.
    @Test func beginAgainReplacesTheCommand() {
        var (state, id, pane) = makeState()
        state.beginRunPane(id, terminal: pane, command: "pnpm dev")
        state.runPaneReturned(pane)
        state.beginRunPane(id, terminal: pane, command: "pnpm dev:web")
        #expect(state.sessions[id]?.live?.runPane == RunPane(terminal: pane, command: "pnpm dev:web", running: true))
    }

    /// A pane that does not belong to the row is refused rather than recorded.
    @Test func aForeignPaneIsRefused() {
        var (state, id, _) = makeState()
        state.beginRunPane(id, terminal: .generate(), command: "pnpm dev")
        #expect(state.sessions[id]?.live?.runPane == nil)
    }

    /// Row status is the agent's alone: a dev server starting next to it changes nothing there.
    @Test func runningLeavesTheRowStatusAlone() {
        var (state, id, pane) = makeState()
        let before = state.sessions[id]?.status
        state.beginRunPane(id, terminal: pane, command: "pnpm dev")
        #expect(state.sessions[id]?.status == before)
        #expect(state.sessions[id]?.live?.agentTerminal == nil)
    }

    // MARK: Where it runs

    /// The checkout the row works in, never the main one: git's toplevel is a worktree's own
    /// directory. Before git has answered, a worktree row still knows its path.
    @Test func runDirectoryIsTheRowsOwnCheckout() {
        let group = GroupID.generate()
        let worktree = Session(
            groupID: group, cwd: "/repo", repoRoot: "/repo",
            worktreePath: "/repo/.claude/worktrees/wt", isWorktree: true, accountKey: "claude")
        #expect(worktree.runDirectory(gitToplevel: "/repo/.claude/worktrees/wt") == "/repo/.claude/worktrees/wt")
        #expect(worktree.runDirectory(gitToplevel: nil) == "/repo/.claude/worktrees/wt")

        // A row that `cd`'d into a worktree without being started as one: git says where it is.
        var plain = Session(groupID: group, cwd: "/repo", repoRoot: "/repo", accountKey: "claude")
        #expect(plain.runDirectory(gitToplevel: "/repo/.claude/worktrees/other") == "/repo/.claude/worktrees/other")
        // No git answer and no worktree: where the row is standing.
        plain.live = LiveSessionState(shellCwd: "/repo/web")
        #expect(plain.runDirectory(gitToplevel: nil) == "/repo/web")
        #expect(plain.runDirectory(gitToplevel: "") == "/repo/web")
    }

    // MARK: Remembered command

    @Test func rememberingWritesTheGroupAndEveryRowInItSeesIt() {
        var (state, id, _) = makeState()
        let groupID = state.sessions[id]!.groupID
        // A second row in the same group — another worktree of the same repo.
        let other = state.createSession(groupID: groupID, cwd: "/repo/.claude/worktrees/x")

        state.rememberRunCommand("pnpm dev:web", for: id)
        #expect(state.groups[groupID]?.runCommand == "pnpm dev:web")
        #expect(state.rememberedRunCommand(for: other.id) == "pnpm dev:web")

        // "Reset to detected".
        state.rememberRunCommand(nil, for: other.id)
        #expect(state.groups[groupID]?.runCommand == nil)
        #expect(state.rememberedRunCommand(for: id) == nil)
    }

    @Test func blankIsForgetting() {
        var (state, id, _) = makeState()
        state.rememberRunCommand("pnpm dev", for: id)
        state.rememberRunCommand("   ", for: id)
        #expect(state.rememberedRunCommand(for: id) == nil)
    }

    /// A bucket group ("Elsewhere") holds unrelated directories, so one row's choice must not
    /// become every other row's ▶.
    @Test func aGroupWithNoRepoRemembersNothing() {
        var (state, id, _) = makeState(repoRoot: nil)
        state.rememberRunCommand("pnpm dev", for: id)
        #expect(state.groups[state.sessions[id]!.groupID]?.runCommand == nil)
        #expect(state.rememberedRunCommand(for: id) == nil)
    }

    /// The change set: a run pane is a row change, a remembered command is a group change.
    @Test func changeSetBuckets() {
        let (state, id, pane) = makeState()
        var running = state
        running.beginRunPane(id, terminal: pane, command: "pnpm dev")
        let rowChange = ChangeSet.diff(from: state, to: running)
        #expect(rowChange.sessions == [id])
        #expect(rowChange.layout.isEmpty)
        #expect(!rowChange.structure)

        var remembered = state
        remembered.rememberRunCommand("pnpm dev", for: id)
        let groupChange = ChangeSet.diff(from: state, to: remembered)
        #expect(groupChange.groups == [state.sessions[id]!.groupID])
        #expect(groupChange.sessions.isEmpty)
    }
}
