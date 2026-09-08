// TerminalHostTests — M1.10 (TKZ-16).
//
// What these prove, in order of how much they matter:
//
//   1. **A background session costs only IO.** With 30 sessions open there is exactly one
//      `TerminalSurface`, it holds the visible session and no other, and bytes written to a
//      *background* session neither wake the display link nor allocate any render state. The
//      view-layer test (`TerminalMetalViewTests.showSwapsSurfaces`) proves the mechanism for two
//      sessions; this proves the invariant survives at the scale the ticket cares about.
//   2. **`show(_:)` really cycles the surface.** A switch is timed in the harness, so a switch that
//      was optimised away would report an implausibly good number. Every switch here is followed by
//      an offscreen frame that must report `DIRTY_FULL` — the signature of a fresh attach.
//   3. **`run` chunks on newlines**, because a tty in canonical mode truncates a line past
//      `MAX_INPUT` (~1 KiB, measured in M1.2).
//   4. **Snapshot at quit / restore at launch** round-trips content through a `SnapshotStore` in a
//      temporary directory — never `~/Library/Application Support` (shared agent brief, rule 8).
//   5. **The idle compressor** never touches the visible session, snapshots before compressing, and
//      does not treat its own pass as activity.
//
// Every test that spawns a shell injects both the snapshot directory and the tkzmux support
// directory into a temporary directory, and hands the child a minimal environment whose `ZDOTDIR`
// does not exist — so zsh sources no user rc file and a test can never read or write real state.

import Foundation
import Metal
import Persistence
import Synchronization
import Testing
import TkzTerminalCore
import TkzTerminalRender
import TkzTerminalView

@testable import TkzApp

// MARK: - Fixtures

