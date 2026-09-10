// UpdateStateTests — the store side of the sidebar's update card (TKZ-50).
//
// Two contracts: the release check and the `✕` ride `ChangeSet.chrome` and nothing else (no row
// reload, nothing structural), and `visibleUpdate` is the one derivation the card reads.

import Testing

@testable import TkzCore

@MainActor
@Suite struct UpdateStateTests {
    let update = AvailableUpdate(version: "0.8.0", releaseURL: "https://example.invalid/v0.8.0")

    @Test("A release arriving is chrome-only")
    func availableUpdateIsChromeOnly() {
        let probe = Probe()
        probe.store.update { $0.setAvailableUpdate(update) }
        probe.store.flush()
        let change = probe.last
        #expect(change.chrome)
        #expect(change.sessions.isEmpty)
        #expect(change.groups.isEmpty)
        #expect(!change.structure)
        #expect(!change.selection)
        #expect(!change.usage)
        #expect(probe.store.state.visibleUpdate == update)
    }

    @Test("Dismissing hides exactly that version; a newer one shows again")
    func dismissIsPerVersion() {
        let probe = Probe()
        probe.store.update { $0.setAvailableUpdate(update) }
        probe.store.update { $0.dismissUpdate(version: "0.8.0") }
        probe.store.flush()
        #expect(probe.last.chrome)
        #expect(probe.last.sessions.isEmpty)
        #expect(probe.store.state.visibleUpdate == nil)
        #expect(probe.store.state.dismissedUpdateVersion == "0.8.0")

        let newer = AvailableUpdate(version: "0.9.0", releaseURL: "https://example.invalid/v0.9.0")
        probe.store.update { $0.setAvailableUpdate(newer) }
        probe.store.flush()
        #expect(probe.store.state.visibleUpdate == newer)
    }

    @Test("A phase change and the capability flag are chrome-only too")
    func phaseIsChromeOnly() {
        let probe = Probe()
        probe.store.update {
            $0.setCanUpgradeInPlace(true)
            $0.setUpgradePhase(.running(step: "update"))
        }
        probe.store.flush()
        #expect(probe.last.chrome)
        #expect(probe.last.sessions.isEmpty)
        #expect(probe.store.state.update.phase.isRunning)
        #expect(probe.store.state.update.canUpgradeInPlace)
        // Setting the same value again delivers nothing.
        probe.store.update { $0.setUpgradePhase(.running(step: "update")) }
        probe.store.flush()
        #expect(probe.received.count == 1)
    }

    @Test("A withdrawn release clears the card")
    func upToDateClears() {
        let probe = Probe()
        probe.store.update { $0.setAvailableUpdate(update) }
        probe.store.update { $0.setAvailableUpdate(nil) }
        probe.store.flush()
        #expect(probe.store.state.visibleUpdate == nil)
    }
}
