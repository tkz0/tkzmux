// The app side of "rebase onto main" (design 5a/5b, 2026-09-13): the `⤿ main ↓7` chip on the
// status strip, the sheet's model and controller, the coordinator's notices and its origin check,
// and the window controller's mapping and menu enablement.

import AppKit
import GitStatus
import Testing
import TkzCore

@testable import TkzApp

@MainActor
struct RebaseChipTests {

    static func items(_ model: StatusBarModel, _ theme: Theme = .default) -> [StatusItem] {
        StatusBarView.items(for: model, theme: theme)
    }

    @Test func behindTheBaseDrawsTheAmberChipAfterTheUpstreamArrows() throws {
        let model = StatusBarModel(
            branch: "develop", isWorktree: true, modelName: "Sonnet 4.5", ahead: 0, behind: 2,
            upstream: "origin/develop", baseBranch: "origin/main", behindBase: 7,
            rebaseShortcut: "\u{2325}\u{2318}R", pullRequest: PRInfo(number: 418))
        let items = Self.items(model)
        #expect(items.map(\.segment.plainText) == [
            "\u{2387} develop", "WT", "SONNET 4.5", "\u{2191}0 \u{2193}2", "\u{293F} 7 behind main", "#418",
        ])
        let chip = try #require(items.first { $0.action == .rebaseOntoBase })
        for theme in Theme.allPresets {
            let themed = try #require(Self.items(model, theme).first { $0.action == .rebaseOntoBase })
            #expect(themed.segment.colors == [theme.rebaseText, theme.rebaseBackground, theme.rebaseBorder])
        }
        #expect(chip.tooltip == "Click or \u{2325}\u{2318}R to rebase onto origin/main\nCommits on origin/main this branch lacks, as of the last fetch")
        // No upstream: the dimmed dashes, then the chip.
        let unpushed = StatusBarModel(branch: "f", upstreamMissing: true, baseBranch: "origin/main", behindBase: 1)
        #expect(Self.items(unpushed).map(\.segment.plainText) == [
            "\u{2387} f", "\u{2191}\u{2013} \u{2193}\u{2013}", "\u{293F} 1 behind main",
        ])
    }

    @Test func inSyncOrUnknownDrawsNoChip() {
        #expect(!Self.items(StatusBarModel(branch: "f", baseBranch: "origin/main", behindBase: 0))
            .contains { $0.action == .rebaseOntoBase })
        #expect(!Self.items(StatusBarModel(branch: "f", baseBranch: "origin/main"))
            .contains { $0.action == .rebaseOntoBase })
        #expect(!Self.items(StatusBarModel(branch: "f", behindBase: 3))
            .contains { $0.segment.plainText.contains("\u{293F}") })
    }

    @Test func rebasingReplacesTheCountAndIsInert() throws {
        let model = StatusBarModel(branch: "f", baseBranch: "origin/main", behindBase: 7, isRebasing: true)
        let chip = try #require(Self.items(model).first { $0.segment.plainText.contains("\u{293F}") })
        #expect(chip.segment.plainText == "\u{293F} rebasing onto main\u{2026}")
        #expect(chip.action == nil)
        #expect(chip.tooltip == "Rebasing onto origin/main\u{2026}")
        // Even at `behindBase == 0` the strip says a rebase is running.
        let settled = StatusBarModel(branch: "f", baseBranch: "origin/main", behindBase: 0, isRebasing: true)
        #expect(Self.items(settled).contains { $0.segment.plainText.contains("rebasing") })
    }

    @Test func labelsAndTooltips() {
        #expect(StatusBarView.baseLabel("origin/main") == "main")
        #expect(StatusBarView.baseLabel("main") == "main")
        #expect(StatusBarView.baseLabel("origin/feature/x") == "feature/x")
        #expect(StatusBarView.baseLabel("origin/") == "origin/")
        #expect(StatusBarView.baseChipText(base: "origin/main", behind: 1) == "\u{293F} 1 behind main")
        #expect(StatusBarView.baseTooltip(base: "origin/main", shortcut: nil)
                == "Click to rebase onto origin/main\nCommits on origin/main this branch lacks, as of the last fetch")
    }

    @Test func clickingTheChipRequestsTheSheet() throws {
        let view = StatusBarInteractionTests.laidOut(
            StatusBarModel(branch: "develop", baseBranch: "origin/main", behindBase: 2))
        let opened = StatusBarInteractionTests.OpenedBox()
        view.openURL = { opened.url = $0 }
        let box = FlagBox()
        view.onRebaseOntoBase = { box.hit = true }

        let chip = try #require(view.placement().first { $0.item.action == .rebaseOntoBase })
        let point = NSPoint(x: chip.frame.midX, y: chip.frame.midY)
        let event = NSEvent.mouseEvent(
            with: .leftMouseUp, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseUp(with: event)
        #expect(box.hit)
        #expect(opened.url == nil)
    }
}

