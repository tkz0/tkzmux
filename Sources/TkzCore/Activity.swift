// TkzCore — the activity feed's event log (⌘I): what every Claude did while the user was away.
//
// One entry per thing worth catching up on — a finished turn, a row that started needing the
// user, a Claude that exited — appended by the reducers that already know the moment it happens
// (`applyEvent`, `rederiveStatus`) and read back by the feed panel in TkzApp. Kept on `AppState`
// rather than on `Session.live`, because `live` is never persisted and an entry's *unread* flag
// has to survive a relaunch: coming back to the app is exactly when the list is wanted.

import Foundation

/// One line of the activity feed.
public struct ActivityEvent: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: Hashable, Sendable, Codable {
        /// Claude finished a turn; `message` is the head of its last reply.
        case stop(message: String)
        /// The row flipped into NEEDS YOU; `message` is Claude's own line for the prompt, or the
        /// last reply for an unattended Stop that aged into NEEDS YOU.
        case needsYou(reason: WaitReason, message: String?)
        /// The agent exited for real — an ending its own adapter judged to be one, rather than a
        /// clear or a resume that leaves the row alive. `reason` is the agent's own word for it.
        case sessionEnded(reason: String?)

        /// Whether an entry of this kind is something to act on. An exit is context, not a call:
        /// it is born read and never bolds a thread.
        public var isActionable: Bool {
            switch self {
            case .stop, .needsYou: true
            case .sessionEnded: false
            }
        }

        /// The message text the filter matches and the preview is cut from.
        public var message: String? {
            switch self {
            case .stop(let message): message
            case .needsYou(_, let message): message
            case .sessionEnded: nil
            }
        }
    }

    public var id: UUID
    public var sessionID: SessionID
    public var kind: Kind
    public var at: Date
    /// The row's title and group name at the time, so an entry still reads once the row has been
    /// renamed or the app relaunched with the row's live state gone.
    public var sessionTitle: String
    public var groupName: String
    /// Set until the row is looked at after the event — selected, typed into, or a Stop arriving
    /// while it is already on screen. *Mark as unread* raises it again.
    public var unread: Bool

    public init(
        id: UUID = UUID(),
        sessionID: SessionID,
        kind: Kind,
        at: Date,
        sessionTitle: String,
        groupName: String,
        unread: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.at = at
        self.sessionTitle = sessionTitle
        self.groupName = groupName
        self.unread = unread
    }

    /// How much of a message an entry keeps: enough for the filter to find a word from the reply
    /// beyond the two lines the feed shows, bounded so 200 entries stay a small file.
    public static let messageCap = 1024

    /// Cuts a message down to `messageCap` characters for storage.
    public static func storedMessage(_ message: String) -> String {
        message.count > messageCap ? String(message.prefix(messageCap)) : message
    }

    /// The first `count` non-empty lines of `text`, trimmed — the feed's preview and the
    /// notification banner's body share this cut.
    public static func firstLines(of text: String, count: Int) -> [String] {
        var lines: [String] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lines.append(line)
            if lines.count == count { break }
        }
        return lines
    }

    /// The two-line preview the feed shows under the entry.
    public var preview: String {
        guard let message = kind.message else { return "" }
        return Self.firstLines(of: message, count: 2).joined(separator: "\n")
    }
}

extension WaitReason {
    /// The reason word the feed prints after NEEDS YOU.
    public var feedLabel: String {
        switch self {
        case .permission: "permission"
        case .elicitation, .agentInput: "question"
        case .doneUnattended: "unattended"
        }
    }
}
