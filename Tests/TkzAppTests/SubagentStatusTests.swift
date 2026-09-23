// Sub-agents keep the row pulsing and put `⟳ N agents` on the status bar — the TkzApp half: the
// strip's mapping and drawing, and the hook frames end to end through `AgentIntegration`.

import AppKit
import Foundation
import Testing
import AgentBridge
import TkzCore

@testable import TkzApp

@MainActor
struct SubagentStatusBarTests {
    static func state(running: [String: RunningSubagent]) -> AppState {
        var state = AppState()
        let group = state.addGroup(name: "g")
        let session = state.createSession(groupID: group.id, cwd: "/tmp/g")
        var live = LiveSessionState(status: .working)
        live.runningSubagents = running
        state.setLive(live, for: session.id)
        state.select(session.id)
        return state
    }

    @Test func runningSubagentsBecomeACountAndATooltip() {
        let t0 = Fixture.now
        let model = MainWindowController.statusModel(for: Self.state(running: [
            "b": RunningSubagent(
                info: SubagentInfo(id: "b", type: "Plan", description: "Plan the migration"),
                startedAt: t0.addingTimeInterval(5)),
            "a": RunningSubagent(
                info: SubagentInfo(id: "a", type: "Explore", description: "Find the hook mapper"), startedAt: t0),
            "c": RunningSubagent(info: SubagentInfo(id: "c"), startedAt: t0.addingTimeInterval(9)),
        ]))
        #expect(model.runningAgents == 3)
        #expect(model.runningAgentsTooltip == """
            3 sub-agents still running
            • Find the hook mapper (Explore)
            • Plan the migration (Plan)
            • agent
            """)
    }

    @Test func noSubagentsIsNoSegment() {
        let model = MainWindowController.statusModel(for: Self.state(running: [:]))
        #expect(model.runningAgents == nil)
        #expect(model.runningAgentsTooltip == nil)
        let items = StatusBarView.items(for: StatusBarModel(branch: "main", modelName: "Opus 5.5"), theme: .default)
        #expect(!items.contains { $0.segment.plainText.contains("\u{27F3}") })
    }

    @Test func theSegmentFollowsTheModelPillInTheWorkingGreen() throws {
        var model = StatusBarModel(branch: "main", modelName: "Opus 5.5", diffAdded: 3, diffRemoved: 1)
        model.runningAgents = 1
        model.runningAgentsTooltip = "1 sub-agent still running"
        for theme in Theme.allPresets {
            let items = StatusBarView.items(for: model, theme: theme)
            #expect(items.map(\.segment.plainText) == ["\u{2387} main", "OPUS 5.5", "\u{27F3} 1 agent", "+3 \u{2212}1"])
            let segment = try #require(items.first { $0.segment.plainText.hasPrefix("\u{27F3}") })
            #expect(segment.segment.colors == [theme.working])
            #expect(segment.tooltip == "1 sub-agent still running")
            #expect(segment.action == nil)
        }
        model.runningAgents = 4
        #expect(StatusBarView.items(for: model, theme: .default).contains { $0.segment.plainText == "\u{27F3} 4 agents" })
    }
}

@MainActor
@Suite(.serialized)
struct SubagentIntegrationTests {
    static func frame(
        _ eventName: String, session: SessionID, agentId: String? = nil, agentType: String? = nil,
        backgroundTasks: [HookBackgroundTask]? = nil, lastAssistantMessage: String? = nil
    ) -> HookFrame {
        .hook(
            HookPayload(
                eventName: eventName, sessionId: "claude-sid", lastAssistantMessage: lastAssistantMessage,
                agentId: agentId, agentType: agentType, backgroundTasks: backgroundTasks),
            sessionID: session, ppid: 4242, fullMessage: lastAssistantMessage)
    }

    /// The reported flow: Claude backgrounds an agent, ends its turn, the agent finishes later.
    @Test func aBackgroundedAgentKeepsTheRowWorkingUntilItFinishes() {
        let h = AgentIntegrationTests.makeHarness()
        h.integration.handle(AgentIntegrationTests.launch(h.session, pid: 4242))
        AgentIntegrationTests.apply(
            h.integration, AgentIntegrationTests.descriptor(pid: 4242, status: .busy), alive: true)

        h.integration.handle(Self.frame("SubagentStart", session: h.session, agentId: "a1", agentType: "Explore"))
        h.integration.handle(Self.frame(
            "Stop", session: h.session,
            backgroundTasks: [
                HookBackgroundTask(id: "a1", type: "subagent", status: "running", description: "Look around", agentType: "Explore"),
                HookBackgroundTask(id: "b1", type: "shell", status: "running", description: "Dev server"),
            ],
            lastAssistantMessage: "Waiting on the agent."))
        AgentIntegrationTests.apply(
            h.integration, AgentIntegrationTests.descriptor(pid: 4242, status: .idle), alive: true)

        var live = h.store.state.sessions[h.session]?.live
        #expect(live?.status == .working)
        #expect(live?.runningSubagents.keys.sorted() == ["a1"], "the shell is not tracked")
        #expect(live?.runningSubagents["a1"]?.info.description == "Look around")
        #expect(h.store.state.summaryCounts.working == 1)

        h.integration.handle(Self.frame(
            "SubagentStop", session: h.session, agentId: "a1",
            backgroundTasks: [HookBackgroundTask(id: "a1", type: "subagent", status: "running")],
            lastAssistantMessage: "sub-agent's own answer"))
        live = h.store.state.sessions[h.session]?.live
        #expect(live?.runningSubagents.isEmpty == true)
        #expect(live?.status == .idle)
        #expect(live?.isDone == true)
        #expect(live?.attention == false)
        // The sub-agent's words are not the session's recap.
        #expect(live?.lastStopMessage == "Waiting on the agent.")
        #expect(h.integration.lastMessage(for: h.session) == "Waiting on the agent.")
    }
}
