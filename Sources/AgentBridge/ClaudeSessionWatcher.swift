// ClaudeSessionWatcher — M3.1.
//
// Claude Code writes `<configDir>/sessions/<pid>.json` and rewrites it *in place* (same inode) as
// status flips between idle/busy, so a directory watcher alone would miss those flips: every
// descriptor gets its own per-file `DispatchSource` in addition to the directory-level one that
// catches new/removed files. A sibling `<pid>.<hash>.key` file exists next to each descriptor and
// must never be read — only `*.json` whose basename (minus extension) is an integer pid qualifies.
//
// On Linux (WOR-306) none of the per-file machinery is needed: one inotify watch on each `sessions`
// directory (TkzPlatform's `FileWatcher`) names the entry behind every create, in-place write,
// rename-replace and delete, so the watch count is one per account whatever the number of
// sessions, and each named event feeds the same debounce → settle → `readAndApply` path the
// per-file sources feed on macOS. The macOS kqueue sources, with their inode re-open, are unchanged.

import Dispatch
import Foundation
import Synchronization
import TkzCore
#if !os(macOS)
import TkzPlatform
#endif

/// Identifies one descriptor: which account's config dir it came from, and its pid.
public struct DescriptorKey: Hashable, Sendable {
    public var configDir: String
    public var pid: pid_t

    public init(configDir: String, pid: pid_t) {
        self.configDir = configDir
        self.pid = pid
    }
}

/// The last known parsed value of a descriptor plus its liveness.
public struct DescriptorState: Hashable, Sendable {
    public var info: ClaudeSessionInfo
    public var alive: Bool
    public var lastSeenAt: Date

    public init(info: ClaudeSessionInfo, alive: Bool, lastSeenAt: Date) {
        self.info = info
        self.alive = alive
        self.lastSeenAt = lastSeenAt
    }
}

/// One change to the discovered set of sessions.
public enum DescriptorEvent: Sendable {
    case updated(ClaudeSessionInfo, alive: Bool)
    case removed(DescriptorKey)
}

/// Watches `<configDir>/sessions` for every configured Claude Code account, keeping a live snapshot
/// of every descriptor and its liveness, and emitting `DescriptorEvent`s as things change.
///
/// Every `DispatchSource` (directory, per-file, debounce, sweep) targets `queue`, a private serial
/// queue, so the handlers below always run there in turn — `onEvent` is invoked from those handlers
/// and so is always on `queue`, in order. `storage` is a `Mutex` (not `@unchecked Sendable`) guarding
/// the actual dictionaries; that is strictly stronger than the queue confinement needs, but it is
/// what lets this class satisfy `Sendable` under strict concurrency without an escape hatch. `start`,
/// `stop` and `setConfigDirs` additionally hop onto `queue` via `queue.sync` since they may be called
/// from any thread; `snapshot()` reads `storage` directly and does **not** hop onto `queue`, so it is
/// safe to call from inside an `onEvent` callback (calling `start`/`stop`/`setConfigDirs`
/// re-entrantly from inside `onEvent`, on the other hand, would deadlock on `queue.sync` — same as
/// re-entering any serial queue from its own callback).
public final class ClaudeSessionWatcher: AgentObservationWatcher {
    private let queue = DispatchQueue(label: "se.tkz.tkzmux.ClaudeSessionWatcher")
    private let liveness: any ProcessLiveness
    private let debounce: Duration
    private let sweepInterval: Duration
    /// How long a descriptor whose process is gone keeps its file watch. Long enough that a
    /// misjudged liveness check cannot silently stop tracking a live session; injectable so the
    /// tests do not have to wait it out.
    private let deadWatchGrace: TimeInterval
    private let onEvent: @Sendable (DescriptorEvent) -> Void
    private let storage: Mutex<Storage>

    private struct Storage {
        var configDirs: [String] = []
        #if os(macOS)
        var dirSources: [String: DispatchSourceFileSystemObject] = [:]
        #else
        /// One inotify instance behind every account's `sessions` directory; made on first use,
        /// released by `stop`.
        var fileWatcher: (any FileWatcher)?
        var dirWatches: [String: FileWatchID] = [:]
        /// The last error adding each directory's watch, so the sweep's retries log it once.
        var dirWatchErrors: [String: FileWatcherError] = [:]
        #endif
        var files: [DescriptorKey: FileWatch] = [:]
        var snapshot: [DescriptorKey: DescriptorState] = [:]
        var sweepTimer: DispatchSourceTimer?
        var started = false
    }

