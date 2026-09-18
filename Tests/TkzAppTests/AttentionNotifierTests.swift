// AttentionNotifierTests — the sidebar's two signals as macOS notifications.
//
// A real `AppStore` drives a real `AttentionNotifier`; the one seam that would reach macOS — the
// notification centre — is a recording fake. Every flip goes through the same reducers the hooks
// use (`applyEvent`, `markAttended`, `rederiveStatuses`), so the tests assert the rule ("a change
// from a known state, on a row you are not looking at") and not a mock of it.

import AppKit
import Foundation
import Testing
import TkzCore

@testable import TkzApp

@MainActor
private final class FakePresenter: NotificationPresenting {
    var requests: [NotificationRequest] = []
    var dismissed: [String] = []
    var authorizationRequests = 0
    var onActivate: (@MainActor (String) -> Void)?
    var onDenied: (@MainActor () -> Void)?

    func present(_ request: NotificationRequest, delivered: @escaping @MainActor (Bool) -> Void) {
        requests.append(request)
        delivered(true)
    }

    func dismiss(identifier: String) { dismissed.append(identifier) }
    func requestAuthorization() { authorizationRequests += 1 }
}

@MainActor
private struct Rig {
    let store: AppStore
    let notifier: AttentionNotifier
    let presenter = FakePresenter()
    let ids: [SessionID]
    let now = Date(timeIntervalSince1970: 1_788_944_400)

    /// `count` rows in one group, each with idle live state unless `live` is false (a restored
    /// row before its descriptor arrives).
    init(count: Int = 2, live: Bool = true, done: Bool = true) {
        var state = AppState()
        state.setNotifyOnDone(done)
        let group = state.addGroup(name: "g")
        var ids: [SessionID] = []
        for n in 0..<count {
            let session = state.createSession(groupID: group.id, cwd: "/tmp/row\(n)")
            if live { state.setLive(LiveSessionState(status: .idle), for: session.id) }
            ids.append(session.id)
        }
        self.ids = ids
        store = AppStore(state: state)
        notifier = AttentionNotifier(store: store, presenter: presenter)
    }

    func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    /// One `Notification` hook, delivered, already mapped to the `AttentionKind` the mapper would
    /// have produced from Claude's own `notification_type` string.
    func prompt(
        _ id: SessionID, _ kind: AttentionKind = .permission,
        message: String? = nil, after seconds: TimeInterval = 0
    ) {
        store.update {
            $0.applyEvent(
                AgentEvent(kind: .attention(kind), message: message),
                to: id, now: at(seconds))
        }
        store.flush()
    }

    /// A `Stop` hook, delivered — `attended` models `ClaudeIntegration`, which marks a Stop on the
    /// row the user is looking at attended in the same mutation. Timestamps must move forward:
    /// the derivation reads a Stop as attended when it is not strictly newer than `attendedAt`.
    func stop(_ id: SessionID, message: String = "done", attended: Bool = false, after seconds: TimeInterval = 0) {
        store.update { state in
            state.applyEvent(AgentEvent(kind: .turnEnded, lastAssistantMessage: message), to: id, now: at(seconds))
            if attended { state.markAttended(id, now: at(seconds)) }
        }
        store.flush()
    }

    /// The prompt was answered: `UserPromptSubmit` clears the pending notification, and with it
    /// the badge. (`markAttended` alone would not — the derivation re-raises a pending prompt.)
    func answer(_ id: SessionID, after seconds: TimeInterval = 0) {
        store.update { $0.applyEvent(AgentEvent(kind: .promptSubmitted), to: id, now: at(seconds)) }
        store.flush()
    }

    /// The user selected the row in a key, visible window: what `windowDidBecomeKey` / `select`
    /// do, with the window's attended check saying yes for this row from now on.
    func look(at id: SessionID, after seconds: TimeInterval = 0) {
        notifier.isSessionAttended = { $0 == id }
        store.update { $0.markAttended(id, now: at(seconds)) }
        store.flush()
    }

    func banner(for id: SessionID) -> String { AttentionNotifier.identifier(for: id) }
}

