// CodexTranscriptReader — first prompt, recap and token usage out of a Codex rollout transcript
// (TKZ-86 part 2).
//
// Codex calls its transcript a "rollout": append-only NDJSON where every line has a top-level
// `"type"` and a `"payload"` object, unlike the flatter shape the other agent's transcript uses.
// What this file borrows wholesale, though, is the *reading discipline* `TranscriptReader` and
// `TranscriptIndex` already established: bounded head-and-tail reads, byte offsets, "skip whatever
// you don't recognise". Reusing their file-level helpers (`TranscriptReader.lines`, `.decode`,
// `.timestamp`, and `TranscriptIndex`'s caps, `Line` and `fold`) keeps this file about Codex's own
// shapes, not about how to read a large file safely a second time.
//
// The trap this slice exists to avoid lives in `TranscriptUsageReader`/`CodexUsageExtractor`, not
// here: Codex's `token_usage_record`/`token_count` lines carry a *running thread total*, never a
// per-line delta, so this file only locates and summarises a transcript — it never sums anything.

import Foundation
import TkzCore

/// Reads a Codex rollout the way the other agent's `TranscriptProvider` conformer reads its own
/// transcript. A single instance serves every Codex account, so nothing here holds a path or a
/// config dir.
public struct CodexTranscriptReader: TranscriptProvider {
    /// Trivial on purpose: `CodexAdapter.transcript` builds one fresh on every access.
    public init() {}

    // MARK: - Locate

    /// `$CODEX_HOME/sessions/**/rollout-*-<conversationId>.jsonl`, newest by modification time.
    ///
    /// **This is a fallback, not the hot path.** Every Codex hook payload carries `transcript_path`
    /// directly (`HookPayload.transcriptPath`), so by the time a row exists the app usually already
    /// knows the file without having to search for it. This method exists for a row with no live
    /// Codex process, which will never see a hook frame naming its transcript.
    ///
    /// The conversation id appears both in the filename and in `session_meta.payload.id` /
    /// `session_id` inside the file, so matching the filename alone is enough — nothing here opens
    /// a file it is not already about to return.
    public func locate(conversationId: String, configDir: String, fileManager: FileManager) -> String? {
        guard !conversationId.isEmpty, !conversationId.contains("/"),
            conversationId != ".", conversationId != ".."
        else { return nil }
        let sessionsDirectory = (configDir as NSString).appendingPathComponent("sessions")
        guard let names = fileManager.enumerator(atPath: sessionsDirectory) else { return nil }
        let prefix = "rollout-"
        let suffix = "-\(conversationId).jsonl"
        var best: (path: String, modified: Date)?
        for case let relative as String in names {
            let name = (relative as NSString).lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                name.count > prefix.count + suffix.count
            else { continue }
            let candidate = (sessionsDirectory as NSString).appendingPathComponent(relative)
            guard let attributes = try? fileManager.attributesOfItem(atPath: candidate) else { continue }
            let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
            if best == nil || modified > best!.modified { best = (candidate, modified) }
        }
        return best?.path
    }

    // MARK: - Summary

    /// Same bounds as the shared reader's own file front end: `headLimit`/`tailLimit` bytes off
    /// each end, tolerant of a file still being appended to underneath it.
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
            tail = head.count == size ? head : (try Self.readAll(handle, from: 0))
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