    #if os(macOS)
    /// Per-descriptor watch state: the open fd, its `DispatchSource`, and the debounce timer.
    private final class FileWatch {
        var fd: Int32 = -1
        var source: DispatchSourceFileSystemObject?
        var debounceTimer: DispatchSourceTimer?
        var path: String
        var inode: ino_t?

        init(path: String) { self.path = path }

        func cancel() {
            source?.cancel()
            source = nil
            debounceTimer?.cancel()
            debounceTimer = nil
            // The source's own cancel handler closes `fd` once cancellation actually completes
            // (asynchronously); closing it here would risk the fd number being reused for an
            // unrelated file while the kqueue registration on the old fd is still alive.
            fd = -1
        }
    }
    #else
    /// Per-descriptor state: just the debounce timer. The directory watch names every entry, so
    /// nothing is opened per file; being in `files` still means "tracked" (see `releaseWatch`).
    private final class FileWatch {
        var debounceTimer: DispatchSourceTimer?
        var path: String

        init(path: String) { self.path = path }

        func cancel() {
            debounceTimer?.cancel()
            debounceTimer = nil
        }
    }
    #endif

    public init(
        configDirs: [String],
        liveness: any ProcessLiveness = SystemProcessLiveness(),
        debounce: Duration = .milliseconds(100),
        sweepInterval: Duration = .seconds(5),
        deadWatchGrace: TimeInterval = 120,
        onEvent: @escaping @Sendable (DescriptorEvent) -> Void
    ) {
        self.liveness = liveness
        self.debounce = debounce
        self.sweepInterval = sweepInterval
        self.deadWatchGrace = deadWatchGrace
        self.onEvent = onEvent
        self.storage = Mutex(Storage(configDirs: configDirs))
    }

    deinit {
        storage.withLock { s in
            for (_, watch) in s.files { watch.cancel() }
            #if os(macOS)
            for (_, source) in s.dirSources { source.cancel() }
            #else
            s.fileWatcher?.cancel()
            #endif
            s.sweepTimer?.cancel()
        }
    }

    // MARK: - Lifecycle (public API — may be called from any thread)

    public func start() {
        let events = queue.sync {
            storage.withLock { s -> [DescriptorEvent] in
                guard !s.started else { return [] }
                s.started = true
                var events: [DescriptorEvent] = []
                for dir in s.configDirs {
                    events += startWatchingConfigDir(dir, &s)
                }
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
                for (_, source) in s.dirSources { source.cancel() }
                s.dirSources.removeAll()
                #else
                s.fileWatcher?.cancel()
                s.fileWatcher = nil
                s.dirWatches.removeAll()
                s.dirWatchErrors.removeAll()
                #endif
                s.sweepTimer?.cancel()
                s.sweepTimer = nil
            }
        }
    }

    public func snapshot() -> [DescriptorKey: DescriptorState] {
        storage.withLock { $0.snapshot }
    }

    /// How many descriptor file watches are currently open — one `O_EVTONLY` fd and one kqueue
    /// registration each. Lower than `snapshot().count` once dead descriptors have been released;
    /// see ``releaseWatch(key:_:)``. On Linux, how many descriptors are tracked: none of them costs
    /// a watch of its own (see ``directoryWatchCount``).
    public var openWatchCount: Int {
        storage.withLock { $0.files.count }
    }

    #if !os(macOS)
    /// How many inotify watches this watcher holds: one per watched `sessions` directory.
    public var directoryWatchCount: Int {
        storage.withLock { $0.fileWatcher?.watchCount ?? 0 }
    }
    #endif

