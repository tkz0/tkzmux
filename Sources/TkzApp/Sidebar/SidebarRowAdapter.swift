// SidebarRowAdapter — the one place that knows both vocabularies (M2.3 / TKZ-19).
//
// `Sidebar/SidebarRowModels.swift` deliberately contains no `TkzCore` model types, so the row views
// can be built and tested against literals. This file is the bridge: `Session`/`Group`/`AppState`
// in, `SidebarSessionRowModel`/`SidebarGroupRowModel`/`SidebarSummaryModel` out. Everything here is
// a pure `static` function over value types — no view, no store, no clock — which is what makes the
// keyboard-selection commands (⌘1–⌘9, ⇧⌘U, ↑/↓) testable without an `NSOutlineView`.
//
// Mapping rules (fixed by the row-view agent's contract, asserted by `SidebarViewControllerTests`):
//
//   * `SidebarStatus` collapses all three `waiting` reasons to `.waiting` — the dot does not
//     distinguish them.
//   * `needsAttention` is `Session.needsAttention` (i.e. `LiveSessionState.attention`), **not**
//     `status == .waiting(.doneUnattended)`. The flag and the dot have independent lifetimes, and
//     `AppState.summaryCounts.needsYou` counts the same flag — deriving it from the status would
//     make the badges and the summary strip disagree with `TkzCore`.
//   * `title` is `Session.displayTitle` (the resolved chain lives in `TkzCore`).
//   * `branch` is the bare name from `GitSummary`; the *view* adds the `⎇`.
//   * `SidebarGroupRowModel.name` keeps its original casing; the view uppercases.
//   * `color: nil` stays `nil` — a group with no colour gets a transparent edge, deliberately not
//     `Theme.groupEdgeDefault` (that token is the colour picker's default, not a fallback).
//   * `SidebarSessionRowModel.groupColor` is the one field on a *session* row that comes from the
//     group rather than the session (TKZ-48), so the colour edge runs down the whole group. It is
//     also the only reason `sessionModel` reads `state.groups`; `SidebarViewController.applyGroups`
//     has to reload a group's session rows when its colour changes because of it.

import Foundation
import TkzCore

public enum SidebarRowAdapter {

    // MARK: - Status

    /// `TkzCore.SessionStatus` → the dot's vocabulary.
    public static func status(_ status: SessionStatus) -> SidebarStatus {
        switch status {
        case .working: .working
        case .waiting: .waiting
        case .idle: .idle
        }
    }

    /// The same, plus the "done" tint: `idle` with `LiveSessionState.isDone` (a Stop newer than
    /// `attendedAt`, younger than the 60 s grace) draws as `.done`.
    public static func status(of session: Session) -> SidebarStatus {
        if session.status == .idle, session.live?.isDone == true { return .done }
        return status(session.status)
    }

    // MARK: - Rows

    /// The model for one 44 pt session row.
    public static func sessionModel(_ session: Session, in state: AppState) -> SidebarSessionRowModel {
        SidebarSessionRowModel(
            title: session.displayTitle,
            branch: session.live?.git?.branch,
            isWorktree: session.showsWorktreeBadge,
            status: status(of: session),
            accountLabel: accountLabel(for: session, in: state),
            accountTooltip: accountTooltip(for: session, in: state),
            accountColor: SidebarSessionRowModel.accountChipColor(forKey: session.accountKey),
            needsAttention: session.needsAttention,
            isSelected: state.selection == session.id,
            groupColor: state.groups[session.groupID]?.color,
            memoryBadge: memoryBadge(for: session)
        )
    }

    /// Above this, a session's process subtree gets a badge on its row.
    ///
    /// 4 GB. Calibrated against what "busy but fine" actually measures: a working set of Claude
    /// Code sessions runs 250–400 MB each, so a whole sidebar of them is under 2 GB (docs/perf.md →
    /// *Session process memory*). A single session past 4 GB is a build or test that has got away,
    /// which is the case worth interrupting someone for — and the only case, since a badge on every
    /// row would be ignored.
    public static let memoryBadgeThreshold: UInt64 = 4 * 1024 * 1024 * 1024

    static func memoryBadge(for session: Session) -> String? {
        guard let bytes = session.live?.subtreeFootprintBytes,
              bytes >= memoryBadgeThreshold else { return nil }
        return formatBytes(bytes)
    }

    /// One decimal in GB — "4.7 GB". Only ever called above the GB-scale threshold.
    static func formatBytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    /// The model for one 28 pt group header.
    ///
    /// `isCollapsed` comes from the **store**, not from `NSOutlineView.isItemExpanded`: the store is
    /// the source of truth (collapse is persisted) and the outline view is kept in sync with it.
    public static func groupModel(_ group: Group, in state: AppState) -> SidebarGroupRowModel {
        SidebarGroupRowModel(
            name: group.name,
            color: group.color,
            isCollapsed: group.isCollapsed,
            sessionCount: state.sessions.values.reduce(into: 0) { count, session in
                if session.groupID == group.id { count += 1 }
            }
        )
    }

