// QuotaReconcilerTests — the scenarios that shaped the algorithm (TKZ-32).
//
// The rules were learned the hard way in a personal dashboard whose implementation had **no tests
// at all** — they existed only as prose in its notes. These are the first tests this algorithm has
// ever had, so each one names the failure it guards against rather than the branch it covers.
//
// Everything here is pure and clock-injected: no files, no watcher, no waiting.
import Foundation
import Testing

@testable import ClaudeBridge

private let t0 = Date(timeIntervalSince1970: 1_757_000_000)
private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }
private let minute: TimeInterval = 60
private let hour: TimeInterval = 3600
private let day: TimeInterval = 24 * 3600

private func reading(_ percent: Int?, _ resetsAt: Date?) -> QuotaReading {
    QuotaReading(percent: percent, resetsAt: resetsAt)
}

@Suite struct QuotaReconcilerTests {
    // MARK: S1 — the idle stale writer

    /// Every concurrent session writes the same account's sidecar with *its own* last-seen limits
    /// and a fresh `updated_at`, so an idle one publishes older, lower numbers that timestamps
    /// cannot distinguish. Observed in the wild: a long-idle session publishing `resets_at` values
    /// two weeks stale, alongside live sessions and a genuine 5-hour reset, within the same minute.
    @Test func staleWriterFromAnOlderWindowIsIgnored() {
        var state = AccountQuotaState()
        _ = state.apply(fiveHour: reading(60, at(2 * hour)), sevenDay: .init(), now: t0)

        let outcome = state.apply(
            fiveHour: reading(20, at(-14 * day)), sevenDay: .init(), now: at(minute)
        ).fiveHour

        #expect(outcome.percent == 60)
        #expect(outcome.resetsAt == at(2 * hour))
    }

    /// The same idle writer reporting the *current* window, just behind on the number.
    @Test func lowerReadingInTheSameWindowIsIgnoredWhileConfirmed() {
        var state = AccountQuotaState()
        _ = state.apply(fiveHour: reading(60, at(2 * hour)), sevenDay: .init(), now: t0)

        let outcome = state.apply(
            fiveHour: reading(20, at(2 * hour)), sevenDay: .init(), now: at(minute)
        ).fiveHour

        #expect(outcome.percent == 60)
    }

    /// …but a mark nothing re-confirms loses its veto, and the stale window then *replaces* it.
    /// This is the branch that is easiest to mis-port as "hold anyway".
    @Test func unconfirmedMarkYieldsToAStaleWriterAndIsReplaced() {
        var state = AccountQuotaState()
        _ = state.apply(fiveHour: reading(60, at(2 * hour)), sevenDay: .init(), now: t0)

        let outcome = state.apply(
            fiveHour: reading(20, at(hour)), sevenDay: .init(), now: at(11 * minute)
        ).fiveHour

        #expect(outcome.percent == 20)
        #expect(state.fiveHour?.resetsAt == at(hour))
    }

    // MARK: S2 — the mid-flip poisoning

