// TranscriptReader — the first prompt and Claude's own recap, out of a Claude Code transcript.
//
// Claude Code keeps every conversation as append-only NDJSON at
// `<configDir>/projects/<mangled cwd>/<sessionId>.jsonl`. The first-prompt card (design 2c.5)
// wants two things out of it, and both live at the ends of the file:
//
//   * the **first prompt** — the first `"type":"user"` line that a human actually typed. The head
//     of a transcript is noisy: `/clear` echoes and their `<local-command-caveat>` wrappers, meta
//     lines, and tool results all arrive as `user` too, so this walks forward and skips them.
//   * the **recap** — the newest `"type":"system"` line with `"subtype":"away_summary"`, which is
//     Claude's own summary of the session so far ("Goal was …; that's done and open as PR #14.
//     Next: …"). It lands a few minutes after a turn's Stop, so a reader that only looked at the
//     hook's `last_assistant_message` would show the wrong thing; that message is the fallback,
//     and the last assistant `text` block in the tail is the fallback's fallback.
//
// A transcript can be tens of megabytes (a `/loop` session writes one line per tick for hours),
// so this never reads the whole file: `headLimit` bytes from the front, `tailLimit` from the back,
// each parsed line by line with bad lines skipped. `parse(head:tail:)` is pure so the rules are
// testable on a synthetic fixture; `read(path:)` is the file front and runs on whatever queue
// calls it — never the main one.

import Foundation

/// What the card shows. `nil` fields mean "not in the part of the file that was read".
public struct TranscriptSummary: Hashable, Sendable {
    /// Where the recap text came from, so the card can label it honestly.
    public enum RecapSource: Hashable, Sendable {
        /// Claude's own `away_summary` — the real thing.
        case awaySummary
        /// The `Stop` hook's `last_assistant_message`, merged in by the caller.
        case stopMessage
        /// The newest assistant `text` block in the tail.
        case assistantText
    }

    public var firstPrompt: String?
    public var firstPromptAt: Date?
    public var recap: String?
    public var recapAt: Date?
    public var recapSource: RecapSource?
    /// The newest `ai-title`, when Claude has named the conversation.
    public var title: String?

    public init(
        firstPrompt: String? = nil, firstPromptAt: Date? = nil,
        recap: String? = nil, recapAt: Date? = nil, recapSource: RecapSource? = nil,
        title: String? = nil
    ) {
        self.firstPrompt = firstPrompt
        self.firstPromptAt = firstPromptAt
        self.recap = recap
        self.recapAt = recapAt
        self.recapSource = recapSource
        self.title = title
    }

    public var isEmpty: Bool { firstPrompt == nil && recap == nil && title == nil }
}

public enum TranscriptReader {
    /// How much of the front of the file the first prompt is looked for in. A prompt further in
    /// than this is not found — the card says so rather than parsing on.
    public static let headLimit = 512 * 1024
    /// How much of the back of the file the recap is looked for in.
    public static let tailLimit = 512 * 1024

    /// Prefixes of a `user` line that is a local command echo, not a prompt.
    static let commandEchoPrefixes = ["<command-name>", "<local-command-caveat>", "<local-command-stdout>"]

    // MARK: - Files

    /// Reads the ends of the transcript at `path` and parses them. Throws when the file cannot be
    /// opened; an empty or torn file simply yields an empty summary.
    public static func read(
        path: String, headLimit: Int = headLimit, tailLimit: Int = tailLimit
    ) throws -> TranscriptSummary {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        guard size > 0 else { return TranscriptSummary() }

        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: min(size, headLimit)) ?? Data()

        let tailStart = max(0, size - tailLimit)
        let tail: Data
        if tailStart == 0 {
            tail = head.count == size ? head : (try readAll(handle, from: 0))
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
        return parse(head: head, tail: tail)
    }

