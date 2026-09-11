// SearchRows.swift — the non-session rows of the toolbar's results overlay (TKZ-52, design 2c.6).
//
// `PaletteResult` already covers sessions, groups and commands: they are fuzzy hits over an
// `AppState` and they all activate the same way. The overlay's other three sections do not fit that
// shape — a transcript hit is a literal match inside a conversation, a changed file belongs to a
// repo rather than to the store, and the Actions row is not a hit at all — so they get their own
// value types and join the list through ``CommandPaletteController/Row``.
//
// All four are plain `Sendable` values with no AppKit: `SearchRowViews` draws them, and the tests
// build them by hand without touching disk.

import Foundation
import TkzCore

/// One match inside a session's Claude transcript.
public struct TranscriptRow: Identifiable, Sendable {

    /// What kind of line the hit sits on. 2c.6 prefixes the excerpt with a glyph so a prompt, an
    /// answer and a tool call are told apart at a glance.
    public enum Kind: String, Sendable {
        case user, assistant, tool

        public var glyph: String {
            switch self {
            case .user: ">"
            case .assistant: "\u{2733}"   // ✳
            case .tool: "\u{25CF}"        // ●
            }
        }
    }

    public let sessionID: SessionID
    /// The session's row title, shown truncated in the 150 pt left column.
    public let sessionTitle: String
    /// 1-based conversation turn, counting the human's prompts.
    public let turn: Int
    public let kind: Kind
    /// A single collapsed line around the hit — never the whole message.
    public let excerpt: String
    /// Ranges into ``excerpt``, ready to highlight.
    public let matchRanges: [Range<String.Index>]
    public let at: Date?

    public var id: String { "transcript:\(sessionID.rawValue):\(turn):\(excerpt.hashValue)" }

    public init(
        sessionID: SessionID,
        sessionTitle: String,
        turn: Int,
        kind: Kind,
        excerpt: String,
        matchRanges: [Range<String.Index>],
        at: Date?
    ) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.turn = turn
        self.kind = kind
        self.excerpt = excerpt
        self.matchRanges = matchRanges
        self.at = at
    }
}

/// One path out of a session repo's working tree.
public struct FileRow: Identifiable, Sendable {
    public let sessionID: SessionID
    public let sessionTitle: String
    /// Repo-relative, as git prints it.
    public let path: String
    /// The porcelain letter — `M`, `A`, `D`, `R`, or `?` for untracked.
    public let status: String
    public let matchRanges: [Range<String.Index>]

    public var id: String { "file:\(sessionID.rawValue):\(path)" }

    public init(
        sessionID: SessionID, sessionTitle: String, path: String, status: String,
        matchRanges: [Range<String.Index>]
    ) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.path = path
        self.status = status
        self.matchRanges = matchRanges
    }
}

/// The overlay's Actions section — today only "start a session from what you typed".
public struct SearchAction: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        /// `＋ New session in <group> with prompt "…"`, activated with ⌘↵.
        case newSessionWithPrompt
    }

    public let kind: Kind
    public let title: String
    /// The shortcut printed at the right edge.
    public let trailing: String
    public let groupID: GroupID?
    /// The text the new session should start with, verbatim.
    public let prompt: String

    public var id: String { "action:\(kind.rawValue):\(groupID?.rawValue ?? "-")" }

    public init(kind: Kind, title: String, trailing: String, groupID: GroupID?, prompt: String) {
        self.kind = kind
        self.title = title
        self.trailing = trailing
        self.groupID = groupID
        self.prompt = prompt
    }
}

/// What ↵ (or a click) on the selected row means. Replaces the bare `PaletteResult` callback now
/// that four different things can be selected.
public enum PaletteActivation: Sendable {
    case result(PaletteResult)
    case transcript(TranscriptRow)
    case file(FileRow)
    case action(SearchAction)
    /// "Show N more…" — expands a truncated section in place rather than navigating anywhere.
    case showMore(SearchScope)
}
