// BoardModel — what the board draws, as values.
//
// `AppState` → four columns of cards, each already carrying the words it shows: the group's name
// and colour, the agent's title and dot, and the one status line that says where the card stands
// ("Queued for feature-x", "Open to TKZMUX agents", "Working"). Pure, so the wording — which is
// most of what makes the automation legible — is asserted in `BoardModelTests` without a view.

import Foundation
import TkzCore

enum BoardModel {
    struct Column: Hashable {
        var column: BoardColumn
        var cards: [Card]
    }

    struct Card: Hashable {
        var id: BoardTaskID
        var title: String
        var notes: String
        var group: GroupTag?
        var agent: Agent?
        var status: Status
    }

    struct GroupTag: Hashable {
        var id: GroupID
        var name: String
        var color: RGB?
    }

    struct Agent: Hashable {
        enum Dot: Hashable { case working, needsYou, idle, offline }
        var id: SessionID
        var title: String
        var dot: Dot
    }

    struct Status: Hashable {
        enum Tone: Hashable { case muted, working, attention, done }
        var text: String
        var tone: Tone
    }

    static func columns(state: AppState) -> [Column] {
        BoardColumn.allCases.map { column in
            Column(column: column, cards: state.boardTasks(in: column).map { card($0, state: state) })
        }
    }

    static func card(_ task: BoardTask, state: AppState) -> Card {
        let group = task.groupID.flatMap { state.groups[$0] }
        let session = task.assignee.flatMap { state.sessions[$0] }
        return Card(
            id: task.id,
            title: task.title,
            notes: task.notes,
            group: group.map { GroupTag(id: $0.id, name: $0.name, color: $0.color) },
            agent: session.map { Agent(id: $0.id, title: $0.displayTitle, dot: dot(for: $0)) },
            status: status(task, group: group, session: session, state: state))
    }

    static func dot(for session: Session) -> Agent.Dot {
        guard let live = session.live, live.alive, !live.ended,
            live.pid != nil || live.descriptor != nil
        else { return .offline }
        if session.needsAttention, session.status != .waiting(.doneUnattended) { return .needsYou }
        return session.status == .working ? .working : .idle
    }

    static func status(_ task: BoardTask, group: Group?, session: Session?, state: AppState) -> Status {
        switch task.column {
        case .todo:
            if let session {
                if let active = state.activeBoardTask(of: session.id), active.id != task.id {
                    return Status(text: "Queued for \(session.displayTitle)", tone: .muted)
                }
                if session.isReadyForBoardTask {
                    return Status(text: "Sending to \(session.displayTitle)\u{2026}", tone: .working)
                }
                return dot(for: session) == .offline
                    ? Status(text: "Waiting for Claude in \(session.displayTitle)", tone: .attention)
                    : Status(text: "Queued for \(session.displayTitle)", tone: .muted)
            }
            if let group {
                // Every row with a Claude in it is an agent for its group. The line names what
                // is actually missing: a group full of bare shells has rows, but nobody to work.
                let agents = state.sessions(in: group.id).filter { state.hasClaude($0.id) }
                if agents.isEmpty {
                    return Status(text: "No Claude running in \(group.name)", tone: .attention)
                }
                return agents.contains(where: \.isReadyForBoardTask)
                    ? Status(text: "Open to \(group.name) agents", tone: .muted)
                    : Status(text: "Waiting for a free agent in \(group.name)", tone: .muted)
            }
            return Status(text: "Unassigned", tone: .muted)
        case .inProgress:
            guard let session else { return Status(text: "In progress", tone: .muted) }
            switch dot(for: session) {
            case .needsYou: return Status(text: "Needs you", tone: .attention)
            case .working: return Status(text: "Working", tone: .working)
            case .idle, .offline: return Status(text: "In progress", tone: .muted)
            }
        case .inReview:
            return Status(text: "Ready for review", tone: .attention)
        case .done:
            return Status(text: "Done", tone: .done)
        }
    }

    /// "3 to do · 1 in progress · 2 in review" — the header's subtitle. Done is left out: it only
    /// grows, and the line is about what is left.
    static func summary(_ columns: [Column]) -> String {
        let parts = columns.filter { $0.column != .done && !$0.cards.isEmpty }
            .map { "\($0.cards.count) \($0.column.title.lowercased())" }
        return parts.isEmpty ? "Nothing open" : parts.joined(separator: " \u{00B7} ")
    }
}
