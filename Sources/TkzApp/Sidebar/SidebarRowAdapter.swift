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
        case .exited: .exited
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
            isWorktree: session.isWorktree,
            status: status(of: session),
            accountLabel: accountLabel(for: session, in: state),
            accountColor: SidebarSessionRowModel.accountChipColor(forKey: session.accountKey),
            needsAttention: session.needsAttention,
            isSelected: state.selection == session.id
        )
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
    /// A single-account setup carries no useful information in the chip, so it is hidden: the chip
    /// only appears once the state knows about more than one account. The label is derived from the
    /// account's *configured* `label` (never hardcoded — see CLAUDE.md): initials for a multi-word
    /// label ("Claude (alt)" → `CA`), the first two characters for a single word ("Claude" → `CL`).
    /// An account the state has never heard of falls back to the same derivation over its key.
    public static func accountLabel(for session: Session, in state: AppState) -> String? {
        guard state.accounts.count > 1 else { return nil }
        let source = state.accounts[session.accountKey]?.label ?? session.accountKey
        return shortLabel(source) ?? shortLabel(session.accountKey)
    }

    static func shortLabel(_ source: String) -> String? {
        let words = source
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        guard let first = words.first else { return nil }
        if words.count > 1 {
            return String(words.prefix(3).compactMap(\.first)).uppercased()
        }
        return String(first.prefix(2)).uppercased()
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
