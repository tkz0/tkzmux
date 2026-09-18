// StatusDerivationTests — M3.4. The table in `StatusDerivation.swift`, exercised row by row, plus
// the clearing rules and the "degrades to descriptor-only" claims.

import Foundation
import Testing

@testable import TkzCore

@Suite struct StatusDerivationTests {
    static let epoch = Date(timeIntervalSince1970: 1_788_944_400)  // Fixture.now

    static func descriptor(status: ClaudeSessionInfo.Status? = nil, parkedJobId: String? = nil,
                            statusUpdatedAt: Date? = nil) -> ClaudeSessionInfo {
        ClaudeSessionInfo(
            configDir: "~/.claude", pid: 1, sessionId: "s", status: status,
            statusUpdatedAt: statusUpdatedAt, parkedJobId: parkedJobId)
    }

    // MARK: - The table, row by row

    @Test func rule1_notAlive_isIdleWithNothingToAttend() {
        // There is no "exited" status (decision 2026-09-08): the row goes when the shell does.
        let outcome = StatusDerivation.derive(StatusInput(alive: false, now: Self.epoch))
        #expect(outcome.status == .idle)
        #expect(outcome.attention == false)
        #expect(outcome.isDone == false)
    }

    /// Claude quit (Ctrl-C twice) but the shell is alive: a plain terminal again.
    @Test func rule1b_ended_isIdle_notExited_evenWithAPendingPrompt() {
        let outcome = StatusDerivation.derive(
            StatusInput(
                ended: true, pending: PendingNotification(kind: .permission, receivedAt: Self.epoch),
                lastStopAt: Self.epoch.addingTimeInterval(-120),
                now: Self.epoch))
        #expect(outcome.status == .idle)
        #expect(outcome.attention == false)
        #expect(outcome.isDone == false)
        let dead = StatusDerivation.derive(StatusInput(alive: false, ended: true, now: Self.epoch))
        #expect(dead.status == .idle)
    }

    @Test func rule2_pendingPermission_waitsWithAttention() {
        let outcome = StatusDerivation.derive(
            StatusInput(
                descriptor: Self.descriptor(status: .busy),
                pending: PendingNotification(kind: .permission, receivedAt: Self.epoch),
                now: Self.epoch))
        #expect(outcome.status == .waiting(.permission))
        #expect(outcome.attention == true)
    }

    @Test func rule2_pendingQuestion_waits() {
        let outcome = StatusDerivation.derive(
            StatusInput(
                pending: PendingNotification(kind: .question, receivedAt: Self.epoch), now: Self.epoch))
        #expect(outcome.status == .waiting(.elicitation))
        #expect(outcome.attention == true)
    }

    @Test func rule2_pendingAgentInput_waits() {
        let outcome = StatusDerivation.derive(
            StatusInput(
                pending: PendingNotification(kind: .agentInput, receivedAt: Self.epoch), now: Self.epoch))
        #expect(outcome.status == .waiting(.agentInput))
        #expect(outcome.attention == true)
    }

    /// The ticket's prose claims `AttentionKind` maps 1:1 onto `WaitReason`; it does not.
    /// `.idleNudge` has no `waitReason` and must not light `NEEDS YOU` on its own — its only job is
    /// rule 5, accelerating an already-unattended `Stop` (see the tests below).
    @Test func rule2_pendingIdleNudgeAlone_fallsThroughToIdle() {
        let outcome = StatusDerivation.derive(
            StatusInput(
                pending: PendingNotification(kind: .idleNudge, receivedAt: Self.epoch), now: Self.epoch))
        #expect(outcome.status == .idle)
        #expect(outcome.attention == false)
    }

