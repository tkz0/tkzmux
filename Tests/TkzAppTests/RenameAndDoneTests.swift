// RenameAndDoneTests — the two GUI-pass follow-ups of 2026-09-08 (M3.4 / TKZ-24):
// ⇧⌘R had no handler, and a fresh Stop drew as plain idle.

import AppKit
import Foundation
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct RenameAndDoneTests {

    @Test("⇧⌘R renames the selected session through the prompt; empty clears it")
    func renameThroughThePrompt() {
        let (harness, _) = MainWindowLaunchTests.makeHarness()
        let controller = harness.controller
        var state = AppState.startup(homeDirectory: "/tmp")
        let session = state.createSession(groupID: state.orderedGroups[0].id, cwd: "/tmp/app", accountKey: "claude")
        state.select(session.id)
        controller.store.update { $0 = state }

        var seen: String?
        controller.renamePrompt = { current in seen = current; return "review" }
        #expect(controller.dispatcher.perform(.renameSession))
        #expect(seen == "app")
        #expect(controller.store.state.sessions[session.id]?.displayTitle == "review")

        controller.renamePrompt = { _ in nil }
        controller.dispatcher.perform(.renameSession)
        #expect(controller.store.state.sessions[session.id]?.title == "review")

        controller.renamePrompt = { _ in "" }
        controller.dispatcher.perform(.renameSession)
        #expect(controller.store.state.sessions[session.id]?.displayTitle == "app")
    }

    @Test("a fresh unattended Stop draws as the done tint, not plain idle")
    func doneTint() {
        var state = AppState.startup(homeDirectory: "/tmp")
        let session = state.createSession(groupID: state.orderedGroups[0].id, cwd: "/tmp/app", accountKey: "claude")
        state.setLive(LiveSessionState(shellPid: 1, status: .idle), for: session.id)
        state.applyHook(HookEvent(kind: .stop, lastAssistantMessage: "ok"), to: session.id, now: Date())
        let row = SidebarRowAdapter.sessionModel(state.sessions[session.id]!, in: state)
        #expect(row.status == .done)
        #expect(row.needsAttention == false)

        state.markAttended(session.id)
        #expect(SidebarRowAdapter.sessionModel(state.sessions[session.id]!, in: state).status == .idle)

        let dot = StatusDotLayer()
        dot.configure(status: .done, theme: .default)
        #expect(dot.isPulsing == false)
    }
}
