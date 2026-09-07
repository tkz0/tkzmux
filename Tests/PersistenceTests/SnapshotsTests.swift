// SnapshotsTests — the `.ghsnap` store and the background-session idle policy (M1.10 / TKZ-16).
//
// Every test writes into a fresh directory under `FileManager.default.temporaryDirectory` and
// removes it afterwards: nothing here may touch `~/Library/Application Support/tkzmux`.
//
// The round trip through a *real* `TerminalSession` cannot live here — `PersistenceTests` only
// depends on `Persistence` — so it runs in the bench harness instead
// (`tkzmux-vtdump bench --sessions N` reports `content_identical_after_restore`), and the measured
// result is in docs/perf.md. See the ticket's PACKAGE.SWIFT DELTA.

import Foundation
import Testing

@testable import Persistence

// MARK: - Helpers

/// A store in a unique temp directory, torn down when `body` returns.
private func withTemporaryStore(_ body: (SnapshotStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-snapshot-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SnapshotStore(directory: directory)
    try store.createDirectory()
    try body(store)
}

// MARK: - Paths

@Test func standardStoreUsesApplicationSupportSessions() throws {
    let base = URL(fileURLWithPath: "/var/empty/AppSupport")
    let store = SnapshotStore.standard(applicationSupport: base)
    #expect(store.directory.path == "/var/empty/AppSupport/tkzmux/sessions")
    #expect(try store.url(for: "abc").lastPathComponent == "abc.ghsnap")
}

@Test(arguments: ["", ".", "..", "a/b", "with\0nul"])
func invalidSessionIDsAreRejected(_ id: String) {
    #expect(!SnapshotStore.isValidSessionID(id))
    let store = SnapshotStore(directory: FileManager.default.temporaryDirectory)
    #expect(throws: SnapshotStoreError.self) { try store.url(for: id) }
}

@Test func validSessionIDsAreAccepted() {
    #expect(SnapshotStore.isValidSessionID(UUID().uuidString))
    #expect(SnapshotStore.isValidSessionID("bench-001"))
}

// MARK: - Round trip

@Test func saveLoadRoundTripsBytes() throws {
    try withTemporaryStore { store in
        // Snapshot blobs are binary, so exercise the full byte range rather than a nice string.
        let payload = Data((0...255).map(UInt8.init)) + Data(repeating: 0, count: 4096)
        let report = try store.save(payload, for: "session-a")
        #expect(report.byteCount == payload.count)
        #expect(report.url.lastPathComponent == "session-a.ghsnap")
        #expect(store.exists("session-a"))
        #expect(try store.load("session-a") == payload)
    }
}

@Test func loadingAMissingSnapshotThrows() throws {
    try withTemporaryStore { store in
        #expect(throws: SnapshotStoreError.missing("nope")) { try store.load("nope") }
    }
}

@Test func saveOverwritesInPlace() throws {
    try withTemporaryStore { store in
        try store.save(Data(repeating: 1, count: 100), for: "s")
        try store.save(Data(repeating: 2, count: 10), for: "s")
        let loaded = try store.load("s")
        #expect(loaded.count == 10)
        #expect(loaded.allSatisfy { $0 == 2 })
        // The rename replaced the file; no second copy and no leftover temp file.
        #expect(try store.list().count == 1)
        let all = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(all == ["s.ghsnap"])
    }
}

@Test func saveLeavesNoTemporaryFileBehind() throws {
    try withTemporaryStore { store in
        for index in 0..<5 {
            try store.save(Data(repeating: UInt8(index), count: 1024), for: "s\(index)")
        }
        let all = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(all.count == 5)
        #expect(all.allSatisfy { $0.hasSuffix(".ghsnap") })
    }
}

@Test func atomicWriteNeverExposesAPartialFile() throws {
    // The invariant the tmp+rename buys: a reader looping while a writer replaces the file only
    // ever sees one of the two complete versions, never a truncated one.
    try withTemporaryStore { store in
        let small = Data(repeating: 0xAA, count: 1024)
        let large = Data(repeating: 0xBB, count: 4 * 1024 * 1024)
        try store.save(small, for: "race")

        let done = DispatchSemaphore(value: 0)
        let directory = store.directory
        DispatchQueue.global().async {
            let writer = SnapshotStore(directory: directory)
            for _ in 0..<20 {
                _ = try? writer.save(large, for: "race")
                _ = try? writer.save(small, for: "race")
            }
            done.signal()
        }
        var reads = 0
        var sizesSeen = Set<Int>()
        while done.wait(timeout: .now()) == .timedOut {
            if let data = try? store.load("race") {
                reads += 1
                sizesSeen.insert(data.count)
                #expect(data.count == small.count || data.count == large.count)
                #expect(data.allSatisfy { $0 == data.first })
            }
        }
        #expect(reads > 0)
        #expect(sizesSeen.isSubset(of: [small.count, large.count]))
    }
}

// MARK: - Listing and accounting

@Test func listAndTotalByteCount() throws {
    try withTemporaryStore { store in
        try store.save(Data(repeating: 0, count: 10), for: "b")
        try store.save(Data(repeating: 0, count: 25), for: "a")
        try store.save(Data(repeating: 0, count: 5), for: "c")
        // A file that is not a snapshot must not be counted.
        try Data("noise".utf8).write(to: store.directory.appending(path: "readme.txt"))

        let entries = try store.list()
        #expect(entries.map(\.id) == ["a", "b", "c"])
        #expect(entries.map(\.byteCount) == [25, 10, 5])
        #expect(try store.totalByteCount() == 40)
    }
}

@Test func listOnAMissingDirectoryIsEmptyNotAnError() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-absent-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = SnapshotStore(directory: directory)
    #expect(try store.list().isEmpty)
    #expect(try store.totalByteCount() == 0)
}

