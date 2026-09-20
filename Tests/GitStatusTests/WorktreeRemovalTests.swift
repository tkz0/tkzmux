// WorktreeRemoval — classification, the command plan, the safety preflight, and the real removals
// (TKZ-70).
//
// Three kinds of test, deliberately kept apart:
//
//   * `classify` and `plan` are pure, so they are asserted against literals with no repo at all.
//     `plan` in particular is the ticket's own acceptance criterion ("tests with a temp repo: the
//     merged/unmerged classification and the command plan") and the contract `docs/privacy.md`
//     transcribes — `runExecutesExactlyThePlan` is what stops the two drifting.
//   * `survey` and `preflight` run against real temp repos, because the interesting cases
//     (squash merge, a locked worktree, a worktree git has forgotten) cannot be faked.
//   * `run` end to end, asserting the *disk*, not just the outcome: the directory, the worktree
//     list and the branch.
//
// Serialized for the same reason as `GitStatusServiceTests`: these block a thread on `git`, and
// twenty at once starve libdispatch's pool until `GitProcess`'s timeout fires.

import Foundation
import Testing
import TkzCore

@testable import GitStatus

// MARK: - Fixture extensions

extension TKZ26Fixture {
    /// A worktree where `claude -w` puts one — `<checkout>/.claude/worktrees/<name>` — which is
    /// the only shape `WorktreeRemoval.preflight` accepts. `TKZ26Fixture.addWorktree` puts it at
    /// `root/<name>`, which has no marker in its path; that one stays so `refusesAWorktreeOutside…`
    /// has something to refuse.
    func addClaudeWorktree(_ name: String, of checkout: String, branch: String) -> String {
        let parent = (checkout as NSString).appendingPathComponent(".claude/worktrees")
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let directory = (parent as NSString).appendingPathComponent(name)
        git(["worktree", "add", "-b", branch, directory], in: checkout)
        return directory
    }

    /// `git merge --no-ff` in the main checkout, so `<branch>` is a genuine ancestor of `<target>`.
    func merge(_ branch: String, into target: String, in checkout: String) {
        git(["switch", target], in: checkout)
        git(["merge", "--no-ff", "--no-edit", branch], in: checkout)
    }

    /// A squash merge: the *content* lands on `target` but `branch` is **not** an ancestor of it.
    /// The normal GitHub shape, and the reason the PR signal has to outrank the ancestor check.
    func squashMerge(_ branch: String, into target: String, in checkout: String) {
        git(["switch", target], in: checkout)
        git(["merge", "--squash", branch], in: checkout)
        git(["commit", "-m", "squashed \(branch)"], in: checkout)
    }

    func commitFile(_ text: String, to name: String, in directory: String, message: String = "change") {
        write(text, to: (directory as NSString).appendingPathComponent(name))
        git(["add", "-A"], in: directory)
        git(["commit", "-m", message], in: directory)
    }

    func lockWorktree(_ path: String, in checkout: String) {
        git(["worktree", "lock", path], in: checkout)
    }

    func worktreePaths(in checkout: String) -> [String] {
        (try? WorktreeList.list(repoRoot: checkout)) ?? []
    }

