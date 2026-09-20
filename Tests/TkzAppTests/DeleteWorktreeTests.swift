// DeleteWorktreeTests — the app half of TKZ-70, in four layers.
//
//   1. The sheet **model** alone: every string and every button state, no AppKit at all.
//   2. The sheet **controller**: the survey phases and which button reports which `BranchDelete`,
//      with the survey injected so no repo is needed.
//   3. The **coordinator**: `GitIntegration`'s notices, its refusals, the one-delete-per-worktree
//      rule, and the safety rule as a test — a request pointing somewhere else never runs.
//   4. The **window controller**: the two menu items, `closePlan`'s five cases, ⇧⌘W through
//      `confirmClose`, and the ordering that makes this feature safe (row closed, git still ran).
//
// No panel reaches the screen and no button is `performClick`ed — see `SheetTestSupport.swift`.

import AppKit
import GitStatus
import Synchronization
import Testing
import TkzCore

@testable import TkzApp

// MARK: - 1 · The model

struct DeleteWorktreeSheetModelTests {

    static func model(
        merge: WorktreeRemoval.MergeState = .mergedIntoBase(base: "origin/main"),
        phase: DeleteWorktreeSheetModel.Phase = .ready,
        branch: String? = "feature",
        dirty: Int = 0
    ) -> DeleteWorktreeSheetModel {
        var model = DeleteWorktreeSheetModel(worktreePath: "/Users/x/dev/repo/.claude/worktrees/duck")
        model.home = "/Users/x"
        model.branch = branch
        model.baseRef = "origin/main"
        model.merge = merge
        model.phase = phase
        model.isDirty = dirty > 0
        model.dirtyFileCount = dirty
        return model
    }

    @Test func titleAndPathNameTheWorktree() {
        let model = Self.model()
        #expect(model.title == "Delete worktree duck")
        #expect(model.pathLine == "~/dev/repo/.claude/worktrees/duck")
        #expect(model.branchLine == "\u{2387} feature")
        #expect(Self.model(branch: nil).branchLine == "detached HEAD")
    }

