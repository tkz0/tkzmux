// SessionLauncher — every way a shell gets behind a sidebar row (M5.2 / TKZ-30).
//
// design.md → *Session flows & persistence*. The window controller used to own `launch(_:)`
// directly (M2.5); this type takes that over and adds the rest of the lifecycle:
//
//   * `start(_:)`   — a *new* row: `Session` in the store → `TerminalHost.open` in the launch
//                     directory with the account's `CLAUDE_CONFIG_DIR` → the command typed once
//                     the shell is ready → the shim's `launch` frame binds the pid (ClaudeIntegration).
//   * `reopen(_:)`  — a row with **no shell behind it** (restored from `state.json`, or hung up
//                     with ⌘W): its `.ghsnap` — the live grid if the host still holds it, else the
//                     file on disk — is restored under a fresh shell, so the user sees the old
//                     content with a new prompt beneath it. Happens lazily, the first time the row
//                     is shown, and is also the first half of a resume.
//   * `resume(_:)`  — `claude --resume <claudeSessionId>` in the directory the conversation lives
//                     in: the worktree while it still exists, else where the session started, else
//                     the repo root. A worktree that is gone clears the `WT` badge.
//   * `remove(_:)`  — the row, its shell and its snapshot go (the worktree on disk is never
//                     touched). There is no "closed but kept" row: ⌘W removes.
//   * `noteExit(_:)` — after a shell or Claude exits, re-read `git worktree list --porcelain` for
//                     that repo (debounced) and drop the badge from rows whose worktree Claude
//                     removed on its way out.
//
// ## Two rules that are easy to lose
//
// **The account follows the session, not the store's account table.** Accounts are discovered,
// never persisted, and today nothing discovers a second one — so after a relaunch every row's
// `accountKey` names an account the store has never heard of. The env is therefore derived from
// the key (`~/.<key>`, the inverse of design.md's account-key rule) whenever the table has no
// entry, and only the primary key means "leave `CLAUDE_CONFIG_DIR` unset". A resume on the wrong
// account is the one failure the ticket singles out.
//
// **Directories are checked here, not by the pty.** `tkz_pty_spawn` runs `chdir` after `fork()`
// and cannot report a failure, so a missing directory would start the shell somewhere else and the
// resume would land in the wrong project. Every path is validated before `open`/`restore`.

import Darwin
import Foundation
import GitStatus
import TkzCore
import TkzTerminalCore
import os

@MainActor
public final class SessionLauncher {
    /// A launch, as the new-session menu resolves it.
    public typealias Spec = NewSessionMenu.Launch

    public enum Failure: Error, Equatable, Sendable {
        /// The directory to start in does not exist. Carries the path that was tried.
        case missingDirectory(String)
        case spawnFailed(String)
        case unknownSession
    }

    public let store: AppStore
    public let host: any TerminalHost
    /// The user's home: tilde expansion and the derived `~/.<key>` config dirs.
    public let home: String

    /// The grid a terminal opens at. The window supplies the *pane's* real grid — a split pane
    /// is half the size of the one it came from, and spawning at the whole window's grid would
    /// make every new pane reflow on its first frame.
    public var gridSize: (TerminalID) -> TerminalSize = { _ in TerminalSize(rows: 40, cols: 120) }
    /// `git worktree list --porcelain` for a repo root. Injected so tests never run git.
    public var worktreeLister: @Sendable (String) throws -> [String] = { try WorktreeList.list(repoRoot: $0) }
    /// How long after an exit the worktree list is re-read. Coalesces a burst of exits in one repo.
    public var worktreeRefreshDelay: Duration = .milliseconds(300)
    /// Called after a worktree refresh has been applied to the store. Tests wait on it.
    public var onWorktreesRefreshed: ((String, [String]) -> Void)?

    /// Called by ``remove(_:)`` after the row is gone, so per-session caches elsewhere can drop
    /// their entry. `MainWindowController` wires it to the Claude and git integrations.
    public var onRemoved: ((SessionID) -> Void)?

