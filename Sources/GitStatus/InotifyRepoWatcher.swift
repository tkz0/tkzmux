// InotifyRepoWatcher — the Linux trigger half of M4.1 (WOR-306 S4).
//
// The same job and API as `FSEventsWatcher` (start/stop/setPaths, a 0.3 s coalescing window,
// filtered paths on the repo queue), built on inotify. Three things differ from FSEvents, and the
// code is shaped by them:
//
//  * **inotify is not recursive.** One watch covers one directory's entries, so a repo is watched
//    by walking it and adding a watch per directory — after the watch is added, before the
//    directory is listed, so a subdirectory created in between is still seen. A new directory
//    (IN_CREATE or IN_MOVED_TO with IN_ISDIR) is walked and watched the same way and reported as
//    changed, which refreshes every session it touches: files created in it before its watch
//    existed are covered by that refresh. A directory renamed or deleted away releases every
//    watch below it, because a child watch would otherwise keep reporting under the old path.
//  * **Watches are a per-user kernel budget** (`fs.inotify.max_user_watches`, 524288 here, shared
//    with every editor and language server). So nothing is watched below a directory
//    `WatchPolicy.isPruned` says can never change `git status` — `node_modules`, `.build`,
//    `.git/objects` — rather than watched and filtered. When the budget is gone anyway (ENOSPC)
//    the watcher logs once and keeps what it has: the row still refreshes on Stop hooks and on the
//    selection poll, it just stops refreshing on writes in the unwatched directories.
//  * **One inotify instance per `GitStatusService`, not per repo** (`max_user_instances` is 1024
//    for the whole user). `InotifyWatchHub` owns it and routes each event to the repo watchers
//    holding that directory; two repos that share a directory (a submodule inside a tracked
//    checkout) share its watch. An IN_Q_OVERFLOW drops every watch the hub holds and tells every
//    repo watcher, which walks its roots afresh and reports them all: a full refresh, since any
//    event may be among the lost ones — an IN_IGNORED too, so a kept watch could be dead (its
//    directory deleted and made again at the same path while the queue was full).
//
// Coalescing follows `kFSEventStreamCreateFlagNoDefer`, which the macOS stream uses: the first
// change after a quiet `latency` is delivered almost at once, later ones are batched until
// `latency` has passed since the last delivery. `GitStatusService` adds its own 300 ms trailing
// debounce, so a trailing window here would put a single write 600 ms from its refresh. "Almost":
// one save is several events (an atomic write is IN_CREATE, IN_MODIFY, IN_CLOSE_WRITE and
// IN_MOVED_TO within a millisecond), and delivering the first of them alone would put the rest in
// a second batch `latency` later, which re-arms the service's debounce — 600 ms again (measured).
// So the first batch waits `settle` (20 ms) for the rest of its burst.
//
// Lock order, the same one `GitStatusService` keeps (`WatcherAction`): the service's `storage`
// is never held while a watcher is called; a repo watcher's lock may be held while it calls the
// hub; the hub's lock may be held while it calls `InotifyFileWatcher`, which calls nobody under
// its own. Events travel the other way with no lock held: the inotify queue calls the hub, which
// looks the route up, lets go, then calls the repo watcher; the repo watcher's timer lets go of
// its lock before `onChange`, which takes the service's `storage`.

#if os(Linux)
import Dispatch
import Foundation
import Glibc
import Synchronization
import TkzPlatform

/// One `InotifyFileWatcher` shared by every repo watcher of one `GitStatusService`.
///
/// The inotify instance is created on the first watch, so a service that never tracks a repo (most
/// tests, a window with no git sessions) holds no file descriptor.
final class InotifyWatchHub: Sendable {
    private static let log = TkzLogger(subsystem: "se.tkz.tkzmux", category: "git-watch")

    private let queue: DispatchQueue
    private let storage = Mutex(Storage())

    private struct Storage {
        var fileWatcher: InotifyFileWatcher?
        /// Set once creating the instance failed; never retried, logged once.
        var instanceFailed = false
        var byPath: [String: FileWatchID] = [:]
        var routes: [FileWatchID: Route] = [:]
        /// Every live repo watcher, for IN_Q_OVERFLOW.
        var owners: [ObjectIdentifier: Owner] = [:]
    }