    /// The failure the TTL exists for: at a weekly reset boundary one tick caught the server
    /// mid-flip and carried the **new** `resets_at` with the **old**, not-yet-zeroed percentage.
    /// A plain `max` then pinned the widget at 13% for a full week while real usage was 2%.
    @Test func poisonedWeeklyMarkAgesOutAfterTheTTL() {
        var state = AccountQuotaState()
        let newWeek = at(7 * day)
        _ = state.apply(fiveHour: .init(), sevenDay: reading(13, newWeek), now: t0)

        // The truth arrives every 30 s and is vetoed while the poisoned mark is still confirmed.
        for tick in stride(from: 30.0, through: 10 * minute, by: 30) {
            let outcome = state.apply(
                fiveHour: .init(), sevenDay: reading(2, newWeek), now: at(tick)
            ).sevenDay
            #expect(outcome.percent == 13, "still vetoed at +\(Int(tick))s")
        }

        // Exactly at the TTL it is still confirmed; a millisecond later it is not.
        #expect(
            state.apply(fiveHour: .init(), sevenDay: reading(2, newWeek), now: at(10 * minute))
                .sevenDay.percent == 13)
        #expect(
            state.apply(
                fiveHour: .init(), sevenDay: reading(2, newWeek), now: at(10 * minute + 0.001)
            ).sevenDay.percent == 2)
    }

    /// The same poisoning on the 5-hour window self-heals when the window rolls over, without the
    /// TTL doing anything — which is why only the weekly gauge ever froze visibly.
    @Test func poisonedFiveHourMarkDiesWithItsWindow() {
        var state = AccountQuotaState()
        _ = state.apply(fiveHour: reading(13, at(hour)), sevenDay: .init(), now: t0)

        let outcome = state.apply(
            fiveHour: reading(2, at(6 * hour)), sevenDay: .init(), now: at(2 * hour)
        ).fiveHour

        #expect(outcome.percent == 2)
    }

    // MARK: S3 — dead windows

    /// A window whose reset has passed describes quota that no longer exists. With the field then
    /// missing there is nothing to fall back on, so it blanks rather than holding a dead number.
    @Test func deadMarkWithAMissingFieldBlanks() {
        var state = AccountQuotaState()
        _ = state.apply(fiveHour: reading(80, at(hour)), sevenDay: .init(), now: t0)

        let outcome = state.apply(fiveHour: .init(), sevenDay: .init(), now: at(2 * hour)).fiveHour

        #expect(outcome.percent == nil)
        #expect(outcome.resetsAt == nil)
    }

    /// A dead mark cannot veto a new reading either, however high it was and however recently it
    /// was confirmed.
    @Test func deadMarkCannotVetoANewReading() {
        var state = AccountQuotaState()
        _ = state.apply(fiveHour: reading(80, at(hour)), sevenDay: .init(), now: t0)

        let outcome = state.apply(
            fiveHour: reading(5, at(7 * hour)), sevenDay: .init(), now: at(2 * hour)
        ).fiveHour

        #expect(outcome.percent == 5)
    }

    @Test func aReadingForAnAlreadyEndedWindowCarriesNoInformation() {
        var state = AccountQuotaState()
        let outcome = state.apply(fiveHour: reading(50, at(-hour)), sevenDay: .init(), now: t0).fiveHour
        #expect(outcome.percent == nil)
        #expect(outcome.resetsAt == nil)
        #expect(state.fiveHour == nil)
    }

    /// A window resetting exactly now is already over.
    @Test func aWindowResettingExactlyNowIsDead() {
        let ending = QuotaReconciler.Mark(percent: 5, resetsAt: t0, observedAt: t0)
        let stillOpen = QuotaReconciler.Mark(percent: 5, resetsAt: at(0.001), observedAt: t0)
        #expect(QuotaReconciler.isExpired(ending, now: t0))
        #expect(QuotaReconciler.isExpired(stillOpen, now: t0) == false)
    }

    // MARK: S4 — the quota reset

    /// A later `resets_at` means the quota reset. It wins immediately, confirmed mark or not — this
    /// is exactly the branch S2's poisoned tick abuses, which is why the TTL is the only guard here.
    @Test func aLaterWindowAlwaysWinsEvenWhenTheMarkIsConfirmed() {
        var state = AccountQuotaState()
        _ = state.apply(fiveHour: reading(95, at(hour)), sevenDay: .init(), now: t0)

        let outcome = state.apply(
            fiveHour: reading(3, at(6 * hour)), sevenDay: .init(), now: at(10)
        ).fiveHour

        #expect(outcome.percent == 3)
        #expect(state.fiveHour?.observedAt == at(10))
    }

    // MARK: S5 — a missing field holds

    /// The producer omits rather than nulls what a payload does not carry, so the reader can hold
    /// its previous value instead of flickering to an empty badge.
    @Test func aMissingFieldHoldsButDoesNotReConfirm() {
        var state = AccountQuotaState()
        _ = state.apply(fiveHour: reading(42, at(2 * hour)), sevenDay: .init(), now: t0)

        let held = state.apply(fiveHour: .init(), sevenDay: .init(), now: at(5 * minute)).fiveHour
        #expect(held.percent == 42)
        #expect(held.resetsAt == at(2 * hour))
        // The hold did not refresh the clock, so the mark still ages out on the original schedule.
        #expect(state.fiveHour?.observedAt == t0)

        let later = state.apply(
            fiveHour: reading(10, at(2 * hour)), sevenDay: .init(), now: at(11 * minute)
        ).fiveHour
        #expect(later.percent == 10)
    }

    /// Early in a session Claude Code knows when the window ends but not how much is gone.
    @Test func aFutureResetWithNoPercentIsReportedWithoutOne() {
        var state = AccountQuotaState()
        let outcome = state.apply(
            fiveHour: reading(nil, at(2 * hour)), sevenDay: .init(), now: t0
        ).fiveHour
        #expect(outcome.percent == nil)
        #expect(outcome.resetsAt == at(2 * hour))
    }

    /// No reset time to key on: pass the reading through untracked rather than guess which window
    /// it belongs to. The tracked mark survives, un-refreshed.
    @Test func aReadingWithNoResetTimeIsPassedThroughUntracked() {
        var state = AccountQuotaState()
        _ = state.apply(fiveHour: reading(60, at(2 * hour)), sevenDay: .init(), now: t0)

        let outcome = state.apply(
            fiveHour: reading(9, nil), sevenDay: .init(), now: at(minute)
        ).fiveHour

        #expect(outcome.percent == 9)
        #expect(outcome.resetsAt == nil)
        #expect(state.fiveHour?.percent == 60)
        #expect(state.fiveHour?.observedAt == t0)
    }

    /// An equal reading re-confirms the mark. Without this a live session republishing its maximum
    /// every 30 s would still let that maximum expire.
    @Test func anEqualReadingReConfirmsTheMark() {
        var state = AccountQuotaState()
        _ = state.apply(fiveHour: reading(60, at(2 * hour)), sevenDay: .init(), now: t0)
        _ = state.apply(fiveHour: reading(60, at(2 * hour)), sevenDay: .init(), now: at(9 * minute))

        let outcome = state.apply(
            fiveHour: reading(20, at(2 * hour)), sevenDay: .init(), now: at(15 * minute)
        ).fiveHour

        #expect(outcome.percent == 60, "the re-confirmation should have reset the TTL clock")
    }

    // MARK: S6 — per-account keying

    /// Before the state was split per account, one plan's `resets_at` looked to the other like
    /// either a stale writer or a quota reset, and the badge showed blended nonsense.
    @Test func twoAccountsDoNotVetoEachOther() {
        var personal = AccountQuotaState()
        var work = AccountQuotaState()

        let personalOut = personal.apply(
            fiveHour: reading(90, at(5 * hour)), sevenDay: .init(), now: t0).fiveHour
        let workOut = work.apply(
            fiveHour: reading(5, at(hour)), sevenDay: .init(), now: t0).fiveHour

        #expect(personalOut.percent == 90)
        #expect(workOut.percent == 5)

        // …and again with the values swapped, to catch any shared mutable state.
        #expect(personal.apply(
            fiveHour: reading(91, at(5 * hour)), sevenDay: .init(), now: at(30)).fiveHour.percent == 91)
        #expect(work.apply(
            fiveHour: reading(6, at(hour)), sevenDay: .init(), now: at(30)).fiveHour.percent == 6)
    }

    // MARK: Scoped windows

    /// Per-model weekly windows share `reconcile`, so both guards cover them too. Claude Code does
    /// not currently send them and nothing renders them yet; this keeps the behaviour honest for
    /// when it does.
    @Test func scopedWindowsShareTheHighWaterRule() {
        var state = AccountQuotaState()
        _ = state.apply(scopedReadings: [("Fable 5", reading(40, at(3 * day)))], now: t0)

        let held = state.apply(
            scopedReadings: [("Fable 5", reading(10, at(3 * day)))], now: at(minute))
        #expect(held.first?.outcome.percent == 40)
    }

    /// A model missing from one payload keeps rendering at its tracked value — the same "hold"
    /// rule as a missing fixed window.
    @Test func aScopedWindowMissingFromAPayloadKeepsRendering() {
        var state = AccountQuotaState()
        _ = state.apply(scopedReadings: [("Fable 5", reading(40, at(3 * day)))], now: t0)

        let still = state.apply(scopedReadings: [], now: at(minute))
        #expect(still.map(\.label) == ["Fable 5"])
        #expect(still.first?.outcome.percent == 40)
    }

    /// …until its own window ends, at which point it is dropped rather than lingering.
    @Test func anExpiredScopedWindowIsDropped() {
        var state = AccountQuotaState()
        _ = state.apply(scopedReadings: [("Fable 5", reading(40, at(hour)))], now: t0)

        #expect(state.apply(scopedReadings: [], now: at(2 * hour)).isEmpty)
        #expect(state.scoped.isEmpty)
    }

    /// A scoped entry with no reset time is never stored, so it never appears at all.
    @Test func aScopedWindowWithoutAResetTimeIsNeverStored() {
        var state = AccountQuotaState()
        #expect(state.apply(scopedReadings: [("Fable 5", reading(40, nil))], now: t0).isEmpty)
        #expect(state.scoped.isEmpty)
    }

    @Test func scopedWindowsAreOrderedByPercentDescending() {
        var state = AccountQuotaState()
        let ordered = state.apply(
            scopedReadings: [
                ("Low", reading(5, at(3 * day))),
                ("High", reading(80, at(3 * day))),
                ("Mid", reading(50, at(3 * day))),
            ],
            now: t0)
        #expect(ordered.map(\.label) == ["High", "Mid", "Low"])
    }
}
