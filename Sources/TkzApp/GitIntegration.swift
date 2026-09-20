// GitIntegration — the app-side coordinator for M4.
//
// `GitStatus` ships three services that each know one thing and none of which knows what a
// `Session` is: `GitStatusService` (branch, diffstat, ahead/behind, FSEvents), `PRLookup`
// (`gh pr view`, gated on a github.com origin) and `PortScanner` (libproc). This type is the one
// place their facts are attributed to rows and posted into the store — the same shape as
// `ClaudeIntegration` for M3, and for the same reason: the services stay testable without a store
// and the store stays free of process state that arrives on foreign queues.
//
// Cadence:
//
//   | Fact  | When it is refreshed |
//   |---|---|
//   | git   | FSEvents on the repo (300 ms debounce, ≤ 1 / 2 s), after each Stop hook, on selection if > 10 s old |
//   | ports | on selection, after each Stop hook, and every 10 s **while selected** |
//   | PR    | on selection, on a branch change, after each Stop hook (≥ 15 s apart, any row), and every 5 min for every row whose PR is open; `PRLookup` throttles and caches failures for 10 |
//
// Non-selected rows are deliberately cheap: their git comes from the file system telling us it
// changed, and their ports only from a Stop. The one thing polled across rows is the PR of a row
// whose PR is known to be open — a merge happens in the browser and nothing local announces it —
// and `PRLookup` caps that at one `gh` call per row per 5 min.
//
// Every service callback arrives on that service's own queue and is hopped onto the main queue
// with `DispatchQueue.main.async` + `MainActor.assumeIsolated` (FIFO, unlike an unstructured
// `Task`), so two refreshes of one session are applied in the order they were produced.

import AppKit
import Foundation
import GitStatus
import TkzCore

@MainActor
public final class GitIntegration {
    public let store: AppStore
    public let service: GitStatusService
    public let prLookup: PRLookup

    // MARK: Rebase and the origin check (design 5a/5b, 2026-09-13)

    /// How often the opt-in origin check fetches each repo's base branch.
    public static let originCheckInterval: TimeInterval = 5 * 60
    /// A repo fetched within this window is not fetched again by the sheet: the number it shows
    /// is fresh enough, and a second fetch would only make the sheet slower to open.
    public static let recentFetchWindow: TimeInterval = 60

    /// A rebase finished or was refused: the window controller shows this in the status strip.
    public var onRebaseNotice: ((String) -> Void)?
    /// `isRebasing` changed for some row: the strip re-derives its chip.
    public var onRebaseStateChange: (() -> Void)?
    /// The rebase for this row is over, however it went: the sheet closes.
    public var onRebaseFinished: ((SessionID, GitRebase.Outcome) -> Void)?

    /// Keyed by toplevel, not session: two rows on one worktree must not both rebase it. A rebase
    /// started from the terminal is caught by `GitRebase.preflight`'s `rebase-merge` check.
    private var rebasingToplevels: Set<String> = []
    /// Every git fetch this coordinator makes — a rebase's own fetch, and the origin check's —
    /// runs here. `RebaseSheetController` is handed this same queue (see `git` in
    /// `MainWindowController`) so the sheet's own opening fetch is serialized behind them instead
    /// of racing a concurrent `git fetch` onto the same repository lock.
    let rebaseQueue = DispatchQueue(
        label: "se.tkz.tkzmux.GitIntegration.rebase", qos: .userInitiated)
    /// When each repo (`RepoInfo.repoRoot`) was last fetched by us — by the sheet, a rebase or
    /// the origin check.
    private var lastFetchAt: [String: Date] = [:]
    private var originTimer: DispatchSourceTimer?
    private var originObservers: [NSObjectProtocol] = []
    private var originCheckInFlight = false
    private var lastOriginCheckAt: Date?

    /// Injected so a test can drive both paths without a remote.
    let runRebase: @Sendable (GitRebase.Request) -> GitRebase.Outcome
    let fetchBase: @Sendable (GitRebase.Request) -> GitRebase.Outcome?
    private let now: () -> Date