final class FlagBox { var hit = false }

// MARK: - Sheet model

struct RebaseSheetModelTests {

    @Test func bodyPerPhase() {
        var model = RebaseSheetModel(baseRef: "origin/main", shortcut: "\u{2325}\u{2318}R")
        model.agentDisplayName = "Claude"
        #expect(model.title == "Rebase onto main")
        #expect(model.body.lead == "Fetching origin/main\u{2026}")
        #expect(model.body.emphasis == nil)
        #expect(!model.canRebase)
        #expect(model.rebaseHint == "Waiting for the fetch")

        model.phase = .ready
        model.behind = 7
        #expect(model.body.lead == "Pulls in ")
        #expect(model.body.emphasis == "7 commits")
        #expect(model.canRebase)
        #expect(model.rebaseHint == nil)

        model.behind = 1
        #expect(model.body.emphasis == "1 commit")

        model.behind = 0
        #expect(model.body.lead == "Already up to date with origin/main")
        #expect(!model.canRebase)
        #expect(model.rebaseHint == "Nothing to rebase")

        model.behind = nil
        #expect(model.body.lead == "Could not count the commits on origin/main")
        #expect(!model.canRebase)

        model.behind = 3
        model.agentWorking = true
        #expect(!model.canRebase)
        #expect(model.rebaseHint == "Wait for Claude to be idle \u{2014} it may be editing files")
        model.agentWorking = false

        model.phase = .fetchFailed("could not read from remote")
        #expect(model.body.lead == "Fetch failed: could not read from remote")
        #expect(!model.canRebase)

        model.phase = .rebasing
        #expect(model.body.lead == "Rebasing onto origin/main\u{2026}")
        #expect(!model.canRebase)
        #expect(model.rebaseHint == "Rebase in progress")
    }

    @Test func rebaseHintNamesWhicheverAgentItWasGiven() {
        var model = RebaseSheetModel(baseRef: "origin/main", behind: 1, phase: .ready)
        #expect(model.agentDisplayName == "the agent", "no adapter wired: honest, not a guess")
        model.agentWorking = true
        #expect(model.rebaseHint == "Wait for the agent to be idle \u{2014} it may be editing files")
        model.agentDisplayName = "Stub Agent"
        #expect(model.rebaseHint == "Wait for Stub Agent to be idle \u{2014} it may be editing files")
    }
}

// MARK: - Sheet controller

// Serialized, and **no panel ever reaches the screen**: `orderFront` is stubbed on every
// controller, like the main-window harness does for its own windows.
//
// Until 2026-09-16 the panels were ordered front for real and a `performClick` on one of their
// buttons ended the whole test run as "passed" mid-way: `NSButtonCell.performClick`
// spins `nextEventMatchingMask:` to show the pressed state of a *visible* button, that first
// request for events starts HIToolbox's event-pulling thread, and from then on every incoming
// event wakes the main thread with `CFRunLoopStop(main)`. Harmless under `NSApplication.run`,
// but the test process's main run loop is `CFRunLoopRun()` inside Swift's async-main drain, which
// calls `exit(0)` the moment that loop stops — no summary line, and every test scheduled after
// that point silently never runs. Off screen there is nothing to spin, and `click` below sends
// the action directly anyway.
@MainActor
@Suite(.serialized) struct RebaseSheetControllerTests {

    static func request() -> GitRebase.Request {
        GitRebase.Request(toplevel: "/tmp/x", gitDir: "/tmp/x/.git", base: BaseBranch(remote: "origin", name: "main"))
    }

    /// The button's action, without the event-loop spin `performClick` does for a visible window.
    static func click(_ button: NSButton) {
        _ = NSApp.sendAction(button.action!, to: button.target, from: button)
    }

