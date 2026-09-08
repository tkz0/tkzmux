// PaletteItem.swift — what ⌘P / ⇧⌘P search over (M2.4 / TKZ-20).
//
// design.md → App architecture → Palette: "fuzzy over sessions (title, branch, cwd, group), groups,
// commands, presets". One flat item type covers all four; ``PaletteItem/Kind`` is what the panel
// groups rows by, and ``PaletteItem/actionID`` is the only thing wave 3 has to dispatch on.
//
// Items carry their fields *pre-folded* (`FuzzyMatch.Target`) because the folding, not the DP, is
// the expensive half of a keystroke — see `PaletteDataSource`.

import Foundation
import TkzCore

/// One searchable row.
public struct PaletteItem: Identifiable, Sendable {

    public enum Kind: String, Sendable, CaseIterable {
        case session, group, command, preset

        /// The section header the panel draws above a run of these.
        public var sectionTitle: String {
            switch self {
            case .session: "Sessions"
            case .group: "Groups"
            case .command: "Commands"
            case .preset: "Presets"
            }
        }

        /// Sections appear in this order; within a section, rows are ranked by score.
        var sectionOrder: Int {
            switch self {
            case .session: 0
            case .group: 1
            case .command: 2
            case .preset: 3
            }
        }
    }

    /// Which of an item's texts a hit came from — the palette prints this next to a non-title match
    /// ("branch", "cwd") so the user can see *why* a row is there.
    public enum Field: String, Sendable, CaseIterable {
        case title, branch, cwd, group, subtitle

        /// Added to the fuzzy score so that, all else equal, a title hit outranks a path hit.
        var weight: Int {
            switch self {
            case .title: 40
            case .branch: 24
            case .group: 12
            case .subtitle: 8
            case .cwd: 0
            }
        }

        public var label: String {
            switch self {
            case .title: "title"
            case .branch: "branch"
            case .cwd: "cwd"
            case .group: "group"
            case .subtitle: "subtitle"
            }
        }
    }

    /// A searchable text plus the field it belongs to, folded once at construction.
    public struct Searchable: Sendable {
        public let field: Field
        public let target: FuzzyMatch.Target
        public var text: String { target.text }

        public init(_ field: Field, _ text: String) {
            self.field = field
            self.target = FuzzyMatch.Target(text)
        }
    }

    public let id: String
    public let kind: Kind
    /// The row's main line.
    public let title: String
    /// The row's dim second line — for a session, `⎇ branch · cwd`.
    public let subtitle: String
    /// What the panel's right edge shows: a shortcut (`⇧⌘P`) or an account key.
    public let trailing: String?
    /// What wave 3 dispatches on. Sessions: `session:<uuid>`. Groups: `group:<uuid>`.
    /// Commands: the raw `ShortcutAction` id, so the palette and the main menu share one vocabulary.
    /// Presets: `preset:<uuid>`.
    public let actionID: String
    /// The session this row acts on, when it is a session row.
    public let sessionID: SessionID?
    public let groupID: TkzCore.GroupID?
    public let fields: [Searchable]

    public init(
        id: String,
        kind: Kind,
        title: String,
        subtitle: String = "",
        trailing: String? = nil,
        actionID: String,
        sessionID: SessionID? = nil,
        groupID: TkzCore.GroupID? = nil,
        fields: [Searchable]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.actionID = actionID
        self.sessionID = sessionID
        self.groupID = groupID
        self.fields = fields
    }
}

/// A ranked hit: the item, its score, and where the query landed.
public struct PaletteResult: Identifiable, Sendable {
    public let item: PaletteItem
    public let score: Int
    /// Which field produced the hit.
    public let field: PaletteItem.Field
    /// The text of ``field`` — the string ``ranges`` index into.
    public let matchedText: String
    /// Matched ranges into ``matchedText``, ready for highlighting.
    public let ranges: [Range<String.Index>]

    public var id: String { item.id }

    /// Ranges into `item.title`, or `[]` when the hit came from another field (in which case the
    /// panel highlights the subtitle instead and labels it with ``field``).
    public var titleRanges: [Range<String.Index>] {
        field == .title && matchedText == item.title ? ranges : []
    }

    public init(
        item: PaletteItem,
        score: Int,
        field: PaletteItem.Field,
        matchedText: String,
        ranges: [Range<String.Index>]
    ) {
        self.item = item
        self.score = score
        self.field = field
        self.matchedText = matchedText
        self.ranges = ranges
    }
}

/// Results for one kind, in section order.
public struct PaletteSection: Identifiable, Sendable {
    public let kind: PaletteItem.Kind
    public let results: [PaletteResult]
    public var id: String { kind.rawValue }
    public var title: String { kind.sectionTitle }
}