    @Test func theStatusLineSaysWhichOfTheThreeCasesThisIs() {
        #expect(Self.model(merge: .prMerged(number: 12)).statusLine == "PR #12 merged")
        #expect(Self.model(merge: .prMerged(number: nil)).statusLine == "Its pull request is merged")
        #expect(Self.model(merge: .mergedIntoBase(base: "origin/main")).statusLine
            == "Branch fully merged into main")
        #expect(Self.model(merge: .unmerged(commits: 2, base: "origin/main")).statusLine
            == "2 commits not on main")
        #expect(Self.model(merge: .unmerged(commits: 1, base: "origin/main")).statusLine
            == "1 commit not on main")
    }

    @Test func theUnhappyCasesSayWhatWentWrongRatherThanShowingANumber() {
        #expect(Self.model(merge: .unmerged(commits: nil, base: "origin/main")).statusLine
            == "Could not count the commits not on main")
        #expect(Self.model(merge: .unknown).statusLine == "Could not compare the branch with main")
        #expect(Self.model(merge: .onBase(base: "origin/main")).statusLine == "This is the base branch")
        #expect(Self.model(merge: .detached, branch: nil).statusLine
            == "Detached HEAD \u{2014} nothing to compare")

        var noBase = Self.model(merge: .unknown)
        noBase.baseRef = nil
        #expect(noBase.statusLine == "No base branch to compare with")
    }

    @Test func thePhaseOutranksTheClassificationInTheStatusLine() {
        #expect(Self.model(phase: .checking).statusLine == "Checking the worktree\u{2026}")
        #expect(Self.model(phase: .deleting).statusLine == "Deleting\u{2026}")
        #expect(Self.model(phase: .checkFailed("no such ref")).statusLine
            == "Could not check the branch: no such ref")
    }

    /// Merged reads quiet; everything else — including "we could not tell" — reads as a caution.
    @Test func onlyAMergedBranchReadsQuiet() {
        #expect(Self.model(merge: .prMerged(number: 1)).statusTone == .quiet)
        #expect(Self.model(merge: .mergedIntoBase(base: "origin/main")).statusTone == .quiet)
        #expect(Self.model(merge: .unmerged(commits: 2, base: "origin/main")).statusTone == .caution)
        #expect(Self.model(merge: .unknown).statusTone == .caution)
        #expect(Self.model(phase: .checkFailed("x")).statusTone == .caution)
    }

    @Test func theDirtyLineCountsAndOnlyShowsOnceTheSurveyLanded() {
        #expect(Self.model(dirty: 0).dirtyLine == nil)
        #expect(Self.model(dirty: 1).dirtyLine == "1 uncommitted change will be lost")
        #expect(Self.model(dirty: 3).dirtyLine == "3 uncommitted changes will be lost")
        #expect(Self.model(phase: .checking, dirty: 3).dirtyLine == nil)
    }

    @Test func theButtonTitleFlipsWithWhetherTheBranchLanded() {
        #expect(Self.model(merge: .prMerged(number: 1)).deleteButtonTitle == "Delete")
        #expect(Self.model(merge: .mergedIntoBase(base: "origin/main")).deleteButtonTitle == "Delete")
        #expect(Self.model(merge: .unmerged(commits: 2, base: "origin/main")).deleteButtonTitle
            == "Delete, keep branch")
        // "We could not tell" takes the conservative shape.
        #expect(Self.model(merge: .unknown).deleteButtonTitle == "Delete, keep branch")
    }

    /// The red button is offered exactly where there is an unmerged branch to force — including
    /// the unmeasured case, which is precisely where the user has to decide.
    @Test func theRedButtonAppearsOnlyWhereThereIsAnUnmergedBranch() {
        #expect(!Self.model(merge: .prMerged(number: 1)).showsDeleteBranchButton)
        #expect(!Self.model(merge: .mergedIntoBase(base: "origin/main")).showsDeleteBranchButton)
        #expect(Self.model(merge: .unmerged(commits: 2, base: "origin/main")).showsDeleteBranchButton)
        #expect(Self.model(merge: .unknown).showsDeleteBranchButton)
        #expect(Self.model(merge: .unmerged(commits: nil, base: "origin/main")).showsDeleteBranchButton)
        // No branch, nothing to force.
        #expect(!Self.model(merge: .detached, branch: nil).showsDeleteBranchButton)
    }

    @Test func thePrimaryButtonDeletesTheBranchExactlyWhenItWillSucceed() {
        #expect(Self.model(merge: .prMerged(number: 1)).primaryDeletesBranch)
        #expect(Self.model(merge: .mergedIntoBase(base: "origin/main")).primaryDeletesBranch)
        #expect(!Self.model(merge: .unmerged(commits: 2, base: "origin/main")).primaryDeletesBranch)
        #expect(!Self.model(merge: .detached, branch: nil).primaryDeletesBranch)
    }

    @Test func theButtonsAreOffUntilTheSurveyLandsAndTheDirtyBoxIsTicked() {
        #expect(!Self.model(phase: .checking).canDelete)
        #expect(!Self.model(phase: .checkFailed("x")).canDelete)
        #expect(!Self.model(phase: .deleting).canDelete)
        #expect(Self.model().canDelete)

        var working = Self.model()
        working.agentWorking = true
        #expect(!working.canDelete)

        var dirty = Self.model(dirty: 2)
        #expect(!dirty.canDelete)
        dirty.acknowledgedDirty = true
        #expect(dirty.canDelete)
    }

    @Test func everyDisabledStateSaysWhy() {
        #expect(Self.model(phase: .checking).deleteHint == "Checking the worktree")
        #expect(Self.model(phase: .deleting).deleteHint == "Delete in progress")
        #expect(Self.model(phase: .checkFailed("x")).deleteHint == "Could not check the worktree")
        #expect(Self.model(dirty: 1).deleteHint == "Confirm you want to discard the uncommitted changes")
        #expect(Self.model().deleteHint == nil)
    }

    /// Byte-identical to `RebaseSheetModel.rebaseHint`'s: one rule, one sentence.
    @Test func theAgentHintMatchesTheRebaseSheetsWordForWord() {
        var model = Self.model()
        model.agentWorking = true
        #expect(model.agentDisplayName == "the agent", "no adapter wired: honest, not a guess")
        #expect(model.deleteHint == "Wait for the agent to be idle \u{2014} it may be editing files")

        var rebase = RebaseSheetModel(baseRef: "origin/main", behind: 1, phase: .ready)
        rebase.agentWorking = true
        #expect(model.deleteHint == rebase.rebaseHint)

        model.agentDisplayName = "Stub Agent"
        #expect(model.deleteHint == "Wait for Stub Agent to be idle \u{2014} it may be editing files")
    }
}

// MARK: - 2 · The sheet controller

@MainActor
@Suite(.serialized) struct DeleteWorktreeSheetControllerTests {

    static func request() -> WorktreeRemoval.Request {
        WorktreeRemoval.Request(
            worktreePath: "/repo/.claude/worktrees/duck", repoRoot: "/repo",
            gitDir: "/repo/.git/worktrees/duck", branch: "feature",
            base: BaseBranch(remote: "origin", name: "main"), marker: "/.claude/worktrees/")
    }

    static func controller(
        _ result: Result<WorktreeRemoval.Survey, WorktreeRemoval.SurveyFailure>
    ) -> DeleteWorktreeSheetController {
        let controller = DeleteWorktreeSheetController(theme: .default, prepare: { _, _ in result })
        controller.orderFront = { _ in }
        controller.dismissesWhenResigningKey = false
        return controller
    }

    static func present(
        _ controller: DeleteWorktreeSheetController, id: SessionID = .generate()
    ) -> SessionID {
        var model = DeleteWorktreeSheetModel(worktreePath: "/repo/.claude/worktrees/duck")
        model.branch = "feature"
        model.baseRef = "origin/main"
        controller.present(for: id, request: request(), pr: nil, model: model, over: nil)
        return id
    }