    func branchExists(_ branch: String, in checkout: String) -> Bool {
        git(["rev-parse", "-q", "--verify", "refs/heads/\(branch)"], in: checkout).succeeded
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

private let marker = "/.claude/worktrees/"

private func request(
    worktree: String, repoRoot: String, branch: String? = "feature",
    base: BaseBranch? = BaseBranch(remote: nil, name: "main"),
    force: Bool = false, branchDelete: WorktreeRemoval.BranchDelete = .keep,
    expectedBranch: String? = nil
) -> WorktreeRemoval.Request {
    WorktreeRemoval.Request(
        worktreePath: worktree,
        repoRoot: repoRoot,
        gitDir: (repoRoot as NSString).appendingPathComponent(
            ".git/worktrees/\((worktree as NSString).lastPathComponent)"),
        branch: branch, base: base, marker: marker,
        force: force, branchDelete: branchDelete, expectedBranch: expectedBranch)
}

private func summary(
    branch: String? = "feature", base: String? = "origin/main",
    ahead: Int? = nil, changed: Int = 0, untracked: Int = 0
) -> GitSummary {
    GitSummary(
        branch: branch, changedFiles: changed, untrackedFiles: untracked,
        isWorktree: true, baseBranch: base, aheadOfBase: ahead,
        behindBase: ahead == nil ? nil : 0)
}

// MARK: - Classification (pure)

struct WorktreeRemovalClassifyTests {

    @Test func aMergedPRBeatsTheCommitCount() {
        let result = WorktreeRemoval.classify(
            summary: summary(ahead: 2), pr: PRInfo(number: 12, state: "MERGED"))
        #expect(result.merge == .prMerged(number: 12))
        #expect(result.merge.isMerged)
    }

    @Test func anOpenPRFallsBackToTheCount() {
        let result = WorktreeRemoval.classify(
            summary: summary(ahead: 2), pr: PRInfo(number: 12, state: "OPEN"))
        #expect(result.merge == .unmerged(commits: 2, base: "origin/main"))
    }

    @Test func zeroAheadIsMergedIntoTheBase() {
        #expect(
            WorktreeRemoval.classify(summary: summary(ahead: 0), pr: nil).merge
                == .mergedIntoBase(base: "origin/main"))
    }

    /// The fail-closed assertion. `aheadOfBase == nil` means "on the base", "no such ref" or
    /// "rev-list timed out" — never "merged".
    @Test func anUnmeasuredBranchIsUnknownNotMerged() {
        let result = WorktreeRemoval.classify(summary: summary(ahead: nil), pr: nil)
        #expect(result.merge == .unknown)
        #expect(!result.merge.isMerged)
    }

    @Test func theBaseBranchItselfIsNotADeletableBranch() {
        let result = WorktreeRemoval.classify(
            summary: summary(branch: "main", base: "origin/main"), pr: nil)
        #expect(result.merge == .onBase(base: "origin/main"))
        #expect(!result.merge.isMerged)
    }

    @Test func aDetachedHeadClassifiesAsDetached() {
        #expect(WorktreeRemoval.classify(summary: summary(branch: nil), pr: nil).merge == .detached)
    }

    @Test func noSummaryAtAllIsUnknown() {
        #expect(WorktreeRemoval.classify(summary: nil, pr: nil).merge == .unknown)
    }

    /// `git worktree remove` refuses on untracked files too, so they count as dirty here —
    /// unlike `git rebase --autostash`, which leaves them alone.
    @Test func untrackedFilesCountAsDirty() {
        let result = WorktreeRemoval.classify(summary: summary(ahead: 0, untracked: 3), pr: nil)
        #expect(result.isDirty)
        #expect(result.dirtyFileCount == 3)
    }

    @Test func aRemoteBasesShortNameIsWhatTheBranchIsComparedWith() {
        #expect(WorktreeRemoval.baseName(of: "origin/main") == "main")
        #expect(WorktreeRemoval.baseName(of: "main") == "main")
    }
}

// MARK: - The command plan (pure)

struct WorktreeRemovalPlanTests {

    private let wt = "/repo/.claude/worktrees/duck"
    private let root = "/repo"

    @Test func aCleanMergedWorktreeIsTwoSteps() {
        let steps = WorktreeRemoval.plan(
            request(worktree: wt, repoRoot: root, branchDelete: .safe))
        #expect(steps.count == 2)
        #expect(steps[0].arguments == ["-C", root, "worktree", "remove", wt])
        #expect(steps[1].arguments == ["-C", root, "branch", "-d", "feature"])
    }

    /// Acknowledging a dirty tree must not escalate the *branch* delete: `--force` on step 1,
    /// still a plain `-d` on step 2.
    @Test func acknowledgingADirtyTreeForcesOnlyTheRemoval() {
        let steps = WorktreeRemoval.plan(
            request(worktree: wt, repoRoot: root, force: true, branchDelete: .safe))
        #expect(steps[0].arguments == ["-C", root, "worktree", "remove", "--force", wt])
        #expect(steps[1].arguments == ["-C", root, "branch", "-d", "feature"])
    }

    @Test func theRedButtonIsTheOnlyThingThatProducesCapitalD() {
        let steps = WorktreeRemoval.plan(
            request(worktree: wt, repoRoot: root, branchDelete: .force))
        #expect(steps[1].arguments == ["-C", root, "branch", "-D", "feature"])
    }

    @Test func keepingTheBranchIsOneStep() {
        let steps = WorktreeRemoval.plan(
            request(worktree: wt, repoRoot: root, branchDelete: .keep))
        #expect(steps.count == 1)
        #expect(steps[0].kind == .removeWorktree)
    }

