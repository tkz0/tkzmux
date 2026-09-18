// TranscriptUsageReader — token usage and spend per session.
//
// Claude Code hands cost to the statusline command's stdin (see `StatuslineCommand.swift`), but
// only a single cumulative USD number for the *live* process, never a token breakdown, and never
// for a session that is not currently running one. The same data at real resolution — per-turn,
// per-model — already lives in the transcript `TranscriptReader` reads: every `"type":"assistant"`
// line carries a `message.usage` object (`input_tokens`, `output_tokens`,
// `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens_details.thinking_tokens`).
//
// This sums that, incrementally: transcripts are append-only, so each session gets a small cache
// file under `~/Library/Application Support/tkzmux/usage/<agent>-<sessionId>.json` recording a byte
// offset and running per-model *token* totals — never a cost, so a `ModelPricing` edit changes what
// old totals cost without needing to re-read anything. A missing or corrupt cache file just means
// the next `refresh` starts from offset 0 and re-derives it: the cache is a recomputable
// convenience, not a source of truth, the same relationship `state.json`'s persisted fields have to
// `AppState`'s process-only ones.
//
// **The cache filename carries the agent (TKZ-86 part 2).** Two agents can produce the same
// conversation id in principle — nothing stops it, they are independent id spaces — so keying the
// file on `sessionId` alone would let one agent's cache collide with another's. This is a
// deliberate, one-time break: a build upgrading from before this change has Claude caches on disk
// named `<sessionId>.json`, none of which match `claude-<sessionId>.json`, so every one of them
// misses once and gets rebuilt from offset 0. That is a full one-time re-read of every open
// transcript's assistant lines, not data loss — the cache was always a recomputable convenience,
// per the paragraph above.
//
// **Claude's accounting and Codex's must never share a summing loop.** Claude's transcript is
// incremental: each assistant line's `usage` is that turn's own tokens, so the right answer is a
// running `+=`. Codex's is cumulative: every usage line already carries the *whole thread's*
// running total, so summing successive lines the Claude way overcounts by however many usage lines
// were ever emitted — and Codex re-emits an unchanged line on a rate-limit refresh, so even a naive
// "add only when the total moved" still double-counts the first repeat. Three other open-source
// usage trackers shipped exactly this bug. `UsageStrategy` is the seam that keeps the two rules from
// ever being smashed into one method with an `if agent == .codex` branch in the middle of it: Claude
// keeps its own conformer, unchanged in every particular from before this file knew Codex existed,
// and Codex's lives beside it in `CodexUsageExtractor`, entirely in `Sources/ClaudeBridge/Codex/`.
//
// An actor, not a `DispatchQueue`-backed class like `StatuslineReader`/`ClaudeSessionWatcher`: there
// is no file to watch here, only a read-modify-write triggered by hook frames, so the actor's
// serialized-access guarantee is all the concurrency safety this needs.

import Foundation
import TkzCore

/// How the lines read since the last `refresh` turn into updated per-model token totals. See the
/// file header for why this exists instead of a branch inside one method.
protocol UsageStrategy: Sendable {
    /// `lines` are complete (newline-terminated) NDJSON lines newly read since the last call, in
    /// file order. Mutates `cache` in place. A line that does not parse, or does not carry usage
    /// this strategy recognises, is simply skipped — the baseline is never guessed at.
    func fold(_ lines: [Data], into cache: inout TranscriptUsageReader.Cache)
}