    @Test func opensCheckingThenShowsWhatGitSaid() async {
        let controller = Self.controller(.success(.init(
            merge: .unmerged(commits: 2, base: "origin/main"), isDirty: true, dirtyFileCount: 3,
            headBranch: "feature")))
        _ = Self.present(controller)
        #expect(controller.model?.phase == .checking)
        #expect(controller.sheetViewForTesting?.deleteButtonForTesting.isEnabled == false)

        await SheetTestSupport.settle { controller.model?.phase == .ready }
        #expect(controller.model?.merge == .unmerged(commits: 2, base: "origin/main"))
        #expect(controller.model?.dirtyFileCount == 3)
        #expect(controller.sheetViewForTesting?.statusForTesting == "2 commits not on main")
        #expect(controller.sheetViewForTesting?.dirtyForTesting == "3 uncommitted changes will be lost")
        // Dirty and unacknowledged: still off, with the reason on the tooltip.
        #expect(controller.sheetViewForTesting?.deleteButtonForTesting.isEnabled == false)
        controller.dismiss()
    }

    @Test func aFailedSurveyLeavesTheButtonsOff() async {
        let controller = Self.controller(.failure(.init("no such ref")))
        _ = Self.present(controller)
        await SheetTestSupport.settle { controller.model?.phase != .checking }
        #expect(controller.model?.phase == .checkFailed("no such ref"))
        #expect(controller.model?.canDelete == false)
        #expect(controller.sheetViewForTesting?.statusForTesting
            == "Could not check the branch: no such ref")
        controller.dismiss()
    }

    @Test func tickingTheBoxIsWhatEnablesTheDelete() async {
        let controller = Self.controller(.success(.init(
            merge: .mergedIntoBase(base: "origin/main"), isDirty: true, dirtyFileCount: 1,
            headBranch: "feature")))
        _ = Self.present(controller)
        await SheetTestSupport.settle { controller.model?.phase == .ready }
        #expect(controller.model?.canDelete == false)

        let box = try! #require(controller.sheetViewForTesting?.dirtyCheckboxForTesting)
        box.state = .on
        SheetTestSupport.click(box)
        #expect(controller.model?.acknowledgedDirty == true)
        #expect(controller.model?.canDelete == true)
        #expect(controller.sheetViewForTesting?.deleteButtonForTesting.isEnabled == true)
        controller.dismiss()
    }

    @Test func eachButtonReportsItsOwnBranchChoice() async throws {
        // Unmerged: the primary keeps the branch, the red one forces it.
        let controller = Self.controller(.success(.init(
            merge: .unmerged(commits: 2, base: "origin/main"), headBranch: "feature")))
        var seen: [WorktreeRemoval.BranchDelete] = []
        controller.onDelete = { _, choice in seen.append(choice) }
        _ = Self.present(controller)
        await SheetTestSupport.settle { controller.model?.phase == .ready }

        let view = try #require(controller.sheetViewForTesting)
        #expect(view.deleteButtonForTesting.title == "Delete, keep branch")
        #expect(view.deleteBranchButtonForTesting.isHidden == false)
        SheetTestSupport.click(view.deleteButtonForTesting)
        SheetTestSupport.click(view.deleteBranchButtonForTesting)
        #expect(seen == [.keep, .force])
        controller.dismiss()

        // Merged: one button, and it takes the branch with it.
        let merged = Self.controller(.success(.init(
            merge: .prMerged(number: 12), headBranch: "feature")))
        var mergedSeen: [WorktreeRemoval.BranchDelete] = []
        merged.onDelete = { _, choice in mergedSeen.append(choice) }
        _ = Self.present(merged)
        await SheetTestSupport.settle { merged.model?.phase == .ready }
        let mergedView = try #require(merged.sheetViewForTesting)
        #expect(mergedView.deleteButtonForTesting.title == "Delete")
        #expect(mergedView.deleteBranchButtonForTesting.isHidden == true)
        SheetTestSupport.click(mergedView.deleteButtonForTesting)
        #expect(mergedSeen == [.safe])
        merged.dismiss()
    }

    /// The controller re-checks `canDelete` rather than trusting the view's `isEnabled` — the same
    /// guard the rebase sheet keeps.
    @Test func aClickWhileTheButtonsAreOffDoesNothing() throws {
        let controller = Self.controller(.success(.init(merge: .prMerged(number: 1))))
        var fired = 0
        controller.onDelete = { _, _ in fired += 1 }
        _ = Self.present(controller)
        #expect(controller.model?.phase == .checking)
        let view = try #require(controller.sheetViewForTesting)
        SheetTestSupport.click(view.deleteButtonForTesting)
        #expect(fired == 0)
        controller.dismiss()
    }

    @Test func cancelEscapeAndTheDeleteFinishingAllDismiss() async throws {
        let controller = Self.controller(.success(.init(merge: .prMerged(number: 1))))
        let id = Self.present(controller)
        await SheetTestSupport.settle { controller.model?.phase == .ready }
        SheetTestSupport.click(try #require(controller.sheetViewForTesting).cancelButtonForTesting)
        #expect(!controller.isShown)

        _ = Self.present(controller, id: id)
        (controller.panelForTesting as? PromptCardPanel)?.cancelOperation(nil)
        #expect(!controller.isShown)

        let again = Self.present(controller, id: id)
        // Another row's delete finishing must not take this sheet down.
        controller.deleteFinished(for: .generate())
        #expect(controller.isShown)
        controller.deleteFinished(for: again)
        #expect(!controller.isShown)
    }

    @Test func theRowsAgentStatusTurnsTheButtonsOffAndOnAgain() async {
        let controller = Self.controller(.success(.init(merge: .prMerged(number: 1))))
        _ = Self.present(controller)
        await SheetTestSupport.settle { controller.model?.phase == .ready }
        #expect(controller.model?.canDelete == true)
        controller.setClaudeWorking(true)
        #expect(controller.model?.canDelete == false)
        controller.setClaudeWorking(false)
        #expect(controller.model?.canDelete == true)
        controller.dismiss()
    }

    /// The whole reason the body is an `NSStackView`: a hidden arranged subview collapses, so
    /// the card that has no dirty warning is genuinely shorter and `place()` measures it right.
    @Test func theCardShrinksWhenThereIsNoDirtyWarning() async throws {
        let clean = Self.controller(.success(.init(merge: .prMerged(number: 1))))
        _ = Self.present(clean)
        await SheetTestSupport.settle { clean.model?.phase == .ready }
        let cleanView = try #require(clean.sheetViewForTesting)
        cleanView.layoutSubtreeIfNeeded()
        let cleanHeight = cleanView.fittingSize.height
        clean.dismiss()

        let dirty = Self.controller(.success(.init(
            merge: .prMerged(number: 1), isDirty: true, dirtyFileCount: 2)))
        _ = Self.present(dirty)
        await SheetTestSupport.settle { dirty.model?.phase == .ready }
        let dirtyView = try #require(dirty.sheetViewForTesting)
        dirtyView.layoutSubtreeIfNeeded()
        #expect(dirtyView.fittingSize.height > cleanHeight)
        dirty.dismiss()
    }

    @Test func theCardSitsAtTheBottomRightOfTheAnchorLikeItsFamily() {
        let anchor = NSRect(x: 100, y: 200, width: 800, height: 600)
        let size = NSSize(width: 318, height: 140)
        #expect(
            GlassSheetPanel.frame(for: size, over: anchor)
                == NSRect(x: 100 + 800 - 14 - 318, y: 200 + 14, width: 318, height: 140))
        #expect(RebaseSheetController.frame(for: size, over: anchor)
            == GlassSheetPanel.frame(for: size, over: anchor))
    }
}

