// ClaudeIntegration — the app-side coordinator for M3 (TKZ-21…TKZ-25).
//
// `ClaudeBridge` ships two services that each know one thing: `HookServer` (frames from
// `tkzmux-hook`) and `ClaudeSessionWatcher` (descriptor files). Neither knows what a `Session` is.
// (`UsageReader` and the per-session sidecar reader are M3.5 / TKZ-25, still in the backlog.)
// This type is the one place where their facts are attributed to rows and posted into the store,
// and it holds the two pieces of state that belong to neither the services nor `AppState`:
//
//   * `pidToSession` — the `launch` frame's `pid → SessionID` binding. It is the primary identity
//     join (design.md → *Claude integration → Identity*): the shim `exec`s the real `claude`, so the
//     pid it announces **is** the pid the descriptor will carry. Descriptor files, hook frames and
//     the `ppid` tree are only fallbacks.
//   * `fullMessages` — the *complete* `last_assistant_message` of the last Stop per session, for the
//     popover. `LiveSessionState.lastStopMessage` keeps 4 KiB by design (state.json and the store
//     diff must stay small); the full text lives here and is never persisted.
//
// Every service callback arrives on that service's queue and is hopped onto the main queue with
// `DispatchQueue.main.async` + `MainActor.assumeIsolated` (FIFO, unlike an unstructured `Task`), so
// two frames from one session are applied in the order they arrived.

import AppKit
import ClaudeBridge
import Foundation
import TkzCore
import os

@MainActor
public final class ClaudeIntegration {
    public let store: AppStore
    /// `~/Library/Application Support/tkzmux` — the socket, `bin/`, `zsh/`.
    public let directory: URL
    /// The user's home; `~/.claude` and the sidecars are found under it.
    public let home: String

    public let hookServer: HookServer
    public let watcher: ClaudeSessionWatcher
    public let installer: ShimInstaller?

    /// `launch`-frame bindings. A session that exits keeps its entry until the pid is reused by a
    /// later `launch`, which simply overwrites it.
    private(set) var pidToSession: [pid_t: SessionID] = [:]
    /// The whole last Stop message per session (see the file header).
    private var fullMessages: [SessionID: String] = [:]
    /// Descriptors no row owns — a cmux window, Terminal.app, VS Code. M5.3's Elsewhere group reads
    /// these; until then they are only kept so the join can be inspected.
    public private(set) var externalDescriptors: [DescriptorKey: DescriptorState] = [:]

