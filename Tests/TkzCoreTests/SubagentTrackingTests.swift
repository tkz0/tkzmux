// Sub-agents keep a row working after its turn ended (StatusDerivation rule 4a) — the derivation
// row itself, and the bookkeeping `applyEvent` / `expireSubagents` / `touchSubagents` do for it.

import Foundation
import Testing

@testable import TkzCore

@Suite struct SubagentTrackingTests {
    let now = Fixture.now

    static func idleObservation() -> AgentObservation {
        AgentObservation(pid: 1, conversationId: "s", configDir: "~/.claude", activity: .idle)
    }

    static func busyObservation() -> AgentObservation {
        AgentObservation(pid: 1, conversationId: "s", configDir: "~/.claude", activity: .busy)
    }

    /// A live, idle Claude row whose turn ended `stopAge` seconds ago and was never looked at.
    func makeState(stopAge: TimeInterval = 5, observation: AgentObservation? = idleObservation())
        -> (AppState, SessionID)
    {
        var state = AppState()
        let group = state.addGroup(name: "g")
        let session = state.createSession(groupID: group.id, cwd: "/tmp")
        state.setLive(
            LiveSessionState(observation: observation, status: .idle, lastStopAt: now.addingTimeInterval(-stopAge)),
            for: session.id)
        return (state, session.id)
    }

    func started(_ id: String, type: String? = "Explore") -> AgentEvent {
        AgentEvent(kind: .subagentStarted(SubagentInfo(id: id, type: type)))
    }

    func stopped(_ id: String) -> AgentEvent {
        AgentEvent(kind: .subagentStopped(id: id))
    }

    // MARK: - Derivation

    @Test func rule4a_idleObservationWithRunningSubagents_isWorking() {
        let outcome = StatusDerivation.derive(StatusInput(
            observation: Self.idleObservation(), lastStopAt: now.addingTimeInterval(-5),
            runningSubagents: 2, now: now))
        #expect(outcome == StatusOutcome(status: .working, attention: false, isDone: false))
    }

    /// The case that was reported: a turn that ended minutes ago would be NEEDS YOU by rule 5.
    @Test func rule4a_beatsTheUnattendedStop() {
        let outcome = StatusDerivation.derive(StatusInput(
            observation: Self.idleObservation(), lastStopAt: now.addingTimeInterval(-300),
            runningSubagents: 1, now: now))
        #expect(outcome.status == .working)
        #expect(outcome.attention == false)
    }

    /// A sub-agent's permission prompt is still a prompt.
    @Test func rule4a_losesToAPendingPrompt() {
        let outcome = StatusDerivation.derive(StatusInput(
            observation: Self.idleObservation(),
            pending: PendingNotification(kind: .permission, receivedAt: now),
            runningSubagents: 3, now: now))
        #expect(outcome.status == .waiting(.permission))
    }

    @Test func rule4a_losesToEndedAndParked() {
        #expect(StatusDerivation.derive(StatusInput(ended: true, runningSubagents: 1, now: now)).status == .idle)
        let parked = AgentObservation(pid: 1, conversationId: "s", configDir: "~/.claude", parked: true)
        #expect(StatusDerivation.derive(StatusInput(observation: parked, runningSubagents: 1, now: now)).status == .idle)
    }

    @Test func noSubagents_leavesTheOldTableAlone() {
        let outcome = StatusDerivation.derive(StatusInput(
            observation: Self.idleObservation(), lastStopAt: now.addingTimeInterval(-300), now: now))
        #expect(outcome.status == .waiting(.doneUnattended))
    }

    // MARK: - Bookkeeping

    @Test func startKeepsTheRowWorkingAfterItsTurnEnded() {
        var (state, id) = makeState(stopAge: 300)
        state.applyEvent(started("a1"), to: id, now: now)
        #expect(state.sessions[id]?.live?.runningSubagents.keys.sorted() == ["a1"])
        #expect(state.sessions[id]?.status == .working)
        #expect(state.sessions[id]?.live?.attention == false)
    }

    /// The last one finishing counts as a fresh stop, so a turn that ended minutes ago does not
    /// flash NEEDS YOU before the agent's follow-up turn picks the results up.
    @Test func lastStopWhileIdleIsAFreshDone() {
        var (state, id) = makeState(stopAge: 300)
        state.applyEvent(started("a1"), to: id, now: now)
        state.applyEvent(started("a2"), to: id, now: now)
        state.applyEvent(stopped("a1"), to: id, now: now)
        #expect(state.sessions[id]?.status == .working)
        state.applyEvent(stopped("a2"), to: id, now: now)
        #expect(state.sessions[id]?.live?.runningSubagents.isEmpty == true)
        #expect(state.sessions[id]?.live?.lastStopAt == now)
        #expect(state.sessions[id]?.status == .idle)
        #expect(state.sessions[id]?.live?.isDone == true)
        #expect(state.sessions[id]?.live?.attention == false)
    }

