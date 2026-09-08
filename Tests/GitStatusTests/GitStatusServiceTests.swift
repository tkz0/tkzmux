// End-to-end tests over real temporary repos, plus the shared fixture used by `RepoInfoTests`.
//
// Deliberately *not* tested here: FSEvents delivery. macOS coalesces filesystem events on its own
// schedule (the 0.3 s latency is a floor, not a bound), so an assertion that waits for a stream
// callback is a flake generator. Everything below drives the service through `refreshAllForTesting`
// or an explicit `refresh`/`refreshIfStale`, with the debounce injected at 60 s so the automatic
// refresh armed by `track` can never fire mid-test and make a callback count ambiguous.

import Foundation
import Synchronization
import Testing
import TkzCore

@testable import GitStatus

// MARK: - Fixture

/// A temp directory holding real git repos. Names are prefixed with the ticket so nothing here can
/// collide with the other M4.1 test files in this module.
final class TKZ26Fixture: Sendable {
    let root: String

    /// `realpath`-resolved, because `NSTemporaryDirectory()` hands back `/var/folders/…` while git
    /// (which resolves via `getcwd`) prints `/private/var/folders/…` for the same directory.
    init() {
        let base = RepoInfo.resolve(NSTemporaryDirectory())
        root = (base as NSString).appendingPathComponent("tkz26-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    func destroy() {
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }

    /// Every knob that could make `git` hang or refuse in someone else's environment: identity is
    /// supplied, signing is off (a global `commit.gpgsign = true` would block on pinentry), and the
    /// user's own config files are out of the picture.
    private static let config = [
        "-c", "user.name=tkzmux test",
        "-c", "user.email=test@example.invalid",
        "-c", "commit.gpgsign=false",
        "-c", "tag.gpgsign=false",
        "-c", "init.defaultBranch=main",
    ]

    @discardableResult
    func git(_ arguments: [String], in directory: String) -> GitProcess.Output {
        let output = try? GitProcess.run(
            GitProcess.gitPath, Self.config + arguments,
            currentDirectory: directory,
            environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"],
            timeout: 20)
        return output ?? GitProcess.Output(status: -1, standardOutput: "", standardError: "launch failed")
    }

    /// A checkout with one empty commit on an explicitly named `main` — never the ambient default.
    func makeCheckout(_ name: String = "checkout") -> String {
        let directory = path(name)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: directory)
        git(["commit", "--allow-empty", "-m", "root"], in: directory)
        return directory
    }

    func addWorktree(_ name: String, of checkout: String, branch: String) -> String {
        let directory = path(name)
        git(["worktree", "add", "-b", branch, directory], in: checkout)
        return directory
    }

    func makePlainDirectory(_ name: String) -> String {
        let directory = path(name)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    func write(_ text: String, to file: String) {
        try? text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// Polls rather than sleeps: the asynchronous paths (`refresh`, `refreshIfStale`,
    /// `setPullRequest`) settle in milliseconds, so this returns almost immediately in the happy
    /// case and only spends the full timeout when the test is genuinely failing.
    static func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }

    /// For the negative assertions ("nothing was posted"), where there is no condition to poll.
    static func settle() { usleep(200_000) }
}

struct TKZ26Post {
    var id: SessionID
    var summary: GitSummary?
}

/// `onSummary` is `@Sendable` and arrives on a service queue, so the recorder is a `Mutex` too.
final class TKZ26Recorder: Sendable {
    private let storage = Mutex<[TKZ26Post]>([])

    func record(_ id: SessionID, _ summary: GitSummary?) {
        storage.withLock { $0.append(TKZ26Post(id: id, summary: summary)) }
    }

    var posts: [TKZ26Post] { storage.withLock { $0 } }
    var count: Int { storage.withLock { $0.count } }
    var last: TKZ26Post? { storage.withLock { $0.last } }
    var lastSummary: GitSummary? { storage.withLock { $0.last?.summary } }
}

private func makeService(_ recorder: TKZ26Recorder) -> GitStatusService {
    GitStatusService(debounce: .seconds(60), minimumInterval: .seconds(60)) { id, summary in
        recorder.record(id, summary)
    }
}

// Serialized: every test here launches `git` and blocks its thread until the process exits, and
// Swift Testing runs tests in parallel by default. Twenty of those at once starve libdispatch's
// thread pool badly enough that `GitProcess`'s timeout fires and detection returns `nil` — a flake
// that has nothing to do with the code under test. Serially the whole suite is well under a second.
@Suite(.serialized) struct GitStatusServiceTests {
    // MARK: - Refresh

    @Test func refreshReportsBranchAndCleanCounts() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        let id = SessionID.generate()
        service.track(id, directory: checkout)
        service.refreshAllForTesting()

