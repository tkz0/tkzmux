// StatuslineReader — the consumer half of the status line integration.
//
// `tkzmux-hook statusline` writes two kinds of file into `<AppPaths.support>/statusline`
// (`~/Library/Application Support/tkzmux` on macOS, `$XDG_DATA_HOME/tkzmux` on Linux):
//
//   usage-<accountKey>.json   quota for one Claude account   → `UsageSnapshot`
//   context-<sessionId>.json  one session's context/model/PR → `SessionSidecar`
//
// Both are rewritten in place by a live statusline every few seconds, so this follows
// `ClaudeSessionWatcher`'s shape exactly: one directory `DispatchSource` for files appearing and
// disappearing, one per-file source (a rewrite of an existing path is invisible to the directory
// source alone), a 100 ms per-file debounce, a 5 s sweep that retries a directory that did not
// exist yet, an unconditional re-open on settle so a rename-replace cannot leave the source watching
// the old inode, and last-good-value semantics so a torn read emits nothing.
//
// On Linux (WOR-306) the per-file sources are not needed: one inotify watch on the directory
// (TkzPlatform's `FileWatcher`) names the sidecar behind every write, rename and delete, and each
// named event arms that file's debounce, which settles through the same `readAndApply`.
//
// Quota goes through `QuotaReconciler` on the way out — see that file for why a raw reading is not
// trustworthy. Context sidecars need no reconciliation; they are simply joined on `sessionId`.

import Dispatch
import Foundation
import Synchronization
import TkzCore
import TkzPlatform

/// One change to what the statusline sidecars say.
public enum StatuslineEvent: Sendable {
    /// A reconciled quota snapshot for one account.
    case usage(UsageSnapshot)
    /// This account no longer has anything to show — a ghost sidecar, a deleted one, or one whose
    /// every window has expired. The store must *clear* the account rather than keep the last value.
    case usageCleared(accountKey: String)
    case context(SessionSidecar)
    case contextRemoved(sessionId: String)
}

public final class StatuslineReader: Sendable {
    /// A context sidecar older than this is ignored: whatever wrote it is long gone.
    static let contextMaxAge: TimeInterval = 24 * 60 * 60
    /// …and one older than this is deleted, so an abandoned directory does not grow forever.
    static let contextDeleteAge: TimeInterval = 7 * 24 * 60 * 60

    private let queue = DispatchQueue(label: "se.tkz.tkzmux.StatuslineReader")
    private let directory: String
    private let debounce: Duration
    private let sweepInterval: Duration
    private let now: @Sendable () -> Date
    private let onEvent: @Sendable (StatuslineEvent) -> Void
    private let storage: Mutex<Storage>

    private struct Storage {
        #if os(macOS)
        var dirSource: DispatchSourceFileSystemObject?
        #else
        /// The inotify instance with the directory's one watch; nil while it is not watched.
        var fileWatcher: (any FileWatcher)?
        /// The last error adding the watch, so the sweep's retries log it once.
        var watchError: FileWatcherError?
        #endif
        var files: [String: FileWatch] = [:]
        var quota: [String: AccountQuotaState] = [:]
        var usage: [String: UsageSnapshot] = [:]
        var context: [String: SessionSidecar] = [:]
        var sweepTimer: DispatchSourceTimer?
        var started = false
    }

    /// What each sidecar filename means. Anything that matches neither is ignored, which is how a
    /// `.tmp` from a half-finished write, or any unrelated file, stays invisible.
    enum Kind: Hashable {
        case usage(accountKey: String)
        case context(sessionId: String)

        /// `usage-<key>.json` with a key that is a safe filename, or `context-<id>.json`.
        static func of(_ name: String) -> Kind? {
            guard name.hasSuffix(".json") else { return nil }
            let base = String(name.dropLast(".json".count))
            if let key = base.dropPrefixIfPresent("usage-") {
                guard !key.isEmpty, key.count <= 64, key.allSatisfy(isKeyCharacter) else { return nil }
                return .usage(accountKey: key)
            }
            if let id = base.dropPrefixIfPresent("context-") {
                guard !id.isEmpty, id.count <= 128, id.allSatisfy(isKeyCharacter) else { return nil }
                return .context(sessionId: id)
            }
            return nil
        }

        private static func isKeyCharacter(_ c: Character) -> Bool {
            c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
        }
    }

    #if os(macOS)
    private final class FileWatch {
        var fd: Int32 = -1
        var source: DispatchSourceFileSystemObject?
        var debounceTimer: DispatchSourceTimer?
        var path: String
        var inode: ino_t?
        let kind: Kind

        init(path: String, kind: Kind) {
            self.path = path
            self.kind = kind
        }

