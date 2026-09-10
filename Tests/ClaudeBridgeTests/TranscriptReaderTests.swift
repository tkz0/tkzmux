// TranscriptReaderTests — the first-prompt / recap rules against a synthetic transcript.
//
// `Fixtures/transcript/session.jsonl` is hand-written to carry every shape the reader has to get
// right: a `/clear` echo and its caveat before the real prompt, a content-array prompt with an
// image block, an `isMeta` image line, tool-result-only user lines, a sidechain prompt, two
// `away_summary` lines, two `ai-title` lines, and a torn last line. Nothing in it is a real
// person's path or name.

import Foundation
import Testing

@testable import ClaudeBridge

@Suite("TranscriptReader")
struct TranscriptReaderTests {

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript/session.jsonl")
    }

    private static func fixture() throws -> Data { try Data(contentsOf: fixtureURL) }

    @Test("The first prompt is the first line a human typed, not a command echo or a tool result")
    func firstPromptSkipsTheNoise() throws {
        let data = try Self.fixture()
        let summary = TranscriptReader.parse(head: data, tail: data)
        #expect(summary.firstPrompt
            == "Add an audit trail to the position service so the UI can show who changed what. [Image #1]")
        #expect(summary.firstPromptAt == ISO8601DateFormatter().date(from: "2026-09-10T08:01:02Z"))
    }

    @Test("The recap is the newest away_summary, and the title the newest ai-title")
    func recapIsTheNewestAwaySummary() throws {
        let data = try Self.fixture()
        let summary = TranscriptReader.parse(head: data, tail: data)
        #expect(summary.recap?.hasPrefix("Audit trail done and covered") == true)
        #expect(summary.recapSource == .awaySummary)
        #expect(summary.recapAt == ISO8601DateFormatter().date(from: "2026-09-10T08:28:00Z"))
        #expect(summary.title == "Position audit trail and tests")
    }

    @Test("Without an away_summary the newest assistant text stands in")
    func assistantTextFallback() throws {
        let lines = String(decoding: try Self.fixture(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.contains("\"away_summary\"") }
        let data = Data(lines.joined(separator: "\n").utf8)
        let summary = TranscriptReader.parse(head: data, tail: data)
        #expect(summary.recap == "Integration test written; 48 passing.")
        #expect(summary.recapSource == .assistantText)
    }

    @Test("Bad lines and a torn tail are skipped, not fatal")
    func tornAndBadLinesAreSkipped() throws {
        var data = Data("not json\n".utf8)
        data.append(try Self.fixture())
        let summary = TranscriptReader.parse(head: data, tail: data)
        #expect(summary.firstPrompt != nil)
        #expect(summary.recap != nil)
        #expect(TranscriptReader.parse(head: Data(), tail: Data()).isEmpty)
    }

    @Test("A prompt beyond the head limit is not found rather than searched for")
    func headLimitIsRespected() throws {
        let data = try Self.fixture()
        let head = data.prefix(200)  // ends inside the caveat line
        let summary = TranscriptReader.parse(head: head, tail: data)
        #expect(summary.firstPrompt == nil)
        #expect(summary.recap != nil)
    }

    @Test("read(path:) reads the ends of a file and drops the partial line at the tail cut")
    func readsHeadAndTailFromDisk() throws {
        let summary = try TranscriptReader.read(path: Self.fixtureURL.path, headLimit: 4096, tailLimit: 900)
        #expect(summary.firstPrompt?.hasPrefix("Add an audit trail") == true)
        // 900 bytes from the end covers the torn line, the tool_use, the last away_summary — and a
        // partial line at the cut, which must be dropped rather than mis-parsed.
        #expect(summary.recap?.hasPrefix("Audit trail done") == true)
        #expect(summary.recapSource == .awaySummary)
    }

    @Test("locate finds <configDir>/projects/*/<sessionId>.jsonl")
    func locateFindsTheTranscript() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tkzmux-transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/-work-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let path = project.appendingPathComponent("abc-123.jsonl")
        try Data("{}\n".utf8).write(to: path)

        #expect(TranscriptReader.locate(sessionId: "abc-123", configDir: root.path) == path.path)
        #expect(TranscriptReader.locate(sessionId: "missing", configDir: root.path) == nil)
        #expect(TranscriptReader.locate(sessionId: "../etc", configDir: root.path) == nil)
    }
}
