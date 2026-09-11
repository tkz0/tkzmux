// PaletteDataSource.swift — turns an `AppState` into searchable palette items and ranks them
// (M2.4 / TKZ-20).
//
// Build one when the state changes, then call ``search(_:)`` per keystroke: every candidate string
// is folded once at construction (`FuzzyMatch.Target`), which is what keeps a keystroke over the
// 40-session fixture in the low milliseconds. Ranking 40 sessions must stay under 50 ms — there is a
// measured test for it in `PaletteTests`.
//
// Two modes, because the design gives the two shortcuts different jobs:
//   * ⌘P  "Search sessions…" — sessions only.
//   * ⇧⌘P command palette   — sessions, groups and commands.

import Foundation
import TkzCore

public struct PaletteDataSource: Sendable {

    public enum Mode: Sendable {
        /// ⌘P — sessions only.
        case sessions
        /// ⇧⌘P — everything.
        case all

        var kinds: Set<PaletteItem.Kind> {
            switch self {
            case .sessions: [.session]
            case .all: Set(PaletteItem.Kind.allCases)
            }
        }
    }

    /// Every item, in "empty query" order: sessions in sidebar order, then groups, then commands.
    public let items: [PaletteItem]
    public let mode: Mode

    public init(state: AppState, mode: Mode = .all) {
        self.mode = mode
        let kinds = mode.kinds
        var items: [PaletteItem] = []

        if kinds.contains(.session) {
            for session in state.orderedSessions {
                items.append(Self.item(for: session, in: state))
            }
        }
        if kinds.contains(.group) {
            for group in state.orderedGroups {
                items.append(Self.item(for: group))
            }
        }
        if kinds.contains(.command) {
            let table = ShortcutsTable.resolved(state: state)
            for action in ShortcutsTable.allActions {
                items.append(Self.item(for: action, shortcut: table[action]))
            }
        }
        self.items = items
    }

    // MARK: Item construction

    static func item(for session: Session, in state: AppState) -> PaletteItem {
        let group = state.groups[session.groupID]
        let branch = session.live?.git?.branch
        var fields: [PaletteItem.Searchable] = [.init(.title, session.displayTitle)]
        if let branch, !branch.isEmpty { fields.append(.init(.branch, branch)) }
        fields.append(.init(.cwd, session.cwd))
        if let name = group?.name, !name.isEmpty { fields.append(.init(.group, name)) }

        var parts: [String] = []
        if let branch, !branch.isEmpty { parts.append("\u{2387} \(branch)") }  // ⎇
        if let name = group?.name, !name.isEmpty { parts.append(name) }
        parts.append(session.cwd)

        return PaletteItem(
            id: "session:\(session.id.rawValue)",
            kind: .session,
            title: session.displayTitle,
            subtitle: parts.joined(separator: " \u{00B7} "),
            trailing: session.status.name,
            actionID: "session:\(session.id.rawValue)",
            sessionID: session.id,
            groupID: session.groupID,
            fields: fields
        )
    }

    static func item(for group: Group) -> PaletteItem {
        var fields: [PaletteItem.Searchable] = [.init(.title, group.name)]
        if let repoRoot = group.repoRoot, !repoRoot.isEmpty { fields.append(.init(.cwd, repoRoot)) }
        return PaletteItem(
            id: "group:\(group.id.rawValue)",
            kind: .group,
            title: group.name,
            subtitle: group.repoRoot ?? "No repo",
            actionID: "group:\(group.id.rawValue)",
            groupID: group.id,
            fields: fields
        )
    }

    static func item(for action: ShortcutAction, shortcut: Shortcut?) -> PaletteItem {
        let title = ShortcutsTable.title(for: action)
        return PaletteItem(
            id: "command:\(action.rawValue)",
            kind: .command,
            title: title,
            subtitle: "",
            trailing: shortcut?.displayString,
            // Command rows dispatch on the bare action id, so the palette and the main menu share
            // one vocabulary (see ShortcutsTable).
            actionID: action.rawValue,
            fields: [.init(.title, title)]
        )
    }

    // MARK: Search

    /// Ranked hits for `query`. An empty query returns every item in construction order with score 0,
    /// so ⌘P opens on the session list rather than on nothing.
    public func search(_ query: String, limit: Int? = nil) -> [PaletteResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let all = items.map {
                PaletteResult(item: $0, score: 0, field: .title, matchedText: $0.title, ranges: [])
            }
            return limit.map { Array(all.prefix($0)) } ?? all
        }

        let pattern = FuzzyMatch.Pattern(trimmed)
        var hits: [(result: PaletteResult, order: Int)] = []
        for (order, item) in items.enumerated() {
            var best: (score: Int, field: PaletteItem.Field, text: String, ranges: [Range<String.Index>])?
            for searchable in item.fields {
                guard let match = FuzzyMatch.match(pattern, in: searchable.target) else { continue }
                let score = match.score + searchable.field.weight
                if best == nil || score > best!.score {
                    best = (score, searchable.field, searchable.text, match.ranges)
                }
            }
            guard let best else { continue }
            hits.append(
                (
                    PaletteResult(
                        item: item, score: best.score, field: best.field,
                        matchedText: best.text, ranges: best.ranges),
                    order
                ))
        }

        hits.sort { lhs, rhs in
            if lhs.result.score != rhs.result.score { return lhs.result.score > rhs.result.score }
            // Same score: the shorter text is the more specific hit, then keep the natural order.
            let l = lhs.result.matchedText.count, r = rhs.result.matchedText.count
            if l != r { return l < r }
            return lhs.order < rhs.order
        }
        let results = hits.map(\.result)
        return limit.map { Array(results.prefix($0)) } ?? results
    }

    /// The same hits, split into the panel's sections (Sessions, Groups, Commands) and
    /// ordered inside each by score. Empty sections are dropped.
    public func sections(for query: String, limit: Int? = nil) -> [PaletteSection] {
        let results = search(query, limit: limit)
        var buckets: [PaletteItem.Kind: [PaletteResult]] = [:]
        for result in results { buckets[result.item.kind, default: []].append(result) }
        return PaletteItem.Kind.allCases
            .sorted { $0.sectionOrder < $1.sectionOrder }
            .compactMap { kind in
                guard let rows = buckets[kind], !rows.isEmpty else { return nil }
                return PaletteSection(kind: kind, results: rows)
            }
    }
}
