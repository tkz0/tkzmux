// AntigravityTranscriptReaderTests — the transcript half, against the captured fixture.

import Foundation
import Testing
import TkzCore

@testable import AgentBridge

@Suite struct AntigravityTranscriptReaderTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/antigravity")

    static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtures.appendingPathComponent(name))
    }

    @Test("The first prompt is what the human typed, not the envelope around it")
    func firstPromptStripsTheRequestTags() throws {
        let data = try Self.fixtureData("transcript-short.jsonl")
        let summary = AntigravityTranscriptReader.parse(head: data, tail: data)

        // Antigravity wraps the prompt in <USER_REQUEST> and then appends metadata blocks about the
        // local time and any settings the user changed. The card must show none of that.
        #expect(summary.firstPrompt == "Reply with exactly the word: pong")
        #expect(summary.firstPrompt?.contains("USER_REQUEST") == false)
        #expect(summary.firstPrompt?.contains("ADDITIONAL_METADATA") == false)
        #expect(summary.firstPrompt?.contains("Model Selection") == false)
        #expect(summary.firstPromptAt != nil, "created_at, not timestamp")
    }

    @Test("The recap is the newest completed model response")
    func recapIsTheNewestModelStep() throws {
        let data = try Self.fixtureData("transcript-short.jsonl")
        let summary = AntigravityTranscriptReader.parse(head: data, tail: data)
        #expect(summary.recap == "pong")
        #expect(summary.recapSource == .assistantText)
        #expect(summary.recapAt != nil)
    }

    @Test("A step that is not a finished model response is not a recap")
    func onlyDoneModelStepsBecomeRecaps() {
        let lines = [
            #"{"step_index":0,"source":"MODEL","type":"PLANNER_RESPONSE","status":"RUNNING","content":"half"}"#,
            #"{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"hi"}"#,
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let summary = AntigravityTranscriptReader.parse(head: data, tail: data)
        // A half-written response must not be shown as the recap, and a user step is never one.
        #expect(summary.recap == nil)
    }

    @Test("The prompt survives a future version that stops wrapping it in tags")
    func anUntaggedPromptIsNotDropped() {
        // Degrading to showing the prompt beats degrading to showing nothing.
        #expect(AntigravityTranscriptReader.userRequest(in: "just text") == "just text")
        #expect(
            AntigravityTranscriptReader.userRequest(in: "<USER_REQUEST>\nhi\n</USER_REQUEST>\ntail")
                == "hi")
        // An opening tag with no close still yields the rest rather than nothing.
        #expect(AntigravityTranscriptReader.userRequest(in: "<USER_REQUEST>\nhi") == "hi")
    }

    @Test("The transcript path is derived from the conversation id, and a hostile id is refused")
    func locateRefusesAHostileConversationId() throws {
        let reader = AntigravityTranscriptReader()
        #expect(
            AntigravityTranscriptReader.transcriptPath(
                conversationId: "abc", configDir: "/Users/tester/.gemini")
                == "/Users/tester/.gemini/antigravity-cli/brain/abc/.system_generated/logs/transcript_full.jsonl")

        // The id lands in a path, so it has to be checked before it is used as one.
        for hostile in ["", "..", ".", "../../etc", "a/b"] {
            #expect(
                reader.locate(conversationId: hostile, configDir: "/Users/tester/.gemini", fileManager: .default) == nil,
                "\(hostile)")
        }
    }

    @Test("Locate finds a real file and returns nil when there is none")
    func locateFindsTheFile() throws {
        let root = try ShimTestSupport.makeTempDirectory("antigravity-transcript")
        defer { try? FileManager.default.removeItem(at: root) }
        let conversation = "ec33ebf9-0cba-4100-8142-c61503f6c587"
        let path = AntigravityTranscriptReader.transcriptPath(
            conversationId: conversation, configDir: root.path)
        let reader = AntigravityTranscriptReader()
        #expect(reader.locate(conversationId: conversation, configDir: root.path, fileManager: .default) == nil)

        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.fixtureData("transcript-short.jsonl").write(to: url)
        #expect(reader.locate(conversationId: conversation, configDir: root.path, fileManager: .default) == path)

        // And the summary reads off the located file, end to end.
        let summary = try reader.summary(path: path)
        #expect(summary.firstPrompt == "Reply with exactly the word: pong")
    }

    @Test("Usage is always nil, matching the absent capability")
    func usageIsAlwaysNil() async {
        let usage = await AntigravityTranscriptReader().usage(
            conversationId: "x", path: "/nonexistent",
            reader: TranscriptUsageReader(cacheDirectory: NSTemporaryDirectory()))
        #expect(usage == nil)
    }
}
