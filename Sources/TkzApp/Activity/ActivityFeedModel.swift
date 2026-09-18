// ActivityFeedModel — what the ⌘I feed lists, as a pure function of the store's state.
//
// The panel (`ActivityFeedController`) only draws rows; everything about *which* rows — the
// working rows pinned at the top with their elapsed time, one thread per row headed by its newest
// Stop / NEEDS YOU, the older entries folded under it, the filter — is decided here so it can be
// asserted without a window.

import Foundation
import TkzCore

enum ActivityFeedModel {
    /// A row that is working right now, pinned above the threads.
    struct WorkingRow: Hashable {
        var sessionID: SessionID
        var title: String
        var groupName: String
        /// `1h 3m` since Claude went busy; empty when the start is unknown.
        var elapsed: String
        var titleRanges: [Range<String.Index>]
    }

    /// One session's thread: its head entry and how many fold under it.
    struct ThreadRow: Hashable {
        var sessionID: SessionID
        var head: ActivityEvent
        var olderCount: Int
        /// Any entry of the thread is unread — the row is bold.
        var unread: Bool
        /// A `sessionEnded` entry newer than the head: drawn as an `· ended` marker.
        var ended: Bool
        var expanded: Bool
        var titleRanges: [Range<String.Index>]
        /// Ranges into `head.preview`.
        var previewRanges: [Range<String.Index>]
    }

    /// An older entry shown under its expanded thread.
    struct FoldedRow: Hashable {
        var sessionID: SessionID
        var event: ActivityEvent
        var previewRanges: [Range<String.Index>]
    }

    enum Row: Hashable {
        case working(WorkingRow)
        case thread(ThreadRow)
        case folded(FoldedRow)
        /// Nothing to list (after filtering, or at all).
        case empty(String)

        var isSelectable: Bool {
            if case .empty = self { return false }
            return true
        }

        var sessionID: SessionID? {
            switch self {
            case .working(let row): row.sessionID
            case .thread(let row): row.sessionID
            case .folded(let row): row.sessionID
            case .empty: nil
            }
        }

        /// Stable across rebuilds, so a selection survives a new entry arriving.
        var identity: String {
            switch self {
            case .working(let row): "working:\(row.sessionID.rawValue)"
            case .thread(let row): "thread:\(row.sessionID.rawValue)"
            case .folded(let row): "folded:\(row.event.id.uuidString)"
            case .empty: "empty"
            }
        }
    }

    static let emptyText = "Nothing happened while you were away"
    static let noMatchText = "No entry matches"

    /// The whole list. `expanded` names the threads whose older entries are shown.
    static func rows(
        state: AppState, query: String, expanded: Set<SessionID>, now: Date
    ) -> [Row] {
        let pattern = FuzzyMatch.Pattern(query.trimmingCharacters(in: .whitespaces))
        var rows: [Row] = []

        // Working rows first, in sidebar order, filtered by title and group like everything else.
        for session in state.orderedSessions where session.status == .working {
            let title = session.displayTitle
            let groupName = state.groups[session.groupID]?.name ?? ""
            guard let titleRanges = matchRanges(pattern, title: title, group: groupName, message: nil) else { continue }
            rows.append(
                .working(
                    WorkingRow(
                        sessionID: session.id, title: title, groupName: groupName,
                        elapsed: elapsed(of: session, now: now), titleRanges: titleRanges)))
        }

        // One thread per session, newest head first.
        for thread in threads(in: state) {
            let messages = thread.events.compactMap(\.kind.message)
            guard let titleRanges = matchRanges(pattern, title: thread.head.sessionTitle, group: thread.head.groupName, messages: messages)
            else { continue }
            let isExpanded = expanded.contains(thread.sessionID)
            rows.append(
                .thread(
                    ThreadRow(
                        sessionID: thread.sessionID, head: thread.head,
                        olderCount: thread.older.count,
                        unread: thread.events.contains { $0.unread },
                        ended: thread.ended, expanded: isExpanded,
                        titleRanges: titleRanges,
                        previewRanges: previewRanges(pattern, in: thread.head.preview))))
            if isExpanded {
                for event in thread.older {
                    rows.append(
                        .folded(
                            FoldedRow(
                                sessionID: thread.sessionID, event: event,
                                previewRanges: previewRanges(pattern, in: event.preview))))
                }
            }
        }

        if rows.isEmpty {
            rows.append(.empty(pattern.isEmpty ? emptyText : noMatchText))
        }
        return rows
    }