    private var tick: DispatchSourceTimer?
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "claude")
    private var started = false

    /// "Is the user looking at this session right now?" — the selected row in a key, visible
    /// window. A Stop that lands while true is attended immediately, so the row the user is
    /// watching never ages into NEEDS YOU under their nose (design.md → *Status derivation*:
    /// `attendedAt` is set when the row is selected while the window is key). Injected so tests
    /// need no window; `MainWindowController` installs the real check.
    public var isSessionAttended: (SessionID) -> Bool = { _ in false }

    /// Claude left a row — its descriptor vanished, or a `SessionEnd` that is an exit arrived —
    /// while the shell may well still be there. `MainWindowController` re-reads the repo's
    /// worktree list on it (M5.2): `claude -w` removes its worktree at this moment, not at the
    /// shell's exit.
    public var onClaudeExited: ((SessionID) -> Void)?

    /// How often the 60 s NEEDS-YOU rule is re-evaluated. Five seconds keeps the amber badge within
    /// a few seconds of the rule without waking the process for nothing.
    public static let tickInterval: TimeInterval = 5

    public init(
        store: AppStore,
        directory: URL,
        home: String = NSHomeDirectory(),
        installer: ShimInstaller? = nil
    ) {
        self.store = store
        self.directory = directory
        self.home = home
        self.installer = installer

        // `~/.claude` is the only given; any further account comes from the store (its
        // `configDir`), never from a hard-coded second directory.
        let primary = (home as NSString).appendingPathComponent(".claude")
        var configDirs = [primary]
        for account in store.state.accounts.values where !configDirs.contains(account.configDir) {
            configDirs.append(account.configDir)
        }

        // Each closure only hops to the main queue; the real work is in the `handle…` methods so
        // that tests can call them directly with synthetic frames.
        let box = WeakBox()
        hookServer = HookServer(
            socketPath: directory.appending(path: "tkzmux.sock", directoryHint: .notDirectory)
        ) { frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { box.value?.handle(frame) } }
        }
        watcher = ClaudeSessionWatcher(configDirs: configDirs) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { box.value?.handle(event) } }
        }
        box.value = self
    }

    /// Lets the service closures reach `self` without capturing it before `init` has finished.
    /// Main-actor isolated, hence `Sendable` without any `@unchecked`; the closures only touch it
    /// inside `MainActor.assumeIsolated`.
    @MainActor private final class WeakBox {
        weak var value: ClaudeIntegration?
    }

    // MARK: Lifecycle

    /// Installs the shim (best effort), then starts every service. Idempotent.
    public func start() {
        guard !started else { return }
        started = true
        if let installer {
            do {
                let outcome = try installer.ensureInstalled()
                logger.info("shell integration: \(String(describing: outcome), privacy: .public)")
            } catch {
                logger.error("shell integration install failed: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            try hookServer.start()
        } catch {
            logger.error("hook server failed to start: \(String(describing: error), privacy: .public)")
        }
        watcher.start()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tickFired() }
        }
        tick = timer
        timer.resume()
    }

    public func stop() {
        guard started else { return }
        started = false
        tick?.cancel()
        tick = nil
        watcher.stop()
        hookServer.stop()
    }

    /// Deletes `bin/`, `zsh/` and `VERSION`; new shells are plain login shells again. The socket,
    /// snapshots and `state.json` stay.
    public func removeShellIntegration() throws {
        try installer?.remove()
    }

    private func tickFired() {
        store.update { $0.rederiveStatuses(now: Date()) }
    }

    // MARK: Hook frames

    func handle(_ frame: HookFrame) {
        switch frame {
        case .launch(let launch):
            bind(launch)
        case .hook(let event, let ppid, let fullMessage, _):
            guard let id = sessionID(forHook: event, ppid: ppid) else {
                logger.info("unattributed hook \(String(describing: event.kind), privacy: .public) sid=\(event.sessionID?.rawValue ?? "-", privacy: .public) ppid=\(ppid)")
                return
            }
            logger.info("hook \(String(describing: event.kind), privacy: .public) → \(id.rawValue, privacy: .public)")
            if event.kind == .stop, let fullMessage { fullMessages[id] = fullMessage }
            let attended = event.kind == .stop && isSessionAttended(id)
            store.update { state in
                let now = Date()
                state.applyHook(event, to: id, now: now)
                if attended { state.markAttended(id, now: now) }
            }
            if event.kind == .sessionEnd, store.state.sessions[id]?.live?.ended == true {
                onClaudeExited?(id)
            }
        }
    }

    /// The shim announced `pid` for `sid`. Binds the pid and, if the watcher already saw a
    /// descriptor for it (a race the 100 ms debounce makes real), applies it now.
    private func bind(_ launch: LaunchAnnouncement) {
        guard let id = launch.sessionID, store.state.sessions[id]?.live != nil else {
            logger.info("launch frame for unknown session \(launch.rawSid, privacy: .public) pid=\(launch.pid)")
            return
        }
        logger.info("launch pid \(launch.pid) → \(id.rawValue, privacy: .public)")
        pidToSession[launch.pid] = id
        store.update { $0.updateLive(id) { $0.pid = launch.pid } }
        for (key, state) in watcher.snapshot() where state.info.pid == launch.pid {
            // Seen before the frame: it was filed as external; it has an owner now.
            externalDescriptors[key] = nil
            store.update { $0.applyDescriptor(state.info, alive: state.alive, to: id, now: Date()) }
        }
    }

    /// `sid` → `payload.session_id` → the `ppid` tree, per design.md → *tkzmux-hook*.
    ///
    /// Only rows with live state are targets: a restored row has no shell, so nothing running can
    /// belong to it, and attributing to it (by a `claudeSessionId` that a resume elsewhere reused)
    /// would resurrect a dead row without a terminal behind it.
    func sessionID(forHook event: HookEvent, ppid: pid_t) -> SessionID? {
        let state = store.state
        if let id = event.sessionID, state.sessions[id]?.live != nil { return id }
        if let claudeID = event.claudeSessionId,
           let match = state.sessions.values.first(where: { $0.live != nil && $0.claudeSessionId == claudeID }) {
            return match.id
        }
        return sessionID(forProcess: ppid)
    }

    /// Walks up from `pid` (inclusive) looking for a pid the store knows: a bound `claude` pid or
    /// a session's shell pid. Depth-limited; stops at launchd.
    func sessionID(forProcess pid: pid_t) -> SessionID? {
        let sessions = store.state.sessions.values
        var current = pid
        for _ in 0..<8 {
            guard current > 1 else { return nil }
            if let id = pidToSession[current], store.state.sessions[id]?.live != nil { return id }
            if let match = sessions.first(where: { $0.live?.pid == current || $0.live?.shellPid == current }) {
                return match.id
            }
            guard let parent = ProcessTree.parent(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    // MARK: Descriptors

    func handle(_ event: DescriptorEvent) {
        switch event {
        case .updated(let info, let alive):
            let key = DescriptorKey(configDir: info.configDir, pid: info.pid)
            guard let id = sessionID(forDescriptor: info) else {
                if externalDescriptors[key] == nil {
                    logger.info("external descriptor pid=\(info.pid) \(info.accountKey, privacy: .public)")
                }
                externalDescriptors[key] = DescriptorState(info: info, alive: alive, lastSeenAt: Date())
                return
            }
            externalDescriptors[key] = nil
            store.update { $0.applyDescriptor(info, alive: alive, to: id, now: Date()) }
        case .removed(let key):
            externalDescriptors[key] = nil
            let bound = store.state.sessions.values.first { $0.live?.pid == key.pid }
            if let bound {
                store.update { $0.descriptorLost(for: bound.id, now: Date()) }
                onClaudeExited?(bound.id)
            }
        }
    }

    /// `launch` binding → a row already carrying this pid → a row whose `claudeSessionId` matches
    /// (a resumed conversation) → the process tree up to a session's shell.
    func sessionID(forDescriptor info: ClaudeSessionInfo) -> SessionID? {
        let state = store.state
        if let id = pidToSession[info.pid], state.sessions[id]?.live != nil { return id }
        if let match = state.sessions.values.first(where: { $0.live?.pid == info.pid }) { return match.id }
        if let match = state.sessions.values.first(where: {
            $0.claudeSessionId == info.sessionId && $0.live != nil && $0.live?.descriptor == nil
        }) {
            return match.id
        }
        if let parent = ProcessTree.parent(of: info.pid) { return sessionID(forProcess: parent) }
        return nil
    }

    // MARK: Queries

    /// The complete last Stop message, falling back to the 4 KiB the store keeps.
    public func lastMessage(for id: SessionID) -> String? {
        fullMessages[id] ?? store.state.sessions[id]?.live?.lastStopMessage
    }
}
