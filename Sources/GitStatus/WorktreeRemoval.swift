// WorktreeRemoval — "delete this merged worktree and its branch" (TKZ-70).
//
// The **second** place in the app that runs git commands which write to a repo; `GitRebase` is the
// first, and this file deliberately mirrors it case for case — a `Request` captured on the main
// actor, a pure `preflight`, a blocking `run` that must never touch the main actor, and an
// `Outcome` the coordinator turns into one line in the status strip. `docs/privacy.md` lists both
// separately for that reason.
//
// **One invariant governs the whole file: every command runs `-C <repoRoot>` — the *main*
// checkout — against an explicit `<branch>` refname. Never `-C <worktreePath>`, never `HEAD`.**
// The single exception is the dirty check, which needs the worktree directory by definition.
// Three reasons, all load-bearing:
//
//   * `git branch -d` cannot run anywhere else. Before the removal git refuses to delete a branch
//     that is checked out in another worktree; after it, `<main>/.git/worktrees/<name>` is gone
//     along with the directory, so `-C <worktree>` has neither a cwd nor a gitdir.
//   * Classification then works identically before and after the directory disappears — which is
//     the normal case, since `claude -w` offers to remove its own worktree when the conversation
//     ends.
//   * "No step ever names the worktree as its cwd" becomes a one-line test over `plan`.
//
// Two rules about how far this goes:
//
//   * **A failed branch delete is never rolled back into a failed removal.** The worktree really
//     is gone; re-creating it would be a second destructive act. `removedBranchNotMerged` and
//     `removedBranchFailed` both carry "the first half succeeded" in the case name.
//   * **Nothing prunes.** `git worktree remove` already drops the registration, and
//     `git worktree prune` is repo-wide — it would clean up worktrees the user never opened as a
//     row, which is exactly what this feature promises not to touch.

import Foundation
import TkzCore

public enum WorktreeRemoval {

    // MARK: - Classification

    /// How a worktree's branch stands relative to the base. The sheet's headline.
    public enum MergeState: Hashable, Sendable {
        /// The branch's PR is merged on GitHub. Outranks everything below: a squash- or
        /// rebase-merged PR leaves a branch that is *not* an ancestor of the base, and no local
        /// check can see that it landed.
        case prMerged(number: Int?)
        /// `git merge-base --is-ancestor <branch> <base>` said yes.
        case mergedIntoBase(base: String)
        /// `commits` are on the branch and not on `base`.
        case unmerged(commits: Int?, base: String)
        /// The worktree's branch *is* the base branch — not a deletable feature branch.
        case onBase(base: String)
        /// Detached HEAD: there is no branch to classify or to delete.
        case detached
        /// No base resolved, the base ref does not exist, or git could not answer.
        ///
        /// **Fails closed**: every consumer must render this as unmerged, never as merged. That
        /// is the whole reason it is a case of its own rather than a `nil` somewhere.
        case unknown

        /// Whether the branch can be deleted with a plain `-d` and be expected to succeed.
        public var isMerged: Bool {
            switch self {
            case .prMerged, .mergedIntoBase: true
            case .unmerged, .onBase, .detached, .unknown: false
            }
        }
    }

    /// `MergeState` plus the working tree's state — everything the sheet needs to describe what it
    /// is about to do.
    public struct Classification: Hashable, Sendable {
        public var merge: MergeState
        /// Tracked **and** untracked: `git worktree remove` refuses on untracked files too, unlike
        /// `git rebase --autostash`, which leaves them alone.
        public var isDirty: Bool
        public var dirtyFileCount: Int

        public init(merge: MergeState, isDirty: Bool = false, dirtyFileCount: Int = 0) {
            self.merge = merge
            self.isDirty = isDirty
            self.dirtyFileCount = dirtyFileCount
        }
    }