@MainActor
@Suite(.serialized)
struct AttentionNotifierTests {
    @Test("a permission prompt on a row you are not looking at posts one banner with Claude's line")
    func needsYouFiresOnceWithTheHookMessage() {
        let rig = Rig()
        rig.prompt(rig.ids[0], message: "Claude needs your permission to use Bash")

        #expect(rig.presenter.requests.count == 1)
        let request = rig.presenter.requests[0]
        #expect(request.identifier == rig.banner(for: rig.ids[0]))
        #expect(request.title == "row0")
        #expect(request.body == "Claude needs your permission to use Bash")
        #expect(rig.notifier.presented[request.identifier] == [rig.ids[0]])

        // Still NEEDS YOU, another delivery for the same row: not a new event.
        rig.prompt(rig.ids[0], .question, after: 1)
        #expect(rig.presenter.requests.count == 1)

        // Answered, then blocked again: that *is* a new event, under the same identifier.
        rig.answer(rig.ids[0], after: 2)
        #expect(rig.presenter.dismissed == [request.identifier])
        rig.prompt(rig.ids[0], after: 3)
        #expect(rig.presenter.requests.count == 2)
        #expect(rig.presenter.requests[1].identifier == request.identifier)
    }

    @Test("without a hook message the body names the reason")
    func fallbackBodyPerReason() {
        let cases: [(AttentionKind, String)] = [
            (.permission, "Claude is waiting for permission"),
            (.question, "Claude is asking you a question"),
            (.agentInput, "Claude needs your input"),
        ]
        for (kind, body) in cases {
            let rig = Rig(count: 1)
            rig.prompt(rig.ids[0], kind)
            #expect(rig.presenter.requests.map(\.body) == [body])
        }
    }

    @Test("Claude finishing in a row you are not looking at is one banner that outlives the 60 s ageing")
    func doneIsOneBanner() {
        let rig = Rig()
        rig.stop(rig.ids[0], message: "  \nAll green.\nDetails follow.")
        #expect(rig.presenter.requests.count == 1)
        let request = rig.presenter.requests[0]
        #expect(request.identifier == rig.banner(for: rig.ids[0]))
        #expect(request.title == "row0")
        #expect(request.body == "Finished: All green.")

        // Still done, another Stop: not a new event.
        rig.stop(rig.ids[0], after: 5)
        #expect(rig.presenter.requests.count == 1)

        // Ageing into NEEDS YOU keeps the same banner: nothing new, nothing dismissed.
        rig.store.update { $0.rederiveStatuses(now: rig.at(70)) }
        rig.store.flush()
        #expect(rig.store.state.sessions[rig.ids[0]]?.needsAttention == true)
        #expect(rig.presenter.requests.count == 1)
        #expect(rig.presenter.dismissed.isEmpty)

        // A Stop on the row being looked at is attended in the same mutation: no tint, no banner.
        rig.stop(rig.ids[1], attended: true, after: 80)
        #expect(rig.presenter.requests.count == 1)

        // No message at all: a plain line.
        let bare = Rig(count: 1)
        bare.store.update { $0.applyEvent(AgentEvent(kind: .turnEnded), to: bare.ids[0], now: bare.now) }
        bare.store.flush()
        #expect(bare.presenter.requests.map(\.body) == ["Claude finished"])
    }

    @Test("a prompt after a finish replaces the done banner; answering it takes the banner away")
    func oneBannerPerRow() {
        let rig = Rig(count: 1)
        rig.stop(rig.ids[0])
        rig.prompt(rig.ids[0], message: "Claude needs your permission to use Bash", after: 1)
        #expect(rig.presenter.requests.map(\.body) == ["Finished: done", "Claude needs your permission to use Bash"])
        #expect(rig.presenter.requests.map(\.identifier) == [rig.banner(for: rig.ids[0]), rig.banner(for: rig.ids[0])])
        #expect(rig.presenter.dismissed == [rig.banner(for: rig.ids[0])], "superseded, so taken back before the new one")
        #expect(rig.notifier.presented.count == 1)

        rig.answer(rig.ids[0], after: 2)
        #expect(rig.presenter.dismissed.count == 2)
        #expect(rig.notifier.presented.isEmpty)
    }

    @Test("the row the user is looking at posts nothing; any other row does")
    func attendedRowIsSilent() {
        let rig = Rig()
        rig.notifier.isSessionAttended = { $0 == rig.ids[0] }
        rig.prompt(rig.ids[0])
        #expect(rig.presenter.requests.isEmpty)
        rig.prompt(rig.ids[1])
        #expect(rig.presenter.requests.map(\.title) == ["row1"])
    }

