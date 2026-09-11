// TkzCore — the sample state. `AppState.fixture` is what the sidebar (M2.3 / TKZ-19), the status
// bar and the palette render before any real session exists, and what their tests measure against.
//
// It is deliberately *representative* rather than pretty: 40 sessions over the design's five
// groups, every `SessionStatus` present, worktrees with `WT` badges, both account keys, a couple of
// titles long enough to force truncation, and one group collapsed. Everything is deterministic —
// fixed UUIDs and a fixed clock — so screenshots and perf runs are comparable between runs.

import Foundation

extension AppState {
    /// The reference state used by previews, the sidebar tests and the perf harness.
    public static var fixture: AppState { Fixture.make() }
}

/// Builder for `AppState.fixture`. Public so that TkzApp's dev window and the perf harness can
/// build variants (`Fixture.make(sessionCount:)`) without duplicating the data.
public enum Fixture {
    /// Deterministic id from a counter: `00000000-0000-4000-8000-0000000000NN`.
    public static func groupID(_ n: Int) -> GroupID { GroupID(uuid: uuid(1000 + n)) }
    public static func sessionID(_ n: Int) -> SessionID { SessionID(uuid: uuid(n)) }

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    /// 2026-09-09 09:00:00 UTC — the fixture's "now".
    public static let now = Date(timeIntervalSince1970: 1_788_944_400)

    /// The two account keys: the basenames of `~/.claude` and `~/.claude-work`. Labels here are
    /// generic on purpose — real ones come from the account's own identity at runtime.
    public static let accountKeys = ["claude", "claude-work"]

    private struct Spec {
        var group: Int
        var title: String?
        var branch: String
        var worktree: String?
        var account: String
        var status: SessionStatus
        /// A row with no live state — what a `state.json` row looks like before its first show.
        var restored: Bool = false
        var attention: Bool = false
        var ports: [UInt16] = []
        var changed: Int = 0
        var insertions: Int = 0
        var deletions: Int = 0
        var context: Double?
    }

    private static let groupSpecs: [(name: String, repo: String?, color: RGB?, collapsed: Bool, account: String)] = [
        ("Northwind Trading", "~/dev/northwind", RGB(hex: 0x8b93f8), false, "claude-work"),
        ("Acme Ledger", "~/dev/acme-ledger", RGB(hex: 0x41c6a8), false, "claude-work"),
        ("Scheduled", nil, RGB(hex: 0xfbbf54), false, "claude"),
        ("Toolbox", "~/dev/toolbox", RGB(hex: 0xc084fc), false, "claude"),
        ("Playground", "~/dev/playground", RGB(hex: 0xf28b8b), true, "claude"),
    ]

