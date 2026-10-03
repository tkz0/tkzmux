#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing

@testable import AgentBridge
import TkzCore

/// Thread-safe sink for `DescriptorEvent`s emitted on the watcher's private queue, with a polling
/// wait helper — the watcher's `onEvent` callback runs off the test's thread.
private final class EventCollector: Sendable {
    private let events = Mutex<[DescriptorEvent]>([])

    var callback: @Sendable (DescriptorEvent) -> Void {
        { [weak self] event in
            self?.events.withLock { $0.append(event) }
        }
    }

    var all: [DescriptorEvent] {
        events.withLock { $0 }
    }

    var count: Int {
        events.withLock { $0.count }
    }

    /// Polls until at least `n` events have arrived, or `timeout` elapses.
    @discardableResult
    func wait(forAtLeast n: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if count >= n { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return count >= n
    }
}

/// A liveness stub whose answer can be flipped mid-test.
private final class FakeLiveness: ProcessLiveness, Sendable {
    private let alivePids = Mutex<Set<pid_t>>([])

    func setAlive(_ pid: pid_t, _ alive: Bool) {
        alivePids.withLock { pids in
            if alive { pids.insert(pid) } else { pids.remove(pid) }
        }
    }

    func isAlive(pid: pid_t, startedAt: Date?) -> Bool {
        alivePids.withLock { $0.contains(pid) }
    }
}

/// Fixture helpers: a temp `<acct>/sessions` directory that is always cleaned up.
private struct Fixture {
    let root: URL
    let configDir: URL
    let sessionsDir: URL

    init(account: String = "acct") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkzmux-watcher-tests-\(UUID().uuidString)")
        configDir = root.appendingPathComponent(account)
        sessionsDir = configDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func descriptorPath(pid: pid_t) -> URL {
        sessionsDir.appendingPathComponent("\(pid).json")
    }

    func write(pid: pid_t, status: String = "idle", extra: String = "") {
        let json = """
            {"pid":\(pid),"sessionId":"sid-\(pid)","cwd":"/tmp","status":"\(status)"\(extra)}
            """
        try? Data(json.utf8).write(to: descriptorPath(pid: pid))
    }
}

private func inode(of url: URL) -> ino_t? {
    var st = stat()
    guard stat(url.path, &st) == 0 else { return nil }
    return st.st_ino
}

@Suite(.serialized)
struct ClaudeSessionWatcherTests {