        func cancel() {
            source?.cancel()
            source = nil
            debounceTimer?.cancel()
            debounceTimer = nil
            // The cancel handler closes `fd` once cancellation completes; closing it here could let
            // the number be reused while the old kqueue registration is still live.
            fd = -1
        }
    }
    #else
    /// Just the debounce: the directory watch names every sidecar, so nothing is opened per file.
    private final class FileWatch {
        var debounceTimer: DispatchSourceTimer?
        var path: String
        let kind: Kind

        init(path: String, kind: Kind) {
            self.path = path
            self.kind = kind
        }

        func cancel() {
            debounceTimer?.cancel()
            debounceTimer = nil
        }
    }
    #endif

    public init(
        directory: String,
        debounce: Duration = .milliseconds(100),
        sweepInterval: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = { Date() },
        onEvent: @escaping @Sendable (StatuslineEvent) -> Void
    ) {
        self.directory = directory
        self.debounce = debounce
        self.sweepInterval = sweepInterval
        self.now = now
        self.onEvent = onEvent
        self.storage = Mutex(Storage())
    }

    deinit {
        storage.withLock { s in
            for (_, watch) in s.files { watch.cancel() }
            #if os(macOS)
            s.dirSource?.cancel()
            #else
            s.fileWatcher?.cancel()
            #endif
            s.sweepTimer?.cancel()
        }
    }

    /// `<support>/statusline`, by default under `AppPaths.support` — the same directory
    /// `tkzmux-hook statusline` derives from its own location (`<support>/bin/tkzmux-hook`).
    public static func standardDirectory(supportDirectory: URL = AppPaths.support) -> String {
        supportDirectory.appendingPathComponent("statusline").path
    }

    // MARK: - Lifecycle

    public func start() {
        let events = queue.sync {
            storage.withLock { s -> [StatuslineEvent] in
                guard !s.started else { return [] }
                s.started = true
                openDirSource(&s)
                let events = scan(&s)
                startSweepTimer(&s)
                return events
            }
        }
        events.forEach(onEvent)
    }

    public func stop() {
        queue.sync {
            storage.withLock { s in
                guard s.started else { return }
                s.started = false
                for (_, watch) in s.files { watch.cancel() }
                s.files.removeAll()
                #if os(macOS)
                s.dirSource?.cancel()
                s.dirSource = nil
                #else
                s.fileWatcher?.cancel()
                s.fileWatcher = nil
                s.watchError = nil
                #endif
                s.sweepTimer?.cancel()
                s.sweepTimer = nil
            }
        }
    }

    public func usageSnapshot() -> [String: UsageSnapshot] { storage.withLock { $0.usage } }
    public func contextSnapshot() -> [String: SessionSidecar] { storage.withLock { $0.context } }

    // MARK: - Directory watching

