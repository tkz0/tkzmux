// TranscriptSearch.swift — finding a word inside a Claude conversation (TKZ-52, design 2c.6).
//
// The overlay's Transcripts section searches the NDJSON files `TranscriptReader` already knows how
// to read, but with the opposite shape: that reader wants two fields off the two ends of one file,
// this one wants every line of every open session's file, repeatedly, at typing speed.
//
// So it is an **index**, not a scan:
//
//   * ``TranscriptIndex/build(path:existing:)`` walks the file once, keeps only the text it could
//     ever show — a collapsed line per user prompt, assistant answer and tool call — and remembers
//     the byte offset it stopped at. The next build reads only what was appended, which is what a
//     live session does between keystrokes.
//   * Matching is a **case- and diacritic-folded literal substring**, not a fuzzy match. Fuzzy
//     scoring over prose matches nearly everything (the query's letters are all in there
//     somewhere), and 2c.6 highlights one contiguous run — which is what a substring is.
//   * Nothing is unbounded. ``lineLimit`` lines and ``textLimit`` bytes are retained per file,
//     newest first; a file bigger than ``byteLimit`` is read from its tail, and says so through
//     ``TranscriptIndex/isPartial`` (turn numbers then count from where the read began).
//
// Every type here is a value and every function is pure apart from `build`, which reads one file.
// The caller owns the threading; see `TranscriptSearchService` in TkzApp.

import Foundation

/// One match inside one transcript.
public struct TranscriptSearchHit: Hashable, Sendable {

    /// Which kind of line the hit sits on. 2c.6 prefixes the excerpt with a glyph per kind.
    public enum Kind: String, Hashable, Sendable {
        case user, assistant, tool
    }

    /// 1-based conversation turn, counting the human's prompts.
    public let turn: Int
    public let kind: Kind
    /// A single whitespace-collapsed line around the match, never a whole message.
    public let excerpt: String
    /// Where the needle landed in ``excerpt``, in characters — a `Range<String.Index>` cannot be
    /// carried between strings, and the row view wants to highlight without searching again.
    public let matchOffset: Int
    public let matchLength: Int
    public let at: Date?

    public init(
        turn: Int, kind: Kind, excerpt: String, matchOffset: Int, matchLength: Int, at: Date?
    ) {
        self.turn = turn
        self.kind = kind
        self.excerpt = excerpt
        self.matchOffset = matchOffset
        self.matchLength = matchLength
        self.at = at
    }

    /// The match as a range into ``excerpt``, or `nil` if the offsets fall outside it.
    public var matchRange: Range<String.Index>? {
        guard matchOffset >= 0, matchLength >= 0, matchOffset + matchLength <= excerpt.count
        else { return nil }
        let lower = excerpt.index(excerpt.startIndex, offsetBy: matchOffset)
        let upper = excerpt.index(lower, offsetBy: matchLength)
        return lower..<upper
    }
}

/// A searchable projection of one transcript file.
public struct TranscriptIndex: Sendable {

    /// One retained line.
    public struct Line: Hashable, Sendable {
        public let turn: Int
        public let kind: TranscriptSearchHit.Kind
        /// Already collapsed to one line and clipped to ``TranscriptIndex/lineTextLimit``.
        public let text: String
        /// ``text`` folded once, so a keystroke is a plain `range(of:)` and not a fold per line.
        public let folded: String
        public let at: Date?
    }

    /// How far into a file a first index reads. Beyond this the tail is used and turn numbers
    /// start from there — a 64 MB transcript is a `/loop` session, and its head is not the answer.
    public static let byteLimit = 16 * 1024 * 1024
    /// Lines retained per file, newest kept.
    public static let lineLimit = 20_000
    /// Characters retained per file, newest kept.
    public static let textLimit = 2 * 1024 * 1024
    /// A single retained line is clipped to this; an excerpt is a window inside it anyway.
    public static let lineTextLimit = 2_000
    /// How wide an excerpt is, centred on the match.
    public static let excerptWidth = 120

    /// Newest last, so the incremental build can simply append.
    public private(set) var lines: [Line]
    /// Where the next build starts reading.
    public private(set) var byteOffset: Int
    /// Turns seen so far, which is what the next appended prompt increments.
    public private(set) var turns: Int
    /// True when the head of the file was skipped, so turn numbers are relative.
    public private(set) var isPartial: Bool
    /// The size the file had when this index was built, for the "did it only grow?" check.
    public private(set) var fileSize: Int