    @Test func aDetachedWorktreeHasNoBranchStepEvenWhenForced() {
        let steps = WorktreeRemoval.plan(
            request(worktree: wt, repoRoot: root, branch: nil, branchDelete: .force))
        #expect(steps.count == 1)
    }

    @Test func theRemovalIsAlwaysFirstAndNothingPrunes() {
        let steps = WorktreeRemoval.plan(
            request(worktree: wt, repoRoot: root, branchDelete: .safe))
        #expect(steps.first?.kind == .removeWorktree)
        #expect(!steps.contains { $0.arguments.contains("prune") })
    }

    /// The file's one invariant, as a test: `git branch -d` cannot run in the worktree (before the
    /// removal git refuses; after it there is no gitdir), so nothing may.
    @Test func everyStepRunsInTheMainCheckout() {
        for branchDelete in [WorktreeRemoval.BranchDelete.keep, .safe, .force] {
            for force in [false, true] {
                let prepared = request(
                    worktree: wt, repoRoot: root, force: force, branchDelete: branchDelete)
                for step in WorktreeRemoval.plan(prepared) {
                    #expect(step.arguments[0] == "-C")
                    #expect(step.arguments[1] == root)
                }
            }
        }
    }

    @Test func theTimeoutsAreTheDeclaredOnes() {
        let steps = WorktreeRemoval.plan(
            request(worktree: wt, repoRoot: root, branchDelete: .safe))
        #expect(steps[0].timeout == WorktreeRemoval.removeTimeout)
        #expect(steps[1].timeout == WorktreeRemoval.branchTimeout)
    }
}

// MARK: - Preflight (pure half)

struct WorktreeRemovalPreflightTests {

    private let root = "/repo"
    private let wt = "/repo/.claude/worktrees/duck"
    private var listed: [String] { ["/repo", wt] }

    private func check(
        _ prepared: WorktreeRemoval.Request, worktrees: [String]? = nil,
        locked: Set<String> = [], isDirty: Bool = false, isWorktreeRow: Bool = true,
        agentWorking: Bool = false, rebaseInProgress: Bool = false, deleteInProgress: Bool = false
    ) -> WorktreeRemoval.Refusal? {
        WorktreeRemoval.preflight(
            prepared, worktrees: worktrees ?? listed, locked: locked, isDirty: isDirty,
            isWorktreeRow: isWorktreeRow, agentWorking: agentWorking,
            rebaseInProgress: rebaseInProgress, deleteInProgress: deleteInProgress)
    }

    @Test func aCleanMergedWorktreeRowPasses() {
        #expect(check(request(worktree: wt, repoRoot: root, branchDelete: .safe)) == nil)
    }

    @Test func aPathOutsideTheAgentsMarkerIsRefused() {
        #expect(
            check(request(worktree: "/repo/elsewhere", repoRoot: root),
                  worktrees: ["/repo", "/repo/elsewhere"]) == .notAWorktreePath)
    }

    /// An agent with no worktree marker of its own (everything but Claude today) can never produce
    /// a deletable worktree.
    @Test func anAgentWithNoMarkerIsRefused() {
        var prepared = request(worktree: wt, repoRoot: root)
        prepared.marker = ""
        #expect(check(prepared) == .notAWorktreePath)
    }