    public func setConfigDirs(_ dirs: [String]) {
        let events = queue.sync {
            storage.withLock { s -> [DescriptorEvent] in
                let old = Set(s.configDirs)
                let new = Set(dirs)
                s.configDirs = dirs
                var events: [DescriptorEvent] = []
                for removedDir in old.subtracting(new) {
                    events += stopWatchingConfigDir(removedDir, &s)
                }
                guard s.started else { return events }
                for addedDir in new.subtracting(old) {
                    events += startWatchingConfigDir(addedDir, &s)
                }
                return events
            }
        }
        events.forEach(onEvent)
    }

    // MARK: - Directory watching (all of the below run only while `storage` is locked, on `queue`)

    private func sessionsDir(for configDir: String) -> String {
        (configDir as NSString).appendingPathComponent("sessions")
    }

    private func startWatchingConfigDir(_ configDir: String, _ s: inout Storage) -> [DescriptorEvent] {
        openDirSource(for: configDir, &s)
        return scanConfigDir(configDir, &s)
    }

    /// No `.removed` events: `setConfigDirs` dropping an account simply stops reporting it.
    private func stopWatchingConfigDir(_ configDir: String, _ s: inout Storage) -> [DescriptorEvent] {
        #if os(macOS)
        s.dirSources[configDir]?.cancel()
        s.dirSources[configDir] = nil
        #else
        if let watch = s.dirWatches.removeValue(forKey: configDir) { s.fileWatcher?.remove(watch) }
        s.dirWatchErrors[configDir] = nil
        #endif
        for key in s.files.keys where key.configDir == configDir {
            s.files[key]?.cancel()
            s.files[key] = nil
            s.snapshot[key] = nil
        }
        return []
    }