    /// A foreground sub-agent inside a running turn: the turn's own `Stop` is still to come.
    @Test func lastStopWhileBusyLeavesTheStopAlone() {
        var (state, id) = makeState(stopAge: 300, observation: Self.busyObservation())
        state.applyEvent(started("a1"), to: id, now: now)
        state.applyEvent(stopped("a1"), to: id, now: now)
        #expect(state.sessions[id]?.live?.lastStopAt == now.addingTimeInterval(-300))
        #expect(state.sessions[id]?.status == .working)
    }

    @Test func stopForAnUnknownIdChangesNothing() {
        var (state, id) = makeState(stopAge: 30)
        state.applyEvent(stopped("never-started"), to: id, now: now)
        #expect(state.sessions[id]?.live?.lastStopAt == now.addingTimeInterval(-30))
    }

    @Test func turnEndedSnapshotReplacesTheSetAndKeepsKnownClocks() {
        var (state, id) = makeState()
        let earlier = now.addingTimeInterval(-60)
        state.applyEvent(started("a1"), to: id, now: earlier)
        state.applyEvent(started("lost"), to: id, now: earlier)
        state.applyEvent(
            AgentEvent(
                kind: .turnEnded,
                runningSubagents: [
                    SubagentInfo(id: "a1", description: "Compare adapters"),
                    SubagentInfo(id: "a3", type: "Plan", description: "Plan it"),
                ]),
            to: id, now: now)
        let running = state.sessions[id]?.live?.runningSubagents
        #expect(running?.keys.sorted() == ["a1", "a3"])
        #expect(running?["a1"]?.startedAt == earlier)
        // The snapshot adds the description; the type the start reported survives.
        #expect(running?["a1"]?.info == SubagentInfo(id: "a1", type: "Explore", description: "Compare adapters"))
        #expect(running?["a3"]?.startedAt == now)
        #expect(state.sessions[id]?.status == .working)
    }

    @Test func turnEndedWithAnEmptySnapshotClearsTheSet() {
        var (state, id) = makeState()
        state.applyEvent(started("a1"), to: id, now: now)
        state.applyEvent(AgentEvent(kind: .turnEnded, runningSubagents: []), to: id, now: now)
        #expect(state.sessions[id]?.live?.runningSubagents.isEmpty == true)
        #expect(state.sessions[id]?.status == .idle)
    }

    /// An agent build that sends no list at all must not wipe what the start/stop pairs built.
    @Test func turnEndedWithoutASnapshotKeepsTheSet() {
        var (state, id) = makeState()
        state.applyEvent(started("a1"), to: id, now: now)
        state.applyEvent(AgentEvent(kind: .turnEnded), to: id, now: now)
        #expect(state.sessions[id]?.live?.runningSubagents.keys.sorted() == ["a1"])
        #expect(state.sessions[id]?.status == .working)
    }

    @Test func sessionEndAndAgentLostClearTheSet_sessionStartDoesNot() {
        var (state, id) = makeState()
        state.applyEvent(started("a1"), to: id, now: now)
        state.applyEvent(AgentEvent(kind: .sessionStart), to: id, now: now)
        #expect(state.sessions[id]?.live?.runningSubagents.count == 1, "a compaction restarts, agents keep running")
        state.applyEvent(AgentEvent(kind: .sessionEnd(exited: false), reason: "clear"), to: id, now: now)
        #expect(state.sessions[id]?.live?.runningSubagents.isEmpty == true)

        state.applyEvent(started("a2"), to: id, now: now)
        state.agentLost(for: id, now: now)
        #expect(state.sessions[id]?.live?.runningSubagents.isEmpty == true)
    }

    // MARK: - Stale sweep

    @Test func expireDropsOnlySilentSubagents() {
        var (state, id) = makeState()
        state.applyEvent(started("old"), to: id, now: now.addingTimeInterval(-700))
        state.applyEvent(started("fresh"), to: id, now: now.addingTimeInterval(-10))
        state.expireSubagents(maxSilence: 600, now: now)
        #expect(state.sessions[id]?.live?.runningSubagents.keys.sorted() == ["fresh"])
        #expect(state.sessions[id]?.status == .working)

        state.expireSubagents(maxSilence: 600, now: now.addingTimeInterval(600))
        #expect(state.sessions[id]?.live?.runningSubagents.isEmpty == true)
        #expect(state.sessions[id]?.status != .working)
    }

    @Test func touchKeepsAWritingSubagentAliveAndNeverMovesAClockBack() {
        var (state, id) = makeState()
        let start = now.addingTimeInterval(-700)
        state.applyEvent(started("a1"), to: id, now: start)
        state.touchSubagents(id, activity: ["a1": now.addingTimeInterval(-5), "gone": now])
        #expect(state.sessions[id]?.live?.runningSubagents["a1"]?.lastActivityAt == now.addingTimeInterval(-5))
        state.touchSubagents(id, activity: ["a1": start])
        #expect(state.sessions[id]?.live?.runningSubagents["a1"]?.lastActivityAt == now.addingTimeInterval(-5))

        state.expireSubagents(maxSilence: 600, now: now)
        #expect(state.sessions[id]?.live?.runningSubagents.keys.sorted() == ["a1"])
    }
}
