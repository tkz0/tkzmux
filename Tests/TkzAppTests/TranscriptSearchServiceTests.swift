import Foundation
import Testing
import TkzCore

@testable import ClaudeBridge
@testable import TkzApp

/// The Transcripts section's engine: indexes per open session, and the caps that keep them from
/// becoming the leak `PerSessionCacheEvictionTests` exists to prevent (TKZ-52).
@Suite(.serialized)
struct TranscriptSearchServiceTests {

    // MARK: Fixtures

    struct Scratch {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tkz-transcript-search-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        func write(_ lines: [String], named name: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            return url.path
        }

        func append(_ line: String, to path: String) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            try handle.close()
        }

        func tearDown() { try? FileManager.default.removeItem(at: directory) }
    }

    static func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    static func prompt(_ text: String, at: String = "2026-09-11T08:00:00.000Z") -> String {
        json(["type": "user", "timestamp": at, "message": ["role": "user", "content": text]])
    }

    static func target(_ path: String, title: String = "Session") -> TranscriptSearchService.Target {
        TranscriptSearchService.Target(
            sessionID: SessionID(uuid: UUID()), title: title, path: path)
    }

    // MARK: Searching

    @Test func hitsCarryTheSessionTheyCameFrom() async throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let path = try scratch.write([Self.prompt("fix the websocket loop")], named: "a.jsonl")
        let target = Self.target(path, title: "Fix reconnect")

        let service = TranscriptSearchService()
        let results = await service.search("websocket", in: [target], limit: 10)

        #expect(results.count == 1)
        #expect(results.first?.target.sessionID == target.sessionID)
        #expect(results.first?.hit.excerpt == "fix the websocket loop")
    }

    @Test func hitsAcrossSessionsComeBackNewestFirst() async throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let older = Self.target(
            try scratch.write(
                [Self.prompt("websocket, on monday", at: "2026-09-08T08:00:00.000Z")],
                named: "old.jsonl"), title: "Older")
        let newer = Self.target(
            try scratch.write(
                [Self.prompt("websocket, an hour ago", at: "2026-09-11T18:00:00.000Z")],
                named: "new.jsonl"), title: "Newer")

        let service = TranscriptSearchService()
        let results = await service.search("websocket", in: [older, newer], limit: 10)
        #expect(results.map(\.target.title) == ["Newer", "Older"])
    }

    @Test func aQueryShorterThanTwoCharactersIsNotASearch() async throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let target = Self.target(try scratch.write([Self.prompt("websocket")], named: "a.jsonl"))

        let service = TranscriptSearchService()
        #expect(await service.search("w", in: [target], limit: 10).isEmpty)
        #expect(await service.search("  ", in: [target], limit: 10).isEmpty)
        #expect(!(await service.search("we", in: [target], limit: 10).isEmpty))
    }

    @Test func anUnreadableTranscriptIsSkippedRatherThanFailingTheSearch() async throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let good = Self.target(
            try scratch.write([Self.prompt("websocket here")], named: "a.jsonl"), title: "Good")
        let missing = Self.target(scratch.directory.appendingPathComponent("gone.jsonl").path)

        let service = TranscriptSearchService()
        let results = await service.search("websocket", in: [missing, good], limit: 10)
        #expect(results.map(\.target.title) == ["Good"])
    }

    @Test func aSecondSearchSeesWhatTheSessionAppended() async throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let path = try scratch.write([Self.prompt("first websocket line")], named: "a.jsonl")
        let target = Self.target(path)
        let service = TranscriptSearchService()

        #expect(await service.search("websocket", in: [target], limit: 10).count == 1)
        try scratch.append(Self.prompt("second websocket line"), to: path)
        #expect(await service.search("websocket", in: [target], limit: 10).count == 2)
    }

    @Test func theLimitCapsWhatComesBack() async throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let path = try scratch.write(
            (1...10).map { Self.prompt("websocket \($0)") }, named: "a.jsonl")

        let service = TranscriptSearchService()
        #expect(await service.search("websocket", in: [Self.target(path)], limit: 3).count == 3)
    }

    // MARK: Eviction

    @Test func closingASessionDropsItsIndexAtTheNextSearch() async throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let a = Self.target(try scratch.write([Self.prompt("websocket a")], named: "a.jsonl"))
        let b = Self.target(try scratch.write([Self.prompt("websocket b")], named: "b.jsonl"))
        let service = TranscriptSearchService()

        _ = await service.search("websocket", in: [a, b], limit: 10)
        #expect(await service.indexedSessionsForTesting == [a.sessionID, b.sessionID])

        // `b` is gone from the sidebar; the next keystroke must not keep paying for it.
        _ = await service.search("websocket", in: [a], limit: 10)
        #expect(await service.indexedSessionsForTesting == [a.sessionID])
    }

    @Test func forgetDropsAnIndexImmediately() async throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let a = Self.target(try scratch.write([Self.prompt("websocket a")], named: "a.jsonl"))
        let service = TranscriptSearchService()

        _ = await service.search("websocket", in: [a], limit: 10)
        #expect(await !service.indexedSessionsForTesting.isEmpty)
        await service.forget(a.sessionID)
        #expect(await service.indexedSessionsForTesting.isEmpty)

        await service.forgetAll()
        #expect(await service.retainedCharactersForTesting == 0)
    }

    @Test func theFleetOfIndexesStaysUnderItsCharacterCap() async throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        // Each file holds ~300 characters, and the service is given a 500-character budget: two
        // files already cross it. Driving the real 8 MB cap would mean writing megabytes, which is
        // both slow and — as the first version of this test proved — easy to get wrong. That one
        // wrote 6 M characters against an 8 M cap and so evicted nothing while still passing.
        var targets: [TranscriptSearchService.Target] = []
        for file in 1...4 {
            let lines = (1...3).map {
                Self.prompt("\(file)-\($0) websocket \(String(repeating: "y", count: 90))")
            }
            targets.append(Self.target(try scratch.write(lines, named: "\(file).jsonl")))
        }

        let service = TranscriptSearchService(characterLimit: 500)
        _ = await service.search("websocket", in: targets, limit: 40)

        let retained = await service.retainedCharactersForTesting
        #expect(retained <= 500)
        #expect(retained > 0, "the most recently searched sessions stay indexed")

        let indexed = await service.indexedSessionsForTesting
        #expect(indexed.count < targets.count, "something was actually evicted")
        // Evictions come off the least-recently-searched end, so the last file searched survives
        // and the first one does not.
        #expect(indexed.contains(targets[3].sessionID))
        #expect(!indexed.contains(targets[0].sessionID))
    }

    @Test func theRealCapIsTheOneTheServiceShipsWith() async throws {
        // The injected budget above must not be mistaken for a relaxed default.
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let target = Self.target(try scratch.write([Self.prompt("websocket")], named: "a.jsonl"))
        let service = TranscriptSearchService()
        _ = await service.search("websocket", in: [target], limit: 10)
        #expect(await service.indexedSessionsForTesting == [target.sessionID])
        #expect(TranscriptSearchService.characterLimit == 8_000_000)
    }

    // MARK: Rows

    @Test @MainActor func aResultBecomesTheRowTheOverlayDraws() async throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let path = try scratch.write(
            [Self.prompt("fix the websocket reconnect loop")], named: "a.jsonl")
        let target = Self.target(path, title: "Fix reconnect")

        let service = TranscriptSearchService()
        let result = try #require(
            await service.search("websocket", in: [target], limit: 10).first)
        let row = result.row()

        #expect(row.sessionID == target.sessionID)
        #expect(row.sessionTitle == "Fix reconnect")
        #expect(row.kind == .user)
        #expect(row.turn == 1)
        let range = try #require(row.matchRanges.first)
        #expect(String(row.excerpt[range]) == "websocket")
    }
}