    static func settle(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func opensFetchingThenShowsTheCount() async throws {
        _ = NSApplication.shared
        let controller = RebaseSheetController(theme: .default) { _ in (nil, 7) }
        controller.dismissesWhenResigningKey = false
        controller.orderFront = { _ in }
        let fetched = FlagBox()
        controller.onFetched = { _ in fetched.hit = true }
        let id = SessionID.generate()

        controller.present(for: id, request: Self.request(), model: RebaseSheetModel(baseRef: "origin/main"), over: nil)
        #expect(controller.isShown)
        let view = try #require(controller.sheetViewForTesting)
        #expect(view.titleForTesting == "Rebase onto main")
        #expect(view.bodyForTesting == "Fetching origin/main\u{2026}")
        #expect(!view.rebaseButtonForTesting.isEnabled)

        await Self.settle { controller.model?.phase == .ready }
        #expect(view.bodyForTesting == "Pulls in 7 commits")
        #expect(view.rebaseButtonForTesting.isEnabled)
        #expect(fetched.hit)

        controller.setClaudeWorking(true)
        #expect(!view.rebaseButtonForTesting.isEnabled)
        controller.setClaudeWorking(false)
        #expect(view.rebaseButtonForTesting.isEnabled)
        controller.dismiss()
    }

    @Test func aSkippedFetchDoesNotClaimToHaveFetched() async {
        _ = NSApplication.shared
        let controller = RebaseSheetController(theme: .default) { _ in (nil, 2) }
        controller.dismissesWhenResigningKey = false
        controller.orderFront = { _ in }
        let fetched = FlagBox()
        controller.onFetched = { _ in fetched.hit = true }
        var request = Self.request()
        request.skipFetch = true
        controller.present(for: SessionID.generate(), request: request, model: RebaseSheetModel(baseRef: "origin/main"), over: nil)
        await Self.settle { controller.model?.phase == .ready }
        #expect(!fetched.hit)
        #expect(controller.model?.behind == 2)
        controller.dismiss()
    }

    @Test func aFailedFetchKeepsTheButtonOff() async throws {
        _ = NSApplication.shared
        let controller = RebaseSheetController(theme: .default) { _ in (.fetchFailed("no route to host"), nil) }
        controller.dismissesWhenResigningKey = false
        controller.orderFront = { _ in }
        controller.present(for: SessionID.generate(), request: Self.request(), model: RebaseSheetModel(baseRef: "origin/main"), over: nil)
        await Self.settle { controller.model?.phase != .fetching }
        #expect(controller.model?.phase == .fetchFailed("no route to host"))
        let view = try #require(controller.sheetViewForTesting)
        #expect(view.bodyForTesting == "Fetch failed: no route to host")
        #expect(!view.rebaseButtonForTesting.isEnabled)
        controller.dismiss()
    }

    @Test func rebaseRunsThroughTheCallbackAndClosesWhenDone() async throws {
        _ = NSApplication.shared
        let controller = RebaseSheetController(theme: .default) { _ in (nil, 3) }
        controller.dismissesWhenResigningKey = false
        controller.orderFront = { _ in }
        let started = FlagBox()
        let dismissed = FlagBox()
        controller.onRebase = { _ in started.hit = true }
        controller.onDismiss = { dismissed.hit = true }
        let id = SessionID.generate()
        controller.present(for: id, request: Self.request(), model: RebaseSheetModel(baseRef: "origin/main"), over: nil)
        await Self.settle { controller.model?.phase == .ready }
        let view = try #require(controller.sheetViewForTesting)

        Self.click(view.rebaseButtonForTesting)
        #expect(started.hit)
        controller.rebaseStarted(for: id)
        #expect(controller.model?.phase == .rebasing)
        #expect(!view.cancelButtonForTesting.isEnabled)
        #expect(view.bodyForTesting == "Rebasing onto origin/main\u{2026}")

        controller.rebaseFinished(for: SessionID.generate())   // another row: ignored
        #expect(controller.isShown)
        controller.rebaseFinished(for: id)
        #expect(!controller.isShown)
        #expect(dismissed.hit)
    }

    @Test func escapeAndCancelDismiss() async throws {
        _ = NSApplication.shared
        let controller = RebaseSheetController(theme: .default) { _ in (nil, 1) }
        controller.dismissesWhenResigningKey = false
        controller.orderFront = { _ in }
        let id = SessionID.generate()
        controller.present(for: id, request: nil, model: RebaseSheetModel(baseRef: "main", behind: 1, phase: .ready), over: nil)
        let view = try #require(controller.sheetViewForTesting)
        #expect(view.bodyForTesting == "Pulls in 1 commit")
        Self.click(view.cancelButtonForTesting)
        #expect(!controller.isShown)

        controller.present(for: id, request: nil, model: RebaseSheetModel(baseRef: "main", behind: 1, phase: .ready), over: nil)
        (controller.panelForTesting as? PromptCardPanel)?.cancelOperation(nil)
        #expect(!controller.isShown)

        // The chord on an open sheet for the same row closes it; another row re-targets.
        controller.toggle(for: id, request: nil, model: RebaseSheetModel(baseRef: "main", phase: .ready), over: nil)
        #expect(controller.isShown)
        let other = SessionID.generate()
        controller.toggle(for: other, request: nil, model: RebaseSheetModel(baseRef: "main", phase: .ready), over: nil)
        #expect(controller.sessionID == other)
        controller.toggle(for: other, request: nil, model: RebaseSheetModel(baseRef: "main", phase: .ready), over: nil)
        #expect(!controller.isShown)
    }

    @Test func sitsAtTheBottomRightOfTheAnchor() {
        let anchor = NSRect(x: 100, y: 200, width: 800, height: 600)
        let frame = RebaseSheetController.frame(for: NSSize(width: 318, height: 96), over: anchor)
        #expect(frame == NSRect(x: 900 - 14 - 318, y: 200 + 14, width: 318, height: 96))
    }
}

// MARK: - Coordinator

@MainActor
struct RebaseCoordinatorTests {

