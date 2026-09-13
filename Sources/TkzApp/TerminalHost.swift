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
// ## The invariant this type exists to hold: an unattached terminal costs only IO
//
// Until TKZ-36 this was stated as "there is exactly one `TerminalSurface`". That is no longer
// true — a session with split panes puts several terminals on screen at once, each with its own
// surface — but the property that mattered is untouched, and it is the *cost* one, not the count.
// A terminal is attached to a surface only while it is on screen; `show(_:)` detaches every
// terminal that is not in the new attachment map before attaching the ones that are. An unattached
// terminal therefore has:
//
//   * no render state, no glyph rows, no atlas positions — `TerminalSurface.detach` frees all of it;
//   * no render signal — `TerminalMetalView.show` clears the outgoing session's `renderSignal`, so
//     a background terminal that produces megabytes calls nothing and can wake no display link;
//   * one serial `DispatchQueue` (not a thread) for its pty reads, and nothing else.
//
// So the bill is per **attached** terminal, and the app attaches exactly what is on screen: the
// selected row's active tab, or its zoomed pane alone. `TerminalHostTests` asserts each of those
// across 30 terminals rather than trusting the prose.
//
// ## Terminals, not sessions
//
// The host is keyed by `TerminalID` — one pty, one VT, one `.ghsnap`. A `SessionID` is a *row*,
// and a row owns one or more terminals. `open` and `restore` therefore take both: the terminal
// they are creating, and the row it belongs to, because the row's id is what goes into the child's
// `TKZMUX_SESSION_ID` and so what the shim, the hook relay and ClaudeBridge correlate on. Every
// pane of a row is one row to them, by design.
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

// MARK: - The surface seam

/// What the host needs from the thing a terminal is drawn into.
///
/// `TerminalMetalView` satisfies this already — every member below exists on it with exactly this
/// signature, so the conformance is an empty extension. The protocol exists so the host can hold N
/// of them without naming an `NSView` a headless test cannot build: the whole `TkzAppTests` suite
/// runs with no GPU, and a spy surface is four members.
@MainActor
public protocol TerminalPaneSurface: AnyObject {
    /// Attaches `session` to this surface, or detaches whatever was there when nil.
    func show(_ session: TerminalSession?)
    /// A dead terminal keeps its screen but must stop blinking a cursor at the user.
    func setCursorSuppressed(_ suppressed: Bool)
    /// How many cells fit at the surface's current size.
    func gridSizeForBounds() -> TerminalSize
    /// Called when the surface's grid changed. The host installs this on attach so the pty follows
    /// its own pane, and clears it on detach.
    var onGridResize: ((TerminalSize) -> Void)? { get set }
}

extension TerminalMetalView: TerminalPaneSurface {}

// MARK: - TerminalHost