// MARK: - 3 · The coordinator

@MainActor
struct WorktreeRemovalCoordinatorTests {

    private static let path = "/repo/.claude/worktrees/duck"

    static func request(
        _ worktreePath: String = path, branch: String? = "feature",
        branchDelete: WorktreeRemoval.BranchDelete = .safe
    ) -> WorktreeRemoval.Request {
        WorktreeRemoval.Request(
            worktreePath: worktreePath, repoRoot: "/repo",
            gitDir: "/repo/.git/worktrees/duck", branch: branch,
            base: BaseBranch(remote: "origin", name: "main"), marker: "/.claude/worktrees/",
            branchDelete: branchDelete)
    }

    static func notice(_ outcome: WorktreeRemoval.Outcome) -> String {
        GitIntegration.notice(for: outcome, path: path, branch: "feature", base: "origin/main")
    }

    @Test func everyOutcomeHasItsOwnLine() {
        #expect(Self.notice(.removedWithBranch(branch: "feature"))
            == "Deleted worktree duck and branch feature")
        #expect(Self.notice(.removed) == "Deleted worktree duck \u{2014} branch feature kept")
        #expect(Self.notice(.removedBranchNotMerged(branch: "feature"))
            == "Deleted worktree duck; branch feature has commits origin/main does not \u{2014} delete it with git branch -D")
        #expect(Self.notice(.removedBranchFailed(branch: "feature", message: "locked ref"))
            == "Deleted worktree duck; branch feature kept: locked ref")
        #expect(Self.notice(.dirty) == "Worktree duck has uncommitted changes \u{2014} not deleted")
        #expect(Self.notice(.locked) == "Worktree duck is locked \u{2014} not deleted")
        #expect(Self.notice(.removalFailed("in use")) == "Could not delete worktree duck: in use")
        #expect(Self.notice(.timedOut(step: "remove"))
            == "Deleting worktree duck timed out during remove")
    }

    /// The notice never carries the full path: the strip is one line and truncates.
    @Test func theNoticeNamesTheWorktreeNotItsPath() {
        for outcome: WorktreeRemoval.Outcome in [
            .removed, .removedWithBranch(branch: "feature"), .dirty, .locked,
            .removalFailed("x"), .timedOut(step: "branch"),
        ] {
            #expect(!Self.notice(outcome).contains("/repo/"))
        }
    }

    @Test func everyRefusalSaysWhy() {
        func line(_ refusal: WorktreeRemoval.Refusal) -> String {
            GitIntegration.notice(for: refusal, name: "duck", agent: "Claude Code")
        }
        #expect(line(.notAWorktreePath)
            == "Only worktrees under .claude/worktrees that tkzmux opened can be deleted here")
        #expect(line(.mainCheckout) == "That is the repository itself, not a worktree")
        #expect(line(.missing) == "The worktree directory is already gone")
        #expect(line(.locked) == "Worktree duck is locked")
        #expect(line(.detachedHead) == "Its HEAD is detached \u{2014} there is no branch to delete")
        #expect(line(.branchIsBase) == "That is the base branch")
        #expect(line(.dirtyTree) == "Worktree duck has uncommitted changes")
        #expect(line(.headMoved) == "Its branch changed since you asked")
        #expect(line(.agentWorking)
            == "Wait for Claude Code to be idle \u{2014} it may be editing files")
        #expect(line(.rebaseInProgress)
            == "Delete skipped: a rebase is in progress on this worktree")
        #expect(line(.deleteInProgress) == "A delete is already running on this worktree")
    }

    @Test func theBatchLineCountsAndNamesOnlyTheFirstFailure() {
        let ok: [WorktreeRemoval.Outcome] = [.removed, .removedWithBranch(branch: "a")]
        #expect(GitIntegration.notice(forBatch: ok, firstFailure: nil) == "Deleted 2 worktrees")
        #expect(GitIntegration.notice(forBatch: [.removed], firstFailure: nil)
            == "Deleted 1 worktree")

        let partial: [WorktreeRemoval.Outcome] = [.removed, .dirty, .locked]
        #expect(
            GitIntegration.notice(
                forBatch: partial, firstFailure: (name: "goose", message: "uncommitted changes"))
                == "Deleted 1 of 3 worktrees; goose failed: uncommitted changes")

        #expect(
            GitIntegration.notice(
                forBatch: [.dirty, .dirty], firstFailure: (name: "duck", message: "uncommitted changes"))
                == "Could not delete 2 worktrees: uncommitted changes")
    }

    @Test func aRefusedBranchDeleteStillCountsAsTheWorktreeHavingGone() {
        #expect(GitIntegration.succeeded(.removed))
        #expect(GitIntegration.succeeded(.removedWithBranch(branch: "a")))
        #expect(GitIntegration.succeeded(.removedBranchNotMerged(branch: "a")))
        #expect(GitIntegration.succeeded(.removedBranchFailed(branch: "a", message: "x")))
        #expect(!GitIntegration.succeeded(.dirty))
        #expect(!GitIntegration.succeeded(.locked))
        #expect(!GitIntegration.succeeded(.removalFailed("x")))
        #expect(!GitIntegration.succeeded(.timedOut(step: "remove")))
        #expect(!GitIntegration.succeeded(.refused(.dirtyTree)))
    }

    /// One delete per worktree, keyed by path rather than session — two rows can sit on one.
    @Test func aSecondDeleteOnTheSameWorktreeIsRefused() {
        let store = AppStore(state: .fixture)
        var notices: [String] = []
        // Never finishes, so the first claim is still held when the second arrives.
        let git = GitIntegration(store: store, runDelete: { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return .removed
        })
        git.onDeleteWorktreeNotice = { notices.append($0) }

        #expect(git.deleteWorktree(Self.request()) == true)
        #expect(git.deletingWorktreePaths.contains(Self.path))
        #expect(git.deleteWorktree(Self.request()) == false)
        #expect(notices == ["A delete is already running on this worktree"])
    }

    @Test func everyOutcomeComesBackAsItsNoticeAndReleasesTheWorktree() async {
        for outcome: WorktreeRemoval.Outcome in [
            .removed, .removedWithBranch(branch: "feature"), .dirty,
            .removalFailed("in use"), .refused(.headMoved),
        ] {
            let store = AppStore(state: .fixture)
            var notices: [String] = []
            var finished: [(SessionID?, String, WorktreeRemoval.Outcome)] = []
            let git = GitIntegration(store: store, runDelete: { _ in outcome })
            git.onDeleteWorktreeNotice = { notices.append($0) }
            git.onDeleteWorktreeFinished = { finished.append(($0, $1, $2)) }

            #expect(git.deleteWorktree(Self.request()) == true)
            await SheetTestSupport.settle { !notices.isEmpty }
            #expect(notices == [Self.notice(outcome)])
            #expect(finished.count == 1)
            #expect(finished.first?.0 == nil, "no row left to attribute it to")
            #expect(finished.first?.1 == "/repo")
            #expect(git.deletingWorktreePaths.isEmpty)
        }
    }

    @Test func aBatchReportsOnceAndReleasesEveryWorktree() async {
        let store = AppStore(state: .fixture)
        var notices: [String] = []
        var roots: Set<String> = []
        let git = GitIntegration(store: store, runDelete: { request in
            request.worktreeName == "goose" ? .dirty : .removed
        })
        git.onDeleteWorktreeNotice = { notices.append($0) }
        git.onDeleteWorktreesFinished = { _, seen in roots = seen }

        let requests = ["duck", "goose", "swan"].map {
            Self.request("/repo/.claude/worktrees/\($0)")
        }
        #expect(git.deleteWorktrees(requests) == 3)
        await SheetTestSupport.settle { !notices.isEmpty }
        #expect(notices == ["Deleted 2 of 3 worktrees; goose failed: uncommitted changes"])
        #expect(roots == ["/repo"])
        #expect(git.deletingWorktreePaths.isEmpty)
    }

    /// **The safety rule, as a test.** A request pointing at a directory that is not a worktree
    /// under the marker never reaches git — `WorktreeRemoval.run`'s own preflight refuses it, and
    /// this asserts the coordinator does not route around that.
    @Test func aRequestPointingElsewhereIsRefusedBeforeAnythingRuns() async {
        let store = AppStore(state: .fixture)
        let ran = Mutex(0)
        var notices: [String] = []
        let git = GitIntegration(store: store, runDelete: { request in
            ran.withLock { $0 += 1 }
            // The real runner's first act, reproduced: nothing else in `run` happens before it.
            if let refusal = WorktreeRemoval.preflight(
                request, worktrees: ["/repo"], locked: [], isDirty: false, isWorktreeRow: true)
            {
                return .refused(refusal)
            }
            return .removed
        })
        git.onDeleteWorktreeNotice = { notices.append($0) }

        #expect(git.deleteWorktree(Self.request("/tmp/somewhere-else")) == true)
        await SheetTestSupport.settle { !notices.isEmpty }
        #expect(ran.withLock { $0 } == 1)
        #expect(notices.first?.contains("Only worktrees under .claude/worktrees") == true)
    }
}

