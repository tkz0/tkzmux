// StatusBarModel.swift — the value type behind the 36 pt status strip.
//
// design.md → App architecture → Status bar:
//   `⎇ branch` · `WT` · `FABLE 5.1` · `+142 −38 · 12 files` · `↑0 ↓2` · ports · `Context 62%` ·
//   `Usage 5% · 41%` (2c.1: the usage meter is two stacked bars — session quota over weekly —
//   and the reset countdown moved from its own segment into the meter's tooltip)
//
// Every field is optional on purpose. The strip is fed by five independent services
// (`GitStatusService`, `PortScanner`, the session sidecar, `UsageReader`, the descriptor watcher)
// that report at different times and may never report at all for a given session. A `nil` field
// means "not known yet" and its segment — including the ` · ` before it — is simply not drawn;
// it never renders as `0`, `—` or an empty gap.
//
// The model carries *already-derived* values only: no dates, no rates, no formatting decisions
// that depend on the current time, so a given model always renders to the same pixels. M4.2
// (TKZ-27) fills it from the real services — `GitStatusService`, `PortScanner`, `PRLookup` — and
// adds the interactive half: every field that can carry a tooltip carries the *text*, not a date
// or a rule, for the same reason.

import Foundation
import TkzCore

/// Everything the status bar shows for the selected session.
///
/// Construct with `StatusBarModel()` for the empty strip and fill in what is known.
public struct StatusBarModel: Hashable, Sendable {
    /// Current git branch of the session's working directory, without a `refs/heads/` prefix.
    /// Rendered as `⎇ <branch>`. `nil` until `GitStatusService` has reported (or not a repo).
    public var branch: String?

    /// `true` when the session's cwd is a git *worktree* rather than the repo root.
    /// Renders the `WT` pill (`wtText` on `wtBackground`). `nil` = unknown, `false` = repo root:
    /// both draw nothing.
    public var isWorktree: Bool?

    /// Display name of the Claude model in use, e.g. `"Sonnet 4.5"` — the sidecar's
    /// `model.display_name`, never the model id. Rendered as a subdued badge.
    public var modelName: String?

    /// Lines added in the working tree vs. HEAD. Rendered `+142` in `diffAdd`.
    public var diffAdded: Int?

    /// Lines removed in the working tree vs. HEAD. Rendered `−142` (U+2212) in `diffRemove`.
    public var diffRemoved: Int?

    /// Number of changed files. Rendered as its own `12 files` segment so it collapses
    /// independently of the line counts.
    public var diffFiles: Int?

    /// Commits ahead of the upstream branch. Rendered `↑2`. `nil` when there is no upstream.
    public var ahead: Int?

    /// Commits behind the upstream branch. Rendered `↓2`. `nil` when there is no upstream.
    public var behind: Int?

    /// Localhost TCP ports opened by the session's process tree, rendered `:3000 :5173`.
    /// An empty array draws nothing, exactly like `nil`.
    public var ports: [UInt16]?

    /// Owning process name per port (`PortScanner` reads `proc_name`), for the badge tooltip.
    /// A port with no entry still renders; only its tooltip is shorter.
    public var portOwners: [UInt16: String]

    /// The pull request for the current branch, from the session sidecar or `gh pr view`.
    /// Renders the clickable `#123 ✓ / ● / draft` pill.
    public var pullRequest: PRInfo?

    /// The upstream ref (`origin/develop`), for the branch tooltip. `nil` with
    /// ``upstreamMissing`` `== false` only means "not known yet".
    public var upstream: String?

    /// The branch is known to have **no** upstream. Renders `\u{2191}\u{2013} \u{2193}\u{2013}`
    /// dimmed with a "no upstream" tooltip, which is different from drawing nothing (that would
    /// read as "not measured yet") and different from `\u{2191}0 \u{2193}0` (that would read as
    /// "in sync with a remote", which there isn't one of).
    public var upstreamMissing: Bool

    /// The worktree's directory name, for the `WT` pill's tooltip.
    public var worktreeName: String?

