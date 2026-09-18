// ActivityTests — the activity feed's event log: what the reducers append, when an entry is read,
// and that the log stays bounded. Pure `AppState`, no store unless the change-set bucket is the
// point.

import Foundation
import Testing

@testable import TkzCore

@Suite struct ActivityLogTests {
    let now = Fixture.now

    func makeState() -> (AppState, SessionID) {
        var state = AppState()
        let group = state.addGroup(name: "Northwind")
        let session = state.createSession(groupID: group.id, cwd: "/tmp/northwind", title: "review")
        state.setLive(LiveSessionState(status: .idle), for: session.id)
        return (state, session.id)
    }

    // MARK: Appending

    @Test func aStopAppendsAnUnreadEntryNamingTheRowAndItsGroup() throws {
        var (state, id) = makeState()
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "Done.\n\nTests are green."), to: id, now: now)
        let entry = try #require(state.activity.last)
        #expect(state.activity.count == 1)
        #expect(entry.sessionID == id)
        #expect(entry.kind == .stop(message: "Done.\n\nTests are green."))
        #expect(entry.at == now)
        #expect(entry.sessionTitle == "review")
        #expect(entry.groupName == "Northwind")
        #expect(entry.unread)
        #expect(entry.preview == "Done.\nTests are green.")
    }

    @Test func aStopMessageIsCappedForStorage() throws {
        var (state, id) = makeState()
        let long = String(repeating: "x", count: ActivityEvent.messageCap + 50)
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: long), to: id, now: now)
        #expect(state.activity.last?.kind.message?.count == ActivityEvent.messageCap)
    }

    @Test func aPermissionPromptAppendsNeedsYouBeforeAnyStop() throws {
        var (state, id) = makeState()
        state.applyEvent(
            .init(kind: .attention(.permission), message: "Claude needs your permission to use Bash"),
            to: id, now: now)
        let entry = try #require(state.activity.last)
        #expect(entry.kind == .needsYou(reason: .permission, message: "Claude needs your permission to use Bash"))
        #expect(entry.unread)
        // The turn then finishes: the Stop lands after it, newest last.
        state.applyEvent(.init(kind: .promptSubmitted), to: id, now: now.addingTimeInterval(5))
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "ok"), to: id, now: now.addingTimeInterval(9))
        #expect(state.activity.map(\.kind) == [
            .needsYou(reason: .permission, message: "Claude needs your permission to use Bash"),
            .stop(message: "ok"),
        ])
    }

    @Test func aQuestionAndAgentInputAreLabelledQuestion() {
        #expect(WaitReason.elicitation.feedLabel == "question")
        #expect(WaitReason.agentInput.feedLabel == "question")
        #expect(WaitReason.permission.feedLabel == "permission")
        #expect(WaitReason.doneUnattended.feedLabel == "unattended")
    }

    @Test func aDescriptorOnlyWaitingAppendsNeedsYouWithoutAnyEvent() {
        var (state, id) = makeState()
        let descriptor = ClaudeSessionInfo(configDir: "~/.claude", pid: 7, sessionId: "s", status: .waiting)
        state.applyDescriptor(descriptor, alive: true, to: id, now: now)
        #expect(state.activity.map(\.kind) == [.needsYou(reason: .permission, message: nil)])
        // The tick sees the same state again: nothing new.
        state.rederiveStatuses(now: now.addingTimeInterval(5))
        state.rederiveStatuses(now: now.addingTimeInterval(10))
        #expect(state.activity.count == 1)
    }

    @Test func anUnattendedStopAgesIntoASecondEntryExactlyOnce() {
        var (state, id) = makeState()
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "Finished the refactor."), to: id, now: now)
        #expect(state.activity.count == 1)
        for seconds in stride(from: 5.0, through: 120, by: 5) {
            state.rederiveStatuses(now: now.addingTimeInterval(seconds))
        }
        #expect(state.activity.map(\.kind) == [
            .stop(message: "Finished the refactor."),
            .needsYou(reason: .doneUnattended, message: "Finished the refactor."),
        ])
        #expect(state.activity.last?.at == now.addingTimeInterval(60))
    }

    @Test func reselectingARowWithAPendingPromptAppendsNothing() {
        var (state, id) = makeState()
        state.applyEvent(.init(kind: .attention(.permission)), to: id, now: now)
        #expect(state.activity.count == 1)
        state.select(id, now: now.addingTimeInterval(1))
        state.select(id, now: now.addingTimeInterval(2))
        state.markAttended(id, now: now.addingTimeInterval(3))
        #expect(state.activity.count == 1)
        // The badge is still up — the prompt has not been answered.
        #expect(state.sessions[id]?.needsAttention == true)
    }

    @Test func theReasonChangingWhileAttentionIsUpAppendsAgain() {
        var (state, id) = makeState()
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "done"), to: id, now: now)
        state.rederiveStatuses(now: now.addingTimeInterval(61))
        #expect(state.sessions[id]?.status == .waiting(.doneUnattended))
        state.applyEvent(.init(kind: .attention(.permission)), to: id, now: now.addingTimeInterval(70))
        #expect(state.activity.map(\.kind).last == .needsYou(reason: .permission, message: nil))
        #expect(state.activity.count == 3)
    }

    @Test func sessionEndAppendsOnceAndOnlyForARealExit() {
        var (state, id) = makeState()
        for reason in ["clear", "resume"] {
            state.applyEvent(.init(kind: .sessionEnd(exited: false), reason: reason), to: id, now: now)
        }
        #expect(state.activity.isEmpty)
        state.applyEvent(.init(kind: .sessionEnd(exited: true), reason: "prompt_input_exit"), to: id, now: now)
        state.applyEvent(
            .init(kind: .sessionEnd(exited: true), reason: "prompt_input_exit"), to: id,
            now: now.addingTimeInterval(1))
        #expect(state.activity.map(\.kind) == [.sessionEnded(reason: "prompt_input_exit")])
        // Context, not a call: born read.
        #expect(state.activity.last?.unread == false)
        #expect(state.activity.last?.kind.isActionable == false)
    }

    @Test func theLogIsCappedOldestFirst() {
        var (state, id) = makeState()
        for n in 0..<(AppState.activityCap + 25) {
            state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "turn \(n)"), to: id, now: now.addingTimeInterval(Double(n)))
        }
        #expect(state.activity.count == AppState.activityCap)
        #expect(state.activity.first?.kind == .stop(message: "turn 25"))
        #expect(state.activity.last?.kind == .stop(message: "turn \(AppState.activityCap + 24)"))
    }

    @Test func removingTheRowPrunesItsEntries() {
        var (state, id) = makeState()
        let other = state.createSession(groupID: state.orderedGroups[0].id, cwd: "/tmp/other")
        state.setLive(LiveSessionState(status: .idle), for: other.id)
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "a"), to: id, now: now)
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "b"), to: other.id, now: now)
        state.removeSession(id)
        #expect(state.activity.map(\.sessionID) == [other.id])
    }

    @Test func aRowWithNoLiveStateAppendsNothingOnRelaunch() {
        // Restored rows have `live == nil`; the tick must not invent entries for them.
        var state = AppState.fixture
        let before = state.activity
        state.rederiveStatuses(now: now.addingTimeInterval(3600))
        #expect(state.activity == before)
    }

    // MARK: Read / unread

    @Test func selectingTheRowReadsItsThreadAndOnlyItsThread() {
        var (state, id) = makeState()
        let other = state.createSession(groupID: state.orderedGroups[0].id, cwd: "/tmp/other")
        state.setLive(LiveSessionState(status: .idle), for: other.id)
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "a"), to: id, now: now)
        state.applyEvent(.init(kind: .attention(.permission)), to: other.id, now: now)
        state.select(id, now: now.addingTimeInterval(1))
        #expect(state.activity.map(\.unread) == [false, true])
    }

    @Test func typingAPromptReadsTheThread() {
        var (state, id) = makeState()
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "a"), to: id, now: now)
        state.applyEvent(.init(kind: .promptSubmitted), to: id, now: now.addingTimeInterval(1))
        #expect(state.activity.map(\.unread) == [false])
    }

    @Test func markUnreadRaisesTheWholeThreadButNeverAnExit() {
        var (state, id) = makeState()
        state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "a"), to: id, now: now)
        state.applyEvent(.init(kind: .attention(.permission)), to: id, now: now.addingTimeInterval(1))
        state.applyEvent(.init(kind: .sessionEnd(exited: true), reason: "exit"), to: id, now: now.addingTimeInterval(2))
        state.select(id, now: now.addingTimeInterval(3))
        #expect(state.activity.map(\.unread) == [false, false, false])
        state.markActivityUnread(id)
        #expect(state.activity.map(\.unread) == [true, true, false])
        // Unknown row: nothing happens.
        state.markActivityUnread(.generate())
        #expect(state.activity.map(\.unread) == [true, true, false])
    }

    // MARK: Change set

    @Test func activityDiffsIntoItsOwnBucket() {
        var (old, id) = makeState()
        old.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "a"), to: id, now: now)
        var new = old
        new.markActivityUnread(id)  // already unread: nothing
        #expect(ChangeSet.diff(from: old, to: new).isEmpty)
        new.markActivityRead(id)
        let change = ChangeSet.diff(from: old, to: new)
        #expect(change.activity)
        #expect(change.sessions.isEmpty)
        #expect(change.chrome == false)
        #expect(change.isEmpty == false)

        var union = ChangeSet.none
        union.formUnion(ChangeSet(activity: true))
        #expect(union.activity)
    }

    @Test func firstLinesSkipsBlanksAndTrims() {
        #expect(ActivityEvent.firstLines(of: "\n  one  \n\n two\nthree", count: 2) == ["one", "two"])
        #expect(ActivityEvent.firstLines(of: "   ", count: 2).isEmpty)
    }
}