public actor TranscriptUsageReader {
    private let cacheDirectory: String

    public init(cacheDirectory: String) {
        self.cacheDirectory = cacheDirectory
    }

    /// `~/Library/Application Support/tkzmux/usage`.
    public static func standardDirectory(supportDirectory: URL) -> String {
        supportDirectory.appendingPathComponent("usage").path
    }

    /// Per-model *token* totals only — `sessionUsage` prices them on the way out, so a
    /// `ModelPricing` change is retroactive without touching this file. Internal rather than
    /// private: `ClaudeUsageStrategy` below and `CodexUsageExtractor` (a different file, same
    /// module) both build these.
    struct RawModelUsage: Codable, Sendable, Equatable {
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var thinkingTokens = 0
    }

    struct Cache: Codable, Sendable {
        var byteOffset: Int = 0
        var perModel: [String: RawModelUsage] = [:]
        var lastUpdatedAt: Date = Date()
        /// Codex only: the model id read off the newest `turn_context` line seen so far, carried
        /// across refreshes so a call that only sees new usage lines (no repeated `turn_context`)
        /// still knows which key to fold `perModel` under. Claude leaves this `nil` forever — its
        /// model id rides on every assistant line already, with no cross-call memory needed.
        var codexModelId: String? = nil

        /// `nil` when nothing has ever been parsed for this session — distinct from "parsed, spent
        /// nothing", which cannot happen (an assistant line always carries some usage, and a Codex
        /// usage snapshot that parsed at all always carries a `total_tokens`).
        var sessionUsage: SessionUsage? {
            guard !perModel.isEmpty else { return nil }
            let models = perModel.map { modelId, raw in
                ModelUsage(
                    modelId: modelId,
                    inputTokens: raw.inputTokens,
                    outputTokens: raw.outputTokens,
                    cacheCreationTokens: raw.cacheCreationTokens,
                    cacheReadTokens: raw.cacheReadTokens,
                    thinkingTokens: raw.thinkingTokens,
                    costUSD: ModelPricing.cost(
                        modelId: modelId,
                        inputTokens: raw.inputTokens,
                        outputTokens: raw.outputTokens,
                        cacheCreationTokens: raw.cacheCreationTokens,
                        cacheReadTokens: raw.cacheReadTokens))
            }.sorted { $0.modelId < $1.modelId }
            // A total only means something when every model in it has a price; a partial sum would
            // read as "this is what the session cost" while silently missing a model's share.
            let allPriced = models.allSatisfy { $0.costUSD != nil }
            let total = allPriced ? models.reduce(0.0) { $0 + ($1.costUSD ?? 0) } : nil
            return SessionUsage(perModel: models, totalCostUSD: total, lastUpdatedAt: lastUpdatedAt)
        }
    }

    /// Parses whatever of `transcriptPath` has been appended since the last call for `sessionId`,
    /// folds it into the persisted per-model totals using `agent`'s own `UsageStrategy`, and returns
    /// the session's usage so far. `nil` when nothing has ever been parsed for this session (no
    /// transcript, unreadable file, or a transcript that so far carries no usage this agent's
    /// strategy recognises) — the caller must not render that as "$0 spent".
    ///
    /// `agent` defaults to `.claude` so every existing call site (and every test written before this
    /// parameter existed) keeps compiling and keeps its old behaviour unchanged.
    @discardableResult
    public func refresh(
        sessionId: String, transcriptPath: String?, agent: AgentKind = .claude
    ) -> SessionUsage? {
        var cache = readCache(agent: agent, sessionId: sessionId) ?? Cache()
        guard let transcriptPath, !transcriptPath.isEmpty,
              let handle = FileHandle(forReadingAtPath: transcriptPath)
        else {
            return cache.sessionUsage
        }
        defer { try? handle.close() }

        let size = Int((try? handle.seekToEnd()) ?? 0)
        // A transcript is append-only in normal operation; a stored offset past the current size
        // means the file was replaced (not observed in practice, but cheap to guard), so start over
        // rather than seek past the end.
        let startOffset = cache.byteOffset <= size ? cache.byteOffset : 0
        guard size > startOffset else { return cache.sessionUsage }

        try? handle.seek(toOffset: UInt64(startOffset))
        let unread = (try? handle.readToEnd()) ?? Data()
        // Only fully-written lines are safe to parse; a transcript can be mid-write to its last
        // line, and consuming a partial one would both misparse it and never see the rest of it
        // once the offset moves past it.
        guard let lastNewline = unread.lastIndex(of: 0x0A) else { return cache.sessionUsage }
        let complete = unread[unread.startIndex...lastNewline]

        let strategy: any UsageStrategy = agent == .codex ? CodexUsageExtractor() : ClaudeUsageStrategy()
        strategy.fold(TranscriptReader.lines(of: complete), into: &cache)

        cache.byteOffset = startOffset + complete.count
        cache.lastUpdatedAt = Date()
        writeCache(agent: agent, sessionId: sessionId, cache: cache)
        return cache.sessionUsage
    }

    static func intValue(_ any: Any?) -> Int {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let n = any as? Double { return Int(n) }
        return 0
    }

    // MARK: - Cache file

    /// `<agent>-<sessionId>.json` — see the file header for why the agent rides in the filename.
    private func cachePath(agent: AgentKind, sessionId: String) -> String {
        (cacheDirectory as NSString).appendingPathComponent("\(agent.rawValue)-\(sessionId).json")
    }

    private func readCache(agent: AgentKind, sessionId: String) -> Cache? {
        guard let data = FileManager.default.contents(atPath: cachePath(agent: agent, sessionId: sessionId))
        else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    /// Write-to-temp + rename via `Data.write(options: .atomic)`, so a read can never catch a
    /// half-written cache — the same guarantee `tkzmux-hook`'s `writeFileAtomically` gives the
    /// statusline sidecars, minus the hand-rolled POSIX calls that target needs to stay
    /// Foundation-free.
    private func writeCache(agent: AgentKind, sessionId: String, cache: Cache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            atPath: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(
            to: URL(fileURLWithPath: cachePath(agent: agent, sessionId: sessionId)), options: .atomic)
    }
}

/// Claude's own fold: every `"type":"assistant"` line's `message.usage` is that turn's own tokens,
/// so the running total is a plain `+=`. Unchanged, line for line, from what `refresh` used to do
/// before it knew about a second agent — this file's guard against ever touching that path again.
struct ClaudeUsageStrategy: UsageStrategy {
    func fold(_ lines: [Data], into cache: inout TranscriptUsageReader.Cache) {
        for line in lines {
            guard let object = TranscriptReader.decode(line),
                object["type"] as? String == "assistant",
                let message = object["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any]
            else { continue }
            // Sidechain (subagent) turns are real API spend against the same account and are
            // folded into the session total rather than dropped.
            let modelId = (message["model"] as? String) ?? "unknown"
            var raw = cache.perModel[modelId] ?? TranscriptUsageReader.RawModelUsage()
            raw.inputTokens += TranscriptUsageReader.intValue(usage["input_tokens"])
            raw.outputTokens += TranscriptUsageReader.intValue(usage["output_tokens"])
            raw.cacheCreationTokens += TranscriptUsageReader.intValue(usage["cache_creation_input_tokens"])
            raw.cacheReadTokens += TranscriptUsageReader.intValue(usage["cache_read_input_tokens"])
            if let details = usage["output_tokens_details"] as? [String: Any] {
                raw.thinkingTokens += TranscriptUsageReader.intValue(details["thinking_tokens"])
            }
            cache.perModel[modelId] = raw
        }
    }
}
