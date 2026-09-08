// ClaudeSessionWatcher — TKZ-21 (M3.1). See docs/design.md → Claude integration → Discovery.
//
// Claude Code writes `<configDir>/sessions/<pid>.json` and rewrites it *in place* (same inode) as
// status flips between idle/busy, so a directory watcher alone would miss those flips: every
// descriptor gets its own per-file `DispatchSource` in addition to the directory-level one that
// catches new/removed files. A sibling `<pid>.<hash>.key` file exists next to each descriptor and
// must never be read — only `*.json` whose basename (minus extension) is an integer pid qualifies.

import Dispatch
import Foundation
import Synchronization
import TkzCore

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
public final class ClaudeSessionWatcher: Sendable {
    private let queue = DispatchQueue(label: "se.tkz.tkzmux.ClaudeSessionWatcher")
    private let liveness: any ProcessLiveness
    private let debounce: Duration
    private let sweepInterval: Duration
    private let onEvent: @Sendable (DescriptorEvent) -> Void
    private let storage: Mutex<Storage>

    private struct Storage {
        var configDirs: [String] = []
        var dirSources: [String: DispatchSourceFileSystemObject] = [:]
        var files: [DescriptorKey: FileWatch] = [:]
        var snapshot: [DescriptorKey: DescriptorState] = [:]
        var sweepTimer: DispatchSourceTimer?
        var started = false
    }

    /// Per-descriptor watch state: the open fd, its `DispatchSource`, and the debounce timer.
    private final class FileWatch {
        var fd: Int32 = -1
        var source: DispatchSourceFileSystemObject?
        var debounceTimer: DispatchSourceTimer?
        var lastGoodInfo: ClaudeSessionInfo?
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

    public init(
        configDirs: [String],
        liveness: any ProcessLiveness = SystemProcessLiveness(),
        debounce: Duration = .milliseconds(100),
        sweepInterval: Duration = .seconds(5),
        onEvent: @escaping @Sendable (DescriptorEvent) -> Void
    ) {
        self.liveness = liveness
        self.debounce = debounce
        self.sweepInterval = sweepInterval
        self.onEvent = onEvent
        self.storage = Mutex(Storage(configDirs: configDirs))
    }

    deinit {
        storage.withLock { s in
            for (_, watch) in s.files { watch.cancel() }
            for (_, source) in s.dirSources { source.cancel() }
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
                for (_, source) in s.dirSources { source.cancel() }
                s.dirSources.removeAll()
                s.sweepTimer?.cancel()
                s.sweepTimer = nil
            }
        }
    }

    public func snapshot() -> [DescriptorKey: DescriptorState] {
        storage.withLock { $0.snapshot }
    }

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
        s.dirSources[configDir]?.cancel()
        s.dirSources[configDir] = nil
        for key in s.files.keys where key.configDir == configDir {
            s.files[key]?.cancel()
            s.files[key] = nil
            s.snapshot[key] = nil
        }
        return []
    }

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

    /// Lists `<configDir>/sessions`, opening watches for any new descriptor files and dropping
    /// watches for ones that vanished (the directory source doesn't tell us *which* file changed).
    private func scanConfigDir(_ configDir: String, _ s: inout Storage) -> [DescriptorEvent] {
        guard s.configDirs.contains(configDir) else { return [] }
        let dir = sessionsDir(for: configDir)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []

        var events: [DescriptorEvent] = []
        var seenPids = Set<pid_t>()
        for name in entries {
            guard name.hasSuffix(".json") else { continue }
            let base = String(name.dropLast(".json".count))
            guard !base.isEmpty, base.allSatisfy({ $0.isNumber }), let pid = pid_t(base) else { continue }
            seenPids.insert(pid)
            let key = DescriptorKey(configDir: configDir, pid: pid)
            if s.files[key] == nil {
                let watch = FileWatch(path: (dir as NSString).appendingPathComponent(name))
                s.files[key] = watch
                openFileSource(for: key, watch: watch, &s)
                if let event = readAndApply(key: key, watch: watch, &s) { events.append(event) }
            }
        }

        // Any watched file whose pid is no longer present (deleted, and we missed the per-file
        // .delete event, e.g. because the source hadn't opened yet) is dropped too.
        for key in s.files.keys where key.configDir == configDir && !seenPids.contains(key.pid) {
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
        return readAndApply(key: key, watch: watch, &s)
    }

    private func readAndApply(key: DescriptorKey, watch: FileWatch, _ s: inout Storage) -> DescriptorEvent? {
        guard let data = FileManager.default.contents(atPath: watch.path) else { return nil }
        guard let info = try? ClaudeSessionInfo.decode(data, configDir: key.configDir) else {
            // Torn write: keep the previous value, emit nothing.
            return nil
        }
        watch.lastGoodInfo = info
        return applyUpdate(key: key, info: info, &s)
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
        for dir in s.configDirs where s.dirSources[dir] == nil {
            openDirSource(for: dir, &s)
            events += scanConfigDir(dir, &s)
        }
        for (key, current) in s.snapshot {
            let alive = liveness.isAlive(pid: current.info.pid, startedAt: current.info.startedAt)
            guard alive != current.alive else { continue }
            var updated = current
            updated.alive = alive
            updated.lastSeenAt = Date()
            s.snapshot[key] = updated
            events.append(.updated(current.info, alive: alive))
        }
        return events
    }

    // MARK: - Helpers

    private static func inode(ofFD fd: Int32) -> ino_t? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return st.st_ino
    }

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
