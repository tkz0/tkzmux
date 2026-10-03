// The Linux repo watcher (WOR-306 S4): inotify delivery, the pruned and shared watch set, a real
// kernel queue overflow, and the service end to end over it — refresh latency, the watch budget of
// a 50k-directory node_modules, and writes there that must not refresh.
//
// Unlike FSEvents (see GitStatusServiceTests' header), inotify delivers promptly and the watcher's
// coalescing is bounded, so these wait on deliveries with a timeout instead of avoiding them.

#if os(Linux)
import Foundation
import Glibc
import Synchronization
import Testing
import TkzCore

@testable import GitStatus

/// Everything `onChange` delivered, in order.
private final class PathRecorder: Sendable {
    private let storage = Mutex<[[String]]>([])

    func record(_ paths: [String]) { storage.withLock { $0.append(paths) } }

    var batches: [[String]] { storage.withLock { $0 } }
    var all: Set<String> { Set(batches.joined()) }
    func clear() { storage.withLock { $0.removeAll() } }
}

/// A temp directory tree, deleted at the end of the test.
private struct Tree {
    let root: String

    init() {
        root = RepoInfo.resolve(NSTemporaryDirectory()) + "/tkzmux-repowatch-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    func destroy() { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String { root + "/" + relative }

    func mkdir(_ relative: String) {
        try? FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    /// A plain open/write/close, so the kernel reports IN_CREATE, IN_MODIFY and IN_CLOSE_WRITE.
    func write(_ relative: String, _ text: String = "x") {
        let fd = open(path(relative), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        _ = text.withCString { Glibc.write(fd, $0, strlen($0)) }
        close(fd)
    }
}

private func makeWatcher(
    _ hub: InotifyWatchHub, _ recorder: PathRecorder, latency: Double = 0.3
) -> InotifyRepoWatcher {
    InotifyRepoWatcher(
        queue: DispatchQueue(label: "test.repo"), latency: latency, hub: hub
    ) { paths in recorder.record(paths) }
}

@Suite(.serialized) struct RepoWatcherTests {
    // MARK: - The watcher

    @Test func aWriteIsReportedAndANewDirectoryIsWatched() {
        let tree = Tree()
        defer { tree.destroy() }
        tree.mkdir("src")
        let hub = InotifyWatchHub()
        let recorder = PathRecorder()
        let watcher = makeWatcher(hub, recorder, latency: 0.05)
        watcher.setPaths([tree.root])
        watcher.start()
        #expect(watcher.watchedDirectories == [tree.root, tree.path("src")])

        tree.write("src/a.swift")
        #expect(TKZ26Fixture.waitUntil { recorder.all.contains(tree.path("src/a.swift")) })

        // Created after start: watched as it appears, and reported itself (its first entries may
        // predate the watch, and the refresh this triggers covers them).
        tree.mkdir("new/deeper")
        #expect(TKZ26Fixture.waitUntil { recorder.all.contains(tree.path("new")) })
        #expect(TKZ26Fixture.waitUntil {
            watcher.watchedDirectories.isSuperset(of: [tree.path("new"), tree.path("new/deeper")])
        })
        tree.write("new/deeper/b.txt")
        #expect(TKZ26Fixture.waitUntil { recorder.all.contains(tree.path("new/deeper/b.txt")) })

        watcher.stop()
        #expect(watcher.watchedDirectories.isEmpty)
        #expect(hub.watchCount == 0)
    }

    @Test func aBurstIsCoalescedAndTheFirstChangeIsNotDeferred() {
        let tree = Tree()
        defer { tree.destroy() }
        let hub = InotifyWatchHub()
        let recorder = PathRecorder()
        let watcher = makeWatcher(hub, recorder, latency: 0.3)
        watcher.setPaths([tree.root])
        watcher.start()

        let clock = ContinuousClock()
        let start = clock.now
        tree.write("first")
        #expect(TKZ26Fixture.waitUntil { !recorder.batches.isEmpty })
        // NoDefer: the first change after a quiet window is not held for the window.
        #expect(clock.now - start < .milliseconds(150))

        for index in 0..<200 { tree.write("burst-\(index % 20)") }
        #expect(TKZ26Fixture.waitUntil { recorder.all.contains(tree.path("burst-19")) })
        usleep(400_000)
        // The 200 writes (600 events) arrive in very few batches, each path once per batch.
        #expect(recorder.batches.count <= 4)
        for batch in recorder.batches { #expect(Set(batch).count == batch.count) }
    }

    @Test func prunedDirectoriesAreNeitherWatchedNorReported() {
        let tree = Tree()
        defer { tree.destroy() }
        tree.mkdir(".git/objects/ab")
        tree.mkdir(".git/refs/heads")
        tree.mkdir("node_modules/left-pad/lib")
        tree.mkdir("web/.next/cache")
        let hub = InotifyWatchHub()
        let recorder = PathRecorder()
        let watcher = makeWatcher(hub, recorder, latency: 0.05)
        watcher.setPaths([tree.root, tree.path(".git")])
        watcher.start()

        #expect(watcher.watchedDirectories == [
            tree.root, tree.path(".git"), tree.path(".git/refs"), tree.path(".git/refs/heads"),
            tree.path("web"),
        ])
        tree.write(".git/objects/ab/cdef")
        tree.write("node_modules/left-pad/lib/index.js")
        tree.write(".git/index.lock")
        tree.mkdir("pkg/__pycache__")
        tree.write("pkg/__pycache__/mod.pyc")
        tree.write(".git/HEAD")
        #expect(TKZ26Fixture.waitUntil { recorder.all.contains(tree.path(".git/HEAD")) })
        usleep(200_000)
        let reported = recorder.all
        #expect(!reported.contains { WatchPolicy.isIgnored($0) }, "\(reported)")
        #expect(!watcher.watchedDirectories.contains(tree.path("pkg/__pycache__")))
    }

