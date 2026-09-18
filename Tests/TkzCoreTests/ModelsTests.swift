// The model contract: identifiers that round-trip as file basenames, and persisted shapes that
// keep `live` out. The descriptor parser's own tests (`ClaudeSessionInfo`) moved to
// `ClaudeBridgeTests` with the type itself (TKZ-81) — TkzCore no longer names it.

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

@Suite struct PersistenceShapeTests {
    /// `live` is process state; `state.json` must not carry it.
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

    @Test func groupsAndAccountsRoundTrip() throws {
        let group = Group(name: "Repo", repoRoot: "~/dev/repo", color: RGB(hex: 0x41c6a8, alpha: 0.5),
                          isCollapsed: true, order: 3, defaultAccountKey: "claude-work")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(Group.self, from: encoder.encode(group)) == group)

        let account = Account(key: "claude", configDir: "~/.claude", label: "Claude", plan: "Max")
        #expect(try decoder.decode(Account.self, from: encoder.encode(account)) == account)
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
    /// The real `~/.claude/dash-usage-<key>.json` shape.
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