    /// How often the selected row's ports are re-scanned. A scan of a 30-process tree is
    /// microseconds, so the interval is about not waking the process, not about cost.
    public static let portInterval: TimeInterval = 10

    /// How old a cached PR answer may be before a Stop hook asks `gh` again. A turn that ran
    /// `gh pr create` ends with a Stop, so this is how long a new PR takes to appear; a burst of
    /// short turns still costs at most one `gh` call per this interval per row.
    public static let stopLookupMaxAge: TimeInterval = 15

    /// The directory each session is currently tracked at, so a `cd` (OSC 7) or a bound descriptor
    /// re-targets the watcher instead of silently reporting the wrong repo.
    private var tracked: [SessionID: String] = [:]
    private var portTimer: DispatchSourceTimer?
    private var started = false
    private let portQueue = DispatchQueue(label: "se.tkz.tkzmux.GitIntegration.ports")

    /// Injected so a test can drive the port path without spawning listeners.
    let scanPorts: @Sendable (pid_t) -> [ListeningPort]

    public init(
        store: AppStore,
        service: GitStatusService? = nil,
        prLookup: PRLookup? = nil,
        scanPorts: @escaping @Sendable (pid_t) -> [ListeningPort] = { PortScanner.scan(rootPid: $0) },
        runRebase: @escaping @Sendable (GitRebase.Request) -> GitRebase.Outcome = { GitRebase.run($0) },
        fetchBase: @escaping @Sendable (GitRebase.Request) -> GitRebase.Outcome? = { GitRebase.fetch($0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.prLookup = prLookup ?? PRLookup()
        self.scanPorts = scanPorts
        self.runRebase = runRebase
        self.fetchBase = fetchBase
        self.now = now

        let box = WeakBox()
        self.service = service ?? GitStatusService { id, summary in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.value?.applySummary(summary, to: id) }
            }
        }
        box.value = self
    }

    /// Lets the service closure reach `self` without capturing it before `init` has finished — the
    /// same device `ClaudeIntegration` uses. Main-actor isolated, hence `Sendable` with no
    /// `@unchecked`.
    @MainActor private final class WeakBox {
        weak var value: GitIntegration?
    }

    // MARK: Lifecycle

