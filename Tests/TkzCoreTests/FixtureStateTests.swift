// FixtureStateTests — `AppState.fixture` stays Claude-only (a hard requirement: a lot of other
// tests measure it by row/group/account count), and `.fixtureMultiAgent` (TKZ-87) is a real,
// separate second agent grafted on top of it.

import Foundation
import Testing

@testable import TkzCore

@Suite struct FixtureStateTests {

    @Test("The plain fixture never grows a second agent")
    func fixtureStaysClaudeOnly() {
        let state = AppState.fixture
        #expect(Set(state.sessions.values.map(\.agent)) == [.claude])
        #expect(Set(state.accounts.values.map(\.agent)) == [.claude])
    }

    @Test("The multi-agent fixture is the plain one, plus a real Codex group")
    func multiAgentAddsCodex() throws {
        let plain = AppState.fixture
        let multi = AppState.fixtureMultiAgent

        // Additive: nothing about the Claude-only rows moved.
        #expect(multi.groups.count == plain.groups.count + 1)
        for (id, group) in plain.groups { #expect(multi.groups[id] == group) }
        for (id, session) in plain.sessions { #expect(multi.sessions[id] == session) }

        let codexAccount = try #require(multi.accounts["codex"])
        #expect(codexAccount.agent == .codex)
        #expect(codexAccount.configDir == "~/.codex")

        let codexSessions = multi.sessions.values.filter { $0.agent == .codex }
        #expect(codexSessions.count == 3)
        #expect(codexSessions.allSatisfy { $0.accountKey == "codex" })

        // Codex writes no descriptor file of its own — a live Codex row must not claim one.
        for session in codexSessions where session.live != nil {
            #expect(session.live?.observation == nil)
        }

        // One restored row (no live state), matching the shape `Fixture.make` itself uses for the
        // same purpose in the Claude-only rows.
        #expect(codexSessions.contains { $0.live == nil })
        #expect(codexSessions.contains { $0.live?.status == .working })
        #expect(codexSessions.contains { $0.live?.attention == true })
    }
}
