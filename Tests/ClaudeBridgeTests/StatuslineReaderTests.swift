// StatuslineReaderTests — the consumer half, and the seam where what the producer writes meets what
// `TkzCore` decodes (TKZ-32).
//
// The most valuable test here is `whatTheProducerWritesIsWhatTheReaderDecodes`: the producer is
// hand-written JSON from a Foundation-free binary and the reader is `Codable`, so nothing but an
// end-to-end run proves the two agree. Everything else drives the watcher with files written
// directly, with a short debounce so the tests do not sit around waiting.
import Foundation
import Synchronization
import Testing
import TkzCore

@testable import ClaudeBridge

/// Collects events off the reader's queue and lets a test wait for them.
private final class EventCollector: Sendable {
    private let events = Mutex<[StatuslineEvent]>([])

    func record(_ event: StatuslineEvent) { events.withLock { $0.append(event) } }
    var all: [StatuslineEvent] { events.withLock { $0 } }

    /// Polls rather than sleeping a fixed time, so a fast machine finishes fast.
    func wait(
        for timeout: TimeInterval = 5, until predicate: @escaping ([StatuslineEvent]) -> Bool
    ) -> [StatuslineEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = all
            if predicate(current) { return current }
            usleep(20_000)
        }
        return all
    }
}

extension StatuslineEvent {
    fileprivate var usage: UsageSnapshot? {
        if case .usage(let snapshot) = self { return snapshot }
        return nil
    }
    fileprivate var context: SessionSidecar? {
        if case .context(let sidecar) = self { return sidecar }
        return nil
    }
    fileprivate var clearedAccount: String? {
        if case .usageCleared(let key) = self { return key }
        return nil
    }
    fileprivate var removedSession: String? {
        if case .contextRemoved(let id) = self { return id }
        return nil
    }
}

@Suite struct StatuslineReaderTests {
    private func directory(_ label: String) throws -> URL {
        let root = try StatuslineTestSupport.tempDirectory(label)
        let statusline = root.appendingPathComponent("statusline", isDirectory: true)
        try FileManager.default.createDirectory(at: statusline, withIntermediateDirectories: true)
        return statusline
    }

    private func write(_ json: String, _ name: String, in directory: URL) throws {
        // Publish by rename, exactly as the producer does — the reader has to survive the inode
        // swapping under a path it is already watching.
        let temporary = directory.appendingPathComponent(".\(name).tmp")
        try Data(json.utf8).write(to: temporary)
        _ = try FileManager.default.replaceItemAt(
            directory.appendingPathComponent(name), withItemAt: temporary)
    }

    private func usageJSON(
        key: String = "claude", fiveHour: Int = 24, sevenDay: Int = 41, resetsAt: String
    ) -> String {
        """
        {"updated_at":"2026-09-09T08:00:00.000Z",
         "account":{"key":"\(key)","label":"Personal","plan":"Max 20x","uuid":null,"config_dir":"/h/.claude"},
         "five_hour":{"used_percentage":\(fiveHour),"resets_at":"\(resetsAt)"},
         "seven_day":{"used_percentage":\(sevenDay),"resets_at":"\(resetsAt)"}}
        """
    }

