// The store's contract: granular diffs, and one delivery per run-loop turn.
// See docs/design.md → *App architecture → Store*.

import Foundation
import Testing

@testable import TkzCore

@MainActor
@Suite struct AppStoreTests {
    /// A session id that exists in the fixture.
    let sessionA = Fixture.sessionID(0)
    let sessionB = Fixture.sessionID(1)
    let group0 = Fixture.groupID(0)

    // MARK: Diff granularity

    /// TKZ-17 acceptance: a status flip names exactly one session and is **not** structural.
    @Test func statusChangeTouchesOneSessionAndIsNotStructural() {
        let probe = Probe()
        let store = probe.store
        store.update { $0.setStatus(.waiting(.permission), for: sessionA) }
        store.flush()
        let change = probe.last
        #expect(change.sessions == [sessionA])
        #expect(change.groups.isEmpty)
        #expect(change.structure == false)
        #expect(change.selection == false)
        #expect(change.usage == false)
    }

    @Test func liveStateChangesNeverGoStructural() {
        let probe = Probe()
        let store = probe.store
        store.update { state in
            state.updateLive(sessionA) { $0.ports = [1234] }
            state.updateLive(sessionA) { $0.git?.insertions = 999 }
            state.renameSession(sessionA, title: "a new name")
        }
        store.flush()
        let change = probe.last
        #expect(change.sessions == [sessionA])
        #expect(change.structure == false)
    }

    /// TKZ-17 acceptance: reordering is structural.
    @Test func reorderingIsStructural() {
        let probe = Probe()
        let store = probe.store
        store.update { $0.reorderSession(sessionB, to: 0) }
        store.flush()
        let change = probe.last
        #expect(change.structure)
        #expect(change.sessions.contains(sessionB))
        #expect(change.sessions.contains(sessionA))  // its order moved too
    }

    @Test func addingAndRemovingSessionsIsStructural() {
        let probe = Probe()
        let store = probe.store
        let created = store.updating { $0.createSession(groupID: group0, cwd: "~/dev/x") }
        store.flush()
        var change = probe.last
        #expect(change.structure)
        #expect(change.sessions == [created.id])

        store.update { $0.removeSession(created.id) }
        store.flush()
        change = probe.last
        #expect(change.structure)
        #expect(change.sessions.contains(created.id))
    }

    @Test func movingBetweenGroupsIsStructural() {
        let probe = Probe()
        let store = probe.store
        store.update { $0.moveSession(sessionA, toGroup: Fixture.groupID(3)) }
        store.flush()
        #expect(probe.last.structure)
    }

    /// Collapsing a group is `collapseItem`, not a reload of the outline: a group change, no structure.
    @Test func collapsingAGroupIsAGroupChangeOnly() {
        let probe = Probe()
        let store = probe.store
        store.update { $0.toggleGroupCollapsed(group0) }
        store.flush()
        let change = probe.last
        #expect(change.groups == [group0])
        #expect(change.sessions.isEmpty)
        #expect(change.structure == false)
    }

    @Test func groupReorderIsStructuralButRenameIsNot() {
        let probe = Probe()
        let store = probe.store
        store.update { $0.renameGroup(group0, name: "Renamed") }
        store.flush()
        #expect(probe.last.structure == false)

        store.update { $0.moveGroup(group0, to: 3) }
        store.flush()
        #expect(probe.last.structure)
    }

    @Test func selectionAndUsageAreTheirOwnFlags() {
        let probe = Probe()
        let store = probe.store
        store.update { $0.select(sessionB) }
        store.flush()
        var change = probe.last
        #expect(change.selection)
        #expect(change.structure == false)

        store.update {
            $0.setUsage(UsageSnapshot(accountKey: "claude", updatedAt: Date(),
                                      sevenDay: UsageWindow(usedPercentage: 99)))
        }
        store.flush()
        change = probe.last
        #expect(change.usage)
        #expect(change.sessions.isEmpty)
        #expect(change.structure == false)
    }

    /// Presets, shortcuts, the window frame and the sidebar toggle are `chrome`: they must be
    /// delivered (the preset menu and M5's writer need them) but must never force a row reload.
    @Test func chromeChangesDeliverWithoutTouchingRows() {
        let probe = Probe()
        let store = probe.store
        store.update { $0.setSidebarVisible(false) }
        store.flush()
        var change = probe.last
        #expect(change.chrome)
        #expect(change.structure == false)
        #expect(change.sessions.isEmpty)

        store.update { $0.addPreset(Preset(name: "p", command: "claude")) }
        store.flush()
        #expect(probe.last.chrome)

        store.update { $0.shortcuts["newSession"] = "cmd+n" }
        store.flush()
        #expect(probe.last.chrome)

        store.update { $0.windowFrame = CGRect(x: 0, y: 0, width: 1400, height: 900) }
        store.flush()
        change = probe.last
        #expect(change.chrome)
        #expect(change.structure == false)
    }

