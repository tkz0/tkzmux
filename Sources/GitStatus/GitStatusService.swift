// GitStatusService — M4.1 (TKZ-26). See docs/design.md → *Git integration*.
//
// Owns the whole answer to "what does this session's repo look like right now?": repo detection per
// directory, an `FSEventStream` per repo root, a debounce/coalesce policy, the two git calls, and
// the single decision to hand a new `GitSummary` to the app.
//
// Four rules shape the code, and each of them is load-bearing:
//
//  1. **One serial queue per repo root.** All the git for one repo runs there, so "one refresh in
//     flight per repo, coalesced" is a property of the queue rather than of a flag someone has to
//     remember to check. Different repos still refresh in parallel.
//  2. **Trailing debounce, then a floor.** A burst of writes arms a 300 ms trailing timer; when it
//     fires inside `minimumInterval` of the last refresh it *re-arms for the remainder* instead of
//     dropping. Dropping would lose the last write of a burst and leave the row stale until the
//     next unrelated event.
//  3. **The Equatable rule.** `GitSummary.updatedAt` moves on every refresh, so comparing whole
//     summaries would post on every tick and re-render the row forever. The last posted value is
//     kept per session and `onSummary` fires only when something *other than* `updatedAt` differs.
//  4. **The service is the only writer of `GitSummary`.** `setPullRequest` feeds `PRInfo` in here
//     rather than the app merging it into the value afterwards, so there is exactly one place that
//     decides what the whole value is — and therefore exactly one place that can apply rule 3.
//
// Threading: `track`/`untrack`/`refresh`/`refreshIfStale`/`setPullRequest` return immediately and do
// their work on a private serial control queue (repo detection launches git, and the app calls these
// from the main actor). `onSummary` is therefore called from one of the service's queues, never the
// main one — the app hops to the main actor itself. `repoInfo(for:)` reads the storage directly, so
// it is safe to call from inside `onSummary`.

import Dispatch
import Foundation
import Synchronization
import TkzCore

/// Keeps a `GitSummary` up to date for every tracked session and posts it when it changes.
public final class GitStatusService: Sendable {
    private let debounce: Duration
    private let minimumInterval: Duration
    private let gitPath: String
    private let onSummary: @Sendable (SessionID, GitSummary?) -> Void

    /// Detection, tracking and teardown run here; it is also what `refreshAllForTesting` drains so
    /// a test that tracks and then refreshes cannot race its own `track`.
    private let controlQueue = DispatchQueue(label: "se.tkz.tkzmux.GitStatusService")
    private let storage: Mutex<Storage>

    // MARK: - State

    private struct Storage {
        var started = false
        var sessions: [SessionID: SessionState] = [:]
        /// Keyed by `RepoInfo.repoRoot` — one entry per repo, shared by all its worktrees.
        var repos: [String: RepoState] = [:]
        /// Detection is one git launch; sessions retarget often enough to be worth caching by cwd.
        var detectCache: [String: DetectResult] = [:]
    }

    private enum DetectResult {
        case repo(RepoInfo)
        /// Negative results carry a timestamp: `git init` in a directory we already looked at must
        /// not be invisible forever.
        case notARepo(at: Date)
    }

    /// Reference type on purpose (like `ClaudeSessionWatcher.FileWatch`): timers and last-posted
    /// state are mutated from inside `storage.withLock` without copying the whole map back.
    private final class SessionState {
        /// The directory as the app gave it — this is what `git -C` runs in.
        var directory: String
        /// `realpath` of `directory`, for comparing against FSEvents paths (which are resolved).
        var watchPath: String
        var info: RepoInfo
        var lastPosted: GitSummary?
        /// When the last *successful* refresh completed — the input to `refreshIfStale`.
        var lastRefreshAt: Date?
        /// When the last refresh *started* — the input to the `minimumInterval` floor.
        var lastRefreshStartedAt: Date?
        var pr: PRInfo?
        var debounceTimer: DispatchSourceTimer?
        /// Bumped whenever the session is retargeted, so a refresh whose git was still running when
        /// `track` moved the session cannot post a summary for the directory it just left.
        var generation: UInt64

        init(directory: String, watchPath: String, info: RepoInfo, generation: UInt64) {
            self.directory = directory
            self.watchPath = watchPath
            self.info = info
            self.generation = generation
        }
    }