/// A temporary directory that removes itself.
private final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "tkzmux-host-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var snapshots: SnapshotStore { SnapshotStore(directory: url.appending(path: "sessions")) }
    var supportDirectory: URL { url.appending(path: "tkzmux", directoryHint: .isDirectory) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// The environment a spawned shell gets. Deliberately minimal: `ZDOTDIR` is set by
/// `TerminalEnvironment` to a directory inside the temp tree that does not exist, so zsh starts
/// with no user rc file and the test is reproducible on any machine.
private func testEnvironment() -> [String: String] {
    [
        "HOME": NSHomeDirectory(),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "SHELL": "/bin/zsh",
        "USER": ProcessInfo.processInfo.userName,
        "LANG": "en_US.UTF-8",
    ]
}

@MainActor
private func makeHost(_ temp: TempDirectory, compressor: TerminalIdleCompressor? = nil) throws -> (
    TerminalRenderContext, TerminalMetalView, TerminalViewHost
)? {
    guard MTLCreateSystemDefaultDevice() != nil else { return nil }
    let context = try TerminalRenderContext(scale: 2)
    let view = TerminalMetalView(
        renderContext: context, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let host = TerminalViewHost(
        view: view,
        snapshots: temp.snapshots,
        tkzmuxDirectory: temp.supportDirectory,
        baseEnvironment: testEnvironment(),
        compressor: compressor)
    return (context, view, host)
}

private func makeSession(cols: UInt16 = 80, rows: UInt16 = 24) throws -> TerminalSession {
    try TerminalSession(options: TerminalSessionOptions(cols: cols, rows: rows))
}

// MARK: - SessionID

@Suite("SessionID")
struct SessionIDTests {
    @Test("a session id must be usable as a .ghsnap basename")
    func validation() {
        #expect(SessionID("abc") != nil)
        #expect(SessionID("") == nil)
        #expect(SessionID(".") == nil)
        #expect(SessionID("..") == nil)
        #expect(SessionID("a/b") == nil)
        #expect(SessionID("a\0b") == nil)
    }

    @Test("generate always produces a valid id")
    func generated() {
        let id = SessionID.generate()
        #expect(SnapshotStore.isValidSessionID(id.rawValue))
        #expect(SessionID.generate() != id)
    }
}

// MARK: - run() chunking

@Suite("TerminalHost.run chunking")
struct RunChunkingTests {
    /// The rule that matters: a chunk ends at a newline, so a canonical-mode tty never sees a line
    /// spanning two writes and never has to buffer more than one line at a time.
    @Test("chunks end at newlines, not at an arbitrary byte count")
    func chunksOnNewlines() {
        let text = "echo one\necho two\recho three"
        let chunks = TerminalViewHost.chunkForCanonicalTty(Data(text.utf8))
        #expect(chunks.count == 3)
        #expect(String(decoding: chunks[0], as: UTF8.self) == "echo one\n")
        #expect(String(decoding: chunks[1], as: UTF8.self) == "echo two\r")
        #expect(String(decoding: chunks[2], as: UTF8.self) == "echo three")
    }

    @Test("a line with no newline is still capped, as a backstop")
    func backstopLimit() {
        let long = String(repeating: "x", count: 2000)
        let chunks = TerminalViewHost.chunkForCanonicalTty(Data(long.utf8))
        #expect(chunks.allSatisfy { $0.count <= TerminalViewHost.maxChunkBytes })
        #expect(chunks.reduce(0) { $0 + $1.count } == 2000)
    }

    @Test("nothing is lost or reordered")
    func lossless() {
        let text = "a\nbb\n\nccc\rdddd"
        let chunks = TerminalViewHost.chunkForCanonicalTty(Data(text.utf8))
        let rejoined = chunks.reduce(into: Data()) { $0.append($1) }
        #expect(String(decoding: rejoined, as: UTF8.self) == text)
    }
}

// MARK: - Background sessions cost only IO

@Suite("TerminalHost — background sessions", .serialized)
@MainActor
struct BackgroundSessionTests {
    /// The headline invariant, at the ticket's scale.
    @Test("30 sessions share exactly one surface, and it holds only the visible session")
    func thirtySessionsOneSurface() throws {
        let temp = try TempDirectory()
        guard let (context, view, host) = try makeHost(temp) else { return }
        defer { host.closeAll(signal: SIGKILL) }

        var ids: [SessionID] = []
        for _ in 0..<30 {
            let id = SessionID.generate()
            _ = try host.open(id, cwd: NSHomeDirectory(), env: [:], size: view.gridSizeForBounds())
            ids.append(id)
        }
        #expect(host.sessionCount == 30)

        // One surface, registered once, for all thirty.
        #expect(context.liveSurfaces().count == 1)

        for id in ids {
            host.show(id)
            #expect(view.surface.isAttached)
            // The single surface holds this session and, by identity, no other.
            #expect(view.surface.session === host.session(for: id))
            #expect(view.session === host.session(for: id))
        }

        // Detaching leaves no libghostty render memory behind at all.
        host.show(nil)
        #expect(!view.surface.isAttached)
        #expect(view.surface.glyphCount == 0)
        #expect(context.liveSurfaces().count == 1)
    }

    /// A background session that produces output must not be able to schedule a frame. This is
    /// structural in the view (`show` clears the outgoing session's `renderSignal`), and this test
    /// is what stops a future refactor from making it a policy again.
    @Test("output from a background session never wakes the display link")
    func backgroundOutputDoesNotWakeTheLink() async throws {
        let temp = try TempDirectory()
        guard let (_, view, host) = try makeHost(temp) else { return }
        defer { host.closeAll(signal: SIGKILL) }

        let background = SessionID.generate()
        let visible = SessionID.generate()
        _ = try host.open(background, cwd: NSHomeDirectory(), env: [:], size: view.gridSizeForBounds())
        _ = try host.open(visible, cwd: NSHomeDirectory(), env: [:], size: view.gridSizeForBounds())
        host.show(visible)

        // Kill both shells and let their last bytes drain. Otherwise zsh's own prompt lands on the
        // *visible* session mid-test and wakes the link for a perfectly legitimate reason, which
        // would make this test flaky rather than wrong.
        host.close(background, signal: SIGKILL)
        host.close(visible, signal: SIGKILL)
        try? await Task.sleep(for: .milliseconds(250))

        // The attach itself legitimately asks for a frame; start from a clean slate.
        view.frameDriver.update { $0.needsUpdate = false }
        let resumesBefore = view.frameDriver.resumeCount

        // 64 KiB straight into the *background* session's VT.
        let payload = String(repeating: "background output\n", count: 4000)
        host.session(for: background)?.write(ptyText: payload)
        // `RenderSignalRelay` delivers through a `Task { @MainActor }`, so yield generously: if a
        // signal were in flight it would land well within this.
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(view.frameDriver.demand.needsUpdate == false)
        #expect(view.frameDriver.resumeCount == resumesBefore)
        // …and the same bytes into the *visible* session do wake it, so the test above is not
        // passing merely because nothing works.
        host.session(for: visible)?.write(ptyText: "visible output\n")
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(view.frameDriver.demand.needsUpdate == true)
    }

    /// The sanity check the ticket asks for: if `show` were being elided, switch timings would be
    /// meaninglessly fast. A fresh attach always reports `DIRTY_FULL` on its first update.
    @Test("every switch produces a DIRTY_FULL first frame")
    func switchesRebuildFully() throws {
        let temp = try TempDirectory()
        guard let (context, view, host) = try makeHost(temp) else { return }
        defer { host.closeAll(signal: SIGKILL) }

        var ids: [SessionID] = []
        for index in 0..<3 {
            let id = SessionID.generate()
            _ = try host.open(id, cwd: NSHomeDirectory(), env: [:], size: view.gridSizeForBounds())
            host.show(id)
            host.session(for: id)?.write(ptyText: "session \(index)\r\n")
            ids.append(id)
        }

        let grid = view.gridSizeForBounds()
        let pixels = context.renderer.drawableSize(columns: Int(grid.cols), rows: Int(grid.rows))
        let texture = try #require(
            context.renderer.makeOffscreenTexture(width: pixels.width, height: pixels.height))

        // Settle: render once so the surface is clean before the switches begin.
        _ = try context.renderer.render(surface: view.surface, to: texture)

        for index in 0..<9 {
            host.show(ids[index % ids.count])
            let outcome = try context.renderer.render(surface: view.surface, to: texture)
            #expect(outcome.update.dirty == .full)
            #expect(outcome.glyphCount > 0)
        }
        #expect(host.showDurations.count > 0)
    }
}

// MARK: - Snapshot on quit, restore on launch

@Suite("TerminalHost — snapshot and restore", .serialized)
@MainActor
struct HostSnapshotTests {
    @Test("snapshotAll writes one .ghsnap per session into the injected directory")
    func snapshotAllWritesFiles() throws {
        let temp = try TempDirectory()
        guard let (_, view, host) = try makeHost(temp) else { return }
        defer { host.closeAll(signal: SIGKILL) }

        var ids: [SessionID] = []
        for _ in 0..<3 {
            let id = SessionID.generate()
            _ = try host.open(id, cwd: NSHomeDirectory(), env: [:], size: view.gridSizeForBounds())
            ids.append(id)
        }
        let sweep = host.snapshotAll()
        #expect(sweep.saved.count == 3)
        #expect(sweep.failed.isEmpty)
        #expect(sweep.totalBytes > 0)
        #expect(Set(try temp.snapshots.list().map(\.id)) == Set(ids.map(\.rawValue)))
        // Nothing was written anywhere near the real store.
        #expect(temp.snapshots.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    /// The acceptance shape: old content plus a *new* prompt. The restored terminal must carry the
    /// text the previous run produced, and the shell behind it must be a different process.
    @Test("restore brings the content back under a fresh shell")
    func restoreKeepsContentAndSpawnsAFreshShell() throws {
        let temp = try TempDirectory()
        guard let (_, view, host) = try makeHost(temp) else { return }

        let id = SessionID.generate()
        _ = try host.open(id, cwd: NSHomeDirectory(), env: [:], size: view.gridSizeForBounds())
        let firstPid = try #require(host.pid(of: id))
        host.session(for: id)?.write(ptyText: "MARKER-9F3A\r\n")
        #expect(host.snapshotAll().saved == [id.rawValue])
        host.closeAll(signal: SIGKILL)

        // A second host over the same store: this is "relaunch".
        guard let (_, view2, host2) = try makeHost(temp) else { return }
        defer { host2.closeAll(signal: SIGKILL) }
        _ = view2
        let sweep = host2.restoreAll(cwd: NSHomeDirectory())
        #expect(sweep.restored == [id.rawValue])
        #expect(sweep.failed.isEmpty)
        #expect(host2.wasRestored(id))
        let restoredPid = try #require(host2.pid(of: id))
        #expect(restoredPid != firstPid)
        let restoredSession = try #require(host2.session(for: id))
        let screen = try restoredSession.formatted()
        #expect(screen.contains("MARKER-9F3A"))
    }

    @Test("discard removes the row and its snapshot")
    func discardDeletesSnapshot() throws {
        let temp = try TempDirectory()
        guard let (_, view, host) = try makeHost(temp) else { return }
        defer { host.closeAll(signal: SIGKILL) }

        let id = SessionID.generate()
        _ = try host.open(id, cwd: NSHomeDirectory(), env: [:], size: view.gridSizeForBounds())
        _ = host.snapshotAll()
        #expect(temp.snapshots.exists(id.rawValue))

        host.discard(id)
        #expect(!host.contains(id))
        #expect(host.sessionCount == 0)
        #expect(!temp.snapshots.exists(id.rawValue))
    }

    @Test("snapshot of an unknown session throws rather than returning empty data")
    func snapshotUnknown() throws {
        let temp = try TempDirectory()
        guard let (_, _, host) = try makeHost(temp) else { return }
        let id = SessionID.generate()
        #expect(throws: TerminalHostError.unknownSession(id.rawValue)) { try host.snapshot(id) }
    }
}

// MARK: - The idle compressor

@Suite("TerminalIdleCompressor")
struct IdleCompressorTests {
    /// Zero idle threshold + a manual `tick` — nothing here waits 60 seconds.
    private func makeCompressor(
        saveSnapshot: (@Sendable (String, TerminalSession) -> Int)? = nil
    ) -> TerminalIdleCompressor {
        TerminalIdleCompressor(
            policy: IdleCompressionPolicy(idleThreshold: .zero, stepInterval: .zero),
            tickInterval: .seconds(3600),
            saveSnapshot: saveSnapshot)
    }

    @Test("the visible session is never compressed")
    func skipsVisible() throws {
        let compressor = makeCompressor()
        let visible = try makeSession()
        let background = try makeSession()
        visible.write(ptyText: String(repeating: "visible\r\n", count: 500))
        background.write(ptyText: String(repeating: "background\r\n", count: 500))
        compressor.register("visible", session: visible, isVisible: true)
        compressor.register("background", session: background, isVisible: false)

        compressor.tick()
        #expect(compressor.stats.passes == 1)  // exactly one session was touched

        // Flip the visibility and the *other* one becomes eligible.
        compressor.setVisible("visible", false)
        compressor.setVisible("background", true)
        compressor.tick()
        #expect(compressor.stats.passes == 2)
    }

    @Test("a session is snapshotted before it is compressed, and only once")
    func snapshotsBeforeCompressing() throws {
        let order = Mutex<[String]>([])
        let compressor = makeCompressor(saveSnapshot: { id, _ in
            order.withLock { $0.append("snapshot:\(id)") }
            return 1
        })
        let session = try makeSession()
        session.write(ptyText: String(repeating: "line\r\n", count: 2000))
        compressor.register("s1", session: session, isVisible: false)

        compressor.tick()
        #expect(order.withLock { $0 } == ["snapshot:s1"])
        #expect(compressor.stats.snapshotsWritten == 1)

        // A second tick on an unchanged, already-`COMPLETE` session does nothing at all — in
        // particular it does not re-encode, which would walk (and rehydrate) the history that was
        // just compressed.
        compressor.tick()
        #expect(order.withLock { $0 } == ["snapshot:s1"])
        #expect(compressor.stats.passes == 1)
    }

    /// The trap this design had to avoid: a compression pass moves the activity token, so a naive
    /// implementation reads its own pass as user activity and compresses (and re-snapshots) forever.
    @Test("a compression pass is not mistaken for activity")
    func passIsNotActivity() throws {
        let compressor = makeCompressor()
        let session = try makeSession()
        session.write(ptyText: String(repeating: "line\r\n", count: 2000))
        compressor.register("s1", session: session, isVisible: false)

        compressor.tick()
        let afterFirst = compressor.stats.passes
        for _ in 0..<5 { compressor.tick() }
        #expect(compressor.stats.passes == afterFirst)
        #expect(compressor.stats.ticks == 6)
    }

    @Test("real output re-arms a settled session")
    func activityReArms() throws {
        let compressor = makeCompressor()
        let session = try makeSession()
        session.write(ptyText: String(repeating: "line\r\n", count: 2000))
        compressor.register("s1", session: session, isVisible: false)
        compressor.tick()
        let afterFirst = compressor.stats.passes

        session.write(ptyText: String(repeating: "more\r\n", count: 2000))
        compressor.tick()
        #expect(compressor.stats.passes > afterFirst)
    }

    @Test("forget stops tracking")
    func forgetting() throws {
        let compressor = makeCompressor()
        let session = try makeSession()
        compressor.register("s1", session: session, isVisible: false)
        #expect(compressor.stats.tracked == 1)
        compressor.forget("s1")
        #expect(compressor.stats.tracked == 0)
        compressor.tick()
        #expect(compressor.stats.passes == 0)
    }

    @Test("start/stop is balanced, so releasing the timer cannot trap")
    func startStopBalanced() {
        let compressor = makeCompressor()
        compressor.start()
        compressor.start()  // idempotent
        compressor.stop()
        compressor.stop()  // idempotent
        compressor.start()
        compressor.stop()
    }
}

// MARK: - Process metrics

@Suite("HostProcessMetrics")
struct HostProcessMetricsTests {
    /// The whole point of sampling `phys_footprint` alongside RSS is that they differ; both must at
    /// least be readable from inside the app process.
    @Test("the sampler reads plausible values and does not leak thread ports")
    func sampler() {
        let first = HostProcessMetrics.sample()
        #expect(first.residentBytes > 0)
        #expect(first.footprintBytes > 0)
        #expect(first.threadCount > 0)
        #expect(first.cpuSeconds > 0)

        // `task_threads` hands back a port per thread; a sampler that leaked them would make the
        // count climb on every reading.
        for _ in 0..<200 { _ = HostProcessMetrics.sample() }
        let last = HostProcessMetrics.sample()
        // Generous on purpose: other suites run in parallel in this same process, so the absolute
        // count moves on its own. A leaked port per sample would add ~200 here.
        #expect(last.threadCount < first.threadCount + 150)
    }
}
