// DeleteWorktreeSheetModel — what the "Delete worktree…" sheet shows (TKZ-70).
//
// The same posture as `RebaseSheetModel`, and for the same reason: every string the sheet draws is
// derived here, so the sheet's four phases and all three button states are asserted in a test
// rather than looked at. No AppKit, and nothing that reads the clock or the filesystem.
//
// Two rules the strings encode:
//
//   * **"We could not tell" reads as unmerged.** `MergeState.unknown`, and an ahead-count git
//     could not produce, both put the sheet in the cautious shape: the primary button becomes
//     *Delete, keep branch* and the red *Delete branch too* appears next to it. That is the case
//     where the user has to decide, so the button that lets them is exactly what must be there.
//   * **The agent-working hint is byte-identical to the rebase sheet's.** Same rule, same words;
//     a second phrasing for one rule is how two sheets start disagreeing.

import Foundation
import GitStatus
import TkzCore

struct DeleteWorktreeSheetModel: Equatable, Sendable {

    enum Phase: Equatable, Sendable {
        /// Opened; the read-only survey (merged? dirty? how far ahead?) is running on the git
        /// queue. The rebase sheet's `.fetching`, minus the network.
        case checking
        /// The survey is in and the buttons mean something.
        case ready
        /// The survey failed. A delete decided on facts we do not have is exactly what this sheet
        /// must not do, so the buttons stay off.
        case checkFailed(String)
        /// A Delete button was pressed; the row is closing and git is about to run. Guards against
        /// a second Return landing while the close confirmation is up.
        case deleting
    }

    /// How the status line reads — and therefore which colour it takes.
    enum Tone: Equatable, Sendable {
        /// Nothing to worry about: the branch landed.
        case quiet
        /// Something is about to be lost, or could not be established.
        case caution
    }

    // MARK: Inputs

    /// Absolute, from `RepoInfo.toplevel`.
    var worktreePath: String
    /// `MainWindowController.home`, so `pathLine` stays pure.
    var home: String = ""
    /// `nil` on a detached HEAD.
    var branch: String?
    /// `BaseBranch.ref` — `origin/main`. `nil` when no base resolved.
    var baseRef: String?
    var merge: WorktreeRemoval.MergeState = .unknown
    var isDirty = false
    var dirtyFileCount = 0
    /// The checkbox. The controller is its only writer, so "ticking the box enables Delete" is a
    /// model assertion with no AppKit in it.
    var acknowledgedDirty = false
    var phase: Phase = .checking
    /// The row's agent is mid-turn and may be editing files under the worktree.
    var agentWorking = false
    /// What the hint calls the row's agent — `AgentAdapter.displayName`. Defaults to a name that
    /// admits it does not know rather than asserting a product name nobody told this model.
    var agentDisplayName = "the agent"

    // MARK: Derived text

    var worktreeName: String { (worktreePath as NSString).lastPathComponent }
    var baseLabel: String { baseRef.map(StatusBarView.baseLabel) ?? "the base branch" }

    var title: String { "Delete worktree \(worktreeName)" }
    var pathLine: String { PaneHeaderAdapter.abbreviatingHome(worktreePath, home: home) }
    var branchLine: String { branch.map { "\u{2387} \($0)" } ?? "detached HEAD" }

    var statusLine: String {
        switch phase {
        case .checking: return "Checking the worktree\u{2026}"
        case .deleting: return "Deleting\u{2026}"
        case .checkFailed(let message): return "Could not check the branch: \(message)"
        case .ready: break
        }
        switch merge {
        case .prMerged(let number?): return "PR #\(number) merged"
        case .prMerged(nil): return "Its pull request is merged"
        case .mergedIntoBase: return "Branch fully merged into \(baseLabel)"
        case .unmerged(let commits?, _):
            return "\(commits) commit\(commits == 1 ? "" : "s") not on \(baseLabel)"
        case .unmerged(nil, _): return "Could not count the commits not on \(baseLabel)"
        case .onBase: return "This is the base branch"
        case .detached: return "Detached HEAD \u{2014} nothing to compare"
        case .unknown:
            return baseRef == nil
                ? "No base branch to compare with"
                : "Could not compare the branch with \(baseLabel)"
        }
    }

    var statusTone: Tone {
        guard case .ready = phase else {
            if case .checkFailed = phase { return .caution }
            return .quiet
        }
        return merge.isMerged ? .quiet : .caution
    }

    /// The warning above the checkbox, or `nil` when there is nothing to lose (or nothing known
    /// yet). Untracked files count: `git worktree remove` refuses on those too.
    var dirtyLine: String? {
        guard isDirty else { return nil }
        switch phase {
        case .ready, .deleting: break
        case .checking, .checkFailed: return nil
        }
        guard dirtyFileCount > 0 else { return "Uncommitted changes will be lost" }
        return "\(dirtyFileCount) uncommitted change\(dirtyFileCount == 1 ? "" : "s") will be lost"
    }

    var requiresDirtyAcknowledgement: Bool { isDirty }
    static let dirtyAcknowledgementTitle = "Discard them and delete anyway"
    var dirtyAcknowledgementTitle: String { Self.dirtyAcknowledgementTitle }

    // MARK: Buttons

    /// Whether the branch has commits the base does not — **including "we could not tell"**, which
    /// is treated as unmerged on purpose: that is the conservative direction, and it is where the
    /// red button earns its place.
    var hasUnmergedCommits: Bool {
        switch merge {
        case .prMerged, .mergedIntoBase: false
        // Nothing to delete on a detached HEAD, and the base branch is never offered either way,
        // so neither puts the sheet in the two-button shape.
        case .detached, .onBase: false
        case .unmerged, .unknown: true
        }
    }

    /// The primary button. It deletes the branch too whenever a plain `git branch -d` is expected
    /// to succeed, which is exactly when the branch is merged.
    var deleteButtonTitle: String { hasUnmergedCommits ? "Delete, keep branch" : "Delete" }
    var primaryDeletesBranch: Bool { !hasUnmergedCommits && branch != nil }

    /// The red one. Only where there is an unmerged branch to force — never on a detached HEAD,
    /// where there is no branch at all.
    var showsDeleteBranchButton: Bool { hasUnmergedCommits && branch != nil }
    static let deleteBranchButtonTitle = "Delete branch too"
    var deleteBranchButtonTitle: String { Self.deleteBranchButtonTitle }

    var canDelete: Bool {
        phase == .ready && !agentWorking && (!isDirty || acknowledgedDirty)
    }

    /// Why the buttons are off, for their tooltip; `nil` when they are on.
    var deleteHint: String? {
        switch phase {
        case .checking: return "Checking the worktree"
        case .deleting: return "Delete in progress"
        case .checkFailed: return "Could not check the worktree"
        case .ready:
            if agentWorking {
                return "Wait for \(agentDisplayName) to be idle \u{2014} it may be editing files"
            }
            if isDirty, !acknowledgedDirty {
                return "Confirm you want to discard the uncommitted changes"
            }
            return nil
        }
    }
}