    /// Watcher calls deferred out of the `storage` lock.
    ///
    /// `FSEventStreamInvalidate` synchronizes with the stream's dispatch queue — the repo queue —
    /// and every FSEvents path (`onRepoPaths`, and the debounce timers, which also target that
    /// queue) takes `storage`. Touching a watcher while holding `storage` would therefore invert
    /// the lock order: control queue holds `storage` and waits for the repo queue, repo queue waits
    /// for `storage`. Locked sections only ever *collect* these; the caller runs them afterwards,
    /// which leaves exactly one lock order — `storage`, then the watcher's own.
    private enum WatcherAction {
        case start(FSEventsWatcher)
        case stop(FSEventsWatcher)
        case setPaths(FSEventsWatcher, [String])

        func run() {
            switch self {
            case .start(let watcher): watcher.start()
            case .stop(let watcher): watcher.stop()
            case .setPaths(let watcher, let paths): watcher.setPaths(paths)
            }
        }
    }

    private final class RepoState {
        let queue: DispatchQueue
        var watcher: FSEventsWatcher?
        var sessions: Set<SessionID> = []

        init(queue: DispatchQueue) { self.queue = queue }
    }

    // MARK: - Init

    /// - Parameters:
    ///   - debounce: trailing debounce after a filesystem event. design.md's 300 ms.
    ///   - minimumInterval: the floor between two refreshes of one session during a burst. 2 s.
    ///   - onSummary: called on a service queue whenever a session's summary *changes*, and once
    ///     with `nil` when a tracked session stops being in a repo.
    public init(
        debounce: Duration = .milliseconds(300),
        minimumInterval: Duration = .seconds(2),
        gitPath: String = GitProcess.gitPath,
        onSummary: @escaping @Sendable (SessionID, GitSummary?) -> Void
    ) {
        self.debounce = debounce
        self.minimumInterval = minimumInterval
        self.gitPath = gitPath
        self.onSummary = onSummary
        self.storage = Mutex(Storage())
    }

    deinit {
        let actions = storage.withLock { s -> [WatcherAction] in
            for (_, state) in s.sessions {
                state.debounceTimer?.cancel()
                state.debounceTimer = nil
            }
            return s.repos.values.compactMap { $0.watcher.map(WatcherAction.stop) }
        }
        actions.forEach { $0.run() }
    }

    // MARK: - Lifecycle

    /// Idempotent. Starts the filesystem watchers for everything already tracked.
    ///
    /// Deliberately *not* hopped onto `controlQueue`: it only touches `storage`, and a `sync` hop
    /// would block the caller behind an in-flight repo detection — and deadlock outright if it were
    /// ever called from an `onSummary` callback, which runs on `controlQueue`.
    public func start() {
        let actions = storage.withLock { s -> [WatcherAction] in
            guard !s.started else { return [] }
            s.started = true
            return s.repos.values.compactMap { $0.watcher.map(WatcherAction.start) }
        }
        actions.forEach { $0.run() }
    }

    /// Idempotent. Stops every watcher and cancels every pending debounce; tracking is kept, so
    /// `start()` resumes where it left off.
    public func stop() {
        let actions = storage.withLock { s -> [WatcherAction] in
            guard s.started else { return [] }
            s.started = false
            for (_, state) in s.sessions {
                state.debounceTimer?.cancel()
                state.debounceTimer = nil
            }
            return s.repos.values.compactMap { $0.watcher.map(WatcherAction.stop) }
        }
        actions.forEach { $0.run() }
    }

    // MARK: - Tracking

    /// Track `id` at `directory`, or retarget it there.
    ///
    /// `nil` — or a directory that is not inside a git repo — untracks the session and posts `nil`
    /// once, so the row can clear its git chip. A session that was never tracked posts nothing:
    /// the app's `git` is already `nil` and a post would be a re-render for no change.
    public func track(_ id: SessionID, directory: String?) {
        controlQueue.async { [self] in applyTrack(id, directory: directory) }
    }

    public func untrack(_ id: SessionID) {
        controlQueue.async { [self] in
            let actions = storage.withLock { s -> [WatcherAction] in
                var actions: [WatcherAction] = []
                removeSession(id, &s, &actions)
                return actions
            }
            actions.forEach { $0.run() }
        }
    }

