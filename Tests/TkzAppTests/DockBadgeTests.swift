// DockBadgeTests — the NEEDS YOU count on the Dock icon (TKZ-67).
//
// A real `AppStore` drives a real `DockBadge`; the Dock tile is a recording fake, so nothing here
// reaches `NSApp`. Every flip goes through the reducers the hooks use (`applyEvent`,
// `rederiveStatuses`), so the tests assert the count the strip shows, not a hand-set status.

import Foundation
import Testing
import TkzCore

@testable import TkzApp

@MainActor
private final class FakeTile: DockTileBadging {
    /// Every value written, in order — a write that does not change the label is a bug.
    var writes: [String?] = []
    var badgeLabel: String? {
        didSet { writes.append(badgeLabel) }
    }
}

@MainActor
private struct Rig {
    let store: AppStore
    let badge: DockBadge
    let tile = FakeTile()
    let ids: [SessionID]
    let now = Date(timeIntervalSince1970: 1_788_944_400)

    /// `count` idle rows in one group. `prepare` runs on the state before the badge exists, for
    /// the launch case.
    init(count: Int = 2, prepare: (inout AppState, [SessionID]) -> Void = { _, _ in }) {
        var state = AppState()
        let group = state.addGroup(name: "g")
        var ids: [SessionID] = []
        for n in 0..<count {
            let session = state.createSession(groupID: group.id, cwd: "/tmp/row\(n)")
            state.setLive(LiveSessionState(status: .idle), for: session.id)
            ids.append(session.id)
        }
        prepare(&state, ids)
        self.ids = ids
        store = AppStore(state: state)
        badge = DockBadge(store: store, tile: tile)
    }

    func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    func prompt(_ id: SessionID, after seconds: TimeInterval = 0) {
        store.update { $0.applyEvent(AgentEvent(kind: .attention(.permission)), to: id, now: at(seconds)) }
        store.flush()
    }

    /// `UserPromptSubmit`: clears the pending prompt, and the row goes to `working`.
    func answer(_ id: SessionID, after seconds: TimeInterval = 0) {
        store.update { $0.applyEvent(AgentEvent(kind: .promptSubmitted), to: id, now: at(seconds)) }
        store.flush()
    }

    func stop(_ id: SessionID, after seconds: TimeInterval = 0) {
        store.update { $0.applyEvent(AgentEvent(kind: .turnEnded, lastAssistantMessage: "done"), to: id, now: at(seconds)) }
        store.flush()
    }

    func setSwitch(_ isOn: Bool) {
        store.update { $0.setBadgeDockIcon(isOn) }
        store.flush()
    }

    var label: String? { tile.badgeLabel }
    var needsYou: Int { store.state.summaryCounts.needsYou }
}

@MainActor
@Suite(.serialized)
struct DockBadgeTests {
    @Test("two permission prompts show 2; answering one shows 1; answering both clears it")
    func countsPromptsAndClears() {
        let rig = Rig()
        #expect(rig.label == nil)

        rig.prompt(rig.ids[0])
        rig.prompt(rig.ids[1], after: 1)
        #expect(rig.label == "2")

        rig.answer(rig.ids[0], after: 2)
        #expect(rig.label == "1")

        rig.answer(rig.ids[1], after: 3)
        #expect(rig.label == nil)
        #expect(rig.tile.writes == ["1", "2", "1", nil])
    }

    @Test("the badge is the summary strip's NEEDS YOU figure")
    func matchesTheSummaryStrip() {
        let rig = Rig(count: 3)
        rig.prompt(rig.ids[0])
        rig.prompt(rig.ids[2], after: 1)
        #expect(rig.needsYou == 2)
        #expect(rig.label == String(rig.needsYou))
    }

    @Test("switch off hides the badge; on again shows the current count at once")
    func switchHidesAndRestores() {
        let rig = Rig()
        rig.prompt(rig.ids[0])
        rig.prompt(rig.ids[1], after: 1)
        #expect(rig.label == "2")

        rig.setSwitch(false)
        #expect(rig.label == nil)
        // Still counted while off: the store has not changed, only the Dock.
        rig.answer(rig.ids[0], after: 2)
        #expect(rig.label == nil)

        rig.setSwitch(true)
        #expect(rig.label == "1")
    }

    @Test("a working row is not counted; an unattended done one is")
    func workingIsNotCountedDoneUnattendedIs() {
        let rig = Rig()
        rig.answer(rig.ids[0])
        #expect(rig.store.state.sessions[rig.ids[0]]?.status == .working)
        #expect(rig.label == nil)

        rig.stop(rig.ids[1], after: 1)
        rig.store.update { $0.rederiveStatuses(now: rig.at(1 + StatusDerivation.unattendedGrace + 10)) }
        rig.store.flush()
        #expect(rig.store.state.sessions[rig.ids[1]]?.status == .waiting(.doneUnattended))
        #expect(rig.label == "1")
    }

    @Test("a change that leaves the count alone does not write the tile again")
    func unchangedCountDoesNotRepaint() {
        let rig = Rig(count: 3)
        rig.prompt(rig.ids[0])
        #expect(rig.tile.writes == ["1"])

        // Another delivery for the same waiting row, and an unrelated row starting work.
        rig.prompt(rig.ids[0], after: 1)
        rig.answer(rig.ids[2], after: 2)
        #expect(rig.tile.writes == ["1"])
    }

    @Test("launching with a prompt already up shows it before any change")
    func initialCountAtLaunch() {
        let rig = Rig { state, ids in
            state.applyEvent(AgentEvent(kind: .attention(.permission)), to: ids[0], now: Date(timeIntervalSince1970: 1_788_944_400))
        }
        #expect(rig.label == "1")
    }

    @Test("launching with the switch off shows nothing")
    func initialSwitchOff() {
        let rig = Rig { state, ids in
            state.setBadgeDockIcon(false)
            state.applyEvent(AgentEvent(kind: .attention(.permission)), to: ids[0], now: Date(timeIntervalSince1970: 1_788_944_400))
        }
        #expect(rig.label == nil)
        #expect(rig.tile.writes.isEmpty)
    }

    @Test("removing a waiting row drops it from the count")
    func removedRowLeavesTheCount() {
        let rig = Rig()
        rig.prompt(rig.ids[0])
        rig.prompt(rig.ids[1], after: 1)
        rig.store.update { $0.removeSession(rig.ids[0]) }
        rig.store.flush()
        #expect(rig.label == "1")
    }
}