    @Test func aRenamedDirectoryReleasesItsSubtreeAndIsWatchedAtItsNewPath() {
        let tree = Tree()
        defer { tree.destroy() }
        tree.mkdir("a/b/c")
        let hub = InotifyWatchHub()
        let recorder = PathRecorder()
        let watcher = makeWatcher(hub, recorder, latency: 0.05)
        watcher.setPaths([tree.root])
        watcher.start()
        #expect(watcher.watchedDirectories.count == 4)

        #expect(rename(tree.path("a"), tree.path("z")) == 0)
        let renamed: Set<String> = [tree.root, tree.path("z"), tree.path("z/b"), tree.path("z/b/c")]
        #expect(TKZ26Fixture.waitUntil { watcher.watchedDirectories == renamed })
        #expect(hub.watchCount == 4)
        #expect(TKZ26Fixture.waitUntil { recorder.all.isSuperset(of: [tree.path("a"), tree.path("z")]) })

        // Events under the new name carry the new name, never the old one.
        recorder.clear()
        tree.write("z/b/c/file")
        #expect(TKZ26Fixture.waitUntil { recorder.all.contains(tree.path("z/b/c/file")) })
        #expect(!recorder.all.contains { $0.hasPrefix(tree.path("a/")) })

        try? FileManager.default.removeItem(atPath: tree.path("z"))
        #expect(TKZ26Fixture.waitUntil { watcher.watchedDirectories == [tree.root] })
        #expect(TKZ26Fixture.waitUntil { hub.watchCount == 1 })
    }

    @Test func setPathsAddsAndReleasesOnlyTheDifference() {
        let tree = Tree()
        defer { tree.destroy() }
        tree.mkdir("one/x")
        tree.mkdir("two/y")
        let hub = InotifyWatchHub()
        let recorder = PathRecorder()
        let watcher = makeWatcher(hub, recorder)
        watcher.setPaths([tree.path("one")])
        #expect(watcher.watchedDirectories.isEmpty)  // not started
        watcher.start()
        #expect(watcher.watchedDirectories == [tree.path("one"), tree.path("one/x")])

        watcher.setPaths([tree.path("one"), tree.path("two")])
        #expect(watcher.watchedDirectories.count == 4)
        watcher.setPaths([tree.path("two")])
        #expect(watcher.watchedDirectories == [tree.path("two"), tree.path("two/y")])
        #expect(hub.watchCount == 2)
    }