    #if os(macOS)
    private func openDirSource(_ s: inout Storage) {
        guard s.dirSource == nil else { return }
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: queue)
        source.setEventHandler { [weak self] in self?.onDirEvent() }
        source.setCancelHandler { close(fd) }
        s.dirSource = source
        source.resume()
    }

    private func onDirEvent() {
        let events = storage.withLock { s in scan(&s) }
        events.forEach(onEvent)
    }
    #else
    /// Watches the directory, unless it already is or does not exist yet (the sweep retries).
    private func openDirSource(_ s: inout Storage) {
        guard s.fileWatcher == nil else { return }
        do throws(FileWatcherError) {
            let watcher = try SystemFileWatcher(queue: queue) { [weak self] event in
                self?.onWatchEvent(event)
            }
            do throws(FileWatcherError) {
                try watcher.add(directory: directory, filter: { Kind.of($0) != nil })
            } catch {
                watcher.cancel()
                throw error
            }
            s.fileWatcher = watcher
            s.watchError = nil
        } catch .noSuchDirectory {
            // Normal until the user consents to the status line integration.
        } catch {
            // The sweep keeps listing the directory, so sidecars appearing and vanishing are
            // still seen; rewrites of known ones are not.
            if s.watchError != error {
                s.watchError = error
                let directory = self.directory
                Self.logger.warning(
                    "cannot watch \(directory, privacy: .private): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static let logger = TkzLogger(subsystem: "se.tkz.tkzmux", category: "statusline")

    /// Every event of the directory watch, on `queue`. A named sidecar event arms that file's
    /// debounce, which settles into one `readAndApply` (or one removal).
    private func onWatchEvent(_ event: FileWatchEvent) {
        let events = storage.withLock { s -> [StatuslineEvent] in
            switch event {
            case .overflow:
                // Dropped events: list the directory again and re-read every sidecar; the apply
                // functions report only what changed.
                var events = scan(&s)
                for (name, watch) in s.files { events += readAndApply(name: name, watch: watch, &s) }
                return events
            case .watchRemoved:
                // The directory went away: drop its sidecars and let the sweep watch it again.
                s.fileWatcher?.cancel()
                s.fileWatcher = nil
                return scan(&s)
            case .changed(let change):
                guard let name = change.name, let kind = Kind.of(name) else { return scan(&s) }
                if s.files[name] == nil {
                    s.files[name] = FileWatch(
                        path: (directory as NSString).appendingPathComponent(name), kind: kind)
                }
                if let watch = s.files[name] { armDebounce(name: name, watch: watch) }
                return []
            }
        }
        events.forEach(onEvent)
    }
    #endif

    private func scan(_ s: inout Storage) -> [StatuslineEvent] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var events: [StatuslineEvent] = []
        var seen = Set<String>()
        for name in entries {
            guard let kind = Kind.of(name) else { continue }
            seen.insert(name)
            guard s.files[name] == nil else { continue }
            let watch = FileWatch(
                path: (directory as NSString).appendingPathComponent(name), kind: kind)
            s.files[name] = watch
            #if os(macOS)
            openFileSource(name: name, watch: watch)
            #endif
            events += readAndApply(name: name, watch: watch, &s)
        }
        for name in s.files.keys where !seen.contains(name) {
            events += remove(name: name, &s)
        }
        return events
    }

    // MARK: - Per-file watching

    // As in `ClaudeSessionWatcher`, handler closures capture only the `Sendable` file name and
    // re-look-up the (non-`Sendable`) `FileWatch` inside the lock they already hold.

    #if os(macOS)
    private func openFileSource(name: String, watch: FileWatch) {
        let fd = open(watch.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watch.fd = fd
        watch.inode = Self.inode(ofFD: fd)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
        source.setEventHandler { [weak self] in self?.onFileEvent(name: name) }
        source.setCancelHandler { close(fd) }
        watch.source = source
        source.resume()
    }

    private func onFileEvent(name: String) {
        storage.withLock { s in
            guard let watch = s.files[name] else { return }
            armDebounce(name: name, watch: watch)
        }
    }
    #endif

    private func armDebounce(name: String, watch: FileWatch) {
        watch.debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + debounce.dispatchInterval)
        timer.setEventHandler { [weak self] in self?.onDebounceFired(name: name) }
        watch.debounceTimer = timer
        timer.resume()
    }

    private func onDebounceFired(name: String) {
        let events = storage.withLock { s -> [StatuslineEvent] in
            guard let watch = s.files[name] else { return [] }
            return settle(name: name, watch: watch, &s)
        }
        events.forEach(onEvent)
    }

    private func settle(name: String, watch: FileWatch, _ s: inout Storage) -> [StatuslineEvent] {
        guard FileManager.default.fileExists(atPath: watch.path) else {
            return remove(name: name, &s)
        }
        #if os(macOS)
        // Re-open unconditionally: the producer publishes by rename, so the path keeps pointing at a
        // new inode while our fd still watches the old one.
        let newFD = open(watch.path, O_EVTONLY)
        if newFD >= 0 {
            let newInode = Self.inode(ofFD: newFD)
            if newInode != watch.inode {
                watch.source?.cancel()
                watch.fd = newFD
                watch.inode = newInode
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: newFD,
                    eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
                source.setEventHandler { [weak self] in self?.onFileEvent(name: name) }
                source.setCancelHandler { close(newFD) }
                watch.source = source
                source.resume()
            } else {
                close(newFD)
            }
        }
        #endif
        return readAndApply(name: name, watch: watch, &s)
    }

    private func remove(name: String, _ s: inout Storage) -> [StatuslineEvent] {
        guard let watch = s.files[name] else { return [] }
        watch.cancel()
        s.files[name] = nil
        switch watch.kind {
        case .usage(let accountKey):
            guard s.usage[accountKey] != nil else { return [] }
            s.usage[accountKey] = nil
            s.quota[accountKey] = nil
            return [.usageCleared(accountKey: accountKey)]
        case .context(let sessionId):
            guard s.context[sessionId] != nil else { return [] }
            s.context[sessionId] = nil
            return [.contextRemoved(sessionId: sessionId)]
        }
    }

    // MARK: - Reading

    private func readAndApply(name: String, watch: FileWatch, _ s: inout Storage) -> [StatuslineEvent] {
        switch watch.kind {
        case .usage(let accountKey):
            return applyUsage(path: watch.path, accountKey: accountKey, &s)
        case .context(let sessionId):
            return applyContext(path: watch.path, sessionId: sessionId, &s)
        }
    }

    private func applyUsage(path: String, accountKey: String, _ s: inout Storage) -> [StatuslineEvent] {
        let moment = now()
        // A sidecar from a config dir that has not run in two weeks would otherwise render a dead
        // badge forever. Deleting the file is the manual remedy.
        if let age = Self.age(ofFile: path, now: moment), age > QuotaReconciler.ghostCutoff {
            return clearUsage(accountKey: accountKey, &s)
        }
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        else {
            // Torn write: keep the previous value and emit nothing.
            return []
        }

        var state = s.quota[accountKey] ?? AccountQuotaState()
        let outcomes = state.apply(
            fiveHour: Self.reading(decoded.fiveHour),
            sevenDay: Self.reading(decoded.sevenDay),
            now: moment)
        s.quota[accountKey] = state

        var snapshot = decoded
        // The filename is the key, never `account.key` inside the document: the file is what the
        // reader and `AppState.usage` agree on.
        snapshot.accountKey = accountKey
        if snapshot.label?.isEmpty ?? true { snapshot.label = accountKey }
        snapshot.fiveHour = Self.window(outcomes.fiveHour)
        snapshot.sevenDay = Self.window(outcomes.sevenDay)

        guard snapshot.fiveHour != nil || snapshot.sevenDay != nil else {
            return clearUsage(accountKey: accountKey, &s)
        }
        guard s.usage[accountKey] != snapshot else { return [] }
        s.usage[accountKey] = snapshot
        return [.usage(snapshot)]
    }

    private func clearUsage(accountKey: String, _ s: inout Storage) -> [StatuslineEvent] {
        guard s.usage[accountKey] != nil else { return [] }
        s.usage[accountKey] = nil
        return [.usageCleared(accountKey: accountKey)]
    }

    private func applyContext(path: String, sessionId: String, _ s: inout Storage) -> [StatuslineEvent] {
        let moment = now()
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode(SessionSidecar.self, from: data)
        else {
            return []
        }
        // Whatever wrote a day-old sidecar is long gone; showing its context would be a lie.
        if let updatedAt = decoded.updatedAt,
           moment.timeIntervalSince(updatedAt) > Self.contextMaxAge {
            guard s.context[sessionId] != nil else { return [] }
            s.context[sessionId] = nil
            return [.contextRemoved(sessionId: sessionId)]
        }
        guard s.context[sessionId] != decoded else { return [] }
        s.context[sessionId] = decoded
        return [.context(decoded)]
    }

    /// A window the reconciler could not put a percentage on is dropped rather than shown: the
    /// status bar has nothing to render for a reset time on its own.
    private static func window(_ outcome: QuotaOutcome) -> UsageWindow? {
        guard let percent = outcome.percent else { return nil }
        return UsageWindow(usedPercentage: Double(percent), resetsAt: outcome.resetsAt)
    }

    /// A window absent from the document *is* the missing-field case (R2): the producer omits a
    /// window it has no percentage for rather than writing a null.
    private static func reading(_ window: UsageWindow?) -> QuotaReading {
        guard let window else { return QuotaReading() }
        return QuotaReading(percent: Int(window.usedPercentage.rounded()), resetsAt: window.resetsAt)
    }

    // MARK: - Sweep

    private func startSweepTimer(_ s: inout Storage) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = sweepInterval.dispatchInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.onSweepFired() }
        s.sweepTimer = timer
        timer.resume()
    }

    private func onSweepFired() {
        let events = storage.withLock { s -> [StatuslineEvent] in
            // The directory may not have existed when we started.
            var events: [StatuslineEvent] = []
            #if os(macOS)
            if s.dirSource == nil {
                openDirSource(&s)
                events += scan(&s)
            }
            #else
            if s.fileWatcher == nil {
                openDirSource(&s)
                events += scan(&s)
            }
            #endif
            // Re-run the reconcile for every account even when no file changed: a high-water mark
            // whose window has expired, or which nothing has re-confirmed, has to age out on time
            // rather than at the next write.
            for (name, watch) in s.files {
                guard case .usage = watch.kind else { continue }
                events += settle(name: name, watch: watch, &s)
            }
            events += housekeepContext(&s)
            return events
        }
        events.forEach(onEvent)
    }

    /// Unlinks context sidecars nothing will ever read again.
    private func housekeepContext(_ s: inout Storage) -> [StatuslineEvent] {
        let moment = now()
        var events: [StatuslineEvent] = []
        for (name, watch) in s.files {
            guard case .context = watch.kind else { continue }
            guard let age = Self.age(ofFile: watch.path, now: moment), age > Self.contextDeleteAge
            else { continue }
            try? FileManager.default.removeItem(atPath: watch.path)
            events += remove(name: name, &s)
        }
        return events
    }

    // MARK: - Helpers

    #if os(macOS)
    private static func inode(ofFD fd: Int32) -> ino_t? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return info.st_ino
    }
    #endif

    private static func age(ofFile path: String, now: Date) -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return now.timeIntervalSince(modified)
    }
}

extension String {
    /// `nil` when the prefix is absent, so a `guard let` reads as "this is the usage kind".
    fileprivate func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

extension Duration {
    /// `Dispatch`'s timer APIs predate `Duration`.
    fileprivate var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        return .nanoseconds(Int(nanoseconds))
    }
}