    /// Characters currently retained — the caller's memory budget is spent in this unit.
    ///
    /// Stored rather than summed on demand: `TranscriptSearchService` asks every index for this on
    /// every keystroke to decide what to evict, and summing a 20 000-line index each time (times
    /// one per open session) is real work for a number that only changes when a line is added or
    /// dropped.
    public private(set) var retainedCharacters: Int

    init(
        lines: [Line] = [], byteOffset: Int = 0, turns: Int = 0, isPartial: Bool = false,
        fileSize: Int = 0, retainedCharacters: Int? = nil
    ) {
        self.lines = lines
        self.byteOffset = byteOffset
        self.turns = turns
        self.isPartial = isPartial
        self.fileSize = fileSize
        self.retainedCharacters = retainedCharacters ?? lines.reduce(0) { $0 + $1.text.count }
    }

    // MARK: Building

    /// Indexes `path`, reusing `existing` when the file has only grown since it was built.
    ///
    /// Throws only when the file cannot be opened; a torn or partly-written line is skipped, which
    /// is normal for a transcript being appended to while it is read.
    public static func build(
        path: String, existing: TranscriptIndex? = nil, fileManager: FileManager = .default
    ) throws -> TranscriptIndex {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        guard size > 0 else { return TranscriptIndex() }

        // Only grown, and we stopped on a line boundary: read the tail and append to what we have.
        if let existing, size >= existing.fileSize, existing.byteOffset > 0,
            size > existing.byteOffset
        {
            let data = try read(handle, from: existing.byteOffset, to: size)
            return existing.appending(data, fileSize: size, readTo: size)
        }
        if let existing, size == existing.fileSize, existing.byteOffset == size {
            return existing
        }

        // A fresh index. A file over the cap is read from its tail, with the partial first line
        // dropped at the first newline — the same trick `TranscriptReader` uses.
        var start = 0
        var partial = false
        if size > byteLimit {
            start = size - byteLimit
            partial = true
        }
        var data = try read(handle, from: start, to: size)
        // The tail almost certainly starts mid-line; that fragment is not valid JSON, so drop it.
        if partial, let newline = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newline)...]
        }
        return TranscriptIndex(isPartial: partial)
            .appending(data, fileSize: size, readTo: size)
    }

    private static func read(_ handle: FileHandle, from offset: Int, to end: Int) throws -> Data {
        guard end > offset else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: end - offset) ?? Data()
    }

    /// Parses `data` as whole NDJSON lines and appends what is searchable. Pure — this is where the
    /// fixtures in the tests go in.
    public func appending(_ data: Data, fileSize: Int, readTo offset: Int) -> TranscriptIndex {
        var lines = self.lines
        var turns = self.turns
        var characters = retainedCharacters

        for raw in TranscriptReader.lines(of: data) {
            guard let object = TranscriptReader.decode(raw) else { continue }
            guard object["isSidechain"] as? Bool != true else { continue }
            let at = TranscriptReader.timestamp(of: object)

            switch object["type"] as? String {
            case "user":
                guard object["isMeta"] as? Bool != true,
                    let message = object["message"] as? [String: Any],
                    let text = TranscriptReader.userText(of: message["content"])?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty,
                    !TranscriptReader.commandEchoPrefixes.contains(where: text.hasPrefix)
                else { continue }
                // A prompt is what makes a turn; everything after it belongs to that turn.
                turns += 1
                append(Self.line(turn: turns, kind: .user, text: text, at: at), to: &lines, &characters)
            case "assistant":
                if let text = TranscriptReader.assistantTextBlock(of: object) {
                    append(
                        Self.line(turn: turns, kind: .assistant, text: text, at: at),
                        to: &lines, &characters)
                }
                for tool in Self.toolUses(of: object) {
                    append(
                        Self.line(turn: turns, kind: .tool, text: tool, at: at),
                        to: &lines, &characters)
                }
            default:
                continue
            }
        }

        return TranscriptIndex(
            lines: lines, byteOffset: offset, turns: turns, isPartial: isPartial,
            fileSize: fileSize, retainedCharacters: characters)
    }

    /// Appends one line and re-applies both caps.
    ///
    /// Newest wins when a cap bites: the tail of a conversation is the part being worked on. The
    /// trim counts how many lines have to go and drops them in **one** `removeFirst(_:)` — dropping
    /// them one at a time is quadratic, and a `/loop` session's transcript is exactly where that
    /// bites (it also made the cap test slow enough to disturb `tkzmux-hook`'s 50 ms budget in a
    /// shared `swift test` run).
    private func append(_ line: Line, to lines: inout [Line], _ characters: inout Int) {
        lines.append(line)
        characters += line.text.count

        // How many lines the line cap alone wants gone...
        var drop = max(0, lines.count - Self.lineLimit)
        for index in 0..<drop { characters -= lines[index].text.count }
        // ...then the character cap keeps going from there.
        while characters > Self.textLimit, drop < lines.count {
            characters -= lines[drop].text.count
            drop += 1
        }
        if drop > 0 { lines.removeFirst(drop) }
    }

    private static func line(
        turn: Int, kind: TranscriptSearchHit.Kind, text: String, at: Date?
    ) -> Line {
        let collapsed = collapse(text)
        return Line(turn: turn, kind: kind, text: collapsed, folded: fold(collapsed), at: at)
    }

    /// `● Bash(wscat -c ws://…)` — 2c.6's tool rows. The first string parameter is what identifies
    /// a call at a glance (the command, the path, the pattern), so that is what is shown.
    static func toolUses(of object: [String: Any]) -> [String] {
        guard let message = object["message"] as? [String: Any],
            let blocks = message["content"] as? [[String: Any]]
        else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "tool_use",
                let name = block["name"] as? String, !name.isEmpty
            else { return nil }
            guard let input = block["input"] as? [String: Any] else { return name + "()" }
            let argument = ["command", "file_path", "path", "pattern", "query", "url", "prompt"]
                .lazy
                .compactMap { input[$0] as? String }
                .first
            return argument.map { "\(name)(\($0))" } ?? "\(name)()"
        }
    }

    // MARK: Searching

    /// Hits for an already-folded `needle`, newest first, at most `limit`.
    public func search(foldedNeedle needle: String, limit: Int) -> [TranscriptSearchHit] {
        guard !needle.isEmpty else { return [] }
        var hits: [TranscriptSearchHit] = []
        // Newest first: a conversation is read from its end, and the caps already dropped the head.
        for line in lines.reversed() {
            guard let foldedRange = line.folded.range(of: needle) else { continue }
            guard let hit = Self.hit(for: line, foldedRange: foldedRange) else { continue }
            hits.append(hit)
            if hits.count >= limit { break }
        }
        return hits
    }

    /// Builds the excerpt window and maps the match into it.
    ///
    /// Folding is per-character and length-preserving for everything this sees (case folding of
    /// Latin text), so a range in the folded string indexes the original. Anything that folded to a
    /// different length is dropped rather than highlighted in the wrong place.
    static func hit(for line: Line, foldedRange: Range<String.Index>) -> TranscriptSearchHit? {
        guard line.folded.count == line.text.count else { return nil }
        let start = line.folded.distance(from: line.folded.startIndex, to: foldedRange.lowerBound)
        let length = line.folded.distance(from: foldedRange.lowerBound, to: foldedRange.upperBound)

        let (window, shift) = excerpt(of: line.text, around: start, length: length)
        let offset = start - shift
        guard offset >= 0, offset + length <= window.count else { return nil }
        return TranscriptSearchHit(
            turn: line.turn, kind: line.kind, excerpt: window,
            matchOffset: offset, matchLength: length, at: line.at)
    }

    /// A window of ``excerptWidth`` characters centred on the match, ellipsised at whichever end
    /// was cut. Returns the window and how many characters were dropped from the front.
    static func excerpt(of text: String, around start: Int, length: Int) -> (String, Int) {
        guard text.count > excerptWidth else { return (text, 0) }
        let slack = max(0, excerptWidth - length)
        var from = max(0, start - slack / 2)
        let to = min(text.count, from + excerptWidth)
        from = max(0, min(from, to - min(excerptWidth, text.count)))

        let lower = text.index(text.startIndex, offsetBy: from)
        let upper = text.index(text.startIndex, offsetBy: to)
        var window = String(text[lower..<upper])
        var shift = from
        if from > 0 {
            window = "\u{2026}" + window
            shift -= 1  // the ellipsis takes one character's worth of room back
        }
        if to < text.count { window += "\u{2026}" }
        return (window, shift)
    }

    // MARK: Text

    /// One line, no runs of whitespace — a transcript line is JSON-escaped prose and can be a whole
    /// diff.
    static func collapse(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(min(text.count, lineTextLimit))
        var lastWasSpace = false
        for character in text {
            let isSpace = character.isWhitespace || character.isNewline
            if isSpace {
                if !lastWasSpace, !out.isEmpty { out.append(" ") }
            } else {
                out.append(character)
            }
            lastWasSpace = isSpace
            if out.count >= lineTextLimit { break }
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    /// Case- and diacritic-folded, character by character, so the folded string keeps the original's
    /// length wherever it can (see ``hit(for:foldedRange:)``).
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