    /// Refresh now — what a `Stop` hook triggers. Ignores both the debounce and the 2 s floor.
    public func refresh(_ id: SessionID) {
        // Via `controlQueue` so a `refresh` issued immediately after `track` cannot overtake it.
        controlQueue.async { [self] in
            guard let queue = repoQueue(for: id) else { return }
            queue.async { [self] in performRefresh(id) }
        }
    }

    /// The selection rule: refresh only when the last successful refresh is older than `maxAge`.
    public func refreshIfStale(_ id: SessionID, maxAge: TimeInterval = 10) {
        controlQueue.async { [self] in
            let target = storage.withLock { s -> DispatchQueue? in
                guard let state = s.sessions[id], let repo = s.repos[state.info.repoRoot] else {
                    return nil
                }
                if let last = state.lastRefreshAt, Date().timeIntervalSince(last) < maxAge {
                    return nil
                }
                return repo.queue
            }
            target?.async { [self] in performRefresh(id) }
        }
    }

    /// Feeds PR info in. The service owns `GitSummary.pr`, so this is what makes a PR change reach
    /// the row — including when nothing in git changed.
    public func setPullRequest(_ pr: PRInfo?, for id: SessionID) {
        controlQueue.async { [self] in
            let post = storage.withLock { s -> GitSummary? in
                guard let state = s.sessions[id] else { return nil }
                guard state.pr != pr else { return nil }
                state.pr = pr
                guard var summary = state.lastPosted else { return nil }
                summary.pr = pr
                summary.updatedAt = Date()
                state.lastPosted = summary
                return summary
            }
            if let post { onSummary(id, post) }
        }
    }

    public func repoInfo(for id: SessionID) -> RepoInfo? {
        storage.withLock { $0.sessions[id]?.info }
    }

    /// The last summary handed to `onSummary`, or `nil`. Diagnostics and tests.
    public func summary(for id: SessionID) -> GitSummary? {
        storage.withLock { $0.sessions[id]?.lastPosted }
    }

    /// Test seam: refresh every tracked session synchronously, on the caller's thread. Drains the
    /// control queue first so a `track` issued a moment ago has definitely landed.
    public func refreshAllForTesting() {
        controlQueue.sync {}
        let ids = storage.withLock { Array($0.sessions.keys) }
        for id in ids { performRefresh(id) }
    }

    // MARK: - Tracking internals (control queue)

    private func applyTrack(_ id: SessionID, directory: String?) {
        guard let directory, !directory.isEmpty else {
            postNilIfWasTracked(id)
            return
        }
        // Nothing to do when the session is already pointed at this exact directory.
        let unchanged = storage.withLock { s in s.sessions[id]?.directory == directory }
        if unchanged { return }

        guard let info = detect(directory) else {
            postNilIfWasTracked(id)
            return
        }

        let actions = storage.withLock { s -> [WatcherAction] in
            var actions: [WatcherAction] = []
            let generation = (s.sessions[id]?.generation ?? 0) &+ 1
            removeSession(id, &s, &actions)
            let state = SessionState(
                directory: directory,
                watchPath: RepoInfo.resolve(directory),
                info: info,
                generation: generation)
            s.sessions[id] = state
            attach(id, to: info.repoRoot, &s, &actions)
            return actions
        }
        actions.forEach { $0.run() }
        // A freshly tracked session wants its chip filled in; the debounce is what keeps a burst of
        // retargets (a shell `cd` loop) from turning into a burst of git.
        scheduleDebounced(id)
    }

    private func postNilIfWasTracked(_ id: SessionID) {
        let result = storage.withLock { s -> (existed: Bool, actions: [WatcherAction]) in
            var actions: [WatcherAction] = []
            let existed = removeSession(id, &s, &actions)
            return (existed, actions)
        }
        result.actions.forEach { $0.run() }
        if result.existed { onSummary(id, nil) }
    }

    /// Removes the session and detaches it from its repo. Returns whether it was there.
    @discardableResult
    private func removeSession(
        _ id: SessionID, _ s: inout Storage, _ actions: inout [WatcherAction]
    ) -> Bool {
        guard let state = s.sessions[id] else { return false }
        state.debounceTimer?.cancel()
        state.debounceTimer = nil
        detach(id, from: state.info.repoRoot, &s, &actions)
        s.sessions[id] = nil
        return true
    }

