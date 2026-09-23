// Sub-agent tracking, AgentBridge half: Claude Code's `SubagentStart` / `SubagentStop` and the
// `background_tasks` list its `Stop` carries, from the captured payloads in `Fixtures/hooks/`
// (Claude Code 2.1.280, 2026-09-23; paths anonymised) through `HookServer`'s real parser and
// `ClaudeHookMapper`, plus the sub-agent transcript lookup the stale sweep uses.
import Foundation
import Testing
import TkzCore

@testable import AgentBridge

@Suite struct SubagentHookTests {
    private static func frame(fixture name: String, event: String) throws -> HookPayload {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hooks/\(name)")
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let envelope: [String: Any] = ["v": 1, "type": "hook", "event": event, "sid": "", "payload": payload]
        guard case .hook(let hookPayload, _, _, _) = HookServer.parseHookFrame(envelope) else {
            throw CocoaError(.coderInvalidValue)
        }
        return hookPayload
    }

    // MARK: - Parsing

    @Test func subagentStartLiftsAgentIdAndType() throws {
        let payload = try Self.frame(fixture: "subagent_start.json", event: "SubagentStart")
        #expect(payload.eventName == "SubagentStart")
        #expect(payload.agentId == "a19f6a0e7f3474257")
        #expect(payload.agentType == "general-purpose")
        #expect(payload.backgroundTasks == nil)
    }

    @Test func stopLiftsBackgroundTasks() throws {
        let payload = try Self.frame(fixture: "stop_background_tasks.json", event: "Stop")
        #expect(payload.backgroundTasks == [
            HookBackgroundTask(
                id: "b4uo0szea", type: "shell", status: "running",
                description: "Sleep for 25 seconds in background"),
            HookBackgroundTask(
                id: "a19f6a0e7f3474257", type: "subagent", status: "running",
                description: "Run sleep and respond", agentType: "general-purpose"),
        ])
    }

    /// The old fixture predates the field: absent is `nil`, not `[]`, so it cannot wipe the set.
    @Test func stopWithoutBackgroundTasksIsNotAnEmptyList() throws {
        let payload = try Self.frame(fixture: "stop.json", event: "Stop")
        #expect(payload.backgroundTasks == nil)
    }

    @Test func backgroundTaskEntriesWithoutAnIdAreSkipped() {
        let tasks = HookServer.backgroundTasks([
            ["type": "subagent"], ["id": "", "type": "subagent"], "junk", ["id": "a1", "type": "subagent"],
        ])
        #expect(tasks == [HookBackgroundTask(id: "a1", type: "subagent")])
        #expect(HookServer.backgroundTasks("not a list") == nil)
    }

    // MARK: - Mapping

    @Test func subagentStartMapsToStarted() throws {
        let event = ClaudeHookMapper.map(try Self.frame(fixture: "subagent_start.json", event: "SubagentStart"))
        #expect(event?.kind == .subagentStarted(SubagentInfo(id: "a19f6a0e7f3474257", type: "general-purpose")))
        #expect(event?.runningSubagents == nil)
    }

    /// `SubagentStop` carries the sub-agent's own last message and a running list that still names
    /// the agent that is stopping. Neither may reach the session: the first is not its recap, the
    /// second would keep the stopped agent running.
    @Test func subagentStopMapsToStoppedAndDropsItsMessageAndList() throws {
        let event = ClaudeHookMapper.map(try Self.frame(fixture: "subagent_stop.json", event: "SubagentStop"))
        #expect(event?.kind == .subagentStopped(id: "a19f6a0e7f3474257"))
        #expect(event?.lastAssistantMessage == nil)
        #expect(event?.runningSubagents == nil)
    }

    @Test func subagentEventsWithoutAnAgentIdAreUnknown() {
        #expect(ClaudeHookMapper.map(HookPayload(eventName: "SubagentStart"))?.kind == .unknown("SubagentStart"))
        #expect(ClaudeHookMapper.map(HookPayload(eventName: "SubagentStop", agentId: ""))?.kind == .unknown("SubagentStop"))
    }

    /// Only sub-agents make the snapshot — background shells are deliberately not tracked.
    @Test func stopSnapshotKeepsSubagentsOnly() throws {
        let event = ClaudeHookMapper.map(try Self.frame(fixture: "stop_background_tasks.json", event: "Stop"))
        #expect(event?.kind == .turnEnded)
        #expect(event?.lastAssistantMessage == "waiting")
        #expect(event?.runningSubagents == [
            SubagentInfo(id: "a19f6a0e7f3474257", type: "general-purpose", description: "Run sleep and respond")
        ])
    }

    @Test func stopSnapshotDropsFinishedSubagents() {
        let event = ClaudeHookMapper.map(HookPayload(
            eventName: "Stop",
            backgroundTasks: [
                HookBackgroundTask(id: "done", type: "subagent", status: "completed"),
                HookBackgroundTask(id: "live", type: "subagent", status: "running"),
                HookBackgroundTask(id: "nostatus", type: "subagent"),
            ]))
        #expect(event?.runningSubagents?.map(\.id) == ["live", "nostatus"])
    }

    @Test func stopWithAnEmptyListIsAnEmptySnapshot() {
        let event = ClaudeHookMapper.map(HookPayload(eventName: "Stop", backgroundTasks: []))
        #expect(event?.runningSubagents == [])
    }

    // MARK: - Sub-agent transcripts

    @Test func subagentTranscriptPathSitsBesideTheSessionTranscript() {
        #expect(ClaudeTranscriptProvider.subagentTranscriptPath(
            transcriptPath: "/p/-dev-x/abc.jsonl", agentId: "a1") == "/p/-dev-x/abc/subagents/agent-a1.jsonl")
        #expect(ClaudeTranscriptProvider.subagentTranscriptPath(transcriptPath: "/p/abc.jsonl", agentId: "../x") == nil)
        #expect(ClaudeTranscriptProvider.subagentTranscriptPath(transcriptPath: "/p/abc.jsonl", agentId: "") == nil)
        #expect(ClaudeTranscriptProvider.subagentTranscriptPath(transcriptPath: "/p/abc.txt", agentId: "a1") == nil)
    }

    @Test func subagentActivityReportsTranscriptMtimes() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("subagents-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let subagents = root.appendingPathComponent("abc/subagents")
        try fileManager.createDirectory(at: subagents, withIntermediateDirectories: true)
        let file = subagents.appendingPathComponent("agent-a1.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        try fileManager.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)

        let activity = ClaudeTranscriptProvider().subagentActivity(
            transcriptPath: root.appendingPathComponent("abc.jsonl").path,
            subagentIds: ["a1", "missing"], fileManager: fileManager)
        #expect(activity == ["a1": stamp])
    }
}
