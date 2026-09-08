// StatusBarModel.swift — the value type behind the 30 pt status strip.
//
// design.md → App architecture → Status bar:
//   `⎇ branch` · `WT` · model badge · `+142 −38 · 12 files` · `↑0 ↓2` · ports · `Context 62%` ·
//   `Usage 5% · resets 4d 12h`
//
// Every field is optional on purpose. The strip is fed by five independent services
// (`GitStatusService`, `PortScanner`, the session sidecar, `UsageReader`, the descriptor watcher)
// that report at different times and may never report at all for a given session. A `nil` field
// means "not known yet" and its segment — including the ` · ` before it — is simply not drawn;
// it never renders as `0`, `—` or an empty gap.
//
// The model carries *already-derived* values only: no dates, no rates, no formatting decisions
// that depend on the current time, so a given model always renders to the same pixels. Wave M4.2
// fills it from the real services; this wave renders it.

import Foundation

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

    /// Percentage of the model's context window used, 0…100, already rounded.
    /// Rendered `Context 62%`.
    public var contextPercent: Int?

    /// Percentage of the account's rolling seven-day quota used, 0…100, already rounded.
    /// Rendered `Usage 5%`.
    public var usagePercent: Int?

    /// Time until the quota window resets, rendered `resets 4d 12h` by
    /// ``StatusBarModel/formatResetsIn(_:)``. Its own segment: `Usage 5%` can appear without it.
    public var usageResetsIn: Duration?

    public init(
        branch: String? = nil,
        isWorktree: Bool? = nil,
        modelName: String? = nil,
        diffAdded: Int? = nil,
        diffRemoved: Int? = nil,
        diffFiles: Int? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        ports: [UInt16]? = nil,
        contextPercent: Int? = nil,
        usagePercent: Int? = nil,
        usageResetsIn: Duration? = nil
    ) {
        self.branch = branch
        self.isWorktree = isWorktree
        self.modelName = modelName
        self.diffAdded = diffAdded
        self.diffRemoved = diffRemoved
        self.diffFiles = diffFiles
        self.ahead = ahead
        self.behind = behind
        self.ports = ports
        self.contextPercent = contextPercent
        self.usagePercent = usagePercent
        self.usageResetsIn = usageResetsIn
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