    /// A *subdirectory* of a worktree resolves to the worktree above it; removing that is not
    /// what was pointed at.
    @Test func aSubdirectoryOfAWorktreeIsRefused() {
        #expect(
            check(request(worktree: wt + "/Sources", repoRoot: root)) == .notAWorktreePath)
    }

    @Test func aRowThatIsNotAWorktreeRowIsRefused() {
        #expect(check(request(worktree: wt, repoRoot: root), isWorktreeRow: false) == .notAWorktreePath)
    }

    @Test func theMainCheckoutIsRefused() {
        #expect(check(request(worktree: root, repoRoot: root)) == .mainCheckout)
    }

    @Test func aWorktreeGitDoesNotListIsRefused() {
        #expect(
            check(request(worktree: wt, repoRoot: root), worktrees: ["/repo"])
                == .missing)
    }

    /// git always prints the main checkout first, so it can never match as a removal candidate
    /// even when its own path is handed in.
    @Test func theFirstEntryIsNeverARemovalCandidate() {
        #expect(check(request(worktree: wt, repoRoot: root), worktrees: [wt]) == .missing)
    }

    @Test func aLockedWorktreeIsRefused() {
        #expect(check(request(worktree: wt, repoRoot: root), locked: [wt]) == .locked)
    }

    @Test func aDetachedHeadIsRefusedOnlyWhenABranchDeleteWasAskedFor() {
        #expect(
            check(request(worktree: wt, repoRoot: root, branch: nil, branchDelete: .safe))
                == .detachedHead)
        #expect(check(request(worktree: wt, repoRoot: root, branch: nil, branchDelete: .keep)) == nil)
    }

    @Test func theBaseBranchIsNeverDeleted() {
        #expect(
            check(request(worktree: wt, repoRoot: root, branch: "main", branchDelete: .safe))
                == .branchIsBase)
    }

    @Test func aDirtyTreeIsRefusedUntilAcknowledged() {
        #expect(check(request(worktree: wt, repoRoot: root), isDirty: true) == .dirtyTree)
        #expect(check(request(worktree: wt, repoRoot: root, force: true), isDirty: true) == nil)
    }

    @Test func theAppStateReasonsComeBackAsTheirOwnRefusals() {
        let prepared = request(worktree: wt, repoRoot: root)
        #expect(check(prepared, agentWorking: true) == .agentWorking)
        #expect(check(prepared, rebaseInProgress: true) == .rebaseInProgress)
        #expect(check(prepared, deleteInProgress: true) == .deleteInProgress)
    }
}

// MARK: - Survey and removal, against real repos

@Suite(.serialized)
struct WorktreeRemovalRepoTests {

    private func base(_ name: String = "main") -> BaseBranch { BaseBranch(remote: nil, name: name) }

    @Test func aMergedBranchIsAnAncestorOfTheBase() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.commitFile("one\n", to: "a.txt", in: worktree)
        fixture.merge("feature", into: "main", in: checkout)