    private static func readAll(_ handle: FileHandle, from offset: UInt64) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }

    /// `<configDir>/projects/*/<sessionId>.jsonl` — for a row that has no live Claude and so will
    /// never see a hook frame naming its transcript. The most recently modified match wins, which
    /// only matters when a session id was resumed from two directories.
    public static func locate(
        sessionId: String, configDir: String, fileManager: FileManager = .default
    ) -> String? {
        guard !sessionId.isEmpty, !sessionId.contains("/"), sessionId != ".", sessionId != ".." else {
            return nil
        }
        let projects = (configDir as NSString).appendingPathComponent("projects")
        guard let dirs = try? fileManager.contentsOfDirectory(atPath: projects) else { return nil }
        var best: (path: String, modified: Date)?
        for dir in dirs {
            let candidate = (projects as NSString)
                .appendingPathComponent(dir)
                .appending("/\(sessionId).jsonl")
            guard let attributes = try? fileManager.attributesOfItem(atPath: candidate) else { continue }
            let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
            if best == nil || modified > best!.modified { best = (candidate, modified) }
        }
        return best?.path
    }

    // MARK: - Parsing

    /// The pure half. `head` is scanned forwards for the first prompt and stops there; `tail` is
    /// scanned backwards for the newest recap, title and assistant text.
    public static func parse(head: Data, tail: Data) -> TranscriptSummary {
        var summary = TranscriptSummary()

        for line in lines(of: head) {
            guard let object = decode(line) else { continue }
            if let prompt = prompt(from: object) {
                summary.firstPrompt = prompt.text
                summary.firstPromptAt = prompt.at
                break
            }
        }

        var assistantText: (text: String, at: Date?)?
        for line in lines(of: tail).reversed() {
            guard let object = decode(line) else { continue }
            let type = object["type"] as? String
            if summary.title == nil, type == "ai-title",
               let title = (object["aiTitle"] as? String)?.trimmed, !title.isEmpty {
                summary.title = title
            }
            if summary.recap == nil, type == "system", object["subtype"] as? String == "away_summary",
               let content = (object["content"] as? String)?.trimmed, !content.isEmpty {
                summary.recap = content
                summary.recapAt = timestamp(of: object)
                summary.recapSource = .awaySummary
            }
            if assistantText == nil, type == "assistant", object["isSidechain"] as? Bool != true,
               let text = assistantTextBlock(of: object) {
                assistantText = (text, timestamp(of: object))
            }
            if summary.title != nil, summary.recap != nil, assistantText != nil { break }
        }
        if summary.recap == nil, let assistantText {
            summary.recap = assistantText.text
            summary.recapAt = assistantText.at
            summary.recapSource = .assistantText
        }
        return summary
    }

    /// The text of a `user` line a human typed, or nil for everything else that arrives as `user`.
    private static func prompt(from object: [String: Any]) -> (text: String, at: Date?)? {
        guard object["type"] as? String == "user",
              object["isMeta"] as? Bool != true,
              object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else { return nil }
        guard let text = userText(of: message["content"])?.trimmed, !text.isEmpty else { return nil }
        for prefix in commandEchoPrefixes where text.hasPrefix(prefix) { return nil }
        return (text, timestamp(of: object))
    }

    /// A string, or the `text` blocks of a content array joined — an image block contributes
    /// nothing, and a line that is only `tool_result` blocks is not a prompt.
    static func userText(of content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    static func assistantTextBlock(of object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text",
                  let text = (block["text"] as? String)?.trimmed, !text.isEmpty
            else { return nil }
            return text
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    /// `2026-09-10T08:01:02.000Z`, with or without the fraction. `ISO8601FormatStyle` is a value
    /// type, unlike `ISO8601DateFormatter`, so it can sit in a static under strict concurrency.
    static func timestamp(of object: [String: Any]) -> Date? {
        guard let raw = object["timestamp"] as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw))
            ?? (try? Date.ISO8601FormatStyle().parse(raw))
    }

    static func decode(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }
        return object
    }

    /// Non-empty lines, as slices of `data`.
    static func lines(of data: Data) -> [Data] {
        var out: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start { out.append(data[start..<end]) }
            start = end == data.endIndex ? end : data.index(after: end)
        }
        return out
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
