// The debounced writer: the only thing that ever calls `StateFile.save` in the running app.
//
// It lives in `Persistence` rather than `TkzApp` because it needs an `AppStore` and a `StateFile`
// and nothing at all from AppKit — which means `PersistenceTests` can drive the whole write policy
// headlessly, without standing up a window.
//
// ## Two things it must get right
//
// **Not every change is a durable change.** `ChangeSet.sessions` fires on every `live` mutation —
// a Claude status flip, a git refresh, a port scan — and none of that is persisted. Writing on
// delivery would rewrite the file several times a second while a session is merely running. So the
// saver projects `PersistedState`, compares it with what it last wrote, and does nothing when they
// are equal. The comparison is the filter; the 500 ms debounce only coalesces bursts (a live window
// resize, a drag across the sidebar).
//
// **The last mutation before quit has not been delivered yet.** `AppStore` coalesces deliveries to
// one per run-loop turn, so at `applicationWillTerminate` there is usually a mutation that no
// observer has seen. `flush()` therefore reads `store.state` directly and re-projects, rather than
// trusting anything a `ChangeSet` told it.

import Foundation
import TkzCore
import os

@MainActor
public final class StateAutosaver {
    /// design.md → *Session flows & persistence*: "500 ms debounced atomic write".
    public static let defaultDebounce: Duration = .milliseconds(500)

    private let store: AppStore
    private let file: StateFile
    private let debounce: Duration
    /// Serial, so writes cannot interleave, and `.userInitiated` rather than `.utility`: the file
    /// is small and infrequent, and a `.utility` queue was measurably starved for many seconds when
    /// the machine was busy — which for a persistence layer means the user's arrangement is not
    /// actually on disk when they think it is.
    private let queue = DispatchQueue(label: "se.tkz.tkzmux.state", qos: .userInitiated)
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "state")

    private var observer: AppStore.ObserverToken?
    private var debounceTask: Task<Void, Never>?
    /// What is on disk (or on its way there). `nil` until the first successful write.
    private var lastWritten: PersistedState?
    /// Unknown top-level keys read from the file, carried through every save.
    private var extras: [String: JSONValue]
    /// Latched off for a file this build must not overwrite.
    private var isEnabled: Bool

    /// Counters for tests and for `diagnosticsLine()`.
    public private(set) var writeCount = 0
    public private(set) var skippedCount = 0

    /// - Parameters:
    ///   - loaded: what `StateFile.load` returned at launch. It supplies both the unknown keys to
    ///     preserve and the baseline that suppresses a pointless write on the very first delivery.
    ///   - isEnabled: `false` disables writing entirely — `TKZMUX_FIXTURE=1` and a state file from
    ///     a newer tkzmux both land here.
    public init(
        store: AppStore,
        file: StateFile,
        loaded: LoadResult? = nil,
        debounce: Duration = StateAutosaver.defaultDebounce,
        isEnabled: Bool = true
    ) {
        self.store = store
        self.file = file
        self.debounce = debounce
        self.extras = loaded?.document?.extras ?? [:]
        self.lastWritten = loaded?.document?.state
        self.isEnabled = isEnabled && (loaded?.isWritable ?? true)
    }

    /// Starts listening. Separate from `init` so a caller can construct the saver before the store
    /// has finished being populated.
    public func start() {
        guard observer == nil else { return }
        observer = store.addObserver { [weak self] _ in
            // The change set is deliberately ignored: `chrome`, `structure`, `selection` and
            // `sessions` can all carry a durable change, and `sessions` can carry a non-durable
            // one. The projection comparison is a better filter than any of those bits.
            self?.scheduleIfNeeded()
        }
    }

    public func stop() {
        if let observer { store.removeObserver(observer) }
        observer = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: Scheduling

    private func scheduleIfNeeded() {
        guard isEnabled else { return }
        let projection = PersistedState(store.state)
        guard projection != lastWritten else {
            skippedCount += 1
            return
        }
        arm()
    }

    /// A `Task` rather than a `DispatchSourceTimer` on the main queue. The dispatch timer was
    /// measurably starved when the rest of the test suite was running — a burst of mutations armed
    /// it and it simply never fired, for ten seconds — because a main-*queue* source depends on the
    /// main queue actually being drained, which competes with everything else on the main actor.
    /// `Task.sleep` is scheduled by the concurrency runtime's own clock and resumes on the main
    /// actor when it is next free, which is the behaviour this wants in the app too.
    private func arm() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.write(PersistedState(self.store.state), synchronously: false)
        }
    }

    /// Writes any outstanding change now, blocking until it is on disk. `applicationWillTerminate`
    /// calls this; nothing else needs to.
    public func flush() {
        debounceTask?.cancel()
        debounceTask = nil
        guard isEnabled else { return }
        let projection = PersistedState(store.state)
        if projection != lastWritten { write(projection, synchronously: true) }
        // Even when there was nothing new to write, a debounced write may still be in flight.
        // Returning before it lands would mean quitting with the bytes not yet on disk.
        waitForPendingWrites()
    }

    /// Blocks until every write this saver has started has reached the disk. A barrier on the same
    /// serial queue the writes run on, so it needs no state of its own.
    public func waitForPendingWrites() {
        queue.sync {}
    }

    private func write(_ projection: PersistedState, synchronously: Bool) {
        guard isEnabled, projection != lastWritten else { return }
        // Record before the write, not after: a second mutation arriving while this one is in
        // flight must compare against what we are *about* to have on disk.
        lastWritten = projection
        writeCount += 1
        let document = StateDocument(state: projection, extras: extras)
        let file = self.file
        let logger = self.logger
        let work: @Sendable () -> Void = {
            do {
                try file.save(document)
            } catch {
                logger.error("state.json save failed: \(String(describing: error), privacy: .public)")
            }
        }
        // `sync` on the same serial queue also serialises behind any write already in flight, so a
        // flush at quit cannot race the debounced write it is replacing.
        if synchronously { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    public func diagnosticsLine() -> String {
        "state_writes=\(writeCount) state_skipped=\(skippedCount) state_enabled=\(isEnabled)"
    }
}