    private func farFuture() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(3600))
    }

    /// The integration that matters most: the producer writes JSON by hand from a Foundation-free
    /// binary, and the reader decodes it with `Codable`. Only a round trip proves they agree on
    /// every key, on ISO-8601 with fractional seconds, and on the `gh`-shaped `pr` block.
    @Test func whatTheProducerWritesIsWhatTheReaderDecodes() throws {
        let support = try StatuslineTestSupport.tempDirectory("round-trip-support")
        _ = try StatuslineTestSupport.run(
            try StatuslineTestSupport.hookBinary(), ["statusline"],
            stdin: StatuslineTestSupport.fullPayload,
            environment: StatuslineTestSupport.environment([
                "TKZMUX_SUPPORT_DIR": support.path, "CLAUDE_CONFIG_DIR": "/h/.claude",
            ]))

        let statusline = support.appendingPathComponent("statusline")
        let usage = try JSONDecoder().decode(
            UsageSnapshot.self,
            from: Data(contentsOf: statusline.appendingPathComponent("usage-claude.json")))
        #expect(usage.fiveHour?.usedPercentage == 24)
        #expect(usage.sevenDay?.usedPercentage == 41)
        // Decoded, not left nil — the producer's ISO-8601 spelling has to match `ISO8601.date(from:)`.
        #expect(usage.fiveHour?.resetsAt != nil)
        #expect(usage.plan == nil || usage.plan?.isEmpty == false)

        let context = try JSONDecoder().decode(
            SessionSidecar.self,
            from: Data(contentsOf: statusline.appendingPathComponent("context-abc-123_XYZ.json")))
        #expect(context.sessionId == "abc-123_XYZ")
        #expect(context.contextUsedPercentage == 62)
        #expect(context.model?.displayName == "Opus 5")
        #expect(context.workspace?.repo == "tkz0/tkzmux")
        #expect(context.worktree == "pricing")
        #expect(context.cost == 1.5)
        #expect(context.updatedAt != nil)
        // `PRInfo` is `gh`-shaped; the producer, not the reader, does that translation.
        #expect(context.pr?.number == 412)
        #expect(context.pr?.state == "OPEN")
        #expect(context.pr?.isDraft == false)
        #expect(context.pr?.reviewDecision == "APPROVED")
    }

    @Test func filesAlreadyPresentAtStartAreReported() throws {
        let directory = try directory("existing")
        try write(usageJSON(resetsAt: farFuture()), "usage-claude.json", in: directory)
        try write(
            #"{"updated_at":"\#(ISO8601DateFormatter().string(from: Date()))","session_id":"s1","context_used_percentage":62}"#,
            "context-s1.json", in: directory)

        let collector = EventCollector()
        let reader = StatuslineReader(
            directory: directory.path, debounce: .milliseconds(20), sweepInterval: .seconds(60)
        ) { collector.record($0) }
        reader.start()
        defer { reader.stop() }

        let events = collector.wait { $0.contains { $0.usage != nil } && $0.contains { $0.context != nil } }
        #expect(events.compactMap(\.usage).first?.accountKey == "claude")
        #expect(events.compactMap(\.usage).first?.sevenDay?.usedPercentage == 41)
        #expect(events.compactMap(\.context).first?.sessionId == "s1")
    }

    /// The producer publishes by rename, so the path the reader watches keeps pointing at a new
    /// inode. Without the unconditional re-open on settle this stops firing after the first write.
    @Test func aRewriteByRenameIsPickedUp() throws {
        let directory = try directory("rename")
        let resets = farFuture()
        try write(usageJSON(sevenDay: 41, resetsAt: resets), "usage-claude.json", in: directory)

        let collector = EventCollector()
        let reader = StatuslineReader(
            directory: directory.path, debounce: .milliseconds(20), sweepInterval: .seconds(60)
        ) { collector.record($0) }
        reader.start()
        defer { reader.stop() }
        _ = collector.wait { $0.contains { $0.usage != nil } }

        try write(usageJSON(sevenDay: 55, resetsAt: resets), "usage-claude.json", in: directory)
        let events = collector.wait { $0.compactMap(\.usage).contains { $0.sevenDay?.usedPercentage == 55 } }
        #expect(events.compactMap(\.usage).last?.sevenDay?.usedPercentage == 55)
    }

    /// The account key is the filename, never `account.key` inside the document: the filename is
    /// what the reader and `AppState.usage` agree on, and a mismatched inner key would otherwise
    /// publish a snapshot nothing looks up.
    @Test func theFilenameWinsOverTheKeyInsideTheDocument() throws {
        let directory = try directory("filename-key")
        try write(usageJSON(key: "wrong", resetsAt: farFuture()), "usage-claude-work.json", in: directory)

        let collector = EventCollector()
        let reader = StatuslineReader(
            directory: directory.path, debounce: .milliseconds(20), sweepInterval: .seconds(60)
        ) { collector.record($0) }
        reader.start()
        defer { reader.stop() }

        let events = collector.wait { $0.contains { $0.usage != nil } }
        #expect(events.compactMap(\.usage).first?.accountKey == "claude-work")
    }

    /// A deleted sidecar clears the account rather than leaving the last percentage on screen: a
    /// stale quota reading is indistinguishable from a current one.
    @Test func aDeletedUsageSidecarClearsTheAccount() throws {
        let directory = try directory("deleted")
        try write(usageJSON(resetsAt: farFuture()), "usage-claude.json", in: directory)

        let collector = EventCollector()
        let reader = StatuslineReader(
            directory: directory.path, debounce: .milliseconds(20), sweepInterval: .milliseconds(200)
        ) { collector.record($0) }
        reader.start()
        defer { reader.stop() }
        _ = collector.wait { $0.contains { $0.usage != nil } }

        try FileManager.default.removeItem(at: directory.appendingPathComponent("usage-claude.json"))
        let events = collector.wait { $0.contains { $0.clearedAccount == "claude" } }
        #expect(events.contains { $0.clearedAccount == "claude" })
    }

    /// Every window in the document has already expired, so there is nothing true left to show.
    @Test func aSidecarWhoseWindowsHaveAllExpiredPublishesNothing() throws {
        let directory = try directory("expired")
        try write(usageJSON(resetsAt: "2020-01-01T00:00:00.000Z"), "usage-claude.json", in: directory)

        let collector = EventCollector()
        let reader = StatuslineReader(
            directory: directory.path, debounce: .milliseconds(20), sweepInterval: .seconds(60)
        ) { collector.record($0) }
        reader.start()
        defer { reader.stop() }

        _ = collector.wait(for: 0.5) { _ in false }
        #expect(collector.all.compactMap(\.usage).isEmpty)
        #expect(reader.usageSnapshot().isEmpty)
    }

    /// A config dir nobody has used in two weeks would otherwise leave a dead badge on screen
    /// forever. The cutoff is exclusive: exactly fourteen days old is still shown.
    @Test func aGhostSidecarIsIgnored() throws {
        let directory = try directory("ghost")
        let name = "usage-old.json"
        try write(usageJSON(key: "old", resetsAt: farFuture()), name, in: directory)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-15 * 24 * 3600)],
            ofItemAtPath: directory.appendingPathComponent(name).path)

        let collector = EventCollector()
        let reader = StatuslineReader(
            directory: directory.path, debounce: .milliseconds(20), sweepInterval: .seconds(60)
        ) { collector.record($0) }
        reader.start()
        defer { reader.stop() }

        _ = collector.wait(for: 0.5) { _ in false }
        #expect(reader.usageSnapshot().isEmpty)
    }

    /// Whatever wrote a day-old context sidecar is long gone; showing its context would be a lie.
    @Test func aStaleContextSidecarIsNotPublished() throws {
        let directory = try directory("stale-context")
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-48 * 3600))
        try write(#"{"updated_at":"\#(old)","session_id":"s1","context_used_percentage":62}"#,
                  "context-s1.json", in: directory)

        let collector = EventCollector()
        let reader = StatuslineReader(
            directory: directory.path, debounce: .milliseconds(20), sweepInterval: .seconds(60)
        ) { collector.record($0) }
        reader.start()
        defer { reader.stop() }

        _ = collector.wait(for: 0.5) { _ in false }
        #expect(reader.contextSnapshot().isEmpty)
    }

    /// A torn read keeps the last good value rather than blanking the badge mid-write.
    @Test func aTornWriteIsIgnoredAndTheLastGoodValueSurvives() throws {
        let directory = try directory("torn")
        let resets = farFuture()
        try write(usageJSON(sevenDay: 41, resetsAt: resets), "usage-claude.json", in: directory)

        let collector = EventCollector()
        let reader = StatuslineReader(
            directory: directory.path, debounce: .milliseconds(20), sweepInterval: .seconds(60)
        ) { collector.record($0) }
        reader.start()
        defer { reader.stop() }
        _ = collector.wait { $0.contains { $0.usage != nil } }

        try write("{ half a docum", "usage-claude.json", in: directory)
        _ = collector.wait(for: 0.4) { _ in false }
        #expect(reader.usageSnapshot()["claude"]?.sevenDay?.usedPercentage == 41)
    }

    /// Anything that is not one of the two shapes is invisible — including the `.tmp` files the
    /// producer publishes through, which is why they carry a suffix the globs do not match.
    @Test func unrelatedFilesAreIgnored() throws {
        let directory = try directory("unrelated")
        for name in ["usage.json", "usage-claude.json.1234.tmp", "notes.txt", "dash-usage-claude.json"] {
            try Data(usageJSON(resetsAt: farFuture()).utf8)
                .write(to: directory.appendingPathComponent(name))
        }

        let collector = EventCollector()
        let reader = StatuslineReader(
            directory: directory.path, debounce: .milliseconds(20), sweepInterval: .seconds(60)
        ) { collector.record($0) }
        reader.start()
        defer { reader.stop() }

        _ = collector.wait(for: 0.5) { _ in false }
        #expect(reader.usageSnapshot().isEmpty)
        #expect(collector.all.isEmpty)
    }

    /// A directory that does not exist when the reader starts — the normal state before the user
    /// consents — is picked up by the sweep rather than needing a restart.
    @Test func aDirectoryThatAppearsLaterIsPickedUp() throws {
        let root = try StatuslineTestSupport.tempDirectory("late")
        let statusline = root.appendingPathComponent("statusline", isDirectory: true)

        let collector = EventCollector()
        let reader = StatuslineReader(
            directory: statusline.path, debounce: .milliseconds(20), sweepInterval: .milliseconds(100)
        ) { collector.record($0) }
        reader.start()
        defer { reader.stop() }

        try FileManager.default.createDirectory(at: statusline, withIntermediateDirectories: true)
        try write(usageJSON(resetsAt: farFuture()), "usage-claude.json", in: statusline)

        let events = collector.wait { $0.contains { $0.usage != nil } }
        #expect(events.compactMap(\.usage).first?.accountKey == "claude")
    }

    /// A context sidecar nothing will read again is unlinked, so an abandoned directory does not
    /// grow forever.
    @Test func housekeepingDeletesAWeekOldContextSidecar() throws {
        let directory = try directory("housekeep")
        let name = "context-s1.json"
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-8 * 24 * 3600))
        try write(#"{"updated_at":"\#(old)","session_id":"s1"}"#, name, in: directory)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: directory.appendingPathComponent(name).path)

        let collector = EventCollector()
        let reader = StatuslineReader(
            directory: directory.path, debounce: .milliseconds(20), sweepInterval: .milliseconds(100)
        ) { collector.record($0) }
        reader.start()
        defer { reader.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            usleep(20_000)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
    }
}