    private static let specs: [Spec] = [
        // Northwind Trading — the busy group, and the one the selection lands in.
        .init(group: 0, title: nil, branch: "main", worktree: nil, account: "claude-work",
              status: .working, ports: [5173], changed: 7, insertions: 142, deletions: 38, context: 62),
        .init(group: 0, title: "deal pipeline: replace the valuation service with the new pricing engine",
              branch: "feat/pricing-engine", worktree: "pricing-engine", account: "claude-work",
              status: .waiting(.doneUnattended), attention: true, changed: 12, insertions: 486,
              deletions: 121, context: 74),
        .init(group: 0, title: "permission prompt", branch: "fix/csv-import", worktree: "csv-import",
              account: "claude-work", status: .waiting(.permission), attention: true, changed: 3,
              insertions: 61, deletions: 12, context: 41),
        .init(group: 0, title: nil, branch: "feat/reporting", worktree: "reporting",
              account: "claude-work", status: .idle, changed: 1, insertions: 9, deletions: 2),
        .init(group: 0, title: "flaky integration tests", branch: "main", worktree: nil,
              account: "claude-work", status: .idle, restored: true),
        .init(group: 0, title: nil, branch: "chore/deps", worktree: "deps", account: "claude",
              status: .working, ports: [3000, 9229], changed: 2, insertions: 18, deletions: 340),
        .init(group: 0, title: "elicitation", branch: "feat/audit-log", worktree: "audit-log",
              account: "claude-work", status: .waiting(.elicitation), attention: true),
        .init(group: 0, title: nil, branch: "main", worktree: nil, account: "claude-work", status: .idle),
        .init(group: 0, title: "agent needs input", branch: "spike/graphql", worktree: "graphql",
              account: "claude", status: .waiting(.agentInput), attention: true),
        .init(group: 0, title: nil, branch: "fix/rounding", worktree: nil, account: "claude-work",
              status: .working, changed: 4, insertions: 33, deletions: 7, context: 28),
        .init(group: 0, title: nil, branch: "main", worktree: nil, account: "claude-work", status: .idle, restored: true),
        .init(group: 0, title: "release 4.2", branch: "release/4.2", worktree: "release-4-2",
              account: "claude-work", status: .idle, changed: 22, insertions: 901, deletions: 455),

        // Acme Ledger — Azure DevOps origin, so never a PR badge.
        .init(group: 1, title: nil, branch: "develop", worktree: nil, account: "claude-work",
              status: .working, ports: [5000], changed: 9, insertions: 210, deletions: 64, context: 55),
        .init(group: 1, title: "migrate the reporting module off the legacy scheduler and onto hangfire",
              branch: "feat/hangfire", worktree: "hangfire", account: "claude-work",
              status: .waiting(.doneUnattended), attention: true, changed: 15, insertions: 640, deletions: 288),
        .init(group: 1, title: nil, branch: "develop", worktree: nil, account: "claude-work", status: .idle),
        .init(group: 1, title: nil, branch: "fix/nullref", worktree: "nullref", account: "claude-work",
              status: .working, changed: 1, insertions: 4, deletions: 1),
        .init(group: 1, title: "db migration", branch: "feat/migrations", worktree: "migrations",
              account: "claude-work", status: .idle, changed: 6, insertions: 120, deletions: 30),
        .init(group: 1, title: nil, branch: "develop", worktree: nil, account: "claude", status: .idle, restored: true),
        .init(group: 1, title: nil, branch: "spike/perf", worktree: "perf", account: "claude-work",
              status: .working, ports: [5001, 5432], changed: 3, insertions: 77, deletions: 12, context: 88),
        .init(group: 1, title: "permission: write outside repo", branch: "develop", worktree: nil,
              account: "claude-work", status: .waiting(.permission), attention: true),
        .init(group: 1, title: nil, branch: "chore/ci", worktree: "ci", account: "claude-work", status: .idle),
        .init(group: 1, title: nil, branch: "develop", worktree: nil, account: "claude-work", status: .idle, restored: true),

        // Scheduled — a bucket with no repo; short-lived jobs.
        .init(group: 2, title: "nightly dependency audit", branch: "main", worktree: nil,
              account: "claude", status: .working),
        .init(group: 2, title: "weekly changelog", branch: "main", worktree: nil, account: "claude",
              status: .idle),
        .init(group: 2, title: "inbox triage", branch: "main", worktree: nil, account: "claude",
              status: .waiting(.doneUnattended), attention: true),
        .init(group: 2, title: "docs sweep", branch: "main", worktree: nil, account: "claude", status: .idle, restored: true),
        .init(group: 2, title: "link checker", branch: "main", worktree: nil, account: "claude", status: .idle),
        .init(group: 2, title: "release notes draft", branch: "main", worktree: nil, account: "claude-work",
              status: .idle, restored: true),

        // Toolbox
        .init(group: 3, title: nil, branch: "main", worktree: nil, account: "claude", status: .working,
              ports: [8080], changed: 5, insertions: 88, deletions: 19, context: 34),
        .init(group: 3, title: "onboarding flow", branch: "feat/onboarding", worktree: "onboarding",
              account: "claude", status: .idle, changed: 8, insertions: 260, deletions: 74),
        .init(group: 3, title: nil, branch: "fix/webhooks", worktree: "webhooks", account: "claude",
              status: .waiting(.doneUnattended), attention: true, changed: 2, insertions: 24, deletions: 6),
        .init(group: 3, title: nil, branch: "main", worktree: nil, account: "claude", status: .idle, restored: true),
        .init(group: 3, title: "prompt tuning for the classifier that keeps mislabelling refunds",
              branch: "spike/classifier", worktree: "classifier", account: "claude", status: .working,
              context: 91),
        .init(group: 3, title: nil, branch: "main", worktree: nil, account: "claude-work", status: .idle),
        .init(group: 3, title: nil, branch: "chore/lint", worktree: nil, account: "claude", status: .idle),

        // Playground — collapsed group.
        .init(group: 4, title: nil, branch: "main", worktree: nil, account: "claude", status: .idle),
        .init(group: 4, title: "scheduling bug", branch: "fix/shifts", worktree: "shifts",
              account: "claude", status: .working, changed: 3, insertions: 41, deletions: 11),
        .init(group: 4, title: nil, branch: "main", worktree: nil, account: "claude", status: .idle, restored: true),
        .init(group: 4, title: nil, branch: "feat/payroll", worktree: "payroll", account: "claude-work",
              status: .waiting(.agentInput), attention: true),
        .init(group: 4, title: nil, branch: "main", worktree: nil, account: "claude", status: .idle),
    ]