        let result = WorktreeRemoval.survey(
            request(worktree: worktree, repoRoot: checkout, base: base()), pr: nil)
        #expect(try! result.get().merge == .mergedIntoBase(base: "main"))
    }

    /// The ticket's "2 commits not on main" criterion.
    @Test func anUnmergedBranchReportsItsCommits() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.commitFile("one\n", to: "a.txt", in: worktree)
        fixture.commitFile("two\n", to: "b.txt", in: worktree)

        let result = try! WorktreeRemoval.survey(
            request(worktree: worktree, repoRoot: checkout, base: base()), pr: nil).get()
        #expect(result.merge == .unmerged(commits: 2, base: "main"))
        #expect(!result.isDirty)
        #expect(result.headBranch == "feature")
    }

    /// Both halves of why the PR signal outranks the ancestor check, in one repo state: a
    /// squash-merged branch is genuinely *not* an ancestor, and only the PR knows it landed.
    @Test func aSquashMergedBranchNeedsThePRToKnowItLanded() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.commitFile("one\n", to: "a.txt", in: worktree)
        fixture.squashMerge("feature", into: "main", in: checkout)
        let prepared = request(worktree: worktree, repoRoot: checkout, base: base())

        #expect(try! WorktreeRemoval.survey(prepared, pr: nil).get().merge
            == .unmerged(commits: 1, base: "main"))
        #expect(try! WorktreeRemoval.survey(prepared, pr: PRInfo(number: 7, state: "MERGED")).get().merge
            == .prMerged(number: 7))
    }

    @Test func aMissingBaseRefIsUnknownNeverMerged() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")

        let result = try! WorktreeRemoval.survey(
            request(worktree: worktree, repoRoot: checkout,
                    base: BaseBranch(remote: "origin", name: "main")), pr: nil).get()
        #expect(result.merge == .unknown)
        #expect(!result.merge.isMerged)
    }

    @Test func theSurveySeesADirtyWorktree() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.write("scratch\n", to: (worktree as NSString).appendingPathComponent("untracked.txt"))

        let result = try! WorktreeRemoval.survey(
            request(worktree: worktree, repoRoot: checkout, base: base()), pr: nil).get()
        #expect(result.isDirty)
        #expect(result.dirtyFileCount == 1)
    }

    /// The anti-drift test, and the reason `execute` is a parameter at all: `run` builds argv
    /// nowhere but `plan`, so a recording executor must see the plan verbatim for every
    /// combination of the two user choices. A real repo, because `run` preflights first — this
    /// asserts what a *passing* preflight then goes on to execute.
    @Test func runExecutesExactlyThePlanAndNothingElse() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")

        for branchDelete in [WorktreeRemoval.BranchDelete.keep, .safe, .force] {
            for force in [false, true] {
                let prepared = request(
                    worktree: worktree, repoRoot: checkout, base: base(),
                    force: force, branchDelete: branchDelete)
                var seen: [WorktreeRemoval.Step] = []
                _ = WorktreeRemoval.run(prepared) { step in
                    seen.append(step)
                    return .success(GitProcess.Output(status: 0, standardOutput: "", standardError: ""))
                }
                #expect(seen == WorktreeRemoval.plan(prepared))
            }
        }
        // Nothing was actually run, so the worktree is still there for the next iteration.
        #expect(fixture.exists(worktree))
    }

    @Test func removesTheWorktreeAndItsMergedBranch() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.commitFile("one\n", to: "a.txt", in: worktree)
        fixture.merge("feature", into: "main", in: checkout)

        let outcome = WorktreeRemoval.run(
            request(worktree: worktree, repoRoot: checkout, base: base(), branchDelete: .safe))
        #expect(outcome == .removedWithBranch(branch: "feature"))
        #expect(!fixture.exists(worktree))
        #expect(!WorktreeList.containsResolved(fixture.worktreePaths(in: checkout), path: worktree))
        #expect(!fixture.branchExists("feature", in: checkout))
    }

    @Test func keepsTheBranchWhenAsked() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.commitFile("one\n", to: "a.txt", in: worktree)
        fixture.merge("feature", into: "main", in: checkout)

        let outcome = WorktreeRemoval.run(
            request(worktree: worktree, repoRoot: checkout, base: base(), branchDelete: .keep))
        #expect(outcome == .removed)
        #expect(!fixture.exists(worktree))
        #expect(fixture.branchExists("feature", in: checkout))
    }

    @Test func refusesADirtyTreeThenRemovesItWhenAcknowledged() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.write("scratch\n", to: (worktree as NSString).appendingPathComponent("untracked.txt"))

        #expect(
            WorktreeRemoval.run(request(worktree: worktree, repoRoot: checkout, base: base()))
                == .refused(.dirtyTree))
        #expect(fixture.exists(worktree))

        #expect(
            WorktreeRemoval.run(
                request(worktree: worktree, repoRoot: checkout, base: base(), force: true))
                == .removed)
        #expect(!fixture.exists(worktree))
    }

    @Test func refusesAWorktreeOutsideTheClaudeMarker() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addWorktree("plain", of: checkout, branch: "feature")

        #expect(
            WorktreeRemoval.run(request(worktree: worktree, repoRoot: checkout, base: base()))
                == .refused(.notAWorktreePath))
        #expect(fixture.exists(worktree))
    }

    @Test func refusesTheMainCheckout() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()

        #expect(
            WorktreeRemoval.run(
                request(worktree: checkout, repoRoot: checkout, branch: "main", base: base()))
                == .refused(.mainCheckout))
        #expect(fixture.exists(checkout))
    }

    @Test func refusesAnotherRepositorysWorktree() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let ours = fixture.makeCheckout("ours")
        let theirs = fixture.makeCheckout("theirs")
        let worktree = fixture.addClaudeWorktree("duck", of: theirs, branch: "feature")

        // Their worktree, our repo root — the path is marker-shaped but under the wrong repo.
        var prepared = request(worktree: worktree, repoRoot: ours, base: base())
        prepared.branchDelete = .safe
        #expect(WorktreeRemoval.run(prepared) == .refused(.notThisRepositorysWorktree))
        #expect(fixture.exists(worktree))
    }

    @Test func refusesALockedWorktree() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.lockWorktree(worktree, in: checkout)

        #expect(
            WorktreeRemoval.run(request(worktree: worktree, repoRoot: checkout, base: base()))
                == .refused(.locked))
        #expect(fixture.exists(worktree))
    }

    /// The most important end-to-end assertion here: the two halves are independent, and a refused
    /// branch delete never resurrects the worktree.
    @Test func theWorktreeIsStillRemovedWhenTheBranchDeleteIsRefused() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.commitFile("one\n", to: "a.txt", in: worktree)
        fixture.commitFile("two\n", to: "b.txt", in: worktree)

        let outcome = WorktreeRemoval.run(
            request(worktree: worktree, repoRoot: checkout, base: base(), branchDelete: .safe))
        #expect(outcome == .removedBranchNotMerged(branch: "feature"))
        #expect(!fixture.exists(worktree))
        #expect(fixture.branchExists("feature", in: checkout))
    }

    @Test func theRedButtonDeletesAnUnmergedBranch() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.commitFile("one\n", to: "a.txt", in: worktree)

        let outcome = WorktreeRemoval.run(
            request(worktree: worktree, repoRoot: checkout, base: base(), branchDelete: .force))
        #expect(outcome == .removedWithBranch(branch: "feature"))
        #expect(!fixture.branchExists("feature", in: checkout))
    }

    @Test func refusesWhenHeadMovedSinceTheRequestWasBuilt() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.git(["switch", "-c", "other"], in: worktree)

        #expect(
            WorktreeRemoval.run(
                request(worktree: worktree, repoRoot: checkout, base: base(),
                        branchDelete: .safe, expectedBranch: "feature"))
                == .refused(.headMoved))
        #expect(fixture.exists(worktree))

        // Removing a worktree is branch-agnostic, so with no branch delete the move is irrelevant.
        #expect(
            WorktreeRemoval.run(
                request(worktree: worktree, repoRoot: checkout, base: base(),
                        branchDelete: .keep, expectedBranch: "feature"))
                == .removed)
    }

    /// `claude -w` removed the directory itself on exit and git still lists it as prunable. The
    /// row's cleanup must still work — and this is why no standalone `git worktree prune` is
    /// needed anywhere.
    @Test func aWorktreeAlreadyGoneFromDiskStillCleansUp() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.commitFile("one\n", to: "a.txt", in: worktree)
        fixture.merge("feature", into: "main", in: checkout)
        try? FileManager.default.removeItem(atPath: worktree)

        // With `expectedBranch` set, as every real request from `GitIntegration` has it: a gone
        // directory answers `nil` for the current branch, and that must not read as "HEAD moved"
        // — this *is* the case the feature exists for.
        let outcome = WorktreeRemoval.run(
            request(
                worktree: worktree, repoRoot: checkout, base: base(), branchDelete: .safe,
                expectedBranch: "feature"))
        #expect(outcome == .removedWithBranch(branch: "feature"))
        #expect(!WorktreeList.containsResolved(fixture.worktreePaths(in: checkout), path: worktree))
        #expect(!fixture.branchExists("feature", in: checkout))
    }

    /// A detached HEAD answers `nil` too, and for the same reason must not be mistaken for a
    /// switch: the branch step names `request.branch`, so it deletes what the sheet showed.
    @Test func aDetachedHeadIsNotMistakenForAMovedHead() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addClaudeWorktree("duck", of: checkout, branch: "feature")
        fixture.commitFile("one\n", to: "a.txt", in: worktree)
        fixture.merge("feature", into: "main", in: checkout)
        fixture.git(["checkout", "--detach"], in: worktree)

        let outcome = WorktreeRemoval.run(
            request(
                worktree: worktree, repoRoot: checkout, base: base(), branchDelete: .safe,
                expectedBranch: "feature"))
        #expect(outcome == .removedWithBranch(branch: "feature"))
        #expect(!fixture.branchExists("feature", in: checkout))
    }
}