    /// Measured 2026-09-08: Claude Code writes `status: "waiting"` while a permission prompt is
    /// up, so NEEDS YOU works without any hook. It must not beat an explicit pending prompt's
    /// reason, and it must beat "parked".
    @Test func rule2b_descriptorWaiting_waitsWithAttention_withoutHooks() {
        let outcome = StatusDerivation.derive(
            StatusInput(descriptor: Self.descriptor(status: .waiting), now: Self.epoch))
        #expect(outcome.status == .waiting(.permission))
        #expect(outcome.attention == true)

        let elicitation = StatusDerivation.derive(
            StatusInput(
                descriptor: Self.descriptor(status: .waiting),
                pending: PendingNotification(kind: .question, receivedAt: Self.epoch),
                now: Self.epoch))
        #expect(elicitation.status == .waiting(.elicitation))

        let parked = StatusDerivation.derive(
            StatusInput(descriptor: Self.descriptor(status: .waiting, parkedJobId: "j"), now: Self.epoch))
        #expect(parked.status == .waiting(.permission))
        #expect(ClaudeSessionInfo.Status(raw: "waiting") == .waiting)
    }

    @Test func rule3_parked_isIdleEvenWhenBusy() {
        let outcome = StatusDerivation.derive(
            StatusInput(descriptor: Self.descriptor(status: .busy, parkedJobId: "job-1"), now: Self.epoch))
        #expect(outcome.status == .idle)
        #expect(outcome.attention == false)
    }

    @Test func rule4_busyDescriptor_isWorking() {
        let outcome = StatusDerivation.derive(
            StatusInput(descriptor: Self.descriptor(status: .busy), now: Self.epoch))
        #expect(outcome.status == .working)
    }

    @Test func rule5_stop30sAgoUnattended_isIdleDone() {
        let outcome = StatusDerivation.derive(
            StatusInput(lastStopAt: Self.epoch.addingTimeInterval(-30), now: Self.epoch))
        #expect(outcome.status == .idle)
        #expect(outcome.attention == false)
        #expect(outcome.isDone == true)
    }

    @Test func rule5_stop61sAgoUnattended_isDoneUnattended() {
        let outcome = StatusDerivation.derive(
            StatusInput(lastStopAt: Self.epoch.addingTimeInterval(-61), now: Self.epoch))
        #expect(outcome.status == .waiting(.doneUnattended))
        #expect(outcome.attention == true)
        #expect(outcome.isDone == false)
    }

    @Test func rule5_idleNudgeAfterAFreshStop_isDoneUnattendedEvenUnder60s() {
        let stop = Self.epoch.addingTimeInterval(-5)
        let outcome = StatusDerivation.derive(
            StatusInput(
                pending: PendingNotification(kind: .idleNudge, receivedAt: Self.epoch.addingTimeInterval(-1)),
                lastStopAt: stop, now: Self.epoch))
        #expect(outcome.status == .waiting(.doneUnattended))
        #expect(outcome.attention == true)
    }

    @Test func rule5_idleNudgeBeforeTheStop_doesNotCountAsAfter() {
        let stop = Self.epoch.addingTimeInterval(-5)
        let outcome = StatusDerivation.derive(
            StatusInput(
                pending: PendingNotification(kind: .idleNudge, receivedAt: Self.epoch.addingTimeInterval(-10)),
                lastStopAt: stop, now: Self.epoch))
        #expect(outcome.status == .idle)
        #expect(outcome.isDone == true)
    }

    /// The rule the ticket's prose gets wrong, pinned end to end: an `.idleNudge` on its own is
    /// never `NEEDS YOU`, but the very same nudge, arriving after an unattended `Stop`, short-
    /// circuits the 60 s grace and makes the row `NEEDS YOU` immediately.
    @Test func idleNudgeAloneIsNotAttention_butAfterAnUnattendedStopItIsImmediateNeedsYou() {
        let alone = StatusDerivation.derive(
            StatusInput(pending: PendingNotification(kind: .idleNudge, receivedAt: Self.epoch), now: Self.epoch))
        #expect(alone.status == .idle)
        #expect(alone.attention == false)

        let stop = Self.epoch.addingTimeInterval(-10)  // well under the 60s grace
        let afterStop = StatusDerivation.derive(
            StatusInput(
                pending: PendingNotification(kind: .idleNudge, receivedAt: Self.epoch),
                lastStopAt: stop, now: Self.epoch))
        #expect(afterStop.status == .waiting(.doneUnattended))
        #expect(afterStop.attention == true)
    }

