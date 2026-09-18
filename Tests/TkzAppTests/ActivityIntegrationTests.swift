// ActivityIntegrationTests — what `AgentIntegration` does to a feed entry's read flag when the
// hook lands on the row the user is looking at.

import Foundation
import Testing
import ClaudeBridge
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct ActivityIntegrationTests {
    typealias H = AgentIntegrationTests

    @Test("a Stop on the row the user is looking at lands read; elsewhere it stays unread")
    func stopReadWhenAttended() {
        let h = H.makeHarness()
        h.integration.handle(H.launch(h.session, pid: 4242))
        h.integration.isSessionAttended = { _ in true }
        h.integration.handle(H.hook(
            "Stop", sessionID: h.session, lastAssistantMessage: "seen", ppid: 4242, fullMessage: "seen"))
        h.store.flush()
        #expect(h.store.state.activity.map(\.unread) == [false])

        h.integration.isSessionAttended = { _ in false }
        h.integration.handle(H.hook(
            "Stop", sessionID: h.session, lastAssistantMessage: "unseen", ppid: 4242, fullMessage: "unseen"))
        h.store.flush()
        #expect(h.store.state.activity.map(\.unread) == [false, true])
    }

    @Test("a permission prompt on the attended row is read on arrival, without resetting attendance")
    func promptReadWhenAttended() {
        let h = H.makeHarness()
        h.integration.handle(H.launch(h.session, pid: 4242))
        h.integration.isSessionAttended = { _ in true }
        let attendedBefore = h.store.state.sessions[h.session]?.live?.attendedAt
        h.integration.handle(H.hook(
            "Notification", sessionID: h.session, notificationType: "permission_prompt", ppid: 4242))
        h.store.flush()
        #expect(h.store.state.activity.map(\.kind) == [.needsYou(reason: .permission, message: nil)])
        #expect(h.store.state.activity.map(\.unread) == [false])
        // Not `markAttended`: the prompt is still pending and the badge stays up.
        #expect(h.store.state.sessions[h.session]?.needsAttention == true)
        #expect(h.store.state.sessions[h.session]?.live?.attendedAt == attendedBefore)
    }
}