    /// Everything derivable from the last posted summary, with no process launched — cheap enough
    /// for menu validation, exactly like `GitRebase.preflight`.
    ///
    /// **Not authoritative for the delete.** `GitStatusService` leaves `aheadOfBase` nil in three
    /// different situations (the row is on the base and the `rev-list` is skipped; the base ref is
    /// missing; the `rev-list` timed out) and on a timeout it carries the *last posted* numbers
    /// forward onto a fresh summary — so a non-nil count can be minutes old. Good enough for a row
    /// label; not good enough to decide what to delete. `survey` is what the sheet opens with.
    public static func classify(summary: GitSummary?, pr: PRInfo?) -> Classification {
        guard let summary else { return Classification(merge: .unknown) }
        let dirty = summary.changedFiles + summary.untrackedFiles

        // Checked first, and before the branch even has to exist: a merged PR is a one-way door,
        // and it is the only signal that survives a squash or rebase merge.
        if pr?.state?.uppercased() == "MERGED" {
            return Classification(
                merge: .prMerged(number: pr?.number), isDirty: dirty > 0, dirtyFileCount: dirty)
        }

        let merge: MergeState
        if summary.branch == nil {
            merge = .detached
        } else if let base = summary.baseBranch {
            if summary.branch == baseName(of: base) {
                merge = .onBase(base: base)
            } else if let ahead = summary.aheadOfBase {
                merge = ahead > 0 ? .unmerged(commits: ahead, base: base) : .mergedIntoBase(base: base)
            } else {
                merge = .unknown
            }
        } else {
            merge = .unknown
        }
        return Classification(merge: merge, isDirty: dirty > 0, dirtyFileCount: dirty)
    }

    /// `origin/main` → `main`; a bare `main` is already the name. `BaseBranch.ref` is what lands in
    /// `GitSummary.baseBranch`, and the branch it is compared with is a local short name.
    static func baseName(of ref: String) -> String {
        guard let slash = ref.lastIndex(of: "/") else { return ref }
        return String(ref[ref.index(after: slash)...])
    }

    // MARK: - Request

    /// What to do with the branch once the worktree is gone.
    public enum BranchDelete: Hashable, Sendable {
        /// Leave it.
        case keep
        /// `git branch -d` — git refuses a branch with commits the main checkout lacks.
        case safe
        /// `git branch -D` — **only** from the sheet's red *Delete branch too* button.
        case force
    }

    /// Everything one removal needs, captured on the main actor and handed to a background queue.
    ///
    /// **It must be self-sufficient.** By the time `run` executes, the row has been closed and
    /// `GitIntegration.forget` has dropped its `RepoInfo`, its `GitSummary` and its PR — see the
    /// ordering note in `GitIntegration.deleteWorktree`. Nothing in this file may look anything up
    /// by session; every string it will ever read is in here.
    public struct Request: Hashable, Sendable {
        /// `RepoInfo.toplevel` of the *worktree* — the directory that gets removed.
        public var worktreePath: String
        /// `RepoInfo.repoRoot` — the MAIN checkout. The `-C` of every command in the plan.
        public var repoRoot: String
        /// `RepoInfo.gitDir` — `<main>/.git/worktrees/<name>`. Not in the plan; kept so a caller
        /// can explain an already-removed worktree without re-deriving it.
        public var gitDir: String
        /// The worktree's branch; `nil` on a detached HEAD.
        public var branch: String?
        public var base: BaseBranch?
        /// `AgentKind.worktreeMarker` for the row's agent — `"/.claude/worktrees/"`. An agent with
        /// no marker of its own can never produce a deletable worktree; `preflight` refuses.
        public var marker: String
        /// The user ticked *Discard them and delete anyway*: `worktree remove --force`.
        public var force: Bool
        public var branchDelete: BranchDelete
        public var gitPath: String
        /// The branch this request was prepared for, captured on the main actor. `run` re-checks
        /// `HEAD` against it immediately before it writes, so a branch switched (or a detach) in
        /// the worktree's own terminal while the sheet was up cannot delete an unintended branch.
        /// Same device, same reason, as `GitRebase.Request.expectedBranch`.
        public var expectedBranch: String?

        public init(
            worktreePath: String,
            repoRoot: String,
            gitDir: String,
            branch: String? = nil,
            base: BaseBranch? = nil,
            marker: String = "",
            force: Bool = false,
            branchDelete: BranchDelete = .keep,
            gitPath: String = GitProcess.gitPath,
            expectedBranch: String? = nil
        ) {
            self.worktreePath = worktreePath
            self.repoRoot = repoRoot
            self.gitDir = gitDir
            self.branch = branch
            self.base = base
            self.marker = marker
            self.force = force
            self.branchDelete = branchDelete
            self.gitPath = gitPath
            self.expectedBranch = expectedBranch
        }

