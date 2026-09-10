// GitIntegration — the app-side coordinator for M4 (TKZ-26, TKZ-27, TKZ-28).
//
// `GitStatus` ships three services that each know one thing and none of which knows what a
// `Session` is: `GitStatusService` (branch, diffstat, ahead/behind, FSEvents), `PRLookup`
// (`gh pr view`, gated on a github.com origin) and `PortScanner` (libproc). This type is the one
// place their facts are attributed to rows and posted into the store — the same shape as
// `ClaudeIntegration` for M3, and for the same reason: the services stay testable without a store
// and the store stays free of process state that arrives on foreign queues.
//
// Cadence, from design.md → *Git integration*:
//
//   | Fact  | When it is refreshed |
//   |---|---|
//   | git   | FSEvents on the repo (300 ms debounce, ≤ 1 / 2 s), after each Stop hook, on selection if > 10 s old |
//   | ports | on selection, after each Stop hook, and every 10 s **while selected** |
//   | PR    | on selection and on a branch change; `PRLookup` itself throttles to 5 min and caches failures for 10 |
//
// Non-selected rows are deliberately cheap: their git comes from the file system telling us it
// changed, and their ports only from a Stop. Nothing here polls every row.
//
// Every service callback arrives on that service's own queue and is hopped onto the main queue
// with `DispatchQueue.main.async` + `MainActor.assumeIsolated` (FIFO, unlike an unstructured
// `Task`), so two refreshes of one session are applied in the order they were produced.

import Foundation
import GitStatus
import TkzCore
import os

@MainActor
public final class GitIntegration {
    public let store: AppStore
    public let service: GitStatusService
    public let prLookup: PRLookup

    /// How often the selected row's ports are re-scanned. A scan of a 30-process tree is
    /// microseconds (TKZ-28), so the interval is about not waking the process, not about cost.
    public static let portInterval: TimeInterval = 10

    /// The directory each session is currently tracked at, so a `cd` (OSC 7) or a bound descriptor
    /// re-targets the watcher instead of silently reporting the wrong repo.
    private var tracked: [SessionID: String] = [:]
    private var portTimer: DispatchSourceTimer?
    private var started = false
    private let portQueue = DispatchQueue(label: "se.tkz.tkzmux.GitIntegration.ports")
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "git")

    /// Injected so a test can drive the port path without spawning listeners.
    let scanPorts: @Sendable (pid_t) -> [ListeningPort]

    public init(
        store: AppStore,
        service: GitStatusService? = nil,
        prLookup: PRLookup? = nil,
        scanPorts: @escaping @Sendable (pid_t) -> [ListeningPort] = { PortScanner.scan(rootPid: $0) }
    ) {
        self.store = store
        self.prLookup = prLookup ?? PRLookup()
        self.scanPorts = scanPorts

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
    }

    public func stop() {
        guard started else { return }
        started = false
        portTimer?.cancel()
        portTimer = nil
        service.stop()
    }

    // MARK: Store observation

    /// Called from `MainWindowController`'s store observer with every delivered change set.
    public func apply(_ change: ChangeSet) {
        guard started else { return }
        if change.structure || !change.sessions.isEmpty { syncTracking() }
        if change.selection { selectionChanged() }
    }

    /// A `Stop` hook landed for this row: Claude has just finished doing something to the working
    /// tree, which is the one moment a refresh is certainly worth it — for *any* row, selected or
    /// not (design.md → *Git integration → Triggers*).
    public func sessionDidStop(_ id: SessionID) {
        guard started else { return }
        syncTracking()
        service.refresh(id)
        scanPorts(for: id)
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
    static func trackingTargets(in state: AppState) -> [SessionID: String] {
        var out: [SessionID: String] = [:]
        for session in state.sessions.values where session.live != nil {
            let directory = session.live?.paneCwds[session.focusedTerminalID] ?? session.effectiveCwd
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
        store.update { $0.setGitSummary(summary, for: id) }
        // A branch change is the other thing that must re-ask for a PR; `PRLookup` compares the
        // branch it last looked up and does nothing when it is the same.
        if store.state.selection == id { requestPullRequest(for: id) }
    }

    // MARK: Pull requests

    /// Sidecar first, `gh` second (design.md → *Git integration → PR*). When the statusline sidecar
    /// already carries a `pr` block there is nothing to ask `gh` about, which also means the whole
    /// `gh` path stays unused for anyone running the sidecar.
    private func requestPullRequest(for id: SessionID) {
        guard let session = store.state.sessions[id], let live = session.live else { return }
        if let fromSidecar = live.context?.pr {
            service.setPullRequest(fromSidecar, for: id)
            return
        }
        guard let branch = live.git?.branch, !branch.isEmpty else { return }
        // Keyed by the checkout, not the pane's subdirectory: `PRLookup` re-runs `gh` when the
        // directory it last looked up changes, and every pane of one checkout has the same PR.
        let directory = service.repoInfo(for: id)?.toplevel ?? tracked[id] ?? session.effectiveCwd
        prLookup.lookup(for: id, directory: directory, branch: branch) { pr in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    self?.service.setPullRequest(pr, for: id)
                }
            }
        }
    }

    // MARK: Ports

    private func scanSelectedPorts() {
        guard let id = store.state.selection else { return }
        scanPorts(for: id)
        // The same tick carries the PR's "every 5 min" refresh. `PRLookup` throttles to 5 minutes
        // itself, so a 10 s tick costs at most one `gh` call per 5 min — and without this a row you
        // sit on with no git change and no Stop would never learn that its PR was approved.
        requestPullRequest(for: id)
    }

    /// Scans off the main actor — libproc is fast but it is still a syscall per file descriptor of
    /// every process in the tree, and the main thread is where frames are encoded.
    private func scanPorts(for id: SessionID) {
        guard let live = store.state.sessions[id]?.live else { return }
        // Every pane's shell, not just the focused one's (TKZ-36). A shell is the root of a tree —
        // a dev server started by Claude is a grandchild of it, and `claude` itself may have been
        // replaced by a resume — and with split panes the server the user wants a badge for is
        // just as likely to be in the pane they are *not* looking at. `shellPid`/`pid` stay in the
        // set so a row whose panes predate this map still scans.
        var roots = Set(live.panePids.values)
        if let shellPid = live.shellPid { roots.insert(shellPid) }
        if roots.isEmpty, let pid = live.pid { roots.insert(pid) }
        guard !roots.isEmpty else { return }
        let scan = scanPorts
        portQueue.async { [weak self] in
            // Deduplicated on the port: two panes in one process tree would otherwise report the
            // same listener twice.
            var seen: Set<UInt16> = []
            var found: [ListeningPort] = []
            for root in roots.sorted() {
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
}