    /// Builds the fixture. `sessionCount` truncates (or, by repeating the spec table, extends) the
    /// session list — the perf harness uses it to sweep row counts.
    public static func make(sessionCount: Int? = nil) -> AppState {
        var state = AppState()
        state.sidebarVisible = true

        for (index, spec) in groupSpecs.enumerated() {
            var group = Group(
                id: groupID(index),
                name: spec.name,
                repoRoot: spec.repo,
                color: spec.color,
                isCollapsed: spec.collapsed,
                order: index,
                defaultAccountKey: spec.account
            )
            group.isCollapsed = spec.collapsed
            state.groups[group.id] = group
        }

        for key in accountKeys {
            state.accounts[key] = Account(
                key: key,
                configDir: key == "claude" ? "~/.claude" : "~/.\(key)",
                label: key == "claude" ? "Claude" : "Claude (alt)",
                plan: key == "claude" ? "Max 20x" : "Team 5x"
            )
        }
        state.usage["claude"] = UsageSnapshot(
            accountKey: "claude",
            updatedAt: now,
            label: "Claude",
            plan: "Max 20x",
            fiveHour: UsageWindow(usedPercentage: 5, resetsAt: now.addingTimeInterval(2 * 3600)),
            sevenDay: UsageWindow(usedPercentage: 18, resetsAt: now.addingTimeInterval(4 * 86_400 + 12 * 3600))
        )
        state.usage["claude-work"] = UsageSnapshot(
            accountKey: "claude-work",
            updatedAt: now,
            label: "Claude (alt)",
            plan: "Team 5x",
            fiveHour: UsageWindow(usedPercentage: 1, resetsAt: now.addingTimeInterval(53 * 60)),
            sevenDay: UsageWindow(usedPercentage: 39, resetsAt: now.addingTimeInterval(2 * 86_400 + 4 * 3600))
        )

        let count = sessionCount ?? specs.count
        for n in 0..<count {
            let spec = specs[n % specs.count]
            let session = makeSession(spec, index: n)
            state.sessions[session.id] = session
        }
        for group in state.orderedGroups { state.normalizeSessionOrder(in: group.id) }

        state.shortcuts = [
            // Not "cmd+t": that is `newTerminal` since TKZ-36, and a fixture collision would
            // silently shadow it under TKZMUX_FIXTURE without any test noticing.
            "newSession": "ctrl+cmd+n",
            "closeTerminal": "cmd+w",
            "nextSession": "ctrl+cmd+down",
            "previousSession": "ctrl+cmd+up",
            "searchSessions": "cmd+p",
            "commandPalette": "shift+cmd+p",
            "toggleSidebar": "ctrl+cmd+s",
        ]
        state.selection = sessionID(0)
        return state
    }

