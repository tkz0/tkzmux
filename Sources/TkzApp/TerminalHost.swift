// TerminalHost — the seam between the terminal engine and the app (M1.10 / TKZ-16).
// See docs/design.md → *TerminalHost — the seam between halves*, and docs/perf.md → *GUI half*.
//
// This file holds two things. (`SessionID` used to live here as a stopgap; M2.1 moved it to
// `TkzCore/Models.swift` as a UUID wrapper, which is stricter than the old rule — anything that
// could be a `.ghsnap` basename — but loses nothing, because every id ever written came from
// `generate()` as an uppercase UUID.)
//
//   1. `TerminalHost` — the protocol design.md specifies, verbatim apart from `@MainActor`
//      (see the DESIGN.MD DELTA in the ticket: an implementation over `NSView` cannot be
//      nonisolated under Swift 6 strict concurrency).
//   2. `TerminalViewHost` — its implementation over `TerminalMetalView` + `Pty` +
//      `TerminalSession`, plus `TerminalIdleCompressor`, the background-session idle timer that
//      drives `IdleCompressionPolicy`.
//
// ## The invariant this type exists to hold: a background session costs only IO
//
// There is exactly **one** `TerminalSurface`, and it belongs to the `TerminalMetalView`. A session
// is attached to it only while it is the visible one; `show(_:)` detaches the outgoing session
// (freeing its render state and every row cache) before attaching the incoming one. A background
// session therefore has:
//
//   * no render state, no glyph rows, no atlas positions — `TerminalSurface.detach` frees all of it;
//   * no render signal — `TerminalMetalView.show` clears the outgoing session's `renderSignal`, so
//     a background session that produces megabytes calls nothing and can wake no display link;
//   * one serial `DispatchQueue` (not a thread) for its pty reads, and nothing else.
//
// `TerminalHostTests` asserts each of those across 30 sessions rather than trusting the prose.
//
// ## Snapshot/compress ordering
//
// docs/perf.md → *Does compression pay?* measured that `compress(INCREMENTAL)` takes 30 filled
// sessions from 577 MiB of `phys_footprint` to 26 MiB for 113 ms of work — but that reading the
// history back **rehydrates** it. So the idle timer snapshots a session to disk *before* it
// compresses it, and the activity token it snapshotted at doubles as a dirty flag: at quit only
// sessions whose token has moved are re-snapshotted, so quitting does not rehydrate 30 sessions
// that were already saved.

import AppKit
import Darwin
import Dispatch
import Foundation
import Persistence
import Synchronization
import TkzCore
import TkzTerminalCore
import TkzTerminalRender
import TkzTerminalView
import os

// MARK: - TerminalHost

/// What the app half may ask of the terminal half. Nothing above this line knows about libghostty,
/// ptys or Metal; nothing below it knows about the sidebar.
///
/// `@MainActor` is not in design.md's listing but is required: the implementation owns an `NSView`.
@MainActor
public protocol TerminalHost: AnyObject {
    /// Spawns a login shell for `id` and returns its pid.
    func open(_ id: SessionID, cwd: String, env: [String: String], size: TerminalSize) throws -> pid_t
    /// Types `command` followed by `\r` into the session's pty.
    func run(_ id: SessionID, command: String)
    /// Types `command` **once the shell is ready to receive it** — see `Pty.writeWhenReady`.
    ///
    /// A protocol requirement rather than an extension-only method on purpose: `host` is held as
    /// `any TerminalHost`, and a call to a method that exists only in a protocol extension is
    /// statically dispatched on an existential — the implementation below would never run.
    func runWhenReady(_ id: SessionID, command: String)
    /// Attaches the single renderer to `id`; `nil` shows nothing.
    func show(_ id: SessionID?)
    /// The session the surface is actually attached to. Not the same as the store's selection: a
    /// row restored from `state.json` (M5.1) is selectable long before it has a terminal, and the
    /// window shows its empty state rather than a blank grid for exactly this reason.
    var visibleSessionID: SessionID? { get }
    func resize(_ id: SessionID, _ size: TerminalSize)
    /// Signals the child (SIGHUP by default). The row stays resumable.
    func close(_ id: SessionID, signal: Int32)
    /// The `.ghsnap` bytes for `id`.
    func snapshot(_ id: SessionID) throws -> Data
    /// Rebuilds `id` from a snapshot and spawns a fresh shell under it. Returns the new pid.
    /// An id the host still holds (a hung-up session whose grid is kept) is replaced.
    func restore(_ id: SessionID, from: Data, cwd: String, env: [String: String]) throws -> pid_t
    /// The `.ghsnap` on disk for `id`, if one was saved — what a row restored from `state.json`
    /// comes back from (M5.2). Not the live grid: that is `snapshot(_:)`.
    func savedSnapshot(_ id: SessionID) -> Data?
    /// **Remove**: forgets the session entirely — hangs it up if alive, drops its grid, deletes its
    /// snapshot on disk. The one call that makes a row unresumable; design.md → *Session flows*.
    func discard(_ id: SessionID)
    /// Every session's events, tagged.
    var events: AsyncStream<(SessionID, TerminalEvent)> { get }
}

