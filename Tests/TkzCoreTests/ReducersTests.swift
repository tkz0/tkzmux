// The reducers, exercised without a store — they are plain `mutating` methods on `AppState`.

import Foundation
import Testing

@testable import TkzCore

@Suite struct SessionReducerTests {
    let group = Fixture.groupID(0)

    @Test func createAppendsAndInheritsTheGroupDefaults() {
        var state = AppState.fixture
        let before = state.sessions(in: group).count
        let created = state.createSession(groupID: group, cwd: "~/dev/northwind")
        #expect(state.sessions(in: group).count == before + 1)
        #expect(state.sessions(in: group).last?.id == created.id)
        #expect(created.order == before)
        #expect(created.accountKey == state.groups[group]?.defaultAccountKey)
        #expect(created.repoRoot == state.groups[group]?.repoRoot)
        #expect(created.status == .idle)  // nothing is running yet; idle until its shell is spawned
    }

    @Test func createExpandsACollapsedTargetGroup() {
        var state = AppState.fixture
        let collapsed = Fixture.groupID(4)  // "Playground" — collapsed in the fixture
        #expect(state.groups[collapsed]?.isCollapsed == true)
        state.createSession(groupID: collapsed, cwd: "/tmp/new")
        #expect(state.groups[collapsed]?.isCollapsed == false, "a new row nobody can see is a bug")

        // An already-expanded group is left exactly as it was, so the diff stays session-only.
        let before = state.groups[group]
        state.createSession(groupID: group, cwd: "/tmp/other")
        #expect(state.groups[group] == before)
    }

    @Test func createFallsBackToTheDefaultAccount() {
        var state = AppState()
        let g = state.addGroup(name: "Bucket")
        let session = state.createSession(groupID: g.id, cwd: "/tmp")
        #expect(session.accountKey == Account.defaultKey(for: .claude))
    }

    @Test func adoptBindsTheObservationAndRecordsTheResumeID() {
        var state = AppState.fixture
        let id = Fixture.sessionID(4)  // a restored fixture row (no live state)
        #expect(state.sessions[id]?.live == nil)
        let observation = AgentObservation(
            pid: 900, conversationId: "new-session-id", configDir: "~/.claude-work",
            activity: .busy, name: "adopted", nameIsDerived: false)
        state.adoptDescriptor(observation, for: id)
        #expect(state.sessions[id]?.live?.pid == 900)
        #expect(state.sessions[id]?.conversationId == "new-session-id")
        #expect(state.sessions[id]?.live?.observation?.name == "adopted")
        // Adopting an unknown session is a no-op, not a crash.
        let count = state.sessions.count
        state.adoptDescriptor(observation, for: .generate())
        #expect(state.sessions.count == count)
    }

    @Test func setStatusRaisesTheAttentionFlagOnlyForDoneUnattended() {
        var state = AppState.fixture
        let id = Fixture.sessionID(0)
        state.setStatus(.waiting(.doneUnattended), for: id)
        #expect(state.sessions[id]?.needsAttention == true)
        state.setStatus(.working, for: id)
        #expect(state.sessions[id]?.needsAttention == false)
        state.setStatus(.waiting(.permission), for: id, attention: true)
        #expect(state.sessions[id]?.needsAttention == true)
    }

    @Test func renameTrimsAndClears() {
        var state = AppState.fixture
        let id = Fixture.sessionID(0)
        state.renameSession(id, title: "  review  ")
        #expect(state.sessions[id]?.title == "review")
        state.renameSession(id, title: "   ")
        #expect(state.sessions[id]?.title == nil)
    }

    @Test func titleDerivationFollowsTheDesignOrder() {
        var session = Session(groupID: .generate(), cwd: "/repo/app", accountKey: "claude")
        #expect(session.displayTitle == "app")  // basename(cwd)
        session.worktreePath = "/repo/.claude/worktrees/pricing"
        session.isWorktree = true
        #expect(session.displayTitle == "pricing")  // worktree name
        session.live = LiveSessionState(
            observation: AgentObservation(pid: 1, conversationId: "s", configDir: "~/.claude",
                                          name: "from claude", nameIsDerived: false))
        #expect(session.displayTitle == "from claude")  // the agent's own name
        session.live?.observation?.nameIsDerived = true
        #expect(session.displayTitle == "pricing")  // a derived name loses to the worktree
        session.title = "user rename"
        #expect(session.displayTitle == "user rename")  // the rename always wins

        // Claude's own cwd beats the shell's starting directory once an observation is bound.
        var moved = Session(groupID: GroupID.generate(), cwd: "/Users/x", accountKey: "claude")
        moved.live = LiveSessionState(observation: AgentObservation(
            pid: 1, conversationId: "s", configDir: "/Users/x/.claude", cwd: "/Users/x/dev/app",
            name: "app-3f", nameIsDerived: true))
        #expect(moved.displayTitle == "app")
    }

    @Test func directoryTitleIsTheFolderWhateverTheTitleSays() {
        // No override: the two agree, so the sidebar shows no `…/folder`.
        var session = Session(groupID: .generate(), cwd: "/repo/app", accountKey: "claude")
        #expect(session.directoryTitle == "app")
        #expect(session.directoryTitle == session.displayTitle)

        // Claude's name, a derived name, a rename: the folder stays the folder.
        session.live = LiveSessionState(
            observation: AgentObservation(pid: 1, conversationId: "s", configDir: "~/.claude",
                                          name: "from claude", nameIsDerived: false))
        #expect(session.displayTitle == "from claude")
        #expect(session.directoryTitle == "app")
        session.live?.observation?.nameIsDerived = true
        #expect(session.directoryTitle == "app")
        session.title = "user rename"
        #expect(session.directoryTitle == "app")

        // A worktree session's folder is the worktree, as its default title would be.
        session.worktreePath = "/repo/.claude/worktrees/pricing"
        session.isWorktree = true
        #expect(session.directoryTitle == "pricing")

        // And Claude's own cwd beats the start dir, exactly as for the title.
        var moved = Session(groupID: GroupID.generate(), cwd: "/Users/x", accountKey: "claude")
        moved.live = LiveSessionState(observation: AgentObservation(
            pid: 1, conversationId: "s", configDir: "/Users/x/.claude", cwd: "/Users/x/dev/app",
            name: "Track updated fields", nameIsDerived: false))
        #expect(moved.directoryTitle == "app")
        #expect(moved.displayTitle == "Track updated fields")
    }