        #expect(recorder.count == 1)
        let summary = recorder.lastSummary
        #expect(summary?.branch == "main")
        #expect(summary?.upstream == nil)
        #expect(summary?.changedFiles == 0)
        #expect(summary?.untrackedFiles == 0)
        #expect(summary?.insertions == 0)
        #expect(summary?.deletions == 0)
        #expect(summary?.isWorktree == false)
        #expect(service.repoInfo(for: id)?.repoRoot == checkout)
    }

    @Test func writingAndStagingAFileMovesTheCounts() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        let id = SessionID.generate()
        service.track(id, directory: checkout)
        service.refreshAllForTesting()

        let file = (checkout as NSString).appendingPathComponent("a.txt")
        fixture.write("one\ntwo\n", to: file)
        service.refreshAllForTesting()
        #expect(recorder.lastSummary?.untrackedFiles == 1)
        #expect(recorder.lastSummary?.changedFiles == 0)

        // `diff HEAD` only sees a file once it is in the index, so the `+`/`−` chip needs the add.
        fixture.git(["add", "a.txt"], in: checkout)
        service.refreshAllForTesting()
        #expect(recorder.lastSummary?.changedFiles == 1)
        #expect(recorder.lastSummary?.untrackedFiles == 0)
        #expect(recorder.lastSummary?.insertions == 2)
        #expect(recorder.lastSummary?.deletions == 0)
    }

    @Test func committingResetsTheCounts() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        let id = SessionID.generate()
        service.track(id, directory: checkout)
        let file = (checkout as NSString).appendingPathComponent("a.txt")
        fixture.write("one\ntwo\n", to: file)
        fixture.git(["add", "a.txt"], in: checkout)
        service.refreshAllForTesting()
        #expect(recorder.lastSummary?.changedFiles == 1)

        fixture.git(["commit", "-m", "add a"], in: checkout)
        service.refreshAllForTesting()
        #expect(recorder.lastSummary?.changedFiles == 0)
        #expect(recorder.lastSummary?.untrackedFiles == 0)
        #expect(recorder.lastSummary?.insertions == 0)
        #expect(recorder.lastSummary?.deletions == 0)
        #expect(recorder.lastSummary?.branch == "main")
    }

    /// TKZ-26's last bullet: `updatedAt` moves on every refresh, so a naive `!=` would re-render the
    /// row forever. Three refreshes over an unchanged repo, exactly one callback.
    @Test func identicalRefreshesPostExactlyOnce() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        service.track(SessionID.generate(), directory: checkout)
        service.refreshAllForTesting()
        #expect(recorder.count == 1)
        service.refreshAllForTesting()
        service.refreshAllForTesting()
        #expect(recorder.count == 1)
    }

    @Test func summariesDifferingOnlyInTimestampAreEqual() {
        let base = GitSummary(branch: "main", changedFiles: 2, updatedAt: Date(timeIntervalSince1970: 0))
        var later = base
        later.updatedAt = Date(timeIntervalSince1970: 9_999)
        #expect(GitStatusService.matchesIgnoringTimestamp(base, later))
        later.changedFiles = 3
        #expect(!GitStatusService.matchesIgnoringTimestamp(base, later))
    }

    // MARK: - Worktrees

    @Test func worktreeSessionIsMarkedAsAWorktree() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addWorktree("feature-wt", of: checkout, branch: "feature")
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        let id = SessionID.generate()
        service.track(id, directory: worktree)
        service.refreshAllForTesting()

        #expect(recorder.lastSummary?.isWorktree == true)
        #expect(recorder.lastSummary?.branch == "feature")
        #expect(service.repoInfo(for: id)?.worktreeName == "feature-wt")
        // The worktree and the main checkout share one repo root, which is what makes one FSEventStream
        // per repo the right unit.
        #expect(service.repoInfo(for: id)?.repoRoot == checkout)
    }

    // MARK: - Tracking

    @Test func trackingNilUntracksAndPostsNilOnce() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        let id = SessionID.generate()
        service.track(id, directory: checkout)
        service.refreshAllForTesting()
        #expect(recorder.count == 1)

        service.track(id, directory: nil)
        #expect(TKZ26Fixture.waitUntil { recorder.count == 2 })
        #expect(recorder.last?.summary == nil)
        #expect(service.repoInfo(for: id) == nil)

        // Untracked already: a second `nil` is not a change and must not post again.
        service.track(id, directory: nil)
        TKZ26Fixture.settle()
        #expect(recorder.count == 2)
    }

    @Test func nonRepoDirectoryIsNotTracked() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let plain = fixture.makePlainDirectory("no-repo-here")
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        let id = SessionID.generate()
        service.track(id, directory: plain)
        service.refreshAllForTesting()  // drains the control queue

        #expect(recorder.count == 0)
        #expect(service.repoInfo(for: id) == nil)
    }

    @Test func retargetingASessionFollowsTheNewRepo() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let first = fixture.makeCheckout("first")
        let second = fixture.makeCheckout("second")
        fixture.git(["switch", "-c", "other"], in: second)
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        let id = SessionID.generate()
        service.track(id, directory: first)
        service.refreshAllForTesting()
        #expect(recorder.lastSummary?.branch == "main")

        service.track(id, directory: second)
        service.refreshAllForTesting()
        #expect(recorder.lastSummary?.branch == "other")
        #expect(service.repoInfo(for: id)?.repoRoot == second)
    }

    @Test func untrackStopsFurtherRefreshes() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        let id = SessionID.generate()
        service.track(id, directory: checkout)
        service.refreshAllForTesting()
        #expect(recorder.count == 1)

        service.untrack(id)
        fixture.write("x\n", to: (checkout as NSString).appendingPathComponent("b.txt"))
        service.refreshAllForTesting()
        TKZ26Fixture.settle()
        #expect(recorder.count == 1)
        #expect(service.repoInfo(for: id) == nil)
    }

    // MARK: - Explicit refresh paths

    @Test func refreshPostsAfterAChange() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        let id = SessionID.generate()
        service.track(id, directory: checkout)
        service.refreshAllForTesting()

        fixture.write("x\n", to: (checkout as NSString).appendingPathComponent("b.txt"))
        service.refresh(id)
        #expect(TKZ26Fixture.waitUntil { recorder.count == 2 })
        #expect(recorder.lastSummary?.untrackedFiles == 1)
    }

    @Test func refreshIfStaleSkipsAFreshSessionAndRunsForAnOldOne() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        let id = SessionID.generate()
        service.track(id, directory: checkout)
        service.refreshAllForTesting()
        #expect(recorder.count == 1)

        fixture.write("x\n", to: (checkout as NSString).appendingPathComponent("b.txt"))
        service.refreshIfStale(id, maxAge: 3_600)
        TKZ26Fixture.settle()
        #expect(recorder.count == 1)

        service.refreshIfStale(id, maxAge: 0)
        #expect(TKZ26Fixture.waitUntil { recorder.count == 2 })
        #expect(recorder.lastSummary?.untrackedFiles == 1)
    }

    // MARK: - Pull requests

    @Test func setPullRequestRepostsTheSummaryAndThenGoesQuiet() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        let id = SessionID.generate()
        service.track(id, directory: checkout)
        service.refreshAllForTesting()
        #expect(recorder.lastSummary?.pr == nil)

        service.setPullRequest(PRInfo(number: 7, state: "OPEN"), for: id)
        #expect(TKZ26Fixture.waitUntil { recorder.count == 2 })
        #expect(recorder.lastSummary?.pr?.number == 7)

        // Same PR again is not a change; and the next git refresh must keep the PR rather than clear it
        // (the service is the single writer of the whole value).
        service.setPullRequest(PRInfo(number: 7, state: "OPEN"), for: id)
        service.refreshAllForTesting()
        #expect(recorder.count == 2)
        #expect(service.summary(for: id)?.pr?.number == 7)
    }

    // MARK: - Lifecycle and helpers

    @Test func startAndStopAreIdempotent() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        service.start()
        service.start()
        let id = SessionID.generate()
        service.track(id, directory: checkout)
        service.refreshAllForTesting()
        #expect(recorder.count == 1)

        service.stop()
        service.stop()
        service.start()
        service.stop()
        #expect(service.repoInfo(for: id)?.repoRoot == checkout)
    }

    @Test func ignoredPathsNeverTriggerARefresh() {
        #expect(FSEventsWatcher.isIgnored("/repo/.git/objects/ab/cdef"))
        #expect(FSEventsWatcher.isIgnored("/repo/node_modules/left-pad/index.js"))
        #expect(FSEventsWatcher.isIgnored("/repo/.git/index.lock"))
        // A linked worktree's index lock does not contain the literal `.git/index.lock`.
        #expect(FSEventsWatcher.isIgnored("/repo/.git/worktrees/feature/index.lock"))
        #expect(!FSEventsWatcher.isIgnored("/repo/Sources/A.swift"))
        #expect(!FSEventsWatcher.isIgnored("/repo/.git/HEAD"))
    }

    @Test func isUnderMatchesDirectoriesNotPrefixes() {
        #expect(GitStatusService.isUnder("/a/b/c.txt", "/a/b"))
        #expect(GitStatusService.isUnder("/a/b", "/a/b"))
        #expect(!GitStatusService.isUnder("/a/bc/d.txt", "/a/b"))
    }
}