    @Test func aNoOpUpdateDeliversNothing() {
        let probe = Probe()
        let store = probe.store
        var deliveries = 0
        store.addObserver { _ in deliveries += 1 }
        store.update { $0.renameSession(sessionA, title: $0.sessions[sessionA]?.title) }
        store.flush()
        #expect(deliveries == 0)
        #expect(store.hasPendingChanges == false)
    }

    // MARK: Coalescing

    /// TKZ-17 acceptance: three updates in one run-loop turn deliver **one** change set,
    /// containing the union of all three.
    @Test func threeUpdatesInOneTurnDeliverOneChangeSet() async {
        let probe = Probe()
        let store = probe.store
        var received: [ChangeSet] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.addObserver { change in
                received.append(change)
                continuation.resume()
            }
            store.update { $0.setStatus(.waiting(.permission), for: sessionA) }
            store.update { $0.setStatus(.idle, for: sessionB) }
            store.update { $0.select(sessionB) }
            // No flush: delivery must come from the store's own main-queue source.
        }
        #expect(received.count == 1)
        #expect(received.first?.sessions == [sessionA, sessionB])
        #expect(received.first?.selection == true)
        #expect(received.first?.structure == false)
        #expect(store.deliveryCount == 1)
    }

    @Test func changesInASecondTurnDeliverASecondChangeSet() async {
        let probe = Probe()
        let store = probe.store
        var counts: [Int] = []
        store.addObserver { counts.append($0.sessions.count) }
        store.update { $0.setStatus(.waiting(.permission), for: sessionA) }
        await Task.yield()
        await mainTurn()
        store.update { $0.setStatus(.working, for: sessionB) }
        await mainTurn()
        #expect(store.deliveryCount == 2)
        #expect(counts == [1, 1])
    }

    /// An observer that mutates must not lose its own change: the pending set is reset before
    /// observers run, so the nested update arms the *next* turn.
    @Test func anUpdateFromInsideAnObserverArmsTheNextTurn() {
        let probe = Probe()
        let store = probe.store
        var seen: [Set<SessionID>] = []
        store.addObserver { change in
            seen.append(change.sessions)
            if change.sessions == [self.sessionA] {
                store.update { $0.setStatus(.idle, for: self.sessionB) }
            }
        }
        store.update { $0.setStatus(.waiting(.permission), for: sessionA) }
        store.flush()
        #expect(seen == [[sessionA]])
        #expect(store.hasPendingChanges)
        store.flush()
        #expect(seen == [[sessionA], [sessionB]])
    }

    @Test func observersCanBeRemoved() {
        let probe = Probe()
        let store = probe.store
        var count = 0
        let token = store.addObserver { _ in count += 1 }
        store.update { $0.setStatus(.waiting(.permission), for: sessionA) }
        store.flush()
        store.removeObserver(token)
        store.update { $0.setStatus(.idle, for: sessionA) }
        store.flush()
        #expect(count == 1)
    }

    // MARK: ChangeSet algebra

    @Test func changeSetUnionAndTouches() {
        var a = ChangeSet(sessions: [sessionA], structure: false)
        a.formUnion(ChangeSet(groups: [group0], structure: true))
        #expect(a.sessions == [sessionA])
        #expect(a.groups == [group0])
        #expect(a.structure)
        #expect(a.touches(sessionA))
        #expect(ChangeSet.none.isEmpty)
        #expect(ChangeSet(chrome: true).isEmpty == false)
        #expect(ChangeSet(sessions: [sessionA]).touches(sessionB) == false)
        #expect(ChangeSet(structure: true).touches(sessionB))  // structure invalidates everything
    }

    @Test func diffIsPureAndUsableWithoutAStore() {
        let old = AppState.fixture
        var new = old
        new.setStatus(.waiting(.permission), for: sessionA)
        let change = ChangeSet.diff(from: old, to: new)
        #expect(change.sessions == [sessionA])
        #expect(ChangeSet.diff(from: old, to: old).isEmpty)
    }

    // MARK: Helpers

    /// Lets one run-loop turn of the main queue complete.
    private func mainTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// A store plus the change sets it has delivered — the shape every test here wants.
@MainActor
final class Probe {
    let store: AppStore
    private(set) var received: [ChangeSet] = []

    init(_ state: AppState = .fixture) {
        store = AppStore(state: state)
        store.addObserver { [weak self] change in self?.received.append(change) }
    }

    var last: ChangeSet { received.last ?? .none }
}