/// What the app half may ask of the terminal half. Nothing above this line knows about libghostty,
/// ptys or Metal; nothing below it knows about the sidebar.
///
/// `@MainActor` is not in design.md's listing but is required: the implementation owns an `NSView`.
@MainActor
public protocol TerminalHost: AnyObject {
    /// Spawns a login shell for the terminal `id` and returns its pid.
    ///
    /// `session` is the **row** the terminal belongs to. It becomes `TKZMUX_SESSION_ID`, so two
    /// panes of one row are one row to the shim and the hook relay. It cannot be smuggled through
    /// `env`: `TerminalEnvironment.make` writes the tkzmux variables last, over anything a caller
    /// passed.
    func open(
        _ id: TerminalID, session: SessionID, cwd: String, env: [String: String],
        size: TerminalSize
    ) throws -> pid_t
    /// Types `command` followed by `\r` into the terminal's pty.
    func run(_ id: TerminalID, command: String)
    /// Raw host input (encoded keys, a mouse report, a paste) for **one addressed terminal**.
    ///
    /// Never "the visible one": with several panes on screen there is no such thing, and routing
    /// by visibility would type the unfocused pane's keystrokes into the focused pane's shell.
    func writeInput(_ id: TerminalID, _ data: Data)
    /// Attaches each terminal to its surface, and detaches every terminal that is attached now but
    /// absent from `attachments`. `[:]` shows nothing, so the whole visible set is one call.
    func show(_ attachments: [TerminalID: any TerminalPaneSurface])
    /// The terminals actually attached to a surface. Not derivable from the store's selection: a
    /// row restored from `state.json` (M5.1) is selectable long before it has a terminal, and the
    /// window shows its empty state rather than a blank grid for exactly this reason.
    var visibleTerminalIDs: Set<TerminalID> { get }
    func resize(_ id: TerminalID, _ size: TerminalSize)
    /// Signals the child (SIGHUP by default). The terminal stays resumable.
    func close(_ id: TerminalID, signal: Int32)
    /// The `.ghsnap` bytes for `id`.
    func snapshot(_ id: TerminalID) throws -> Data
    /// Rebuilds `id` from a snapshot and spawns a fresh shell under it. Returns the new pid.
    /// An id the host still holds (a hung-up terminal whose grid is kept) is replaced.
    func restore(
        _ id: TerminalID, session: SessionID, from: Data, cwd: String, env: [String: String]
    ) throws -> pid_t
    /// The `.ghsnap` on disk for `id`, if one was saved — what a row restored from `state.json`
    /// comes back from (M5.2). Not the live grid: that is `snapshot(_:)`.
    func savedSnapshot(_ id: TerminalID) -> Data?
    /// **Remove**: forgets the terminal entirely — hangs it up if alive, drops its grid, deletes
    /// its snapshot on disk. The one call that makes a terminal unresumable.
    func discard(_ id: TerminalID)
    /// Does the host hold a terminal under `id`? The lazy-restore paths ask before spawning, so
    /// it has to be reachable through the existential, not only on `TerminalViewHost`.
    func contains(_ id: TerminalID) -> Bool
    /// Every terminal's events, tagged.
    var events: AsyncStream<(TerminalID, TerminalEvent)> { get }
}

public enum TerminalHostError: Error, Equatable, Sendable {
    case unknownSession(String)
    case sessionNotAlive(String)
}

// MARK: - One live session

/// One spawned shell: its VT, its pty, and the task draining its event stream.
@MainActor
final class HostSession {
    let id: TerminalID
    /// The row this terminal belongs to. Needed on the way back out: `.exited` has to be told to
    /// the right row, and a re-spawn has to re-export the same `TKZMUX_SESSION_ID`.
    let sessionID: SessionID
    let session: TerminalSession
    private(set) var pty: Pty
    /// The shell's name until the shell sets a title of its own.
    var title: String
    var isAlive = true
    var eventsTask: Task<Void, Never>?
    /// Set when the session's content came from a `.ghsnap` at launch.
    var wasRestored = false

    init(id: TerminalID, sessionID: SessionID, session: TerminalSession, pty: Pty, title: String) {
        self.id = id
        self.sessionID = sessionID
        self.session = session
        self.pty = pty
        self.title = title
    }

    deinit { eventsTask?.cancel() }
}

// MARK: - TerminalViewHost

/// `TerminalHost` over N `TerminalPaneSurface`s sharing one render context.
///
/// Everything injectable is injected for one reason: a test must never write to
/// `~/Library/Application Support/tkzmux` and must never inherit the developer's environment
/// (shared agent brief, hard rule 8). `snapshots` and `tkzmuxDirectory` both default to the real
/// locations, and both are overridden by `DevWindowController`'s harness env vars.
@MainActor
public final class TerminalViewHost: TerminalHost {
    /// The app-wide font set / atlas / renderer owner. The host needs it for one thing —
    /// `makeSession` themes a new VT from it — and holding the context rather than a view is what
    /// lets the host outlive, and out-number, any individual pane.
    public let renderContext: TerminalRenderContext
    /// The grid to spawn a terminal at when it has no surface yet: a pane created behind a
    /// background tab, or a restore that happens before the container has laid out.
    public var defaultGrid: () -> TerminalSize
    public let snapshots: SnapshotStore
    /// tkzmux's application-support directory — `ZDOTDIR`, `TKZMUX_BIN`, the socket.
    public let tkzmuxDirectory: URL
    /// The login shell every session runs (TKZ-33): `SHELL` from `baseEnvironment`, then the
    /// account database, then `/bin/zsh`. Decided once; a `chsh` takes effect at the next launch.
    public let shell: LoginShell
    /// What a session's environment is built on top of.
    public let baseEnvironment: [String: String]