    @Test func moveBetweenGroupsRenumbersBothSides() {
        var state = AppState.fixture
        let id = Fixture.sessionID(1)
        let destination = Fixture.groupID(3)
        state.moveSession(id, toGroup: destination, at: 0)
        #expect(state.sessions[id]?.groupID == destination)
        #expect(state.sessions(in: destination).first?.id == id)
        #expect(state.sessions(in: destination).map(\.order) == Array(0..<state.sessions(in: destination).count))
        #expect(state.sessions(in: Fixture.groupID(0)).map(\.order)
            == Array(0..<state.sessions(in: Fixture.groupID(0)).count))
    }

    @Test func reorderWithinAGroupIsContiguous() {
        var state = AppState.fixture
        let group = Fixture.groupID(1)
        let ids = state.sessions(in: group).map(\.id)
        state.reorderSession(ids[3], to: 0)
        let after = state.sessions(in: group)
        #expect(after.first?.id == ids[3])
        #expect(after.map(\.order) == Array(0..<after.count))
    }

    @Test func moveClampsOutOfRangeIndices() {
        var state = AppState.fixture
        let group = Fixture.groupID(4)
        let ids = state.sessions(in: group).map(\.id)
        state.moveSession(ids[0], toGroup: group, at: 999)
        #expect(state.sessions(in: group).last?.id == ids[0])
        state.moveSession(ids[0], toGroup: group, at: -5)
        #expect(state.sessions(in: group).first?.id == ids[0])
    }

    /// Remove deletes the row; there is no "close but keep" (decision 2026-09-08).
    @Test func removeDeletesTheRow() {
        var state = AppState.fixture
        let id = Fixture.sessionID(0)
        let count = state.sessions.count
        state.removeSession(id)
        #expect(state.sessions[id] == nil)
        #expect(state.sessions.count == count - 1)
    }

    @Test func removingTheSelectedSessionSelectsItsNeighbour() {
        var state = AppState.fixture
        let ordered = state.orderedSessions
        state.select(ordered[0].id)
        state.removeSession(ordered[0].id)
        #expect(state.selection == ordered[1].id)

        // Removing the very last row falls back to the previous one.
        var tail = AppState.fixture
        let last = tail.orderedSessions.last!
        let penultimate = tail.orderedSessions.dropLast().last!
        tail.select(last.id)
        tail.removeSession(last.id)
        #expect(tail.selection == penultimate.id)
    }

    @Test func resumeDirectoryPrefersTheWorktree() {
        // `claude -w` runs from the repo root, so cwd == repoRoot for a worktree session.
        var session = Session(groupID: .generate(), cwd: "/repo", repoRoot: "/repo",
                              worktreePath: "/repo/.claude/worktrees/wt", isWorktree: true,
                              accountKey: "claude")
        #expect(session.resumeDirectory == "/repo/.claude/worktrees/wt")
        #expect(session.resumeDirectoryCandidates == ["/repo/.claude/worktrees/wt", "/repo"])
        session.isWorktree = false  // worktree gone → repo root, badge cleared
        #expect(session.resumeDirectory == "/repo")
        #expect(session.resumeDirectoryCandidates == ["/repo"])
    }

    @Test func resumeDirectoryCandidatesPutTheStartDirectoryBeforeTheRepoRoot() {
        // A session opened elsewhere: Claude ran in `cwd`, which is the project `--resume` looks under,
        // so it outranks the group's repo root. The launcher takes the first that exists (M5.2).
        let fixed = Session(groupID: .generate(), cwd: "/elsewhere", repoRoot: "/repo",
                            accountKey: "claude")
        #expect(fixed.resumeDirectoryCandidates == ["/elsewhere", "/repo"])
        let bare = Session(groupID: .generate(), cwd: "/home", accountKey: "claude")
        #expect(bare.resumeDirectoryCandidates == ["/home"])
    }

    @Test func titleIsTheLastPathSegment() {
        #expect(Session.title(forPath: "/Users/x/dev/toolbox/") == "toolbox")
        #expect(Session.title(forPath: "/Users/x/dev/toolbox") == "toolbox")
        #expect(Session.title(forPath: "/Users/someone") == "someone")
        #expect(Session.title(forPath: "/") == "/")
        #expect(Session.title(forPath: "~") == (NSHomeDirectory() as NSString).lastPathComponent)
        #expect(Session.title(forPath: "~/dev/x/") == "x")

        // Rename → Claude's auto-name → worktree name (+ WT) → Claude's cwd → the start dir.
        var session = Session(groupID: .generate(), cwd: "/Users/x/dev/toolbox/", accountKey: "claude")
        #expect(session.displayTitle == "toolbox")
        session.worktreePath = "/Users/x/dev/.claude/worktrees/hello"
        session.isWorktree = true
        #expect(session.displayTitle == "hello")
        session.title = "mine"
        #expect(session.displayTitle == "mine")
    }

    @Test func theTitleFollowsTheShellsReportedDirectory() {
        var state = AppState()
        let group = state.addGroup(name: "home", repoRoot: "/Users/x")
        let session = state.createSession(groupID: group.id, cwd: "/Users/x", accountKey: "claude")
        #expect(state.sessions[session.id]?.displayTitle == "x")

        // A restored row has no live state: OSC 7 for it is ignored (there is no shell).
        state.setShellCwd(session.id, path: "/Users/x/dev/toolbox")
        #expect(state.sessions[session.id]?.displayTitle == "x")

        state.setLive(LiveSessionState(shellPid: 1), for: session.id)
        state.setShellCwd(session.id, path: "/Users/x/dev/toolbox/")
        #expect(state.sessions[session.id]?.displayTitle == "toolbox")
        #expect(state.sessions[session.id]?.effectiveCwd == "/Users/x/dev/toolbox/")
        #expect(state.sessions[session.id]?.cwd == "/Users/x", "the start directory is not rewritten by a cd")

        // Inside a worktree the badge shows, without touching the persisted flag.
        state.setShellCwd(session.id, path: "/Users/x/dev/repo/.claude/worktrees/hello")
        #expect(state.sessions[session.id]?.displayTitle == "hello")
        #expect(state.sessions[session.id]?.showsWorktreeBadge == true)
        #expect(state.sessions[session.id]?.isWorktree == false)

        // Claude's own cwd wins while an observation is bound, and becomes the directory of record.
        state.applyObservation(
            AgentObservation(pid: 9, conversationId: "s", configDir: "/Users/x/.claude", cwd: "/Users/x/dev/repo"),
            alive: true, to: session.id)
        #expect(state.sessions[session.id]?.displayTitle == "repo")
        #expect(state.sessions[session.id]?.cwd == "/Users/x/dev/repo")
        #expect(state.sessions[session.id]?.showsWorktreeBadge == false)

        // Claude gone: back to the shell's cwd.
        state.agentLost(for: session.id)
        #expect(state.sessions[session.id]?.displayTitle == "hello")

        state.setShellCwd(session.id, path: "")
        #expect(state.sessions[session.id]?.displayTitle == "repo", "an empty report falls back to the directory of record")
    }

    @Test func worktreeRootOfPath() {
        var state = AppState()
        let group = state.addGroup(name: "repo", repoRoot: "/repo")
        let claudeSession = state.createSession(groupID: group.id, cwd: "/repo", accountKey: "claude")
        #expect(claudeSession.worktreeRoot(ofPath: "/repo/.claude/worktrees/review") == "/repo/.claude/worktrees/review")
        #expect(claudeSession.worktreeRoot(ofPath: "/repo/.claude/worktrees/review/src/deep") == "/repo/.claude/worktrees/review")
        #expect(claudeSession.worktreeRoot(ofPath: "/repo/.claude/worktrees/") == nil)
        #expect(claudeSession.worktreeRoot(ofPath: "/repo/.claude/worktrees") == nil)
        #expect(claudeSession.worktreeRoot(ofPath: "/repo/src") == nil)
        #expect(claudeSession.worktreeRoot(ofPath: "~/dev/x/.claude/worktrees/a") == "~/dev/x/.claude/worktrees/a")

        // The whole point of TKZ-79: Codex has no worktree marker, so the same paths that resolve
        // for a Claude session must resolve to nothing at all for a Codex one.
        let codexSession = state.createSession(groupID: group.id, cwd: "/repo", agent: .codex, accountKey: "codex")
        #expect(codexSession.worktreeRoot(ofPath: "/repo/.claude/worktrees/review") == nil)
        #expect(codexSession.worktreeRoot(ofPath: "~/dev/x/.claude/worktrees/a") == nil)
    }

    /// A Codex row sitting inside a `.claude/worktrees/…` directory (e.g. a Codex session started
    /// inside a Claude worktree) must not claim the `WT` badge — that badge is Claude's marker, and
    /// Codex knows nothing about the directory it happens to be standing in.
    @Test func aCodexSessionInsideAClaudeWorktreeDoesNotShowTheBadge() {
        var state = AppState()
        let group = state.addGroup(name: "repo", repoRoot: "/repo")
        let session = state.createSession(
            groupID: group.id, cwd: "/repo/.claude/worktrees/x", agent: .codex, accountKey: "codex")
        #expect(state.sessions[session.id]?.showsWorktreeBadge == false)
    }

    @Test func observationInsideAWorktreeSetsTheBadge() {
        var state = AppState()
        let group = state.addGroup(name: "repo", repoRoot: "/repo")
        let session = state.createSession(groupID: group.id, cwd: "/repo", accountKey: "claude")
        state.setLive(LiveSessionState(shellPid: 1), for: session.id)
        #expect(state.sessions[session.id]?.isWorktree == false)

        // `claude -w` reports the worktree it created as its cwd.
        let observation = AgentObservation(
            pid: 99, conversationId: "sid-1", configDir: "/home/.claude",
            cwd: "/repo/.claude/worktrees/tkz-30", activity: .idle)
        state.applyObservation(observation, alive: true, to: session.id)
        #expect(state.sessions[session.id]?.isWorktree == true)
        #expect(state.sessions[session.id]?.worktreePath == "/repo/.claude/worktrees/tkz-30")
        #expect(state.sessions[session.id]?.displayTitle == "tkz-30")

        // A plain repo-root observation leaves a non-worktree row alone.
        var plain = AppState()
        let g2 = plain.addGroup(name: "repo", repoRoot: "/repo")
        let s2 = plain.createSession(groupID: g2.id, cwd: "/repo", accountKey: "claude")
        plain.applyObservation(
            AgentObservation(pid: 7, conversationId: "sid-2", configDir: "/home/.claude", cwd: "/repo"),
            alive: true, to: s2.id)
        #expect(plain.sessions[s2.id]?.isWorktree == false)
        #expect(plain.sessions[s2.id]?.worktreePath == nil)
    }

    @Test func clearingTheWorktreeBadgeKeepsThePath() {
        var state = AppState()
        let group = state.addGroup(name: "repo", repoRoot: "/repo")
        let session = state.createSession(
            groupID: group.id, cwd: "/repo", worktreePath: "/repo/.claude/worktrees/x",
            isWorktree: true, accountKey: "claude")
        state.clearWorktreeBadge(session.id)
        #expect(state.sessions[session.id]?.isWorktree == false)
        #expect(state.sessions[session.id]?.worktreePath == "/repo/.claude/worktrees/x")
        #expect(state.sessions[session.id]?.resumeDirectory == "/repo")
        state.setWorktree(session.id, path: "/repo/.claude/worktrees/y", isWorktree: true)
        #expect(state.sessions[session.id]?.worktreePath == "/repo/.claude/worktrees/y")
        #expect(state.sessions[session.id]?.isWorktree == true)
    }

    @Test func accountConfigDirectoryIsDerivedFromTheKey() {
        // The primary is spelled out too: a resume must land on `~/.claude` even when the user's
        // environment defaults to another account.
        #expect(Account.configDirectory(forKey: "claude", home: "/Users/x") == "/Users/x/.claude")
        #expect(Account.configDirectory(forKey: "claude-work", home: "/Users/x") == "/Users/x/.claude-work")
        #expect(Account.configDirectory(forKey: "claude-work", home: "/Users/x/") == "/Users/x/.claude-work")
        #expect(Account.configDirectory(forKey: "", home: "/Users/x") == nil)
        #expect(Account.configDirectory(forKey: "../etc", home: "/Users/x") == nil)
        #expect(Account.key(forConfigDirectory: "/Users/x/.claude-work") == "claude-work")
        #expect(Account.key(forConfigDirectory: "/Users/x/.claude") == "claude")
        #expect(Account.key(forConfigDirectory: "/Users/x/.claude/") == "claude")
    }

    @Test func setSessionAccountFollowsTheProcess() {
        var state = AppState()
        let group = state.addGroup(name: "repo", repoRoot: "/repo")
        let session = state.createSession(groupID: group.id, cwd: "/repo")
        #expect(state.sessions[session.id]?.accountKey == "claude")
        state.setSessionAccount(session.id, key: "claude-work")
        #expect(state.sessions[session.id]?.accountKey == "claude-work")
        state.setSessionAccount(session.id, key: "")
        #expect(state.sessions[session.id]?.accountKey == "claude-work")
    }

    @Test func autoResumePreferenceIsAChromeChange() {
        var state = AppState()
        let before = state
        state.setAutoResumeOnLaunch(true)
        let change = ChangeSet.diff(from: before, to: state)
        #expect(change.chrome)
        #expect(change.structure == false)
        #expect(change.sessions.isEmpty)
    }

    @Test func showSessionSpendIsASessionsChangeForEveryRowNotChrome() {
        var state = AppState()
        let group = state.addGroup(name: "G", repoRoot: "/repo")
        let a = state.createSession(groupID: group.id, cwd: "/repo")
        let b = state.createSession(groupID: group.id, cwd: "/repo")
        let before = state
        state.setShowSessionSpend(false)
        let change = ChangeSet.diff(from: before, to: state)
        #expect(change.chrome == false)
        #expect(change.structure == false)
        #expect(change.sessions == [a.id, b.id])
    }

    @Test func disablingShowSessionSpendDoesNotFabricateLiveStateForADormantSession() {
        // A restored-but-never-shown row has `live == nil`: flipping
        // the global switch off must not wake one into existence just to clear a figure it never
        // had. `updateLive` would otherwise do exactly that.
        var state = AppState()
        let group = state.addGroup(name: "G", repoRoot: "/repo")
        let dormant = state.createSession(groupID: group.id, cwd: "/repo")
        #expect(state.sessions[dormant.id]?.live == nil)

        state.setShowSessionSpend(false)
        #expect(state.sessions[dormant.id]?.live == nil)
    }

    @Test func disablingShowSessionSpendClearsEverySessionsLiveUsage() {
        var state = AppState()
        let group = state.addGroup(name: "G", repoRoot: "/repo")
        let created = state.createSession(groupID: group.id, cwd: "/repo")
        state.updateLive(created.id) {
            $0.usage = SessionUsage(perModel: [], totalCostUSD: 1.23, lastUpdatedAt: Date())
        }
        #expect(state.sessions[created.id]?.live?.usage != nil)

        state.setShowSessionSpend(false)
        #expect(state.sessions[created.id]?.live?.usage == nil)
    }

    @Test func setSpendTrackingDisabledOnADormantSessionSetsTheFlagWithoutFabricatingLiveState() {
        var state = AppState()
        let group = state.addGroup(name: "G", repoRoot: "/repo")
        let dormant = state.createSession(groupID: group.id, cwd: "/repo")
        #expect(state.sessions[dormant.id]?.live == nil)

        state.setSpendTrackingDisabled(dormant.id, true)
        #expect(state.sessions[dormant.id]?.spendTrackingDisabled == true)
        #expect(state.sessions[dormant.id]?.live == nil)
    }

    @Test func setSpendTrackingDisabledTogglesOneSessionAndClearsItsUsage() {
        var state = AppState()
        let group = state.addGroup(name: "G", repoRoot: "/repo")
        let session = state.createSession(groupID: group.id, cwd: "/repo")
        state.updateLive(session.id) {
            $0.usage = SessionUsage(perModel: [], totalCostUSD: 1.23, lastUpdatedAt: Date())
        }

        state.setSpendTrackingDisabled(session.id, true)
        #expect(state.sessions[session.id]?.spendTrackingDisabled == true)
        #expect(state.sessions[session.id]?.live?.usage == nil)

        // Re-enabling clears the flag back to `nil`, not `false` — `nil` is the one value a file
        // written before this field existed can ever decode to.
        state.setSpendTrackingDisabled(session.id, false)
        #expect(state.sessions[session.id]?.spendTrackingDisabled == nil)
    }

    @Test func setNotificationsMutedTogglesOneSessionBetweenTrueAndNil() {
        var state = AppState()
        let group = state.addGroup(name: "G", repoRoot: "/repo")
        let session = state.createSession(groupID: group.id, cwd: "/repo")
        let other = state.createSession(groupID: group.id, cwd: "/repo")
        #expect(state.sessions[session.id]?.notificationsMuted == nil)

        state.setNotificationsMuted(session.id, true)
        #expect(state.sessions[session.id]?.notificationsMuted == true)
        #expect(state.sessions[other.id]?.notificationsMuted == nil)
        #expect(state.sessions[session.id]?.live == nil, "no live state fabricated")

        // Unmuting clears the flag back to `nil`, not `false`, like the spend opt-out.
        state.setNotificationsMuted(session.id, false)
        #expect(state.sessions[session.id]?.notificationsMuted == nil)
        state.setNotificationsMuted(SessionID.generate(), true)  // unknown id: no-op
    }

    @Test func togglingTheThemeFlipsBetweenDarkAndLight() {
        var state = AppState()
        #expect(Theme.preset(state.themePreset).isDark)

        state.toggleTheme()
        #expect(Theme.preset(state.themePreset).isDark == false)

        state.toggleTheme()
        #expect(state.themePreset == Theme.default.preset)
    }

    @Test func settingThePresetIsAThemeChangeAndNothingElse() {
        var state = AppState()
        let before = state
        state.setThemePreset(.light)
        let change = ChangeSet.diff(from: before, to: state)
        #expect(change.theme)
        #expect(change.chrome == false)
        #expect(change.structure == false)
        #expect(change.sessions.isEmpty)
    }
}