    private struct Route {
        var directory: String
        var owners: [ObjectIdentifier: Owner]
    }

    private struct Owner {
        weak var watcher: InotifyRepoWatcher?
    }

    /// - Parameter queue: where inotify is read and repo watchers are told about changes. Tests
    ///   suspend it to make the kernel queue overflow.
    init(queue: DispatchQueue = DispatchQueue(label: "se.tkz.tkzmux.GitStatusService.inotify")) {
        self.queue = queue
    }

    deinit {
        storage.withLock { $0.fileWatcher?.cancel() }
    }

    /// Directory watches held by this hub, whoever asked for them.
    var watchCount: Int {
        storage.withLock { $0.fileWatcher?.watchCount ?? 0 }
    }

    func register(_ watcher: InotifyRepoWatcher) {
        storage.withLock { $0.owners[ObjectIdentifier(watcher)] = Owner(watcher: watcher) }
    }

    func unregister(_ id: ObjectIdentifier) {
        storage.withLock { $0.owners[id] = nil }
    }

    /// Makes `watcher` one of the holders of the watch on `directory`, adding the watch if it is
    /// the first. Under the hub's lock, so an event for a new watch cannot be routed before its
    /// route exists.
    func retain(_ directory: String, for watcher: InotifyRepoWatcher) throws(FileWatcherError) {
        let owner = ObjectIdentifier(watcher)
        try storage.withLock { s throws(FileWatcherError) in
            if let id = s.byPath[directory] {
                s.routes[id]?.owners[owner] = Owner(watcher: watcher)
                return
            }
            let fileWatcher = try instance(&s)
            let id = try fileWatcher.add(directory: directory)
            s.byPath[directory] = id
            s.routes[id] = Route(directory: directory, owners: [owner: Owner(watcher: watcher)])
        }
    }

    /// Drops `watcher` as a holder of `directory`'s watch, and the watch once nobody holds it.
    func release(_ directory: String, for watcher: ObjectIdentifier) {
        storage.withLock { s in
            guard let id = s.byPath[directory], var route = s.routes[id] else { return }
            route.owners[watcher] = nil
            guard route.owners.isEmpty else {
                s.routes[id] = route
                return
            }
            s.routes[id] = nil
            s.byPath[directory] = nil
            s.fileWatcher?.remove(id)
        }
    }

    private func instance(_ s: inout Storage) throws(FileWatcherError) -> InotifyFileWatcher {
        if let fileWatcher = s.fileWatcher { return fileWatcher }
        guard !s.instanceFailed else { throw .instanceLimitReached }
        do {
            let fileWatcher = try InotifyFileWatcher(queue: queue) { [weak self] event in
                self?.dispatch(event)
            }
            s.fileWatcher = fileWatcher
            return fileWatcher
        } catch {
            s.instanceFailed = true
            Self.log.error(
                "no inotify instance for git status (\(String(describing: error), privacy: .public)); rows refresh on hooks and polls only")
            throw error
        }
    }

    // MARK: Events (on `queue`, no lock held while a repo watcher runs)

    private func dispatch(_ event: FileWatchEvent) {
        switch event {
        case .changed(let change):
            guard let (directory, watchers) = storage.withLock({ s in
                s.routes[change.watch].map { ($0.directory, $0.owners.values.compactMap(\.watcher)) }
            }) else { return }
            for watcher in watchers { watcher.handle(change, in: directory) }
        case .watchRemoved(let id):
            guard let (directory, watchers) = storage.withLock({ s -> (String, [InotifyRepoWatcher])? in
                guard let route = s.routes.removeValue(forKey: id) else { return nil }
                s.byPath[route.directory] = nil
                return (route.directory, route.owners.values.compactMap(\.watcher))
            }) else { return }
            for watcher in watchers { watcher.watchEnded(directory) }
        case .overflow:
            Self.log.notice("inotify queue overflowed; re-walking every watched repo")
            let watchers = storage.withLock { s -> [InotifyRepoWatcher] in
                // Any watch may be dead with its IN_IGNORED among the lost events, so none is
                // kept: the re-walk adds fresh ones. Records still queued for these are stale.
                for id in s.routes.keys { s.fileWatcher?.remove(id) }
                s.routes.removeAll()
                s.byPath.removeAll()
                return s.owners.values.compactMap(\.watcher)
            }
            for watcher in watchers { watcher.overflowed() }
        }
    }
}

