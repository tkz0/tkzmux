// FSEventsWatcher — the trigger half of M4.1 (TKZ-26).
//
// design.md → *Git integration*: "one `FSEventStream` per repoRoot (common-dir + session cwds;
// ignore `.git/objects`, `node_modules`), 300 ms debounce". This type is only the stream: it knows
// nothing about git, it hands `GitStatusService` a filtered list of changed paths on a queue the
// service owns, and the service decides which sessions that touches and when to actually run git.
//
// Watching the *common dir* rather than only the checkouts is what makes a `git commit` or a
// `git switch` in a sibling worktree show up: refs, HEAD and the index all live there, and file
// events under a worktree's own directory would miss a commit that changed nothing on disk.
//
// The ignore list is not an optimisation, it is a correctness requirement. `.git/objects` churns
// on every fetch and every commit with hundreds of events, `node_modules` churns on every install,
// and `index.lock` is written by *our own* refresh — without dropping it a refresh would schedule
// the next refresh and the repo would never go quiet.

import CoreServices
import Dispatch
import Foundation
import Synchronization

/// One `FSEventStream` over a changing set of directories, delivering filtered paths on `queue`.
///
/// `Sendable` the same way `ClaudeSessionWatcher` is: all mutable state lives behind a `Mutex`, and
/// the stream itself is only ever created, started and invalidated while that lock is held. The C
/// callback reaches back through `FSEventStreamContext.info` (an unretained pointer to `self` —
/// the owner outlives the stream, and `stop()`/`deinit` invalidate it before that stops being true).
public final class FSEventsWatcher: Sendable {
    private let queue: DispatchQueue
    private let latency: CFTimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let storage: Mutex<Storage>

    private struct Storage {
        var paths: [String] = []
        var stream: FSEventStreamRef?
        var started = false
    }

    /// - Parameters:
    ///   - queue: the private serial queue the stream (and therefore `onChange`) runs on. The
    ///     service passes its per-repo queue so a filesystem event and a refresh cannot interleave.
    ///   - latency: `FSEventStreamCreate`'s coalescing window; design.md's 0.3 s.
    public init(
        queue: DispatchQueue,
        latency: CFTimeInterval = 0.3,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.queue = queue
        self.latency = latency
        self.onChange = onChange
        self.storage = Mutex(Storage())
    }

    deinit {
        storage.withLock { s in Self.teardown(&s) }
    }

    // MARK: - Lifecycle

    /// Idempotent. A watcher with no paths yet simply has no stream until `setPaths` gives it some.
    public func start() {
        storage.withLock { s in
            guard !s.started else { return }
            s.started = true
            rebuild(&s)
        }
    }

    /// Idempotent. Invalidates the stream; `start()` recreates it from the current paths.
    public func stop() {
        storage.withLock { s in
            s.started = false
            Self.teardown(&s)
        }
    }

    /// Replaces the watched set. A no-op when the set is unchanged; otherwise the stream is torn
    /// down and rebuilt, which is what `ClaudeSessionWatcher` does for config dirs and is far
    /// simpler than trying to mutate a live stream's path list (FSEvents has no such API).
    public func setPaths(_ paths: [String]) {
        let wanted = Self.normalize(paths)
        storage.withLock { s in
            guard s.paths != wanted else { return }
            s.paths = wanted
            guard s.started else { return }
            rebuild(&s)
        }
    }

    /// The paths currently watched, deduplicated and sorted. For tests and diagnostics.
    public var watchedPaths: [String] { storage.withLock { $0.paths } }

    // MARK: - Filtering

    /// Paths whose changes must never trigger a refresh.
    ///
    /// `index.lock` is matched by basename rather than by the literal `.git/index.lock`, because a
    /// linked worktree's index lives at `<main>/.git/worktrees/<name>/index.lock` and that spelling
    /// would slip through — and it is exactly our own refresh that writes it.
    public static func isIgnored(_ path: String) -> Bool {
        if path.contains("/.git/objects/") { return true }
        if path.contains("/node_modules/") || path.hasSuffix("/node_modules") { return true }
        if (path as NSString).lastPathComponent == "index.lock" { return true }
        return false
    }

    // MARK: - Stream plumbing (called only while `storage` is locked)

    private func rebuild(_ s: inout Storage) {
        Self.teardown(&s)
        guard s.started, !s.paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            // Without `kFSEventStreamCreateFlagUseCFTypes` (we do not pass it) `eventPaths` is a
            // plain `char **`, not a CFArray — the `unsafeBitCast(_:to: NSArray.self)` seen in older
            // samples is a latent crash.
            let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var paths: [String] = []
            paths.reserveCapacity(numEvents)
            for index in 0..<numEvents {
                guard let cPath = cPaths[index] else { continue }
                paths.append(String(cString: cPath))
            }
            watcher.deliver(paths)
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)

        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                s.paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags)
        else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        s.stream = stream
    }

    private static func teardown(_ s: inout Storage) {
        guard let stream = s.stream else { return }
        s.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Runs on `queue` (FSEvents was handed it), so `onChange` does too.
    private func deliver(_ paths: [String]) {
        let interesting = paths.filter { !Self.isIgnored($0) }
        guard !interesting.isEmpty else { return }
        onChange(interesting)
    }

    private static func normalize(_ paths: [String]) -> [String] {
        Array(Set(paths.filter { !$0.isEmpty })).sorted()
    }
}
