import Foundation
import GitStatus
import Testing
import TkzCore
@testable import TkzApp

/// The app-side half of M4: which directory a row is watched at, and how a port scan becomes
/// store state. The services themselves are tested in `GitStatusTests`; what is asserted here is
/// the attribution — the part that knows what a `Session` is.
@MainActor
struct GitIntegrationTests {

    static func stateWithSession(
        cwd: String = "/tmp/repo",
        live: LiveSessionState? = LiveSessionState(shellPid: 4_242)
    ) -> (AppState, SessionID) {
        var state = AppState()
        let group = state.addGroup(name: "repo", repoRoot: cwd)
        let session = state.createSession(groupID: group.id, cwd: cwd)
        state.setLive(live, for: session.id)
        return (state, session.id)
    }

    // MARK: Tracking

    @Test func onlyLiveRowsAreTracked() {
        var (state, live) = Self.stateWithSession()
        // A restored row: in `state.json`, no shell behind it, nothing running in its directory.
        let group = state.orderedGroups[0].id
        let restored = state.createSession(groupID: group, cwd: "/tmp/other")
        #expect(state.sessions[restored.id]?.live == nil)

        let targets = GitIntegration.trackingTargets(in: state)
        #expect(targets[live] == "/tmp/repo")
        #expect(targets[restored.id] == nil)
    }

    @Test func theShellsOwnCwdWinsOverTheLaunchDirectory() {
        // OSC 7 from the ZDOTDIR wrapper: the user `cd`'d into a different repo. The status bar
        // must follow, exactly as the row's title does.
        var (state, id) = Self.stateWithSession()
        state.setShellCwd(id, path: "/tmp/elsewhere")
        #expect(GitIntegration.trackingTargets(in: state)[id] == "/tmp/elsewhere")
    }

    @Test func claudesOwnDirectoryOutranksTheShells() {
        var (state, id) = Self.stateWithSession()
        state.setShellCwd(id, path: "/tmp/elsewhere")
        state.updateLive(id) {
            $0.descriptor = ClaudeSessionInfo(
                configDir: "/home/.claude", pid: 99, sessionId: "s", cwd: "/tmp/claude-cwd")
        }
        #expect(GitIntegration.trackingTargets(in: state)[id] == "/tmp/claude-cwd")
    }

    // MARK: Ports

    @Test func aScanBecomesPortsAndOwnerTooltips() {
        let (state, id) = Self.stateWithSession()
        let store = AppStore(state: state)
        let integration = GitIntegration(store: store, scanPorts: { _ in [] })

        integration.applyPorts([
            ListeningPort(port: 3_000, pid: 900, processName: "node"),
            ListeningPort(port: 5_173, pid: 901, processName: "vite"),
        ], to: id)

        #expect(store.state.sessions[id]?.live?.ports == [3_000, 5_173])
        #expect(store.state.sessions[id]?.live?.portOwners[3_000] == "node (pid 900)")
        #expect(store.state.sessions[id]?.live?.portOwners[5_173] == "vite (pid 901)")
    }

    @Test func anUnchangedScanCostsNoDelivery() {
        // The 10 s cadence must not re-render the sidebar every 10 s: an identical scan has to
        // diff as unchanged all the way through the store.
        let (state, id) = Self.stateWithSession()
        let store = AppStore(state: state)
        let integration = GitIntegration(store: store, scanPorts: { _ in [] })
        let found = [ListeningPort(port: 8_080, pid: 7, processName: "python3")]

        integration.applyPorts(found, to: id)
        store.flush()
        let after = store.deliveryCount
        integration.applyPorts(found, to: id)
        store.flush()
        #expect(store.deliveryCount == after)
    }

    @Test func aPortWithNoNameStillReportsItsPort() {
        let (state, id) = Self.stateWithSession()
        let store = AppStore(state: state)
        let integration = GitIntegration(store: store, scanPorts: { _ in [] })
        integration.applyPorts([ListeningPort(port: 1_234, pid: 3, processName: nil)], to: id)
        #expect(store.state.sessions[id]?.live?.ports == [1_234])
        #expect(store.state.sessions[id]?.live?.portOwners.isEmpty == true)
    }

    // MARK: Store guards

    @Test func gitAndPortsAreRefusedForARowWithNoShell() {
        // `setGitSummary` / `setPorts` guard on `live`, so a race between "the row was removed"
        // and "the scan finished" cannot resurrect a dead row with a branch name.
        var state = AppState()
        let group = state.addGroup(name: "repo", repoRoot: "/tmp/repo")
        let session = state.createSession(groupID: group.id, cwd: "/tmp/repo")
        state.setGitSummary(GitSummary(branch: "develop"), for: session.id)
        state.setPorts([3_000], owners: [:], for: session.id)
        #expect(state.sessions[session.id]?.live == nil)
    }
}

/// `MainWindowController.statusModel(for:)` — the pure mapping from the store to the strip. M4.2
/// added the fields the git, PR and port services fill in; this is where "what the services learned
/// becomes what the user sees" is asserted without a window.
@MainActor
struct StatusModelMappingTests {

