// AgentIntegration — the app-side coordinator for M3, generalized by TKZ-82 from the
// Claude-only `ClaudeIntegration` into one driven by an `[AgentKind: any AgentAdapter]` table.
//
// `ClaudeBridge` ships two kinds of service that each know one thing: `HookServer` (frames from
// `tkzmux-hook`) and an `AgentObservationWatcher` per adapter that has one (descriptor files, for
// Claude). Neither knows what a `Session` is. (`UsageReader` and the per-session sidecar reader
// are M3.5, still in the backlog; the account-label half of M3.5 is here, reached through the
// adapter that owns each account.)
// This type is the one place where their facts are attributed to rows and posted into the store,
// and it holds the two pieces of state that belong to neither the services nor `AppState`:
//
//   * `pidToSession` — the `launch` frame's `pid → SessionID` binding. It is the primary identity
//     join: the shim `exec`s the real `claude`, so the
//     pid it announces **is** the pid the descriptor will carry. Descriptor files, hook frames and
//     the `ppid` tree are only fallbacks.
//   * `fullMessages` — the *complete* `last_assistant_message` of the last Stop per session, for the
//     popover. `LiveSessionState.lastStopMessage` keeps 4 KiB by design (state.json and the store
//     diff must stay small); the full text lives here and is never persisted.
//
// Every service callback arrives on that service's queue and is hopped onto the main queue with
// `DispatchQueue.main.async` + `MainActor.assumeIsolated` (FIFO, unlike an unstructured `Task`), so
// two frames from one session are applied in the order they arrived.
//
// The test of whether the seam is real: adding an agent means adding an adapter and nothing else.
// This type never names a concrete adapter — `adapters` is injectable, and `AgentIntegrationTests`
// registers a stub to prove it.

import AppKit
import ClaudeBridge
import Foundation
import TkzCore
import os

@MainActor
public final class AgentIntegration {
    public let store: AppStore
    /// `~/Library/Application Support/tkzmux` — the socket, `bin/`, `zsh/`.
    public let directory: URL
    /// The user's home; `~/.claude` and the sidecars are found under it.
    public let home: String
    /// One adapter per agent tkzmux knows about. Defaults to Claude alone; tests register a stub
    /// here instead, which is the whole seam this type is built around.
    public let adapters: [AgentKind: any AgentAdapter]

    public let hookServer: HookServer
    /// One observation watcher per adapter that has one — Claude's descriptor watcher today,
    /// nothing for an adapter that returns `nil` from `makeObservationWatcher`.
    private var watchers: [AgentKind: any AgentObservationWatcher] = [:]
    public let installer: ShimInstaller?
    /// Reads the two statusline sidecars `tkzmux-hook statusline` writes. Present even
    /// when nothing has been installed yet — the directory simply stays empty and the sweep keeps
    /// looking, so the badges light up the moment the user consents.
    public let statusline: StatuslineReader
    /// Writes `statusLine` into the user's `settings.json`. `nil` when the hook binary isn't
    /// installed, exactly like `installer`. The statusline itself stays Claude-only (design: only
    /// Claude Code has one to wrap) and every method below gates on `.statusline` rather than
    /// assuming every account can use it.
    public let statuslineInstaller: StatuslineInstaller?
    /// Sums token usage and estimated spend off each session's own transcript (design: token usage
    /// and spend per session). Unlike `statusline`, this needs nothing installed or opted into —
    /// `~/.claude` is already read for the first-prompt card — so it is always present.
    public let usageReader: TranscriptUsageReader

    /// `launch`-frame bindings. A session that exits keeps its entry until the pid is reused by a
    /// later `launch`, which simply overwrites it.
    ///
    /// Internal setter rather than `private(set)` so the eviction tests can seed a binding; both
    /// this and `fullMessages` are dropped by ``forget(_:)``.
    var pidToSession: [pid_t: SessionID] = [:]
    /// The whole last Stop message per session (see the file header). Internal for the same reason.
    var fullMessages: [SessionID: String] = [:]
    /// `payload.transcript_path` from the last attributed hook frame per session — where the agent
    /// keeps the conversation the first-prompt card (design 2c.5) reads. Process state like
    /// `fullMessages`: a restored row has none and falls back to the adapter's own `locate`.
    var transcriptPaths: [SessionID: String] = [:]
    /// Memoized transcript-locate answers, for rows no hook frame has named.
    ///
    /// **Including the misses.** Locating a transcript enumerates a whole `projects` tree and
    /// `stat`s a candidate in every project directory — dozens to hundreds of syscalls — and it is
    /// reached from `transcriptTargets()`, which the search field used to call on *every keystroke*
    /// for *every* open session, on the main thread. Caching only the hits would have left the
    /// common case (a row whose conversation is not on disk) paying the full scan every time.
    ///
    /// Keyed by the two inputs that decide the answer, so a row that is resumed under a new
    /// conversation or moved to another account re-resolves instead of returning a stale path.
    var locatedTranscripts: [SessionID: (conversationID: String, accountKey: String, path: String?)] = [:]
    /// The last good transcript summary per session, so reopening the card is instant and a torn
    /// read never blanks it. Same lifecycle as `fullMessages`.
    var transcriptSummaries: [SessionID: TranscriptSummary] = [:]
    /// Transcript reads happen here, never on the main queue: a `/loop` transcript is tens of
    /// megabytes and even the capped head+tail read is two file seeks and a JSON pass.
    private let transcriptQueue = DispatchQueue(label: "se.tkz.tkzmux.transcript", qos: .userInitiated)
    /// Descriptors no row owns — a cmux window, Terminal.app, VS Code. M5.3's Elsewhere group reads
    /// these; until then they are only kept so the join can be inspected.
    public private(set) var externalDescriptors: [DescriptorKey: ExternalObservation] = [:]

