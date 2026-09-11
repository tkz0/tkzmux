// ClaudeIntegration — the app-side coordinator for M3 (TKZ-21…TKZ-25).
//
// `ClaudeBridge` ships two services that each know one thing: `HookServer` (frames from
// `tkzmux-hook`) and `ClaudeSessionWatcher` (descriptor files). Neither knows what a `Session` is.
// (`UsageReader` and the per-session sidecar reader are M3.5 / TKZ-25, still in the backlog; the
// account-label half of TKZ-25 is here, in `accountLabels(home:fileManager:)`.)
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
    /// Reads the two statusline sidecars `tkzmux-hook statusline` writes (TKZ-32). Present even
    /// when nothing has been installed yet — the directory simply stays empty and the sweep keeps
    /// looking, so the badges light up the moment the user consents.
    public let statusline: StatuslineReader
    /// Writes `statusLine` into the user's `settings.json`. `nil` when the hook binary isn't
    /// installed, exactly like `installer`.
    public let statuslineInstaller: StatuslineInstaller?

    /// `launch`-frame bindings. A session that exits keeps its entry until the pid is reused by a
    /// later `launch`, which simply overwrites it.
    ///
    /// Internal setter rather than `private(set)` so the eviction tests can seed a binding; both
    /// this and `fullMessages` are dropped by ``forget(_:)``.
    var pidToSession: [pid_t: SessionID] = [:]
    /// The whole last Stop message per session (see the file header). Internal for the same reason.
    var fullMessages: [SessionID: String] = [:]
    /// `payload.transcript_path` from the last attributed hook frame per session — where Claude
    /// keeps the conversation the first-prompt card (design 2c.5) reads. Process state like
    /// `fullMessages`: a restored row has none and falls back to `TranscriptReader.locate`.
    var transcriptPaths: [SessionID: String] = [:]
    /// The last good `TranscriptReader` result per session, so reopening the card is instant and a
    /// torn read never blanks it. Same lifecycle as `fullMessages`.
    var transcriptSummaries: [SessionID: TranscriptSummary] = [:]
    /// Transcript reads happen here, never on the main queue: a `/loop` transcript is tens of
    /// megabytes and even the capped head+tail read is two file seeks and a JSON pass.
    private let transcriptQueue = DispatchQueue(label: "se.tkz.tkzmux.transcript", qos: .userInitiated)
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

    /// A `Stop` hook landed for this row — Claude has finished a turn, and whatever it did to the
    /// working tree is on disk now. `GitIntegration` (M4) refreshes git and re-scans ports on it;
    /// it is the one moment a refresh is worth making unconditionally, for any row.
    public var onStop: ((SessionID) -> Void)?

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

        // Accounts are discovered, never hard-coded: `~/.claude` plus every `~/.claude-*` that
        // looks like a config dir, plus whatever the store already knows, plus the account of every
        // persisted row (a resume must find its descriptor in *that* account's `sessions/`).
        let discovered = Self.discoverAccounts(home: home)
        let labels = Self.accountLabels(home: home)
        var accounts = store.state.accounts
        for account in discovered where accounts[account.key] == nil { accounts[account.key] = account }
        for session in store.state.sessions.values where accounts[session.accountKey] == nil {
            if let dir = Account.configDirectory(forKey: session.accountKey, home: home) {
                accounts[session.accountKey] = Account(
                    key: session.accountKey, configDir: dir,
                    label: labels[session.accountKey] ?? session.accountKey)
            }
        }
        var configDirs: [String] = []
        for key in accounts.keys.sorted() where !configDirs.contains(accounts[key]!.configDir) {
            configDirs.append(accounts[key]!.configDir)
        }
        watchedConfigDirs = configDirs

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
        statusline = StatuslineReader(
            directory: StatuslineReader.standardDirectory(supportDirectory: directory)
        ) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { box.value?.handle(event) } }
        }
        statuslineInstaller = StatuslineInstaller(directory: directory)
        box.value = self

        let toRegister = accounts.values.filter { store.state.accounts[$0.key] == nil }
        if !toRegister.isEmpty {
            store.update { state in for account in toRegister { state.setAccount(account) } }
        }
    }

    /// The config dirs the watcher is currently pointed at, in registration order.
    public private(set) var watchedConfigDirs: [String]

    /// `~/.claude` (always) and every `~/.claude-*` directory that carries `settings.json`,
    /// `sessions/` or `.claude.json` — the discovery rule sketched for M3.5, brought forward
    /// because a second account that is never watched is a second account whose sessions never
    /// get a status, a title or a badge. Nothing here names a particular account: the names come
    /// from ``accountLabels(home:fileManager:)``, and a key with no entry there is its own label.
    public static func discoverAccounts(home: String, fileManager: FileManager = .default) -> [Account] {
        let labels = accountLabels(home: home, fileManager: fileManager)
        var out: [Account] = []
        let primary = (home as NSString).appendingPathComponent(".claude")
        out.append(
            Account(
                key: Account.defaultKey, configDir: primary,
                label: labels[Account.defaultKey] ?? Account.defaultKey))
        let entries = (try? fileManager.contentsOfDirectory(atPath: home)) ?? []
        for name in entries.sorted() where name.hasPrefix(".claude-") {
            let path = (home as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let markers = ["settings.json", "sessions", ".claude.json"]
            guard markers.contains(where: { fileManager.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }) else { continue }
            let key = Account.key(forConfigDirectory: path)
            out.append(Account(key: key, configDir: path, label: labels[key] ?? key))
        }
        return out
    }

    /// The account-label overlay: `~/.claude/dash-accounts.json`, shape
    /// `{"labels": {"<account key>": "<display name>"}}`.
    ///
    /// This is the only place a **human-written** account name comes from, and CLAUDE.md is
    /// explicit that names belong in config rather than in code — so the file is read and no name
    /// is ever spelled out here. It is read from the *primary* config dir, not per-account: the
    /// point is one table naming all of them, and an account cannot name itself before it is
    /// discovered.
    ///
    /// Written by another program, so decoding is forgiving in the same way the descriptor is: a
    /// missing file, a torn write or a non-string value yields no overlay at all, and every key
    /// then falls back to being its own label. Empty and whitespace-only names are dropped —
    /// a blank chip would be worse than `ALT`.
    public static func accountLabels(
        home: String, fileManager: FileManager = .default
    ) -> [String: String] {
        let path = (home as NSString)
            .appendingPathComponent(".claude/dash-accounts.json")
        guard let data = fileManager.contents(atPath: path),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let labels = root["labels"] as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in labels {
            guard let name = value as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out[key] = trimmed }
        }
        return out
    }

    /// A process announced which config dir it really runs under. Registers the account if it is
    /// new, watches its `sessions/` if it is not watched, and corrects the row's `accountKey` —
    /// the user's environment (a shell rc, a wrapper) may have picked a different account than the
    /// launcher asked for, and the chip, the descriptor join and every later resume must follow
    /// the process, not the request.
    func learnAccount(configDir: String, for id: SessionID) {
        let trimmed = configDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let standardized = (trimmed as NSString).standardizingPath
        let key = Account.key(forConfigDirectory: standardized)
        guard !key.isEmpty else { return }
        let known = store.state.accounts[key]
        // Only a *new* account needs a name looked up. This method runs on every launch frame and
        // every descriptor update — several times a minute per session — and `accountLabels` reads
        // and parses a file, so it must not be on that path for an account we already know.
        let label = known == nil ? (Self.accountLabels(home: home)[key] ?? key) : key
        store.update { state in
            if known == nil {
                state.setAccount(Account(key: key, configDir: standardized, label: label))
            }
            state.setSessionAccount(id, key: key)
        }
        let dir = known?.configDir ?? standardized
        if !watchedConfigDirs.contains(dir) {
            logger.info("watching account \(key, privacy: .public) at \(dir, privacy: .public)")
            watchedConfigDirs.append(dir)
            watcher.setConfigDirs(watchedConfigDirs)
        }
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
        watcher.stop()
        statusline.stop()
        hookServer.stop()
    }

    // MARK: Statusline sidecars

    /// Quota and per-session context, posted straight into the store. Unlike hook frames these need
    /// no attribution work: usage is keyed by account and context joins on Claude's own session id.
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
                state.clearSessionSidecar(claudeSessionId: sessionId)
            }
        }
    }

    /// Which producer, if any, is feeding the statusline for an account's config dir.
    public func statuslineProducer(accountKey: String) -> StatuslineProducer {
        guard let installer = statuslineInstaller,
              let configDir = store.state.accounts[accountKey]?.configDir
        else { return .none }
        return installer.detect(configDir: configDir)
    }

    public func statuslinePlan(accountKey: String) throws -> StatuslineInstallPlan? {
        guard let installer = statuslineInstaller,
              let configDir = store.state.accounts[accountKey]?.configDir
        else { return nil }
        return try installer.plan(configDir: configDir, accountKey: accountKey)
    }

    public func installStatusline(accountKey: String) throws {
        guard let installer = statuslineInstaller,
              let configDir = store.state.accounts[accountKey]?.configDir
        else { return }
        try installer.install(configDir: configDir, accountKey: accountKey)
    }

    public func uninstallStatusline(accountKey: String) throws {
        guard let installer = statuslineInstaller,
              let configDir = store.state.accounts[accountKey]?.configDir
        else { return }
        try installer.uninstall(configDir: configDir, accountKey: accountKey)
    }

    /// Drops every per-session entry for `id`. Called when the row is removed.
    ///
    /// `fullMessages` is the one that matters: a Stop message is an arbitrarily long string (a
    /// pasted diff, a log dump), and without this the app keeps one per session id it has *ever*
    /// seen, for as long as it runs. `pidToSession` is small but has the same shape.
    public func forget(_ id: SessionID) {
        fullMessages.removeValue(forKey: id)
        transcriptPaths.removeValue(forKey: id)
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

    private func tickFired() {
        store.update { $0.rederiveStatuses(now: Date()) }
    }

    // MARK: Hook frames

    func handle(_ frame: HookFrame) {
        switch frame {
        case .launch(let launch):
            bind(launch)
        case .hook(let event, let ppid, let fullMessage, _, let transcriptPath):
            guard let id = sessionID(forHook: event, ppid: ppid) else {
                logger.info("unattributed hook \(String(describing: event.kind), privacy: .public) sid=\(event.sessionID?.rawValue ?? "-", privacy: .public) ppid=\(ppid)")
                return
            }
            logger.info("hook \(String(describing: event.kind), privacy: .public) → \(id.rawValue, privacy: .public)")
            if event.kind == .stop, let fullMessage { fullMessages[id] = fullMessage }
            if let transcriptPath, !transcriptPath.isEmpty { transcriptPaths[id] = transcriptPath }
            let attended = event.kind == .stop && isSessionAttended(id)
            store.update { state in
                let now = Date()
                state.applyHook(event, to: id, now: now)
                if attended { state.markAttended(id, now: now) }
            }
            if event.kind == .stop { onStop?(id) }
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
        logger.info("launch pid \(launch.pid) → \(id.rawValue, privacy: .public) config_dir=\(launch.configDir, privacy: .public)")
        pidToSession[launch.pid] = id
        // Which pane the frame came from, resolved *before* the descriptor below is applied —
        // applying a live descriptor is what clears `claudeStartup`, the cheap answer.
        let terminal = claudeTerminal(for: launch, in: id)
        store.update { state in
            state.updateLive(id) { $0.pid = launch.pid }
            state.setClaudeTerminal(id, terminal)
        }
        learnAccount(configDir: launch.configDir, for: id)
        for (key, state) in watcher.snapshot() where state.info.pid == launch.pid {
            // Seen before the frame: it was filed as external; it has an owner now.
            externalDescriptors[key] = nil
            store.update { $0.applyDescriptor(state.info, alive: state.alive, to: id, now: Date()) }
            learnAccount(configDir: state.info.configDir, for: id)
        }
    }

    /// The pane whose shell is running the `claude` the shim just announced. A boot command or a
    /// resume recorded its pane in `claudeStartup`; a `claude` typed by hand in a split did not,
    /// so the frame's pid (the shim's `$$`, a child of the pane's login shell) is walked up
    /// `panePids` the same way `sessionID(forProcess:)` walks it. `nil` when neither places it;
    /// `GitIntegration` then falls back to "the row's only pane".
    func claudeTerminal(for launch: LaunchAnnouncement, in id: SessionID) -> TerminalID? {
        guard let live = store.state.sessions[id]?.live else { return nil }
        if let startup = live.claudeStartup { return startup.terminal }
        guard !live.panePids.isEmpty else { return nil }
        var current = launch.pid
        for _ in 0..<8 {
            guard current > 1 else { return nil }
            if let match = live.panePids.first(where: { $0.value == current }) { return match.key }
            guard let parent = ProcessTree.parent(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
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
            // `panePids` is what makes this work for a `claude` started in a split pane: without
            // it the walk climbs to that pane's shell, which no row's `shellPid` names, and falls
            // through to nil. Only reachable when the shim did not run — a `claude` invoked around
            // the wrapper — since the shim's `launch` frame binds the row directly.
            if let match = sessions.first(where: {
                $0.live?.pid == current || $0.live?.shellPid == current
                    || $0.live?.panePids.values.contains(current) == true
            }) {
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
            // The descriptor's directory is where Claude *actually* keeps this session — truer
            // than the launch frame, which reports the shell's environment before Claude ran.
            learnAccount(configDir: info.configDir, for: id)
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

    // MARK: Transcript (design 2c.5)

    /// Where this row's Claude conversation is on disk: the path the hooks named, or — for a row
    /// that has no live Claude and so never will — the file under its account's `projects/` that
    /// carries its persisted `claudeSessionId`.
    public func transcriptPath(for id: SessionID) -> String? {
        if let path = transcriptPaths[id] { return path }
        guard let session = store.state.sessions[id], let claudeID = session.claudeSessionId else { return nil }
        let configDir = store.state.accounts[session.accountKey]?.configDir
            ?? Account.configDirectory(forKey: session.accountKey, home: home)
        guard let configDir else { return nil }
        return TranscriptReader.locate(sessionId: claudeID, configDir: configDir)
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
        let box = WeakBox()
        box.value = self
        transcriptQueue.async {
            let fresh = path.flatMap { try? TranscriptReader.read(path: $0) }
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
    /// over a newer `away_summary`, which is Claude's considered summary rather than its last line.
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