    /// One inotify instance per service: two repo watchers over overlapping trees (a submodule in
    /// a tracked checkout) share the overlapping watches, and keep them until both let go.
    @Test func watchersOfOneHubShareOverlappingWatches() {
        let tree = Tree()
        defer { tree.destroy() }
        tree.mkdir("sub/inner")
        let hub = InotifyWatchHub()
        let outer = PathRecorder()
        let inner = PathRecorder()
        let outerWatcher = makeWatcher(hub, outer, latency: 0.05)
        let innerWatcher = makeWatcher(hub, inner, latency: 0.05)
        outerWatcher.setPaths([tree.root])
        innerWatcher.setPaths([tree.path("sub")])
        outerWatcher.start()
        innerWatcher.start()
        #expect(hub.watchCount == 3)

        tree.write("sub/inner/f")
        #expect(TKZ26Fixture.waitUntil { outer.all.contains(tree.path("sub/inner/f")) })
        #expect(TKZ26Fixture.waitUntil { inner.all.contains(tree.path("sub/inner/f")) })

        outerWatcher.stop()
        #expect(hub.watchCount == 2)
        tree.write("sub/inner/g")
        #expect(TKZ26Fixture.waitUntil { inner.all.contains(tree.path("sub/inner/g")) })
        #expect(!outer.all.contains(tree.path("sub/inner/g")))
    }

    /// A real IN_Q_OVERFLOW: the hub's queue is suspended while more events than
    /// `fs.inotify.max_queued_events` (16384 by default) pile up, then a directory is created whose
    /// IN_CREATE the kernel drops. Only the overflow path can find it: it re-walks the roots and
    /// reports them all.
    @Test func aKernelQueueOverflowReWalksAndReportsTheRoots() throws {
        let limit = (try? String(contentsOfFile: "/proc/sys/fs/inotify/max_queued_events", encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 16384
        try #require(limit <= 100_000, "max_queued_events is \(limit); overflowing it would take too long")

        let tree = Tree()
        defer { tree.destroy() }
        tree.mkdir("flood")
        let queue = DispatchQueue(label: "test.inotify")
        let hub = InotifyWatchHub(queue: queue)
        let recorder = PathRecorder()
        let watcher = makeWatcher(hub, recorder, latency: 0.05)
        watcher.setPaths([tree.root])
        watcher.start()

        queue.suspend()
        // Each new file is IN_CREATE, IN_MODIFY and IN_CLOSE_WRITE: three events, none merged.
        for index in 0...(limit / 3 + 100) { tree.write("flood/\(index)") }
        tree.mkdir("late/inner")
        queue.resume()

        #expect(TKZ26Fixture.waitUntil(10) {
            watcher.watchedDirectories.isSuperset(of: [tree.path("late"), tree.path("late/inner")])
        })
        #expect(TKZ26Fixture.waitUntil { recorder.all.contains(tree.root) })
        tree.write("late/inner/f")
        #expect(TKZ26Fixture.waitUntil { recorder.all.contains(tree.path("late/inner/f")) })
    }

