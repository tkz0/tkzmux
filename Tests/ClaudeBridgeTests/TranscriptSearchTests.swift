import Foundation
import Testing

@testable import ClaudeBridge

/// Searching inside a Claude transcript (TKZ-52, design 2c.6's Transcripts section).
///
/// The fixture below is the line shape a real `~/.claude/projects/**/*.jsonl` has: prompts, answers
/// with `text` and `tool_use` blocks, sidechains and meta lines that must not be indexed at all.
struct TranscriptSearchTests {

    // MARK: Fixture

    static func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    static func prompt(_ text: String, at: String = "2026-09-11T08:00:00.000Z") -> String {
        line(["type": "user", "timestamp": at, "message": ["role": "user", "content": text]])
    }

    static func answer(_ text: String, at: String = "2026-09-11T08:00:10.000Z") -> String {
        line([
            "type": "assistant", "timestamp": at,
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
        ])
    }

    static func tool(_ name: String, _ input: [String: Any]) -> String {
        line([
            "type": "assistant", "timestamp": "2026-09-11T08:00:20.000Z",
            "message": [
                "role": "assistant",
                "content": [["type": "tool_use", "name": name, "input": input]],
            ],
        ])
    }

    static let transcript = [
        prompt("fix the websocket reconnect loop"),
        answer("the websocket client drops the token on 1006 close frames"),
        tool("Bash", ["command": "wscat -c ws://localhost:5101/websocket"]),
        prompt("now push summaries over the feed instead of polling"),
        answer("done \u{2014} the feed is live"),
    ].joined(separator: "\n").data(using: .utf8)!

    static func index(_ data: Data = transcript) -> TranscriptIndex {
        TranscriptIndex().appending(data, fileSize: data.count, readTo: data.count)
    }

    static func search(_ query: String, in index: TranscriptIndex, limit: Int = 20)
        -> [TranscriptSearchHit]
    {
        index.search(foldedNeedle: TranscriptIndex.fold(query), limit: limit)
    }

    // MARK: Indexing

    @Test func everyKindOfLineIsIndexedAndNumbered() {
        let index = Self.index()
        #expect(index.turns == 2, "two human prompts, two turns")

        let kinds = index.lines.map(\.kind)
        #expect(kinds == [.user, .assistant, .tool, .user, .assistant])
        // A turn starts at its prompt and owns everything Claude did after it.
        #expect(index.lines.map(\.turn) == [1, 1, 1, 2, 2])
    }

    @Test func aToolCallIsSummarisedByItsFirstTellingArgument() {
        let index = Self.index()
        let tool = index.lines.first { $0.kind == .tool }
        #expect(tool?.text == "Bash(wscat -c ws://localhost:5101/websocket)")
    }

    @Test func toolCallsWithoutAKnownArgumentStillNameThemselves() {
        let data = Self.tool("TodoWrite", ["todos": ["a", "b"]]).data(using: .utf8)!
        let index = Self.index(data)
        #expect(index.lines.first?.text == "TodoWrite()")
    }

    @Test func sidechainsAndMetaLinesAreNotIndexed() {
        let noise = [
            Self.line([
                "type": "user", "isMeta": true,
                "message": ["role": "user", "content": "websocket meta"],
            ]),
            Self.line([
                "type": "user", "isSidechain": true,
                "message": ["role": "user", "content": "websocket sidechain"],
            ]),
            Self.line([
                "type": "user",
                "message": ["role": "user", "content": "<command-name>/clear</command-name>"],
            ]),
            Self.line(["type": "system", "subtype": "away_summary", "content": "websocket recap"]),
        ].joined(separator: "\n").data(using: .utf8)!

        let index = Self.index(noise)
        #expect(index.lines.isEmpty)
        #expect(index.turns == 0)
    }

    @Test func aTornLineIsSkippedRatherThanEndingTheParse() {
        let data = ("{\"type\":\"user\",\"mes" + "\n" + Self.prompt("websocket survives"))
            .data(using: .utf8)!
        let index = Self.index(data)
        #expect(index.lines.count == 1)
        #expect(index.lines.first?.text == "websocket survives")
    }

    @Test func textIsCollapsedToOneLine() {
        let data = Self.prompt("a\n\n  b\tc   d").data(using: .utf8)!
        #expect(Self.index(data).lines.first?.text == "a b c d")
    }

    // MARK: Searching

    @Test func aMatchCarriesItsTurnKindAndExcerpt() throws {
        let hits = Self.search("websocket", in: Self.index())
        #expect(hits.count == 3, "prompt, answer and tool call all mention it")

        // Newest first: a conversation is read from its end.
        let first = try #require(hits.first)
        #expect(first.kind == .tool)
        #expect(first.turn == 1)

        let answer = try #require(hits.first { $0.kind == .assistant })
        #expect(answer.excerpt == "the websocket client drops the token on 1006 close frames")
        let range = try #require(answer.matchRange)
        #expect(String(answer.excerpt[range]) == "websocket")
    }

    @Test func matchingIgnoresCaseAndDiacritics() throws {
        let index = Self.index(Self.prompt("the Réconnect loop").data(using: .utf8)!)
        let hits = Self.search("reconnect", in: index)
        let hit = try #require(hits.first)
        let range = try #require(hit.matchRange)
        #expect(String(hit.excerpt[range]) == "Réconnect", "the original text is what gets marked")
    }

    @Test func aQueryThatIsNotThereFindsNothing() {
        #expect(Self.search("kubernetes", in: Self.index()).isEmpty)
        #expect(Self.search("", in: Self.index()).isEmpty, "an empty needle is not a match-all")
    }