@Suite struct GroupReducerTests {
    @Test func addRenameColourAndCollapse() {
        var state = AppState()
        let a = state.addGroup(name: "A", repoRoot: "/a")
        let b = state.addGroup(name: "B")
        #expect(state.orderedGroups.map(\.name) == ["A", "B"])
        #expect(b.order == 1)

        state.renameGroup(a.id, name: "  Alpha ")
        #expect(state.groups[a.id]?.name == "Alpha")
        state.renameGroup(a.id, name: "   ")  // empty rename is ignored
        #expect(state.groups[a.id]?.name == "Alpha")

        state.setGroupColor(a.id, color: RGB(hex: 0x123456))
        #expect(state.groups[a.id]?.color == RGB(hex: 0x123456))
        state.toggleGroupCollapsed(a.id)
        #expect(state.groups[a.id]?.isCollapsed == true)
        state.setGroupCollapsed(a.id, false)
        #expect(state.groups[a.id]?.isCollapsed == false)
        state.setGroupDefaultAccount(a.id, accountKey: "claude-work")
        #expect(state.groups[a.id]?.defaultAccountKey == "claude-work")
        #expect(state.group(forRepoRoot: "/a")?.id == a.id)

        // A bucket becomes a repo group and back again.
        state.setGroupRepoRoot(b.id, path: "/b")
        #expect(state.groups[b.id]?.repoRoot == "/b")
        state.setGroupRepoRoot(b.id, path: nil)
        #expect(state.groups[b.id]?.repoRoot == nil)
        state.setGroupRepoRoot(.generate(), path: "/nowhere")  // unknown id is a no-op
        #expect(state.groups.count == 2)
    }