    private static func readAll(_ handle: FileHandle, from offset: UInt64) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }

    /// The pure half: the head is scanned forward for the first prompt and stops there; the tail is
    /// scanned backward for the newest recap.
    static func parse(head: Data, tail: Data) -> TranscriptSummary {
        var summary = TranscriptSummary()

        for line in TranscriptReader.lines(of: head) {
            guard let object = TranscriptReader.decode(line) else { continue }
            if let prompt = firstPrompt(of: object) {
                summary.firstPrompt = prompt.text
                summary.firstPromptAt = prompt.at
                break
            }
        }

        for line in TranscriptReader.lines(of: tail).reversed() {
            guard let object = TranscriptReader.decode(line) else { continue }
            if let recap = taskCompleteMessage(of: object) {
                summary.recap = recap.text
                summary.recapAt = recap.at
                // `TranscriptSummary.RecapSource` has no Codex-specific case — it lives outside this
                // slice, in the file the other adapter's reader owns — so this reuses `.stopMessage`,
                // the closest analogue: both name "the last thing the agent said, off a turn-ending
                // event, used because nothing richer was found".
                summary.recapSource = .stopMessage
                break
            }
        }
        return summary
    }

    /// The first prompt-bearing line, in either shape a rollout has used for it: a `response_item`
    /// message with `role == "user"` (seen in the newest capture), or an `event_msg` of type
    /// `user_message` (seen in the older ones). No further filtering is applied: a rollout's early
    /// lines carry developer instructions and environment context under `role == "user"` too, and
    /// telling those apart from a human's own words is a job for a future ticket — this one asks for
    /// exactly these two shapes and nothing about screening what is inside them.
    private static func firstPrompt(of object: [String: Any]) -> (text: String, at: Date?)? {
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        let type = object["type"] as? String
        if type == "response_item", payload["type"] as? String == "message",
            payload["role"] as? String == "user",
            let text = inputText(of: payload["content"])?.trimmed, !text.isEmpty
        {
            return (text, TranscriptReader.timestamp(of: object))
        }
        if type == "event_msg", payload["type"] as? String == "user_message",
            let text = (payload["message"] as? String)?.trimmed, !text.isEmpty
        {
            return (text, TranscriptReader.timestamp(of: object))
        }
        return nil
    }

    /// `task_complete`'s own `last_agent_message`, wherever the newest one is. A `null` here (a turn
    /// that produced no final text — seen in both older captures) is not a recap, so that line is
    /// skipped in favour of an earlier, real one if any exists.
    private static func taskCompleteMessage(of object: [String: Any]) -> (text: String, at: Date?)? {
        guard object["type"] as? String == "event_msg",
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "task_complete",
            let text = (payload["last_agent_message"] as? String)?.trimmed, !text.isEmpty
        else { return nil }
        return (text, TranscriptReader.timestamp(of: object))
    }

    /// The `input_text` (and, leniently, `output_text`) blocks of a `response_item` message's
    /// content array, joined the same way the shared reader joins the other agent's `text` blocks —
    /// same idea, different block-type string.
    private static func inputText(of content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "input_text" || block["type"] as? String == "output_text"
            else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    // MARK: - Usage

    /// Codex's numbers must never go through the incremental fold the shared reader's default
    /// strategy uses — see the file header and `CodexUsageExtractor`. This just tells the shared
    /// actor which strategy applies.
    public func usage(
        conversationId: String, path: String, reader: TranscriptUsageReader
    ) async -> SessionUsage? {
        await reader.refresh(sessionId: conversationId, transcriptPath: path, agent: .codex)
    }

    // MARK: - Search index

    /// User and agent messages only — no tool rows, unlike the other agent's index, because a
    /// rollout's tool calls (`custom_tool_call`, its embedded `exec_command` scripts) are not what
    /// the transcript search feature was built to search over, and their shapes already differ
    /// between the two captured versions.
    ///
    /// Reuses `TranscriptIndex`'s own caps (`byteLimit`, `lineLimit`, `textLimit`) and its `fold`
    /// text-normalisation, but not its own line-walking — that is written for the other agent's line
    /// shapes — so this walks Codex's shapes directly and produces the same `TranscriptIndex` value.
    public func searchIndex(path: String, existing: TranscriptIndex?) throws -> TranscriptIndex {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        guard size > 0 else { return TranscriptIndex() }

        // Only grown, and the previous build stopped on a line boundary: read the tail and append.
        if let existing, size >= existing.fileSize, existing.byteOffset > 0, size > existing.byteOffset {
            let data = try Self.read(handle, from: existing.byteOffset, to: size)
            return Self.appending(data, to: existing, fileSize: size, readTo: size)
        }
        if let existing, size == existing.fileSize, existing.byteOffset == size {
            return existing
        }

        // A fresh index. A file over the cap is read from its tail, with the partial first line
        // dropped at the first newline.
        var start = 0
        var partial = false
        if size > TranscriptIndex.byteLimit {
            start = size - TranscriptIndex.byteLimit
            partial = true
        }
        var data = try Self.read(handle, from: start, to: size)
        if partial, let newline = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newline)...]
        }
        return Self.appending(data, to: TranscriptIndex(isPartial: partial), fileSize: size, readTo: size)
    }

    private static func read(_ handle: FileHandle, from offset: Int, to end: Int) throws -> Data {
        guard end > offset else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: end - offset) ?? Data()
    }

    /// Parses `data` as whole NDJSON lines and folds in whatever is searchable, applying
    /// `TranscriptIndex`'s own line/character caps the same way it applies them itself.
    private static func appending(
        _ data: Data, to index: TranscriptIndex, fileSize: Int, readTo offset: Int
    ) -> TranscriptIndex {
        var lines = index.lines
        var turns = index.turns
        var characters = index.retainedCharacters

        for raw in TranscriptReader.lines(of: data) {
            guard let object = TranscriptReader.decode(raw), let payload = object["payload"] as? [String: Any]
            else { continue }
            guard payload["type"] as? String == "message" else { continue }
            let at = TranscriptReader.timestamp(of: object)
            let role = payload["role"] as? String
            guard object["type"] as? String == "response_item",
                let text = inputText(of: payload["content"])?.trimmed, !text.isEmpty
            else { continue }

            if role == "user" {
                // A prompt is what makes a turn; everything after it belongs to that turn — the
                // same convention the other agent's index uses.
                turns += 1
                append(line(turn: turns, kind: .user, text: text, at: at), to: &lines, &characters)
            } else if role == "assistant" {
                append(line(turn: turns, kind: .assistant, text: text, at: at), to: &lines, &characters)
            }
        }

        return TranscriptIndex(
            lines: lines, byteOffset: offset, turns: turns, isPartial: index.isPartial,
            fileSize: fileSize, retainedCharacters: characters)
    }

    /// Appends one line and re-applies both caps: newest wins, and the drop happens in one
    /// `removeFirst(_:)` rather than one at a time — the same rule `TranscriptIndex.append` uses.
    private static func append(
        _ line: TranscriptIndex.Line, to lines: inout [TranscriptIndex.Line], _ characters: inout Int
    ) {
        lines.append(line)
        characters += line.text.count
        var drop = max(0, lines.count - TranscriptIndex.lineLimit)
        for index in 0..<drop { characters -= lines[index].text.count }
        while characters > TranscriptIndex.textLimit, drop < lines.count {
            characters -= lines[drop].text.count
            drop += 1
        }
        if drop > 0 { lines.removeFirst(drop) }
    }

    private static func line(
        turn: Int, kind: TranscriptSearchHit.Kind, text: String, at: Date?
    ) -> TranscriptIndex.Line {
        let collapsed = TranscriptIndex.collapse(text)
        return TranscriptIndex.Line(
            turn: turn, kind: kind, text: collapsed, folded: TranscriptIndex.fold(collapsed), at: at)
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