    private var sessions: [TerminalID: HostSession] = [:]
    /// Insertion order, for a stable sweep order in `snapshotAll` and `closeAll`.
    public private(set) var order: [TerminalID] = []
    /// Terminal → the surface it is attached to. The keys are the visible set.
    public private(set) var visible: [TerminalID: any TerminalPaneSurface] = [:]

    private let continuation: AsyncStream<(TerminalID, TerminalEvent)>.Continuation
    public let events: AsyncStream<(TerminalID, TerminalEvent)>

    /// The idle-compression timer, or nil when compression is disabled.
    public let compressor: TerminalIdleCompressor?

    /// Called after `show(_:)` completed, so the owner can re-push things the view cannot know
    /// about (the mouse controller's pixel geometry, the window title).
    public var onDidShow: ((Set<TerminalID>) -> Void)?

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
        renderContext: TerminalRenderContext,
        defaultGrid: @escaping () -> TerminalSize = { TerminalSize(rows: 40, cols: 120) },
        snapshots: SnapshotStore = .standard(),
        tkzmuxDirectory: URL? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        compressor: TerminalIdleCompressor? = nil
    ) {
        self.renderContext = renderContext
        self.defaultGrid = defaultGrid
        self.snapshots = snapshots
        self.tkzmuxDirectory = tkzmuxDirectory
            ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "tkzmux", directoryHint: .isDirectory)
            ?? URL(filePath: NSTemporaryDirectory()).appending(path: "tkzmux", directoryHint: .isDirectory)
        self.baseEnvironment = baseEnvironment
        self.shell = LoginShell.detect(environment: baseEnvironment)
        self.compressor = compressor
        TerminalViewHost.createShellDirectory(in: self.tkzmuxDirectory)
        var escapee: AsyncStream<(TerminalID, TerminalEvent)>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { escapee = $0 }
        self.continuation = escapee
    }

    deinit { continuation.finish() }

    /// Creates the `ZDOTDIR` the spawned zsh shells are pointed at. zsh only: bash and fish are
    /// started without their wrapper when it is missing (`LoginShell.argv`), and need no directory.
    ///
    /// `TerminalEnvironment.make` sets `ZDOTDIR` to `<tkzmuxDirectory>/zsh` for every zsh, and
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
    public var sessionIDs: [TerminalID] { order }
    public func contains(_ id: TerminalID) -> Bool { sessions[id] != nil }
    public func isAlive(_ id: TerminalID) -> Bool { sessions[id]?.isAlive ?? false }
    public func pid(of id: TerminalID) -> pid_t? { sessions[id]?.pty.pid }
    public func title(of id: TerminalID) -> String? { sessions[id]?.title }
    public func wasRestored(_ id: TerminalID) -> Bool { sessions[id]?.wasRestored ?? false }
    /// The row a terminal belongs to, as the host was told at `open`.
    public func owner(of id: TerminalID) -> SessionID? { sessions[id]?.sessionID }
    /// The `TerminalSession` behind `id`. Exposed so the window controller can push mouse geometry
    /// and so tests can assert on the VT directly.
    public func session(for id: TerminalID) -> TerminalSession? { sessions[id]?.session }

    /// Re-themes the render context and every live terminal — the terminal half of the ☾/☀ toggle.
    ///
    /// Order matters: the context first, so a session opened between the two lines still picks the
    /// new theme up from `renderContext.theme` in `makeSession`. Every session is re-themed, not
    /// just the attached ones: the alternative is a lazy re-theme on attach, which flashes the old
    /// colours for a frame on every tab switch. The repaint itself rides `TerminalSession.setTheme`'s
    /// render signal, so only attached panes actually draw.
    public func setTheme(_ theme: Theme) {
        guard theme != renderContext.theme else { return }
        renderContext.theme = theme
        for id in order {
            do {
                try sessions[id]?.session.setTheme(theme)
            } catch {
                logger.error(
                    "re-theme failed for \(id.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The size last pushed to the pty — what the shell sees as `TIOCGWINSZ`. Tests only: the
    /// view's grid and the VT's size can agree while the pty still disagrees with both.
    func ptySize(for id: TerminalID) -> TerminalSize? { sessions[id]?.pty.size }

    /// The terminal a surface currently holds — how the input path turns "the view that got the
    /// key event" into "the pty to write to".
    public func terminalID(forSurface surface: any TerminalPaneSurface) -> TerminalID? {
        visible.first { $0.value === surface }?.key
    }
    /// Retained scrollback rows per session, in `order`. Diagnostics: it is the only way to say
    /// what a harness corpus actually built up rather than what it was asked to build up.
    public func scrollbackRows() -> [Int] { order.compactMap { sessions[$0]?.session.scrollbackRows } }

    /// Per-session memory held by the *spawned processes* — the shell, Claude Code, and whatever
    /// those started — in `order`. This is the number the app's own `HostProcessMetrics` cannot
    /// see and that Activity Monitor blames on us anyway; see `SessionMemory`.
    ///
    /// One `proc_pid_rusage` syscall per process in each tree, so call it on a slow timer.
    public func sessionMemory() -> [(id: TerminalID, sample: SessionMemorySample)] {
        sessionPids().map { ($0.id, SessionMemory.sample(rootPid: $0.pid)) }
    }

    /// Just the root pids, in `order` — everything `sessionMemory()` needs from the main actor and
    /// nothing that it does with them.
    ///
    /// Sampling walks each tree with `proc_listchildpids` (a system-wide scan per node) and one
    /// `proc_pid_rusage` per process. Handing the pids out lets the caller do that off the main
    /// thread and come back with the answers, which is what the once-a-minute status tick does.
    public func sessionPids() -> [(id: TerminalID, pid: pid_t)] {
        order.compactMap { id in
            guard let pid = sessions[id]?.pty.pid, pid > 0 else { return nil }
            return (id, pid)
        }
    }

    // MARK: - open

    /// Spawns the login shell for `id` under the full tkzmux environment.
    ///
    /// `env` is applied as **overrides on top of `baseEnvironment`**, before
    /// `TerminalEnvironment.make` gets its hands on it — so a caller can set `CLAUDE_CONFIG_DIR`
    /// or a working `PATH` without being able to break `TERM` / `TERMINFO` / `TKZMUX_*`, which
    /// `make` always writes last.
    @discardableResult
    public func open(
        _ id: TerminalID, session sessionID: SessionID, cwd: String, env: [String: String],
        size: TerminalSize
    ) throws -> pid_t {
        let session = try makeSession(size: size)
        let pty = try spawn(
            sessionID: sessionID, session: session, cwd: cwd, env: env, size: size)
        evict(id)
        adopt(HostSession(id: id, sessionID: sessionID, session: session, pty: pty, title: shell.name))
        return pty.pid
    }

    /// Drops a session the host still holds under `id` so a new one can take its place — the
    /// Resume-after-⌘W case, where the dead grid is kept on screen until the row is reopened.
    /// Unlike `discard`, the snapshot on disk is left alone: it is what the reopen restores from.
    /// Without this, `adopt` would overwrite `sessions[id]`, append `id` to `order` a second time
    /// and leave the old event pump running against a session nothing references.
    private func evict(_ id: TerminalID) {
        guard let host = sessions.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        host.eventsTask?.cancel()
        host.session.finishEvents()
        if host.isAlive { _ = host.pty.terminate(signal: SIGHUP) }
        compressor?.forget(id.rawValue)
        detach(id)
    }

    /// Frees whatever surface `id` was attached to, if any.
    private func detach(_ id: TerminalID) {
        guard let surface = visible.removeValue(forKey: id) else { return }
        surface.onGridResize = nil
        surface.show(nil)
    }

    /// A `TerminalSession` sized for the grid, themed from the view's render context.
    private func makeSession(size: TerminalSize) throws -> TerminalSession {
        let session = try TerminalSession(
            options: TerminalSessionOptions(
                cols: max(1, size.cols),
                rows: max(1, size.rows),
                cellWidthPx: UInt32(size.cellWidthPx),
                cellHeightPx: UInt32(size.cellHeightPx),
                theme: renderContext.theme),
            label: "tkzmux.session.\(sessions.count)")
        // Repeat-click detection is otherwise dead: libghostty compares timestamps against this
        // interval and `TkzTerminalCore` cannot read AppKit's copy of it.
        session.selectionDoubleClickInterval = NSEvent.doubleClickInterval
        return session
    }

    private func spawn(
        sessionID: SessionID, session: TerminalSession, cwd: String, env: [String: String],
        size: TerminalSize
    ) throws -> Pty {
        // The **row's** id, not the terminal's: every pane of a row must look like one row to the
        // shim, the hook relay and ClaudeBridge (TKZ-36).
        let spawn = TerminalEnvironment.loginShellSpawn(
            sessionID: sessionID.rawValue,
            cwd: cwd,
            size: size,
            tkzmuxDir: tkzmuxDirectory,
            baseEnvironment: baseEnvironment.merging(env) { _, override in override },
            shell: shell)

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
        compressor?.register(id.rawValue, session: session, isVisible: visible[id] != nil)
    }

    /// The host's own reaction to an event. Everything else is the consumer's business.
    private func observe(_ event: TerminalEvent, for id: TerminalID) {
        switch event {
        case .title(let title):
            sessions[id]?.title = title.isEmpty ? shell.name : title
        case .exited:
            sessions[id]?.isAlive = false
            // A dead terminal keeps its screen but must stop blinking a cursor at the user.
            visible[id]?.setCursorSuppressed(true)
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
    public func run(_ id: TerminalID, command: String) {
        guard let host = sessions[id], host.isAlive else { return }
        let data = Data(command.utf8) + Data([0x0D])
        let pty = host.pty
        for chunk in TerminalViewHost.chunkForCanonicalTty(data) {
            host.session.ioQueue.async { try? pty.write(chunk) }
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

    /// Raw host input (encoded keys, a mouse report, a paste) for one addressed terminal.
    ///
    /// This used to route to whichever terminal was visible. With several panes on screen that is
    /// not merely imprecise, it is wrong: the unfocused pane's keystrokes would reach the focused
    /// pane's shell. The caller resolves the pane — `TerminalInputController` already knows which
    /// view produced the event — and says so here.
    public func writeInput(_ id: TerminalID, _ data: Data) {
        guard !data.isEmpty, let host = sessions[id], host.isAlive else { return }
        let pty = host.pty
        host.session.ioQueue.async { try? pty.write(data) }
        compressor?.noteActivity(id.rawValue)
    }

    // MARK: - show

    public var visibleTerminalIDs: Set<TerminalID> { Set(visible.keys) }

    /// Makes `attachments` exactly the visible set: everything attached now and absent from the map
    /// is detached first, everything in it is attached — except a terminal that is already on the
    /// surface the map gives it, which is left exactly as it is.
    ///
    /// Detaching before attaching is not cosmetic. Both halves take drawables from a small pool,
    /// and a terminal that is moving from one surface to another (a pane that changed place in the
    /// tree) must not be attached twice even for an instant — `TerminalSession.renderSignal` is a
    /// single closure, so the second attach would silently orphan the first surface's wake-ups.
    ///
    /// The whole call is one `os_signpost` interval (`show`), and its wall time is also recorded in
    /// `showDurations` so the distribution can be printed without Instruments. The budget is one
    /// frame at 120 Hz: 8.3 ms.
    public func show(_ attachments: [TerminalID: any TerminalPaneSurface]) {
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("show", id: signpostID)
        let start = ContinuousClock.now

        let previous = Set(visible.keys)
        for id in previous where attachments[id] == nil { detach(id) }
        // A terminal already attached to a *different* surface has to let go of the old one first.
        for (id, surface) in attachments where visible[id] !== surface { detach(id) }

        for (id, surface) in attachments {
            guard let host = sessions[id] else { continue }
            // The pty follows its own pane. This is why `resizeVisible` is gone: with N panes
            // "the visible one" names nothing, and the hook belongs where the pairing is known.
            //
            // Installed **before** `show`: attaching ends with a forced grid resize that fires this
            // hook, and a hook installed afterwards misses it. Then the VT is sized to the pane
            // while the pty keeps its spawn size, and the shell redraws its prompt against the
            // wrong grid until the pane's bounds happen to change again.
            surface.onGridResize = { [weak self] size in self?.resize(id, size) }
            // Already on this very surface: nothing to attach. A re-attach is a `DIRTY_FULL` and a
            // forced resize of a pane the user did not touch, and every layout delivery — a focus
            // change, a divider drag — comes through here.
            if visible[id] !== surface {
                surface.show(host.session)
            }
            // `show` resets the flag, so re-apply it: coming back to an already-dead terminal must
            // not resurrect its cursor.
            surface.setCursorSuppressed(!host.isAlive)
            visible[id] = surface
        }

        let elapsed = ContinuousClock.now - start
        showDurations.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        if showDurations.count > TerminalViewHost.maxShowDurations {
            showDurations.removeFirst(showDurations.count - TerminalViewHost.maxShowDurations)
        }
        signposter.endInterval("show", interval)

        let now = Set(visible.keys)
        if previous != now { compressor?.setVisible(Set(now.map(\.rawValue))) }
        onDidShow?(now)
    }

    /// The one-pane spelling, for the many callers that show a single terminal.
    public func show(_ id: TerminalID?, on surface: any TerminalPaneSurface) {
        show(id.map { [$0: surface] } ?? [:])
    }

    public func resetShowDurations() { showDurations.removeAll(keepingCapacity: true) }

    // MARK: - resize

    /// Resizes both halves.
    ///
    /// Every path comes here now, including an attached pane's own `onGridResize`. The view has
    /// already resized the *terminal* by then, so the `session.resize` below is redundant on that
    /// path — but it is idempotent inside libghostty, and one entry point that is always correct
    /// beats two that differ in what they assume about the caller.
    public func resize(_ id: TerminalID, _ size: TerminalSize) {
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

    // MARK: - close / discard

    /// Signals the child. The row stays: `close` is "hang up the shell", not "forget the session",
    /// and the snapshot on disk stays valid until `discard`.
    public func close(_ id: TerminalID, signal: Int32 = SIGHUP) {
        guard let host = sessions[id] else { return }
        _ = host.pty.terminate(signal: signal)
    }

    /// Forgets the row entirely: cancels the event pump, drops the session, deletes its snapshot.
    ///
    /// The snapshot is deleted **whether or not the host holds the session**: a row restored from
    /// `state.json` that was never selected has a `.ghsnap` and no `HostSession`, and Remove on it
    /// must still take the file with it (M5.2). Part of the protocol since M5.2; design.md's
    /// `close` keeps the row resumable, so this is the only way to make one go away.
    /// It does **not** put something else on screen in place of a discarded visible terminal.
    /// It used to, when there was one surface and one visible session; with a store-driven window
    /// that is wrong — `MainWindowController.applySelection` decides what is visible, and quietly
    /// attaching whatever happened to be last would fight it.
    public func discard(_ id: TerminalID) {
        evict(id)
        _ = try? snapshots.delete(id.rawValue)
    }

    public func savedSnapshot(_ id: TerminalID) -> Data? {
        try? snapshots.load(id.rawValue)
    }

    /// Hangs up every shell and detaches the surface. Called from the window controller's
    /// `shutdown()`, i.e. on window close and on `applicationWillTerminate`.
    public func closeAll(signal: Int32 = SIGHUP) {
        for id in Array(visible.keys) { detach(id) }
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

    public func snapshot(_ id: TerminalID) throws -> Data {
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
        _ id: TerminalID, session sessionID: SessionID, from data: Data, cwd: String,
        env: [String: String]
    ) throws -> pid_t {
        // A restore can happen before the pane it belongs to has a surface — a background tab, or
        // a reopen that runs before the container laid out — so the cell metrics come from the
        // host's default grid rather than from a view that may not exist yet.
        let grid = visible[id]?.gridSizeForBounds() ?? defaultGrid()
        let session = try makeSession(size: grid)
        try session.restore(from: data)
        let restoredSize = session.size
        let size = TerminalSize(
            rows: restoredSize.rows, cols: restoredSize.cols,
            cellWidthPx: grid.cellWidthPx, cellHeightPx: grid.cellHeightPx)
        let pty = try spawn(
            sessionID: sessionID, session: session, cwd: cwd, env: env, size: size)
        let host = HostSession(
            id: id, sessionID: sessionID, session: session, pty: pty, title: shell.name)
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

    /// The periodic sweep: encode on the main queue, write off it.
    ///
    /// The encode has to happen here — it reads the terminal under its lock — but the write is a
    /// temp file, an `fsync` and a rename, and none of that needs the main thread. The unskipped
    /// sweep was measured at 58.8 ms for 30 sessions (docs/perf.md → *Snapshot on quit*), roughly
    /// half of it in the write, and it runs every five minutes while the user is looking at the
    /// window.
    ///
    /// Quit keeps using `snapshotAll` instead: there the process is about to go away and a write
    /// parked on another queue might never land.
    /// - Note: the encode loop lives in `encodeForSweep()` rather than inline. Swift 6.2.1 crashes
    ///   in `ClosureLifetimeFixup` when `autoreleasepool`'s non-escaping closure shares a function
    ///   body with the escaping `async` closures below; keeping them in separate functions is the
    ///   workaround, and the split reads fine on its own terms.
    public func snapshotAllOffMain(
        completion: @escaping @Sendable (SnapshotSweep) -> Void = { _ in }
    ) {
        let start = ContinuousClock.now
        let encoded = encodeForSweep()
        var sweep = encoded.sweep
        guard !encoded.pending.isEmpty else {
            sweep.elapsed = Self.seconds(since: start)
            completion(sweep)
            return
        }
        let writes = encoded.pending
        // A `let` copy: the `var` above cannot cross into the write queue's closure (Swift 6.3
        // rejects it as a data race even though nothing mutates it past this point).
        let encodedSweep = sweep
        let store = snapshots
        let logger = logger
        Self.snapshotWriteQueue.async {
            var saved: [(id: String, token: UInt64, bytes: Int)] = []
            var failed: [String] = []
            for write in writes {
                autoreleasepool {
                    do {
                        let report = try store.save(write.data, for: write.id)
                        saved.append((write.id, write.token, report.byteCount))
                    } catch {
                        failed.append(write.id)
                        logger.error("snapshot write failed for \(write.id, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            }
            let done = saved
            let lost = failed
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Recorded only for writes that actually landed: the token doubles as the
                    // dirty flag quit reads, so marking a failed write fresh would make quit skip
                    // a session whose `.ghsnap` was never written.
                    for entry in done { self.compressor?.noteSnapshotted(entry.id, token: entry.token) }
                    var finished = encodedSweep
                    finished.saved = done.map(\.id)
                    finished.totalBytes = done.reduce(0) { $0 + $1.bytes }
                    finished.failed.append(contentsOf: lost)
                    finished.elapsed = Self.seconds(since: start)
                    completion(finished)
                }
            }
        }
    }

    /// The main-queue half of `snapshotAllOffMain`: decide what needs saving and encode it.
    ///
    /// Skipping is the same rule `snapshotAll` uses — a session the idle compressor already saved,
    /// whose activity token has not moved since, is left alone rather than re-encoded (which would
    /// rehydrate the history compression just released).
    private func encodeForSweep()
        -> (sweep: SnapshotSweep, pending: [(id: String, token: UInt64, data: Data)]) {
        var sweep = SnapshotSweep()
        var pending: [(id: String, token: UInt64, data: Data)] = []
        for id in order {
            // One pool per session — see `snapshotAll`; the encoded `Data` of a whole history is
            // exactly the temporary that must not accumulate across the loop.
            autoreleasepool {
                guard let host = sessions[id] else { return }
                let token = host.session.compressionActivity()
                if let compressor, compressor.hasFreshSnapshot(id.rawValue, token: token) {
                    sweep.skipped.append(id.rawValue)
                    return
                }
                do {
                    pending.append((id.rawValue, token, try host.session.snapshot()))
                } catch {
                    sweep.failed.append(id.rawValue)
                    logger.error("snapshot encode failed for \(id.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        return (sweep, pending)
    }

    /// Where `snapshotAllOffMain` writes. One serial queue, so two sweeps cannot interleave their
    /// writes to the same `.ghsnap`.
    private static let snapshotWriteQueue = DispatchQueue(
        label: "tkzmux.snapshot-write", qos: .utility)

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    public struct RestoreSweep: Sendable, Equatable {
        public var restored: [String] = []
        public var failed: [String] = []
        public var totalBytes: Int = 0
        public var elapsed: Double = 0
    }

    /// Restores every `.ghsnap` in the store, in id order, each with a fresh shell.
    ///
    /// `owner` says which row a snapshot belongs to. Its default is the whole point of the schema
    /// v2 migration: every row lifted from v1 got one leaf whose uuid **is** the session's, so a
    /// `<uuid>.ghsnap` written by any earlier build maps straight back to its row with no lookup
    /// table and no rename (see `Migrations.liftV1ToV2`). A caller that knows better — the app,
    /// which has the tree from `state.json` — passes its own.
    @discardableResult
    public func restoreAll(
        cwd: String, env: [String: String] = [:],
        owner: (TerminalID) -> SessionID = { SessionID(uuid: $0.uuid) }
    ) -> RestoreSweep {
        let start = ContinuousClock.now
        var sweep = RestoreSweep()
        let entries = (try? snapshots.list()) ?? []
        for entry in entries {
            guard let id = TerminalID(entry.id), sessions[id] == nil else { continue }
            do {
                let data = try snapshots.load(entry.id)
                _ = try restore(id, session: owner(id), from: data, cwd: cwd, env: env)
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
        /// What `setVisible` last installed, so a repeat is a no-op rather than policy churn.
        var visible: Set<String> = []
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
            if isVisible { state.visible.insert(id) } else { state.visible.remove(id) }
            state.sessions[id] = session
            state.tokens[id] = token
            state.policy.register(id, at: .now, activityToken: token, isVisible: isVisible)
        }
    }

    public func forget(_ id: String) {
        state.withLock { state in
            state.visible.remove(id)
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

    /// Replaces the visible set wholesale.
    ///
    /// Only the symmetric difference reaches the policy: re-showing the same panes — which
    /// `TerminalHost.show` does on every selection change and every layout delivery — must cost one
    /// lock and no policy churn, or a busy sidebar would keep resetting every pane's idle clock.
    public func setVisible(_ ids: Set<String>) {
        state.withLock { state in
            let now = ContinuousClock.now
            for id in state.visible.subtracting(ids) {
                state.policy.noteVisibility(id, isVisible: false, at: now)
            }
            for id in ids.subtracting(state.visible) {
                state.policy.noteVisibility(id, isVisible: true, at: now)
            }
            state.visible = ids
        }
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