    @Test func moveGroupRenumbers() {
        var state = AppState.fixture
        let last = state.orderedGroups.last!
        state.moveGroup(last.id, to: 0)
        #expect(state.orderedGroups.first?.id == last.id)
        #expect(state.orderedGroups.map(\.order) == Array(0..<state.groups.count))
    }

    @Test func removeGroupCanReassignOrDeleteItsSessions() {
        var state = AppState.fixture
        let source = Fixture.groupID(4)
        let destination = Fixture.groupID(3)
        let moved = state.sessions(in: source).count
        let target = state.sessions(in: destination).count
        state.removeGroup(source, reassignTo: destination)
        #expect(state.groups[source] == nil)
        #expect(state.sessions(in: destination).count == target + moved)
        #expect(state.orderedGroups.map(\.order) == Array(0..<state.groups.count))

        var dropping = AppState.fixture
        let before = dropping.sessions.count
        let victims = dropping.sessions(in: source).count
        dropping.removeGroup(source)
        #expect(dropping.sessions.count == before - victims)
    }
}

@Suite struct AccountReducerTests {

    /// A group default naming an account nothing knows about is still stamped on the session: the
    /// account may only be discovered once the process announces itself, and until then the row has
    /// to remember which one was asked for so a resume lands on it.
    @Test func aGroupDefaultIsHonouredEvenWhenTheAccountIsUnknown() {
        var state = AppState.fixture
        let group = Fixture.groupID(0)
        state.setGroupDefaultAccount(group, accountKey: "claude-gone")
        #expect(state.accounts["claude-gone"] == nil)
        let created = state.createSession(groupID: group, cwd: "~/dev/northwind")
        #expect(created.accountKey == "claude-gone")

        // No default at all falls through to `~/.claude`.
        state.setGroupDefaultAccount(group, accountKey: nil)
        #expect(state.createSession(groupID: group, cwd: "~/dev/northwind").accountKey == Account.defaultKey(for: .claude))
    }

