// DeleteMergedWorktreesSheetModel — Group › "Delete merged worktrees…" (TKZ-70).
//
// The per-row sheet's bulk twin: one row per worktree session in the group whose branch has
// landed, pre-checked, with the ones that cannot go listed but off. Same posture as every other
// sheet model here — every string is derived, so the list's rules are asserted without a window.
//
// Two rules the shape encodes:
//
//   * **A row that is not merged is not listed at all.** The sheet is "delete the merged ones";
//     an unmerged worktree is a trip to the row menu, where the red button lives.
//   * **This sheet never force-removes.** There is no per-row acknowledgement here, so a dirty
//     worktree is listed *unchecked* with its status line saying why, and deleting it is a
//     deliberate visit to the row's own sheet.

import Foundation
import GitStatus
import TkzCore

struct DeleteMergedWorktreesSheetModel: Equatable, Sendable {

    enum Phase: Equatable, Sendable {
        /// Surveying every worktree row in the group, one pass on the git queue.
        case checking
        case ready
        case deleting
    }

    struct Row: Equatable, Sendable, Identifiable {
        var id: SessionID
        /// `Session.displayTitle`.
        var title: String
        var worktreeName: String
        var branch: String?
        /// "PR #12 merged" / "Branch fully merged into main", plus " — uncommitted changes".
        var statusLine: String
        var isChecked: Bool
        var isEnabled: Bool
        /// The checkbox's tooltip when it is off.
        var disabledReason: String?
    }

    var groupName: String
    var rows: [Row] = []
    var phase: Phase = .checking

    var title: String { "Delete merged worktrees in \(groupName)" }

    var checkedCount: Int { rows.filter { $0.isChecked && $0.isEnabled }.count }

    var body: String {
        switch phase {
        case .checking: return "Checking the worktrees in \(groupName)\u{2026}"
        case .deleting: return "Deleting\u{2026}"
        case .ready:
            guard !rows.isEmpty else { return "No merged worktrees in \(groupName)" }
            let n = rows.count
            return "\(n) merged worktree\(n == 1 ? "" : "s"). Each row's session is closed, then its worktree and branch are removed."
        }
    }

    var deleteButtonTitle: String {
        let n = checkedCount
        guard n > 0 else { return "Delete" }
        return "Delete \(n) worktree\(n == 1 ? "" : "s")"
    }

    var canDelete: Bool { phase == .ready && checkedCount > 0 }

    var deleteHint: String? {
        switch phase {
        case .checking: return "Checking the worktrees"
        case .deleting: return "Delete in progress"
        case .ready: return checkedCount > 0 ? nil : "Nothing selected"
        }
    }

    /// The status line for one surveyed row, or `nil` when the row does not belong in the list.
    ///
    /// `nil` is the "not merged" case, and it is the only filter: a dirty or busy row *is* listed
    /// (it is merged, after all), just not checked — hiding it would leave the user wondering
    /// where it went.
    static func statusLine(for merge: WorktreeRemoval.MergeState, isDirty: Bool) -> String? {
        let base: String
        switch merge {
        case .prMerged(let number?): base = "PR #\(number) merged"
        case .prMerged(nil): base = "Its pull request is merged"
        case .mergedIntoBase(let ref): base = "Branch fully merged into \(StatusBarView.baseLabel(ref))"
        case .unmerged, .onBase, .detached, .unknown: return nil
        }
        return isDirty ? base + " \u{2014} uncommitted changes" : base
    }
}