    @Test("a row whose first live state is already waiting does not fire — only a change from a known state does")
    func noFireOnFirstLiveState() {
        let rig = Rig(count: 1, live: false)
        rig.store.update { state in
            state.setLive(LiveSessionState(status: .idle), for: rig.ids[0])
            state.applyEvent(
                AgentEvent(kind: .attention(.permission)),
                to: rig.ids[0], now: rig.now)
        }
        rig.store.flush()
        #expect(rig.store.state.sessions[rig.ids[0]]?.needsAttention == true)
        #expect(rig.presenter.requests.isEmpty, "a relaunch with a waiting row is not an event")

        rig.answer(rig.ids[0], after: 1)
        rig.prompt(rig.ids[0], after: 2)
        #expect(rig.presenter.requests.count == 1)
    }

    @Test("looking at the row takes its banner back while the badge, rightly, stays on")
    func lookingAtTheRowDismisses() {
        let rig = Rig()
        rig.prompt(rig.ids[0])
        let identifier = rig.presenter.requests[0].identifier

        rig.look(at: rig.ids[0], after: 1)
        #expect(rig.presenter.dismissed == [identifier])
        #expect(rig.notifier.presented.isEmpty)
        #expect(rig.store.state.sessions[rig.ids[0]]?.needsAttention == true, "the prompt is still up")

        // Still looking, still pending: nothing new. Another row: business as usual.
        rig.prompt(rig.ids[0], .question, after: 2)
        #expect(rig.presenter.requests.count == 1)
        rig.prompt(rig.ids[1], after: 3)
        #expect(rig.presenter.requests.map(\.title) == ["row0", "row1"])
    }

    @Test("two rows in one delivery share one banner; answering either takes it back")
    func batchCoalesces() {
        let rig = Rig()
        rig.store.update { state in
            for id in rig.ids {
                state.applyEvent(
                    AgentEvent(kind: .attention(.permission)),
                    to: id, now: rig.now)
            }
        }
        rig.store.flush()

        #expect(rig.presenter.requests.count == 1)
        let request = rig.presenter.requests[0]
        #expect(request.identifier.hasPrefix("needs-you.batch."))
        #expect(request.title == "2 sessions need you")
        #expect(request.body == "row0, row1")
        #expect(rig.notifier.presented[request.identifier] == rig.ids)

        rig.answer(rig.ids[1], after: 1)
        #expect(rig.presenter.dismissed == [request.identifier])
        #expect(rig.notifier.presented.isEmpty)
    }

    @Test("a muted row posts nothing, muting takes its banner back, unmuting resumes")
    func mute() {
        let rig = Rig()
        rig.prompt(rig.ids[0])
        let identifier = rig.banner(for: rig.ids[0])
        #expect(rig.notifier.presented[identifier] == [rig.ids[0]])

        rig.store.update { $0.setNotificationsMuted(rig.ids[0], true) }
        rig.store.flush()
        #expect(rig.presenter.dismissed == [identifier])
        #expect(rig.notifier.presented.isEmpty)
        #expect(rig.store.state.sessions[rig.ids[0]]?.needsAttention == true, "the badge is not muted")

        // Answered and prompted again while muted: silence. Finished while muted: silence.
        rig.answer(rig.ids[0], after: 1)
        rig.prompt(rig.ids[0], after: 2)
        rig.answer(rig.ids[0], after: 3)
        rig.stop(rig.ids[0], after: 4)
        #expect(rig.presenter.requests.count == 1)
        // The other row is unaffected, and a batch leaves the muted row out.
        rig.answer(rig.ids[0], after: 5)
        rig.store.update { state in
            for id in rig.ids {
                state.applyEvent(
                    AgentEvent(kind: .attention(.permission)),
                    to: id, now: rig.at(6))
            }
        }
        rig.store.flush()
        #expect(rig.presenter.requests.count == 2)
        #expect(rig.presenter.requests[1].identifier == rig.banner(for: rig.ids[1]))

        // Unmuted: the next event posts again.
        rig.store.update { $0.setNotificationsMuted(rig.ids[0], false) }
        rig.store.flush()
        rig.answer(rig.ids[0], after: 7)
        rig.prompt(rig.ids[0], after: 8)
        #expect(rig.presenter.requests.count == 3)
        #expect(rig.presenter.requests[2].identifier == identifier)
    }