    /// The rule `createSession` adds for TKZ-79: a group default only applies to a row of *its own*
    /// agent. A Codex row in a group whose default names a Claude account must not inherit that
    /// account — it would point `CODEX_HOME` at Claude's config dir — so it falls back to Codex's
    /// own primary instead. The existing Claude-inherits-the-group-default behaviour must still hold
    /// alongside it.
    @Test func aCodexRowDoesNotInheritAClaudeGroupDefault() {
        var state = AppState.fixture
        let group = Fixture.groupID(0)
        #expect(state.accounts["claude-work"]?.agent == .claude)
        state.setGroupDefaultAccount(group, accountKey: "claude-work")

        let codexRow = state.createSession(groupID: group, cwd: "~/dev/northwind", agent: .codex)
        #expect(codexRow.accountKey == Account.defaultKey(for: .codex))

        let claudeRow = state.createSession(groupID: group, cwd: "~/dev/northwind")
        #expect(claudeRow.accountKey == "claude-work")
    }

    /// `setUsage` takes the plan, and the usage file's name only for an account nobody has named:
    /// a generated name must never overwrite the one a human wrote in `dash-accounts.json`.
    @Test func usageNamesOnlyTheAccountsNobodyHasNamed() {
        var state = AppState.fixture

        // `claude-work` carries a configured name, so the usage file's is ignored — but the plan,
        // which nothing else knows, is taken.
        #expect(state.accounts["claude-work"]?.label == "Claude (alt)")
        state.setUsage(UsageSnapshot(accountKey: "claude-work", label: "Generated", plan: "Team 5x"))
        #expect(state.accounts["claude-work"]?.label == "Claude (alt)")
        #expect(state.accounts["claude-work"]?.plan == "Team 5x")

        // An account still standing in for itself takes the better name on offer.
        state.setAccount(Account(key: "claude-spare", configDir: "~/.claude-spare", label: "claude-spare"))
        state.setUsage(UsageSnapshot(accountKey: "claude-spare", label: "Spare"))
        #expect(state.accounts["claude-spare"]?.label == "Spare")
        // …and a snapshot with no name of its own leaves it alone.
        state.setUsage(UsageSnapshot(accountKey: "claude-spare"))
        #expect(state.accounts["claude-spare"]?.label == "Spare")

        // A usage file for a config dir nobody has discovered is not evidence that it exists.
        state.setUsage(UsageSnapshot(accountKey: "claude-ghost", label: "Ghost"))
        #expect(state.accounts["claude-ghost"] == nil)
        #expect(state.usage["claude-ghost"]?.label == "Ghost")
    }
}

@Suite struct SelectionReducerTests {
    @Test func selectingMarksAttendedAndClearsTheBadge() {
        var state = AppState.fixture
        let id = Fixture.sessionID(1)  // NEEDS YOU in the fixture
        #expect(state.sessions[id]?.needsAttention == true)
        state.select(id)
        #expect(state.selection == id)
        #expect(state.sessions[id]?.needsAttention == false)
    }

    @Test func selectingAnUnknownIDClearsRatherThanDangles() {
        var state = AppState.fixture
        state.select(.generate())
        #expect(state.selection == nil)
    }

    @Test func adjacentSelectionWalksTheFlatSidebarOrderAndWraps() {
        var state = AppState.fixture
        let ordered = state.orderedSessions.map(\.id)
        state.select(ordered[0])
        state.selectAdjacentSession(offset: 1)
        #expect(state.selection == ordered[1])
        state.selectAdjacentSession(offset: -1)
        #expect(state.selection == ordered[0])
        state.selectAdjacentSession(offset: -1)
        #expect(state.selection == ordered.last)  // wraps
    }

}

@MainActor
@Suite struct HookTests {
    let now = Fixture.now

    /// A session with `live` already present (idle, alive), so hooks have something to fold into.
    func makeState() -> (AppState, SessionID) {
        var state = AppState()
        let group = state.addGroup(name: "g")
        let session = state.createSession(groupID: group.id, cwd: "/tmp")
        state.setLive(LiveSessionState(status: .idle), for: session.id)
        return (state, session.id)
    }

    @Test func sessionStartClearsEndedAndPendingAndAdoptsTheClaudeID() {
        var (state, id) = makeState()
        state.updateLive(id) { $0.ended = true; $0.pendingNotification = PendingNotification(kind: .permission, receivedAt: now) }
        state.applyEvent(.init(kind: .sessionStart, conversationId: "new-id", source: "startup"), to: id, now: now)
        #expect(state.sessions[id]?.live?.ended == false)
        #expect(state.sessions[id]?.live?.pendingNotification == nil)
        #expect(state.sessions[id]?.conversationId == "new-id")
    }

    @Test func sessionEndNotExitedLeavesTheRowAlive() {
        var (state, id) = makeState()
        state.applyEvent(.init(kind: .sessionEnd(exited: false), reason: "clear"), to: id, now: now)
        #expect(state.sessions[id]?.live?.ended == false)
        #expect(state.sessions[id]?.status == .idle)
    }

