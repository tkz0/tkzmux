// A background shell keeps a row working after its turn ended (StatusDerivation rule 4a, second
// half) — the derivation row, and what `applyObservation` / `applyEvent` do around it. Reported
// 2026-09-24: Claude backgrounded a CI watcher, said "I'll report back as soon as it completes",
// and the row read as done while the descriptor said `"shell"`.

import Foundation
import Testing

@testable import TkzCore

@Suite struct BackgroundShellTests {
    let now = Fixture.now

    static func observation(_ activity: AgentObservation.Activity?, pid: pid_t = 1) -> AgentObservation {
        AgentObservation(pid: pid, conversationId: "s", configDir: "~/.claude", activity: activity)
    }

    /// A live Claude row whose turn ended `stopAge` seconds ago and was never looked at.
    func makeState(stopAge: TimeInterval = 300, activity: AgentObservation.Activity? = .backgroundShell)
        -> (AppState, SessionID)
    {
        var state = AppState()
        let group = state.addGroup(name: "g")
        let session = state.createSession(groupID: group.id, cwd: "/tmp")
        state.setLive(
            LiveSessionState(observation: Self.observation(activity), status: .idle, lastStopAt: now.addingTimeInterval(-stopAge)),
            for: session.id)
        state.rederiveStatus(for: session.id, now: now)
        return (state, session.id)
    }

    // MARK: - Derivation

    /// The reported case: a Stop minutes old would be NEEDS YOU by rule 5.
    @Test func backgroundShellBeatsTheUnattendedStop() {
        let outcome = StatusDerivation.derive(StatusInput(
            observation: Self.observation(.backgroundShell), lastStopAt: now.addingTimeInterval(-300), now: now))
        #expect(outcome == StatusOutcome(status: .working, attention: false, isDone: false))
    }

    @Test func backgroundShellLosesToAPendingPromptEndedAndParked() {
        let prompt = StatusDerivation.derive(StatusInput(
            observation: Self.observation(.backgroundShell),
            pending: PendingNotification(kind: .permission, receivedAt: now), now: now))
        #expect(prompt.status == .waiting(.permission))
        #expect(StatusDerivation.derive(StatusInput(
            observation: Self.observation(.backgroundShell), ended: true, now: now)).status == .idle)
        var parked = Self.observation(.backgroundShell)
        parked.parked = true
        #expect(StatusDerivation.derive(StatusInput(observation: parked, now: now)).status == .idle)
    }

    // MARK: - Bookkeeping

    @Test func theShellExitingIsAFreshStop() {
        var (state, id) = makeState()
        #expect(state.sessions[id]?.status == .working)
        state.applyObservation(Self.observation(.idle), alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.lastStopAt == now)
        #expect(state.sessions[id]?.status == .idle)
        #expect(state.sessions[id]?.live?.isDone == true)
        #expect(state.sessions[id]?.live?.attention == false)
    }

    /// Straight into the follow-up turn: that turn's own `Stop` is still to come.
    @Test func theShellHandingOverToABusyTurnLeavesTheStopAlone() {
        var (state, id) = makeState()
        state.applyObservation(Self.observation(.busy), alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.lastStopAt == now.addingTimeInterval(-300))
        #expect(state.sessions[id]?.status == .working)
    }

    /// An idle observation that was never `shell` is no stop at all.
    @Test func idleAfterIdleLeavesTheStopAlone() {
        var (state, id) = makeState(activity: .idle)
        state.applyObservation(Self.observation(.idle), alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.lastStopAt == now.addingTimeInterval(-300))
    }

    /// A different agent process bound to the row says nothing about the old one's shells.
    @Test func aReboundObservationIsNoStop() {
        var (state, id) = makeState()
        state.applyObservation(Self.observation(.idle, pid: 2), alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.lastStopAt == now.addingTimeInterval(-300))
    }

    @Test func stopListIsKeptUntilTheObservationGoesIdle() {
        var (state, id) = makeState(activity: .busy)
        let watcher = BackgroundShellInfo(id: "b1", description: "Watch build 8182", command: "until …; do sleep 60; done")
        state.applyEvent(AgentEvent(kind: .turnEnded, backgroundShells: [watcher]), to: id, now: now)
        #expect(state.sessions[id]?.live?.backgroundShells == [watcher])
        // A Stop can land while the descriptor still says busy; the list must survive that.
        state.applyObservation(Self.observation(.busy), alive: true, to: id, now: now)
        state.applyObservation(Self.observation(.backgroundShell), alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.backgroundShells == [watcher])
        #expect(state.sessions[id]?.status == .working)

        state.applyObservation(Self.observation(.idle), alive: true, to: id, now: now)
        #expect(state.sessions[id]?.live?.backgroundShells.isEmpty == true)
    }

    @Test func aStopWithoutAListKeepsTheOldOne() {
        var (state, id) = makeState()
        let shell = BackgroundShellInfo(id: "b1", command: "npm run dev")
        state.applyEvent(AgentEvent(kind: .turnEnded, backgroundShells: [shell]), to: id, now: now)
        state.applyEvent(AgentEvent(kind: .turnEnded), to: id, now: now)
        #expect(state.sessions[id]?.live?.backgroundShells == [shell])
        state.applyEvent(AgentEvent(kind: .turnEnded, backgroundShells: []), to: id, now: now)
        #expect(state.sessions[id]?.live?.backgroundShells.isEmpty == true)
    }

    @Test func sessionEndAndAgentLostClearTheList() {
        var (state, id) = makeState()
        let shell = BackgroundShellInfo(id: "b1", command: "npm run dev")
        state.applyEvent(AgentEvent(kind: .turnEnded, backgroundShells: [shell]), to: id, now: now)
        state.applyEvent(AgentEvent(kind: .sessionEnd(exited: false), reason: "clear"), to: id, now: now)
        #expect(state.sessions[id]?.live?.backgroundShells.isEmpty == true)

        state.applyEvent(AgentEvent(kind: .turnEnded, backgroundShells: [shell]), to: id, now: now)
        state.agentLost(for: id, now: now)
        #expect(state.sessions[id]?.live?.backgroundShells.isEmpty == true)
    }
}