    /// "N working · N need you". `needAttention` counts `NEEDS YOU` **badges**, not `.waiting` dots
    /// — which is exactly what `AppState.summaryCounts` already computes.
    public static func summaryModel(for state: AppState) -> SidebarSummaryModel {
        let counts = state.summaryCounts
        return SidebarSummaryModel(working: counts.working, needAttention: counts.needsYou)
    }

    // MARK: - Account chip

    /// Short label for the account chip, or `nil` to hide the chip entirely.
    ///
    /// **The default account (`~/.claude`) never shows a chip** (decision 2026-09-08): almost
    /// nobody runs more than one Claude plan, and for the one plan everybody has the chip says
    /// nothing. A chip appears only on a row that runs on some *other* config dir, and reads as
    /// "this one is different". The text is derived from the account's *configured* `label` when it
    /// has one, else from its key — never hardcoded, see CLAUDE.md. See ``shortLabel(_:)`` for the
    /// rule.
    public static func accountLabel(for session: Session, in state: AppState) -> String? {
        guard session.accountKey != Account.defaultKey else { return nil }
        let source = state.accounts[session.accountKey]?.label ?? session.accountKey
        return shortLabel(source) ?? shortLabel(session.accountKey)
    }

    /// The chip's tooltip: the account as a human would name it, and the config dir it stands for.
    ///
    /// The chip has room for five characters, so the full name lives here — an account the state
    /// has never heard of has nothing but its key to offer.
    public static func accountTooltip(for session: Session, in state: AppState) -> String? {
        guard session.accountKey != Account.defaultKey else { return nil }
        guard let account = state.accounts[session.accountKey] else { return session.accountKey }
        let name = account.label == account.key ? account.key : "\(account.label) (\(account.key))"
        return "\(name) \u{2014} \(account.configDir)"
    }

    /// **Drop a leading `claude`, then take the first word**, uppercased and cut to
    /// ``chipMaxLength``.
    ///
    /// Every account tkzmux discovers is `~/.claude` or `~/.claude-*`
    /// (`ClaudeIntegration.discoverAccounts`), and a configured name usually leads with the product
    /// too, so that first word carries no information: dropping it is what turns `CA` into `ALT`,
    /// `CW` into `WORK`, and "Claude (work)" into `WORK`.
    ///
    /// What is left is *truncated*, not reduced to initials. The identifying part of a real name is
    /// its first word — "Ada Industries" reads far better as `ADA` than as `AI` — and initials were
    /// the whole reason every chip used to start with `C`. The cost is that two accounts whose
    /// names differ only after the first word share a chip; they still differ in tint
    /// (`accountChipColor(forKey:)`) and in the tooltip, which is what the tooltip is for.
    static let chipMaxLength = 5

    static func shortLabel(_ source: String) -> String? {
        var words = source
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        if words.count > 1, words[0].lowercased() == Account.defaultKey { words.removeFirst() }
        guard let first = words.first else { return nil }
        return String(first.prefix(chipMaxLength)).uppercased()
    }

    // MARK: - Visible rows & the keyboard commands
    //
    // "Visible" means *the outline view's rows*: a collapsed group's sessions are not rows, so they
    // are not reachable by ⌘1–⌘9 or by ↑/↓. ⇧⌘U is the deliberate exception — see below.

    /// Every session that is currently a row, top to bottom.
    public static func visibleSessions(in state: AppState) -> [Session] {
        state.orderedGroups
            .filter { !$0.isCollapsed }
            .flatMap { state.sessions(in: $0.id) }
    }

    /// ⌘1–⌘9: the n-th visible session, **1-based**. `nil` when there are fewer than `n` rows.
    public static func session(atVisibleIndex n: Int, in state: AppState) -> SessionID? {
        let visible = visibleSessions(in: state)
        guard n >= 1, n <= visible.count else { return nil }
        return visible[n - 1].id
    }

    /// ⇧⌘U: the first session showing a `NEEDS YOU` badge, in sidebar order.
    ///
    /// This one scans **every** session, including those inside a collapsed group — a session that
    /// needs you is exactly the thing a collapsed group must not be able to hide. The controller
    /// expands the containing group in the same store mutation that moves the selection.
    public static func firstSessionNeedingAttention(in state: AppState) -> SessionID? {
        state.orderedSessions.first(where: \.needsAttention)?.id
    }

    /// ↑/↓ over the visible rows, **clamped** at both ends.
    ///
    /// Deliberately different from `AppState.selectAdjacentSession(offset:)`, which wraps and walks
    /// every session: that is the ⌥⌘↑/⌥⌘↓ *command*, while this is the list's arrow-key behaviour,
    /// where wrapping from the last row back to the first would be surprising.
    public static func session(adjacentTo current: SessionID?, offset: Int, in state: AppState) -> SessionID? {
        let visible = visibleSessions(in: state)
        guard !visible.isEmpty else { return nil }
        guard let current, let index = visible.firstIndex(where: { $0.id == current }) else {
            return offset >= 0 ? visible[0].id : visible[visible.count - 1].id
        }
        let target = min(max(index + offset, 0), visible.count - 1)
        return visible[target].id
    }
}
