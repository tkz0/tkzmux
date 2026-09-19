// TkzCore — which coding agent a row runs.
//
// The discriminator the rest of the app branches on. Everything that knows a path, a JSON schema
// or a CLI flag lives behind an `AgentAdapter` in AgentBridge; this type is only the name.
//
// **A struct, not an enum, on purpose.** `state.json` carries this value, and a file written by a
// build that knows `gemini` has to keep loading in a build that does not. An enum would fail to
// decode the whole session; a raw-string struct decodes it into an agent nobody has an adapter
// for, and the row shows as an unknown agent with resume disabled. Same reason
// `AgentObservation.activity` is `nil` rather than a guess when an agent's own descriptor reports
// a status this build does not recognise.

import Foundation

public struct AgentKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    /// Claude Code.
    public static let claude = AgentKind(rawValue: "claude")
    /// OpenAI Codex CLI.
    public static let codex = AgentKind(rawValue: "codex")

    /// Every agent tkzmux ships an adapter for. Not every one of these is installed — that is the
    /// adapter registry's question, not this type's.
    public static let known: [AgentKind] = [.claude, .codex]

    public var isKnown: Bool { Self.known.contains(self) }
}

extension AgentKind {
    /// The path fragment that makes a directory one of this agent's worktrees, or `nil` for an
    /// agent with no worktree flag at all.
    ///
    /// Claude Code's `claude -w <name>` creates `<repo>/.claude/worktrees/<name>` and starts there.
    /// Codex has no equivalent, so a Codex row never derives a worktree from its cwd — and must
    /// not, or a Codex session started *inside* a Claude worktree would claim the `WT` badge and a
    /// `worktreePath` that Codex knows nothing about.
    public var worktreeMarker: String? {
        self == .claude ? "/.claude/worktrees/" : nil
    }

    /// The worktree `path` lies in under this agent's marker, or `nil`.
    ///
    /// Anything at or below `<repo>/<marker><name>` maps to that directory; a path that merely
    /// *contains* the marker with nothing after it is not a worktree.
    public func worktreeRoot(ofPath path: String) -> String? {
        guard let marker = worktreeMarker else { return nil }
        return Self.worktreeRoot(ofPath: path, marker: marker)
    }

    /// The marker-agnostic half, so a test can exercise the parsing without an agent.
    static func worktreeRoot(ofPath path: String, marker: String) -> String? {
        guard let range = path.range(of: marker) else { return nil }
        let rest = path[range.upperBound...]
        let name = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first
        guard let name, !name.isEmpty else { return nil }
        return String(path[..<range.upperBound]) + name
    }
}

extension AgentKind {
    /// A bare JSON string (`"claude"`), not `{"rawValue": "claude"}`. Spelled out rather than left
    /// to `RawRepresentable`'s default, so the on-disk shape is a decision rather than a synthesis
    /// detail — `Migrations.liftV3ToV4` writes this value as a plain string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
