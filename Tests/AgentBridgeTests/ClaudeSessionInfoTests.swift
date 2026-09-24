// `ClaudeSessionInfo`'s tolerant decoding, re-homed from `Tests/TkzCoreTests/ModelsTests.swift`
// when the type itself moved to `AgentBridge` in TKZ-81 — the descriptor is Claude Code's own
// file schema, so its decoder tests belong beside it, not in the agent-blind TkzCore test target.

import Foundation
import Testing

@testable import AgentBridge

@Suite struct ClaudeSessionInfoTests {
    /// A realistic descriptor, plus an unknown key that a future Claude Code version might add.
    static let realistic = """
        {
          "pid": 43117,
          "sessionId": "5c1f2d90-7f3a-4a1e-9d1e-6a2b0c8e11ff",
          "cwd": "/repo/.claude/worktrees/pricing",
          "startedAt": 1788940000123,
          "version": "2.1.263",
          "kind": "interactive",
          "entrypoint": "cli",
          "name": "pricing engine",
          "nameSource": "auto",
          "status": "busy",
          "updatedAt": 1788944400000,
          "statusUpdatedAt": 1788944399000,
          "messagingSocketPath": "/tmp/claude-43117.sock",
          "bridgeSessionId": "bridge-9",
          "jobId": "job-4",
          "somethingNewInTheNextVersion": {"a": [1, 2, 3]}
        }
        """

    @Test func decodesARealisticDescriptorAndIgnoresUnknownKeys() throws {
        let info = try ClaudeSessionInfo.decode(Data(Self.realistic.utf8), configDir: "/Users/x/.claude-work")
        #expect(info.pid == 43117)
        #expect(info.sessionId == "5c1f2d90-7f3a-4a1e-9d1e-6a2b0c8e11ff")
        #expect(info.cwd == "/repo/.claude/worktrees/pricing")
        #expect(info.kind == .interactive)
        #expect(info.status == .busy)
        #expect(info.nameSource == .auto)
        #expect(info.name == "pricing engine")
        #expect(info.jobId == "job-4")
        #expect(info.parkedJobId == nil)
        // configDir is injected, not decoded — it is what identifies the account.
        #expect(info.configDir == "/Users/x/.claude-work")
        #expect(info.accountKey == "claude-work")  // basename minus the leading dot
    }

    /// `startedAt` is epoch **milliseconds**.
    @Test func decodesTimestampsFromEpochMilliseconds() throws {
        let info = try ClaudeSessionInfo.decode(Data(Self.realistic.utf8), configDir: "~/.claude")
        #expect(info.startedAt == Date(timeIntervalSince1970: 1_788_940_000.123))
        #expect(info.updatedAt == Date(timeIntervalSince1970: 1_788_944_400))
        // A seconds-scale reading would be off by three orders of magnitude; catch that directly.
        #expect(info.startedAt!.timeIntervalSince1970 < 2_000_000_000)
    }

    @Test func acceptsNumericStringsAndMissingOptionalFields() throws {
        let json = #"{"pid":"501","sessionId":"s1","startedAt":"1788940000000"}"#
        let info = try ClaudeSessionInfo.decode(Data(json.utf8), configDir: "~/.claude")
        #expect(info.pid == 501)
        #expect(info.kind == nil)
        #expect(info.status == nil)
        #expect(info.name == nil)
        #expect(info.startedAt != nil)
    }

    /// Unknown enum values must degrade, not throw: Claude Code adds statuses without asking us.
    @Test func unknownEnumValuesDegradeToUnknown() throws {
        let json = #"{"pid":1,"sessionId":"s","kind":"weird","status":"thinking","nameSource":"typed"}"#
        let info = try ClaudeSessionInfo.decode(Data(json.utf8), configDir: "~/.claude")
        #expect(info.kind == .unknown("weird"))
        #expect(info.status == .unknown("thinking"))
        #expect(info.nameSource == .unknown("typed"))
        #expect(info.isBackground == false)
    }

    /// Claude Code 2.1.281: idle with a background Bash task still running (captured from a live
    /// CoreInvest session waiting on a CI watcher, 2026-09-24).
    @Test func shellStatusProjectsToBackgroundShell() throws {
        let json = #"{"pid":8892,"sessionId":"s","kind":"interactive","status":"shell","statusUpdatedAt":1790258975617}"#
        let info = try ClaudeSessionInfo.decode(Data(json.utf8), configDir: "~/.claude")
        #expect(info.status == .shell)
        #expect(info.observation.activity == .backgroundShell)
    }

    @Test func mapsTheBackgroundKind() throws {
        let json = #"{"pid":2,"sessionId":"s","kind":"bg","parkedJobId":"job-4"}"#
        let info = try ClaudeSessionInfo.decode(Data(json.utf8), configDir: "~/.claude")
        #expect(info.isBackground)
        #expect(info.parkedJobId == "job-4")
    }

    /// A file rewritten in place can be read mid-write. Every truncation of a real descriptor must
    /// either decode or throw a `DecodingError` — never crash, never produce a half-built value.
    /// The watcher's contract is "torn JSON keeps the previous value".
    @Test func survivesEveryTruncationOfARealDescriptor() {
        let bytes = Array(Self.realistic.utf8)
        var decoded = 0
        for cut in stride(from: 1, to: bytes.count, by: 1) {
            let data = Data(bytes.prefix(cut))
            if let info = try? ClaudeSessionInfo.decode(data, configDir: "~/.claude") {
                decoded += 1
                #expect(info.pid == 43117)  // anything that decodes is still coherent
            }
        }
        // Nothing but the whole document is valid JSON here, so no prefix should decode.
        #expect(decoded == 0)
    }

    @Test func rejectsDescriptorsWithoutTheRequiredIdentity() {
        for json in [#"{}"#, #"{"pid":10}"#, #"{"sessionId":"s"}"#, #"{"pid":"x","sessionId":"s"}"#,
                     #"{"pid":1,"sessionId":""}"#, "not json at all"] {
            #expect(throws: (any Error).self) {
                try ClaudeSessionInfo.decode(Data(json.utf8), configDir: "~/.claude")
            }
        }
    }

    /// The key must be spelled the way `Account.key` and `dash-usage-<key>.json` spell it,
    /// because M3 joins descriptors to sessions on it.
    @Test func accountKeyMatchesTheAccountKeySpelling() {
        #expect(ClaudeSessionInfo(configDir: "/Users/x/.claude", pid: 1, sessionId: "s").accountKey == "claude")
        #expect(ClaudeSessionInfo(configDir: "/Users/x/.claude-work", pid: 1, sessionId: "s").accountKey
            == "claude-work")
    }
}