    private let fileManager: FileManager
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "launch")
    private var pendingWorktreeRefresh: [String: Task<Void, Never>] = [:]

    public init(
        store: AppStore,
        host: any TerminalHost,
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.host = host
        self.home = home
        self.fileManager = fileManager
    }

    // MARK: - Start

    /// A new row: spawn the pty, put the session in the store, select it, type the command.
    ///
    /// Selection is what makes the terminal visible — the window's store observer calls
    /// `host.show`. Nothing here shows anything.
    @discardableResult
    public func start(_ spec: Spec) -> Result<SessionID, Failure> {
        let cwd = Paths.expandingTilde(spec.cwd, home: home)
        guard isDirectory(cwd) else { return .failure(.missingDirectory(cwd)) }

        let id = SessionID.generate()
        // `Session.init` seeds its first leaf with the row's own uuid; matching it here is what
        // keeps "a `.ghsnap` basename maps back to its row" true for new rows as well as migrated
        // ones (see `Migrations.liftV1ToV2`).
        let terminal = TerminalID(uuid: id.uuid)
        let env = environment(accountKey: spec.accountKey, extra: spec.env)
        let pid: pid_t
        do {
            pid = try host.open(
                terminal, session: id, cwd: cwd, env: env, size: gridSize(terminal))
        } catch {
            logger.error("spawn failed: \(String(describing: error), privacy: .public)")
            return .failure(.spawnFailed(String(describing: error)))
        }

        store.update {
            // `cwd` goes in **unexpanded**: the models keep paths as written (`state.json` persists
            // them) and expansion belongs at the `chdir` boundary above.
            $0.createSession(
                id: id, groupID: spec.groupID, cwd: spec.cwd,
                accountKey: spec.accountKey, presetID: spec.presetID)
            // `live` is what says the row has a shell; without it the reopen path would fire.
            $0.setLive(
                LiveSessionState(shellPid: pid, status: .idle, panePids: [terminal: pid]),
                for: id)
            $0.select(id)
        }

        // `.shell` types nothing. Everything else waits for the shell to be ready first — a write
        // in the same turn as the spawn is discarded by zsh's `tcsetattr(TCSAFLUSH)` (M1.10).
        if !spec.command.isEmpty {
            host.runWhenReady(terminal, command: spec.command)
        }
        logLaunch(kind: spec.kind.rawValue, id: id, cwd: cwd, env: env, command: spec.command)
        return .success(id)
    }

    // MARK: - Reopen

    /// What `reopen` did.
    public enum ReopenOutcome: Equatable, Sendable {
        /// A shell was already running; nothing to do.
        case alreadyRunning
        /// A fresh shell was spawned in `directory`; `restoredContent` says whether the old screen
        /// came back with it.
        case reopened(directory: String, restoredContent: Bool)
    }

    /// Puts a shell behind a row that has none: the old content (if any snapshot exists) under a
    /// fresh prompt, in the directory a resume would use. Does **not** type anything.
    ///
    /// The worktree/cwd/repo-root fallback is resolved here and the `WT` badge cleared when the
    /// worktree is what went missing — so a row whose worktree Claude removed reads correctly the
    /// moment it is reopened, resume or not.
    ///
    /// Only the **active tab's** panes are reopened. A background tab's terminals come back when
    /// that tab is first selected (`MainWindowController.applySelection`), which mirrors the
    /// existing lazy-on-first-show rule for rows and keeps a four-tab row from spawning eight
    /// shells the moment it is clicked. Nothing is lost by waiting: their `.ghsnap` files stay on
    /// disk, because snapshot housekeeping keeps every leaf of every tab.
    @discardableResult
    public func reopen(_ id: SessionID) -> Result<ReopenOutcome, Failure> {
        guard let session = store.state.sessions[id] else { return .failure(.unknownSession) }
        if session.live != nil { return .success(.alreadyRunning) }

        let resolved = resolveDirectory(for: session)
        guard let cwd = resolved.directory else {
            logger.error("reopen \(id.rawValue, privacy: .public): no directory (tried \(resolved.tried.joined(separator: ", "), privacy: .public))")
            return .failure(.missingDirectory(resolved.tried.first ?? session.cwd))
        }
        if resolved.worktreeLost {
            logger.info("reopen \(id.rawValue, privacy: .public): worktree gone, falling back to \(cwd, privacy: .public)")
            store.update { $0.clearWorktreeBadge(id) }
        }

        let env = environment(accountKey: session.accountKey, extra: [:])
        let focused = session.focusedTerminalID
        var pids: [TerminalID: pid_t] = [:]
        var restoredContent = false
        var firstFailure: Failure?

        for terminal in session.activeTabValue.terminalIDs {
            switch spawnTerminal(terminal, in: id, cwd: cwd, env: env) {
            case .success(let outcome):
                pids[terminal] = outcome.pid
                if outcome.restoredContent { restoredContent = true }
            case .failure(let failure):
                // One pane that will not come back must not cost the user the whole row: log it,
                // drop that leaf, and carry on with the rest of the tab.
                logger.error(
                    "reopen \(terminal.rawValue, privacy: .public): \(String(describing: failure), privacy: .public)"
                )
                firstFailure = firstFailure ?? failure
                store.update { _ = $0.closePane(terminal) }
            }
        }

        guard !pids.isEmpty else { return .failure(firstFailure ?? .spawnFailed("no pane spawned")) }

        // `live` stays row-level by design (TKZ-36): the row's `shellPid` is the focused pane's,
        // and `panePids` carries the rest so the port scanner and the hook relay's ppid fallback
        // can see a shell in any pane.
        let shellPid = pids[focused] ?? pids.first?.value
        store.update {
            $0.setLive(
                LiveSessionState(shellPid: shellPid, status: .idle, panePids: pids), for: id)
        }
        logLaunch(kind: "reopen", id: id, cwd: cwd, env: env, command: "")
        return .success(.reopened(directory: cwd, restoredContent: restoredContent))
    }

    /// One pane's share of a reopen: its old screen from a snapshot if there is one, under a fresh
    /// shell, else just the shell. Also the whole of `reopenTerminal`, below.
    private func spawnTerminal(
        _ terminal: TerminalID, in id: SessionID, cwd: String, env: [String: String]
    ) -> Result<(pid: pid_t, restoredContent: Bool), Failure> {
        // The live grid first: after a hang-up the host still holds the screen exactly as the shell
        // left it, which is fresher than anything on disk. Then the `.ghsnap` from the last quit.
        let snapshot = (try? host.snapshot(terminal)) ?? host.savedSnapshot(terminal)
        do {
            if let snapshot, !snapshot.isEmpty {
                do {
                    let pid = try host.restore(
                        terminal, session: id, from: snapshot, cwd: cwd, env: env)
                    return .success((pid, true))
                } catch {
                    // A snapshot that no longer decodes must not make the row unusable: the
                    // conversation is Claude's, the screen was only ever a convenience.
                    logger.error("snapshot restore failed for \(terminal.rawValue, privacy: .public): \(String(describing: error), privacy: .public); opening a fresh shell")
                }
            }
            let pid = try host.open(
                terminal, session: id, cwd: cwd, env: env, size: gridSize(terminal))
            return .success((pid, false))
        } catch {
            logger.error("reopen spawn failed: \(String(describing: error), privacy: .public)")
            return .failure(.spawnFailed(String(describing: error)))
        }
    }

    /// Puts a shell behind **one** pane that has none — how a background tab's terminals come back
    /// when it is first selected. `reopen` handles a whole row; this is its per-pane half.
    @discardableResult
    public func reopenTerminal(_ terminal: TerminalID) -> Result<Bool, Failure> {
        guard let session = store.state.session(owning: terminal) else {
            return .failure(.unknownSession)
        }
        if host.contains(terminal) { return .success(false) }

        let resolved = resolveDirectory(for: session)
        guard let cwd = resolved.directory else {
            return .failure(.missingDirectory(resolved.tried.first ?? session.cwd))
        }
        let env = environment(accountKey: session.accountKey, extra: [:])
        switch spawnTerminal(terminal, in: session.id, cwd: cwd, env: env) {
        case .success(let outcome):
            store.update { $0.setPanePid(terminal, pid: outcome.pid) }
            logLaunch(kind: "reopen-pane", id: session.id, cwd: cwd, env: env, command: "")
            return .success(true)
        case .failure(let failure):
            store.update { _ = $0.closePane(terminal) }
            return .failure(failure)
        }
    }

    // MARK: - Extra terminals

    /// ⌘T / ⌘D / ⇧⌘D: a bare shell in a new pane or a new tab. Types nothing, ever.
    ///
    /// The pane starts in the **source pane's** directory when the shell has told us one — "split
    /// here" should land where the user is standing — falling back to the row's resume directory.
    @discardableResult
    public func addTerminal(
        to id: SessionID, splitting axis: PaneAxis? = nil
    ) -> Result<TerminalID, Failure> {
        guard let session = store.state.sessions[id] else { return .failure(.unknownSession) }
        let source = session.focusedTerminalID

        let cwd = Paths.expandingTilde(
            store.state.paneCwd(source) ?? resolveDirectory(for: session).directory ?? session.cwd,
            home: home)
        guard isDirectory(cwd) else { return .failure(.missingDirectory(cwd)) }

        var created: TerminalID?
        store.updating { state in
            if let axis {
                created = state.splitPane(source, axis: axis)
            } else {
                created = state.addTab(to: id)
            }
        }
        guard let terminal = created else { return .failure(.spawnFailed("the tab is full")) }

        let env = environment(accountKey: session.accountKey, extra: [:])
        do {
            let pid = try host.open(
                terminal, session: id, cwd: cwd, env: env, size: gridSize(terminal))
            store.update { $0.setPanePid(terminal, pid: pid) }
            logLaunch(
                kind: axis == nil ? "tab" : "split", id: id, cwd: cwd, env: env, command: "")
            return .success(terminal)
        } catch {
            // The store and the host must stay in step, or the row grows a pane with no shell that
            // nothing can ever close.
            store.update { _ = $0.closePane(terminal) }
            logger.error("new terminal failed: \(String(describing: error), privacy: .public)")
            return .failure(.spawnFailed(String(describing: error)))
        }
    }

    /// ⌘W on a pane, and a pane whose shell exited: close that leaf, and only if it was the row's
    /// last one does the row itself go.
    public func closeTerminal(_ terminal: TerminalID) {
        guard let session = store.state.session(owning: terminal) else { return }
        if session.terminalCount == 1 {
            // `remove` discards every leaf of the row, this one included — discarding here first
            // would double it, which a spy host notices and a real one silently tolerates.
            noteExit(session.id)
            remove(session.id)
        } else {
            host.discard(terminal)
            store.update { _ = $0.closePane(terminal) }
        }
    }

    // MARK: - Resume

    /// What `resume` did.
    public enum ResumeOutcome: Equatable, Sendable {
        /// Claude is already running in this row (a descriptor is bound); nothing typed.
        case claudeRunning
        /// The row has no `claudeSessionId` to resume; the shell was (re)opened and that is all.
        case nothingToResume
        /// `claude --resume <id>` was typed into the row's shell.
        case resumed(claudeSessionId: String)
    }

    /// `claude --resume <claudeSessionId>` in the row's shell, reopening it first if it has none.
    @discardableResult
    public func resume(_ id: SessionID, select: Bool = true) -> Result<ResumeOutcome, Failure> {
        guard let before = store.state.sessions[id] else { return .failure(.unknownSession) }
        if before.live?.descriptor != nil { return .success(.claudeRunning) }

        let hadShell = before.live != nil
        if !hadShell {
            if case .failure(let failure) = reopen(id) { return .failure(failure) }
        }
        if select { store.update { $0.select(id) } }

        guard let claudeSessionId = before.claudeSessionId, !claudeSessionId.isEmpty else {
            return .success(.nothingToResume)
        }
        let command = "claude --resume \(claudeSessionId)"
        // A shell that was already sitting at its prompt produces no output for `runWhenReady`
        // to wait on, and would only get the bytes after that path's timeout.
        // Into the focused pane: a resume is something the user asked for while looking at one
        // particular terminal.
        let terminal = store.state.sessions[id]?.focusedTerminalID ?? TerminalID(uuid: id.uuid)
        if hadShell {
            host.run(terminal, command: command)
        } else {
            host.runWhenReady(terminal, command: command)
        }
        logger.info("resume \(id.rawValue, privacy: .public): \(command, privacy: .public)")
        return .success(.resumed(claudeSessionId: claudeSessionId))
    }

    /// "Resume all in group": every row in `groupID` that has a conversation to resume and no
    /// Claude running. The selection stays where it is. Returns the ids resumed and the failures.
    @discardableResult
    public func resumeAll(in groupID: GroupID) -> (resumed: [SessionID], failed: [(SessionID, Failure)]) {
        resumeAll(store.state.sessions(in: groupID).map(\.id))
    }

    /// The auto-resume-on-launch pass: every restored row with a `claudeSessionId`.
    @discardableResult
    public func resumeAll(_ ids: [SessionID]) -> (resumed: [SessionID], failed: [(SessionID, Failure)]) {
        var resumed: [SessionID] = []
        var failed: [(SessionID, Failure)] = []
        for id in ids {
            guard let session = store.state.sessions[id],
                  session.claudeSessionId != nil, session.live?.descriptor == nil
            else { continue }
            switch resume(id, select: false) {
            case .success(.resumed): resumed.append(id)
            case .success: break
            case .failure(let failure): failed.append((id, failure))
            }
        }
        return (resumed, failed)
    }

    // MARK: - Close / remove

    /// Remove (⌘W, the row's `×`, a shell that ended): the row, its shell and its snapshot go
    /// away. Never touches the worktree on disk.
    public func remove(_ id: SessionID) {
        // Read the leaves *before* the store mutation: afterwards the row is gone and with it any
        // way to find the `.ghsnap` files its panes owned.
        for terminal in store.state.sessions[id]?.terminalIDs ?? [] { host.discard(terminal) }
        store.update { $0.removeSession(id) }
        // Everything else that keys state by session id gets told here. Without it those caches
        // keep one entry per session the process has *ever* seen. `removeGroup` below is the other
        // path a row can leave by and fires the same hook — any third one must too.
        onRemoved?(id)
    }

    /// Remove a whole group: every member's shell and snapshot go the way `remove(_:)` sends one,
    /// then the group and its rows leave in a single change set — one sidebar diff, one selection
    /// pass, rather than N of each. The reducer's own `removeGroup` never touches `host`, which is
    /// the whole reason this lives here. Never touches a worktree on disk.
    public func removeGroup(_ id: GroupID) {
        let members = store.state.sessions(in: id).map(\.id)
        for member in members { host.discard(member) }
        store.update { $0.removeGroup(id) }
        // Same per-session cache eviction `remove(_:)` does — a row leaving with its group is
        // still a row leaving, and `fullMessages` holds an arbitrarily long string per id.
        for member in members { onRemoved?(member) }
    }

    // MARK: - Worktrees after an exit

    /// A shell exited or Claude ended: schedule a re-read of that repo's worktree list.
    public func noteExit(_ id: SessionID) {
        guard let session = store.state.sessions[id] else { return }
        guard let root = session.repoRoot, !root.isEmpty else { return }
        refreshWorktrees(repoRoot: root)
    }

    /// Debounced per repo root. The git call runs off the main actor; the result is applied on it.
    public func refreshWorktrees(repoRoot: String) {
        let expandedRoot = Paths.expandingTilde(repoRoot, home: home)
        pendingWorktreeRefresh[expandedRoot]?.cancel()
        let delay = worktreeRefreshDelay
        let lister = worktreeLister
        pendingWorktreeRefresh[expandedRoot] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let listed = await Task.detached(priority: .utility) { () -> [String]? in
                try? lister(expandedRoot)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.pendingWorktreeRefresh[expandedRoot] = nil
            guard let listed else { return }
            self.applyWorktrees(listed, repoRoot: expandedRoot)
        }
    }

    /// Drops the `WT` badge from every row of `repoRoot` whose worktree git no longer lists.
    func applyWorktrees(_ listed: [String], repoRoot: String) {
        let home = self.home
        store.update { state in
            for session in state.sessions.values where session.isWorktree {
                guard let sessionRoot = session.repoRoot,
                      Paths.expandingTilde(sessionRoot, home: home) == repoRoot,
                      let worktree = session.worktreePath
                else { continue }
                let expanded = Paths.expandingTilde(worktree, home: home)
                if !WorktreeList.contains(listed, path: expanded) {
                    state.clearWorktreeBadge(session.id)
                }
            }
        }
        onWorktreesRefreshed?(repoRoot, listed)
    }

    // MARK: - Environment

    /// `CLAUDE_CONFIG_DIR` for the account named by `accountKey` — the primary included — then
    /// the caller's extras on top. `nil` means "no account was chosen": the variable is left
    /// alone, the user's environment decides, and the shim's `launch` frame reports what that was
    /// (`ClaudeIntegration.learnAccount`).
    ///
    /// The same value goes out as `TKZMUX_CLAUDE_CONFIG_DIR`: the ZDOTDIR wrapper re-exports it
    /// after the user's own rc files have run, so an `export CLAUDE_CONFIG_DIR=…` in a `.zshrc`
    /// cannot override an account the user picked in the app.
    public func environment(accountKey: String?, extra: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        if let key = accountKey, let dir = configDirectory(forKey: key) {
            env["CLAUDE_CONFIG_DIR"] = dir
            env["TKZMUX_CLAUDE_CONFIG_DIR"] = dir
        }
        env.merge(extra) { _, override in override }
        return env
    }

    /// The store's account when it has one (its `configDir` is authoritative — it may live
    /// somewhere unusual), else the derived `~/.<key>`.
    public func configDirectory(forKey key: String) -> String? {
        if let account = store.state.accounts[key] { return account.configDir }
        return Account.configDirectory(forKey: key, home: home)
    }

    // MARK: - Directories

    struct ResolvedDirectory {
        /// The first candidate that exists, or nil.
        var directory: String?
        /// Every candidate tried, in order, expanded.
        var tried: [String]
        /// The session claimed a worktree and it is not there.
        var worktreeLost: Bool
    }

    func resolveDirectory(for session: Session) -> ResolvedDirectory {
        var tried: [String] = []
        for (index, candidate) in session.resumeDirectoryCandidates.enumerated() {
            let expanded = Paths.expandingTilde(candidate, home: home)
            tried.append(expanded)
            if isDirectory(expanded) {
                let worktreeLost = session.isWorktree && index > 0
                return ResolvedDirectory(directory: expanded, tried: tried, worktreeLost: worktreeLost)
            }
        }
        return ResolvedDirectory(directory: nil, tried: tried, worktreeLost: session.isWorktree)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Audit log

    /// One line per launch in the unified log, category `launch`, everything public: this is the
    /// "no wrong-account launches" audit the ticket asks for (docs/perf.md → *Launch audit*).
    private func logLaunch(kind: String, id: SessionID, cwd: String, env: [String: String], command: String) {
        let account = env["CLAUDE_CONFIG_DIR"] ?? "default"
        let extras = env.keys.filter { $0 != "CLAUDE_CONFIG_DIR" }.sorted()
            .map { "\($0)=\(env[$0] ?? "")" }.joined(separator: " ")
        logger.info("launch kind=\(kind, privacy: .public) session=\(id.rawValue, privacy: .public) cwd=\(cwd, privacy: .public) CLAUDE_CONFIG_DIR=\(account, privacy: .public) env=[\(extras, privacy: .public)] cmd=\(command, privacy: .public)")
    }
}