        /// What the notices and the sheet title call this worktree.
        public var worktreeName: String { (worktreePath as NSString).lastPathComponent }
    }

    // MARK: - Survey

    /// The definitive, fresh state the sheet opens with.
    public struct Survey: Hashable, Sendable {
        public var merge: MergeState
        public var isDirty: Bool
        public var dirtyFileCount: Int
        /// What `HEAD` actually points at right now; `nil` on a detached HEAD or when git failed.
        public var headBranch: String?

        public init(
            merge: MergeState, isDirty: Bool = false, dirtyFileCount: Int = 0,
            headBranch: String? = nil
        ) {
            self.merge = merge
            self.isDirty = isDirty
            self.dirtyFileCount = dirtyFileCount
            self.headBranch = headBranch
        }
    }

    /// Why the sheet could not describe the worktree. A type rather than a bare `String` because
    /// `Result`'s failure must be an `Error`; the message is what the sheet shows.
    public struct SurveyFailure: Error, Hashable, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    /// Three or four local git launches, blocking — never on the main actor.
    ///
    /// **No fetch, ever.** The base is only as fresh as the opt-in origin check last made it,
    /// which is what the ticket asks for. A stale base can only *overstate* the unmerged commits,
    /// and overstating them only makes the sheet more cautious: it offers "Delete, keep branch"
    /// where a plain "Delete" would have done.
    ///
    /// `pr` is passed through from the store rather than looked up: no `gh` call belongs on a
    /// destructive path, and `PRLookup` has already answered within the last five minutes.
    public static func survey(_ request: Request, pr: PRInfo?) -> Result<Survey, SurveyFailure> {
        let dirty = dirtyCount(request)
        let head = currentBranch(request)

        if pr?.state?.uppercased() == "MERGED" {
            return .success(Survey(
                merge: .prMerged(number: pr?.number), isDirty: (dirty ?? 0) > 0,
                dirtyFileCount: dirty ?? 0, headBranch: head))
        }

        let merge: MergeState
        if let branch = request.branch {
            if let base = request.base {
                if branch == base.name {
                    merge = .onBase(base: base.ref)
                } else {
                    switch isAncestor(request, branch: branch, base: base) {
                    case .some(true): merge = .mergedIntoBase(base: base.ref)
                    case .some(false):
                        merge = .unmerged(
                            commits: unmergedCount(request, branch: branch, base: base),
                            base: base.ref)
                    case nil: merge = .unknown
                    }
                }
            } else {
                merge = .unknown
            }
        } else {
            merge = .detached
        }

        // The dirty read is the one call whose failure the sheet must not paper over: it gates
        // `--force`, and "we could not tell" must not read as "clean". `worktree remove` would
        // refuse on its own, but by then the row is already closed.
        guard let dirty else {
            return .failure(SurveyFailure("could not read the worktree's status"))
        }
        return .success(Survey(
            merge: merge, isDirty: dirty > 0, dirtyFileCount: dirty, headBranch: head))
    }