// MARK: - 4 · The window controller

@MainActor
@Suite(.serialized) struct DeleteWorktreeWindowTests {

    typealias Harness = MainWindowControllerTests.Harness

    /// Session 3 of the fixture sits in `…/.claude/worktrees/reporting`; session 0 is in the main
    /// checkout. Marking a row's PR merged is all it takes to make it a delete candidate as far
    /// as the *row model* is concerned.
    static func markMerged(_ harness: Harness, _ id: SessionID) {
        harness.mutate { state in
            state.updateLive(id) {
                $0.git = GitSummary(branch: "feature", pr: PRInfo(number: 12, state: "MERGED"))
            }
        }
    }

    // MARK: Menu items

    @Test func theRowMenuOffersDeleteWorktreeOnlyOnAWorktreeRow() throws {
        let harness = MainWindowControllerTests.makeHarness()
        let worktreeRow = Fixture.sessionID(3)
        let plainRow = Fixture.sessionID(0)

        let plain = try #require(harness.controller.sessionContextMenu(for: plainRow))
        #expect(!plain.items.contains { $0.identifier == MainWindowController.ContextItemID.deleteWorktree })

        let menu = try #require(harness.controller.sessionContextMenu(for: worktreeRow))
        let item = try #require(
            menu.items.first { $0.identifier == MainWindowController.ContextItemID.deleteWorktree })
        #expect(item.title == "Delete Worktree\u{2026}")
        // Right after Remove, in the same block.
        let removeIndex = try #require(
            menu.items.firstIndex { $0.identifier == MainWindowController.ContextItemID.remove })
        #expect(menu.items.firstIndex(of: item) == removeIndex + 1)
    }

    /// The ticket's "disabled with the reason, like the rebase button" — and the reason is on the
    /// tooltip, exactly as `rebaseButton.toolTip` is.
    @Test func aWorkingRowsDeleteItemIsOffWithTheReasonOnItsTooltip() throws {
        let harness = MainWindowControllerTests.makeHarness()
        harness.controller.git = GitIntegration(store: harness.store)
        let id = Fixture.sessionID(3)
        harness.mutate { $0.setStatus(.working, for: id) }

        let menu = try #require(harness.controller.sessionContextMenu(for: id))
        let item = try #require(
            menu.items.first { $0.identifier == MainWindowController.ContextItemID.deleteWorktree })
        #expect(!item.isEnabled)
        #expect(item.toolTip?.hasPrefix("Wait for ") == true)
        #expect(item.toolTip?.hasSuffix("to be idle \u{2014} it may be editing files") == true)
    }

    /// A destructive item with nothing to ask must refuse, not offer — the opposite default from
    /// `Resume`, which is harmless when it guesses wrong.
    @Test func withNoCoordinatorTheItemIsOffRatherThanOptimistic() throws {
        let harness = MainWindowControllerTests.makeHarness()
        #expect(harness.controller.git == nil)
        let menu = try #require(harness.controller.sessionContextMenu(for: Fixture.sessionID(3)))
        let item = try #require(
            menu.items.first { $0.identifier == MainWindowController.ContextItemID.deleteWorktree })
        #expect(!item.isEnabled)
        #expect(item.toolTip == "Waiting for this row's git status")
    }

    @Test func theGroupMenuOffersTheBulkDeleteWhenTheGroupHasWorktreeRows() throws {
        let harness = MainWindowControllerTests.makeHarness()
        let group = try #require(harness.store.state.sessions[Fixture.sessionID(3)]).groupID

        let menu = try #require(harness.controller.groupContextMenu(for: group))
        let item = try #require(
            menu.items.first {
                $0.identifier == MainWindowController.ContextItemID.deleteMergedWorktrees
            })
        #expect(item.title == "Delete Merged Worktrees\u{2026}")
        #expect(item.isEnabled)
        #expect(item.toolTip == nil)
        // With the group's sessions, not with the group itself: before the Remove separator.
        let removeIndex = try #require(
            menu.items.firstIndex { $0.identifier == MainWindowController.ContextItemID.removeGroup })
        #expect(try #require(menu.items.firstIndex(of: item)) < removeIndex)
    }

    // MARK: closePlan

    static func plan(
        _ status: SessionStatus, merged: Bool
    ) -> MainWindowController.CloseSessionPlan? {
        var session = Session(id: .generate(), groupID: .generate(), order: 0, cwd: "/repo", accountKey: "claude")
        session.title = "duck"
        session.live = LiveSessionState()
        session.live?.status = status
        return MainWindowController.closePlan(
            for: session, agentName: "Claude Code", isMergedWorktree: merged,
            worktreePath: "/Users/x/dev/repo/.claude/worktrees/duck", branch: "feature",
            home: "/Users/x")
    }

    /// **The non-regression that matters**: an idle row that is not a merged worktree still
    /// closes with no dialog at all, exactly as it always has.
    @Test func anIdleOrdinaryRowAsksNothing() {
        #expect(Self.plan(.idle, merged: false) == nil)
    }

    @Test func anIdleMergedWorktreeRowOffersTheDeleteAsTheDefault() throws {
        let plan = try #require(Self.plan(.idle, merged: true))
        #expect(plan.buttons == [.closeAndDeleteWorktree, .close, .cancel])
        #expect(plan.title == "Close \u{201C}duck\u{201D}?")
        #expect(plan.message
            == "Its pull request is merged. Closing removes the row; deleting also removes the worktree at ~/dev/repo/.claude/worktrees/duck and its branch feature.")
        #expect(MainWindowController.buttonTitle(for: plan.buttons[0], offersDelete: true)
            == "Close and Delete Worktree")
        #expect(MainWindowController.buttonTitle(for: plan.buttons[1], offersDelete: true)
            == "Close Only")
    }

    @Test func aWaitingMergedRowKeepsTheOfferAndAWorkingOneDoesNot() throws {
        let waiting = try #require(Self.plan(.waiting(.doneUnattended), merged: true))
        #expect(waiting.buttons == [.closeAndDeleteWorktree, .close, .cancel])
        #expect(waiting.message.hasPrefix("This session is waiting for you."))
        #expect(waiting.message.contains("Its pull request is merged."))

        // The agent may be editing files under the worktree — the same rule the menu item and the
        // rebase button key on.
        let working = try #require(Self.plan(.working, merged: true))
        #expect(working.buttons == [.close, .cancel])
    }

    /// The busy sentences are unchanged, byte for byte.
    @Test func theOrdinaryBusyDialogsSayExactlyWhatTheyAlwaysSaid() throws {
        let working = try #require(Self.plan(.working, merged: false))
        #expect(working.buttons == [.close, .cancel])
        #expect(working.message
            == "Claude Code is still working in this session. Closing ends the shell and removes the row; the conversation is kept by Claude Code.")
        #expect(MainWindowController.buttonTitle(for: .close, offersDelete: false) == "Close")

        let waiting = try #require(Self.plan(.waiting(.permission), merged: false))
        #expect(waiting.message
            == "This session is waiting for you. Closing ends the shell and removes the row; the conversation is kept by Claude Code.")
    }

    // MARK: ⇧⌘W through the plan

    @Test func closeOnlyRemovesTheRowAndRunsNoGit() throws {
        let harness = MainWindowControllerTests.makeHarness()
        let deleted = Mutex<[WorktreeRemoval.Request]>([])
        harness.controller.git = GitIntegration(
            store: harness.store, runDelete: { request in
                deleted.withLock { $0.append(request) }
                return .removed
            })
        let id = Fixture.sessionID(3)
        Self.markMerged(harness, id)
        harness.mutate { $0.setStatus(.working, for: id) }

        harness.controller.confirmClose = { _ in .close }
        harness.controller.removeSession(id)
        harness.store.flush()
        #expect(harness.store.state.sessions[id] == nil)
        #expect(deleted.withLock { $0.isEmpty })
    }

    @Test func cancelKeepsTheRow() throws {
        let harness = MainWindowControllerTests.makeHarness()
        harness.controller.git = GitIntegration(store: harness.store)
        let id = Fixture.sessionID(3)
        harness.mutate { $0.setStatus(.working, for: id) }
        harness.controller.confirmClose = { _ in .cancel }
        harness.controller.removeSession(id)
        harness.store.flush()
        #expect(harness.store.state.sessions[id] != nil)
    }

    /// An idle ordinary row must never reach the confirmation at all — the dialog this ticket adds
    /// is only for the merged worktree case. Session 7 of the fixture is idle and not a worktree.
    @Test func anIdleOrdinaryRowNeverConsultsTheConfirmation() throws {
        let harness = MainWindowControllerTests.makeHarness()
        harness.controller.git = GitIntegration(store: harness.store)
        let id = Fixture.sessionID(7)
        let session = try #require(harness.store.state.sessions[id])
        #expect(session.status == .idle)
        #expect(!session.showsWorktreeBadge)

        let asked = Mutex(0)
        harness.controller.confirmClose = { _ in
            asked.withLock { $0 += 1 }
            return .close
        }
        harness.controller.removeSession(id)
        harness.store.flush()
        #expect(asked.withLock { $0 } == 0)
        #expect(harness.store.state.sessions[id] == nil)
    }

    /// **The ordering that makes this feature safe**, end to end against a real repo: the row is
    /// gone *and* the removal still ran, with the request captured before the row left.
    ///
    /// Running git first and closing the row after was the alternative, and it would leave the
    /// pty alive with its cwd inside a directory `git worktree remove` is unlinking.
    @Test func theRowIsClosedFirstAndTheRemovalStillRuns() async throws {
        let repo = TempRepo()
        defer { repo.destroy() }
        let worktree = repo.addClaudeWorktree("duck", branch: "feature")

        let harness = MainWindowControllerTests.makeHarness()
        let seen = Mutex<[WorktreeRemoval.Request]>([])
        let git = GitIntegration(
            store: harness.store,
            runDelete: { request in
                seen.withLock { $0.append(request) }
                return .removedWithBranch(branch: request.branch ?? "")
            })
        harness.controller.git = git
        git.start()

        // A row that really sits in that worktree, so `RepoInfo` resolves for it.
        let id = Fixture.sessionID(3)
        harness.mutate { state in
            state.setStatus(.idle, for: id)
            state.setWorktree(id, path: worktree, isWorktree: true)
            state.updateLive(id) {
                $0.paneCwds = [:]
                $0.git = GitSummary(branch: "feature", isWorktree: true)
            }
        }
        git.service.track(id, directory: worktree)
        await SheetTestSupport.settle(.seconds(5)) { git.service.repoInfo(for: id) != nil }
        let info = try #require(git.service.repoInfo(for: id))
        #expect(info.isWorktree)

        let request = try #require(git.deleteWorktreeRequest(for: id))
        #expect(request.worktreePath == info.toplevel)
        #expect(request.repoRoot == info.repoRoot)
        #expect(request.branch == "feature")

        // Drive the sheet's Delete the way the button does.
        var model = DeleteWorktreeSheetModel(worktreePath: worktree)
        model.branch = "feature"
        model.merge = .prMerged(number: 12)
        model.phase = .ready
        harness.controller.deleteWorktreeSheet.present(
            for: id, request: nil, pr: nil, model: model, over: nil)
        harness.controller.performWorktreeDelete(for: id, branchDelete: .safe)
        harness.store.flush()

        #expect(harness.store.state.sessions[id] == nil, "the row goes before git runs")
        await SheetTestSupport.settle(.seconds(5)) { !seen.withLock(\.isEmpty) }
        let ran = seen.withLock { $0 }
        #expect(ran.count == 1)
        #expect(ran.first?.worktreePath == info.toplevel)
        #expect(ran.first?.branchDelete == .safe)
        #expect(ran.first?.force == false)
        git.stop()
    }
}

// MARK: - A real repository, for the ordering test

/// The smallest temp repo these tests need. `GitStatusTests` has `TKZ26Fixture` for this, but it
/// is a test-target-local type; the app suite needs its own, and only needs two operations.
final class TempRepo {
    let root: String
    let checkout: String

    init() {
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tkz70-\(UUID().uuidString)")
        checkout = (root as NSString).appendingPathComponent("repo")
        try? FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
        run(["init", "-b", "main"], in: checkout)
        run(["commit", "--allow-empty", "-m", "root"], in: checkout)
    }

    func destroy() { try? FileManager.default.removeItem(atPath: root) }

    func addClaudeWorktree(_ name: String, branch: String) -> String {
        let parent = (checkout as NSString).appendingPathComponent(".claude/worktrees")
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let directory = (parent as NSString).appendingPathComponent(name)
        run(["worktree", "add", "-b", branch, directory], in: checkout)
        return directory
    }

    /// Hermetic: an identity is supplied and the user's own config is out of the picture, so a
    /// global `commit.gpgsign` cannot block this on pinentry.
    @discardableResult
    private func run(_ arguments: [String], in directory: String) -> Int32 {
        let config = [
            "-c", "user.name=tkzmux test", "-c", "user.email=test@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main",
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = config + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
