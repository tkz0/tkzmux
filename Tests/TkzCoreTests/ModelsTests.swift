// The model contract: identifiers that round-trip as file basenames, a descriptor parser that
// survives what another program writes underneath it, and persisted shapes that keep `live` out.

import Foundation
import Testing

@testable import TkzCore

@Suite struct IdentifierTests {
    @Test func roundTripsThroughItsStringForm() {
        let id = SessionID.generate()
        #expect(SessionID(id.rawValue) == id)
        #expect(id.description == id.rawValue)
        #expect(GroupID(GroupID.generate().rawValue) != nil)
    }

    /// The string form must be usable as a `<id>.ghsnap` basename and as `TKZMUX_SESSION_ID`.
    @Test func stringFormIsALegalFileBasenameAndEnvValue() {
        let raw = SessionID.generate().rawValue
        #expect(!raw.isEmpty)
        #expect(raw != "." && raw != "..")
        #expect(!raw.contains("/"))
        #expect(!raw.contains("\0"))
        #expect(!raw.contains("="))
        #expect(raw == raw.uppercased())
        #expect(raw.count == 36)
    }

    @Test func rejectsNonUUIDStrings() {
        #expect(SessionID("") == nil)
        #expect(SessionID("..") == nil)
        #expect(SessionID("a/b") == nil)
        #expect(SessionID("not-a-uuid") == nil)
    }

    @Test func codesAsAPlainString() throws {
        let id = SessionID.generate()
        let data = try JSONEncoder().encode(["id": id])
        #expect(String(data: data, encoding: .utf8) == #"{"id":"\#(id.rawValue)"}"#)
        let back = try JSONDecoder().decode([String: SessionID].self, from: data)
        #expect(back["id"] == id)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([String: SessionID].self, from: Data(#"{"id":"nope"}"#.utf8))
        }
    }

    @Test func sortsByStringForm() {
        let a = SessionID(uuid: Fixture.uuid(1))
        let b = SessionID(uuid: Fixture.uuid(2))
        #expect(a < b)
    }
}

@Suite struct ClaudeSessionInfoTests {
    /// A realistic descriptor, verbatim in the shape design.md → *Evidence* records, plus an
    /// unknown key that a future Claude Code version might add.
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

    @Test func mapsTheBackgroundKind() throws {
        let json = #"{"pid":2,"sessionId":"s","kind":"bg","parkedJobId":"job-4"}"#
        let info = try ClaudeSessionInfo.decode(Data(json.utf8), configDir: "~/.claude")
        #expect(info.isBackground)
        #expect(info.parkedJobId == "job-4")
    }

    /// A file rewritten in place can be read mid-write. Every truncation of a real descriptor must
    /// either decode or throw a `DecodingError` — never crash, never produce a half-built value.
    /// The watcher's contract (design.md → *Discovery*) is "torn JSON keeps the previous value".
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
        // …and it agrees with the fixture's sessions, which is the join M3 performs.
        let state = AppState.fixture
        for session in state.sessions.values {
            guard let descriptor = session.live?.descriptor else { continue }
            #expect(descriptor.accountKey == session.accountKey)
        }
    }
}

@Suite struct PersistenceShapeTests {
    /// `live` is process state; `state.json` must not carry it (design.md → *Session flows*).
    @Test func sessionCodingDropsLiveState() throws {
        var session = Session(groupID: .generate(), cwd: "~/dev/x", accountKey: "claude")
        session.live = LiveSessionState(pid: 42, status: .working)
        let data = try JSONEncoder().encode(session)
        let text = String(data: data, encoding: .utf8)!
        #expect(!text.contains("\"live\""))
        let back = try JSONDecoder().decode(Session.self, from: data)
        #expect(back.live == nil)
        #expect(back.status == .idle)  // a restored row is idle until it is first shown
        #expect(back.id == session.id)
        #expect(back.accountKey == "claude")
    }

