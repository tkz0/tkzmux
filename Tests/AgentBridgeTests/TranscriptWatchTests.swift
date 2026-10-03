// TranscriptWatchTests — the debounced "this transcript grew" watch the prompt card uses, moved
// into AgentBridge in WOR-306 S2. Runs on both OSes: a DispatchSource on the file on macOS, a
// FileWatcher on its directory on Linux, with the same observable behaviour.
import Foundation
import Synchronization
import Testing

import AgentBridge

/// Counts callbacks; they arrive on the main actor.
private final class FireCounter: Sendable {
    private let fires = Mutex(0)

    func record() { fires.withLock { $0 += 1 } }
    var count: Int { fires.withLock { $0 } }

    /// Polls until at least `n` fires, or `timeout` elapses.
    func wait(forAtLeast n: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while count < n, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return count >= n
    }
}

@Suite struct TranscriptWatchTests {
    private func transcript(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tkzmux-transcript-watch-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: file)
        return file
    }

    private func append(_ line: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    @Test func aMissingFileHasNoWatch() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkzmux-no-such-\(UUID().uuidString)/session.jsonl").path
        #expect(TranscriptWatch(path: path) {} == nil)
    }

    /// A turn writes several lines in quick succession; the debounce (150 ms) folds them into one
    /// re-read.
    @Test func aBurstOfAppendsFiresOnce() async throws {
        let file = try transcript("burst")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let counter = FireCounter()
        let watch = try #require(TranscriptWatch(path: file.path) { counter.record() })
        defer { watch.cancel() }

        // Back to back, and timed: on a starved runner a gap longer than the debounce would make
        // two bursts, and then a second fire is right, not a failure.
        let started = ContinuousClock.now
        for index in 0..<5 {
            try append(#"{"type":"assistant","n":\#(index)}"#, to: file)
        }
        let span = ContinuousClock.now - started
        #expect(await counter.wait(forAtLeast: 1))
        try await Task.sleep(for: .milliseconds(400))
        if span < .milliseconds(100) { #expect(counter.count == 1) }

        // A later append is a later fire.
        try append(#"{"type":"system"}"#, to: file)
        #expect(await counter.wait(forAtLeast: 2))
    }

    /// Writes to a sibling in the same directory (another session of the same project) are not
    /// this transcript's.
    @Test func aSiblingFileDoesNotFire() async throws {
        let file = try transcript("sibling")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let counter = FireCounter()
        let watch = try #require(TranscriptWatch(path: file.path) { counter.record() })
        defer { watch.cancel() }

        let sibling = file.deletingLastPathComponent().appendingPathComponent("other.jsonl")
        try Data("{}\n".utf8).write(to: sibling)
        try append(#"{"type":"user"}"#, to: sibling)
        try await Task.sleep(for: .milliseconds(400))
        #expect(counter.count == 0)
    }

    /// A deleted transcript ends the watch: a new file under the same name is not followed until
    /// the owner opens a fresh watch.
    @Test func aDeleteEndsTheWatch() async throws {
        let file = try transcript("delete")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let counter = FireCounter()
        let watch = try #require(TranscriptWatch(path: file.path) { counter.record() })
        defer { watch.cancel() }

        try FileManager.default.removeItem(at: file)
        try await Task.sleep(for: .milliseconds(100))
        try Data("{}\n".utf8).write(to: file)
        try append(#"{"type":"user"}"#, to: file)
        try await Task.sleep(for: .milliseconds(400))
        #expect(counter.count == 0)
    }

    /// `cancel` drops a debounce already armed: nothing fires after it.
    @Test func cancelStopsAPendingFire() async throws {
        let file = try transcript("cancel")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let counter = FireCounter()
        let watch = try #require(TranscriptWatch(path: file.path) { counter.record() })

        let appended = ContinuousClock.now
        try append(#"{"type":"user"}"#, to: file)
        try await Task.sleep(for: .milliseconds(50))
        watch.cancel()
        // Only conclusive when the cancel came well inside the 150 ms debounce; a starved runner
        // that overslept the 50 ms saw the fire happen first, correctly.
        let cancelledAfter = ContinuousClock.now - appended
        try await Task.sleep(for: .milliseconds(400))
        if cancelledAfter < .milliseconds(120) { #expect(counter.count == 0) }
        watch.cancel()  // idempotent
    }
}