    /// One agent's observation seen but not attributed to any row — the generic replacement for
    /// carrying `ClaudeSessionInfo` here, which would have put one agent's file schema back into a
    /// type every agent shares.
    public struct ExternalObservation: Sendable {
        public var observation: AgentObservation
        public var alive: Bool
        public var lastSeenAt: Date
    }

    private var tick: DispatchSourceTimer?
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "agents")
    private var started = false

    /// "Is the user looking at this session right now?" — the selected row in a key, visible
    /// window. A Stop that lands while true is attended immediately, so the row the user is
    /// watching never ages into NEEDS YOU under their nose (`attendedAt` is set when the row is
    /// selected while the window is key). Injected so tests
    /// need no window; `MainWindowController` installs the real check.
    public var isSessionAttended: (SessionID) -> Bool = { _ in false }

    /// The agent left a row — its observation vanished, or a `SessionEnd` that is an exit arrived —
    /// while the shell may well still be there. `MainWindowController` re-reads the repo's
    /// worktree list on it (M5.2): `claude -w` removes its worktree at this moment, not at the
    /// shell's exit.
    public var onAgentExited: ((SessionID) -> Void)?

    /// A `Stop` hook landed for this row — the agent has finished a turn, and whatever it did to the
    /// working tree is on disk now. `GitIntegration` (M4) refreshes git and re-scans ports on it;
    /// it is the one moment a refresh is worth making unconditionally, for any row.
    public var onStop: ((SessionID) -> Void)?

    /// How often the 60 s NEEDS-YOU rule is re-evaluated. Five seconds keeps the amber badge within
    /// a few seconds of the rule without waking the process for nothing.
    public static let tickInterval: TimeInterval = 5

    /// This instance's pid: names its hook socket and anchors the ownership walk.
    public let instancePID: pid_t
    /// Parent/name lookups for `ownsProcess(_:)` and the pid walks. Injected so the joins can be
    /// driven with a fake process tree.
    let ancestry: any ProcessAncestry
    /// This executable's short name, the marker the ownership walk uses to recognise *another*
    /// tkzmux in a pid's ancestry (a dev build started from a pane). `swift run tkzmux` and the
    /// app bundle both report `tkzmux`; a binary built under some other name would not be
    /// recognised, and only that one topology would cross-claim again.
    let executableName: String
    /// `kill(pid,0)` plus the pid-reuse guard, for the tick's liveness sweep (below). Injected the
    /// same way `ancestry` is, so a test can report a bound pid dead without a real process.
    let liveness: any ProcessLiveness

    public init(
        store: AppStore,
        directory: URL,
        home: String = NSHomeDirectory(),
        adapters: [AgentKind: any AgentAdapter]? = nil,
        installer: ShimInstaller? = nil,
        instancePID: pid_t = getpid(),
        ancestry: any ProcessAncestry = SystemProcessAncestry(),
        liveness: any ProcessLiveness = SystemProcessLiveness()
    ) {
        self.store = store
        self.directory = directory
        self.home = home
        // `nil` (the default) builds Claude-plus-Codex-if-installed; a test registers its own
        // table instead, which is the whole seam this type is built around (see the file header).
        // The default can't simply be `[.claude: ClaudeAdapter(), .codex: CodexAdapter(...)]` the
        // way Claude's own entry once was: whether Codex belongs in the table depends on
        // `directory` (its hook installer's own support directory) and on `codex` actually being
        // on `PATH`, neither of which a default *argument* expression can see — only the
        // initializer's body can.
        self.adapters = adapters ?? Self.defaultAdapters(supportDirectory: directory)
        self.installer = installer
        self.instancePID = instancePID
        self.ancestry = ancestry
        self.liveness = liveness
        self.executableName = ancestry.name(of: instancePID) ?? ""

        // Accounts are discovered, never hard-coded: every adapter's own `discoverAccounts` (e.g.
        // `~/.claude` plus every `~/.claude-*` that looks like a config dir), plus whatever the
        // store already knows, plus the account of every persisted row (a resume must find its
        // descriptor in *that* account's own directory).
        let discovered = self.adapters.values.flatMap { $0.discoverAccounts(home: home, fileManager: .default) }
        var accounts = store.state.accounts
        for account in discovered where accounts[account.key] == nil { accounts[account.key] = account }
        for session in store.state.sessions.values where accounts[session.accountKey] == nil {
            if let dir = Account.configDirectory(forKey: session.accountKey, home: home) {
                // The row itself says which agent it belongs to, so the account this fabricates
                // follows `session.agent` rather than assuming Claude — the adapter table is what
                // makes that honest now that a second agent can exist.
                let label = self.adapters[session.agent]?.accountLabels(home: home, fileManager: .default)[session.accountKey]
                    ?? session.accountKey
                accounts[session.accountKey] = Account(
                    key: session.accountKey, configDir: dir, label: label, agent: session.agent)
            }
        }
        var flatConfigDirs: [String] = []
        for key in accounts.keys.sorted() where !flatConfigDirs.contains(accounts[key]!.configDir) {
            flatConfigDirs.append(accounts[key]!.configDir)
        }
        watchedConfigDirs = flatConfigDirs

        // Each closure only hops to the main queue; the real work is in the `handle…` methods so
        // that tests can call them directly with synthetic frames.
        let box = WeakBox()
        // One socket per running instance (`HookSocket`): the same name `TerminalEnvironment`
        // exports as `TKZMUX_SOCKET` for this pid, so a pane's frames reach the instance that
        // spawned it and a second tkzmux no longer fails to bind.
        hookServer = HookServer(
            socketPath: HookSocket.url(in: directory, pid: instancePID)
        ) { frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { box.value?.handle(frame) } }
        }
        var watchers: [AgentKind: any AgentObservationWatcher] = [:]
        for (kind, adapter) in self.adapters {
            let dirs = Self.configDirs(for: kind, in: accounts)
            let onEvent: @Sendable (ObservationEvent) -> Void = { event in
                DispatchQueue.main.async { MainActor.assumeIsolated { box.value?.handle(event, from: kind) } }
            }
            guard let watcher = adapter.makeObservationWatcher(configDirs: dirs, onEvent: onEvent) else { continue }
            watchers[kind] = watcher
        }
        self.watchers = watchers
        statusline = StatuslineReader(
            directory: StatuslineReader.standardDirectory(supportDirectory: directory)
        ) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { box.value?.handle(event) } }
        }
        statuslineInstaller = StatuslineInstaller(directory: directory)
        usageReader = TranscriptUsageReader(
            cacheDirectory: TranscriptUsageReader.standardDirectory(supportDirectory: directory))
        box.value = self

        let toRegister = accounts.values.filter { store.state.accounts[$0.key] == nil }
        if !toRegister.isEmpty {
            store.update { state in for account in toRegister { state.setAccount(account) } }
        }
    }

    /// Claude, always, plus Codex only when `codex` is actually on `PATH` (TKZ-86). This is what
    /// keeps an uninstalled Codex from changing anything for a Claude-only user: no adapter in the
    /// table means no Codex accounts discovered, no Codex hook frames routed, nothing — exactly
    /// today's table, bit for bit, on a machine that has never heard of Codex.
    ///
    /// Internal rather than `private`, and `path` is an extra parameter beyond what `init` passes
    /// (defaulted to the real `PATH`) — both exist solely so `AgentIntegrationTests` can assert the
    /// gate itself deterministically, the same way `CodexAdapter.discoverAccounts(path:)` does.
    static func defaultAdapters(
        supportDirectory: URL, path: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> [AgentKind: any AgentAdapter] {
        var table: [AgentKind: any AgentAdapter] = [.claude: ClaudeAdapter()]
        let codex = CodexAdapter(supportDirectory: supportDirectory)
        if codex.isInstalled(path: path) { table[.codex] = codex }
        return table
    }

    /// The config dirs the watchers are currently pointed at, in registration order, across every
    /// agent. `watchers[agent]` is handed only its own slice, computed on demand from the store.
    public private(set) var watchedConfigDirs: [String]

    /// `accounts`' config dirs belonging to one agent, deduped and key-ordered. What each adapter's
    /// own observation watcher is pointed at — a Codex watcher must never be handed a Claude config
    /// dir and vice versa; they are unrelated file layouts that only coincidentally share the word
    /// "account".
    private static func configDirs(for agent: AgentKind, in accounts: [String: Account]) -> [String] {
        var out: [String] = []
        for key in accounts.keys.sorted() where accounts[key]?.agent == agent {
            let dir = accounts[key]!.configDir
            if !out.contains(dir) { out.append(dir) }
        }
        return out
    }

    /// A process announced which config dir it really runs under. Registers the account if it is
    /// new, watches its own directory if it is not watched, and corrects the row's `accountKey` —
    /// the user's environment (a shell rc, a wrapper) may have picked a different account than the
    /// launcher asked for, and the chip, the descriptor join and every later resume must follow
    /// the process, not the request.
    func learnAccount(configDir: String, for id: SessionID, agent: AgentKind) {
        let trimmed = configDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let standardized = (trimmed as NSString).standardizingPath
        let key = Account.key(forConfigDirectory: standardized)
        guard !key.isEmpty else { return }
        let known = store.state.accounts[key]
        // Only a *new* account needs a name looked up. This method runs on every launch frame and
        // every observation update — several times a minute per session — and label lookup reads
        // and parses a file, so it must not be on that path for an account we already know.
        let label = known == nil ? (adapters[agent]?.accountLabels(home: home, fileManager: .default)[key] ?? key) : key
        store.update { state in
            if known == nil {
                state.setAccount(Account(key: key, configDir: standardized, label: label, agent: agent))
            }
            state.setSessionAccount(id, key: key)
        }
        let dir = known?.configDir ?? standardized
        if !watchedConfigDirs.contains(dir) {
            logger.info("watching account \(key, privacy: .public) at \(dir, privacy: .public)")
            watchedConfigDirs.append(dir)
            watchers[agent]?.setConfigDirs(Self.configDirs(for: agent, in: store.state.accounts))
        }
    }

    /// Lets the service closures reach `self` without capturing it before `init` has finished.
    /// Main-actor isolated, hence `Sendable` without any `@unchecked`; the closures only touch it
    /// inside `MainActor.assumeIsolated`.
    @MainActor private final class WeakBox {
        weak var value: AgentIntegration?
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
        // Sockets of instances that crashed or were killed are named after pids nobody reuses
        // on purpose; sweep them before adding ours. A live sibling survives its probe.
        HookServer.sweepStaleInstanceSockets(in: directory, except: hookServer.socketPath)
        do {
            try hookServer.start()
        } catch {
            logger.error(
                "hook server failed to start at \(self.hookServer.socketPath.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        for watcher in watchers.values { watcher.start() }
        statusline.start()

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
        for watcher in watchers.values { watcher.stop() }
        statusline.stop()
        hookServer.stop()
    }

    // MARK: Statusline sidecars

    /// Quota and per-session context, posted straight into the store. Unlike hook frames these need
    /// no attribution work: usage is keyed by account and context joins on the agent's own session id.
    func handle(_ event: StatuslineEvent) {
        store.update { state in
            switch event {
            case .usage(let snapshot):
                state.setUsage(snapshot)
            case .usageCleared(let accountKey):
                state.clearUsage(for: accountKey)
            case .context(let sidecar):
                state.setSessionSidecar(sidecar)
            case .contextRemoved(let sessionId):
                state.clearSessionSidecar(conversationId: sessionId)
            }
        }
    }

    /// Whether `accountKey`'s own agent can even have a status line — the statusline stays a
    /// Claude Code feature (it edits Claude's own `settings.json`), so every method below refuses
    /// an account whose adapter does not claim `.statusline` rather than quietly acting on it.
    private func statuslineCapableAccount(_ accountKey: String) -> Account? {
        guard let account = store.state.accounts[accountKey],
              adapters[account.agent]?.capabilities.contains(.statusline) == true
        else { return nil }
        return account
    }

    /// Which producer, if any, is feeding the statusline for an account's config dir.
    public func statuslineProducer(accountKey: String) -> StatuslineProducer {
        guard let installer = statuslineInstaller,
              let account = statuslineCapableAccount(accountKey)
        else { return .none }
        return installer.detect(configDir: account.configDir)
    }

    public func statuslinePlan(accountKey: String) throws -> StatuslineInstallPlan? {
        guard let installer = statuslineInstaller,
              let account = statuslineCapableAccount(accountKey)
        else { return nil }
        return try installer.plan(configDir: account.configDir, accountKey: accountKey)
    }

    public func installStatusline(accountKey: String) throws {
        guard let installer = statuslineInstaller,
              let account = statuslineCapableAccount(accountKey)
        else { return }
        try installer.install(configDir: account.configDir, accountKey: accountKey)
    }

    public func uninstallStatusline(accountKey: String) throws {
        guard let installer = statuslineInstaller,
              let account = statuslineCapableAccount(accountKey)
        else { return }
        try installer.uninstall(configDir: account.configDir, accountKey: accountKey)
    }

    /// Re-points any account whose `statusLine` runs a `tkzmux-hook` that is not this build's.
    /// Returns the account keys it repaired.
    ///
    /// Called once per launch from `AppDelegate`, deliberately *not* from ``start()``: this writes
    /// the user's `settings.json`, and `start()` is called by tests that pass a temp support
    /// directory but the real `home` — from which every real account would look stale, and get
    /// "repaired" to point at a hook under `/var/folders`. `AppDelegate` is the seam where the rest
    /// of the settings-touching startup work already lives.
    ///
    /// Worth doing at all because the failure it repairs is invisible: the settings file still
    /// names a tkzmux hook, so the integration reads as installed, but that hook writes its
    /// sidecars beside *itself* and this app watches a directory nobody fills. The user sees an
    /// empty quota band and no error anywhere. One launch of the real app now fixes it.
    ///
    /// Not a consent-worthy edit: the user already agreed to tkzmux owning `statusLine` for this
    /// account, and this only corrects which binary that command names.
    @discardableResult
    public func repairStaleStatuslines() -> [String] {
        guard let installer = statuslineInstaller else { return [] }
        var repaired: [String] = []
        for account in store.state.accounts.values.sorted(by: { $0.key < $1.key }) {
            guard adapters[account.agent]?.capabilities.contains(.statusline) == true else { continue }
            guard case .stale(let command) = installer.detect(configDir: account.configDir) else {
                continue
            }
            do {
                guard try installer.repair(configDir: account.configDir, accountKey: account.key)
                else { continue }
                repaired.append(account.key)
                logger.info(
                    "statusline: re-pointed \(account.key, privacy: .public) at this build's hook, was \(command, privacy: .public)"
                )
            } catch {
                logger.error(
                    "statusline: could not repair \(account.key, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return repaired
    }

    /// Drops every per-session entry for `id`. Called when the row is removed.
    ///
    /// `fullMessages` is the one that matters: a Stop message is an arbitrarily long string (a
    /// pasted diff, a log dump), and without this the app keeps one per session id it has *ever*
    /// seen, for as long as it runs. `pidToSession` is small but has the same shape.
    public func forget(_ id: SessionID) {
        fullMessages.removeValue(forKey: id)
        transcriptPaths.removeValue(forKey: id)
        locatedTranscripts.removeValue(forKey: id)
        transcriptSummaries.removeValue(forKey: id)
        pidToSession = pidToSession.filter { $0.value != id }
    }

    /// Deletes `bin/`, `zsh/` and `VERSION`; new shells are plain login shells again. The socket,
    /// snapshots and `state.json` stay.
    ///
    /// The statusline is uninstalled **first**: `settings.json` points at `bin/tkzmux-hook`, and
    /// removing `bin/` while that reference stands would leave the user with a statusline command
    /// that no longer exists. A failure here is deliberately swallowed per account — a config dir
    /// the user has since rewired by hand must not block removing the shell integration.
    public func removeShellIntegration() throws {
        for account in store.state.accounts.values.sorted(by: { $0.key < $1.key }) {
            try? uninstallStatusline(accountKey: account.key)
        }
        try installer?.remove()
    }

    /// Internal rather than `private`: the 5 s timer is what calls this in the app, but the tests
    /// drive it directly rather than sleeping for a real interval.
    func tickFired() {
        pollLivenessForRowsWithNoObservation()
        store.update { $0.rederiveStatuses(now: Date()) }
    }

    /// The fallback for an agent that writes no descriptor file at all. Claude always has an
    /// observation while its process is alive, so a Claude row learns of a crash from
    /// `handle(_ event: ObservationEvent, from:)`'s `.removed` case — the file vanishing is the
    /// signal. Codex has no such file, so a row bound to a Codex pid would otherwise sit at whatever
    /// status its last hook left it in forever, even after the process is long gone. This sweep
    /// is what catches that: a row with a bound launch pid and no observation is asked, once a
    /// tick, whether that pid still exists, and `agentLost` runs if it does not.
    ///
    /// A row with an observation is skipped outright — that is the watcher's job, not this one's
    /// — and this cannot fire for Claude today precisely because Claude never leaves that gap.
    private func pollLivenessForRowsWithNoObservation() {
        for id in store.state.sessions.keys {
            guard let live = store.state.sessions[id]?.live, let pid = live.pid, live.observation == nil
            else { continue }
            // Only a row this instance itself bound the pid for — `pidToSession` is the launch
            // frame's own record, so a stray pid that merely matches (already handled elsewhere,
            // or belonging to a row that has moved on) is left alone.
            guard pidToSession[pid] == id else { continue }
            guard !liveness.isAlive(pid: pid, startedAt: nil) else { continue }
            store.update { $0.agentLost(for: id, now: Date()) }
            onAgentExited?(id)
        }
    }

    // MARK: Hook frames

    func handle(_ frame: HookFrame) {
        switch frame {
        case .launch(let launch):
            bind(launch)
        case .hook(let payload, let frameSessionID, let ppid, let fullMessage):
            // Routed on `payload.agent`: a payload from an agent nobody has an adapter for has
            // nobody to translate it and is dropped rather than misread by a mapper that speaks a
            // different vocabulary.
            guard let adapter = adapters[payload.agent] else {
                logger.info("no adapter for agent=\(payload.agent.rawValue, privacy: .public) event=\(payload.eventName, privacy: .public)")
                return
            }
            guard var event = adapter.mapHook(payload) else {
                logger.info("unmapped hook agent=\(payload.agent.rawValue, privacy: .public) event=\(payload.eventName, privacy: .public)")
                return
            }
            event.sessionID = frameSessionID
            guard let id = sessionID(forHook: event, ppid: ppid, agent: payload.agent) else {
                logger.info("unattributed hook \(String(describing: event.kind), privacy: .public) sid=\(event.sessionID?.rawValue ?? "-", privacy: .public) ppid=\(ppid)")
                return
            }
            logger.info("hook \(String(describing: event.kind), privacy: .public) → \(id.rawValue, privacy: .public)")
            if event.kind == .turnEnded, let fullMessage { fullMessages[id] = fullMessage }
            if let transcriptPath = payload.transcriptPath, !transcriptPath.isEmpty {
                transcriptPaths[id] = transcriptPath
            }
            // A hook landing on the row the user is looking at is seen as it lands: a Stop is
            // attended outright (the NEEDS YOU clock never starts), and any other kind at least
            // leaves the row's feed entries read — the outline view never re-fires selection for
            // the row that is already selected, so nothing else would clear them.
            let attended = isSessionAttended(id)
            store.update { state in
                let now = Date()
                state.applyEvent(event, to: id, now: now)
                if attended {
                    if event.kind == .turnEnded { state.markAttended(id, now: now) } else { state.markActivityRead(id) }
                }
            }
            if event.kind == .turnEnded { onStop?(id) }
            if case .sessionEnd = event.kind, store.state.sessions[id]?.live?.ended == true {
                onAgentExited?(id)
            }
            switch event.kind {
            case .sessionStart, .turnEnded, .sessionEnd, .promptSubmitted:
                refreshUsage(for: id)
            case .attention, .attentionCleared, .unknown:
                break
            }
        }
    }

    /// An OSC 9 desktop notification landed in the pane that is running the agent (TKZ-85). The
    /// caller — `MainWindowController.handle(_:for:)` — has already checked `paneHostsAgent`;
    /// this is where the row's *own* adapter gets to say whether the title/body classify as
    /// anything at all. Classification never crosses into TkzCore itself: the adapter turns raw
    /// text into an `AgentEvent`, exactly as `mapHook` does for a hook frame, so the store still
    /// never sees a notification title.
    ///
    /// A `nil` from the adapter — or no adapter for this row's agent — does nothing, which is the
    /// honest answer for an agent whose notifications carry nothing we can classify (Claude, until
    /// there is a reason to think otherwise).
    func handleTerminalNotification(sessionID: SessionID, terminal: TerminalID, title: String, body: String) {
        guard let session = store.state.sessions[sessionID], let adapter = adapters[session.agent],
            let event = adapter.mapTerminalNotification(title: title, body: body)
        else { return }
        // Same attended handling a hook frame gets (`handle(_ frame:)`, above): a turn ending on
        // the row the user is already looking at is attended outright, and anything else at least
        // marks the row's feed read — the outline view never re-fires selection for the row that
        // is already selected, so nothing else would clear it.
        let attended = isSessionAttended(sessionID)
        store.update { state in
            let now = Date()
            state.applyEvent(event, to: sessionID, now: now)
            if attended {
                if event.kind == .turnEnded { state.markAttended(sessionID, now: now) } else { state.markActivityRead(sessionID) }
            }
        }
    }

    /// Sums `id`'s transcript for token usage and estimated spend, off the main actor, and lands
    /// the result on `Session.live.usage` (design: token usage and spend per session). The reader
    /// keeps its own byte-offset cursor per session, so calling this on every relevant hook is
    /// cheap — a `Stop` right after `SessionStart`'s full backfill only parses what's new.
    ///
    /// Skips the read entirely while the feature is off, globally or for this one session (design:
    /// enable/disable, all sessions and per session), while the row's agent has no adapter or does
    /// not claim `.transcriptUsage`, or while there is no transcript path to read yet.
    private func refreshUsage(for id: SessionID) {
        guard let session = store.state.sessions[id], let conversationId = session.conversationId,
              store.state.showSessionSpend, session.spendTrackingDisabled != true,
              let adapter = adapters[session.agent], adapter.capabilities.contains(.transcriptUsage),
              let path = transcriptPath(for: id)
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let usage = await adapter.transcript.usage(
                conversationId: conversationId, path: path, reader: self.usageReader)
            else { return }
            self.store.update { $0.setSessionUsage(usage, conversationId: conversationId) }
        }
    }

    /// Re-reads one session's transcript right away — called when its own spend-tracking opt-out
    /// is turned back off (design: enable/disable, per session), so its badge/status-bar figure
    /// reappears without waiting for that session's next hook.
    public func refreshUsageNow(for id: SessionID) { refreshUsage(for: id) }

    /// Re-reads every session's transcript right away — called when the global spend switch is
    /// turned back on (design: enable/disable, all sessions). Cheap even for a session that stays
    /// disabled: `refreshUsage(for:)`'s guard returns before touching its transcript.
    public func refreshAllUsage() {
        for id in store.state.sessions.keys { refreshUsage(for: id) }
    }

    /// The shim announced `pid` for `sid`. Binds the pid and, if the watcher already saw a
    /// descriptor for it (a race the 100 ms debounce makes real), applies it now.
    private func bind(_ launch: LaunchAnnouncement) {
        guard let id = launch.sessionID, store.state.sessions[id]?.live != nil else {
            logger.info("launch frame for unknown session \(launch.rawSid, privacy: .public) pid=\(launch.pid)")
            return
        }
        logger.info("launch pid \(launch.pid) → \(id.rawValue, privacy: .public) config_dir=\(launch.configDir, privacy: .public)")
        pidToSession[launch.pid] = id
        // Which pane the frame came from, resolved *before* the observation below is applied —
        // applying a live observation is what clears `agentStartup`, the cheap answer.
        let terminal = agentTerminal(for: launch, in: id)
        store.update { state in
            state.updateLive(id) { $0.pid = launch.pid }
            state.setAgentTerminal(id, terminal)
        }
        // `tkzmux-hook launch` is only ever sent by the `.perInvocation` shim path, which today
        // means Claude — `LaunchAnnouncement` carries no agent field of its own to route on.
        let agent = AgentKind.claude
        learnAccount(configDir: launch.configDir, for: id, agent: agent)
        // The launch/descriptor race-fix below only makes sense for a watcher backed by a file on
        // disk (Claude's descriptor), so it stays scoped to that concrete type rather than growing
        // a new protocol requirement for one caller.
        if let claudeWatcher = watchers[.claude] as? ClaudeSessionWatcher {
            for (key, state) in claudeWatcher.snapshot() where state.info.pid == launch.pid {
                // Seen before the frame: it was filed as external; it has an owner now.
                externalDescriptors[key] = nil
                store.update { $0.applyObservation(state.info.observation, alive: state.alive, to: id, now: Date()) }
                learnAccount(configDir: state.info.configDir, for: id, agent: .claude)
            }
        }
    }

    /// The pane whose shell is running the agent the shim just announced. A boot command or a
    /// resume recorded its pane in `agentStartup`; an agent typed by hand in a split did not,
    /// so the frame's pid (the shim's `$$`, a child of the pane's login shell) is walked up
    /// `panePids` the same way `sessionID(forProcess:)` walks it. `nil` when neither places it;
    /// `GitIntegration` then falls back to "the row's only pane".
    func agentTerminal(for launch: LaunchAnnouncement, in id: SessionID) -> TerminalID? {
        guard let live = store.state.sessions[id]?.live else { return nil }
        if let startup = live.agentStartup { return startup.terminal }
        guard !live.panePids.isEmpty else { return nil }
        var current = launch.pid
        for _ in 0..<8 {
            guard current > 1 else { return nil }
            if let match = live.panePids.first(where: { $0.value == current }) { return match.key }
            guard let parent = ancestry.parent(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// Whether `pid` runs under this instance — its ancestry reaches our pid before launchd and
    /// without crossing another tkzmux (`ProcessOwnership`). Gates the descriptor joins that
    /// cannot tell instances apart on their own.
    func ownsProcess(_ pid: pid_t) -> Bool {
        ProcessOwnership.owns(pid, selfPid: instancePID, selfName: executableName, ancestry: ancestry)
    }

    /// `sid` → `payload.session_id` → the `ppid` tree.
    ///
    /// Only rows with live state are targets: a restored row has no shell, so nothing running can
    /// belong to it, and attributing to it (by a `conversationId` that a resume elsewhere reused)
    /// would resurrect a dead row without a terminal behind it.
    func sessionID(forHook event: AgentEvent, ppid: pid_t, agent: AgentKind) -> SessionID? {
        let state = store.state
        if let id = event.sessionID, state.sessions[id]?.live != nil { return id }
        // A hook's own conversation id must only match a row of the *same* agent — otherwise a
        // coincidental id collision could hand one agent's payload to another agent's row.
        if let conversationId = event.conversationId,
           let match = state.sessions.values.first(where: {
               $0.live != nil && $0.agent == agent && $0.conversationId == conversationId
           }) {
            return match.id
        }
        return sessionID(forProcess: ppid)
    }

    /// Walks up from `pid` (inclusive) looking for a pid the store knows: a bound agent pid or
    /// a session's shell pid. Depth-limited; stops at launchd, and at another tkzmux — a dev
    /// build running in one of our panes has our pane's shell above it, and everything under it
    /// belongs to that build, not to the row hosting it.
    func sessionID(forProcess pid: pid_t) -> SessionID? {
        let sessions = store.state.sessions.values
        var current = pid
        for _ in 0..<8 {
            guard current > 1 else { return nil }
            if current != instancePID, !executableName.isEmpty, ancestry.name(of: current) == executableName {
                return nil
            }
            if let id = pidToSession[current], store.state.sessions[id]?.live != nil { return id }
            // `panePids` is what makes this work for an agent started in a split pane: without
            // it the walk climbs to that pane's shell, which no row's `shellPid` names, and falls
            // through to nil. Only reachable when the shim did not run — an agent invoked around
            // the wrapper — since the shim's `launch` frame binds the row directly.
            if let match = sessions.first(where: {
                $0.live?.pid == current || $0.live?.shellPid == current
                    || $0.live?.panePids.values.contains(current) == true
            }) {
                return match.id
            }
            guard let parent = ancestry.parent(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    // MARK: Observation

    func handle(_ event: ObservationEvent, from agent: AgentKind) {
        switch event {
        case .updated(let observation, let alive):
            let key = DescriptorKey(configDir: observation.configDir, pid: observation.pid)
            guard let id = sessionID(forObservation: observation, agent: agent) else {
                if externalDescriptors[key] == nil {
                    logger.info("external observation pid=\(observation.pid) \(Account.key(forConfigDirectory: observation.configDir), privacy: .public)")
                }
                externalDescriptors[key] = ExternalObservation(observation: observation, alive: alive, lastSeenAt: Date())
                return
            }
            externalDescriptors[key] = nil
            // The watcher hands us the agent's own descriptor; what crosses into the store is its
            // agent-blind projection (the file header's boundary rule).
            store.update { $0.applyObservation(observation, alive: alive, to: id, now: Date()) }
            // The descriptor's directory is where the agent *actually* keeps this session — truer
            // than the launch frame, which reports the shell's environment before it ran.
            learnAccount(configDir: observation.configDir, for: id, agent: agent)
        case .removed(let pid, let configDir):
            let key = DescriptorKey(configDir: configDir, pid: pid)
            externalDescriptors[key] = nil
            let bound = store.state.sessions.values.first { $0.live?.pid == pid }
            if let bound {
                store.update { $0.agentLost(for: bound.id, now: Date()) }
                onAgentExited?(bound.id)
            }
        }
    }

    /// `launch` binding → a row already carrying this pid → a row whose `conversationId` matches
    /// (a resumed conversation) → the process tree up to a session's shell.
    ///
    /// The first two joins are instance-local by construction (the pid came over *our* socket,
    /// or we bound it before). The last two are not: descriptors are global, two instances
    /// restore the same conversation ids from one `state.json`, and a dev build in a pane is
    /// itself under one of our shells — so both are gated on `ownsProcess`, and an agent process
    /// that is not ours is filed as external like any Terminal.app one.
    func sessionID(forObservation observation: AgentObservation, agent: AgentKind) -> SessionID? {
        let state = store.state
        if let id = pidToSession[observation.pid], state.sessions[id]?.live != nil { return id }
        if let match = state.sessions.values.first(where: { $0.live?.pid == observation.pid }) { return match.id }
        guard ownsProcess(observation.pid) else { return nil }
        // A watcher only ever describes its own agent's descriptor files, so this join must not
        // let a `conversationId` collision hand the descriptor to some other agent's row.
        if let match = state.sessions.values.first(where: {
            $0.agent == agent && $0.conversationId == observation.conversationId && $0.live != nil
                && $0.live?.observation == nil
        }) {
            return match.id
        }
        if let parent = ancestry.parent(of: observation.pid) { return sessionID(forProcess: parent) }
        return nil
    }

    // MARK: Queries

    /// The complete last Stop message, falling back to the 4 KiB the store keeps.
    public func lastMessage(for id: SessionID) -> String? {
        fullMessages[id] ?? store.state.sessions[id]?.live?.lastStopMessage
    }

    // MARK: Transcript (design 2c.5)

    /// Where this row's conversation is on disk: the path the hooks named, or — for a row that has
    /// no live agent and so never will — the file its adapter's `locate` finds from its account's
    /// config dir and its persisted `conversationId`.
    public func transcriptPath(for id: SessionID) -> String? {
        if let path = transcriptPaths[id] { return path }
        guard let session = store.state.sessions[id], let conversationId = session.conversationId,
              let adapter = adapters[session.agent]
        else { return nil }
        if let cached = locatedTranscripts[id],
           cached.conversationID == conversationId, cached.accountKey == session.accountKey {
            return cached.path
        }
        // The key namespace is shared across agents (`Account.agent`'s doc comment), so a
        // registered account under this key must also match the row's own agent before its
        // `configDir` is trusted — otherwise a Claude row could resolve into a Codex account that
        // happens to share a key.
        let configDir = store.state.accounts[session.accountKey]
            .flatMap { $0.agent == session.agent ? $0.configDir : nil }
            ?? Account.configDirectory(forKey: session.accountKey, home: home)
        guard let configDir else { return nil }
        let located = adapter.transcript.locate(
            conversationId: conversationId, configDir: configDir, fileManager: .default)
        locatedTranscripts[id] = (conversationId, session.accountKey, located)
        return located
    }

    /// The last summary read for this row, if any — what the card shows while a fresh read runs.
    public func cachedTranscriptSummary(for id: SessionID) -> TranscriptSummary? {
        transcriptSummaries[id]
    }

    /// Reads the row's transcript off the main queue and hands back a summary on it. A row with no
    /// transcript, or one whose file cannot be read, yields what the hooks know: the last Stop
    /// message as the recap. A torn or empty read keeps the previous summary rather than blanking.
    public func loadTranscriptSummary(
        for id: SessionID, completion: @escaping @MainActor @Sendable (TranscriptSummary) -> Void
    ) {
        let path = transcriptPath(for: id)
        let adapter = store.state.sessions[id].flatMap { adapters[$0.agent] }
        let box = WeakBox()
        box.value = self
        transcriptQueue.async {
            let fresh: TranscriptSummary? = path.flatMap { path in
                guard let adapter else { return nil }
                return try? adapter.transcript.summary(path: path)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = box.value else { return }
                    var summary = fresh ?? self.transcriptSummaries[id] ?? TranscriptSummary()
                    if fresh?.isEmpty == true, let previous = self.transcriptSummaries[id] { summary = previous }
                    self.mergeStopMessage(into: &summary, for: id)
                    self.transcriptSummaries[id] = summary
                    completion(summary)
                }
            }
        }
    }

    /// The hook's `last_assistant_message` is newer than an `away_summary` written before it, and
    /// it is all a transcript-less row has — so it wins over an older or missing recap, but never
    /// over a newer `away_summary`, which is the agent's considered summary rather than its last line.
    private func mergeStopMessage(into summary: inout TranscriptSummary, for id: SessionID) {
        guard let message = lastMessage(for: id), !message.isEmpty else { return }
        let stopAt = store.state.sessions[id]?.live?.lastStopAt
        switch summary.recapSource {
        case .awaySummary:
            if let recapAt = summary.recapAt, let stopAt, stopAt > recapAt.addingTimeInterval(1) {
                summary.recap = message
                summary.recapAt = stopAt
                summary.recapSource = .stopMessage
            }
        case .assistantText, .stopMessage, nil:
            summary.recap = message
            summary.recapAt = stopAt ?? summary.recapAt
            summary.recapSource = .stopMessage
        }
    }
}