    /// `git -C <repoRoot> merge-base --is-ancestor <branch> <base>`. Exit 0 = yes, 1 = no,
    /// anything else (128: no such ref) = `nil`, which the caller renders as `.unknown`.
    ///
    /// Three exit codes is exactly why this beats reusing the summary's `rev-list` count: that one
    /// collapses "bad ref" into the same non-zero exit as everything else. It is also cheaper —
    /// `--is-ancestor` stops at the merge base instead of walking the whole ahead set.
    static func isAncestor(_ request: Request, branch: String, base: BaseBranch) -> Bool? {
        guard
            let output = try? GitProcess.git(
                ["merge-base", "--is-ancestor", branch, base.ref],
                in: request.repoRoot, gitPath: request.gitPath)
        else { return nil }
        switch output.status {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    /// `git -C <repoRoot> rev-list --count <base>..<branch>` — the sheet's "N commits not on main".
    /// `nil` when git could not answer; the sheet then says so rather than showing a number.
    static func unmergedCount(_ request: Request, branch: String, base: BaseBranch) -> Int? {
        guard
            let output = try? GitProcess.git(
                ["rev-list", "--count", "\(base.ref)..\(branch)"],
                in: request.repoRoot, gitPath: request.gitPath),
            output.succeeded
        else { return nil }
        return Int(output.trimmedOutput)
    }

    /// Tracked + untracked changes in the worktree. The one read that runs in the worktree itself.
    /// `nil` when the directory is gone or git could not be launched.
    static func dirtyCount(_ request: Request) -> Int? {
        guard
            let output = try? GitProcess.git(
                ["status", "--porcelain=v2", "-z"], in: request.worktreePath, gitPath: request.gitPath),
            output.succeeded
        else { return nil }
        let status = GitStatusParsing.parsePorcelainV2(output.standardOutput)
        return status.changedFiles + status.untrackedFiles
    }

    /// The short name `HEAD` points at in the worktree, or `nil` on a detached HEAD / a directory
    /// that is already gone.
    static func currentBranch(_ request: Request) -> String? {
        guard
            let output = try? GitProcess.git(
                ["symbolic-ref", "-q", "--short", "HEAD"],
                in: request.worktreePath, gitPath: request.gitPath),
            output.succeeded
        else { return nil }
        let name = output.trimmedOutput
        return name.isEmpty ? nil : name
    }

    // MARK: - Commands (pure)

    /// One repo-writing command. A local type rather than `TkzApp`'s `UpdateCommand`: `GitStatus`
    /// must not depend on the app, and the environment here is `GitProcess.environment`'s job.
    public struct Step: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case removeWorktree, deleteBranch }
        public var kind: Kind
        public var executable: String
        /// The complete argv after the executable, ready for `GitProcess.run`.
        public var arguments: [String]
        public var timeout: TimeInterval

        public init(kind: Kind, executable: String, arguments: [String], timeout: TimeInterval) {
            self.kind = kind
            self.executable = executable
            self.arguments = arguments
            self.timeout = timeout
        }
    }

    /// Nothing here touches the network, so these are local-filesystem bounds, not link bounds:
    /// 30 s is generous for unlinking a checkout on a slow or network-mounted volume, and a ref
    /// write is already pathological at 15.
    public static let removeTimeout: TimeInterval = 30
    public static let branchTimeout: TimeInterval = 15

    /// Every command this removal will run, in order. Pure: no process, no filesystem, no clock.
    ///
    /// This is what the ticket's "the command plan" acceptance criterion tests, and what the table
    /// in `docs/privacy.md` transcribes. `run` executes *this* list and builds argv nowhere else,
    /// so the test and production cannot drift.
    ///
    /// `--no-optional-locks` is deliberately absent, as it is on `GitRebase`'s write commands:
    /// `GitProcess.environment` still sets `GIT_OPTIONAL_LOCKS=0` on every call, so the protection
    /// is intact and the argv stays readable next to the privacy table.
    ///
    /// **The order is load-bearing.** `git branch -d` refuses a branch checked out in another
    /// worktree ("Cannot delete branch 'x' used by worktree at …"), so the removal must come first.
    public static func plan(_ request: Request) -> [Step] {
        var steps: [Step] = []
        var remove = ["-C", request.repoRoot, "worktree", "remove"]
        if request.force { remove.append("--force") }
        remove.append(request.worktreePath)
        steps.append(Step(
            kind: .removeWorktree, executable: request.gitPath, arguments: remove,
            timeout: removeTimeout))

        if request.branchDelete != .keep, let branch = request.branch, !branch.isEmpty {
            steps.append(Step(
                kind: .deleteBranch, executable: request.gitPath,
                arguments: [
                    "-C", request.repoRoot, "branch",
                    request.branchDelete == .force ? "-D" : "-d", branch,
                ],
                timeout: branchTimeout))
        }
        return steps
    }

    // MARK: - Preflight