    @Test func noticesNameTheBaseAndTheOutcome() {
        typealias G = GitIntegration
        #expect(G.notice(for: .rebased(commits: 3, stashReapplied: false), base: "origin/main", hadUpstream: false)
                == "Rebased onto origin/main (3 commits)")
        #expect(G.notice(for: .rebased(commits: 1, stashReapplied: true), base: "origin/main", hadUpstream: true)
                == "Rebased onto origin/main (1 commit), local changes reapplied \u{2014} push with git push --force-with-lease")
        #expect(G.notice(for: .rebasedStashConflict(commits: 2), base: "origin/main", hadUpstream: false)
                == "Rebased onto origin/main, but reapplying your local changes conflicted \u{2014} they are kept in git stash")
        #expect(G.notice(for: .upToDate, base: "origin/main", hadUpstream: true) == "Already up to date with origin/main")
        #expect(G.notice(for: .conflicts(files: 1), base: "origin/main", hadUpstream: false)
                == "Rebase stopped on conflicts in 1 file, tree restored \u{2014} run git rebase origin/main by hand")
        #expect(G.notice(for: .fetchFailed("no route"), base: "origin/main", hadUpstream: false) == "Fetch of origin/main failed: no route")
        #expect(G.notice(for: .failed("boom"), base: "origin/main", hadUpstream: false) == "Rebase failed, tree restored: boom")
        #expect(G.notice(for: .timedOut(step: "fetch"), base: "origin/main", hadUpstream: false) == "Rebase timed out during fetch, tree restored")

        #expect(G.notice(for: .noBase, base: nil) == "No base branch to rebase onto")
        #expect(G.notice(for: .onBase, base: "origin/main") == "Already on origin/main")
        #expect(G.notice(for: .detachedHead, base: nil) == "Rebase skipped: HEAD is detached")
        #expect(G.notice(for: .rebaseInProgress, base: nil) == "Rebase skipped: a rebase is already in progress")
        #expect(G.notice(for: .mergeInProgress, base: nil) == "Rebase skipped: a merge is in progress")
    }

    @Test func originCheckTargetsOneFetchPerRepoWithARemoteBase() {
        let a = SessionID.generate(), b = SessionID.generate(), c = SessionID.generate(), d = SessionID.generate()
        let repo = RepoInfo(toplevel: "/r/main", gitDir: "/r/main/.git", commonDir: "/r/main/.git", repoRoot: "/r/main", isWorktree: false, worktreeName: nil)
        let worktree = RepoInfo(toplevel: "/r/main/.claude/worktrees/x", gitDir: "/r/main/.git/worktrees/x", commonDir: "/r/main/.git", repoRoot: "/r/main", isWorktree: true, worktreeName: "x")
        let local = RepoInfo(toplevel: "/l", gitDir: "/l/.git", commonDir: "/l/.git", repoRoot: "/l", isWorktree: false, worktreeName: nil)
        let infos: [SessionID: RepoInfo] = [a: repo, b: worktree, c: local]
        let bases: [SessionID: BaseBranch] = [
            a: BaseBranch(remote: "origin", name: "main"), b: BaseBranch(remote: "origin", name: "main"),
            c: BaseBranch(remote: nil, name: "main"),
        ]
        let targets = GitIntegration.originCheckTargets(
            sessions: [a, b, c, d], repoInfo: { infos[$0] }, baseBranch: { bases[$0] })
        #expect(targets.count == 1)
        #expect(targets.first?.repoRoot == "/r/main")
        #expect(Set(targets.first?.sessions ?? []) == [a, b])
        #expect(targets.first?.request.base.ref == "origin/main")
    }

    @Test func thePreferenceArmsAndDisarmsTheCheck() {
        let store = AppStore(state: AppState())
        let integration = GitIntegration(store: store, scanPorts: { _ in [] }, fetchBase: { _ in nil })
        #expect(!integration.isOriginCheckArmed)
        integration.start()
        #expect(!integration.isOriginCheckArmed)   // off by default

        store.update { $0.setCheckOriginPeriodically(true) }
        store.flush()
        integration.apply(ChangeSet(chrome: true))
        #expect(integration.isOriginCheckArmed)

        store.update { $0.setCheckOriginPeriodically(false) }
        store.flush()
        integration.apply(ChangeSet(chrome: true))
        #expect(!integration.isOriginCheckArmed)
        integration.stop()
    }

    @Test func aRowWithNoBaseIsRefusedWithANotice() {
        var state = AppState()
        let group = state.addGroup(name: "repo", repoRoot: "/tmp/repo")
        let id = state.createSession(groupID: group.id, cwd: "/tmp/repo").id
        state.setLive(LiveSessionState(shellPid: 1, status: .idle), for: id)
        let store = AppStore(state: state)
        let integration = GitIntegration(store: store, scanPorts: { _ in [] })
        let notices = NoticeBox()
        integration.onRebaseNotice = { notices.lines.append($0) }
        integration.rebaseOntoBase(id)
        #expect(notices.lines == ["No base branch to rebase onto"])
        #expect(!integration.canRebaseOntoBase(id))
        #expect(!integration.isRebasing(id))
    }
}