@Test func deleteReportsWhetherAnythingWasThere() throws {
    try withTemporaryStore { store in
        try store.save(Data([1, 2, 3]), for: "gone")
        #expect(try store.delete("gone"))
        #expect(!store.exists("gone"))
        #expect(try store.delete("gone") == false)
    }
}

// MARK: - Housekeeping

@Test func housekeepingRemovesOrphansAndKeepsLiveSessions() throws {
    try withTemporaryStore { store in
        try store.save(Data(repeating: 0, count: 100), for: "live")
        try store.save(Data(repeating: 0, count: 300), for: "orphan")

        let report = try store.housekeep(liveSessionIDs: ["live"])
        #expect(report.orphaned == ["orphan"])
        #expect(report.stale.isEmpty)
        #expect(report.reclaimedBytes == 300)
        #expect(try store.list().map(\.id) == ["live"])
    }
}

@Test func housekeepingRemovesStaleSnapshotsUsingTheInjectedClock() throws {
    try withTemporaryStore { store in
        try store.save(Data(repeating: 0, count: 64), for: "old")
        try store.save(Data(repeating: 0, count: 64), for: "fresh")
        // Age "old" by back-dating its mtime — the alternative is sleeping for a week.
        let oldURL = try store.url(for: "old")
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: oldURL.path)

        let sevenDays: TimeInterval = 7 * 24 * 3600
        let report = try store.housekeep(
            liveSessionIDs: ["old", "fresh"], maximumAge: sevenDays, now: Date()
        )
        #expect(report.stale == ["old"])
        #expect(try store.list().map(\.id) == ["fresh"])

        // Same directory, a clock far enough in the past: nothing is stale.
        let second = try store.housekeep(
            liveSessionIDs: ["fresh"], maximumAge: sevenDays, now: Date().addingTimeInterval(-sevenDays)
        )
        #expect(second.stale.isEmpty)
        #expect(second.orphaned.isEmpty)
    }
}