    @Test func lifecycleCreateModifyDelete() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let collector = EventCollector()
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixture.configDir.path],
            debounce: .milliseconds(30), sweepInterval: .milliseconds(100),
            onEvent: collector.callback)
        watcher.start()
        defer { watcher.stop() }

        fixture.write(pid: 123, status: "idle")
        #expect(collector.wait(forAtLeast: 1))

        guard case .updated(let info, let alive) = collector.all[0] else {
            Issue.record("expected .updated")
            return
        }
        #expect(info.pid == 123)
        #expect(info.configDir == fixture.configDir.path)
        #expect(info.accountKey == "acct")
        #expect(info.status == .idle)
        _ = alive

        let path = fixture.descriptorPath(pid: 123)
        let inodeBefore = try #require(inode(of: path))

        // Modify in place: open the existing file, truncate, write new content — same inode.
        let fd = open(path.path, O_WRONLY | O_TRUNC)
        #expect(fd >= 0)
        let newJSON = Data("""
            {"pid":123,"sessionId":"sid-123","cwd":"/tmp","status":"busy"}
            """.utf8)
        newJSON.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)

        // The ticket's SLA: an in-place status flip must be observed within 300 ms.
        #expect(collector.wait(forAtLeast: 2, timeout: 0.3))
        let inodeAfter = try #require(inode(of: path))
        #expect(inodeBefore == inodeAfter)

        guard case .updated(let info2, _) = collector.all[1] else {
            Issue.record("expected .updated")
            return
        }
        #expect(info2.status == .busy)

        try FileManager.default.removeItem(at: path)
        #expect(collector.wait(forAtLeast: 3))
        guard case .removed(let key) = collector.all[2] else {
            Issue.record("expected .removed")
            return
        }
        #expect(key.pid == 123)
        #expect(key.configDir == fixture.configDir.path)
    }

    @Test func tornWriteKeepsPreviousValue() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let collector = EventCollector()
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixture.configDir.path],
            debounce: .milliseconds(30), sweepInterval: .milliseconds(100),
            onEvent: collector.callback)
        watcher.start()
        defer { watcher.stop() }

        fixture.write(pid: 456, status: "idle")
        #expect(collector.wait(forAtLeast: 1))
        let countAfterCreate = collector.count

        let path = fixture.descriptorPath(pid: 456)
        let full = """
            {"pid":456,"sessionId":"sid-456","cwd":"/tmp","status":"busy"}
            """
        let half = String(full.prefix(full.count / 2))
        let fd = open(path.path, O_WRONLY | O_TRUNC)
        #expect(fd >= 0)
        Data(half.utf8).withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)

        // Give the debounce window time to fire and confirm no event was emitted for the torn write.
        Thread.sleep(forTimeInterval: 0.15)
        #expect(collector.count == countAfterCreate)

        let fd2 = open(path.path, O_WRONLY | O_TRUNC)
        #expect(fd2 >= 0)
        Data(full.utf8).withUnsafeBytes { _ = write(fd2, $0.baseAddress, $0.count) }
        close(fd2)

        #expect(collector.wait(forAtLeast: countAfterCreate + 1))
        guard case .updated(let info, _) = collector.all.last else {
            Issue.record("expected .updated")
            return
        }
        #expect(info.status == .busy)
    }

    @Test func renameReplaceObservesFutureEdits() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let collector = EventCollector()
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixture.configDir.path],
            debounce: .milliseconds(30), sweepInterval: .milliseconds(100),
            onEvent: collector.callback)
        watcher.start()
        defer { watcher.stop() }

        fixture.write(pid: 789, status: "idle")
        #expect(collector.wait(forAtLeast: 1))

        let path = fixture.descriptorPath(pid: 789)
        let tmpPath = fixture.sessionsDir.appendingPathComponent("789.json.tmp")
        try Data("""
            {"pid":789,"sessionId":"sid-789","cwd":"/tmp","status":"busy"}
            """.utf8).write(to: tmpPath)
        _ = rename(tmpPath.path, path.path)

        #expect(collector.wait(forAtLeast: 2))
        guard case .updated(let info, _) = collector.all[1] else {
            Issue.record("expected .updated after rename-replace")
            return
        }
        #expect(info.status == .busy)

        // Further in-place edits on the replaced file must still be observed.
        let fd = open(path.path, O_WRONLY | O_TRUNC)
        #expect(fd >= 0)
        Data("""
            {"pid":789,"sessionId":"sid-789","cwd":"/tmp","status":"idle"}
            """.utf8).withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)

        #expect(collector.wait(forAtLeast: 3))
        guard case .updated(let info2, _) = collector.all[2] else {
            Issue.record("expected .updated after further edit")
            return
        }
        #expect(info2.status == .idle)
    }

    @Test func ignoresKeyFilesAndNonPidNames() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let collector = EventCollector()
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixture.configDir.path],
            debounce: .milliseconds(30), sweepInterval: .milliseconds(100),
            onEvent: collector.callback)
        watcher.start()
        defer { watcher.stop() }

        try Data("secret".utf8).write(to: fixture.sessionsDir.appendingPathComponent("123.abc.key"))
        try Data("{}".utf8).write(to: fixture.sessionsDir.appendingPathComponent("foo.json"))

        Thread.sleep(forTimeInterval: 0.3)
        #expect(collector.count == 0)
    }

    @Test func setConfigDirsAddsAndRemoves() throws {
        let fixtureA = try Fixture(account: "a")
        let fixtureB = try Fixture(account: "b")
        defer {
            fixtureA.cleanup()
            fixtureB.cleanup()
        }
        let collector = EventCollector()
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixtureA.configDir.path],
            debounce: .milliseconds(30), sweepInterval: .milliseconds(100),
            onEvent: collector.callback)
        watcher.start()
        defer { watcher.stop() }

        fixtureA.write(pid: 1, status: "idle")
        #expect(collector.wait(forAtLeast: 1))

        watcher.setConfigDirs([fixtureA.configDir.path, fixtureB.configDir.path])
        fixtureB.write(pid: 2, status: "idle")
        #expect(collector.wait(forAtLeast: 2))

        let countBeforeRemoval = collector.count
        watcher.setConfigDirs([fixtureA.configDir.path])
        // Removing fixtureB should stop reporting: further edits to it produce no new events.
        let fdB = open(fixtureB.descriptorPath(pid: 2).path, O_WRONLY | O_TRUNC)
        if fdB >= 0 {
            Data("""
                {"pid":2,"sessionId":"sid-2","cwd":"/tmp","status":"busy"}
                """.utf8).withUnsafeBytes { _ = write(fdB, $0.baseAddress, $0.count) }
            close(fdB)
        }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(collector.count == countBeforeRemoval)
    }

    @Test func fakeLivenessFlipsAliveState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let collector = EventCollector()
        let fake = FakeLiveness()
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixture.configDir.path], liveness: fake,
            debounce: .milliseconds(30), sweepInterval: .milliseconds(100),
            onEvent: collector.callback)
        watcher.start()
        defer { watcher.stop() }

        fixture.write(pid: 99999, status: "idle")
        #expect(collector.wait(forAtLeast: 1))
        guard case .updated(_, let alive) = collector.all[0] else {
            Issue.record("expected .updated")
            return
        }
        #expect(alive == false)

        fake.setAlive(99999, true)
        #expect(collector.wait(forAtLeast: 2, timeout: 1))
        guard case .updated(_, let alive2) = collector.all.last else {
            Issue.record("expected .updated")
            return
        }
        #expect(alive2 == true)
    }

    @Test func realProcessLivenessThroughWatcher() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let sleepPid = process.processIdentifier
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }

        let collector = EventCollector()
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixture.configDir.path],
            debounce: .milliseconds(30), sweepInterval: .milliseconds(100),
            onEvent: collector.callback)
        watcher.start()
        defer { watcher.stop() }

        let startedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        fixture.write(pid: sleepPid, status: "idle", extra: ",\"startedAt\":\(startedAtMs)")

        #expect(collector.wait(forAtLeast: 1))
        guard case .updated(_, let alive) = collector.all[0] else {
            Issue.record("expected .updated")
            return
        }
        #expect(alive == true)

        kill(sleepPid, SIGKILL)
        process.waitUntilExit()

        #expect(collector.wait(forAtLeast: 2, timeout: 1))
        guard case .updated(_, let alive2) = collector.all.last else {
            Issue.record("expected .updated")
            return
        }
        #expect(alive2 == false)
    }

    @Test func snapshotHelpersFilterAndJoin() throws {
        let interactiveInfo = ClaudeSessionInfo(
            configDir: "/tmp/x", pid: 1, sessionId: "s1", kind: .interactive, jobId: "job-1")
        let backgroundInfo = ClaudeSessionInfo(
            configDir: "/tmp/x", pid: 2, sessionId: "s2", kind: .background, parkedJobId: "job-1")
        let otherInfo = ClaudeSessionInfo(
            configDir: "/tmp/x", pid: 3, sessionId: "s3", kind: .background, parkedJobId: "job-nope")

        let now = Date()
        let snapshot: [DescriptorKey: DescriptorState] = [
            DescriptorKey(configDir: "/tmp/x", pid: 1): DescriptorState(
                info: interactiveInfo, alive: true, lastSeenAt: now),
            DescriptorKey(configDir: "/tmp/x", pid: 2): DescriptorState(
                info: backgroundInfo, alive: true, lastSeenAt: now),
            DescriptorKey(configDir: "/tmp/x", pid: 3): DescriptorState(
                info: otherInfo, alive: true, lastSeenAt: now),
        ]

        let interactiveOnly = ClaudeSessionWatcher.interactive(in: snapshot)
        #expect(interactiveOnly.count == 1)
        #expect(interactiveOnly.first?.info.pid == 1)

        let parent = ClaudeSessionWatcher.parent(ofBackground: backgroundInfo, in: snapshot)
        #expect(parent?.info.pid == 1)

        let noParent = ClaudeSessionWatcher.parent(ofBackground: otherInfo, in: snapshot)
        #expect(noParent == nil)
    }

    /// `observation` is the projection that crosses into `TkzCore`; verify the parts of it that
    /// aren't a straight field copy.
    @Test func observationProjectsTheAgentBlindHalf() {
        let base = ClaudeSessionInfo(
            configDir: "/Users/x/.claude", pid: 7, sessionId: "sid-7", kind: .interactive)

        // sessionId lands on conversationId.
        #expect(base.observation.conversationId == "sid-7")

        // A status this build doesn't recognise is "no evidence", not "idle".
        var unknownStatus = base
        unknownStatus.status = .unknown("thinking")
        #expect(unknownStatus.observation.activity == nil)

        // Known statuses still map straight across.
        var busy = base
        busy.status = .busy
        #expect(busy.observation.activity == .busy)

        // A parked job id collapses to a boolean.
        var parked = base
        parked.parkedJobId = "job-4"
        #expect(parked.observation.parked == true)
        #expect(base.observation.parked == false)

        // A derived name loses to tkzmux's own title derivation.
        var derived = base
        derived.nameSource = .derived
        #expect(derived.observation.nameIsDerived == true)
        var auto = base
        auto.nameSource = .auto
        #expect(auto.observation.nameIsDerived == false)
    }

    @Test func idleCostIsLow() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let collector = EventCollector()
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixture.configDir.path],
            debounce: .milliseconds(30), sweepInterval: .milliseconds(200),
            onEvent: collector.callback)

        for pid in 1...10 {
            fixture.write(pid: pid_t(pid), status: "idle")
        }
        watcher.start()
        defer { watcher.stop() }
        #expect(collector.wait(forAtLeast: 10))

        let before = processCPUSeconds()
        Thread.sleep(forTimeInterval: 2)
        let after = processCPUSeconds()

        // The ticket's own number is 20 ms in isolation; this process's rusage also picks up CPU
        // burned by every other suite running concurrently in `swift test`'s default parallel mode,
        // which alone measured ~90 ms of noise here. 400 ms keeps a wide margin below what a genuine
        // busy loop would burn in 2 s (close to 2000 ms on one core) while tolerating that noise.
        #expect((after - before) < 0.4)
    }

    /// A Claude Code that is SIGKILLed never deletes its `<pid>.json`, so the file — and the
    /// `O_EVTONLY` fd plus kqueue registration watching it — outlived the process forever, one set
    /// per crashed session. Retention was a function of the directory's contents, not of live
    /// sessions. A long-dead descriptor now gives its watch back while staying in the snapshot, so
    /// the row still reads as dead rather than vanishing.
    @Test("a long-dead descriptor releases its file watch but keeps its snapshot entry")
    func deadDescriptorReleasesItsWatch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let liveness = FakeLiveness()
        let collector = EventCollector()
        // `deadWatchGrace: 0` so the sweep acts at once; in the app it is 120 s.
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixture.configDir.path], liveness: liveness,
            debounce: .milliseconds(30), sweepInterval: .milliseconds(50), deadWatchGrace: 0,
            onEvent: collector.callback)

        liveness.setAlive(4242, true)
        fixture.write(pid: 4242, status: "busy")
        watcher.start()
        defer { watcher.stop() }

        #expect(collector.wait(forAtLeast: 1))
        #expect(watcher.openWatchCount == 1)

        // The process dies; the file stays on disk, as a crash leaves it.
        liveness.setAlive(4242, false)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, watcher.openWatchCount > 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(watcher.openWatchCount == 0, "the watch on a dead descriptor should be given back")

        // Still known, still reported dead — the fd is what was released, not the knowledge.
        let key = DescriptorKey(configDir: fixture.configDir.path, pid: 4242)
        let state = try #require(watcher.snapshot()[key])
        #expect(state.alive == false)
        #expect(state.info.pid == 4242)

        // And deleting the file still clears it, even with no watch left to notice.
        try FileManager.default.removeItem(at: fixture.descriptorPath(pid: 4242))
        let gone = Date().addingTimeInterval(2)
        while Date() < gone, watcher.snapshot()[key] != nil {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(watcher.snapshot()[key] == nil)
    }

    #if os(Linux)
    /// WOR-306 S2: on Linux each change to a descriptor is one inotify record (or a short burst of
    /// them) on the directory watch, and every burst must settle into exactly one event after the
    /// debounce — not one per record, and not one per watch.
    @Test("create, in-place rewrite, rename-replace and delete each yield exactly one event")
    func eachChangeYieldsExactlyOneEvent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let liveness = FakeLiveness()
        liveness.setAlive(321, true)
        let collector = EventCollector()
        let debounce = 40
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixture.configDir.path], liveness: liveness,
            debounce: .milliseconds(debounce), sweepInterval: .seconds(60),
            onEvent: collector.callback)
        watcher.start()
        defer { watcher.stop() }
        let path = fixture.descriptorPath(pid: 321)

        /// Waits for the n-th event, then for several more debounce windows, and returns how many
        /// events arrived in all.
        func settled(after n: Int) -> Int {
            #expect(collector.wait(forAtLeast: n))
            Thread.sleep(forTimeInterval: Double(debounce * 5) / 1000)
            return collector.count
        }

        // Create (not atomically: create, then write, then close — three records).
        fixture.write(pid: 321, status: "idle")
        #expect(settled(after: 1) == 1)

        // In-place rewrite: same inode, truncate and write.
        let fd = open(path.path, O_WRONLY | O_TRUNC)
        #expect(fd >= 0)
        Data(#"{"pid":321,"sessionId":"sid-321","cwd":"/tmp","status":"busy"}"#.utf8)
            .withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
        #expect(settled(after: 2) == 2)

        // Rename-replace: a temp file the filter ignores, renamed over the descriptor.
        let temporary = fixture.sessionsDir.appendingPathComponent("321.json.tmp")
        try Data(#"{"pid":321,"sessionId":"sid-321","cwd":"/tmp","status":"idle","name":"x"}"#.utf8)
            .write(to: temporary)
        #expect(rename(temporary.path, path.path) == 0)
        #expect(settled(after: 3) == 3)

        // Delete.
        try FileManager.default.removeItem(at: path)
        #expect(settled(after: 4) == 4)

        let events = collector.all
        guard events.count == 4 else { return }
        let statuses = events.prefix(3).compactMap { event -> ClaudeSessionInfo.Status? in
            if case .updated(let info, _) = event { return info.status }
            return nil
        }
        #expect(statuses == [.idle, .busy, .idle])
        guard case .removed(let key) = events[3] else {
            Issue.record("expected .removed, got \(events[3])")
            return
        }
        #expect(key.pid == 321)
    }

    /// The Linux twin of the fd-retention test: there is nothing per descriptor to retain. One
    /// inotify watch covers the `sessions` directory however many sessions it holds, alive or long
    /// dead, and the kernel agrees (`/proc/self/fdinfo` lists the watches of an inotify fd).
    @Test("one inotify watch per sessions directory, whatever the number of sessions")
    func watchCountDoesNotDependOnSessionCount() throws {
        let fixture = try Fixture()
        let other = try Fixture(account: "other")
        defer {
            fixture.cleanup()
            other.cleanup()
        }
        let liveness = FakeLiveness()
        let collector = EventCollector()
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixture.configDir.path, other.configDir.path], liveness: liveness,
            debounce: .milliseconds(20), sweepInterval: .milliseconds(50), deadWatchGrace: 0,
            onEvent: collector.callback)
        for pid in 1...3 {
            liveness.setAlive(pid_t(pid), true)
            fixture.write(pid: pid_t(pid))
        }
        watcher.start()
        defer { watcher.stop() }
        #expect(collector.wait(forAtLeast: 3))
        let sessionsInode = try #require(inode(of: fixture.sessionsDir))
        #expect(watcher.directoryWatchCount == 2)
        #expect(inotifyWatches(onInodeOf: sessionsInode) == 2)

        for pid in 4...200 {
            liveness.setAlive(pid_t(pid), true)
            fixture.write(pid: pid_t(pid))
        }
        #expect(collector.wait(forAtLeast: 200, timeout: 5))
        #expect(watcher.snapshot().count == 200)
        #expect(watcher.directoryWatchCount == 2)
        #expect(inotifyWatches(onInodeOf: sessionsInode) == 2)

        // Every process dies and leaves its file behind, as a crash does: the descriptors are
        // released (no longer tracked) but stay in the snapshot, and the watch count is unchanged.
        for pid in 1...200 { liveness.setAlive(pid_t(pid), false) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, watcher.openWatchCount > 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(watcher.openWatchCount == 0)
        #expect(watcher.snapshot().count == 200)
        #expect(watcher.directoryWatchCount == 2)
        #expect(inotifyWatches(onInodeOf: sessionsInode) == 2)

        // A rewrite of a released descriptor is not followed (as on macOS, where its watch is
        // gone), but its deletion still clears it.
        let before = collector.count
        fixture.write(pid: 7, status: "busy")
        Thread.sleep(forTimeInterval: 0.2)
        #expect(collector.count == before)
        try FileManager.default.removeItem(at: fixture.descriptorPath(pid: 7))
        let key = DescriptorKey(configDir: fixture.configDir.path, pid: 7)
        let gone = Date().addingTimeInterval(2)
        while Date() < gone, watcher.snapshot()[key] != nil {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(watcher.snapshot()[key] == nil)

        // `stop` gives the inotify instance back (its fd closes once the read source's
        // cancellation has run on the queue).
        watcher.stop()
        #expect(watcher.directoryWatchCount == 0)
        let closed = Date().addingTimeInterval(2)
        while Date() < closed, inotifyWatches(onInodeOf: sessionsInode) != nil {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(inotifyWatches(onInodeOf: sessionsInode) == nil)
    }

    /// The sessions directory going away (an account's config dir deleted) drops its descriptors,
    /// and the sweep watches it again once it is back.
    @Test func aRemovedSessionsDirectoryIsWatchedAgainWhenItReturns() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let liveness = FakeLiveness()
        liveness.setAlive(55, true)
        liveness.setAlive(56, true)
        let collector = EventCollector()
        let watcher = ClaudeSessionWatcher(
            configDirs: [fixture.configDir.path], liveness: liveness,
            debounce: .milliseconds(20), sweepInterval: .milliseconds(50),
            onEvent: collector.callback)
        fixture.write(pid: 55)
        watcher.start()
        defer { watcher.stop() }
        #expect(collector.wait(forAtLeast: 1))

        try FileManager.default.removeItem(at: fixture.sessionsDir)
        #expect(collector.wait(forAtLeast: 2))
        if case .removed(let key) = collector.all.last { #expect(key.pid == 55) } else {
            Issue.record("expected .removed")
        }

        try FileManager.default.createDirectory(at: fixture.sessionsDir, withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, watcher.directoryWatchCount == 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(watcher.directoryWatchCount == 1)
        fixture.write(pid: 56)
        #expect(collector.wait(forAtLeast: 3))
        if case .updated(let info, _) = collector.all.last { #expect(info.pid == 56) } else {
            Issue.record("expected .updated")
        }
    }
    #endif
}

#if os(Linux)
/// How many watches the inotify instance watching `inode` holds, from the `inotify wd:` lines of
/// /proc/self/fdinfo; nil when no inotify fd of this process watches it.
private func inotifyWatches(onInodeOf inode: ino_t) -> Int? {
    let hex = "ino:" + String(UInt64(inode), radix: 16) + " "
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fdinfo")) ?? []
    for entry in entries {
        guard let info = try? String(contentsOfFile: "/proc/self/fdinfo/\(entry)", encoding: .utf8)
        else { continue }
        let watches = info.split(separator: "\n").filter { $0.hasPrefix("inotify wd:") }
        if watches.contains(where: { $0.contains(hex) }) { return watches.count }
    }
    return nil
}
#endif

/// Mirrors the `proc_pid_rusage`-based CPU accounting used elsewhere in the app
/// (`Sources/TkzApp/TerminalHost.swift`); `getrusage(RUSAGE_SELF)` on Linux.
private func processCPUSeconds() -> Double {
    #if canImport(Darwin)
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    if result == 0 { return Double(info.ri_user_time + info.ri_system_time) / 1e9 }
    #endif
    var usage = rusage()
    #if canImport(Glibc)
    let who = Int32(RUSAGE_SELF.rawValue)  // a C enum in Glibc
    #else
    let who = RUSAGE_SELF
    #endif
    guard getrusage(who, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}