extension TerminalHost {
    /// The stopgap the M1 harness used, kept as the default so a test double (or any future
    /// conformer) does not have to reimplement readiness: wait long enough that a login zsh has
    /// finished its `tcsetattr(TCSAFLUSH)`, then type. `TerminalViewHost` overrides it with the
    /// real signal.
    public func runWhenReady(_ id: SessionID, command: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { self.run(id, command: command) }
        }
    }
}

public enum TerminalHostError: Error, Equatable, Sendable {
    case unknownSession(String)
    case sessionNotAlive(String)
}

// MARK: - One live session

/// One spawned shell: its VT, its pty, and the task draining its event stream.
@MainActor
final class HostSession {
    let id: SessionID
    let session: TerminalSession
    private(set) var pty: Pty
    var title: String = "zsh"
    var isAlive = true
    var eventsTask: Task<Void, Never>?
    /// Set when the session's content came from a `.ghsnap` at launch.
    var wasRestored = false

    init(id: SessionID, session: TerminalSession, pty: Pty) {
        self.id = id
        self.session = session
        self.pty = pty
    }

    deinit { eventsTask?.cancel() }
}

// MARK: - TerminalViewHost

/// `TerminalHost` over one `TerminalMetalView`.
///
/// Everything injectable is injected for one reason: a test must never write to
/// `~/Library/Application Support/tkzmux` and must never inherit the developer's environment
/// (shared agent brief, hard rule 8). `snapshots` and `tkzmuxDirectory` both default to the real
/// locations, and both are overridden by `DevWindowController`'s harness env vars.
@MainActor
public final class TerminalViewHost: TerminalHost {
    public let view: TerminalMetalView
    public let snapshots: SnapshotStore
    /// tkzmux's application-support directory — `ZDOTDIR`, `TKZMUX_BIN`, the socket.
    public let tkzmuxDirectory: URL
    /// What a session's environment is built on top of.
    public let baseEnvironment: [String: String]

    private var sessions: [SessionID: HostSession] = [:]
    /// Insertion order, for a stable "next session" after a close.
    public private(set) var order: [SessionID] = []
    public private(set) var visibleID: SessionID?

    private let continuation: AsyncStream<(SessionID, TerminalEvent)>.Continuation
    public let events: AsyncStream<(SessionID, TerminalEvent)>

    /// The idle-compression timer, or nil when compression is disabled.
    public let compressor: TerminalIdleCompressor?

    /// Called after `show(_:)` completed, so the owner can re-push things the view cannot know
    /// about (the mouse controller's pixel geometry, the window title).
    public var onDidShow: ((SessionID?) -> Void)?