    @Test func sessionEndExitedLeavesTheShellAliveButClaudeGone() {
        for reason in ["logout", "prompt_input_exit", "other", nil] {
            var (state, id) = makeState()
            state.applyEvent(.init(kind: .sessionEnd(exited: true), reason: reason), to: id, now: now)
            #expect(state.sessions[id]?.live?.ended == true, "reason \(String(describing: reason))")
            // The terminal is still there (`alive`), so never `exited` — that would dim a live shell.
            #expect(state.sessions[id]?.status == .idle, "reason \(String(describing: reason))")
            #expect(state.sessions[id]?.needsAttention == false)
        }
    }

    @Test func userPromptSubmitMarksAttendedAndClearsPending() {
        var (state, id) = makeState()
        state.updateLive(id) { $0.pendingNotification = PendingNotification(kind: .agentInput, receivedAt: now) }
        state.applyEvent(.init(kind: .promptSubmitted), to: id, now: now)
        #expect(state.sessions[id]?.live?.lastPromptAt == now)
        #expect(state.sessions[id]?.live?.attendedAt == now)
        #expect(state.sessions[id]?.live?.pendingNotification == nil)
    }

    @Test func stopRecordsTheMessageAndKeepsThePreviousOneWhenAbsent() {
        var (state, id) = makeState()
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "done"), to: id, now: now)
        #expect(state.sessions[id]?.live?.lastStopAt == now)
        #expect(state.sessions[id]?.live?.lastStopMessage == "done")

        let later = now.addingTimeInterval(30)
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: nil), to: id, now: later)
        #expect(state.sessions[id]?.live?.lastStopAt == later)
        #expect(state.sessions[id]?.live?.lastStopMessage == "done")  // kept
    }

    @Test func attentionSetsPendingByKind() {
        let cases: [(AttentionKind, WaitReason)] = [
            (.permission, .permission), (.question, .elicitation), (.agentInput, .agentInput),
        ]
        for (kind, reason) in cases {
            var (state, id) = makeState()
            state.applyEvent(.init(kind: .attention(kind)), to: id, now: now)
            #expect(state.sessions[id]?.live?.pendingNotification?.kind == kind)
            #expect(state.sessions[id]?.status == .waiting(reason))
        }
    }

    @Test func attentionClearedClearsPending() {
        var (state, id) = makeState()
        state.updateLive(id) { $0.pendingNotification = PendingNotification(kind: .question, receivedAt: now) }
        state.applyEvent(.init(kind: .attentionCleared), to: id, now: now)
        #expect(state.sessions[id]?.live?.pendingNotification == nil)
    }

    /// The banner's body is Claude's own line, kept only for the three prompts that become
    /// NEEDS YOU, and gone once the prompt is answered or the row attended.
    @Test func notificationKeepsClaudesMessageForBlockedPromptsOnly() {
        var (state, id) = makeState()
        state.applyEvent(
            .init(kind: .attention(.permission), message: "Claude needs your permission to use Bash"),
            to: id, now: now)
        #expect(state.sessions[id]?.live?.lastNotificationMessage == "Claude needs your permission to use Bash")

        // A prompt without a message keeps the previous line rather than blanking it.
        state.applyEvent(.init(kind: .attention(.question), message: ""), to: id, now: now)
        #expect(state.sessions[id]?.live?.lastNotificationMessage == "Claude needs your permission to use Bash")

        state.applyEvent(.init(kind: .attentionCleared), to: id, now: now)
        #expect(state.sessions[id]?.live?.lastNotificationMessage == nil)

        // An idle nudge is not a blocked prompt: its message is not the banner's.
        state.applyEvent(.init(kind: .attention(.idleNudge), message: "Claude is waiting for your input"), to: id, now: now)
        #expect(state.sessions[id]?.live?.lastNotificationMessage == nil)

        state.applyEvent(.init(kind: .attention(.agentInput), message: "Agent needs input"), to: id, now: now)
        #expect(state.sessions[id]?.live?.lastNotificationMessage == "Agent needs input")
        state.markAttended(id, now: now)
        #expect(state.sessions[id]?.live?.lastNotificationMessage == nil)
    }

    @Test func unknownEventIsIgnored() {
        var (state, id) = makeState()
        state.applyEvent(.init(kind: .unknown("mystery")), to: id, now: now)
        #expect(state.sessions[id]?.live?.pendingNotification == nil)
    }

    @Test func busyObservationNewerThanPendingClearsIt() {
        var (state, id) = makeState()
        state.updateLive(id) {
            $0.pendingNotification = PendingNotification(kind: .permission, receivedAt: now)
        }
        let observation = AgentObservation(
            pid: 1, conversationId: "s", configDir: "~/.claude", activity: .busy,
            statusUpdatedAt: now.addingTimeInterval(5))
        state.applyObservation(observation, alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.pendingNotification == nil)
        #expect(state.sessions[id]?.status == .working)
    }

    @Test func busyObservationOlderThanPendingDoesNotClearIt() {
        var (state, id) = makeState()
        state.updateLive(id) {
            $0.pendingNotification = PendingNotification(kind: .permission, receivedAt: now)
        }
        let observation = AgentObservation(
            pid: 1, conversationId: "s", configDir: "~/.claude", activity: .busy,
            statusUpdatedAt: now.addingTimeInterval(-5))
        state.applyObservation(observation, alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.pendingNotification != nil)
        #expect(state.sessions[id]?.status == .waiting(.permission))
    }

    @Test func applyObservationReboundClearsEnded() {
        var (state, id) = makeState()
        state.updateLive(id) {
            $0.ended = true
            $0.observation = AgentObservation(pid: 1, conversationId: "old", configDir: "~/.claude")
        }
        let observation = AgentObservation(pid: 2, conversationId: "new", configDir: "~/.claude")
        state.applyObservation(observation, alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.ended == false)
    }

    @Test func applyObservationSetsAliveAndConversationID() {
        var (state, id) = makeState()
        let observation = AgentObservation(
            pid: 42, conversationId: "abc", configDir: "~/.claude", activity: .busy)
        state.applyObservation(observation, alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.alive == true)
        #expect(state.sessions[id]?.live?.pid == 42)
        #expect(state.sessions[id]?.conversationId == "abc")
        #expect(state.sessions[id]?.status == .working)
    }

    @Test func applyObservationChangesDisplayTitleAndDiffsAsSessionsOnly() throws {
        var state = AppState()
        let group = state.addGroup(name: "g")
        let session = state.createSession(groupID: group.id, cwd: "/repo/app")
        let store = AppStore(state: state)
        var delivered: ChangeSet?
        _ = store.addObserver { delivered = $0 }
        let observation = AgentObservation(
            pid: 1, conversationId: "abc", configDir: "~/.claude", name: "from claude", nameIsDerived: false)
        store.update { $0.applyObservation(observation, alive: true, to: session.id, now: now) }
        store.flush()
        #expect(store.state.sessions[session.id]?.displayTitle == "from claude")
        let change = try #require(delivered)
        #expect(change.sessions == [session.id])
        #expect(change.structure == false)
    }

    @Test func agentLostClearsTheObservationButKeepsAlive() {
        var (state, id) = makeState()
        let observation = AgentObservation(pid: 1, conversationId: "s", configDir: "~/.claude", activity: .busy)
        state.applyObservation(observation, alive: true, to: id, now: now)
        state.agentLost(for: id, now: now)
        #expect(state.sessions[id]?.live?.observation == nil)
        #expect(state.sessions[id]?.live?.pid == nil)
        #expect(state.sessions[id]?.live?.alive == true)
        #expect(state.sessions[id]?.status == .idle)
    }

    @Test func setAliveFalseIsPlainIdle() {
        // No "exited" status: a dead shell's row is removed by the window, so for the instant it
        // still exists it is idle with nothing to attend to.
        var (state, id) = makeState()
        state.setAlive(false, for: id, now: now)
        #expect(state.sessions[id]?.status == .idle)
        #expect(state.sessions[id]?.needsAttention == false)
        state.setAlive(true, for: id, now: now)
        #expect(state.sessions[id]?.status == .idle)
    }

    @Test func rederiveStatusesAgesAnUnattendedStopIntoDoneUnattended() {
        var (state, id) = makeState()
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "done"), to: id, now: now)
        #expect(state.sessions[id]?.status == .idle)  // fresh, <60s
        #expect(state.sessions[id]?.live?.isDone == true)

        state.rederiveStatuses(now: now.addingTimeInterval(61))
        #expect(state.sessions[id]?.status == .waiting(.doneUnattended))
        #expect(state.sessions[id]?.needsAttention == true)
    }

    @Test func rederiveStatusesTouchesOnlyChangedSessions() {
        var state = AppState()
        let group = state.addGroup(name: "g")
        let a = state.createSession(groupID: group.id, cwd: "/tmp/a")
        let b = state.createSession(groupID: group.id, cwd: "/tmp/b")
        state.setLive(LiveSessionState(status: .idle, lastStopAt: now.addingTimeInterval(-70)), for: a.id)
        state.setLive(
            LiveSessionState(
                observation: AgentObservation(pid: 1, conversationId: "s", configDir: "~/.claude", activity: .busy),
                status: .working),
            for: b.id)

        let store = AppStore(state: state)
        store.update { $0.rederiveStatuses(now: now) }
        store.flush()
        #expect(store.state.sessions[a.id]?.status == .waiting(.doneUnattended))
        #expect(store.state.sessions[b.id]?.status == .working)  // unchanged
    }

    @Test func markAttendedClearsDoneUnattended() {
        var (state, id) = makeState()
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "done"), to: id, now: now)
        state.rederiveStatuses(now: now.addingTimeInterval(61))
        #expect(state.sessions[id]?.status == .waiting(.doneUnattended))

        state.markAttended(id, now: now.addingTimeInterval(61))
        #expect(state.sessions[id]?.status == .idle)
        #expect(state.sessions[id]?.needsAttention == false)
        #expect(state.sessions[id]?.live?.isDone == false)
    }

    @Test func aStatusFlipDiffsAsSessionsOnlyNeverStructure() throws {
        let (state, id) = makeState()
        let store = AppStore(state: state)
        var delivered: ChangeSet?
        _ = store.addObserver { delivered = $0 }
        // idle → waiting(.permission), driven by `applyEvent` itself.
        store.update { $0.applyEvent(.init(kind: .attention(.permission)), to: id, now: now) }
        store.flush()
        let change = try #require(delivered)
        #expect(change.sessions == [id])
        #expect(change.structure == false)
        #expect(store.state.sessions[id]?.status == .waiting(.permission))
    }

    @Test func summaryCountsNeedsYouFollowsAttention() {
        let (state, id) = makeState()
        let store = AppStore(state: state)
        store.update { $0.applyEvent(.init(kind: .attention(.permission)), to: id, now: now) }
        store.flush()
        #expect(store.state.summaryCounts.needsYou == 1)
        store.update { $0.markAttended(id, now: now.addingTimeInterval(1)) }
        store.flush()
        // A permission prompt is still pending, so attendance alone does not clear it.
        #expect(store.state.summaryCounts.needsYou == 1)
        store.update { $0.applyEvent(.init(kind: .promptSubmitted), to: id, now: now.addingTimeInterval(2)) }
        store.flush()
        #expect(store.state.summaryCounts.needsYou == 0)
    }
}

