// A background shell keeps the row pulsing and puts `⟳ 1 shell` on the status bar — the TkzApp
// half: the strip's mapping and drawing, and the descriptor + Stop flow through `AgentIntegration`.

import AppKit
import Foundation
import Testing
import AgentBridge
import TkzCore

@testable import TkzApp

@MainActor
struct BackgroundShellStatusBarTests {
    static func state(activity: AgentObservation.Activity, shells: [BackgroundShellInfo]) -> AppState {
        var state = AppState()
        let group = state.addGroup(name: "g")
        let session = state.createSession(groupID: group.id, cwd: "/tmp/g")
        var live = LiveSessionState(
            observation: AgentObservation(pid: 1, conversationId: "s", configDir: "~/.claude", activity: activity),
            status: .working)
        live.backgroundShells = shells
        state.setLive(live, for: session.id)
        state.select(session.id)
        return state
    }

    @Test func listedShellsBecomeACountAndATooltip() {
        let model = MainWindowController.statusModel(for: Self.state(activity: .backgroundShell, shells: [
            BackgroundShellInfo(id: "b1", description: "Watch build 8182", command: "until …; done"),
            BackgroundShellInfo(id: "b2", command: "npm run dev"),
        ]))
        #expect(model.runningShells == 2)
        #expect(model.runningShellsTooltip == """
            2 background shells still running
            • Watch build 8182
            • npm run dev
            """)
    }

    /// The descriptor says `shell` but no `Stop` has listed any (hooks missing, an older shim).
    @Test func anUnlistedShellIsStillASegment() {
        let model = MainWindowController.statusModel(for: Self.state(activity: .backgroundShell, shells: []))
        #expect(model.runningShells == 0)
        #expect(model.runningShellsTooltip == "A background shell is still running")
    }

    /// A stored list outliving its shells never shows: the descriptor is what says they run.
    @Test func noSegmentUnlessTheDescriptorSaysShell() {
        let shells = [BackgroundShellInfo(id: "b1", command: "sleep 25")]
        for activity: AgentObservation.Activity in [.idle, .busy] {
            let model = MainWindowController.statusModel(for: Self.state(activity: activity, shells: shells))
            #expect(model.runningShells == nil)
            #expect(model.runningShellsTooltip == nil)
        }
    }

    @Test func theSegmentIsInTheWorkingGreen() throws {
        var model = StatusBarModel(branch: "main", modelName: "Opus 5.5", diffAdded: 3, diffRemoved: 1)
        model.runningShells = 1
        model.runningShellsTooltip = "1 background shell still running"
        for theme in Theme.allPresets {
            let items = StatusBarView.items(for: model, theme: theme)
            #expect(items.map(\.segment.plainText) == ["\u{2387} main", "OPUS 5.5", "\u{27F3} 1 shell", "+3 \u{2212}1"])
            let segment = try #require(items.first { $0.segment.plainText.hasPrefix("\u{27F3}") })
            #expect(segment.segment.colors == [theme.working])
            #expect(segment.tooltip == "1 background shell still running")
        }
        model.runningShells = 3
        #expect(StatusBarView.items(for: model, theme: .default).contains { $0.segment.plainText == "\u{27F3} 3 shells" })
        model.runningShells = 0
        #expect(StatusBarView.items(for: model, theme: .default).contains { $0.segment.plainText == "\u{27F3} shell" })
    }
}

@MainActor
@Suite(.serialized)
struct BackgroundShellIntegrationTests {
    static func stop(session: SessionID, tasks: [HookBackgroundTask]) -> HookFrame {
        .hook(
            HookPayload(
                eventName: "Stop", sessionId: "claude-sid", lastAssistantMessage: "Waiting on build 8182.",
                backgroundTasks: tasks),
            sessionID: session, ppid: 4242, fullMessage: "Waiting on build 8182.")
    }

    /// The reported flow: Claude backgrounds a CI watcher, ends its turn, the watcher exits later.
    @Test func aBackgroundShellKeepsTheRowWorkingUntilItExits() {
        let h = AgentIntegrationTests.makeHarness()
        h.integration.handle(AgentIntegrationTests.launch(h.session, pid: 4242))
        AgentIntegrationTests.apply(
            h.integration, AgentIntegrationTests.descriptor(pid: 4242, status: .busy), alive: true)
        h.integration.handle(Self.stop(session: h.session, tasks: [
            HookBackgroundTask(
                id: "b1", type: "shell", status: "running", description: "Watch build 8182",
                command: "until out=$(az pipelines runs list …); do sleep 60; done"),
        ]))
        AgentIntegrationTests.apply(
            h.integration, AgentIntegrationTests.descriptor(pid: 4242, status: .shell), alive: true)

        var live = h.store.state.sessions[h.session]?.live
        #expect(live?.status == .working)
        #expect(live?.attention == false)
        #expect(live?.backgroundShells.map(\.id) == ["b1"])
        #expect(h.store.state.summaryCounts.working == 1)

        AgentIntegrationTests.apply(
            h.integration, AgentIntegrationTests.descriptor(pid: 4242, status: .idle), alive: true)
        live = h.store.state.sessions[h.session]?.live
        #expect(live?.status == .idle)
        #expect(live?.isDone == true)
        #expect(live?.backgroundShells.isEmpty == true)
    }

    /// On the row the user is watching, the shell exiting is attended the way a `Stop` is.
    @Test func theShellExitingOnAWatchedRowIsAttended() {
        let h = AgentIntegrationTests.makeHarness()
        h.integration.isSessionAttended = { _ in true }
        h.integration.handle(AgentIntegrationTests.launch(h.session, pid: 4242))
        AgentIntegrationTests.apply(
            h.integration, AgentIntegrationTests.descriptor(pid: 4242, status: .busy), alive: true)
        h.integration.handle(Self.stop(session: h.session, tasks: []))
        AgentIntegrationTests.apply(
            h.integration, AgentIntegrationTests.descriptor(pid: 4242, status: .shell), alive: true)
        AgentIntegrationTests.apply(
            h.integration, AgentIntegrationTests.descriptor(pid: 4242, status: .idle), alive: true)

        let live = h.store.state.sessions[h.session]?.live
        #expect(live?.status == .idle)
        #expect(live?.isDone == false)
        #expect(live?.attendedAt == live?.lastStopAt)
    }
}
