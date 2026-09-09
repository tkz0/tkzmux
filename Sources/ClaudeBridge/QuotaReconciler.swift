// QuotaReconciler — turning a stream of quota readings into a number that does not lie (TKZ-32).
//
// Why this exists at all: every concurrent Claude Code session runs its own statusline and writes
// its account's sidecar with *its own* last-seen `rate_limits`, stamping a fresh `updated_at`
// regardless. An idle session therefore publishes stale, *lower* percentages, and timestamps cannot
// tell the two apart. What can: usage inside a fixed quota window never decreases, and every writer
// reports the same `resets_at` for a given window. So the reconciler tracks a high-water mark per
// window, keyed on `resets_at`.
//
// Two guards stop that high-water mark from freezing the number, and both were added after it did:
//
//   1. A window whose `resets_at` has passed is **dead**. Its percentage describes quota that no
//      longer exists, so it is never displayed, never held, and never allowed to veto a new reading.
//   2. A mark that no reading re-confirms within `confirmationTTL` loses its veto — in *every*
//      branch — and the lower reading is believed. This is not theoretical: at a weekly reset
//      boundary one statusline tick carried the *new* `resets_at` with the *old*, not-yet-zeroed
//      percentage, and a plain `max` then pinned the widget at 13% for a full week while real usage
//      was 2%. A live session rewrites its sidecar at least every 30 s, so a genuine maximum is
//      re-confirmed ~20 times per TTL while a bogus one simply ages out.
//
// The state is per account *and* per window. Before it was split per account, one plan's `resets_at`
// looked to the other like either a stale writer or a quota reset, and the badge showed blended
// nonsense.
//
// Everything here is pure and clock-injected, so every scenario is testable without touching a file.

import Foundation

/// One quota window exactly as a sidecar reports it, before reconciliation.
///
/// `percent == nil` means the field was **absent** from the payload — the producer omits rather
/// than nulls precisely so this case stays distinguishable from a genuine zero.
public struct QuotaReading: Hashable, Sendable {
    public var percent: Int?
    public var resetsAt: Date?

