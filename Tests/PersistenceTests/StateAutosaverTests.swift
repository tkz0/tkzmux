// StateAutosaverTests — the write *policy* (M5.1 / TKZ-29): when a mutation reaches the disk, and,
// more importantly, when it must not.
//
// The saver lives in `Persistence` rather than `TkzApp` precisely so this file can exist: no
// window, no AppKit, no run loop beyond the main queue the store already needs.

import Foundation
import Testing
import TkzCore

@testable import Persistence

@MainActor
private func withSaver(
    debounce: Duration = .milliseconds(20),
    isEnabled: Bool = true,
    _ body: (AppStore, StateFile, StateAutosaver) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-autosave-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = StateFile(url: directory.appending(path: "state.json", directoryHint: .notDirectory))

    var state = AppState()
    let group = state.addGroup(name: "G", repoRoot: "/tmp")
    _ = state.createSession(groupID: group.id, cwd: "/tmp")
    let store = AppStore(state: state)
    let saver = StateAutosaver(
        store: store, file: file, loaded: file.load(), debounce: debounce, isEnabled: isEnabled)
    saver.start()
    defer { saver.stop() }
    try await body(store, file, saver)
}

/// Yields the main actor until `condition` holds or the deadline passes.
///
/// It must *suspend*, not spin a run loop: the saver's debounce is a `DispatchSourceTimer` on the
/// main queue, and blocking the main actor inside `RunLoop.run` starves it — the timer simply never
/// fires and the test times out having proved nothing.
@MainActor
///
/// 10 s rather than 2 s: the whole suite runs in parallel in one process, and since M3 added the
/// process-spawning ClaudeBridge suites the main actor was measured to be starved for more than
/// 2 s while these tests waited (they pass alone and in pairs with every other suite). The saver's
/// own debounce is 20–60 ms here, so a real regression still fails fast.
private func settle(until condition: @MainActor () -> Bool, timeout: Duration = .seconds(10)) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Test @MainActor func aDurableMutationIsWrittenAfterTheDebounce() async throws {
    try await withSaver { store, file, saver in
        store.update { $0.setSidebarVisible(false) }
        store.flush()
        // Wait for the debounce on the saver's own counter, then for the write itself with a
        // barrier. Polling the file instead is a race: the write runs on a background queue, and
        // under a loaded machine it was observed to land many seconds after `writeCount` rose.
        await settle(until: { saver.writeCount > 0 })
        #expect(saver.writeCount == 1)
        saver.waitForPendingWrites()
        #expect(file.load().document?.state.sidebar.visible == false)
    }
}

@Test @MainActor func aBurstOfMutationsCollapsesIntoOneWrite() async throws {
    try await withSaver(debounce: .milliseconds(60)) { store, file, saver in
        // What a live window resize looks like: many chrome deliveries in one debounce window.
        for width in 300..<340 {
            store.update { $0.sidebarWidth = CGFloat(width) }
            store.flush()
        }
        // "Exactly one" would be flaky — under load the debounce window can elapse partway
        // through the burst. The invariant that matters is that 40 mutations do not cost 40
        // writes, and that the file ends up holding the *last* value rather than some middle one.
        await settle(until: { saver.writeCount > 0 })
        #expect(saver.writeCount <= 3)
        saver.waitForPendingWrites()
        #expect(file.load().document?.state.sidebar.width == 339)
    }
}

@Test @MainActor func liveOnlyChangesNeverTouchTheDisk() async throws {
    try await withSaver { store, file, saver in
        // Establish a baseline first: with no file on disk the very first delivery is a real
        // change (the initial state has never been persisted) and *should* write.
        saver.flush()
        #expect(saver.writeCount == 1)

        let id = try #require(store.state.orderedSessions.first?.id)
        // Exactly the traffic a running Claude session generates: status flips, git refreshes,
        // port scans. None of it is durable, and writing the file for it would mean rewriting the
        // whole sidebar several times a second for as long as anything is running.
        for step in 0..<50 {
            store.update {
                $0.setLive(
                    LiveSessionState(pid: 100, status: step % 2 == 0 ? .working : .idle,
                                     ports: [UInt16(4000 + step)]),
                    for: id)
            }
            store.flush()
        }
        await settle(until: { saver.skippedCount >= 50 }, timeout: .seconds(1))
        #expect(saver.writeCount == 1)   // still just the baseline: 50 live mutations wrote nothing
        saver.waitForPendingWrites()
        #expect(file.load().document?.state == PersistedState(store.state))
    }
}