    private let signposter = OSSignposter(subsystem: "se.tkz.tkzmux", category: "terminalhost")
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "terminalhost")

    /// The most recent `show(_:)` durations in seconds, in call order. Diagnostics; see
    /// docs/perf.md.
    ///
    /// Capped: `resetShowDurations()` is only ever called by the dev bench, so in the real app
    /// this otherwise grew by one `Double` per session switch for the life of the process. The
    /// switch benchmark reads a distribution over a run of a few hundred, so the cap is well above
    /// what it needs.
    public private(set) var showDurations: [Double] = []
    private static let maxShowDurations = 4096

    public init(
        view: TerminalMetalView,
        snapshots: SnapshotStore = .standard(),
        tkzmuxDirectory: URL? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        compressor: TerminalIdleCompressor? = nil
    ) {
        self.view = view
        self.snapshots = snapshots
        self.tkzmuxDirectory = tkzmuxDirectory
            ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "tkzmux", directoryHint: .isDirectory)
            ?? URL(filePath: NSTemporaryDirectory()).appending(path: "tkzmux", directoryHint: .isDirectory)
        self.baseEnvironment = baseEnvironment
        self.compressor = compressor
        TerminalViewHost.createShellDirectory(in: self.tkzmuxDirectory)
        var escapee: AsyncStream<(SessionID, TerminalEvent)>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { escapee = $0 }
        self.continuation = escapee
    }

    deinit { continuation.finish() }

    /// Creates the `ZDOTDIR` the spawned shells are pointed at.
    ///
    /// `TerminalEnvironment.make` sets `ZDOTDIR` to `<tkzmuxDirectory>/zsh` unconditionally, and
    /// before M3.3's `ShimInstaller` wrote the wrapper rc files into it nothing created it — so every
    /// login zsh failed to lock its history file and printed
    /// `zsh: locking failed for …/zsh/.zsh_history: no such file or directory` into the user's
    /// terminal, most visibly on SIGHUP, when zsh flushes history on the way out. An empty
    /// directory is enough: zsh finds no rc files there and behaves as a plain login shell, which
    /// is also what a shell gets after *Remove Shell Integration*. Failure is ignored on purpose — a shell that cannot keep history is still a
    /// working shell, and refusing to construct the host over it would be worse.
    private static func createShellDirectory(in tkzmuxDirectory: URL) {
        let zdotdir = tkzmuxDirectory.appending(path: "zsh", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
    }

    // MARK: Introspection (tests and diagnostics)

    public var sessionCount: Int { sessions.count }
    public var sessionIDs: [SessionID] { order }
    public func contains(_ id: SessionID) -> Bool { sessions[id] != nil }
    public func isAlive(_ id: SessionID) -> Bool { sessions[id]?.isAlive ?? false }
    public func pid(of id: SessionID) -> pid_t? { sessions[id]?.pty.pid }
    public func title(of id: SessionID) -> String? { sessions[id]?.title }
    public func wasRestored(_ id: SessionID) -> Bool { sessions[id]?.wasRestored ?? false }
    /// The `TerminalSession` behind `id`. Exposed so the window controller can push mouse geometry
    /// and so tests can assert on the VT directly.
    public func session(for id: SessionID) -> TerminalSession? { sessions[id]?.session }
    /// Retained scrollback rows per session, in `order`. Diagnostics: it is the only way to say
    /// what a harness corpus actually built up rather than what it was asked to build up.
    public func scrollbackRows() -> [Int] { order.compactMap { sessions[$0]?.session.scrollbackRows } }

    /// Per-session memory held by the *spawned processes* — the shell, Claude Code, and whatever
    /// those started — in `order`. This is the number the app's own `HostProcessMetrics` cannot
    /// see and that Activity Monitor blames on us anyway; see `SessionMemory`.
    ///
    /// One `proc_pid_rusage` syscall per process in each tree, so call it on a slow timer.
    public func sessionMemory() -> [(id: SessionID, sample: SessionMemorySample)] {
        order.compactMap { id in
            guard let pid = sessions[id]?.pty.pid, pid > 0 else { return nil }
            return (id, SessionMemory.sample(rootPid: pid))
        }
    }

    // MARK: - open

    /// Spawns a login zsh for `id` under the full tkzmux environment.
    ///
    /// `env` is applied as **overrides on top of `baseEnvironment`**, before
    /// `TerminalEnvironment.make` gets its hands on it — so a caller can set `CLAUDE_CONFIG_DIR`
    /// or a working `PATH` without being able to break `TERM` / `TERMINFO` / `TKZMUX_*`, which
    /// `make` always writes last.
    @discardableResult
    public func open(
        _ id: SessionID, cwd: String, env: [String: String], size: TerminalSize
    ) throws -> pid_t {
        let session = try makeSession(size: size)
        let pty = try spawn(id: id, session: session, cwd: cwd, env: env, size: size)
        evict(id)
        adopt(HostSession(id: id, session: session, pty: pty))
        return pty.pid
    }

    /// Drops a session the host still holds under `id` so a new one can take its place — the
    /// Resume-after-⌘W case, where the dead grid is kept on screen until the row is reopened.
    /// Unlike `discard`, the snapshot on disk is left alone: it is what the reopen restores from.
    /// Without this, `adopt` would overwrite `sessions[id]`, append `id` to `order` a second time
    /// and leave the old event pump running against a session nothing references.
    private func evict(_ id: SessionID) {
        guard let host = sessions.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        host.eventsTask?.cancel()
        host.session.finishEvents()
        if host.isAlive { _ = host.pty.terminate(signal: SIGHUP) }
        compressor?.forget(id.rawValue)
        if visibleID == id {
            view.show(nil)
            visibleID = nil
        }
    }

    /// A `TerminalSession` sized for the grid, themed from the view's render context.
    private func makeSession(size: TerminalSize) throws -> TerminalSession {
        let session = try TerminalSession(
            options: TerminalSessionOptions(
                cols: max(1, size.cols),
                rows: max(1, size.rows),
                cellWidthPx: UInt32(size.cellWidthPx),
                cellHeightPx: UInt32(size.cellHeightPx),
                theme: view.renderContext.theme),
            label: "tkzmux.session.\(sessions.count)")
        // Repeat-click detection is otherwise dead: libghostty compares timestamps against this
        // interval and `TkzTerminalCore` cannot read AppKit's copy of it.
        session.selectionDoubleClickInterval = NSEvent.doubleClickInterval
        return session
    }

    private func spawn(
        id: SessionID, session: TerminalSession, cwd: String, env: [String: String], size: TerminalSize
    ) throws -> Pty {
        let spawn = TerminalEnvironment.loginShellSpawn(
            sessionID: id.rawValue,
            cwd: cwd,
            size: size,
            tkzmuxDir: tkzmuxDirectory,
            baseEnvironment: baseEnvironment.merging(env) { _, override in override })

        let pty = try Pty(
            spawn: spawn,
            ioQueue: session.ioQueue,
            // Deliberately *not* poking the compressor here: this closure is the hot IO path and a
            // shared lock on it would serialize 30 sessions against each other. Idleness is
            // detected by polling `compressionActivity()` on the timer's own tick instead, which
            // is what `terminal.h` intends the token for.
            onData: { [session] data in session.write(ptyBytes: data) },
            onExit: { [session] exit in
                if let signal = exit.signal {
                    session.noteExit(.signaled(signal: signal))
                } else {
                    session.noteExit(.exited(code: exit.exitCode ?? 0))
                }
            })

        // Query replies and mode reports the VT wants to send back. `Pty.write` must be called on
        // the IO queue and the sink can fire from the main thread (a resize), so hop.
        session.setOnWritePty { [weak pty, weak session] data in
            guard let pty, let session else { return }
            session.ioQueue.async { try? pty.write(data) }
        }
        return pty
    }

    /// Files a freshly spawned session and starts draining its events into the merged stream.
    private func adopt(_ host: HostSession) {
        sessions[host.id] = host
        order.append(host.id)
        let id = host.id
        let session = host.session
        host.eventsTask = Task { @MainActor [weak self] in
            for await event in session.events {
                guard let self else { return }
                // An evicted session (reopened under the same id) can still deliver its `.exited`
                // after the replacement was adopted; applying it would kill the fresh shell's row.
                // Identity, not id, decides.
                guard self.sessions[id]?.session === session else { continue }
                self.observe(event, for: id)
                self.continuation.yield((id, event))
            }
        }
        compressor?.register(id.rawValue, session: session, isVisible: id == visibleID)
    }

    /// The host's own reaction to an event. Everything else is the consumer's business.
    private func observe(_ event: TerminalEvent, for id: SessionID) {
        switch event {
        case .title(let title):
            sessions[id]?.title = title.isEmpty ? "zsh" : title
        case .exited:
            sessions[id]?.isAlive = false
            // A dead session keeps its screen but must stop blinking a cursor at the user.
            if id == visibleID { view.setCursorSuppressed(true) }
        default:
            break
        }
        // A title, a bell or a chunk of output all mean the session is not idle.
        compressor?.noteActivity(id.rawValue)
    }

    // MARK: - run

    /// Types `command` plus a carriage return into `id`'s pty.
    ///
    /// **Chunked on newlines, not on byte count.** A tty in canonical mode truncates any *line*
    /// longer than `MAX_INPUT` (~1 KiB — measured in M1.2 and used by `tkzmux-vtdump`'s script
    /// runner for the same reason), so the write is split after every `\n`/`\r` and, as a
    /// backstop, every `maxChunkBytes`. A single command line longer than `MAX_INPUT` is still
    /// truncated by the tty — that is the kernel's rule, not something this method can paper over.
    public func run(_ id: SessionID, command: String) {
        guard let host = sessions[id], host.isAlive else { return }
        let data = Data(command.utf8) + Data([0x0D])
        let pty = host.pty
        for chunk in TerminalViewHost.chunkForCanonicalTty(data) {
            host.session.ioQueue.async { try? pty.write(chunk) }
        }
        compressor?.noteActivity(id.rawValue)
    }

    /// Types `command` once the shell has printed its prompt and gone quiet.
    ///
    /// `run` in the same turn as `open` is silently swallowed: a login zsh's line-editor setup
    /// calls `tcsetattr(…, TCSAFLUSH, …)`, which discards the tty's input queue (measured in
    /// M1.10). `Pty.writeWhenReady` parks the bytes until the child has produced output and then
    /// settled, with a timeout for a shell that prints nothing.
    public func runWhenReady(_ id: SessionID, command: String) {
        guard let host = sessions[id], host.isAlive else { return }
        let data = Data(command.utf8) + Data([0x0D])
        for chunk in TerminalViewHost.chunkForCanonicalTty(data) {
            host.pty.writeWhenReady(chunk)
        }
        compressor?.noteActivity(id.rawValue)
    }

    /// Conservative: `MAX_INPUT` is 1024 on Darwin, so 512 leaves room for the tty's own
    /// bookkeeping even in the pathological case.
    nonisolated static let maxChunkBytes = 512

    nonisolated static func chunkForCanonicalTty(_ data: Data, limit: Int = maxChunkBytes) -> [Data] {
        var chunks: [Data] = []
        var current = Data()
        for byte in data {
            current.append(byte)
            if byte == 0x0A || byte == 0x0D || current.count >= limit {
                chunks.append(current)
                current = Data()
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Raw host input (encoded keys, a mouse report, a paste) for the **visible** session.
    public func writeInput(_ data: Data) {
        guard !data.isEmpty, let visibleID, let host = sessions[visibleID], host.isAlive else { return }
        let pty = host.pty
        host.session.ioQueue.async { try? pty.write(data) }
        compressor?.noteActivity(visibleID.rawValue)
    }

    // MARK: - show

    /// Attaches the single renderer to `id`.
    ///
    /// The whole call is one `os_signpost` interval (`show`), and its wall time is also recorded in
    /// `showDurations` so the distribution can be printed without Instruments. The budget is one
    /// frame at 120 Hz: 8.3 ms.
    public var visibleSessionID: SessionID? { visibleID }

    public func show(_ id: SessionID?) {
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("show", id: signpostID)
        let start = ContinuousClock.now

        let previous = visibleID
        visibleID = id
        if let id, let host = sessions[id] {
            view.show(host.session)
            // `show` resets the flag, so re-apply it: selecting back to an already-dead session
            // must not resurrect its cursor.
            view.setCursorSuppressed(!host.isAlive)
        } else {
            visibleID = nil
            view.show(nil)
        }
        let elapsed = ContinuousClock.now - start
        showDurations.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        if showDurations.count > TerminalViewHost.maxShowDurations {
            showDurations.removeFirst(showDurations.count - TerminalViewHost.maxShowDurations)
        }
        signposter.endInterval("show", interval)

        if let previous, previous != visibleID { compressor?.setVisible(previous.rawValue, false) }
        if let visibleID { compressor?.setVisible(visibleID.rawValue, true) }
        onDidShow?(visibleID)
    }

    public func resetShowDurations() { showDurations.removeAll(keepingCapacity: true) }

    // MARK: - resize

    /// Resizes both halves. For the visible session the view drives this itself on its own tick;
    /// this entry point exists for background sessions (M2 resizes them when the sidebar's split
    /// changes) and for the tests.
    public func resize(_ id: SessionID, _ size: TerminalSize) {
        guard let host = sessions[id] else { return }
        do {
            try host.session.resize(
                cols: size.cols, rows: size.rows,
                cellWidthPx: UInt32(size.cellWidthPx), cellHeightPx: UInt32(size.cellHeightPx))
        } catch {
            logger.error("terminal resize failed: \(String(describing: error), privacy: .public)")
        }
        guard host.isAlive else { return }
        do { try host.pty.resize(size) } catch {
            logger.error("pty resize failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Pushes `size` to whichever session is visible. The view's `onGridResize` hook.
    public func resizeVisible(_ size: TerminalSize) {
        guard let visibleID, let host = sessions[visibleID], host.isAlive else { return }
        // The view already resized the *terminal* before calling back; only the pty is left.
        do { try host.pty.resize(size) } catch {
            logger.error("pty resize failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - close / discard

    /// Signals the child. The row stays: `close` is "hang up the shell", not "forget the session",
    /// and the snapshot on disk stays valid until `discard`.
    public func close(_ id: SessionID, signal: Int32 = SIGHUP) {
        guard let host = sessions[id] else { return }
        _ = host.pty.terminate(signal: signal)
    }

    /// Forgets the row entirely: cancels the event pump, drops the session, deletes its snapshot.
    ///
    /// The snapshot is deleted **whether or not the host holds the session**: a row restored from
    /// `state.json` that was never selected has a `.ghsnap` and no `HostSession`, and Remove on it
    /// must still take the file with it (M5.2). Part of the protocol since M5.2; design.md's
    /// `close` keeps the row resumable, so this is the only way to make one go away.
    public func discard(_ id: SessionID) {
        let wasVisible = visibleID == id
        evict(id)
        _ = try? snapshots.delete(id.rawValue)
        if wasVisible { show(order.last) }
    }

    public func savedSnapshot(_ id: SessionID) -> Data? {
        try? snapshots.load(id.rawValue)
    }

    /// Hangs up every shell and detaches the surface. Called from the window controller's
    /// `shutdown()`, i.e. on window close and on `applicationWillTerminate`.
    public func closeAll(signal: Int32 = SIGHUP) {
        view.show(nil)
        visibleID = nil
        for id in order {
            guard let host = sessions[id] else { continue }
            host.eventsTask?.cancel()
            _ = host.pty.terminate(signal: signal)
        }
        compressor?.stop()
        // `stop()` only parks the timer — the compressor's own `sessions` table still holds a
        // strong `TerminalSession` (and therefore its whole scrollback) per entry. `evict` drops
        // one; this is the same debt for all of them.
        for id in order { compressor?.forget(id.rawValue) }
        sessions.removeAll()
        order.removeAll()
    }

    // MARK: - snapshot / restore

    public func snapshot(_ id: SessionID) throws -> Data {
        guard let host = sessions[id] else { throw TerminalHostError.unknownSession(id.rawValue) }
        return try host.session.snapshot()
    }

    /// Rebuilds `id`'s content from `data` and spawns a **fresh** shell under it: the user sees the
    /// old scrollback with a new prompt below it, which is what design.md → *Session flows &
    /// persistence* asks for ("restore content and spawn a fresh shell").
    ///
    /// The size is not a parameter of the protocol, and it does not need to be: `restore(from:)`
    /// adopts the snapshot's own cols/rows, so the pty is spawned at exactly the size the terminal
    /// now reports. The next `show` re-applies the view's real grid.
    @discardableResult
    public func restore(
        _ id: SessionID, from data: Data, cwd: String, env: [String: String]
    ) throws -> pid_t {
        let grid = view.gridSizeForBounds()
        let session = try makeSession(size: grid)
        try session.restore(from: data)
        let restoredSize = session.size
        let size = TerminalSize(
            rows: restoredSize.rows, cols: restoredSize.cols,
            cellWidthPx: grid.cellWidthPx, cellHeightPx: grid.cellHeightPx)
        let pty = try spawn(id: id, session: session, cwd: cwd, env: env, size: size)
        let host = HostSession(id: id, session: session, pty: pty)
        host.wasRestored = true
        evict(id)
        adopt(host)
        return pty.pid
    }

    // MARK: Snapshot on quit / restore on launch

    public struct SnapshotSweep: Sendable, Equatable {
        public var saved: [String] = []
        public var skipped: [String] = []
        public var failed: [String] = []
        public var totalBytes: Int = 0
        /// Wall seconds for the whole sweep.
        public var elapsed: Double = 0
    }

    /// Writes every session's `.ghsnap`.
    ///
    /// A session the idle compressor already snapshotted, and which has not produced any
    /// compression-relevant activity since, is **skipped**: re-encoding it would walk its history
    /// and rehydrate the very pages compression just released (docs/perf.md → *rehydration is
    /// real*). `force: true` disables that and re-encodes everything.
    @discardableResult
    public func snapshotAll(force: Bool = false) -> SnapshotSweep {
        let start = ContinuousClock.now
        var sweep = SnapshotSweep()
        for id in order {
            // One pool per session, not one for the sweep: this runs on the main queue and each
            // iteration encodes up to a session's whole history and pushes it through
            // `FileManager`/`URL`. Without a pool per iteration, 30 sessions' worth of temporaries
            // — the `Data` copies included — are all held until the sweep returns.
            autoreleasepool {
                guard let host = sessions[id] else { return }
                let token = host.session.compressionActivity()
                if !force, let compressor, compressor.hasFreshSnapshot(id.rawValue, token: token) {
                    sweep.skipped.append(id.rawValue)
                    return
                }
                do {
                    let report = try snapshots.save(host.session.snapshot(), for: id.rawValue)
                    compressor?.noteSnapshotted(id.rawValue, token: token)
                    sweep.saved.append(id.rawValue)
                    sweep.totalBytes += report.byteCount
                } catch {
                    sweep.failed.append(id.rawValue)
                    logger.error("snapshot failed for \(id.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        let elapsed = ContinuousClock.now - start
        sweep.elapsed = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return sweep
    }

    public struct RestoreSweep: Sendable, Equatable {
        public var restored: [String] = []
        public var failed: [String] = []
        public var totalBytes: Int = 0
        public var elapsed: Double = 0
    }

    /// Restores every `.ghsnap` in the store, in id order, each with a fresh shell.
    @discardableResult
    public func restoreAll(cwd: String, env: [String: String] = [:]) -> RestoreSweep {
        let start = ContinuousClock.now
        var sweep = RestoreSweep()
        let entries = (try? snapshots.list()) ?? []
        for entry in entries {
            guard let id = SessionID(entry.id), sessions[id] == nil else { continue }
            do {
                let data = try snapshots.load(entry.id)
                _ = try restore(id, from: data, cwd: cwd, env: env)
                sweep.restored.append(entry.id)
                sweep.totalBytes += data.count
            } catch {
                sweep.failed.append(entry.id)
                logger.error("restore failed for \(entry.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        let elapsed = ContinuousClock.now - start
        sweep.elapsed = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return sweep
    }
}

// MARK: - TerminalIdleCompressor

/// The idle-compression timer: the *impure* half of `IdleCompressionPolicy`.
///
/// The policy decides **when**; this decides nothing and only supplies a clock, a timer, the
/// terminals, and the snapshot-before-compress ordering. It is `Sendable` because every piece of
/// mutable state lives behind a `Mutex` (shared agent brief, settled decision 1) — the timer fires
/// on a `.utility` queue, `noteActivity` is called from pty IO queues, and `setVisible` from the
/// main actor.
///
/// ## What a tick does
///
///   1. Poll `ghostty_terminal_compression_activity` for every tracked session and feed it to
///      `noteActivityToken`. A changed token restarts the idle delay, exactly as `terminal.h`
///      prescribes; an unchanged one costs one locked read.
///   2. For each session the policy calls due: snapshot it to disk (if a `saveSnapshot` hook was
///      given and the token moved since the last save), then loop `compress(INCREMENTAL)` until it
///      reports COMPLETE or the step budget runs out.
///   3. Feed the result back with `noteStep`.
///
/// The whole of step 2 happens under **that session's** lock. The visible session is never due, so
/// the render tick's `begin_update` never contends with a compression pass — which is the one
/// property this design has to have (see docs/perf.md → *frame pacing*).
public final class TerminalIdleCompressor: Sendable {
    /// Bookkeeping the timer thread owns.
    private struct State {
        var policy: IdleCompressionPolicy
        var sessions: [String: TerminalSession] = [:]
        /// The last activity token this compressor *observed*, including the one its own pass
        /// produced. Owning the comparison here rather than in the policy is what stops a
        /// compression pass from looking like user activity: the pass moves the token, and
        /// feeding that straight to `noteActivityToken` would restart the idle delay forever.
        var tokens: [String: UInt64] = [:]
        /// The activity token each session was last snapshotted at.
        var snapshotTokens: [String: UInt64] = [:]
        var running = false
        // Diagnostics.
        var ticks = 0
        var steps = 0
        var passes = 0
        var snapshotsWritten = 0
        var compressSeconds: Double = 0
        var maxPassSeconds: Double = 0
    }

    private let state: Mutex<State>
    private let queue: DispatchQueue
    private let timer: any DispatchSourceTimer
    /// How many INCREMENTAL steps one tick may spend on one session before yielding.
    private let stepBudget: Int
    /// Called before a session is compressed, on the timer queue. Returns the bytes written.
    private let saveSnapshot: (@Sendable (String, TerminalSession) -> Int)?
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "compress")

    /// - Parameters:
    ///   - policy: the pure rule. Its `stepInterval` is *not* the tick interval: a due session is
    ///     taken all the way to COMPLETE inside one tick, because a step is ~66 µs and a whole
    ///     20 000-row session is ~3.8 ms (docs/perf.md), so waiting a second between steps would
    ///     take a minute per session for no benefit.
    ///   - tickInterval: how often the timer wakes at all.
    ///   - stepBudget: hard cap on steps per session per tick, so a pathological session cannot
    ///     hold its own lock for an unbounded time.
    ///   - saveSnapshot: snapshot-before-compress hook. Nil disables it.
    public init(
        policy: IdleCompressionPolicy = IdleCompressionPolicy(
            idleThreshold: .seconds(60), stepInterval: .milliseconds(0)),
        tickInterval: Duration = .seconds(5),
        stepBudget: Int = 4096,
        queue: DispatchQueue? = nil,
        saveSnapshot: (@Sendable (String, TerminalSession) -> Int)? = nil
    ) {
        self.state = Mutex(State(policy: policy))
        self.stepBudget = stepBudget
        self.saveSnapshot = saveSnapshot
        let queue = queue ?? DispatchQueue(label: "tkzmux.compress", qos: .utility)
        self.queue = queue
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let seconds = Double(tickInterval.components.seconds)
            + Double(tickInterval.components.attoseconds) / 1e18
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(500))
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.tick() }
    }

    deinit {
        timer.cancel()
        // Releasing a *suspended* dispatch source traps. `makeTimerSource` hands one back
        // suspended and `stop()` suspends again, so balance the count before the object dies;
        // resuming a cancelled source only decrements the suspend count.
        if !state.withLock({ $0.running }) { timer.resume() }
    }

    // MARK: Lifecycle

    public func start() {
        let shouldResume = state.withLock { state -> Bool in
            guard !state.running else { return false }
            state.running = true
            return true
        }
        if shouldResume { timer.resume() }
    }

    public func stop() {
        let shouldSuspend = state.withLock { state -> Bool in
            guard state.running else { return false }
            state.running = false
            return true
        }
        if shouldSuspend { timer.suspend() }
    }

    public func register(_ id: String, session: TerminalSession, isVisible: Bool) {
        let token = session.compressionActivity()
        state.withLock { state in
            state.sessions[id] = session
            state.tokens[id] = token
            state.policy.register(id, at: .now, activityToken: token, isVisible: isVisible)
        }
    }

    public func forget(_ id: String) {
        state.withLock { state in
            state.sessions.removeValue(forKey: id)
            state.tokens.removeValue(forKey: id)
            state.snapshotTokens.removeValue(forKey: id)
            state.policy.forget(id)
        }
    }

    /// Called from pty IO queues and from the main actor. Cheap: one lock, one dictionary write.
    public func noteActivity(_ id: String) {
        state.withLock { $0.policy.noteActivity(id, at: .now) }
    }

    public func setVisible(_ id: String, _ isVisible: Bool) {
        state.withLock { $0.policy.noteVisibility(id, isVisible: isVisible, at: .now) }
    }

    /// True when `id`'s on-disk snapshot was taken at `token`, i.e. nothing compression-relevant
    /// has happened since and re-encoding would only rehydrate history.
    public func hasFreshSnapshot(_ id: String, token: UInt64) -> Bool {
        state.withLock { $0.snapshotTokens[id] == token }
    }

    public func noteSnapshotted(_ id: String, token: UInt64) {
        state.withLock { $0.snapshotTokens[id] = token }
    }

    // MARK: Diagnostics

    public struct Stats: Sendable, Equatable {
        public var tracked: Int
        public var ticks: Int
        public var passes: Int
        public var steps: Int
        public var snapshotsWritten: Int
        public var compressSeconds: Double
        /// The longest single session's compression pass. This is the number that would show up as
        /// a stall *if* the visible session were ever compressed — it never is.
        public var maxPassSeconds: Double
    }

    /// Whether the timer is armed. A compressor that exists but was never `start()`ed compresses
    /// nothing, which looks exactly like not having one — so this is worth being able to assert.
    public var isRunning: Bool { state.withLock { $0.running } }

    public var stats: Stats {
        state.withLock {
            Stats(
                tracked: $0.sessions.count, ticks: $0.ticks, passes: $0.passes, steps: $0.steps,
                snapshotsWritten: $0.snapshotsWritten, compressSeconds: $0.compressSeconds,
                maxPassSeconds: $0.maxPassSeconds)
        }
    }

    /// Runs one tick synchronously. The timer calls this; tests call it directly so nothing has to
    /// wait 60 seconds.
    public func tick(now: ContinuousClock.Instant = .now) {
        // 1. Poll activity tokens and ask the policy who is due — all under one lock, so the
        //    decision is taken against a consistent snapshot of the world.
        let due: [(id: String, session: TerminalSession)] = state.withLock { state in
            state.ticks += 1
            for (id, session) in state.sessions {
                let token = session.compressionActivity()
                guard state.tokens[id] != token else { continue }
                state.tokens[id] = token
                state.policy.noteActivity(id, at: now)
            }
            return state.policy.due(at: now).compactMap { id in
                state.sessions[id].map { (id, $0) }
            }
        }
        guard !due.isEmpty else { return }

        for (id, session) in due {
          // One pool per session: `saveSnapshot` below encodes a whole history and writes it
          // through `FileManager`, and this runs on the compressor's own `.utility` queue where a
          // single pool would otherwise hold every session's temporaries until the tick ends.
          autoreleasepool {
            // 2. Snapshot *before* compressing: reading history back rehydrates it.
            if let saveSnapshot {
                let token = session.compressionActivity()
                let alreadyFresh = state.withLock { $0.snapshotTokens[id] == token }
                if !alreadyFresh {
                    let bytes = saveSnapshot(id, session)
                    if bytes > 0 {
                        state.withLock {
                            $0.snapshotTokens[id] = token
                            $0.snapshotsWritten += 1
                        }
                    }
                }
            }

            // 3. Take it all the way to COMPLETE, bounded. Each `compress` call takes and releases
            //    that session's lock, so the loop is interruptible by its own pty IO.
            let start = ContinuousClock.now
            var steps = 0
            var pending = true
            while pending, steps < stepBudget {
                pending = session.compress()
                steps += 1
            }
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

            state.withLock { state in
                state.steps += steps
                state.passes += 1
                state.compressSeconds += seconds
                state.maxPassSeconds = max(state.maxPassSeconds, seconds)
                state.policy.noteStep(id, result: pending ? .pending : .complete, at: .now)
                // Re-read the token and record it as *observed*, without telling the policy
                // anything. `terminal.h` does not say whether a compression pass moves the
                // activity token; measured on 29 sessions it did not. Owning the comparison here
                // means it cannot matter either way — if a future version did move it, a naive
                // `noteActivityToken` would read the pass as user activity, restart the idle
                // delay, and re-snapshot (i.e. rehydrate) the session on every cycle.
                state.tokens[id] = session.compressionActivity()
            }
          }
        }
    }
}

// MARK: - Process metrics

/// A point-in-time reading of what this process costs the machine.
///
/// A deliberate duplicate of the sampler in `tkzmux-vtdump/BenchCommands.swift`: `TkzApp` does not
/// depend on that executable and the numbers in docs/perf.md have to come from the *app* process,
/// not from a benchmark binary. Both must stay identical — same fields, same flavours — or the two
/// halves of docs/perf.md stop being comparable.
///
/// `phys_footprint` is the field that matters. `resident_size` keeps `MADV_FREE`'d pages until the
/// kernel needs them, which is exactly how the M1.3 spike concluded that compression reclaimed
/// nothing (docs/perf.md → *Does compression pay?*).
public struct HostProcessMetrics: Sendable {
    public var residentBytes: UInt64
    public var footprintBytes: UInt64
    public var reusableBytes: UInt64
    public var compressedBytes: UInt64
    public var threadCount: Int
    public var cpuSeconds: Double
    public var wallSeconds: Double

    public static func sample() -> HostProcessMetrics {
        let vm = hostVMInfo()
        return HostProcessMetrics(
            residentBytes: hostResidentBytes(),
            footprintBytes: vm.footprint,
            reusableBytes: vm.reusable,
            compressedBytes: vm.compressed,
            threadCount: hostThreadCount(),
            cpuSeconds: hostCPUSeconds(),
            wallSeconds: Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
    }

    /// CPU as a percentage of one core over the interval since `earlier`.
    public func cpuPercent(since earlier: HostProcessMetrics) -> Double {
        let wall = wallSeconds - earlier.wallSeconds
        guard wall > 0 else { return 0 }
        return (cpuSeconds - earlier.cpuSeconds) / wall * 100
    }
}

private func hostResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

private func hostVMInfo() -> (footprint: UInt64, reusable: UInt64, compressed: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0, 0) }
    return (UInt64(info.phys_footprint), UInt64(info.reusable), UInt64(info.compressed))
}

/// Every port `task_threads` returns must be deallocated, and the array `vm_deallocate`d — leaking
/// them inflates every later reading of this same process.
private func hostThreadCount() -> Int {
    var threads: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
    for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
    vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    return Int(count)
}

private func hostCPUSeconds() -> Double {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    if result == 0 { return Double(info.ri_user_time + info.ri_system_time) / 1e9 }
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}