@Test func housekeepingSweepsTemporaryFilesFromAnInterruptedWrite() throws {
    try withTemporaryStore { store in
        try store.save(Data(repeating: 0, count: 8), for: "keep")
        // Exactly the shape `save` uses for its temp file: one abandoned, one that a concurrent
        // `save` could still be fsync'ing right now.
        let leftover = store.directory.appending(path: ".keep.999.tmp")
        try Data(repeating: 7, count: 2048).write(to: leftover)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-SnapshotStore.temporaryFileGrace - 10)],
            ofItemAtPath: leftover.path
        )
        let inFlight = store.directory.appending(path: ".keep.1000.tmp")
        try Data(repeating: 9, count: 16).write(to: inFlight)
        #expect(try store.list().count == 1)  // hidden temp files are not snapshots

        let report = try store.housekeep(liveSessionIDs: ["keep"])
        #expect(report.temporaries == 1)
        #expect(report.reclaimedBytes == 2048)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        // The young one is left alone — deleting it would break the write that owns it.
        #expect(FileManager.default.fileExists(atPath: inFlight.path))
        #expect(store.exists("keep"))
    }
}

// MARK: - Bounding

@Test func boundingPassesTheLimitToTheEncoder() throws {
    try withTemporaryStore { store in
        // `SnapshotStore` cannot lower SCROLLBACK_MAX_BYTES itself; it hands the bound to whoever
        // owns the terminal. This pins that contract.
        var seen: [Int?] = []
        try store.save(for: "a", bounding: .unbounded) { limit in
            seen.append(limit)
            return Data([0])
        }
        try store.save(for: "b", bounding: .bounded4MiB) { limit in
            seen.append(limit)
            return Data([0, 1])
        }
        #expect(seen == [nil, 4 * 1024 * 1024])
        #expect(try store.load("b").count == 2)
    }
}

@Test func saveWithEncoderTimesEncodeAndWrite() throws {
    try withTemporaryStore { store in
        let report = try store.save(for: "timed") { _ in Data(repeating: 3, count: 1 << 20) }
        #expect(report.byteCount == 1 << 20)
        #expect(report.elapsed > 0)
    }
}

// MARK: - Idle compression policy

private let origin = ContinuousClock.now

@Test func policyWaitsOutTheIdleThreshold() {
    var policy = IdleCompressionPolicy(idleThreshold: .seconds(60))
    policy.register("a", at: origin)

    #expect(policy.due(at: origin) == [])
    #expect(policy.due(at: origin.advanced(by: .seconds(59))) == [])
    #expect(policy.due(at: origin.advanced(by: .seconds(60))) == ["a"])
}

@Test func activityRestartsTheIdleClock() {
    var policy = IdleCompressionPolicy(idleThreshold: .seconds(60))
    policy.register("a", at: origin)
    policy.noteActivity("a", at: origin.advanced(by: .seconds(59)))

    #expect(policy.due(at: origin.advanced(by: .seconds(61))) == [])
    #expect(policy.due(at: origin.advanced(by: .seconds(119))) == ["a"])
}

@Test func changedActivityTokenCountsAsActivityAndAnUnchangedOneDoesNot() {
    var policy = IdleCompressionPolicy(idleThreshold: .seconds(60))
    policy.register("a", at: origin, activityToken: 7)

    policy.noteActivityToken("a", 7, at: origin.advanced(by: .seconds(30)))
    #expect(policy.due(at: origin.advanced(by: .seconds(61))) == ["a"])

    policy.noteActivityToken("a", 8, at: origin.advanced(by: .seconds(61)))
    #expect(policy.due(at: origin.advanced(by: .seconds(62))) == [])
    #expect(policy.due(at: origin.advanced(by: .seconds(121))) == ["a"])
}