    /// Why a removal was not even attempted.
    public enum Refusal: Hashable, Sendable {
        /// The path is not exactly `<repo><marker><name>` — not a worktree this app opened as a
        /// row. Covers an agent with no worktree marker of its own, too.
        case notAWorktreePath
        /// `git worktree list` in this repo does not list it.
        case notThisRepositorysWorktree
        /// The path is the main checkout.
        case mainCheckout
        /// The main checkout lives *inside* the worktree; removing it would take the repo with it.
        case containsRepoRoot
        /// git lists no such worktree and the directory is not there either.
        case missing
        /// `git worktree lock` was run on it.
        case locked
        /// Detached HEAD, and a branch delete was asked for.
        case detachedHead
        /// The branch is the repo's base branch.
        case branchIsBase
        /// Uncommitted or untracked changes, and the user has not acknowledged them.
        case dirtyTree
        /// `HEAD` moved to a different branch since the request was built.
        case headMoved
        /// The row's agent is mid-turn and may be editing files under the worktree.
        case agentWorking
        /// A rebase is running on this worktree.
        case rebaseInProgress
        /// A delete is already running on this worktree.
        case deleteInProgress
    }

    /// The pure half: every check that is a comparison over inputs the caller already has, so the
    /// safety rules are tests rather than observations.
    ///
    /// The three app-state facts are parameters rather than a second function on purpose — the
    /// disabled menu item's tooltip and the refusal notice both go through one list of reasons and
    /// so can never disagree.
    public static func preflight(
        _ request: Request,
        worktrees: [String],
        locked: Set<String>,
        isDirty: Bool,
        isWorktreeRow: Bool,
        agentWorking: Bool = false,
        rebaseInProgress: Bool = false,
        deleteInProgress: Bool = false
    ) -> Refusal? {
        let path = RepoInfo.resolve(request.worktreePath)
        let root = RepoInfo.resolve(request.repoRoot)

        // The two catastrophic cases first, even though the marker check below would refuse them
        // anyway (a main checkout is never marker-shaped): they are the ones worth naming, and a
        // refusal that says "that is the repository itself" beats one that says "not a worktree".
        guard path != root else { return .mainCheckout }
        guard !root.hasPrefix(path + "/") else { return .containsRepoRoot }

        // "Never delete a worktree that the user did not open as a WT row", and "never one that is
        // not under the repo's `.claude/worktrees`". The marker match is exact: a *subdirectory*
        // of a worktree resolves to the worktree above it, and removing that is not what was asked.
        guard isWorktreeRow else { return .notAWorktreePath }
        guard !request.marker.isEmpty,
              let markerRoot = AgentKind.worktreeRoot(ofPath: request.worktreePath, marker: request.marker),
              RepoInfo.resolve(markerRoot) == path
        else { return .notAWorktreePath }

        // git's first entry is always the main checkout, so it is never a removal candidate.
        guard WorktreeList.containsResolved(Array(worktrees.dropFirst()), path: path) else {
            return FileManager.default.fileExists(atPath: path)
                ? .notThisRepositorysWorktree : .missing
        }
        guard !locked.contains(where: { RepoInfo.resolve($0) == path }) else { return .locked }

        if request.branchDelete != .keep {
            guard let branch = request.branch, !branch.isEmpty else { return .detachedHead }
            if let base = request.base, branch == base.name { return .branchIsBase }
        }

        if isDirty && !request.force { return .dirtyTree }
        if agentWorking { return .agentWorking }
        if rebaseInProgress { return .rebaseInProgress }
        if deleteInProgress { return .deleteInProgress }
        return nil
    }

    /// The wrapper `run` uses: one `git worktree list --porcelain` launch for both the paths and
    /// the locks, plus the dirty read. The app-state facts are the caller's — `GitIntegration`
    /// has already checked them on the main actor and they cannot change under a queued request.
    public static func preflight(_ request: Request) -> Refusal? {
        guard let porcelain = try? WorktreeList.porcelain(
            repoRoot: request.repoRoot, gitPath: request.gitPath)
        else { return .notThisRepositorysWorktree }
        return preflight(
            request,
            worktrees: WorktreeList.parse(porcelain),
            locked: WorktreeList.parseLocked(porcelain),
            // A directory already gone reads as clean, which is right: there is nothing to lose,
            // and git's own `worktree remove` handles the prunable case.
            isDirty: (dirtyCount(request) ?? 0) > 0,
            isWorktreeRow: true)
    }

    // MARK: - Outcome