    private func attach(
        _ id: SessionID, to repoRoot: String, _ s: inout Storage, _ actions: inout [WatcherAction]
    ) {
        let repo: RepoState
        if let existing = s.repos[repoRoot] {
            repo = existing
        } else {
            repo = RepoState(
                queue: DispatchQueue(label: "se.tkz.tkzmux.GitStatusService.repo"))
            let watcher = FSEventsWatcher(queue: repo.queue) { [weak self] paths in
                self?.onRepoPaths(repoRoot: repoRoot, paths: paths)
            }
            repo.watcher = watcher
            s.repos[repoRoot] = repo
            if s.started { actions.append(.start(watcher)) }
        }
        repo.sessions.insert(id)
        updateWatchPaths(repoRoot, &s, &actions)
    }

    private func detach(
        _ id: SessionID, from repoRoot: String, _ s: inout Storage, _ actions: inout [WatcherAction]
    ) {
        guard let repo = s.repos[repoRoot] else { return }
        repo.sessions.remove(id)
        guard repo.sessions.isEmpty else {
            updateWatchPaths(repoRoot, &s, &actions)
            return
        }
        if let watcher = repo.watcher { actions.append(.stop(watcher)) }
        repo.watcher = nil
        s.repos[repoRoot] = nil
    }

    /// The repo's common dir (where refs, HEAD and the index live) plus every tracked session
    /// directory under it.
    private func updateWatchPaths(
        _ repoRoot: String, _ s: inout Storage, _ actions: inout [WatcherAction]
    ) {
        guard let repo = s.repos[repoRoot], let watcher = repo.watcher else { return }
        var paths = Set<String>()
        for id in repo.sessions {
            guard let state = s.sessions[id] else { continue }
            paths.insert(state.info.commonDir)
            paths.insert(state.watchPath)
        }
        actions.append(.setPaths(watcher, Array(paths)))
    }

    private func repoQueue(for id: SessionID) -> DispatchQueue? {
        storage.withLock { s in
            guard let state = s.sessions[id] else { return nil }
            return s.repos[state.info.repoRoot]?.queue
        }
    }

    private func detect(_ directory: String) -> RepoInfo? {
        let cached = storage.withLock { s in s.detectCache[directory] }
        switch cached {
        case .repo(let info):
            return info
        case .notARepo(let at) where Date().timeIntervalSince(at) < 30:
            return nil
        default:
            break
        }
        let info = RepoInfo.detect(cwd: directory, gitPath: gitPath)
        storage.withLock { s in
            s.detectCache[directory] = info.map { DetectResult.repo($0) } ?? .notARepo(at: Date())
        }
        return info
    }

    // MARK: - Filesystem events (repo queue)

    private func onRepoPaths(repoRoot: String, paths: [String]) {
        let ids = storage.withLock { s -> [SessionID] in
            guard let repo = s.repos[repoRoot] else { return [] }
            return repo.sessions.filter { id in
                guard let state = s.sessions[id] else { return false }
                return paths.contains { path in
                    Self.isUnder(path, state.watchPath) || Self.isUnder(path, state.info.commonDir)
                }
            }
        }
        for id in ids { scheduleDebounced(id) }
    }

    static func isUnder(_ path: String, _ directory: String) -> Bool {
        path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    // MARK: - Debounce and the 2 s floor

    private func scheduleDebounced(_ id: SessionID) {
        storage.withLock { s in arm(id, after: debounce, &s) }
    }

    private func arm(_ id: SessionID, after delay: Duration, _ s: inout Storage) {
        guard let state = s.sessions[id], let repo = s.repos[state.info.repoRoot] else { return }
        state.debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: repo.queue)
        timer.schedule(deadline: .now() + delay.dispatchInterval)
        timer.setEventHandler { [weak self] in self?.onDebounceFired(id) }
        state.debounceTimer = timer
        timer.resume()
    }

    private func onDebounceFired(_ id: SessionID) {
        let shouldRefresh = storage.withLock { s -> Bool in
            guard let state = s.sessions[id] else { return false }
            state.debounceTimer = nil
            guard let started = state.lastRefreshStartedAt else { return true }
            let elapsed = Date().timeIntervalSince(started)
            let floor = minimumInterval.seconds
            guard elapsed < floor else { return true }
            // Inside the floor: re-arm for the remainder rather than dropping, so the last write of
            // a burst still gets reflected.
            arm(id, after: .milliseconds(Int(((floor - elapsed) * 1000).rounded(.up)) + 1), &s)
            return false
        }
        if shouldRefresh { performRefresh(id) }
    }