    /// Percentage of the model's context window used, 0…100, already rounded.
    /// Rendered `Context 62%`.
    public var contextPercent: Int?

    /// The current session (five-hour) quota window — the **top** bar of the stacked `Usage`
    /// meter in 2c.1. `nil` draws no bar; if only one of the two windows is known the meter
    /// falls back to a single bar, so a half-reported account never draws an empty track.
    public var sessionUsage: UsageQuota?

    /// The rolling seven-day quota window — the **bottom** bar of the stacked meter, drawn at
    /// half the fill's alpha while it is in the normal band (2c.1 dims it so the two bars read
    /// as primary/secondary rather than as two equal claims).
    public var weeklyUsage: UsageQuota?

    /// The usage badge's tooltip — the two windows with their resets, then every account's
    /// seven-day window one per line, because the quota the number describes belongs to one
    /// account and the user runs more than one.
    public var usageTooltip: String?

    /// A transient message that replaces the whole strip: "Restored sidebar from backup" after a
    /// `state.json` recovery (M5.1). Deliberately *not* part of `AppState` — it describes something
    /// that happened once at launch, not something the app persists, and `statusModel(for:)` stays
    /// a pure function of persisted state.
    public var notice: String?

    /// One quota window as the strip needs it: a percentage, and time/instant of its reset.
    ///
    /// The reset is *derived text and a duration*, never a `Date`, for the same reason the rest
    /// of the model is: a given model has to render to the same pixels whenever it is drawn.
    public struct UsageQuota: Hashable, Sendable {
        /// 0…100, already rounded. The bar clamps; the number is what is reported.
        public var percent: Int
        /// Time until the window resets, rendered `resets 4d 12h` by
        /// ``StatusBarModel/formatResetsIn(_:)`` into the meter's tooltip.
        public var resetsIn: Duration?
        /// The exact reset instant as already-formatted text (`2026-09-12 08:00`), for the
        /// tooltip. Formatted by the caller, not here — a model that formats a `Date` would
        /// render differently in a different locale.
        public var resetsAtText: String?

        public init(percent: Int, resetsIn: Duration? = nil, resetsAtText: String? = nil) {
            self.percent = percent
            self.resetsIn = resetsIn
            self.resetsAtText = resetsAtText
        }
    }

    public init(
        notice: String? = nil,
        branch: String? = nil,
        isWorktree: Bool? = nil,
        worktreeName: String? = nil,
        modelName: String? = nil,
        diffAdded: Int? = nil,
        diffRemoved: Int? = nil,
        diffFiles: Int? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        upstream: String? = nil,
        upstreamMissing: Bool = false,
        pullRequest: PRInfo? = nil,
        ports: [UInt16]? = nil,
        portOwners: [UInt16: String] = [:],
        contextPercent: Int? = nil,
        sessionUsage: UsageQuota? = nil,
        weeklyUsage: UsageQuota? = nil,
        usageTooltip: String? = nil
    ) {
        self.notice = notice
        self.branch = branch
        self.isWorktree = isWorktree
        self.worktreeName = worktreeName
        self.modelName = modelName
        self.diffAdded = diffAdded
        self.diffRemoved = diffRemoved
        self.diffFiles = diffFiles
        self.ahead = ahead
        self.behind = behind
        self.upstream = upstream
        self.upstreamMissing = upstreamMissing
        self.pullRequest = pullRequest
        self.ports = ports
        self.portOwners = portOwners
        self.contextPercent = contextPercent
        self.sessionUsage = sessionUsage
        self.weeklyUsage = weeklyUsage
        self.usageTooltip = usageTooltip
    }

    /// The empty strip — every service silent. Renders as bare background, no separators.
    public static let empty = StatusBarModel()
}

extension StatusBarModel {
    /// `4d 12h` / `12h 30m` / `45m` / `30s`. Deliberately hand-rolled and locale-independent:
    /// the design's string is fixed ASCII and must be byte-stable across machines and tests.
    /// Negative durations (a reset already in the past) clamp to `0s`.
    public static func formatResetsIn(_ duration: Duration) -> String {
        let total = max(0, duration.components.seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }
}
