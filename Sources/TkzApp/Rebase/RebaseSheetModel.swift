// RebaseSheetModel — what the rebase sheet shows (design 5a/5b, 2026-09-13).
//
// The simplified sheet: a title (`Rebase onto main`), the chord, one body line (`Pulls in
// 7 commits`), Cancel and Rebase. Everything the view draws is derived here, as strings, so the
// sheet's four phases are asserted in a test rather than looked at.

import Foundation
import TkzCore

struct RebaseSheetModel: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Opened; `git fetch` of the base is running so the count is honest.
        case fetching
        /// The count is in. `behind` may still be `nil` when `rev-list` failed.
        case ready
        /// The fetch failed; the rebase would too, so the button stays off.
        case fetchFailed(String)
        /// Rebase pressed; the runner is at work. The sheet closes when it finishes.
        case rebasing
    }

    /// `origin/main` — the ref, for the body and the tooltip. The title shows its last segment.
    var baseRef: String
    /// Commits on the base that the branch lacks, after the fetch.
    var behind: Int?
    /// `⌥⌘R`, already formatted, or `nil` when the chord is unbound.
    var shortcut: String?
    var phase: Phase = .fetching
    /// The row's agent is mid-turn and may be editing files under the rebase: the button is off
    /// until it is idle (decision 2026-09-13, in place of the artboard's "session pauses" line).
    var agentWorking = false
    /// What the tooltip calls the row's agent — `AgentAdapter.displayName`. Defaults to a name
    /// that admits it does not know rather than asserting a product name nobody told this model.
    var agentDisplayName = "the agent"

    var baseLabel: String { StatusBarView.baseLabel(baseRef) }
    var title: String { "Rebase onto \(baseLabel)" }

    /// The body line as two runs: a dim lead and, when there is a number, a brighter count.
    var body: (lead: String, emphasis: String?) {
        switch phase {
        case .fetching:
            return ("Fetching \(baseRef)\u{2026}", nil)
        case .rebasing:
            return ("Rebasing onto \(baseRef)\u{2026}", nil)
        case .fetchFailed(let message):
            return ("Fetch failed: \(message)", nil)
        case .ready:
            guard let behind else { return ("Could not count the commits on \(baseRef)", nil) }
            guard behind > 0 else { return ("Already up to date with \(baseRef)", nil) }
            return ("Pulls in ", "\(behind) \(behind == 1 ? "commit" : "commits")")
        }
    }

    /// The Rebase button.
    var canRebase: Bool {
        phase == .ready && (behind ?? 0) > 0 && !agentWorking
    }

    /// Why the button is off, for its tooltip; `nil` when it is on.
    var rebaseHint: String? {
        switch phase {
        case .fetching: return "Waiting for the fetch"
        case .rebasing: return "Rebase in progress"
        case .fetchFailed: return "Fix the fetch first"
        case .ready:
            if agentWorking { return "Wait for \(agentDisplayName) to be idle \u{2014} it may be editing files" }
            guard let behind else { return "Could not count the commits on \(baseRef)" }
            if behind == 0 { return "Nothing to rebase" }
            return nil
        }
    }
}