    @Test func matchingIsLiteralAndNotFuzzy() {
        // "wst" is a subsequence of "websocket"; a fuzzy matcher would call that a hit.
        #expect(Self.search("wst", in: Self.index()).isEmpty)
    }

    @Test func theLimitStopsTheScan() {
        #expect(Self.search("websocket", in: Self.index(), limit: 2).count == 2)
    }

    // MARK: Excerpts

    @Test func aLongLineIsWindowedAroundTheMatch() throws {
        let filler = String(repeating: "x ", count: 200)
        let index = Self.index(Self.prompt(filler + "websocket " + filler).data(using: .utf8)!)
        let hit = try #require(Self.search("websocket", in: index).first)

        #expect(hit.excerpt.count <= TranscriptIndex.excerptWidth + 2, "plus the two ellipses")
        #expect(hit.excerpt.hasPrefix("\u{2026}"))
        #expect(hit.excerpt.hasSuffix("\u{2026}"))
        let range = try #require(hit.matchRange)
        #expect(String(hit.excerpt[range]) == "websocket", "the window must not shift the mark")
    }

    @Test func aMatchAtTheStartKeepsItsLeadingText() throws {
        let index = Self.index(
            Self.prompt("websocket " + String(repeating: "x ", count: 200)).data(using: .utf8)!)
        let hit = try #require(Self.search("websocket", in: index).first)
        #expect(!hit.excerpt.hasPrefix("\u{2026}"))
        #expect(hit.matchOffset == 0)
        let range = try #require(hit.matchRange)
        #expect(String(hit.excerpt[range]) == "websocket")
    }

    @Test func aShortLineIsItsOwnExcerpt() throws {
        let hit = try #require(Self.search("reconnect", in: Self.index()).first)
        #expect(hit.excerpt == "fix the websocket reconnect loop")
    }

    // MARK: Incremental build

    @Test func appendedLinesExtendTheIndexAndKeepCounting() {
        var index = Self.index()
        let more = Self.prompt("a third websocket question").data(using: .utf8)!
        index = index.appending(
            more, fileSize: Self.transcript.count + more.count,
            readTo: Self.transcript.count + more.count)

        #expect(index.turns == 3)
        #expect(index.lines.last?.turn == 3)
        #expect(Self.search("websocket", in: index).count == 4)
    }

    @Test func aGrownFileIsReadFromWhereTheLastBuildStopped() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.jsonl")

        try (Self.transcript + Data("\n".utf8)).write(to: url)
        let first = try TranscriptIndex.build(path: url.path)
        #expect(first.turns == 2)
        #expect(first.byteOffset == first.fileSize)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.prompt("appended websocket line") + "\n").utf8))
        try handle.close()

        let second = try TranscriptIndex.build(path: url.path, existing: first)
        #expect(second.turns == 3, "the appended prompt is a new turn")
        #expect(second.lines.count == first.lines.count + 1)
        #expect(second.byteOffset > first.byteOffset)
    }

    @Test func anUnchangedFileIsNotReadAgain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.jsonl")
        try Self.transcript.write(to: url)

        let first = try TranscriptIndex.build(path: url.path)
        let second = try TranscriptIndex.build(path: url.path, existing: first)
        #expect(second.lines.count == first.lines.count, "a re-index must not double the lines")
        #expect(second.turns == first.turns)
    }

    @Test func anEmptyFileIndexesToNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.jsonl")
        try Data().write(to: url)
        #expect(try TranscriptIndex.build(path: url.path).lines.isEmpty)
    }

    @Test func aMissingFileThrowsRatherThanReturningEmpty() {
        #expect(throws: (any Error).self) {
            try TranscriptIndex.build(path: "/nonexistent/session.jsonl")
        }
    }

    // MARK: Caps

    @Test func theRetainedTextIsBoundedAndKeepsTheNewestLines() {
        // A retained line is clipped to 2 000 characters, so ~1 200 of them is comfortably past
        // the 2 MB cap. One `appending` call rather than 1 200: the incremental path has its own
        // tests, and this one is about the caps.
        let filler = String(repeating: "y", count: 2_000)
        let turns = 1_200
        let data = (1...turns)
            .map { Self.prompt("\($0) \(filler)") }
            .joined(separator: "\n")
            .data(using: .utf8)!

        let index = Self.index(data)
        #expect(index.retainedCharacters <= TranscriptIndex.textLimit)
        #expect(index.lines.count <= TranscriptIndex.lineLimit)
        #expect(index.lines.count < turns, "the cap really bit")
        #expect(index.turns == turns, "the turn count survives even when its lines do not")
        #expect(index.lines.last?.text.hasPrefix("\(turns) ") == true, "the newest line is kept")
        #expect(index.lines.first?.text.hasPrefix("1 ") == false, "the oldest lines went first")
    }

    @Test func theRetainedCountStaysInStepWithTheLinesItCounts() {
        // It is carried incrementally now (a `reduce` per keystroke per session was real work), so
        // it has to agree with the lines actually held — after a trim as much as before one.
        var index = Self.index()
        #expect(index.retainedCharacters == index.lines.reduce(0) { $0 + $1.text.count })

        let filler = String(repeating: "z", count: 2_000)
        for turn in 1...1_200 {
            index = index.appending(
                Self.prompt("\(turn) \(filler)").data(using: .utf8)!, fileSize: 0, readTo: 0)
        }
        #expect(index.retainedCharacters == index.lines.reduce(0) { $0 + $1.text.count })
        #expect(index.retainedCharacters <= TranscriptIndex.textLimit)
    }

    @Test func aSingleEnormousLineIsClipped() {
        let data = Self.prompt(String(repeating: "z", count: 50_000)).data(using: .utf8)!
        let index = Self.index(data)
        #expect(index.lines.first?.text.count == TranscriptIndex.lineTextLimit)
    }
}
