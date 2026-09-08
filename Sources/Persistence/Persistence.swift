// Persistence — see docs/design.md. The module holds `state.json` (StateFile, PersistedState,
// Migrations, StateAutosaver, JSONValue — M5.1), the snapshot store (Snapshots.swift) and the
// background-session idle policy below.

import Foundation

/// Module marker used by the smoke tests until the module has real API.
public enum PersistenceModule {
    public static let name = "Persistence"
}

// MARK: - Background-session idle policy

/// *When* a background session should be handed to `ghostty_terminal_compress(INCREMENTAL)`.
///
/// This is the pure half of design.md → *Threading* → "Background sessions: … optional
/// `ghostty_terminal_compress(INCREMENTAL)` from an idle timer (under the lock)". It owns no timer,
/// no terminal and no clock: a caller ticks it with the current instant and it answers with the
/// ids that are due. That makes the whole rule unit-testable without waiting 60 seconds.
///
/// The rules it encodes come from `terminal.h`:
///
///   * Compression is *caller-driven*; libghostty creates no thread and no timer.
///   * `ghostty_terminal_compression_activity` returns an opaque token that changes whenever
///     compression-relevant state changes. The embedder should restart its idle delay on a change
///     — so a token change counts as activity here, exactly like a pty write.
///   * `PENDING` means "call again while still idle"; `COMPLETE` means "nothing more to do until
///     the activity token changes". `UNSUPPORTED` means stop asking entirely.
///   * A *visible* session is never compressed: the render tick already holds the lock often
///     enough, and stalling it is exactly what this policy exists to avoid.
///
/// **Measured, not assumed** (docs/perf.md → *Does compression pay?*): on 30 live sessions holding
/// 19 963 rows each, looping INCREMENTAL to `COMPLETE` took 113 ms and cut `phys_footprint` from
/// 577 MiB to 26 MiB, with a control run confirming the drop comes from `compress` and not from
/// the workload. (The M1.3 spike's "reclaimed nothing" measured `resident_size`, which on Darwin
/// keeps `MADV_FREE`'d pages until the kernel needs them.) So this timer is worth wiring — but
/// snapshot *before* compressing: reading history back rehydrates it.
///
/// One step costs ~66 µs and a full 20 000-row session ~3.8 ms, so `stepInterval` at 1 s is far
/// more conservative than the data requires; the ticket that wires the timer should re-tune it
/// against real frame pacing.
public struct IdleCompressionPolicy: Sendable, Equatable {
    /// How long a session must be quiet before its first compression step. design.md says 60 s.
    public var idleThreshold: Duration
    /// Gap between two steps of the same session while work is still `PENDING`. Small on purpose:
    /// an incremental step is bounded work, and the session is idle by definition.
    public var stepInterval: Duration

    public init(idleThreshold: Duration = .seconds(60), stepInterval: Duration = .seconds(1)) {
        self.idleThreshold = idleThreshold
        self.stepInterval = stepInterval
    }

    /// The outcome the caller feeds back after running a step.
    public enum StepResult: Sendable, Equatable {
        /// `GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING` — more work remains.
        case pending
        /// `GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE` — done until activity changes.
        case complete
        /// `GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED`, or the call failed. Never ask again.
        case unsupported
    }

    /// Per-session bookkeeping. Exposed for assertions; mutated only through the methods below.
    public struct Entry: Sendable, Equatable {
        public var lastActivity: ContinuousClock.Instant
        public var activityToken: UInt64
        public var isVisible: Bool
        /// Set once a `complete` step ran; cleared by the next activity.
        public var settled: Bool
        /// Set by `unsupported`; never cleared.
        public var disabled: Bool
        /// When the last step ran, so `stepInterval` can be honoured.
        public var lastStep: ContinuousClock.Instant?
    }

    public private(set) var entries: [String: Entry] = [:]

    public var trackedIDs: Set<String> { Set(entries.keys) }

    // MARK: Bookkeeping

    /// Start tracking a session. Its idle clock starts now.
    public mutating func register(
        _ id: String, at now: ContinuousClock.Instant, activityToken: UInt64 = 0, isVisible: Bool = false
    ) {
        entries[id] = Entry(
            lastActivity: now, activityToken: activityToken, isVisible: isVisible,
            settled: false, disabled: false, lastStep: nil
        )
    }

    public mutating func forget(_ id: String) {
        entries.removeValue(forKey: id)
    }

    /// Bytes arrived (or anything else the caller counts as work). Resets the idle clock and
    /// un-settles the session so a future `COMPLETE` does not keep it excluded forever.
    public mutating func noteActivity(_ id: String, at now: ContinuousClock.Instant) {
        guard var entry = entries[id] else { return }
        entry.lastActivity = now
        entry.settled = false
        entries[id] = entry
    }

    /// Feed the current `ghostty_terminal_compression_activity` token. A *changed* token is
    /// activity; an unchanged one is not, so polling it is free.
    public mutating func noteActivityToken(_ id: String, _ token: UInt64, at now: ContinuousClock.Instant) {
        guard var entry = entries[id] else { return }
        guard entry.activityToken != token else { return }
        entry.activityToken = token
        entry.lastActivity = now
        entry.settled = false
        entries[id] = entry
    }

    public mutating func noteVisibility(_ id: String, isVisible: Bool, at now: ContinuousClock.Instant) {
        guard var entry = entries[id] else { return }
        entry.isVisible = isVisible
        // Coming back to the foreground counts as activity: the user is about to type into it.
        if isVisible {
            entry.lastActivity = now
            entry.settled = false
        }
        entries[id] = entry
    }

    /// Record what a step returned.
    public mutating func noteStep(_ id: String, result: StepResult, at now: ContinuousClock.Instant) {
        guard var entry = entries[id] else { return }
        entry.lastStep = now
        switch result {
        case .pending:
            entry.settled = false
        case .complete:
            entry.settled = true
        case .unsupported:
            entry.disabled = true
            entry.settled = true
        }
        entries[id] = entry
    }

    // MARK: The decision

    /// Would this one session be compressed on a tick at `now`?
    public func isDue(_ id: String, at now: ContinuousClock.Instant) -> Bool {
        guard let entry = entries[id] else { return false }
        guard !entry.isVisible, !entry.disabled, !entry.settled else { return false }
        guard now - entry.lastActivity >= idleThreshold else { return false }
        if let lastStep = entry.lastStep, now - lastStep < stepInterval { return false }
        return true
    }

    /// Every session due for one incremental step at `now`, in a stable order.
    public func due(at now: ContinuousClock.Instant) -> [String] {
        entries.keys.filter { isDue($0, at: now) }.sorted()
    }
}