    private static func makeSession(_ spec: Spec, index n: Int) -> Session {
        let groupSpec = groupSpecs[spec.group]
        let repoRoot = groupSpec.repo
        let worktreePath = spec.worktree.flatMap { name in
            repoRoot.map { "\($0)/.claude/worktrees/\(name)" }
        }
        let cwd = worktreePath ?? repoRoot ?? "~"
        let created = now.addingTimeInterval(-Double(n) * 900 - 3600)

        var session = Session(
            id: sessionID(n),
            groupID: groupID(spec.group),
            order: n,
            title: spec.title,
            cwd: cwd,
            repoRoot: repoRoot,
            worktreePath: worktreePath,
            isWorktree: worktreePath != nil,
            accountKey: spec.account,
            claudeSessionId: String(format: "11111111-2222-4333-8444-%012d", n),
            createdAt: created,
            lastActiveAt: now.addingTimeInterval(-Double(n) * 60)
        )

        guard !spec.restored else { return session }  // restored rows carry no live state

        var live = LiveSessionState(
            pid: pid_t(40_000 + n),
            shellPid: pid_t(39_000 + n),
            status: spec.status,
            attention: spec.attention,
            ports: spec.ports
        )
        live.descriptor = ClaudeSessionInfo(
            configDir: spec.account == "claude" ? "~/.claude" : "~/.\(spec.account)",
            pid: pid_t(40_000 + n),
            sessionId: session.claudeSessionId ?? "",
            cwd: cwd,
            startedAt: created,
            version: "2.1.263",
            kind: .interactive,
            entrypoint: "cli",
            name: spec.title,
            nameSource: spec.title == nil ? .auto : .derived,
            status: spec.status == .working ? .busy : .idle,
            updatedAt: now,
            statusUpdatedAt: now
        )
        live.git = GitSummary(
            branch: spec.branch,
            upstream: "origin/\(spec.branch)",
            ahead: spec.status == .working ? 1 : 0,
            behind: n % 5 == 0 ? 2 : 0,
            changedFiles: spec.changed,
            untrackedFiles: spec.changed > 4 ? 2 : 0,
            insertions: spec.insertions,
            deletions: spec.deletions,
            isWorktree: worktreePath != nil,
            pr: spec.worktree != nil && spec.group == 0
                ? PRInfo(
                    number: 400 + n, url: "https://github.com/example/repo/pull/\(400 + n)",
                    state: "OPEN", isDraft: n % 3 == 0, reviewDecision: "REVIEW_REQUIRED")
                : nil,
            updatedAt: now
        )
        if spec.status == .waiting(.doneUnattended) {
            live.lastStopMessage = "Done — the failing test now passes; want me to open a PR?"
            live.lastStopAt = now.addingTimeInterval(-420)
            live.lastHook = HookEvent(
                kind: .stop, sessionID: session.id, claudeSessionId: session.claudeSessionId,
                lastAssistantMessage: live.lastStopMessage, pid: live.pid,
                receivedAt: now.addingTimeInterval(-420))
        }
        if let context = spec.context {
            live.context = SessionSidecar(
                updatedAt: now,
                sessionId: session.claudeSessionId ?? "",
                accountKey: spec.account,
                contextUsedPercentage: context,
                model: SessionSidecar.Model(id: "claude-opus-5", displayName: "Opus 5"),
                sessionName: spec.title,
                workspace: SessionSidecar.Workspace(
                    gitWorktree: spec.worktree, projectDir: cwd, repo: groupSpec.name),
                worktree: spec.worktree,
                pr: nil,
                cost: 1.25
            )
        }
        session.live = live
        return session
    }
}