    public enum Outcome: Hashable, Sendable {
        /// The worktree is gone; the branch was kept on purpose (`branchDelete == .keep`).
        case removed
        /// Both gone.
        case removedWithBranch(branch: String)
        /// The worktree is gone and `git branch -d` refused: the branch has commits the main
        /// checkout does not have. This is the state the red *Delete branch too* button acts on.
        case removedBranchNotMerged(branch: String)
        /// The worktree is gone; deleting the branch failed for some other reason (git's last line).
        case removedBranchFailed(branch: String, message: String)
        /// `worktree remove` refused: modified or untracked files. **Nothing was removed.**
        case dirty
        /// `worktree remove` refused: the worktree is locked. **Nothing was removed.**
        case locked
        /// `worktree remove` failed for any other reason (in use, permissions). Nothing was removed.
        case removalFailed(String)
        /// `step` is `"remove"` or `"branch"`.
        case timedOut(step: String)
        /// `preflight` said no; nothing was run.
        case refused(Refusal)
    }

    /// The production executor. The only place this file launches a process for a write.
    public static func execute(_ step: Step) -> Result<GitProcess.Output, GitProcess.Failure> {
        do {
            return .success(try GitProcess.run(step.executable, step.arguments, timeout: step.timeout))
        } catch let failure as GitProcess.Failure {
            return .failure(failure)
        } catch {
            return .failure(.launchFailed(String(describing: error)))
        }
    }

    /// Preflight, re-check `HEAD`, then run every `Step` of `plan(request)` in order. Blocking —
    /// never on the main actor.
    ///
    /// `execute` is the whole test seam: one defaulted closure, no protocol and no runner object.
    /// A test passes a recording closure and asserts it saw exactly `plan(request)`, which is what
    /// makes "the command plan" a contract rather than a description.
    public static func run(
        _ request: Request,
        execute: (Step) -> Result<GitProcess.Output, GitProcess.Failure> = Self.execute
    ) -> Outcome {
        if let refusal = preflight(request) { return .refused(refusal) }

        // As close to the write as this call can get it: a `git switch` in the worktree's own
        // terminal between the sheet opening and this landing must not delete the wrong branch.
        // Only interesting when a branch delete was asked for — removing a worktree is
        // branch-agnostic.
        //
        // Refused only on a **different** branch, never on `nil`. `currentBranch` answers nil for
        // a detached HEAD *and* for a directory that is already gone — and "already gone" is the
        // normal case here, since `claude -w` offers to remove its own worktree when the
        // conversation ends. Treating that as "HEAD moved" would refuse exactly the cleanup this
        // feature exists for. Neither nil case is evidence of a switch, and the branch step names
        // `request.branch` explicitly, so it can only ever delete the branch the sheet showed.
        if request.branchDelete != .keep, let expected = request.expectedBranch,
            let current = currentBranch(request), current != expected
        {
            return .refused(.headMoved)
        }

        var branchDeleted = false
        for step in plan(request) {
            let result = execute(step)
            switch step.kind {
            case .removeWorktree:
                switch result {
                case .failure(.timedOut): return .timedOut(step: "remove")
                case .failure(let failure): return .removalFailed(String(describing: failure))
                case .success(let output) where !output.succeeded: return removalFailure(output)
                case .success: continue
                }
            case .deleteBranch:
                // Reached only when `plan` emitted the step, which it does only with a branch.
                let branch = request.branch ?? ""
                switch result {
                case .failure(.timedOut): return .timedOut(step: "branch")
                case .failure(let failure):
                    return .removedBranchFailed(branch: branch, message: String(describing: failure))
                case .success(let output) where !output.succeeded:
                    return output.standardError.contains("not fully merged")
                        ? .removedBranchNotMerged(branch: branch)
                        : .removedBranchFailed(branch: branch, message: GitRebase.lastLine(of: output))
                case .success: branchDeleted = true
                }
            }
        }
        if branchDeleted, let branch = request.branch { return .removedWithBranch(branch: branch) }
        return .removed
    }

    /// What `git worktree remove` refused for. Matching on git's own words is safe here precisely
    /// because `GitProcess.environment` pins `LC_ALL=C` — that is what the line is for.
    static func removalFailure(_ output: GitProcess.Output) -> Outcome {
        let text = output.standardError + output.standardOutput
        if text.contains("contains modified or untracked files") { return .dirty }
        if text.contains("is locked") { return .locked }
        return .removalFailed(GitRebase.lastLine(of: output))
    }
}
