// AntigravityTranscriptReader — first prompt and recap out of an Antigravity transcript.
//
// The transcript is append-only NDJSON at
// `<config>/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript_full.jsonl`,
// one flat object per step:
//
//   {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE",
//    "created_at":"2026-09-19T10:44:52Z","content":"<USER_REQUEST>…</USER_REQUEST>…"}
//   {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE", …,"content":"pong"}
//
// **snake_case here, camelCase in the hook payload.** Both were measured off Antigravity CLI 1.2.7
// and captured in this module's test target's `Fixtures/antigravity/`; the mismatch is the agent's,
// not a transcription slip.
//
// What this file borrows wholesale is the *reading discipline* `TranscriptReader` already
// established — bounded head-and-tail reads, skip whatever you do not recognise — so it stays about
// Antigravity's own shapes rather than about how to read a large file safely a third time.
//
// It deliberately computes **no usage**. Antigravity records no token or cost accounting anywhere
// (see the fixtures README), so `AntigravityAdapter` does not claim `.transcriptUsage` and `usage`
// below returns `nil` rather than a number nobody has measured.

import Foundation
import TkzCore

public struct AntigravityTranscriptReader: TranscriptProvider {
    /// Trivial on purpose: `AntigravityAdapter.transcript` builds one fresh on every access.
    public init() {}

    /// The `USER_REQUEST` tag Antigravity wraps a typed prompt in, along with the metadata blocks
    /// it appends after it. The card must show what the human typed, not the envelope.
    static let requestOpen = "<USER_REQUEST>"
    static let requestClose = "</USER_REQUEST>"

    // MARK: - Locate

    /// `<configDir>/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript_full.jsonl`.
    ///
    /// **This is a fallback, not the hot path**: every Antigravity hook payload carries
    /// `transcriptPath` directly, so a live row already knows its file. This exists for a restored
    /// row whose agent is not running and which will therefore never see a hook frame.
    ///
    /// The path is fully determined by the conversation id, so unlike the other readers in this
    /// module there is no
    /// directory to scan — but the id still has to be checked, because it lands in a path.
    public func locate(conversationId: String, configDir: String, fileManager: FileManager) -> String? {
        guard !conversationId.isEmpty, !conversationId.contains("/"),
            conversationId != ".", conversationId != ".."
        else { return nil }
        let path = Self.transcriptPath(conversationId: conversationId, configDir: configDir)
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    /// The pure half of ``locate(conversationId:configDir:fileManager:)``, so a test can assert the
    /// layout without a file on disk.
    static func transcriptPath(conversationId: String, configDir: String) -> String {
        var path = configDir as NSString
        for component in [
            "antigravity-cli", "brain", conversationId, ".system_generated", "logs",
            "transcript_full.jsonl",
        ] {
            path = path.appendingPathComponent(component) as NSString
        }
        return path as String
    }

    // MARK: - Summary

    public func summary(path: String) throws -> TranscriptSummary {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        guard size > 0 else { return TranscriptSummary() }

        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: min(size, TranscriptReader.headLimit)) ?? Data()

        let tailStart = max(0, size - TranscriptReader.tailLimit)
        let tail: Data
        if tailStart == 0 {
            if head.count == size {
                tail = head
            } else {
                try handle.seek(toOffset: 0)
                tail = try handle.readToEnd() ?? Data()
            }
        } else {
            try handle.seek(toOffset: UInt64(tailStart))
            var bytes = try handle.readToEnd() ?? Data()
            // The cut almost certainly landed mid-line; drop the partial first line.
            if let newline = bytes.firstIndex(of: 0x0A) {
                bytes = bytes[bytes.index(after: newline)...]
            } else {
                bytes = Data()
            }
            tail = bytes
        }
        return Self.parse(head: head, tail: tail)
    }

    /// The pure half: the head is scanned forward for the first prompt and stops there; the tail is
    /// scanned backward for the newest model response.
    static func parse(head: Data, tail: Data) -> TranscriptSummary {
        var summary = TranscriptSummary()

        for line in TranscriptReader.lines(of: head) {
            guard let object = TranscriptReader.decode(line) else { continue }
            guard object["type"] as? String == "USER_INPUT",
                object["source"] as? String == "USER_EXPLICIT",
                let content = object["content"] as? String
            else { continue }
            let prompt = userRequest(in: content)
            guard !prompt.isEmpty else { continue }
            summary.firstPrompt = prompt
            summary.firstPromptAt = timestamp(object)
            summary.firstPromptCommand = PromptCommand.parse(prompt)
            break
        }

        for line in TranscriptReader.lines(of: tail).reversed() {
            guard let object = TranscriptReader.decode(line) else { continue }
            guard object["source"] as? String == "MODEL",
                object["status"] as? String == "DONE",
                let content = object["content"] as? String,
                !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            summary.recap = content
            summary.recapAt = timestamp(object)
            summary.recapSource = .assistantText
            break
        }

        return summary
    }

    /// What the human actually typed. Antigravity wraps it in `<USER_REQUEST>` and then appends
    /// `<ADDITIONAL_METADATA>` and `<USER_SETTINGS_CHANGE>` blocks describing the local time and any
    /// settings the user changed — none of which the first-prompt card should ever show.
    ///
    /// A payload with no tag at all is returned whole rather than dropped: the wrapper is what was
    /// measured on 1.2.7, and a future version that stops using it should degrade to showing the
    /// prompt, not to showing nothing.
    static func userRequest(in content: String) -> String {
        guard let open = content.range(of: requestOpen) else {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rest = content[open.upperBound...]
        guard let close = rest.range(of: requestClose) else {
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Antigravity stamps `created_at`, where the other agents' transcripts say `timestamp`, so
    /// `TranscriptReader.timestamp(of:)` cannot be reused directly — only its parsing can.
    private static func timestamp(_ object: [String: Any]) -> Date? {
        guard let raw = object["created_at"] as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw))
            ?? (try? Date.ISO8601FormatStyle().parse(raw))
    }

    // MARK: - Usage

    /// Always `nil`, and deliberately so.
    ///
    /// Antigravity records no token or cost accounting that tkzmux can read — not in the transcript,
    /// not under `brain/`, not in any config file (searched after a real turn; see the fixtures
    /// README). `nil` is different from zero and leaves the spend badge hidden, which is the honest
    /// outcome. `AntigravityAdapter` does not claim `.transcriptUsage`, so nothing should call this
    /// in the first place.
    public func usage(
        conversationId: String, path: String, reader: TranscriptUsageReader
    ) async -> SessionUsage? { nil }

    // MARK: - Search

    public func searchIndex(path: String, existing: TranscriptIndex?) throws -> TranscriptIndex {
        try TranscriptIndex.build(path: path, existing: existing)
    }
}
