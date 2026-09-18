import Foundation
import Testing
@testable import TkzCore

@Suite struct AgentKindTests {
    // MARK: Wire format

    /// `state.json` and `Migrations.liftV3ToV4` both write this value as a bare JSON string
    /// (`"claude"`), never `{"rawValue": "claude"}` — an object wire format would break every file
    /// the v3→v4 lift already stamped.
    @Test func roundTripsThroughJSONAsABareString() throws {
        let data = try JSONEncoder().encode(AgentKind.claude)
        #expect(String(data: data, encoding: .utf8) == "\"claude\"")
        let decoded = try JSONDecoder().decode(AgentKind.self, from: data)
        #expect(decoded == .claude)
    }

    /// An agent nobody has an adapter for still decodes: the row shows as an unknown agent with
    /// resume disabled, rather than the whole file failing to load.
    @Test func anUnknownRawValueDecodesAndReportsUnknown() throws {
        let data = Data("\"gemini\"".utf8)
        let decoded = try JSONDecoder().decode(AgentKind.self, from: data)
        #expect(decoded.rawValue == "gemini")
        #expect(decoded.isKnown == false)
    }

    @Test func knownAgentsReportKnown() {
        #expect(AgentKind.claude.isKnown)
        #expect(AgentKind.codex.isKnown)
    }

    // MARK: Worktree marker

    /// Only Claude Code has a worktree flag (`claude -w`); every other agent, known or not, has no
    /// marker to find one by.
    @Test func worktreeMarkerIsNilForAnythingButClaude() {
        #expect(AgentKind.claude.worktreeMarker == "/.claude/worktrees/")
        #expect(AgentKind.codex.worktreeMarker == nil)
        #expect(AgentKind(rawValue: "gemini").worktreeMarker == nil)
    }
}