@Test func visibleSessionsAreNeverCompressed() {
    var policy = IdleCompressionPolicy(idleThreshold: .seconds(60))
    policy.register("front", at: origin, isVisible: true)
    policy.register("back", at: origin, isVisible: false)

    #expect(policy.due(at: origin.advanced(by: .seconds(120))) == ["back"])

    // Backgrounding it makes it eligible: its idle clock has been running the whole time (only
    // *becoming* visible counts as activity), so it is due on the very next tick.
    policy.noteVisibility("front", isVisible: false, at: origin.advanced(by: .seconds(120)))
    #expect(policy.due(at: origin.advanced(by: .seconds(120))).sorted() == ["back", "front"])
}

@Test func becomingVisibleResetsTheIdleClock() {
    var policy = IdleCompressionPolicy(idleThreshold: .seconds(60))
    policy.register("a", at: origin)
    policy.noteVisibility("a", isVisible: true, at: origin.advanced(by: .seconds(10)))
    policy.noteVisibility("a", isVisible: false, at: origin.advanced(by: .seconds(20)))
    #expect(policy.due(at: origin.advanced(by: .seconds(61))) == [])
    #expect(policy.due(at: origin.advanced(by: .seconds(71))) == ["a"])
}

@Test func pendingSchedulesAnotherStepAfterTheStepInterval() {
    var policy = IdleCompressionPolicy(idleThreshold: .seconds(60), stepInterval: .seconds(1))
    policy.register("a", at: origin)
    let first = origin.advanced(by: .seconds(60))
    #expect(policy.due(at: first) == ["a"])

    policy.noteStep("a", result: .pending, at: first)
    #expect(policy.due(at: first.advanced(by: .milliseconds(500))) == [])
    #expect(policy.due(at: first.advanced(by: .seconds(1))) == ["a"])
}

@Test func completeSettlesTheSessionUntilTheNextActivity() {
    var policy = IdleCompressionPolicy(idleThreshold: .seconds(60))
    policy.register("a", at: origin)
    let first = origin.advanced(by: .seconds(60))
    policy.noteStep("a", result: .complete, at: first)

    #expect(policy.due(at: first.advanced(by: .seconds(600))) == [])
    // New output, then quiet again: eligible once more.
    policy.noteActivity("a", at: first.advanced(by: .seconds(600)))
    #expect(policy.due(at: first.advanced(by: .seconds(661))) == ["a"])
}

@Test func unsupportedDisablesTheSessionPermanently() {
    var policy = IdleCompressionPolicy(idleThreshold: .seconds(60))
    policy.register("a", at: origin)
    policy.noteStep("a", result: .unsupported, at: origin.advanced(by: .seconds(60)))
    policy.noteActivity("a", at: origin.advanced(by: .seconds(100)))
    #expect(policy.due(at: origin.advanced(by: .seconds(1000))) == [])
    #expect(policy.entries["a"]?.disabled == true)
}

@Test func forgottenSessionsDisappearAndUnknownIdsAreIgnored() {
    var policy = IdleCompressionPolicy(idleThreshold: .seconds(60))
    policy.register("a", at: origin)
    policy.register("b", at: origin)
    policy.forget("a")
    #expect(policy.trackedIDs == ["b"])
    // Every mutator tolerates an unknown id: sessions die while a timer tick is in flight.
    policy.noteActivity("ghost", at: origin)
    policy.noteActivityToken("ghost", 1, at: origin)
    policy.noteVisibility("ghost", isVisible: true, at: origin)
    policy.noteStep("ghost", result: .complete, at: origin)
    #expect(policy.trackedIDs == ["b"])
    #expect(!policy.isDue("ghost", at: origin.advanced(by: .seconds(600))))
}

@Test func dueIsStablyOrderedAcrossManySessions() {
    var policy = IdleCompressionPolicy(idleThreshold: .seconds(60))
    for index in 0..<30 {
        policy.register(String(format: "s%02d", index), at: origin)
    }
    let due = policy.due(at: origin.advanced(by: .seconds(61)))
    #expect(due.count == 30)
    #expect(due == due.sorted())
}