    // MARK: - The refresh itself

    /// Runs the two git calls and posts the result when it differs. Called on a repo queue (or, in
    /// `refreshAllForTesting`, on the caller's thread) — never with `storage` held, because git can
    /// take tens of milliseconds and blocking every other session on it is exactly what the
    /// per-repo queues exist to avoid.
    private func performRefresh(_ id: SessionID) {
        struct Target {
            var directory: String
            var info: RepoInfo
            var generation: UInt64
        }
        let target = storage.withLock { s -> Target? in
            guard let state = s.sessions[id] else { return nil }
            state.lastRefreshStartedAt = Date()
            state.debounceTimer?.cancel()
            state.debounceTimer = nil
            return Target(
                directory: state.directory, info: state.info, generation: state.generation)
        }
        guard let target else { return }
        guard
            let fresh = Self.computeSummary(
                directory: target.directory, info: target.info, gitPath: gitPath)
        else { return }  // git failed or the directory went away: keep the last known value.

        let post = storage.withLock { s -> GitSummary? in
            // Stale-result guard: the session may have been retargeted or untracked while git ran.
            guard let state = s.sessions[id], state.generation == target.generation,
                state.directory == target.directory
            else { return nil }
            state.lastRefreshAt = Date()
            var summary = fresh
            summary.pr = state.pr  // one writer of the whole value (rule 4).
            if let last = state.lastPosted, Self.matchesIgnoringTimestamp(last, summary) {
                return nil  // THE EQUATABLE RULE: only `updatedAt` moved, so nothing to re-render.
            }
            state.lastPosted = summary
            return summary
        }
        if let post { onSummary(id, post) }
    }

    /// `git status --porcelain=v2 --branch -z` + `git diff HEAD --shortstat`, in `directory` (the
    /// session's own, not the repo root — a worktree has its own status). `nil` only when `status`
    /// itself failed.
    static func computeSummary(directory: String, info: RepoInfo, gitPath: String) -> GitSummary? {
        guard
            let statusOutput = try? GitProcess.git(
                ["status", "--porcelain=v2", "--branch", "-z"], in: directory, gitPath: gitPath),
            statusOutput.succeeded
        else { return nil }
        let status = GitStatusParsing.parsePorcelainV2(statusOutput.standardOutput)

        // `diff HEAD` fails on an unborn HEAD (there is no HEAD to diff against). That is a normal
        // state for a fresh repo, not a reason to drop the summary — the counts are simply zero.
        //
        // Any *other* diff failure — a 5 s timeout on a stalled network mount, the directory going
        // away between the two calls — is a measurement we did not make, and reporting it as `+0
        // −38` would erase the row's real numbers with something that looks like data. So the whole
        // summary is dropped and the caller keeps the last known value.
        var insertions = 0
        var deletions = 0
        let diffOutput = try? GitProcess.git(
            ["diff", "HEAD", "--shortstat"], in: directory, gitPath: gitPath)
        if let diffOutput, diffOutput.succeeded {
            let shortstat = GitStatusParsing.parseShortstat(diffOutput.standardOutput)
            insertions = shortstat.insertions
            deletions = shortstat.deletions
        } else if !status.isUnborn {
            return nil
        }

        return GitSummary(
            branch: status.branch,
            upstream: status.upstream,
            ahead: status.ahead ?? 0,
            behind: status.behind ?? 0,
            changedFiles: status.changedFiles,
            untrackedFiles: status.untrackedFiles,
            insertions: insertions,
            deletions: deletions,
            isWorktree: info.isWorktree,
            pr: nil,
            updatedAt: Date())
    }

    /// Two summaries that differ only in `updatedAt`. The whole point of rule 3, in one function so
    /// it can be tested directly.
    static func matchesIgnoringTimestamp(_ lhs: GitSummary, _ rhs: GitSummary) -> Bool {
        var a = lhs
        var b = rhs
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
}

extension Duration {
    /// `Dispatch`'s timer APIs predate `Duration`; millisecond granularity is all this needs.
    fileprivate var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds * 1_000_000_000 + attoseconds / 1_000_000_000))
    }

    fileprivate var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