    /// Starts the watchers and tracks whatever the store already holds. Idempotent.
    public func start() {
        guard !started else { return }
        started = true
        service.start()
        syncTracking()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.portInterval, repeating: Self.portInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scanSelectedPorts() }
        }
        portTimer = timer
        timer.resume()

        if store.state.selection != nil { selectionChanged() }
        applyOriginCheckPreference()
    }

    public func stop() {
        guard started else { return }
        started = false
        portTimer?.cancel()
        portTimer = nil
        stopOriginCheck()
        service.stop()
    }

    // MARK: Store observation

    /// Called from `MainWindowController`'s store observer with every delivered change set.
    public func apply(_ change: ChangeSet) {
        guard started else { return }
        if change.structure || !change.sessions.isEmpty { syncTracking() }
        if change.selection { selectionChanged() }
        if change.chrome { applyOriginCheckPreference() }
    }

    /// A `Stop` hook landed for this row: Claude has just finished doing something to the working
    /// tree, which is the one moment a refresh is certainly worth it — for *any* row, selected or
    /// not.
    public func sessionDidStop(_ id: SessionID) {
        guard started else { return }
        syncTracking()
        service.refresh(id)
        scanPorts(for: id)
        // The PR too, whether or not the row is selected: `gh pr create` changes nothing in the
        // working tree, so the git refresh above would never re-ask on its own.
        requestPullRequest(for: id, maxAge: Self.stopLookupMaxAge)
    }

    /// The row is gone: stop watching its directory and drop its cached PR.
    public func forget(_ id: SessionID) {
        tracked[id] = nil
        service.untrack(id)
        prLookup.forget(id)
    }

    // MARK: Tracking

    /// Which directory each session should be watched at. Pure, so the "a `cd` re-targets the
    /// watcher" rule is a test rather than an observation.
    ///
    /// Only rows with live state qualify: a restored row has no shell, nothing is running in a
    /// directory on its behalf, and `AppState.setGitSummary` would refuse the result anyway.
    ///
    /// **The focused pane's directory wins** (design 2c.3/2c.4, 2026-09-10): the status bar
    /// describes the pane that has the keyboard, so a split whose panes stand in two repos shows
    /// the branch of the one you are typing in, and moving focus moves the strip. Only when that
    /// pane has not reported an OSC 7 yet (a fresh split, for its first second) does the row fall
    /// back to `effectiveCwd` — Claude's cwd while a descriptor is bound, then the shell's last
    /// reported cwd, then where it was started — which is still the directory the row's *title*
    /// comes from. The title and the `WT` badge deliberately do not follow pane focus; the git
    /// facts do, everywhere they are shown: the strip and the sidebar row's `⎇ branch` line both
    /// read `GitSummary`, so both name the focused pane's branch.
    ///
    /// **Except in the pane that is running Claude** (2026-09-11): there the shell's OSC 7 is
    /// stale by construction. `claude -w <name>` is typed in the main checkout and chdirs into
    /// `.claude/worktrees/<name>` itself; the shell underneath never `cd`s, so its last report
    /// names the main checkout — `develop`, `+0 −0`, and a `WT` pill next to it that came from
    /// the descriptor. `Session.paneDirectory` carries that rule (the pane header reads the same
    /// one), so the pane hosting Claude is watched at Claude's own cwd while a live descriptor
    /// is bound, and a second pane in another repo still steers the strip when it has focus.
    static func trackingTargets(in state: AppState) -> [SessionID: String] {
        var out: [SessionID: String] = [:]
        for session in state.sessions.values where session.live != nil {
            let directory = session.paneDirectory(session.focusedTerminalID)
            guard !directory.isEmpty else { continue }
            out[session.id] = directory
        }
        return out
    }

    private func syncTracking() {
        let targets = Self.trackingTargets(in: store.state)
        for (id, directory) in targets where tracked[id] != directory {
            tracked[id] = directory
            // Still inside the checkout the row was already watched at? Then it is the same HEAD
            // and the same PR. This is the common retarget now that the target follows pane focus:
            // two panes of one repo swap the directory on every ⌥⌘-arrow, and dropping the badge
            // and re-running `gh` for each would be churn for nothing. (Nested worktrees pass
            // this test too; they are caught a moment later, when the branch change re-asks.)
            let sameCheckout = service.repoInfo(for: id).map {
                directory == $0.toplevel || directory.hasPrefix($0.toplevel + "/")
            } ?? false
            service.track(id, directory: directory)
            // Otherwise a new directory is a new repo as far as the PR is concerned — both the
            // cache and the badge, or the strip would keep showing the previous repo's `#123`
            // until a lookup for the new one happened to land.
            if !sameCheckout {
                prLookup.forget(id)
                service.setPullRequest(nil, for: id)
            }
        }
        // Snapshot the keys: `forget` mutates `tracked`, and iterating the live view while it
        // changes is exactly the kind of exclusivity trap Swift 6 is right to dislike.
        for id in Array(tracked.keys) where targets[id] == nil {
            forget(id)
        }
    }

    // MARK: Selection

    private func selectionChanged() {
        guard let id = store.state.selection else { return }
        // "On selection if older than 10 s" — a row the user is flicking through does not re-run
        // git for every arrow key, but a row they come back to after a while is fresh.
        service.refreshIfStale(id, maxAge: 10)
        scanPorts(for: id)
        requestPullRequest(for: id)
    }

    // MARK: Git

    private func applySummary(_ summary: GitSummary?, to id: SessionID) {
        let previousBranch = store.state.sessions[id]?.live?.git?.branch
        store.update { $0.setGitSummary(summary, for: id) }
        // A branch change is the other thing that must re-ask for a PR — for *any* row, because a
        // turn that ran `git checkout -b` and `gh pr create` ends with a Stop whose lookup still
        // named the old branch; the summary that lands a moment later carries the new one.
        // `PRLookup` compares the branch it last looked up and does nothing when it is the same.
        // A row's *first* summary is not a change: a fresh unselected row waits for a Stop or a
        // selection, as before, rather than costing a `gh` call just for being launched.
        let branchChanged = previousBranch != nil && summary?.branch != previousBranch
        if store.state.selection == id || branchChanged {
            requestPullRequest(for: id)
        }
        // The origin check's initial run — at launch with the preference already on, or the
        // instant it is turned on — can land before any repo has resolved its base branch, in
        // which case `checkOrigin` finds no targets and does nothing, and the first real check
        // waits a full `originCheckInterval`. Retrying here, on every summary a session posts
        // until one succeeds, catches the moment a base resolves instead of waiting on the timer;
        // `checkOrigin` is a cheap no-op both when disarmed and when it has already run.
        if originTimer != nil, lastOriginCheckAt == nil {
            checkOrigin()
        }
    }

    // MARK: Pull requests

    /// The sidecar seeds, `gh` decides. The statusline sidecar's `pr` block only ever describes an
    /// *open* PR (`tkzmux-hook` stamps it `OPEN`) and the file freezes when Claude exits, so it
    /// is a fine first answer — the badge shows before `gh` has run, or when `gh` is not installed
    /// — but not the last word: once a lookup has landed, a stale sidecar must not flip a merged
    /// PR back to open. Hence: seed only while nothing has been looked up, then always ask.
    private func requestPullRequest(for id: SessionID, maxAge: TimeInterval? = nil) {
        guard let session = store.state.sessions[id], let live = session.live else { return }
        if Self.shouldSeedFromSidecar(git: live.git, sidecar: live.context), let seed = live.context?.pr {
            service.setPullRequest(seed, for: id)
        }
        guard let branch = live.git?.branch, !branch.isEmpty else { return }
        // Keyed by the checkout, not the pane's subdirectory: `PRLookup` re-runs `gh` when the
        // directory it last looked up changes, and every pane of one checkout has the same PR.
        let directory = service.repoInfo(for: id)?.toplevel ?? tracked[id] ?? session.effectiveCwd
        prLookup.lookup(for: id, directory: directory, branch: branch, maxAge: maxAge) { pr in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    self?.service.setPullRequest(pr, for: id)
                }
            }
        }
    }

    /// The sidecar's PR is worth writing only while nothing has been looked up: `git.pr` is what
    /// `gh` last said (or what the sidecar seeded), and once it exists it is the fresher of the two.
    static func shouldSeedFromSidecar(git: GitSummary?, sidecar: SessionSidecar?) -> Bool {
        sidecar?.pr != nil && git?.pr == nil
    }

    /// The rows the 10 s tick re-asks about: the selected one (so a row you sit on learns of a
    /// review), plus every live row whose PR is still open — a merge happens in the browser, on
    /// no schedule of ours, and a row you are not looking at must turn purple too. Rows with no
    /// PR or a merged one cost nothing here; `PRLookup`'s own throttle caps the rest at one `gh`
    /// call per row per 5 min.
    static func rowsNeedingPRRefresh(in state: AppState) -> [SessionID] {
        var out: [SessionID] = []
        if let selected = state.selection { out.append(selected) }
        for (id, session) in state.sessions where id != state.selection {
            guard let pr = session.live?.git?.pr else { continue }
            if pr.state?.uppercased() == "OPEN" { out.append(id) }
        }
        return out
    }

    // MARK: Ports

    private func scanSelectedPorts() {
        if let id = store.state.selection { scanPorts(for: id) }
        // The same tick carries the PR's "every 5 min" refresh. `PRLookup` throttles to 5 minutes
        // itself, so a 10 s tick costs at most one `gh` call per 5 min per row — and without this
        // a row with no git change and no Stop would never learn that its PR was approved or
        // merged.
        for id in Self.rowsNeedingPRRefresh(in: store.state) {
            requestPullRequest(for: id)
        }
    }

    /// Scans off the main actor — libproc is fast but it is still a syscall per file descriptor of
    /// every process in the tree, and the main thread is where frames are encoded.
    private func scanPorts(for id: SessionID) {
        guard let live = store.state.sessions[id]?.live else { return }
        // Every pane's shell, not just the focused one's. A shell is the root of a tree —
        // a dev server started by Claude is a grandchild of it, and `claude` itself may have been
        // replaced by a resume — and with split panes the server the user wants a badge for is
        // just as likely to be in the pane they are *not* looking at. `shellPid`/`pid` stay in the
        // set so a row whose panes predate this map still scans.
        var pids = Set(live.panePids.values)
        if let shellPid = live.shellPid { pids.insert(shellPid) }
        if pids.isEmpty, let pid = live.pid { pids.insert(pid) }
        guard !pids.isEmpty else { return }
        let roots = pids.sorted()
        let scan = scanPorts
        portQueue.async { [weak self] in
            // Deduplicated on the port: two panes in one process tree would otherwise report the
            // same listener twice.
            var seen: Set<UInt16> = []
            var found: [ListeningPort] = []
            for root in roots {
                for port in scan(root) where seen.insert(port.port).inserted {
                    found.append(port)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyPorts(found, to: id) }
            }
        }
    }

    func applyPorts(_ found: [ListeningPort], to id: SessionID) {
        let ports = found.map(\.port)
        var owners: [UInt16: String] = [:]
        for entry in found {
            if let name = entry.processName, !name.isEmpty, owners[entry.port] == nil {
                owners[entry.port] = "\(name) (pid \(entry.pid))"
            }
        }
        store.update { $0.setPorts(ports, owners: owners, for: id) }
    }

    // MARK: Rebase (design 5a/5b)

    /// Whether a rebase is running on `id`'s worktree — started from this row or another row
    /// of the same checkout.
    public func isRebasing(_ id: SessionID) -> Bool {
        guard let toplevel = service.repoInfo(for: id)?.toplevel else { return false }
        return rebasingToplevels.contains(toplevel)
    }

    /// The Session-menu item's enablement: the branch is behind a known base and nothing is
    /// rebasing it. The chip follows the same rule through `StatusBarModel`.
    public func canRebaseOntoBase(_ id: SessionID) -> Bool {
        guard let git = store.state.sessions[id]?.live?.git, git.isOffBase,
            let behind = git.behindBase, behind > 0
        else { return false }
        return !isRebasing(id)
    }

    /// Everything the runner needs for `id`, or `nil` before the repo and its base are known.
    /// `skipFetch` is set when the repo was fetched within `recentFetchWindow`.
    public func rebaseRequest(for id: SessionID) -> GitRebase.Request? {
        guard let info = service.repoInfo(for: id), let base = service.baseBranch(for: id) else {
            return nil
        }
        let recent = lastFetchAt[info.repoRoot].map { now().timeIntervalSince($0) < Self.recentFetchWindow }
        return GitRebase.Request(
            toplevel: info.toplevel, gitDir: info.gitDir, base: base, skipFetch: recent ?? false,
            expectedBranch: store.state.sessions[id]?.live?.git?.branch)
    }

    /// The sheet fetched on its own (through `GitRebase.fetch`): remember it so the rebase that
    /// follows, and the origin check, do not fetch again right away.
    public func noteFetched(for id: SessionID) {
        guard let root = service.repoInfo(for: id)?.repoRoot else { return }
        lastFetchAt[root] = now()
    }

    /// Fetch the base and rebase `id`'s branch onto it, off the main actor; the outcome comes back
    /// as a notice. Refusals (`GitRebase.preflight`) are notices too, at once — and are reported
    /// back in the return value, since those paths never reach `finishRebase` and so never call
    /// `onRebaseFinished`: a caller that flips its own UI to "in progress" on the assumption this
    /// always finishes asynchronously must gate that on the return value, not run it unconditionally.
    @discardableResult
    public func rebaseOntoBase(_ id: SessionID, skipFetch: Bool = false) -> Bool {
        guard let live = store.state.sessions[id]?.live else { return false }
        guard let info = service.repoInfo(for: id), var prepared = rebaseRequest(for: id) else {
            onRebaseNotice?(Self.notice(for: .noBase, base: nil))
            return false
        }
        if let refusal = GitRebase.preflight(summary: live.git, gitDir: info.gitDir) {
            onRebaseNotice?(Self.notice(for: refusal, base: prepared.base.ref))
            return false
        }
        guard rebasingToplevels.insert(info.toplevel).inserted else {
            onRebaseNotice?(Self.notice(for: .rebaseInProgress, base: prepared.base.ref))
            return false
        }
        prepared.skipFetch = prepared.skipFetch || skipFetch
        let request = prepared
        onRebaseStateChange?()

        let hadUpstream = live.git?.upstream != nil
        let run = runRebase
        let box = WeakBox()
        box.value = self
        rebaseQueue.async {
            let outcome = run(request)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.value?.finishRebase(
                        id, info: info, base: request.base.ref, hadUpstream: hadUpstream,
                        outcome: outcome)
                }
            }
        }
        return true
    }

    private func finishRebase(
        _ id: SessionID, info: RepoInfo, base: String, hadUpstream: Bool,
        outcome: GitRebase.Outcome
    ) {
        rebasingToplevels.remove(info.toplevel)
        if case .fetchFailed = outcome {} else if case .timedOut("fetch") = outcome {} else {
            lastFetchAt[info.repoRoot] = now()
        }
        onRebaseStateChange?()
        onRebaseFinished?(id, outcome)
        onRebaseNotice?(Self.notice(for: outcome, base: base, hadUpstream: hadUpstream))
        // FSEvents will have fired during the rebase, but the last refresh may have run mid-way
        // (a detached HEAD, half the commits): one more, now that the tree has settled.
        service.refresh(id)
    }

    /// The status-strip line for each way a rebase can end. `base` is the ref (`origin/main`).
    static func notice(for outcome: GitRebase.Outcome, base: String, hadUpstream: Bool) -> String {
        switch outcome {
        case .rebased(let commits, let stashReapplied):
            var text = "Rebased onto \(base) (\(commits) \(commits == 1 ? "commit" : "commits"))"
            if stashReapplied { text += ", local changes reapplied" }
            if hadUpstream { text += " \u{2014} push with git push --force-with-lease" }
            return text
        case .rebasedStashConflict:
            return "Rebased onto \(base), but reapplying your local changes conflicted \u{2014} they are kept in git stash"
        case .upToDate:
            return "Already up to date with \(base)"
        case .conflicts(let files):
            return "Rebase stopped on conflicts in \(files) \(files == 1 ? "file" : "files"), tree restored \u{2014} run git rebase \(base) by hand"
        case .fetchFailed(let message):
            return "Fetch of \(base) failed: \(message)"
        case .failed(let message):
            return "Rebase failed, tree restored: \(message)"
        case .timedOut(let step):
            return "Rebase timed out during \(step), tree restored"
        }
    }

    static func notice(for refusal: GitRebase.Refusal, base: String?) -> String {
        switch refusal {
        case .noBase: "No base branch to rebase onto"
        case .onBase: "Already on \(base ?? "the base branch")"
        case .detachedHead: "Rebase skipped: HEAD is detached"
        case .rebaseInProgress: "Rebase skipped: a rebase is already in progress"
        case .mergeInProgress: "Rebase skipped: a merge is in progress"
        }
    }

    // MARK: Origin check (opt-in, off by default)

    /// Arms or disarms the periodic fetch to match `AppState.checkOriginPeriodically`. Turning it
    /// on runs a check at once; turning it off cancels the timer. Idempotent.
    func applyOriginCheckPreference() {
        let enabled = started && store.state.checkOriginPeriodically
        if enabled, originTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(
                wallDeadline: .now() + Self.originCheckInterval, repeating: Self.originCheckInterval,
                leeway: .seconds(30))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.checkOrigin() }
            }
            originTimer = timer
            timer.resume()
            let center = NSWorkspace.shared.notificationCenter
            originObservers.append(center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkOriginIfStale() }
            })
            originObservers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkOriginIfStale() }
            })
            checkOrigin()
        } else if !enabled {
            stopOriginCheck()
        }
    }

    private func stopOriginCheck() {
        originTimer?.cancel()
        originTimer = nil
        for observer in originObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in originObservers { NotificationCenter.default.removeObserver(observer) }
        originObservers = []
    }

    /// Wake / activation: only when the timer would have fired by now had the Mac stayed awake.
    func checkOriginIfStale() {
        guard originTimer != nil else { return }
        guard let last = lastOriginCheckAt else { checkOrigin(); return }
        if now().timeIntervalSince(last) >= Self.originCheckInterval { checkOrigin() }
    }

    /// One fetch per repo that has a session and a *remote* base — a local `main` has nothing
    /// to fetch. Serial on the rebase queue, so a check can never race a rebase. Coalesces: a
    /// check already in flight is not doubled.
    func checkOrigin() {
        guard !originCheckInFlight else { return }
        let targets = Self.originCheckTargets(
            sessions: Array(tracked.keys), repoInfo: service.repoInfo(for:),
            baseBranch: service.baseBranch(for:))
        guard !targets.isEmpty else { return }
        originCheckInFlight = true
        lastOriginCheckAt = now()
        let fetch = fetchBase
        let box = WeakBox()
        box.value = self
        rebaseQueue.async {
            var fetched: [String] = []
            for target in targets where fetch(target.request) == nil {
                fetched.append(target.repoRoot)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.value?.finishOriginCheck(fetched: fetched, targets: targets) }
            }
        }
    }

    struct OriginCheckTarget: Equatable, Sendable {
        var repoRoot: String
        var request: GitRebase.Request
        var sessions: [SessionID]
    }

    /// One target per repo root, carrying every session of that repo. Pure, so the "once per
    /// repo, not per session, and only with a remote base" rule is a test.
    static func originCheckTargets(
        sessions: [SessionID],
        repoInfo: (SessionID) -> RepoInfo?,
        baseBranch: (SessionID) -> BaseBranch?
    ) -> [OriginCheckTarget] {
        var byRoot: [String: OriginCheckTarget] = [:]
        var order: [String] = []
        for id in sessions.sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            guard let info = repoInfo(id), let base = baseBranch(id), base.remote != nil else { continue }
            if byRoot[info.repoRoot] == nil {
                byRoot[info.repoRoot] = OriginCheckTarget(
                    repoRoot: info.repoRoot,
                    request: GitRebase.Request(toplevel: info.toplevel, gitDir: info.gitDir, base: base),
                    sessions: [])
                order.append(info.repoRoot)
            }
            byRoot[info.repoRoot]?.sessions.append(id)
        }
        return order.compactMap { byRoot[$0] }
    }

    private func finishOriginCheck(fetched: [String], targets: [OriginCheckTarget]) {
        originCheckInFlight = false
        let stamp = now()
        for root in fetched { lastFetchAt[root] = stamp }
        // The refs moved in the common dir, so FSEvents already scheduled a refresh; this one
        // covers the case where the fetch brought nothing new but the chip was never computed.
        for target in targets where fetched.contains(target.repoRoot) {
            for id in target.sessions { service.refresh(id) }
        }
    }

    /// Test access.
    var isOriginCheckArmed: Bool { originTimer != nil }
}