    // MARK: Threads

    struct Thread {
        var sessionID: SessionID
        var head: ActivityEvent
        /// Every other entry, newest first.
        var older: [ActivityEvent]
        var ended: Bool
        var events: [ActivityEvent]
    }

    /// One thread per session with entries, ordered by the head's time, newest first. The head is
    /// the newest Stop / NEEDS YOU; an exit only heads a thread that has nothing else, and
    /// otherwise becomes the `ended` marker.
    static func threads(in state: AppState) -> [Thread] {
        var bySession: [SessionID: [ActivityEvent]] = [:]
        for event in state.activity { bySession[event.sessionID, default: []].append(event) }
        var threads: [Thread] = []
        for (sessionID, events) in bySession {
            let ordered = events.sorted { $0.at > $1.at }  // newest first; the log is chronological
            guard let head = ordered.first(where: { $0.kind.isActionable }) ?? ordered.first else { continue }
            let ended = ordered.contains { event in
                if case .sessionEnded = event.kind { return event.at >= head.at && event.id != head.id }
                return false
            }
            threads.append(
                Thread(
                    sessionID: sessionID, head: head,
                    older: ordered.filter { $0.id != head.id },
                    ended: ended, events: ordered))
        }
        return threads.sorted {
            ($0.head.at, $0.sessionID.rawValue) > ($1.head.at, $1.sessionID.rawValue)
        }
    }

    // MARK: Filter

    /// The title's match ranges when the query matches the title, the group or any message —
    /// contiguous, like ⌘F. `nil` means the row is filtered out. An empty query matches all.
    static func matchRanges(
        _ pattern: FuzzyMatch.Pattern, title: String, group: String, message: String?
    ) -> [Range<String.Index>]? {
        matchRanges(pattern, title: title, group: group, messages: message.map { [$0] } ?? [])
    }

    static func matchRanges(
        _ pattern: FuzzyMatch.Pattern, title: String, group: String, messages: [String]
    ) -> [Range<String.Index>]? {
        if pattern.isEmpty { return [] }
        if let hit = FuzzyMatch.substring(pattern, in: FuzzyMatch.Target(title)) { return hit.ranges }
        if FuzzyMatch.substring(pattern, in: FuzzyMatch.Target(group)) != nil { return [] }
        for message in messages where FuzzyMatch.substring(pattern, in: FuzzyMatch.Target(message)) != nil {
            return []
        }
        return nil
    }

    static func previewRanges(_ pattern: FuzzyMatch.Pattern, in preview: String) -> [Range<String.Index>] {
        guard !pattern.isEmpty, !preview.isEmpty else { return [] }
        return FuzzyMatch.substring(pattern, in: FuzzyMatch.Target(preview))?.ranges ?? []
    }

    // MARK: Elapsed

    /// `1h 3m` since the observation last flipped to busy — the agent's own clock for the status —
    /// else since the prompt that started the turn. Empty when neither is known.
    static func elapsed(of session: Session, now: Date) -> String {
        guard let since = session.live?.observation?.statusUpdatedAt ?? session.live?.lastPromptAt else { return "" }
        let seconds = max(0, now.timeIntervalSince(since))
        return StatusBarModel.formatResetsIn(.seconds(seconds))
    }

    /// `now` / `12m` / `1h` / `3d`, the sidebar's own short form.
    static func age(of event: ActivityEvent, now: Date) -> String {
        SearchTranscriptRowView.age(from: event.at, now: now)
    }

    /// The kind pill's text: `NEEDS YOU · permission`, `Stop`, `ended`.
    static func kindLabel(_ kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .stop: "STOP"
        case .needsYou(let reason, _): "NEEDS YOU \u{00B7} \(reason.feedLabel)"
        case .sessionEnded(let reason):
            if let reason, !reason.isEmpty { "ENDED \u{00B7} \(reason)" } else { "ENDED" }
        }
    }
}