    static func state(
        git: GitSummary? = nil,
        sidecar: SessionSidecar? = nil,
        ports: [UInt16] = [],
        portOwners: [UInt16: String] = [:],
        worktreePath: String? = nil,
        isWorktree: Bool = false
    ) -> AppState {
        var state = AppState()
        let group = state.addGroup(name: "toolbox", repoRoot: "/tmp/toolbox")
        let session = state.createSession(
            groupID: group.id, cwd: "/tmp/toolbox",
            worktreePath: worktreePath, isWorktree: isWorktree)
        state.setLive(
            LiveSessionState(git: git, ports: ports, portOwners: portOwners, context: sidecar),
            for: session.id)
        state.select(session.id)
        return state
    }

    @Test func noUpstreamBecomesTheDimmedState() {
        let model = MainWindowController.statusModel(
            for: Self.state(git: GitSummary(branch: "spike", ahead: 0, behind: 0)))
        #expect(model.upstreamMissing)
        #expect(model.ahead == nil)
        #expect(model.behind == nil)
        #expect(model.upstream == nil)
    }

    @Test func anUpstreamBringsTheCountsBack() {
        let summary = GitSummary(branch: "develop", upstream: "origin/develop", ahead: 1, behind: 2)
        let model = MainWindowController.statusModel(for: Self.state(git: summary))
        #expect(model.upstreamMissing == false)
        #expect(model.ahead == 1)
        #expect(model.behind == 2)
        #expect(model.upstream == "origin/develop")
    }

    @Test func noGitAtAllLeavesEveryGitFieldUnknown() {
        let model = MainWindowController.statusModel(for: Self.state())
        #expect(model.branch == nil)
        #expect(model.upstreamMissing == false)   // not "no upstream": nothing has reported yet
        #expect(model.diffAdded == nil)
    }

    @Test func theLookedUpPullRequestWinsOverTheSidecarsOnlyWhenThereIsOne() {
        let looked = PRInfo(number: 12, state: "OPEN")
        let sidecarPR = PRInfo(number: 99, state: "MERGED")
        let sidecar = SessionSidecar(sessionId: "s", pr: sidecarPR)

        let both = MainWindowController.statusModel(
            for: Self.state(git: GitSummary(branch: "b", pr: looked), sidecar: sidecar))
        #expect(both.pullRequest?.number == 12)

        // Nothing looked up yet (or `gh` is not installed): the sidecar still shows a PR.
        let sidecarOnly = MainWindowController.statusModel(
            for: Self.state(git: GitSummary(branch: "b"), sidecar: sidecar))
        #expect(sidecarOnly.pullRequest?.number == 99)
    }

    @Test func theWorktreeNameReachesTheBadgeTooltip() {
        let model = MainWindowController.statusModel(for: Self.state(
            worktreePath: "/tmp/toolbox/.claude/worktrees/tkz-26", isWorktree: true))
        #expect(model.isWorktree == true)
        #expect(model.worktreeName == "tkz-26")
    }

    @Test func portOwnersArePassedThroughForTheTooltips() {
        let model = MainWindowController.statusModel(for: Self.state(
            ports: [3_000], portOwners: [3_000: "node (pid 900)"]))
        #expect(model.ports == [3_000])
        #expect(model.portOwners[3_000] == "node (pid 900)")
    }

    @Test func theUsageTooltipListsEveryAccountsWindow() throws {
        var state = Self.state()
        state.setAccount(Account(key: "claude", configDir: "/h/.claude", label: "Private"))
        state.setAccount(Account(key: "claude-work", configDir: "/h/.claude-work", label: "Work"))
        state.setUsage(UsageSnapshot(
            accountKey: "claude", label: "Private",
            sevenDay: UsageWindow(usedPercentage: 5)))
        state.setUsage(UsageSnapshot(
            accountKey: "claude-work", label: "Work",
            sevenDay: UsageWindow(usedPercentage: 61)))

        let tooltip = try #require(MainWindowController.statusModel(for: state).usageTooltip)
        #expect(tooltip == """
            Private: 5% of the seven-day quota
            Work: 61% of the seven-day quota
            """)

        // The configured name wins over the one the usage file generated, so the strip and the
        // sidebar chip (which reads `Account.label`) never call one account two things.
        state.setUsage(UsageSnapshot(
            accountKey: "claude-work", label: "Work Inc AB",
            sevenDay: UsageWindow(usedPercentage: 61)))
        #expect(state.accounts["claude-work"]?.label == "Work")
        #expect(try #require(MainWindowController.statusModel(for: state).usageTooltip).contains(
            "Work: 61%"))

        // An account nobody has named falls back to whatever the usage file offers.
        state.setAccount(Account(key: "claude-spare", configDir: "/h/.claude-spare", label: "claude-spare"))
        state.setUsage(UsageSnapshot(
            accountKey: "claude-spare", label: "Spare", sevenDay: UsageWindow(usedPercentage: 2)))
        #expect(try #require(MainWindowController.statusModel(for: state).usageTooltip).contains(
            "Spare: 2%"))
    }

    @Test func theResetsTooltipIsLocaleIndependent() {
        var state = Self.state()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        state.setUsage(UsageSnapshot(
            accountKey: "claude",
            sevenDay: UsageWindow(usedPercentage: 5, resetsAt: now.addingTimeInterval(3_600))))
        let model = MainWindowController.statusModel(for: state, now: now)
        #expect(model.usageResetsIn == .seconds(3_600))
        // Same instant, same string, on any machine: the formatter is POSIX and fixed-format.
        #expect(model.usageResetsAtText == MainWindowController.resetsAtFormatter.string(
            from: now.addingTimeInterval(3_600)))
        #expect(model.usageResetsAtText?.count == 16)
    }
}
