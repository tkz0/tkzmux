// The reducers, exercised without a store — they are plain `mutating` methods on `AppState`.
// Flows: docs/design.md → *Session flows & persistence*.

import Foundation
import Testing

@testable import TkzCore

@Suite struct SessionReducerTests {
    let group = Fixture.groupID(0)

    @Test func createAppendsAndInheritsTheGroupDefaults() {
        var state = AppState.fixture
        let before = state.sessions(in: group).count
        let created = state.createSession(groupID: group, cwd: "~/dev/frontinvest")
        #expect(state.sessions(in: group).count == before + 1)
        #expect(state.sessions(in: group).last?.id == created.id)
        #expect(created.order == before)
        #expect(created.accountKey == state.groups[group]?.defaultAccountKey)
        #expect(created.repoRoot == state.groups[group]?.repoRoot)
        #expect(created.status == .exited)  // nothing is running yet
    }

    @Test func createFallsBackToTheDefaultAccount() {
        var state = AppState()
        let g = state.addGroup(name: "Bucket")
        let session = state.createSession(groupID: g.id, cwd: "/tmp")
        #expect(session.accountKey == Account.defaultKey)
    }

    @Test func adoptBindsTheDescriptorAndRecordsTheResumeID() {
        var state = AppState.fixture
        let id = Fixture.sessionID(4)  // an exited fixture row
        #expect(state.sessions[id]?.live == nil)
        let descriptor = ClaudeSessionInfo(
            configDir: "~/.claude-alt", pid: 900, sessionId: "new-session-id",
            kind: .interactive, name: "adopted", nameSource: .auto, status: .busy)
        state.adoptDescriptor(descriptor, for: id)
        #expect(state.sessions[id]?.live?.pid == 900)
        #expect(state.sessions[id]?.claudeSessionId == "new-session-id")
        #expect(state.sessions[id]?.live?.descriptor?.name == "adopted")
        // Adopting an unknown session is a no-op, not a crash.
        let count = state.sessions.count
        state.adoptDescriptor(descriptor, for: .generate())
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
            descriptor: ClaudeSessionInfo(configDir: "~/.claude", pid: 1, sessionId: "s",
                                          name: "from claude", nameSource: .auto))
        #expect(session.displayTitle == "from claude")  // descriptor name
        session.live?.descriptor?.nameSource = .derived
        #expect(session.displayTitle == "pricing")  // a derived name loses to the worktree
        session.title = "user rename"
        #expect(session.displayTitle == "user rename")  // the rename always wins

        // Claude's own cwd beats the shell's starting directory once a descriptor is bound.
        var moved = Session(groupID: GroupID.generate(), cwd: "/Users/x", accountKey: "claude")
        moved.live = LiveSessionState(descriptor: ClaudeSessionInfo(
            configDir: "/Users/x/.claude", pid: 1, sessionId: "s", cwd: "/Users/x/dev/app",
            name: "app-3f", nameSource: .derived))
        #expect(moved.displayTitle == "app")
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