    @Test("the row's context menu offers Mute, then Unmute, and flips the flag")
    func contextMenuMute() {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let id = harness.store.state.orderedSessions[0].id

        func muteItem() -> NSMenuItem? {
            harness.controller.sessionContextMenu(for: id)?.items
                .first { $0.identifier == MainWindowController.ContextItemID.toggleMute }
        }
        let mute = muteItem()
        #expect(mute?.title == "Mute Notifications")
        NSApp.sendAction(mute!.action!, to: mute!.target, from: mute!)
        harness.store.flush()
        #expect(harness.store.state.sessions[id]?.notificationsMuted == true)

        let unmute = muteItem()
        #expect(unmute?.title == "Unmute Notifications")
        NSApp.sendAction(unmute!.action!, to: unmute!.target, from: unmute!)
        harness.store.flush()
        #expect(harness.store.state.sessions[id]?.notificationsMuted == nil)
    }

    @Test("removing the row takes its banner back")
    func removalDismisses() {
        let rig = Rig()
        rig.prompt(rig.ids[1])
        rig.store.update { $0.removeSession(rig.ids[1]) }
        rig.store.flush()
        #expect(rig.presenter.dismissed == [rig.banner(for: rig.ids[1])])
        #expect(rig.notifier.presented.isEmpty)
    }

    @Test("the finished switch gates only its own banner; NEEDS YOU always posts")
    func doneSwitch() {
        let rig = Rig(count: 2, done: false)
        #expect(rig.presenter.authorizationRequests == 1, "asked at launch regardless of the switch")
        rig.stop(rig.ids[0])
        #expect(rig.presenter.requests.isEmpty)
        rig.prompt(rig.ids[1], after: 1)
        #expect(rig.presenter.requests.count == 1)

        // Turning it off takes the finished banners back and leaves the NEEDS YOU ones alone.
        let on = Rig(count: 2)
        on.stop(on.ids[0])
        on.prompt(on.ids[1], after: 1)
        #expect(on.presenter.requests.count == 2)
        on.store.update { $0.setNotifyOnDone(false) }
        on.store.flush()
        #expect(on.presenter.dismissed == [on.banner(for: on.ids[0])])
        #expect(on.notifier.presented.keys.sorted() == [on.banner(for: on.ids[1])])
    }

    @Test("a click resolves to the row — the first still waiting for a batch, decoded for a stale banner")
    func activation() {
        let rig = Rig(count: 3)
        var activated: [SessionID] = []
        rig.notifier.onActivate = { activated.append($0) }

        rig.store.update { state in
            for id in rig.ids.prefix(2) {
                state.applyEvent(
                    AgentEvent(kind: .attention(.permission)),
                    to: id, now: rig.now)
            }
        }
        rig.store.flush()
        let batch = rig.presenter.requests[0].identifier
        rig.presenter.onActivate?(batch)
        #expect(activated == [rig.ids[0]])

        // A banner from before a relaunch: nothing remembered, the identifier still names the row.
        rig.presenter.onActivate?(rig.banner(for: rig.ids[2]))
        #expect(activated == [rig.ids[0], rig.ids[2]])

        rig.presenter.onActivate?("session.not-a-row")
        rig.presenter.onActivate?("something-else")
        #expect(activated.count == 2)
    }

    @Test("a refusal from macOS is surfaced once")
    func deniedIsSurfacedOnce() {
        let rig = Rig()
        var notices = 0
        rig.notifier.onDenied = { notices += 1 }
        rig.presenter.onDenied?()
        rig.presenter.onDenied?()
        #expect(notices == 1)
    }

    @Test("the window lends the notifier its attended check and reveals the clicked row")
    func windowWiring() {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let presenter = FakePresenter()
        let notifier = AttentionNotifier(store: harness.store, presenter: presenter)
        harness.controller.attention = notifier

        var hidden: SessionID?
        harness.mutate { state in
            let group = state.addGroup(name: "hidden")
            hidden = state.createSession(groupID: group.id, cwd: "/tmp/hidden").id
            state.setGroupCollapsed(group.id, true)
        }
        let id = hidden!
        #expect(harness.store.state.selection != id)

        notifier.onActivate?(id)
        harness.store.flush()
        #expect(harness.store.state.selection == id)
        #expect(harness.store.state.groups[harness.store.state.sessions[id]!.groupID]?.isCollapsed == false)
        // Nothing is key in a test run, so the window's check says "not attended" for every row.
        #expect(notifier.isSessionAttended(id) == false)
        #expect(notifier.onDenied != nil)
    }
}