    #if os(macOS)
    /// Opens the directory `DispatchSource` for `configDir`'s `sessions` directory, idempotently —
    /// a no-op if already open (fixes a prior bug where `start()` would open it twice, leaking a
    /// source and its fd) or if the directory does not exist yet. A missing directory is retried by
    /// the liveness sweep.
    private func openDirSource(for configDir: String, _ s: inout Storage) {
        guard s.dirSources[configDir] == nil else { return }
        guard s.configDirs.contains(configDir) else { return }
        let dir = sessionsDir(for: configDir)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: queue)
        source.setEventHandler { [weak self] in
            self?.onDirEvent(configDir)
        }
        source.setCancelHandler { close(fd) }
        s.dirSources[configDir] = source
        source.resume()
    }

    private func onDirEvent(_ configDir: String) {
        let events = storage.withLock { s in scanConfigDir(configDir, &s) }
        events.forEach(onEvent)
    }
    #else
    /// Adds `configDir`'s `sessions` directory to the shared inotify instance, idempotently — a
    /// no-op if already watched or if the directory does not exist yet (the sweep retries).
    private func openDirSource(for configDir: String, _ s: inout Storage) {
        guard s.dirWatches[configDir] == nil else { return }
        guard s.configDirs.contains(configDir) else { return }
        do throws(FileWatcherError) {
            if s.fileWatcher == nil {
                s.fileWatcher = try SystemFileWatcher(queue: queue) { [weak self] event in
                    self?.onWatchEvent(event)
                }
            }
            s.dirWatches[configDir] = try s.fileWatcher?.add(
                directory: sessionsDir(for: configDir),
                filter: { Self.descriptorPid(fromName: $0) != nil })
            s.dirWatchErrors[configDir] = nil
        } catch .noSuchDirectory {
            // Not created yet: Claude Code makes it on first run.
        } catch {
            // Degraded, not broken: the sweep lists the directory every `sweepInterval` until the
            // watch can be added (new and removed descriptors are still seen, in-place rewrites
            // are not).
            if s.dirWatchErrors.updateValue(error, forKey: configDir) != error {
                let dir = sessionsDir(for: configDir)
                Self.logger.warning(
                    "cannot watch \(dir, privacy: .private): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static let logger = TkzLogger(subsystem: "se.tkz.tkzmux", category: "sessionwatcher")

    /// Every event of the shared directory watcher, on `queue`. A named descriptor event only arms
    /// that descriptor's debounce, so a create, an in-place rewrite, a rename-replace or a delete
    /// each settles into one `readAndApply` (or one removal).
    private func onWatchEvent(_ event: FileWatchEvent) {
        let events = storage.withLock { s -> [DescriptorEvent] in
            switch event {
            case .overflow:
                // The kernel dropped events: list every directory again and re-read every tracked
                // descriptor. `applyUpdate` reports only what actually changed.
                var events: [DescriptorEvent] = []
                for dir in s.configDirs { events += scanConfigDir(dir, &s) }
                for (key, watch) in s.files {
                    if let event = readAndApply(key: key, watch: watch, &s) { events.append(event) }
                }
                return events
            case .watchRemoved(let id):
                // The sessions directory was deleted or moved away: drop what was in it, and let
                // the sweep watch it again once it is back.
                guard let dir = s.dirWatches.first(where: { $0.value == id })?.key else { return [] }
                s.dirWatches[dir] = nil
                return scanConfigDir(dir, &s)
            case .changed(let change):
                guard let dir = s.dirWatches.first(where: { $0.value == change.watch })?.key else { return [] }
                guard let name = change.name, let pid = Self.descriptorPid(fromName: name) else {
                    // The directory itself changed.
                    return scanConfigDir(dir, &s)
                }
                let key = DescriptorKey(configDir: dir, pid: pid)
                if s.files[key] == nil {
                    // A long-dead descriptor stays untracked, as on macOS, where it has no watch
                    // left to fire; only its deletion still has to clear the snapshot.
                    guard change.kind == .removed || descriptorIsWatchable(key: key, s) else { return [] }
                    s.files[key] = FileWatch(
                        path: (sessionsDir(for: dir) as NSString).appendingPathComponent(name))
                }
                if let watch = s.files[key] { armDebounce(key: key, watch: watch) }
                return []
            }
        }
        events.forEach(onEvent)
    }
    #endif

    /// Lists `<configDir>/sessions`, opening watches for any new descriptor files and dropping
    /// watches for ones that vanished (the directory source doesn't tell us *which* file changed).
    private func scanConfigDir(_ configDir: String, _ s: inout Storage) -> [DescriptorEvent] {
        guard s.configDirs.contains(configDir) else { return [] }
        let dir = sessionsDir(for: configDir)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []

        var events: [DescriptorEvent] = []
        var seenPids = Set<pid_t>()
        for name in entries {
            guard let pid = Self.descriptorPid(fromName: name) else { continue }
            seenPids.insert(pid)
            let key = DescriptorKey(configDir: configDir, pid: pid)
            // A descriptor long since concluded dead keeps no watch — see `releaseWatch`.
            if s.files[key] == nil, descriptorIsWatchable(key: key, s) {
                let watch = FileWatch(path: (dir as NSString).appendingPathComponent(name))
                s.files[key] = watch
                #if os(macOS)
                openFileSource(for: key, watch: watch, &s)
                #endif
                if let event = readAndApply(key: key, watch: watch, &s) { events.append(event) }
            }
        }

        // Any watched file whose pid is no longer present (deleted, and we missed the per-file
        // .delete event, e.g. because the source hadn't opened yet) is dropped too.
        // Both maps, not just `s.files`: a dead descriptor has no watch any more (see
        // `releaseWatch`) but still has a snapshot entry, and once its file is gone that entry must
        // go too — otherwise nothing would ever clear it.
        let known = Set(s.files.keys).union(s.snapshot.keys)
        for key in known where key.configDir == configDir && !seenPids.contains(key.pid) {
            if let event = removeDescriptor(key: key, &s) { events.append(event) }
        }
        return events
    }

    // MARK: - Per-file watching

    // Event-handler closures below capture only `key` (a `Sendable` value), never a `FileWatch`
    // reference directly — capturing the class itself across the closure that also touches
    // `storage`'s `inout sending` contents defeats the strict-concurrency checker's region
    // analysis (it cannot prove the non-`Sendable` `FileWatch` isn't retained past the lock). Every
    // handler instead re-looks-up `s.files[key]` from *inside* the lock it already holds.

    #if os(macOS)
    private func openFileSource(for key: DescriptorKey, watch: FileWatch, _ s: inout Storage) {
        let fd = open(watch.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watch.fd = fd
        watch.inode = Self.inode(ofFD: fd)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
        source.setEventHandler { [weak self] in
            self?.onFileEvent(key: key)
        }
        source.setCancelHandler { close(fd) }
        watch.source = source
        source.resume()
    }

    private func onFileEvent(key: DescriptorKey) {
        storage.withLock { s in
            guard let watch = s.files[key] else { return }
            armDebounce(key: key, watch: watch)
        }
    }
    #endif

    private func armDebounce(key: DescriptorKey, watch: FileWatch) {
        watch.debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + debounce.dispatchInterval)
        timer.setEventHandler { [weak self] in
            self?.onDebounceFired(key: key)
        }
        watch.debounceTimer = timer
        timer.resume()
    }

    private func onDebounceFired(key: DescriptorKey) {
        let event = storage.withLock { s -> DescriptorEvent? in
            guard let watch = s.files[key] else { return nil }
            return settleFile(key: key, watch: watch, &s)
        }
        if let event { onEvent(event) }
    }

    /// Decides whether the descriptor was deleted, rewritten in place, or replaced via rename, and
    /// reopens/re-reads as needed.
    private func settleFile(key: DescriptorKey, watch: FileWatch, _ s: inout Storage) -> DescriptorEvent? {
        guard FileManager.default.fileExists(atPath: watch.path) else {
            return removeDescriptor(key: key, &s)
        }
        #if os(macOS)
        // Re-open unconditionally: a rename-replace swaps the inode under the same path, and our
        // fd (opened O_EVTONLY on the old inode) would otherwise keep firing on the *old* file only.
        let newFD = open(watch.path, O_EVTONLY)
        if newFD >= 0 {
            let newInode = Self.inode(ofFD: newFD)
            if newInode != watch.inode {
                watch.source?.cancel()  // old fd is closed by its own cancel handler
                watch.fd = newFD
                watch.inode = newInode
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: newFD, eventMask: [.write, .extend, .delete, .rename, .attrib],
                    queue: queue)
                source.setEventHandler { [weak self] in
                    self?.onFileEvent(key: key)
                }
                source.setCancelHandler { close(newFD) }
                watch.source = source
                source.resume()
            } else {
                close(newFD)
            }
        }
        #endif
        return readAndApply(key: key, watch: watch, &s)
    }

    private func readAndApply(key: DescriptorKey, watch: FileWatch, _ s: inout Storage) -> DescriptorEvent? {
        guard let data = FileManager.default.contents(atPath: watch.path) else { return nil }
        guard let info = try? ClaudeSessionInfo.decode(data, configDir: key.configDir) else {
            // Torn write: keep the previous value, emit nothing.
            return nil
        }
        return applyUpdate(key: key, info: info, &s)
    }

    /// Closes the file watch but keeps the snapshot entry.
    ///
    /// A dead process will never rewrite its descriptor, so watching the file buys nothing — and a
    /// Claude Code that was SIGKILLed never deletes it, so the file (and therefore the watch) would
    /// otherwise outlive the process forever: one `O_EVTONLY` fd, one kqueue registration and one
    /// `DispatchSource` per crashed session, for the life of the app. That made the cost a function
    /// of the *directory's* contents rather than of live sessions.
    ///
    /// The snapshot entry is deliberately kept: it is a small struct, it is what makes the row read
    /// as dead rather than absent, and dropping it would only invite `scanConfigDir` to re-open the
    /// watch on the next directory event. `descriptorIsWatchable` is the other half of that.
    private func releaseWatch(key: DescriptorKey, _ s: inout Storage) {
        s.files[key]?.cancel()
        s.files[key] = nil
    }

    /// Whether a descriptor file deserves an open watch: yes, unless its process has been gone
    /// longer than ``deadWatchGrace``.
    private func descriptorIsWatchable(key: DescriptorKey, _ s: Storage) -> Bool {
        guard let state = s.snapshot[key], !state.alive else { return true }
        return Date().timeIntervalSince(state.lastSeenAt) <= deadWatchGrace
    }


    private func removeDescriptor(key: DescriptorKey, _ s: inout Storage) -> DescriptorEvent? {
        s.files[key]?.cancel()
        s.files[key] = nil
        guard s.snapshot[key] != nil else { return nil }
        s.snapshot[key] = nil
        return .removed(key)
    }

    /// Merges a freshly parsed descriptor into the snapshot, returning `.updated` only when the
    /// info or liveness actually changed.
    private func applyUpdate(key: DescriptorKey, info: ClaudeSessionInfo, _ s: inout Storage) -> DescriptorEvent? {
        let alive = liveness.isAlive(pid: info.pid, startedAt: info.startedAt)
        let previous = s.snapshot[key]
        let changed = previous?.info != info || previous?.alive != alive
        s.snapshot[key] = DescriptorState(info: info, alive: alive, lastSeenAt: Date())
        guard changed else { return nil }
        return .updated(info, alive: alive)
    }

    // MARK: - Liveness sweep

    private func startSweepTimer(_ s: inout Storage) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = sweepInterval.dispatchInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.onSweepFired()
        }
        s.sweepTimer = timer
        timer.resume()
    }

    private func onSweepFired() {
        let events = storage.withLock { s in sweep(&s) }
        events.forEach(onEvent)
    }

    private func sweep(_ s: inout Storage) -> [DescriptorEvent] {
        var events: [DescriptorEvent] = []
        // A sessions dir that didn't exist at start (or when last added) may exist now.
        #if os(macOS)
        for dir in s.configDirs where s.dirSources[dir] == nil {
            openDirSource(for: dir, &s)
            events += scanConfigDir(dir, &s)
        }
        #else
        for dir in s.configDirs where s.dirWatches[dir] == nil {
            openDirSource(for: dir, &s)
            events += scanConfigDir(dir, &s)
        }
        #endif
        for (key, current) in s.snapshot {
            let alive = liveness.isAlive(pid: current.info.pid, startedAt: current.info.startedAt)
            guard alive != current.alive else {
                // Long-dead and still on disk: stop paying for a watch on it. Deliberately *not*
                // done the moment it reads dead — `isAlive` is a pid check, and giving up a watch
                // immediately would mean a descriptor misjudged dead is never seen updating again.
                // After the grace there is nothing to miss: a Claude Code that comes back writes a
                // *new* `<pid>.json`, which the directory source catches.
                if !alive, s.files[key] != nil,
                    Date().timeIntervalSince(current.lastSeenAt) > deadWatchGrace
                {
                    releaseWatch(key: key, &s)
                }
                continue
            }
            var updated = current
            updated.alive = alive
            updated.lastSeenAt = Date()
            s.snapshot[key] = updated
            events.append(.updated(current.info, alive: alive))
        }
        return events
    }

    // MARK: - Helpers

    /// The pid a descriptor file is named after: `<pid>.json` with an all-digit pid. Anything else
    /// (the `<pid>.<hash>.key` sibling, a temp file) is not a descriptor.
    static func descriptorPid(fromName name: String) -> pid_t? {
        guard name.hasSuffix(".json") else { return nil }
        let base = String(name.dropLast(".json".count))
        guard !base.isEmpty, base.allSatisfy({ $0.isNumber }), let pid = pid_t(base) else { return nil }
        return pid
    }

    #if os(macOS)
    private static func inode(ofFD fd: Int32) -> ino_t? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return st.st_ino
    }
    #endif

    // MARK: - Pure snapshot helpers

    public static func interactive(in snapshot: [DescriptorKey: DescriptorState]) -> [DescriptorState] {
        snapshot.values.filter { $0.info.kind == .interactive }
    }

    /// Finds the interactive session a background descriptor was parked under: `bg.kind ==
    /// .background` and `bg.parkedJobId == parent.jobId`.
    public static func parent(
        ofBackground bg: ClaudeSessionInfo, in snapshot: [DescriptorKey: DescriptorState]
    ) -> DescriptorState? {
        guard bg.isBackground, let parkedJobId = bg.parkedJobId else { return nil }
        return snapshot.values.first { $0.info.jobId == parkedJobId }
    }
}

extension Duration {
    /// `Dispatch` timer APIs predate `Duration`; this converts losslessly enough for our
    /// millisecond-to-second granularity (debounce/sweep intervals).
    fileprivate var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        return .nanoseconds(Int(nanoseconds))
    }
}