    @Test func rule6_stopOlderThanAttended_isPlainIdle() {
        let outcome = StatusDerivation.derive(
            StatusInput(
                lastStopAt: Self.epoch.addingTimeInterval(-30),
                attendedAt: Self.epoch.addingTimeInterval(-10), now: Self.epoch))
        #expect(outcome.status == .idle)
        #expect(outcome.attention == false)
        #expect(outcome.isDone == false)
    }

    @Test func rule7_nothingApplies_isIdle() {
        let outcome = StatusDerivation.derive(StatusInput(now: Self.epoch))
        #expect(outcome.status == .idle)
        #expect(outcome.attention == false)
        #expect(outcome.isDone == false)
    }

    // MARK: - Precedence between rules

    @Test func precedence_endedBeatsPending() {
        let outcome = StatusDerivation.derive(
            StatusInput(
                ended: true, pending: PendingNotification(kind: .agentInput, receivedAt: Self.epoch),
                now: Self.epoch))
        #expect(outcome.status == .idle)
        #expect(outcome.attention == false)
    }

    @Test func precedence_parkedBeatsBusy() {
        let outcome = StatusDerivation.derive(
            StatusInput(descriptor: Self.descriptor(status: .busy, parkedJobId: "job-1"), now: Self.epoch))
        #expect(outcome.status == .idle)
    }

    @Test func precedence_pendingBeatsBusy() {
        let outcome = StatusDerivation.derive(
            StatusInput(
                descriptor: Self.descriptor(status: .busy),
                pending: PendingNotification(kind: .permission, receivedAt: Self.epoch), now: Self.epoch))
        #expect(outcome.status == .waiting(.permission))
    }

    // MARK: - Clearing rules (folded through `applyEvent`/`applyDescriptor`, but the derivation
    // itself only sees the *result* of a clear — a `nil` pending — so these prove the pending
    // notification, once cleared, no longer drives `.waiting`)

    @Test func clearing_noPendingFallsThroughToTheRestOfTheTable() {
        let outcome = StatusDerivation.derive(
            StatusInput(descriptor: Self.descriptor(status: .busy), pending: nil, now: Self.epoch))
        #expect(outcome.status == .working)
    }

    // Clearing on promptSubmitted/turnEnded/sessionEnd/attentionCleared, and the busy-descriptor
    // rule (newer clears, older does not), are reducer behaviour — see `ReducersTests.HookTests`.

    // MARK: - Degradation

    @Test func degradesToDescriptorOnly_withNoEvents() {
        let busy = StatusDerivation.derive(
            StatusInput(descriptor: Self.descriptor(status: .busy), now: Self.epoch))
        #expect(busy.status == .working)

        let idle = StatusDerivation.derive(
            StatusInput(descriptor: Self.descriptor(status: .idle), now: Self.epoch))
        #expect(idle.status == .idle)
    }

    @Test func plainShell_noDescriptorNoEvents_isIdleWhileAlive() {
        let outcome = StatusDerivation.derive(StatusInput(alive: true, now: Self.epoch))
        #expect(outcome.status == .idle)
        #expect(outcome.attention == false)
    }

    // MARK: - The `LiveSessionState` convenience

    @Test func liveConvenienceMatchesTheExplicitInput() {
        var live = LiveSessionState()
        live.descriptor = Self.descriptor(status: .busy)
        let fromLive = StatusDerivation.derive(live, now: Self.epoch)
        let fromInput = StatusDerivation.derive(
            StatusInput(descriptor: live.descriptor, now: Self.epoch))
        #expect(fromLive == fromInput)
    }
}