    public init(percent: Int? = nil, resetsAt: Date? = nil) {
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// What to display for a window after reconciliation.
///
/// `percent` can be nil while `resetsAt` is not: a session that has not made its first API call
/// knows when its window ends but not how much of it is gone.
public struct QuotaOutcome: Hashable, Sendable {
    public var percent: Int?
    public var resetsAt: Date?

    public init(percent: Int? = nil, resetsAt: Date? = nil) {
        self.percent = percent
        self.resetsAt = resetsAt
    }

    public static let none = QuotaOutcome()
}

public enum QuotaReconciler {
    /// How long a high-water mark keeps its veto without being re-confirmed by a reading.
    public static let confirmationTTL: TimeInterval = 10 * 60
    /// A sidecar from a config dir that has not run in this long is a ghost — stop rendering it.
    public static let ghostCutoff: TimeInterval = 14 * 24 * 60 * 60

    /// The tracked high-water mark for one window. `resetsAt` is the window's identity: two readings
    /// belong to the same window iff their `resetsAt` are equal.
    public struct Mark: Hashable, Sendable {
        public var percent: Int
        public var resetsAt: Date
        /// When this mark was last **accepted**. Refreshed only on accept, never on a hold — that
        /// is what makes an unconfirmed mark age out.
        public var observedAt: Date

        public init(percent: Int, resetsAt: Date, observedAt: Date) {
            self.percent = percent
            self.resetsAt = resetsAt
            self.observedAt = observedAt
        }
    }

    /// A window whose reset has passed is over: its percentage describes dead quota. A window
    /// resetting exactly *now* is already dead.
    public static func isExpired(_ mark: Mark?, now: Date) -> Bool {
        guard let mark else { return false }
        return mark.resetsAt <= now
    }

    /// Merges one reading into the tracked mark, returning the mark to keep and the value to show.
    ///
    /// The rules, in evaluation order — R5's and R6's fall-through are the two easiest to get wrong,
    /// so they are called out explicitly below.
    public static func reconcile(
        previous: Mark?,
        reading: QuotaReading,
        now: Date
    ) -> (mark: Mark?, outcome: QuotaOutcome) {
        // R1. Anything tracked for a window that has since ended is discarded outright — it can
        // neither be displayed nor veto a new reading.
        let live = isExpired(previous, now: now) ? nil : previous

        func hold(_ mark: Mark) -> (Mark?, QuotaOutcome) {
            (mark, QuotaOutcome(percent: mark.percent, resetsAt: mark.resetsAt))
        }

        // R2. Field absent from this payload — keep what we had rather than blanking. Note the
        // `observedAt` is deliberately *not* refreshed, so a window that stops being reported still
        // ages out of its veto.
        guard let percent = reading.percent else {
            if let live { return hold(live) }
            let future = reading.resetsAt.map { $0 > now } ?? false
            return (nil, QuotaOutcome(percent: nil, resetsAt: future ? reading.resetsAt : nil))
        }

        // R3. No reset time to key on — pass the value through untracked rather than guess. The
        // tracked mark survives unchanged and un-refreshed.
        guard let resetsAt = reading.resetsAt else {
            return (live, QuotaOutcome(percent: percent, resetsAt: nil))
        }

        // R4. The reading itself describes a window that already ended: no current information.
        if resetsAt <= now {
            if let live { return hold(live) }
            return (nil, .none)
        }

        if let live {
            // A mark nothing has re-confirmed lately loses its veto in every branch below, or a bad
            // sample could still freeze the number until the window rolls over.
            let confirmed = now.timeIntervalSince(live.observedAt) <= confirmationTTL

            if resetsAt < live.resetsAt {
                // R5. Older window than the one we track: an idle session's stale copy. Unconfirmed,
                // this falls through and *replaces* the mark — it does not hold anyway.
                if confirmed { return hold(live) }
            } else if resetsAt == live.resetsAt {
                // R6. Same window: usage only ever climbs, so keep the high-water mark. `>=` rather
                // than `>` matters — an equal reading re-confirms, which is how a live session keeps
                // a genuine maximum alive indefinitely.
                if percent >= live.percent {
                    let merged = Mark(percent: percent, resetsAt: resetsAt, observedAt: now)
                    return (merged, QuotaOutcome(percent: percent, resetsAt: resetsAt))
                }
                // …unless the mark has gone unconfirmed, in which case believe the lower reading.
                if confirmed { return hold(live) }
            }
            // R7. A later window means the quota reset — start over from this reading, whether or
            // not the old mark was confirmed.
        }

        // R8. First sighting, or any fall-through above.
        let fresh = Mark(percent: percent, resetsAt: resetsAt, observedAt: now)
        return (fresh, QuotaOutcome(percent: percent, resetsAt: resetsAt))
    }
}

/// The tracked marks for one account. Process-lifetime and never persisted: restoring a stale
/// percentage as if it were current is worse than showing nothing.
public struct AccountQuotaState: Hashable, Sendable {
    public var fiveHour: QuotaReconciler.Mark?
    public var sevenDay: QuotaReconciler.Mark?
    /// Per-model weekly windows, keyed by display label. Claude Code does not currently send these,
    /// but they share `reconcile` and so are covered by both guards if it starts.
    public var scoped: [String: QuotaReconciler.Mark] = [:]

    public init() {}

    /// Applies one reading of each fixed window. The two fixed windows are written back
    /// unconditionally, nil included.
    public mutating func apply(
        fiveHour fiveHourReading: QuotaReading,
        sevenDay sevenDayReading: QuotaReading,
        now: Date
    ) -> (fiveHour: QuotaOutcome, sevenDay: QuotaOutcome) {
        let five = QuotaReconciler.reconcile(previous: fiveHour, reading: fiveHourReading, now: now)
        let seven = QuotaReconciler.reconcile(previous: sevenDay, reading: sevenDayReading, now: now)
        fiveHour = five.mark
        sevenDay = seven.mark
        return (five.outcome, seven.outcome)
    }

    /// Applies the scoped windows and returns them ordered as the UI would show them.
    ///
    /// Two asymmetries with the fixed windows, both deliberate: a nil result never *deletes* a
    /// scoped entry (so a model missing from one payload keeps rendering), and the only removal is
    /// the expiry sweep below.
    public mutating func apply(
        scopedReadings: [(label: String, reading: QuotaReading)],
        now: Date
    ) -> [(label: String, outcome: QuotaOutcome)] {
        for entry in scopedReadings {
            let merged = QuotaReconciler.reconcile(
                previous: scoped[entry.label], reading: entry.reading, now: now)
            if let mark = merged.mark { scoped[entry.label] = mark }
        }
        for (label, mark) in scoped where mark.resetsAt <= now {
            scoped.removeValue(forKey: label)
        }
        // Descending by percent. Swift's sort is not stable, so the label breaks ties rather than
        // leaving the order to depend on dictionary iteration.
        return scoped
            .map { (label: $0.key, outcome: QuotaOutcome(percent: $0.value.percent, resetsAt: $0.value.resetsAt)) }
            .sorted { a, b in
                let (left, right) = (a.outcome.percent ?? 0, b.outcome.percent ?? 0)
                return left == right ? a.label < b.label : left > right
            }
    }
}