    /// Close keeps the row (resumable); remove deletes it.
    @Test func closeKeepsTheRowAndRemoveDeletesIt() {
        var state = AppState.fixture
        let id = Fixture.sessionID(0)
        let claudeID = state.sessions[id]?.claudeSessionId
        state.closeSession(id)
        #expect(state.sessions[id] != nil)
        #expect(state.sessions[id]?.status == .exited)
        #expect(state.sessions[id]?.claudeSessionId == claudeID)  // still resumable

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
        var session = Session(groupID: .generate(), cwd: "/repo/wt", repoRoot: "/repo",
                              worktreePath: "/repo/.claude/worktrees/wt", isWorktree: true,
                              accountKey: "claude")
        #expect(session.resumeDirectory == "/repo/.claude/worktrees/wt")
        session.isWorktree = false  // worktree gone → repo root, badge cleared
        #expect(session.resumeDirectory == "/repo")
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
        state.setGroupDefaultAccount(a.id, accountKey: "claude-alt")
        #expect(state.groups[a.id]?.defaultAccountKey == "claude-alt")
        #expect(state.group(forRepoRoot: "/a")?.id == a.id)
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

    @Test func presetsAreAddedUpdatedAndRemoved() {
        var state = AppState()
        var preset = Preset(name: "wt", command: "claude -w")
        state.addPreset(preset)
        preset.name = "worktree"
        state.addPreset(preset)
        #expect(state.presets.count == 1)
        #expect(state.preset(preset.id)?.name == "worktree")
        state.removePreset(preset.id)
        #expect(state.presets.isEmpty)
    }

    @Test func cwdModeResolvesTheLaunchDirectory() {
        // `claude -w` must run from the main checkout, so worktree mode still launches at the root.
        #expect(CwdMode.worktree(name: "x").directory(repoRoot: "/repo", fallback: "/tmp") == "/repo")
        #expect(CwdMode.repoRoot.directory(repoRoot: nil, fallback: "/tmp") == "/tmp")
        #expect(CwdMode.fixed(path: "/srv").directory(repoRoot: "/repo", fallback: "/tmp") == "/srv")
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
        state.updateLive(id) { $0.ended = true; $0.pendingNotification = PendingNotification(type: .permissionPrompt, receivedAt: now) }
        state.applyHook(.init(kind: .sessionStart, claudeSessionId: "new-id", source: "startup"), to: id, now: now)
        #expect(state.sessions[id]?.live?.ended == false)
        #expect(state.sessions[id]?.live?.pendingNotification == nil)
        #expect(state.sessions[id]?.claudeSessionId == "new-id")
    }

    @Test func sessionEndTreatsClearAndResumeAsNotExited() {
        for reason in ["clear", "resume"] {
            var (state, id) = makeState()
            state.applyHook(.init(kind: .sessionEnd, reason: reason), to: id, now: now)
            #expect(state.sessions[id]?.live?.ended == false, "reason \(reason)")
            #expect(state.sessions[id]?.status != .exited, "reason \(reason)")
        }
    }

    @Test func sessionEndTreatsOtherReasonsAsClaudeGone_theShellStaysIdle() {
        for reason in ["logout", "prompt_input_exit", "other", nil] {
            var (state, id) = makeState()
            state.applyHook(.init(kind: .sessionEnd, reason: reason), to: id, now: now)
            #expect(state.sessions[id]?.live?.ended == true, "reason \(String(describing: reason))")
            // The terminal is still there (`alive`), so never `exited` — that would dim a live shell.
            #expect(state.sessions[id]?.status == .idle, "reason \(String(describing: reason))")
            #expect(state.sessions[id]?.needsAttention == false)
        }
    }

    @Test func userPromptSubmitMarksAttendedAndClearsPending() {
        var (state, id) = makeState()
        state.updateLive(id) { $0.pendingNotification = PendingNotification(type: .agentNeedsInput, receivedAt: now) }
        state.applyHook(.init(kind: .userPromptSubmit), to: id, now: now)
        #expect(state.sessions[id]?.live?.lastPromptAt == now)
        #expect(state.sessions[id]?.live?.attendedAt == now)
        #expect(state.sessions[id]?.live?.pendingNotification == nil)
    }

    @Test func stopRecordsTheMessageAndKeepsThePreviousOneWhenAbsent() {
        var (state, id) = makeState()
        state.applyHook(.init(kind: .stop, lastAssistantMessage: "done"), to: id, now: now)
        #expect(state.sessions[id]?.live?.lastStopAt == now)
        #expect(state.sessions[id]?.live?.lastStopMessage == "done")

        let later = now.addingTimeInterval(30)
        state.applyHook(.init(kind: .stop, lastAssistantMessage: nil), to: id, now: later)
        #expect(state.sessions[id]?.live?.lastStopAt == later)
        #expect(state.sessions[id]?.live?.lastStopMessage == "done")  // kept
    }

    @Test func notificationSetsPendingByType() {
        let cases: [(HookEvent.NotificationType, WaitReason)] = [
            (.permissionPrompt, .permission), (.elicitationDialog, .elicitation), (.agentNeedsInput, .agentInput),
        ]
        for (type, reason) in cases {
            var (state, id) = makeState()
            state.applyHook(.init(kind: .notification, notificationType: type), to: id, now: now)
            #expect(state.sessions[id]?.live?.pendingNotification?.type == type)
            #expect(state.sessions[id]?.status == .waiting(reason))
        }
    }

    @Test func elicitationCompleteClearsPending() {
        var (state, id) = makeState()
        state.updateLive(id) { $0.pendingNotification = PendingNotification(type: .elicitationDialog, receivedAt: now) }
        state.applyHook(.init(kind: .notification, notificationType: .elicitationComplete), to: id, now: now)
        #expect(state.sessions[id]?.live?.pendingNotification == nil)
    }

    @Test func unknownNotificationIsIgnored() {
        var (state, id) = makeState()
        state.applyHook(.init(kind: .notification, notificationType: .unknown("mystery")), to: id, now: now)
        #expect(state.sessions[id]?.live?.pendingNotification == nil)
    }

    @Test func busyDescriptorNewerThanPendingClearsIt() {
        var (state, id) = makeState()
        state.updateLive(id) {
            $0.pendingNotification = PendingNotification(type: .permissionPrompt, receivedAt: now)
        }
        let descriptor = ClaudeSessionInfo(
            configDir: "~/.claude", pid: 1, sessionId: "s", status: .busy,
            statusUpdatedAt: now.addingTimeInterval(5))
        state.applyDescriptor(descriptor, alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.pendingNotification == nil)
        #expect(state.sessions[id]?.status == .working)
    }

    @Test func busyDescriptorOlderThanPendingDoesNotClearIt() {
        var (state, id) = makeState()
        state.updateLive(id) {
            $0.pendingNotification = PendingNotification(type: .permissionPrompt, receivedAt: now)
        }
        let descriptor = ClaudeSessionInfo(
            configDir: "~/.claude", pid: 1, sessionId: "s", status: .busy,
            statusUpdatedAt: now.addingTimeInterval(-5))
        state.applyDescriptor(descriptor, alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.pendingNotification != nil)
        #expect(state.sessions[id]?.status == .waiting(.permission))
    }

    @Test func applyDescriptorReboundClearsEnded() {
        var (state, id) = makeState()
        state.updateLive(id) {
            $0.ended = true
            $0.descriptor = ClaudeSessionInfo(configDir: "~/.claude", pid: 1, sessionId: "old")
        }
        let descriptor = ClaudeSessionInfo(configDir: "~/.claude", pid: 2, sessionId: "new")
        state.applyDescriptor(descriptor, alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.ended == false)
    }

    @Test func applyDescriptorSetsAliveAndClaudeSessionID() {
        var (state, id) = makeState()
        let descriptor = ClaudeSessionInfo(configDir: "~/.claude", pid: 42, sessionId: "abc", status: .busy)
        state.applyDescriptor(descriptor, alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.alive == true)
        #expect(state.sessions[id]?.live?.pid == 42)
        #expect(state.sessions[id]?.claudeSessionId == "abc")
        #expect(state.sessions[id]?.status == .working)
    }

    @Test func applyDescriptorChangesDisplayTitleAndDiffsAsSessionsOnly() throws {
        var state = AppState()
        let group = state.addGroup(name: "g")
        let session = state.createSession(groupID: group.id, cwd: "/repo/app")
        let store = AppStore(state: state)
        var delivered: ChangeSet?
        _ = store.addObserver { delivered = $0 }
        let descriptor = ClaudeSessionInfo(
            configDir: "~/.claude", pid: 1, sessionId: "abc", name: "from claude", nameSource: .auto)
        store.update { $0.applyDescriptor(descriptor, alive: true, to: session.id, now: now) }
        store.flush()
        #expect(store.state.sessions[session.id]?.displayTitle == "from claude")
        let change = try #require(delivered)
        #expect(change.sessions == [session.id])
        #expect(change.structure == false)
    }

    @Test func descriptorLostClearsTheDescriptorButKeepsAlive() {
        var (state, id) = makeState()
        let descriptor = ClaudeSessionInfo(configDir: "~/.claude", pid: 1, sessionId: "s", status: .busy)
        state.applyDescriptor(descriptor, alive: true, to: id, now: now)
        state.descriptorLost(for: id, now: now)
        #expect(state.sessions[id]?.live?.descriptor == nil)
        #expect(state.sessions[id]?.live?.pid == nil)
        #expect(state.sessions[id]?.live?.alive == true)
        #expect(state.sessions[id]?.status == .idle)
    }

    @Test func setAliveFalseDerivesExited() {
        var (state, id) = makeState()
        state.setAlive(false, for: id, now: now)
        #expect(state.sessions[id]?.status == .exited)
        state.setAlive(true, for: id, now: now)
        #expect(state.sessions[id]?.status == .idle)
    }

    @Test func rederiveStatusesAgesAnUnattendedStopIntoDoneUnattended() {
        var (state, id) = makeState()
        state.applyHook(.init(kind: .stop, lastAssistantMessage: "done"), to: id, now: now)
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
                descriptor: ClaudeSessionInfo(configDir: "~/.claude", pid: 1, sessionId: "s", status: .busy),
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
        state.applyHook(.init(kind: .stop, lastAssistantMessage: "done"), to: id, now: now)
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
        // idle → waiting(.permission), driven by `applyHook` itself.
        store.update { $0.applyHook(.init(kind: .notification, notificationType: .permissionPrompt), to: id, now: now) }
        store.flush()
        let change = try #require(delivered)
        #expect(change.sessions == [id])
        #expect(change.structure == false)
        #expect(store.state.sessions[id]?.status == .waiting(.permission))
    }

    @Test func summaryCountsNeedsYouFollowsAttention() {
        let (state, id) = makeState()
        let store = AppStore(state: state)
        store.update { $0.applyHook(.init(kind: .notification, notificationType: .permissionPrompt), to: id, now: now) }
        store.flush()
        #expect(store.state.summaryCounts.needsYou == 1)
        store.update { $0.markAttended(id, now: now.addingTimeInterval(1)) }
        store.flush()
        // A permission prompt is still pending, so attendance alone does not clear it.
        #expect(store.state.summaryCounts.needsYou == 1)
        store.update { $0.applyHook(.init(kind: .userPromptSubmit), to: id, now: now.addingTimeInterval(2)) }
        store.flush()
        #expect(store.state.summaryCounts.needsYou == 0)
    }
}

@Suite struct FixtureTests {
    /// TKZ-19 exercises row-granular reloads against this; it must stay big and varied.
    @Test func isBigEnoughAndCoversEveryState() {
        let state = AppState.fixture
        #expect(state.sessions.count == 40)
        #expect(state.groups.count == 5)
        #expect(state.orderedGroups.map(\.name)
            == ["Almi FrontInvest", "Core Invest", "Scheduled", "Aira", "Workamo"])

        let statuses = Set(state.sessions.values.map(\.status.name))
        #expect(statuses.contains("working"))
        #expect(statuses.contains("idle"))
        #expect(statuses.contains("exited"))
        #expect(statuses.contains("waiting(doneUnattended)"))
        #expect(statuses.contains("waiting(permission)"))

        #expect(state.sessions.values.contains { $0.isWorktree })
        #expect(state.sessions.values.contains { $0.needsAttention })
        #expect(Set(state.sessions.values.map(\.accountKey)) == ["claude", "claude-alt"])
        #expect(state.sessions.values.contains { $0.displayTitle.count > 50 })  // truncation case
        #expect(state.groups.values.contains { $0.isCollapsed })
        #expect(state.sessions.values.contains { !($0.live?.ports.isEmpty ?? true) })
        #expect(state.sessions.values.contains { $0.live?.context?.contextUsedPercentage != nil })
        #expect(state.sessions.values.contains { $0.live?.git?.pr != nil })
        #expect(state.usage.count == 2)
        #expect(state.accounts.count == 2)
        #expect(state.presets.count == 3)
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