/// The directories of one repo, watched through an `InotifyWatchHub`, delivering filtered paths
/// on `queue`. `Sendable` the way `FSEventsWatcher` is: all mutable state, the coalescing timer
/// included, lives behind a `Mutex` and is only created and cancelled while it is held.
public final class InotifyRepoWatcher: Sendable {
    private static let log = TkzLogger(subsystem: "se.tkz.tkzmux", category: "git-watch")

    /// How long the first change after a quiet window waits for the rest of its burst.
    static let settle: Double = 0.02

    private let queue: DispatchQueue
    private let latency: Double
    private let hub: InotifyWatchHub
    private let onChange: @Sendable ([String]) -> Void
    private let storage: Mutex<Storage>

    private struct Storage {
        var roots: [String] = []
        var started = false
        /// Every directory this watcher holds a watch on.
        var directories: Set<String> = []
        /// Changed paths waiting for the coalescing timer.
        var pending: Set<String> = []
        var timer: DispatchSourceTimer?
        var lastDelivery: DispatchTime?
        /// The watch budget ran out (or there is no inotify instance); logged once.
        var degraded = false
    }

    /// - Parameters:
    ///   - queue: the repo queue; `onChange` runs there.
    ///   - latency: the coalescing window, as `FSEventsWatcher`'s; 0.3 s.
    ///   - hub: the service's shared inotify instance.
    init(
        queue: DispatchQueue,
        latency: Double = 0.3,
        hub: InotifyWatchHub,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.queue = queue
        self.latency = latency
        self.hub = hub
        self.onChange = onChange
        self.storage = Mutex(Storage())
        hub.register(self)
    }

    deinit {
        let id = ObjectIdentifier(self)
        let directories = storage.withLock { s -> Set<String> in
            s.timer?.cancel()
            s.timer = nil
            return s.directories
        }
        for directory in directories { hub.release(directory, for: id) }
        hub.unregister(id)
    }

    // MARK: - Lifecycle

    /// Idempotent. Walks and watches the current paths.
    public func start() {
        storage.withLock { s in
            guard !s.started else { return }
            s.started = true
            reconcile(&s)
        }
    }

    /// Idempotent. Releases every watch and drops anything not yet delivered.
    public func stop() {
        storage.withLock { s in
            s.started = false
            s.timer?.cancel()
            s.timer = nil
            s.pending.removeAll()
            for directory in s.directories { hub.release(directory, for: ObjectIdentifier(self)) }
            s.directories.removeAll()
        }
    }

    /// Replaces the watched roots. Unlike FSEvents, inotify can change a live watch set, so only
    /// the difference is added or released.
    public func setPaths(_ paths: [String]) {
        let wanted = Array(Set(paths.filter { !$0.isEmpty })).sorted()
        storage.withLock { s in
            guard s.roots != wanted else { return }
            s.roots = wanted
            guard s.started else { return }
            reconcile(&s)
        }
    }

    /// The directories this watcher holds a watch on. Tests.
    var watchedDirectories: Set<String> {
        storage.withLock { $0.directories }
    }

    // MARK: - Events (from the hub, on its queue)

    func handle(_ change: FileWatchChange, in directory: String) {
        storage.withLock { s in
            guard s.started, s.directories.contains(directory) else { return }
            let path = change.name.map { Self.join(directory, $0) } ?? directory
            if change.isDirectory, change.name != nil {
                switch change.kind {
                case .created:
                    walk(path, &s)
                case .removed:
                    releaseTree(path, &s)
                case .modified, .attributes:
                    break
                }
            }
            guard !WatchPolicy.isIgnored(path) else { return }
            enqueue(path, &s)
        }
    }

    /// The directory was deleted, renamed away or unmounted; inotify already dropped its watch.
    func watchEnded(_ directory: String) {
        storage.withLock { s in
            guard s.directories.remove(directory) != nil else { return }
            releaseTree(directory, &s)
            guard s.started, !WatchPolicy.isIgnored(directory) else { return }
            enqueue(directory, &s)
        }
    }

