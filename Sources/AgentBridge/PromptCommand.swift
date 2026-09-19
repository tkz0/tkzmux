// PromptCommand — a slash command or skill invocation, out of the block Claude Code writes for it.
//
// When a prompt starts with a slash, the transcript's `user` line is not what the human typed but
// a tag block standing in for it:
//
//     <command-message>brainstorming-skill:brainstorming-skill</command-message>
//     <command-name>/brainstorming-skill:brainstorming-skill</command-name>
//     <command-args>We need to start work on ADO 3620. …</command-args>
//
// Shown raw — which is what the first-prompt card and the search index did — three lines of markup
// come before the sentence that says what the session is about. This turns the block back into the
// line as typed: `/brainstorming-skill We need to start work on ADO 3620. …`, with the name kept
// apart so the card can style it.
//
// Only a block that *starts* with `<command-message>` counts. A local command's echo — `/clear`,
// `/model`, `/effort` — is written name-first and is rejected before it ever reaches here (see
// ``TranscriptReader/commandEchoPrefixes``); the prefix rule is what keeps those two apart.
//
// `parse` runs on every indexed user line, on a background queue, so it allocates nothing up front:
// no static regex (an `NSRegularExpression` in a `static let` is exactly the non-`Sendable` class
// this module avoids), and the prefix check bails out of all the rest in one comparison.

import Foundation

public struct PromptCommand: Hashable, Sendable {
    /// `/brainstorming-skill` — the leading slash kept, a duplicated `foo:foo` collapsed to `foo`.
    public let name: String
    /// What the human typed after the name, trimmed; `nil` for a bare `/loop`.
    public let arguments: String?

    public init(name: String, arguments: String?) {
        self.name = name
        self.arguments = arguments
    }

    /// The line as it was typed — what Copy prompt writes, and what the search index stores.
    public var typedLine: String { arguments.map { "\(name) \($0)" } ?? name }

    /// `nil` for anything that is not a command invocation.
    public static func parse(_ text: String) -> PromptCommand? {
        guard text.hasPrefix("<command-message>") else { return nil }
        guard let raw = tag("command-name", in: text) ?? tag("command-message", in: text),
              let name = normalize(raw)
        else { return nil }
        let arguments = tag("command-args", in: text)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PromptCommand(name: name, arguments: (arguments?.isEmpty ?? true) ? nil : arguments)
    }

    /// The contents of `<name>…</name>`. A tag opened and never closed — a torn last line — yields
    /// what there is rather than nothing.
    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>") else { return nil }
        let rest = text[open.upperBound...]
        guard let close = rest.range(of: "</\(name)>") else { return String(rest) }
        return String(rest[..<close.lowerBound])
    }

    /// `brainstorming-skill:brainstorming-skill` → `/brainstorming-skill`, and
    /// `/frontinvest-team-tools:release-pr` → itself. Only an exact duplicate collapses: two
    /// different halves are a plugin and its command, and both of them carry meaning.
    static func normalize(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix("/") { name.removeFirst() }
        if let colon = name.firstIndex(of: ":") {
            let plugin = String(name[..<colon])
            let command = String(name[name.index(after: colon)...])
            if !plugin.isEmpty, plugin == command { name = plugin }
        }
        guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return nil }
        return "/" + name
    }
}