// MARK: - WorktreeList additions

struct WorktreeListLockTests {

    private let porcelain = """
        worktree /repo
        HEAD abc
        branch refs/heads/main

        worktree /repo/.claude/worktrees/duck
        HEAD def
        branch refs/heads/feature
        locked

        worktree /repo/.claude/worktrees/goose
        HEAD 012
        branch refs/heads/other
        locked waiting for review

        worktree /repo/.claude/worktrees/swan
        HEAD 345
        branch refs/heads/third

        """

    @Test func parseLockedFindsBothSpellings() {
        let locked = WorktreeList.parseLocked(porcelain)
        #expect(locked == [
            "/repo/.claude/worktrees/duck", "/repo/.claude/worktrees/goose",
        ])
    }

    @Test func parseStillReturnsEveryEntryInOrder() {
        #expect(WorktreeList.parse(porcelain).first == "/repo")
        #expect(WorktreeList.parse(porcelain).count == 4)
    }

    /// `standardizingPath` strips `/private` on macOS while git prints it, so `contains` says no
    /// and `containsResolved` says yes for the same directory. That difference is the reason the
    /// destructive path has its own comparison.
    @Test func containsResolvedMatchesAcrossThePrivatePrefix() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let directory = fixture.makePlainDirectory("here")
        let unresolved = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent((fixture.root as NSString).lastPathComponent + "/here")
        #expect(WorktreeList.containsResolved([directory], path: unresolved))
    }
}