    /// The IN_IGNORED of a watch can be among the events an overflow drops: a watched directory
    /// deleted and made again at the same path while the queue is full leaves a dead watch on the
    /// old inode under the same path. The overflow must replace it, not trust it.
    @Test func aDirectoryRecreatedDuringAnOverflowIsWatchedAgain() throws {
        let limit = (try? String(contentsOfFile: "/proc/sys/fs/inotify/max_queued_events", encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 16384
        try #require(limit <= 100_000, "max_queued_events is \(limit); overflowing it would take too long")

        let tree = Tree()
        defer { tree.destroy() }
        tree.mkdir("flood")
        tree.mkdir("kept/inner")
        let queue = DispatchQueue(label: "test.inotify")
        let hub = InotifyWatchHub(queue: queue)
        let recorder = PathRecorder()
        let watcher = makeWatcher(hub, recorder, latency: 0.05)
        watcher.setPaths([tree.root])
        watcher.start()
        #expect(hub.watchCount == 4)

        queue.suspend()
        for index in 0...(limit / 3 + 100) { tree.write("flood/\(index)") }
        try FileManager.default.removeItem(atPath: tree.path("kept"))
        tree.mkdir("kept/inner")
        queue.resume()

        #expect(TKZ26Fixture.waitUntil(10) { recorder.all.contains(tree.root) })
        recorder.clear()
        tree.write("kept/inner/f")
        #expect(TKZ26Fixture.waitUntil { recorder.all.contains(tree.path("kept/inner/f")) })
        #expect(TKZ26Fixture.waitUntil { hub.watchCount == 4 })
    }

    /// A refresh must not schedule the next one: the git calls a refresh makes write nothing the
    /// watcher reports, or a watched repo would never go quiet.
    @Test func aRefreshIsNotItselfAChange() throws {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        fixture.write("v0\n", to: checkout + "/tracked.txt")
        fixture.git(["add", "tracked.txt"], in: checkout)
        fixture.git(["commit", "-m", "tracked"], in: checkout)
        fixture.write("v1\n", to: checkout + "/tracked.txt")  // dirty, so status has work to do
        let info = try #require(RepoInfo.detect(cwd: checkout))

        let hub = InotifyWatchHub()
        let recorder = PathRecorder()
        let watcher = makeWatcher(hub, recorder, latency: 0.05)
        watcher.setPaths([checkout, info.commonDir])
        watcher.start()
        usleep(100_000)
        recorder.clear()

        for _ in 0..<3 {
            let base = BaseBranch.resolve(in: checkout, gitPath: GitProcess.gitPath)
            _ = GitStatusService.compute(directory: checkout, info: info, base: base, gitPath: GitProcess.gitPath)
        }
        usleep(300_000)
        #expect(recorder.batches.isEmpty, "\(recorder.all)")
    }

    // MARK: - The service over it

    /// A tracked write refreshes the row within 400 ms: the watcher delivers the first change at
    /// once (NoDefer), the service's 300 ms debounce runs, then `git status` and `git diff`.
    @Test func statusRefreshesWithin400MillisecondsOfATrackedWrite() throws {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        fixture.write("v0\n", to: checkout + "/tracked.txt")
        fixture.git(["add", "tracked.txt"], in: checkout)
        fixture.git(["commit", "-m", "tracked"], in: checkout)

        let recorder = TKZ26Recorder()
        let service = GitStatusService(minimumInterval: .milliseconds(50)) { id, summary in
            recorder.record(id, summary)
        }
        service.start()
        let id = SessionID.generate()
        service.track(id, directory: checkout)
        try #require(TKZ26Fixture.waitUntil { recorder.count == 1 })

        let clock = ContinuousClock()
        var latencies: [Duration] = []
        for round in 1...3 {
            usleep(500_000)  // past the watcher's window and the service's floor: a cold write.
            let before = recorder.count
            let start = clock.now
            fixture.write("v\(round)\n" + String(repeating: "line\n", count: round), to: checkout + "/tracked.txt")
            try #require(TKZ26Fixture.waitUntil { recorder.count > before })
            latencies.append(clock.now - start)
        }
        #expect(recorder.lastSummary?.changedFiles == 1)
        #expect(latencies.allSatisfy { $0 < .milliseconds(400) }, "\(latencies)")
    }

    /// The budget case: a 50k-directory node_modules (not even gitignored) costs no watches below
    /// it, and 10k writes there — one of them to a tracked file, which a refresh would report —
    /// never refresh the row. A tracked write outside it afterwards still does.
    @Test func a50kDirectoryNodeModulesCostsNoWatchesAndItsWritesNoRefresh() throws {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let modules = checkout + "/node_modules"
        // mkdir(2) directly: FileManager is several times slower for 50k directories.
        Glibc.mkdir(modules, 0o755)
        for package in 0..<250 {
            Glibc.mkdir("\(modules)/p\(package)", 0o755)
            for directory in 0..<200 { Glibc.mkdir("\(modules)/p\(package)/d\(directory)", 0o755) }
        }
        fixture.write("module.exports = 1\n", to: modules + "/p0/index.js")
        fixture.write("v0\n", to: checkout + "/tracked.txt")
        fixture.git(["add", "-f", "node_modules/p0/index.js", "tracked.txt"], in: checkout)
        fixture.git(["commit", "-m", "deps"], in: checkout)

        let recorder = TKZ26Recorder()
        let service = GitStatusService(
            debounce: .milliseconds(50), minimumInterval: .milliseconds(50)
        ) { id, summary in recorder.record(id, summary) }
        service.start()
        let id = SessionID.generate()
        service.track(id, directory: checkout)
        try #require(TKZ26Fixture.waitUntil(10) { recorder.count == 1 })

        #expect(service.watchCountForTesting < 2_000, "\(service.watchCountForTesting) watches")

        fixture.write("module.exports = 2\n", to: modules + "/p0/index.js")
        for index in 0..<10_000 {
            let fd = open("\(modules)/p\(index % 250)/d\(index % 200)/f\(index)", O_WRONLY | O_CREAT, 0o644)
            if fd >= 0 { close(fd) }
        }
        usleep(1_000_000)
        #expect(recorder.count == 1, "a write under node_modules refreshed the row")

        fixture.write("v1\n", to: checkout + "/tracked.txt")
        #expect(TKZ26Fixture.waitUntil { recorder.count == 2 })
        // That refresh sees both edits: the one in node_modules was never lost, only not a trigger.
        #expect(recorder.lastSummary?.changedFiles == 2)
    }
}
#endif