    /// Events were lost and the hub dropped every watch: walk the roots afresh, refresh everything.
    func overflowed() {
        storage.withLock { s in
            // Mostly no-ops (the hub holds none of these any more), except for a directory
            // retained again since, by a `setPaths` that ran between the hub's drop and this.
            for directory in s.directories { hub.release(directory, for: ObjectIdentifier(self)) }
            s.directories.removeAll()
            guard s.started else { return }
            reconcile(&s)
            for root in s.roots { enqueue(root, &s) }
        }
    }

    // MARK: - Watch set (called only while `storage` is locked)

    /// Watches every directory under the roots that is not watched yet, and releases the ones no
    /// root covers any more. Directories already watched are not listed again: their IN_CREATE
    /// events have kept the set below them current.
    private func reconcile(_ s: inout Storage) {
        for root in s.roots { walk(root, &s) }
        let stale = s.directories.filter { directory in
            !s.roots.contains { GitStatusService.isUnder(directory, $0) }
        }
        for directory in stale {
            s.directories.remove(directory)
            hub.release(directory, for: ObjectIdentifier(self))
        }
    }

    /// Depth-first from `root`: watch, then list, then descend, never into a pruned directory or
    /// through a symlink (FSEvents does not follow them either).
    private func walk(_ root: String, _ s: inout Storage) {
        var stack = [root]
        while let directory = stack.popLast() {
            guard !WatchPolicy.isPruned(directory: directory), !s.directories.contains(directory),
                retain(directory, &s)
            else { continue }
            Self.forEachSubdirectory(of: directory) { stack.append($0) }
        }
    }

    private func retain(_ directory: String, _ s: inout Storage) -> Bool {
        do {
            try hub.retain(directory, for: self)
            s.directories.insert(directory)
            return true
        } catch {
            switch error {
            case .watchLimitReached, .instanceLimitReached, .cancelled, .system:
                if !s.degraded {
                    s.degraded = true
                    let watched = s.directories.count
                    Self.log.error(
                        "git status stops watching new directories (\(String(describing: error), privacy: .public), \(watched) watched for this repo); raise fs.inotify.max_user_watches")
                }
            case .noSuchDirectory, .notADirectory, .permissionDenied, .alreadyWatched:
                // Gone or replaced by a file since it was listed; unreadable; or the same
                // directory under another path (a bind mount), which is watched already.
                break
            }
            return false
        }
    }

    /// Releases `directory` and every watched directory below it.
    private func releaseTree(_ directory: String, _ s: inout Storage) {
        let doomed = s.directories.filter { GitStatusService.isUnder($0, directory) }
        for path in doomed {
            s.directories.remove(path)
            hub.release(path, for: ObjectIdentifier(self))
        }
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// Calls `body` with the path of every real subdirectory (not a symlink to one) of `directory`.
    private static func forEachSubdirectory(of directory: String, _ body: (String) -> Void) {
        guard let dir = opendir(directory) else { return }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let type = entry.pointee.d_type
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let path = join(directory, name)
            switch Int(type) {
            case Int(DT_DIR):
                body(path)
            case Int(DT_UNKNOWN):
                // Some filesystems do not fill d_type; ask lstat.
                var info = stat()
                if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { body(path) }
            default:
                break
            }
        }
    }

    // MARK: - Coalescing (called only while `storage` is locked)

    private func enqueue(_ path: String, _ s: inout Storage) {
        s.pending.insert(path)
        guard s.timer == nil else { return }
        let now = DispatchTime.now()
        var deadline = now + Swift.min(Self.settle, latency)
        if let last = s.lastDelivery {
            let next = last + latency
            if next > now { deadline = next }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: deadline)
        timer.setEventHandler { [weak self] in self?.deliver() }
        s.timer = timer
        timer.resume()
    }

    /// Runs on `queue`, like FSEvents' callback, so `onChange` does too.
    private func deliver() {
        let paths = storage.withLock { s -> [String] in
            s.timer?.cancel()
            s.timer = nil
            guard s.started, !s.pending.isEmpty else { return [] }
            s.lastDelivery = DispatchTime.now()
            defer { s.pending.removeAll() }
            return s.pending.sorted()
        }
        guard !paths.isEmpty else { return }
        onChange(paths)
    }
}
#endif