    @Test func groupsPresetsAndAccountsRoundTrip() throws {
        let group = Group(name: "Repo", repoRoot: "~/dev/repo", color: RGB(hex: 0x41c6a8, alpha: 0.5),
                          isCollapsed: true, order: 3, defaultAccountKey: "claude-work")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(Group.self, from: encoder.encode(group)) == group)

        let preset = Preset(name: "wt", command: "claude -w", cwdMode: .worktree(name: "x"),
                            accountKey: "claude", env: ["A": "1"])
        #expect(try decoder.decode(Preset.self, from: encoder.encode(preset)) == preset)

        let account = Account(key: "claude", configDir: "~/.claude", label: "Claude", plan: "Max")
        #expect(try decoder.decode(Account.self, from: encoder.encode(account)) == account)

        for mode in [CwdMode.repoRoot, .worktree(name: nil), .fixed(path: "/tmp")] {
            #expect(try decoder.decode(CwdMode.self, from: encoder.encode(mode)) == mode)
        }
    }

    @Test func statusAndWaitReasonHaveStableNames() {
        #expect(SessionStatus.working.name == "working")
        #expect(SessionStatus.waiting(.doneUnattended).name == "waiting(doneUnattended)")
        #expect(SessionStatus.waiting(.permission).isWaiting)
        #expect(SessionStatus.idle.isWaiting == false)
        #expect(WaitReason.allCases.count == 4)
    }
}

@Suite struct UsageAndSidecarTests {
    /// The real `~/.claude/dash-usage-<key>.json` shape (design.md → *Evidence → Quota*).
    @Test func decodesADashUsageDocument() throws {
        let json = """
            {
              "updated_at": "2026-09-08T05:07:24.249Z",
              "account": {"key": "claude-work", "label": "Alt", "plan": "Team 5x",
                          "uuid": "9ea88c5d-0e4f-4847-9810-46137558a0b2",
                          "config_dir": "/Users/x/.claude-work"},
              "five_hour": {"used_percentage": 1, "resets_at": "2026-09-08T06:00:00.000Z"},
              "seven_day": {"used_percentage": 39, "resets_at": "2026-09-10T13:00:00.000Z"}
            }
            """
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.accountKey == "claude-work")
        #expect(snapshot.plan == "Team 5x")
        #expect(snapshot.sevenDay?.usedPercentage == 39)
        #expect(snapshot.fiveHour?.resetsAt != nil)
        #expect(snapshot.updatedAt != nil)
    }

    @Test func formatsTheResetCountdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UsageWindow(usedPercentage: 5, resetsAt: now.addingTimeInterval(4 * 86_400 + 12 * 3600))
            .resetsInText(now: now) == "4d 12h")
        #expect(UsageWindow(usedPercentage: 5, resetsAt: now.addingTimeInterval(3600 + 300))
            .resetsInText(now: now) == "1h 5m")
        #expect(UsageWindow(usedPercentage: 5, resetsAt: now.addingTimeInterval(120))
            .resetsInText(now: now) == "2m")
        #expect(UsageWindow(usedPercentage: 5).resetsInText(now: now) == nil)
    }

    @Test func decodesTheSessionSidecarContract() throws {
        let json = """
            {"updated_at":"2026-09-08T05:00:00.000Z","session_id":"s1","account_key":"claude",
             "context_used_percentage":62,"model":{"id":"claude-opus-5","display_name":"Opus 5"},
             "session_name":"pricing","workspace":{"git_worktree":"pricing","project_dir":"/repo",
             "repo":"repo"},"worktree":"pricing","pr":{"number":412,"state":"OPEN"},"cost":1.25,
             "unknown":"ignored"}
            """
        let sidecar = try JSONDecoder().decode(SessionSidecar.self, from: Data(json.utf8))
        #expect(sidecar.sessionId == "s1")
        #expect(sidecar.contextUsedPercentage == 62)
        #expect(sidecar.model?.displayName == "Opus 5")
        #expect(sidecar.workspace?.gitWorktree == "pricing")
        #expect(sidecar.pr?.number == 412)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SessionSidecar.self, from: Data(#"{"cost":1}"#.utf8))
        }
    }
}
