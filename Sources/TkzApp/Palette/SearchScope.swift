// SearchScope.swift — the chip row of the toolbar's results overlay (TKZ-52, design 2c.6).
//
// 2c.6 draws four chips — `All · Sessions · Transcripts · Files changed` — and a group filter on
// the right (`in: All groups ▾`). Tab cycles the chips; the scope decides which sections the
// overlay assembles, not how any of them are ranked.
//
// Plain value types with no AppKit in them: the chip bar draws them, `CommandPaletteController`
// filters on them, and the tests drive them without a window.

import Foundation
import TkzCore

/// Which kinds of hit the overlay shows.
public enum SearchScope: String, CaseIterable, Sendable {
    case all, sessions, transcripts, filesChanged

    /// The chip's label.
    public var chipTitle: String {
        switch self {
        case .all: "All"
        case .sessions: "Sessions"
        case .transcripts: "Transcripts"
        case .filesChanged: "Files changed"
        }
    }

    public var includesSessions: Bool { self == .all || self == .sessions }
    public var includesTranscripts: Bool { self == .all || self == .transcripts }
    public var includesFiles: Bool { self == .all || self == .filesChanged }
    /// The Actions row is an "everything" affordance; a narrowed scope is a narrowed list.
    public var includesActions: Bool { self == .all }

    /// Tab = `+1`, ⇧Tab = `-1`. Wraps: four chips in a row read as a ring, and unlike a result
    /// list there is no "am I at the end?" question to answer.
    public func cycled(by offset: Int) -> SearchScope {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return .all }
        let count = all.count
        return all[((index + offset) % count + count) % count]
    }
}

/// The `in: … ▾` filter next to the chips. Groups are the only axis the design offers.
public enum SearchGroupFilter: Hashable, Sendable {
    case allGroups
    case group(GroupID)

    public func title(in state: AppState) -> String {
        switch self {
        case .allGroups: "All groups"
        case .group(let id): state.groups[id]?.name ?? "All groups"
        }
    }

    /// Whether a hit belonging to `groupID` survives the filter.
    public func admits(_ groupID: GroupID?) -> Bool {
        switch self {
        case .allGroups: true
        case .group(let id): groupID == id
        }
    }
}