final class NoticeBox { var lines: [String] = [] }

// MARK: - Window controller

@MainActor
struct RebaseWindowTests {

    @Test func statusModelCarriesTheBaseAndTheChord() {
        var state = AppState()
        let group = state.addGroup(name: "repo", repoRoot: "/tmp/repo")
        let id = state.createSession(groupID: group.id, cwd: "/tmp/repo/.claude/worktrees/x").id
        state.setLive(LiveSessionState(shellPid: 1, status: .idle), for: id)
        state.setGitSummary(
            GitSummary(branch: "x", baseBranch: "origin/main", aheadOfBase: 2, behindBase: 5), for: id)
        state.selection = id

        let model = MainWindowController.statusModel(for: state)
        #expect(model.baseBranch == "origin/main")
        #expect(model.behindBase == 5)
        #expect(model.rebaseShortcut == ShortcutsTable.defaults[.rebaseOntoBase]?.displayString)
        #expect(model.isRebasing == false)
    }

    @Test func theMenuItemIsEnabledOnlyWithSomethingToRebase() {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let dispatcher = harness.controller.dispatcher
        #expect(dispatcher.canPerform(.rebaseOntoBase))
        #expect(harness.store.state.checkOriginPeriodically == false)

        let id = harness.store.state.selection!
        harness.mutate { $0.setLive(LiveSessionState(shellPid: 1, status: .idle), for: id) }
        harness.mutate { $0.setGitSummary(GitSummary(branch: "main", baseBranch: "origin/main"), for: id) }
        #expect(!dispatcher.isEnabled(.rebaseOntoBase))

        harness.mutate {
            $0.setGitSummary(GitSummary(branch: "f", baseBranch: "origin/main", aheadOfBase: 1, behindBase: 0), for: id)
        }
        #expect(!dispatcher.isEnabled(.rebaseOntoBase))

        harness.mutate {
            $0.setGitSummary(GitSummary(branch: "f", baseBranch: "origin/main", aheadOfBase: 1, behindBase: 4), for: id)
        }
        #expect(dispatcher.isEnabled(.rebaseOntoBase))

        // The sheet opens with no coordinator: the last refresh's count, ready at once.
        harness.controller.toggleRebaseSheet()
        #expect(harness.controller.rebaseSheet.isShown)
        #expect(harness.controller.rebaseSheet.model?.behind == 4)
        #expect(harness.controller.rebaseSheet.model?.phase == .ready)
        harness.controller.toggleRebaseSheet()
        #expect(!harness.controller.rebaseSheet.isShown)

        // The origin check is a Settings switch now; its controller setter still flips it.
        harness.controller.toggleOriginCheck()
        harness.store.flush()
        #expect(harness.store.state.checkOriginPeriodically)
    }
}