/// The "Starting Claude…" fact: set by a boot-command launch, cleared by whichever signal says
/// Claude is up (or gone) first. Only the store side; the 2 s / give-up timing is the AppKit
/// edge's (`StartupOverlayPolicy`).
@Suite struct ClaudeStartupTests {
    let now = Fixture.now

    func makeState() -> (AppState, SessionID, TerminalID) {
        var state = AppState()
        let group = state.addGroup(name: "g")
        let session = state.createSession(groupID: group.id, cwd: "/tmp")
        let terminal = TerminalID(uuid: session.id.uuid)
        state.setLive(LiveSessionState(shellPid: 1, panePids: [terminal: 1]), for: session.id)
        state.beginAgentStartup(session.id, terminal: terminal, command: "claude -w x", now: now)
        return (state, session.id, terminal)
    }

    @Test func beginRecordsThePaneTheCommandAndTheTime() {
        let (state, id, terminal) = makeState()
        #expect(
            state.sessions[id]?.live?.agentStartup
                == AgentStartup(terminal: terminal, command: "claude -w x", startedAt: now))
        // No status of its own: the row is a plain idle shell until Claude says otherwise.
        #expect(state.sessions[id]?.status == .idle)
    }

    @Test func beginNeedsALiveRow() {
        var state = AppState()
        let group = state.addGroup(name: "g")
        let session = state.createSession(groupID: group.id, cwd: "/tmp")
        state.sessions[session.id]?.live = nil
        state.beginAgentStartup(
            session.id, terminal: TerminalID(uuid: session.id.uuid), command: "claude", now: now)
        #expect(state.sessions[session.id]?.live == nil)
    }

    @Test func sessionStartEndsIt() {
        var (state, id, _) = makeState()
        state.applyEvent(.init(kind: .sessionStart, conversationId: "new"), to: id, now: now)
        #expect(state.sessions[id]?.live?.agentStartup == nil)
    }

    @Test func aLiveObservationEndsIt() {
        var (state, id, _) = makeState()
        state.applyObservation(
            AgentObservation(pid: 9, conversationId: "abc", configDir: "/x/.claude", activity: .idle),
            alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.agentStartup == nil)
    }

    /// A stale observation from before a crash, matched to a resumed row by its conversation id,
    /// says nothing about the Claude that is starting now.
    @Test func aDeadObservationDoesNotEndIt() {
        var (state, id, _) = makeState()
        state.applyObservation(
            AgentObservation(pid: 9, conversationId: "abc", configDir: "/x/.claude", activity: .idle),
            alive: false, to: id, now: now)
        #expect(state.sessions[id]?.live?.agentStartup != nil)
    }

    @Test func otherEventsLeaveItAlone() {
        let kinds: [AgentEvent.Kind] = [
            .promptSubmitted, .turnEnded, .attention(.permission), .sessionEnd(exited: true),
        ]
        for kind in kinds {
            var (state, id, _) = makeState()
            state.applyEvent(.init(kind: kind), to: id, now: now)
            #expect(state.sessions[id]?.live?.agentStartup != nil, "\(kind)")
        }
    }

    @Test func closingTheBootPaneEndsItAndClosingAnotherDoesNot() throws {
        var (state, id, terminal) = makeState()
        let split = state.splitPane(terminal, axis: .horizontal)
        let other = try #require(split)
        let closedOther = state.closePane(other)
        #expect(closedOther)
        #expect(state.sessions[id]?.live?.agentStartup?.terminal == terminal)

        let splitAgain = state.splitPane(terminal, axis: .horizontal)
        let another = try #require(splitAgain)
        let closedBoot = state.closePane(terminal)
        #expect(closedBoot)
        #expect(state.sessions[id]?.live?.agentStartup == nil)
        #expect(state.sessions[id]?.terminalIDs == [another])
    }

    @Test func endIsANoOpWhenNothingIsPending() {
        var (state, id, _) = makeState()
        state.endAgentStartup(id)
        let before = state
        state.endAgentStartup(id)
        #expect(state == before)
    }
}