@Suite struct StatuslineStoreTests {
    /// The join is on Claude's own session id, not tkzmux's: the sidecar is written by a statusline
    /// that knows nothing about rows.
    @Test func aSidecarLandsOnTheRowWithTheMatchingClaudeSessionId() {
        var state = AppState.fixture
        guard let session = state.sessions.values.first else { Issue.record("no fixture"); return }
        state.sessions[session.id]?.claudeSessionId = "conv-1"

        state.setSessionSidecar(SessionSidecar(sessionId: "conv-1", contextUsedPercentage: 62))
        #expect(state.sessions[session.id]?.live?.context?.contextUsedPercentage == 62)

        state.clearSessionSidecar(claudeSessionId: "conv-1")
        #expect(state.sessions[session.id]?.live?.context == nil)
    }

    /// A sidecar for a conversation no row is running is dropped rather than landing on some other
    /// row — a resume rotates the id, and the old one must simply stop matching.
    @Test func aSidecarForAnUnknownConversationIsDropped() {
        var state = AppState.fixture
        let before = state.sessions
        state.setSessionSidecar(SessionSidecar(sessionId: "nobody", contextUsedPercentage: 10))
        #expect(state.sessions == before)
    }

    @Test func clearUsageRemovesTheAccountEntirely() {
        var state = AppState.fixture
        state.setUsage(UsageSnapshot(accountKey: "claude", sevenDay: UsageWindow(usedPercentage: 5)))
        #expect(state.usage["claude"] != nil)
        state.clearUsage(for: "claude")
        #expect(state.usage["claude"] == nil)
    }
}