@Test @MainActor func flushWritesAMutationThatWasNeverDelivered() async throws {
    try await withSaver(debounce: .seconds(30)) { store, file, saver in
        // `AppStore` coalesces deliveries to one per run-loop turn, so at ⌘Q there is normally a
        // mutation no observer has seen. `flush` must re-project from the store, not wait for it.
        // The id is read *outside* the closure: reading `store.state` inside `update` is the
        // exclusivity trap design.md warns about.
        let id = try #require(store.state.orderedSessions.first?.id)
        store.update { $0.renameSession(id, title: "last words") }
        saver.flush()
        #expect(file.load().document?.state.sessions.first?.title == "last words")
    }
}

@Test @MainActor func flushIsANoOpWhenNothingChanged() async throws {
    try await withSaver { store, file, saver in
        saver.flush()
        #expect(saver.writeCount == 1)   // the initial state had never been persisted
        saver.flush()
        #expect(saver.writeCount == 1)   // …and now there is nothing left to say
        #expect(file.load().document?.state == PersistedState(store.state))
    }
}

@Test @MainActor func aDisabledSaverWritesNothing() async throws {
    // `TKZMUX_FIXTURE=1` and a state file from a newer tkzmux both land here.
    try await withSaver(isEnabled: false) { store, file, saver in
        store.update { $0.setSidebarVisible(false) }
        store.flush()
        saver.flush()
        await settle(until: { saver.writeCount > 0 }, timeout: .milliseconds(200))
        #expect(saver.writeCount == 0)
        #expect(file.load().document == nil)
    }
}

@Test @MainActor func aFutureVersionFileLatchesTheSaverOff() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-autosave-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = StateFile(url: directory.appending(path: "state.json", directoryHint: .notDirectory))

    var state = AppState()
    _ = state.addGroup(name: "G", repoRoot: "/tmp")
    try file.save(StateDocument(state: PersistedState(state)))
    var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file.url))
    object["schemaVersion"] = .number(7)
    let untouched = try StateFile.makeEncoder().encode(object)
    try untouched.write(to: file.url)

    let store = AppStore(state: state)
    let saver = StateAutosaver(store: store, file: file, loaded: file.load(), debounce: .milliseconds(10))
    saver.start()
    defer { saver.stop() }
    store.update { $0.setSidebarVisible(false) }
    store.flush()
    saver.flush()
    await settle(until: { saver.writeCount > 0 }, timeout: .milliseconds(200))
    #expect(saver.writeCount == 0)
    #expect(try Data(contentsOf: file.url) == untouched)
}

@Test @MainActor func unknownKeysReadAtLaunchAreCarriedThroughEverySave() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-autosave-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = StateFile(url: directory.appending(path: "state.json", directoryHint: .notDirectory))

    var state = AppState()
    _ = state.addGroup(name: "G", repoRoot: "/tmp")
    try file.save(StateDocument(state: PersistedState(state), extras: ["futureFlag": .bool(true)]))

    let store = AppStore(state: state)
    let loaded = file.load()
    let saver = StateAutosaver(store: store, file: file, loaded: loaded, debounce: .milliseconds(10))
    saver.start()
    defer { saver.stop() }
    store.update { $0.setSidebarVisible(false) }
    store.flush()
    saver.flush()
    #expect(file.load().document?.extras["futureFlag"] == .bool(true))
    #expect(file.load().document?.state.sidebar.visible == false)
}
