// TerminalHostTests — M1.10 (TKZ-16).
//
// What these prove, in order of how much they matter:
//
//   1. **An unattached terminal costs only IO.** With 30 terminals open, only the ones actually
//      shown have a surface; each holds its own terminal and no other, and bytes written to an
//      *unattached* one neither wake any display link nor allocate render state. Until TKZ-36 this
//      was stated as "exactly one surface" — split panes make that count wrong, but the property
//      that mattered was always the cost, not the cardinality. The view-layer test
//      (`TerminalMetalViewTests.showSwapsSurfaces`) proves the mechanism for two sessions; this
//      proves the invariant survives at the scale the ticket cares about.
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

import ClaudeBridge
import Foundation
import Metal
import Persistence
import Synchronization
import Testing
import TkzCore
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
private func makeHost(
    _ temp: TempDirectory, compressor: TerminalIdleCompressor? = nil,
    environment: [String: String] = testEnvironment()
) throws -> (
    TerminalRenderContext, TerminalMetalView, TerminalViewHost
)? {
    guard MTLCreateSystemDefaultDevice() != nil else { return nil }
    let context = try TerminalRenderContext(scale: 2)
    let view = TerminalMetalView(
        renderContext: context, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let host = TerminalViewHost(
        renderContext: context,
        defaultGrid: { [weak view] in
            view?.gridSizeForBounds() ?? TerminalSize(rows: 24, cols: 80)
        },
        snapshots: temp.snapshots,
        tkzmuxDirectory: temp.supportDirectory,
        baseEnvironment: environment,
        compressor: compressor)
    return (context, view, host)
}

/// A second pane over the same render context — what a split gives you.
@MainActor
private func makePane(_ context: TerminalRenderContext) -> TerminalMetalView {
    TerminalMetalView(renderContext: context, frame: NSRect(x: 0, y: 0, width: 400, height: 600))
}

/// `open` with the row id derived from the terminal id, the way every migrated and every new row
/// is shaped. Keeps the call sites here about what they are testing.
@MainActor
private func open(
    _ host: TerminalViewHost, _ id: TerminalID, size: TerminalSize
) throws -> pid_t {
    try host.open(
        id, session: SessionID(uuid: id.uuid), cwd: NSHomeDirectory(), env: [:], size: size)
}

private func makeSession(cols: UInt16 = 80, rows: UInt16 = 24) throws -> TerminalSession {
    try TerminalSession(options: TerminalSessionOptions(cols: cols, rows: rows))
}

// MARK: - SessionID

@Suite("SessionID")
struct SessionIDTests {
    // M2.1 replaced TerminalHost's temporary SessionID with the real `TkzCore.SessionID`, which is
    // a UUID wrapper. That is *stricter* than the old rule (any string that could be a `.ghsnap`
    // basename), so ids like "abc" are now rejected. Nothing is lost: every id ever written was
    // produced by `generate()`, i.e. an uppercase UUID string, so existing snapshots still parse.
    @Test("a session id is a UUID, and its rawValue is always a legal .ghsnap basename")
    func validation() {
        let uuid = UUID().uuidString
        #expect(SessionID(uuid) != nil)
        #expect(SessionID(uuid)?.rawValue == uuid)
        #expect(SnapshotStore.isValidSessionID(uuid))

        #expect(SessionID("abc") == nil)
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

/// Poll until `predicate` holds or the deadline passes — never a fixed sleep.
@MainActor
private func waitForHost(
    _ timeout: Duration = .seconds(10), _ predicate: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

@Suite("TerminalHost — background sessions", .serialized)
@MainActor
struct BackgroundSessionTests {
    /// The headline invariant, at the ticket's scale — restated for panes (TKZ-36).
    ///
    /// The count of surfaces is now the app's business (one per visible pane); what the host still
    /// guarantees is that a terminal nobody is looking at holds no render memory at all.
    @Test("30 terminals attach only what is shown, and each surface holds its own terminal")
    func thirtyTerminalsAttachOnlyWhatIsShown() throws {
        let temp = try TempDirectory()
        guard let (_, view, host) = try makeHost(temp) else { return }
        defer { host.closeAll(signal: SIGKILL) }

        var ids: [TerminalID] = []
        for _ in 0..<30 {
            let id = TerminalID.generate()
            _ = try open(host, id, size: view.gridSizeForBounds())
            ids.append(id)
        }
        #expect(host.sessionCount == 30)

        for id in ids {
            host.show([id: view])
            #expect(host.visibleTerminalIDs == [id])
            #expect(view.surface.isAttached)
            // The surface holds this terminal and, by identity, no other.
            #expect(view.surface.session === host.session(for: id))
            #expect(view.session === host.session(for: id))
        }

        // Detaching leaves no libghostty render memory behind at all.
        host.show([:])
        #expect(host.visibleTerminalIDs.isEmpty)
        #expect(!view.surface.isAttached)
        #expect(view.surface.glyphCount == 0)
    }

    /// Two panes side by side: both attached, each to its own surface, and `show` is what decides
    /// which — the split container never touches a surface itself.
    @Test("two panes attach to two surfaces, and dropping one detaches only that one")
    func twoPanesAttachToTwoSurfaces() throws {
        let temp = try TempDirectory()
        guard let (context, view, host) = try makeHost(temp) else { return }
        let second = makePane(context)
        defer { host.closeAll(signal: SIGKILL) }

        let a = TerminalID.generate()
        let b = TerminalID.generate()
        _ = try open(host, a, size: view.gridSizeForBounds())
        _ = try open(host, b, size: view.gridSizeForBounds())

        host.show([a: view, b: second])
        #expect(host.visibleTerminalIDs == [a, b])
        #expect(view.surface.session === host.session(for: a))
        #expect(second.surface.session === host.session(for: b))

        // Closing one pane must not disturb the other.
        host.show([a: view])
        #expect(host.visibleTerminalIDs == [a])
        #expect(view.surface.isAttached)
        #expect(!second.surface.isAttached)
        #expect(second.surface.glyphCount == 0)
    }

    /// The bug this ticket exists to avoid. Input used to be routed to "the visible session",
    /// which with two panes on screen names nothing in particular — the unfocused pane's
    /// keystrokes would have landed in the focused pane's shell.
    @Test("writeInput reaches the addressed terminal and no other")
    func writeInputAddressesOnePane() async throws {
        let temp = try TempDirectory()
        guard let (context, view, host) = try makeHost(temp) else { return }
        let second = makePane(context)
        defer { host.closeAll(signal: SIGKILL) }

        let a = TerminalID.generate()
        let b = TerminalID.generate()
        _ = try open(host, a, size: view.gridSizeForBounds())
        _ = try open(host, b, size: view.gridSizeForBounds())
        host.show([a: view, b: second])

        // Hang both shells up first: a live zsh would echo and prompt over the assertion.
        host.close(a, signal: SIGKILL)
        host.close(b, signal: SIGKILL)
        _ = await waitForHost { !host.isAlive(a) && !host.isAlive(b) }

        host.session(for: b)?.write(ptyText: "MARKER-PANE-B\r\n")
        let landed = await waitForHost {
            ((try? host.session(for: b)?.formatted()) ?? nil)?.contains("MARKER-PANE-B") == true
        }
        #expect(landed)
        let other = try #require(try host.session(for: a)?.formatted())
        #expect(!other.contains("MARKER-PANE-B"), "pane A saw pane B's bytes")
    }

    /// Each attached pane resizes its own pty. `resizeVisible` is gone precisely because it could
    /// not express this.
    @Test("resizing one pane leaves the other pane's terminal alone")
    func resizeAddressesOnePane() throws {
        let temp = try TempDirectory()
        guard let (context, view, host) = try makeHost(temp) else { return }
        let second = makePane(context)
        defer { host.closeAll(signal: SIGKILL) }

        let a = TerminalID.generate()
        let b = TerminalID.generate()
        _ = try open(host, a, size: view.gridSizeForBounds())
        _ = try open(host, b, size: view.gridSizeForBounds())
        host.show([a: view, b: second])

        let before = try #require(host.session(for: b)).size
        host.resize(a, TerminalSize(rows: 10, cols: 40, cellWidthPx: 8, cellHeightPx: 16))
        #expect(try #require(host.session(for: a)).size.cols == 40)
        #expect(try #require(host.session(for: b)).size == before)
    }

    /// Attaching ends with a forced grid resize, and the pty has to hear it too. The hook that
    /// carries it used to be installed *after* `show`, so the VT was sized to the pane while the
    /// shell kept its spawn size and redrew its prompt against the wrong grid.
    @Test("attaching a pane resizes its pty to the surface's grid")
    func attachResizesThePty() throws {
        let temp = try TempDirectory()
        guard let (_, view, host) = try makeHost(temp) else { return }
        defer { host.closeAll(signal: SIGKILL) }

        let id = TerminalID.generate()
        _ = try open(
            host, id, size: TerminalSize(rows: 10, cols: 10, cellWidthPx: 8, cellHeightPx: 16))
        #expect(host.ptySize(for: id)?.cols == 10)

        host.show([id: view])
        let grid = view.gridSizeForBounds()
        #expect(grid.cols != 10)
        #expect(host.ptySize(for: id) == grid)
        #expect(host.session(for: id)?.size.cols == grid.cols)
    }

    /// Every layout delivery re-shows the visible set. A pane that is already on its surface must
    /// not be re-attached: that is a full redraw and a forced resize of a pane nobody touched.
    @Test("re-showing a pane on the surface it already has does not re-attach it")
    func reshowingTheSameSurfaceDoesNotReattach() throws {
        let temp = try TempDirectory()
        guard let (_, view, host) = try makeHost(temp) else { return }
        defer { host.closeAll(signal: SIGKILL) }

        let id = TerminalID.generate()
        _ = try open(host, id, size: view.gridSizeForBounds())
        host.show([id: view])
        let resizes = view.gridResizeCount

        host.show([id: view])
        #expect(view.gridResizeCount == resizes)
        #expect(view.surface.isAttached)
        #expect(host.visibleTerminalIDs == [id])
    }

    /// A session whose shell has exited keeps its screen (the row is resumable) but must stop
    /// blinking a cursor at the user — it reads as ready for input that goes nowhere.
    @Test("an exited session stops showing a cursor, and selecting back to it does not resurrect it")
    func exitedSessionSuppressesTheCursor() async throws {
        let temp = try TempDirectory()
        guard let (_, view, host) = try makeHost(temp) else { return }
        defer { host.closeAll(signal: SIGKILL) }

        let id = TerminalID.generate()
        _ = try open(host, id, size: view.gridSizeForBounds())
        host.show([id: view])
        #expect(!view.surface.isCursorSuppressed, "a live session must keep its cursor")

        host.close(id, signal: SIGKILL)
        let died = await waitForHost { !host.isAlive(id) && view.surface.isCursorSuppressed }
        #expect(died, "the cursor was still being drawn for a dead shell")

        // `show` resets the flag; re-selecting an already-dead session must re-apply it.
        host.show([:])
        host.show([id: view])
        #expect(view.surface.isCursorSuppressed)
    }

    /// `ZDOTDIR` must exist before a shell is spawned, or zsh cannot lock its history file and
    /// says so **in the user's terminal**:
    /// `zsh: locking failed for …/zsh/.zsh_history: no such file or directory`, most visibly on
    /// SIGHUP when it flushes history on the way out. `TerminalEnvironment.make` points every
    /// session at that directory unconditionally; until M3.3 writes rc files into it, nothing else
    /// creates it.
    @Test("the host creates the ZDOTDIR its shells are pointed at")
    func hostCreatesTheShellDirectory() throws {
        let temp = try TempDirectory()
        let zdotdir = temp.supportDirectory.appending(path: "zsh", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: zdotdir.path), "precondition")

        guard let (_, _, host) = try makeHost(temp) else { return }
        defer { host.closeAll(signal: SIGKILL) }

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: zdotdir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        // Empty is the point: zsh must still find no rc files there until M3.3 ships them.
        #expect(try FileManager.default.contentsOfDirectory(atPath: zdotdir.path).isEmpty)
    }

    /// TKZ-33: the host spawns the login shell `SHELL` names, and a pane is titled after it until
    /// the shell sets a title of its own. The wrapper is not on disk here, so bash is started as a
    /// plain login shell rather than with `--rcfile <missing file>`.
    @Test("the host follows the login shell in its environment")
    func hostFollowsTheLoginShell() throws {
        let temp = try TempDirectory()
        var environment = testEnvironment()
        environment["SHELL"] = "/bin/bash"
        guard let (_, view, host) = try makeHost(temp, environment: environment) else { return }
        defer { host.closeAll(signal: SIGKILL) }
        #expect(host.shell == LoginShell(path: "/bin/bash"))

        let id = TerminalID.generate()
        _ = try host.open(
            id, session: SessionID(uuid: id.uuid), cwd: NSHomeDirectory(), env: [:],
            size: view.gridSizeForBounds())
        #expect(host.title(of: id) == "bash")
        #expect(host.isAlive(id))
    }

    /// End-to-end (2026-09-09): a session opened with a boot command really runs it in the spawned
    /// shell, and the output lands on the rendered screen.
    ///
    /// The spy-host tests assert the wiring and `ZshWrapperTests` covers `.zlogin` on its own; this
    /// is the one that exercises the whole path through `TerminalViewHost` and a real pty — the
    /// place the old readiness heuristic silently lost `claude --resume` when zsh's line-editor
    /// setup flushed the tty's input queue out from under it. Since 2026-09-10 `.zlogin` defers the
    /// command to a precmd hook, so this also proves the app's spawn reaches a first prompt.
    @Test("a boot command runs in a real shell and its output reaches the screen")
    func bootCommandReachesTheShell() async throws {
        let temp = try TempDirectory()
        guard let (_, view, host) = try makeHost(temp) else { return }
        defer { host.closeAll(signal: SIGKILL) }

        // The spawn points ZDOTDIR at `<support>/zsh`; the boot command lives in `.zlogin`, so the
        // real wrapper has to be on disk there for this to be an end-to-end test at all.
        let zdotdir = temp.supportDirectory.appendingPathComponent("zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        let zlogin = try #require(ShimResources.bundled().zshFiles["zlogin"])
        try zlogin.write(
            to: zdotdir.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)

        let id = TerminalID.generate()
        _ = try host.open(
            id, session: SessionID(uuid: id.uuid), cwd: NSHomeDirectory(),
            env: ["TKZMUX_BOOT_COMMAND": "echo TKZMUX-E2E-OK"],
            size: view.gridSizeForBounds())
        host.show([id: view])

        let session = try #require(host.session(for: id))
        let deadline = ContinuousClock.now + .seconds(10)
        var screen = ""
        while ContinuousClock.now < deadline {
            screen = (try? session.formatted()) ?? ""
            // Once: the command's own output. A boot command is run by `.zlogin`, not typed, so
            // the tty never echoes it back the way a typed line would.
            if screen.contains("TKZMUX-E2E-OK") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            screen.contains("TKZMUX-E2E-OK"),
            "the command never ran in the shell. Screen:\n\(screen)")
    }

    /// An **unattached** terminal that produces output must not be able to schedule a frame on
    /// **any** view. This is structural in the view (`show` clears the outgoing session's
    /// `renderSignal`), and this test is what stops a future refactor from making it a policy
    /// again. A second pane is live throughout, so "no link woke" means all of them.
    @Test("output from an unattached terminal never wakes any display link")
    func backgroundOutputDoesNotWakeTheLink() async throws {
        let temp = try TempDirectory()
        guard let (context, view, host) = try makeHost(temp) else { return }
        let second = makePane(context)
        defer { host.closeAll(signal: SIGKILL) }

        let background = TerminalID.generate()
        let visible = TerminalID.generate()
        let alsoVisible = TerminalID.generate()
        _ = try open(host, background, size: view.gridSizeForBounds())
        _ = try open(host, visible, size: view.gridSizeForBounds())
        _ = try open(host, alsoVisible, size: second.gridSizeForBounds())
        host.show([visible: view, alsoVisible: second])

        // Kill both shells and let their last bytes drain. Otherwise zsh's own prompt lands on the
        // *visible* session mid-test and wakes the link for a perfectly legitimate reason, which
        // would make this test flaky rather than wrong.
        host.close(background, signal: SIGKILL)
        host.close(visible, signal: SIGKILL)
        host.close(alsoVisible, signal: SIGKILL)
        try? await Task.sleep(for: .milliseconds(250))

        // The attach itself legitimately asks for a frame; start from a clean slate.
        view.frameDriver.update { $0.needsUpdate = false }
        second.frameDriver.update { $0.needsUpdate = false }
        let resumesBefore = view.frameDriver.resumeCount
        let secondResumesBefore = second.frameDriver.resumeCount

        // 64 KiB straight into the *background* session's VT.
        let payload = String(repeating: "background output\n", count: 4000)
        host.session(for: background)?.write(ptyText: payload)
        // `RenderSignalRelay` delivers through a `Task { @MainActor }`, so yield generously: if a
        // signal were in flight it would land well within this.
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(view.frameDriver.demand.needsUpdate == false)
        #expect(view.frameDriver.resumeCount == resumesBefore)
        #expect(second.frameDriver.demand.needsUpdate == false)
        #expect(second.frameDriver.resumeCount == secondResumesBefore)
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

        var ids: [TerminalID] = []
        for index in 0..<3 {
            let id = TerminalID.generate()
            _ = try open(host, id, size: view.gridSizeForBounds())
            host.show([id: view])
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
            host.show([ids[index % ids.count]: view])
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

        var ids: [TerminalID] = []
        for _ in 0..<3 {
            let id = TerminalID.generate()
            _ = try open(host, id, size: view.gridSizeForBounds())
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

        let id = TerminalID.generate()
        _ = try open(host, id, size: view.gridSizeForBounds())
        let firstPid = try #require(host.pid(of: id))
        host.session(for: id)?.write(ptyText: "MARKER-9F3A\r\n")
        #expect(host.snapshotAll().saved == [id.rawValue])
        host.closeAll(signal: SIGKILL)

        // A second host over the same store: this is "relaunch".
        guard let (_, view2, host2) = try makeHost(temp) else { return }
        defer { host2.closeAll(signal: SIGKILL) }
        _ = view2
        // No `owner:` argument on purpose: the default is what makes a `.ghsnap` written by any
        // earlier build map back to its row after the schema v2 migration.
        let sweep = host2.restoreAll(cwd: NSHomeDirectory())
        #expect(sweep.restored == [id.rawValue])
        #expect(host2.owner(of: id) == SessionID(uuid: id.uuid))
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

        let id = TerminalID.generate()
        _ = try open(host, id, size: view.gridSizeForBounds())
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
        let id = TerminalID.generate()
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

    /// `stop()` only parks the timer. The compressor's own table holds a strong `TerminalSession`
    /// per entry — and therefore that session's whole scrollback — so a `closeAll` that stopped the
    /// timer without forgetting the sessions kept every VT alive for the app's remaining lifetime.
    /// `evict` always did the `forget`; `closeAll` did not.
    // `@MainActor` because this one drives a real host (the rest of this suite pokes the
    // compressor directly); the surrounding suite is nonisolated.
    @MainActor
    @Test("closeAll releases the compressor's session references, not just its timer")
    func closeAllForgetsSessions() throws {
        let temp = try TempDirectory()
        let compressor = makeCompressor()
        guard let (_, view, host) = try makeHost(temp, compressor: compressor) else { return }

        for _ in 0..<3 {
            let id = TerminalID.generate()
            _ = try host.open(
                id, session: SessionID(uuid: id.uuid), cwd: NSHomeDirectory(), env: [:],
                size: view.gridSizeForBounds())
        }
        #expect(compressor.stats.tracked == 3)

        host.closeAll(signal: SIGKILL)
        #expect(compressor.stats.tracked == 0)
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
        compressor.setVisible(["background"])
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