@Suite struct FixtureTests {
    /// The sidebar (M2.3) exercises row-granular reloads against this; it must stay big and varied.
    @Test func isBigEnoughAndCoversEveryState() {
        let state = AppState.fixture
        #expect(state.sessions.count == 40)
        #expect(state.groups.count == 5)
        #expect(state.orderedGroups.map(\.name)
            == ["Northwind Trading", "Acme Ledger", "Scheduled", "Toolbox", "Playground"])

        let statuses = Set(state.sessions.values.map(\.status.name))
        #expect(statuses.contains("working"))
        #expect(statuses.contains("idle"))
        #expect(statuses.contains("waiting(doneUnattended)"))
        #expect(statuses.contains("waiting(permission)"))

        #expect(state.sessions.values.contains { $0.isWorktree })
        #expect(state.sessions.values.contains { $0.needsAttention })
        #expect(Set(state.sessions.values.map(\.accountKey)) == ["claude", "claude-work"])
        #expect(state.sessions.values.contains { $0.displayTitle.count > 50 })  // truncation case
        #expect(state.groups.values.contains { $0.isCollapsed })
        #expect(state.sessions.values.contains { !($0.live?.ports.isEmpty ?? true) })
        #expect(state.sessions.values.contains { $0.live?.context?.contextUsedPercentage != nil })
        #expect(state.sessions.values.contains { $0.live?.git?.pr != nil })
        #expect(state.usage.count == 2)
        #expect(state.accounts.count == 2)
        #expect(state.selection != nil)
    }

    @Test func isDeterministic() {
        #expect(AppState.fixture == AppState.fixture)
        #expect(Fixture.sessionID(0).rawValue == "00000000-0000-4000-8000-000000000000")
    }

    @Test func ordersAreContiguousWithinEveryGroup() {
        let state = AppState.fixture
        for group in state.orderedGroups {
            let orders = state.sessions(in: group.id).map(\.order)
            #expect(orders == Array(0..<orders.count), "group \(group.name)")
        }
        #expect(state.orderedSessions.count == state.sessions.count)
    }

    @Test func summaryCountsMatchTheRows() {
        let state = AppState.fixture
        let summary = state.summaryCounts
        #expect(summary.working == state.sessions.values.filter { $0.status == .working }.count)
        #expect(summary.needsYou == state.sessions.values.filter(\.needsAttention).count)
        #expect(summary.working > 0 && summary.needsYou > 0)
    }

    @Test func canBeScaledForPerfRuns() {
        let big = Fixture.make(sessionCount: 120)
        #expect(big.sessions.count == 120)
        #expect(big.orderedSessions.count == 120)
    }
}

/// Which pane runs the bound `claude`: set from the shim's `launch` frame, gone with the
/// descriptor or the pane. The rule that reads it lives in `GitIntegration` (TkzAppTests).
@Suite struct ClaudeTerminalTests {
    let now = Fixture.now

    func makeState() -> (AppState, SessionID, TerminalID) {
        var state = AppState()
        let group = state.addGroup(name: "g")
        let session = state.createSession(groupID: group.id, cwd: "/tmp")
        let terminal = TerminalID(uuid: session.id.uuid)
        state.setLive(LiveSessionState(shellPid: 1, panePids: [terminal: 1]), for: session.id)
        return (state, session.id, terminal)
    }

    @Test func setRecordsThePaneAndNeedsALiveRow() {
        var (state, id, terminal) = makeState()
        state.setAgentTerminal(id, terminal)
        #expect(state.sessions[id]?.live?.agentTerminal == terminal)

        state.sessions[id]?.live = nil
        state.setAgentTerminal(id, terminal)
        #expect(state.sessions[id]?.live == nil)
    }

    @Test func losingTheObservationClearsIt() {
        var (state, id, terminal) = makeState()
        state.applyObservation(
            AgentObservation(pid: 9, conversationId: "abc", configDir: "/x/.claude", activity: .idle),
            alive: true, to: id, now: now)
        state.setAgentTerminal(id, terminal)
        state.agentLost(for: id, now: now)
        #expect(state.sessions[id]?.live?.agentTerminal == nil)
    }

    @Test func closingTheClaudePaneClearsItAndClosingAnotherDoesNot() throws {
        var (state, id, terminal) = makeState()
        state.setAgentTerminal(id, terminal)
        let split = state.splitPane(terminal, axis: .horizontal)
        let other = try #require(split)
        let closedOther = state.closePane(other)
        #expect(closedOther)
        #expect(state.sessions[id]?.live?.agentTerminal == terminal)

        let splitAgain = state.splitPane(terminal, axis: .horizontal)
        let another = try #require(splitAgain)
        let closedClaude = state.closePane(terminal)
        #expect(closedClaude)
        #expect(state.sessions[id]?.live?.agentTerminal == nil)
        #expect(state.sessions[id]?.terminalIDs == [another])
    }
}
