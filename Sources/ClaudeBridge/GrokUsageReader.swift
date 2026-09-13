// GrokUsageReader — token usage and spend for sessions running the Grok CLI.
//
// Grok has no hooks and no descriptor files, but it persists everything tkzmux needs:
//
//   ~/.grok/active_sessions.json                        [{session_id, pid, cwd, opened_at}]
//   ~/.grok/sessions/<url-encoded cwd>/<id>/updates.jsonl
//
// `updates.jsonl` is the ACP update stream, and every finished turn appends one
// `params.update.sessionUpdate == "turn_completed"` line whose `usage` object carries that turn's
// token counts per model (`modelUsage.<model>`) and — unlike Claude's transcript — **what Grok says
// the turn cost**, as `costUsdTicks`. xAI's unit: 10^10 ticks to the dollar, already net of cache
// discounts (https://docs.x.ai/developers/cost-tracking). So nothing here keeps a price table; the
// dollar figure is Grok's own.
//
// Grok's token fields are shaped differently from Claude's: `inputTokens` *includes*
// `cachedReadTokens`, and `reasoningTokens` is part of `outputTokens`. They are mapped onto
// `ModelUsage`'s Claude-shaped fields on the way out (uncached input, cache reads, thinking within
// output), so the sidebar badge and the status-bar tooltip need no Grok-specific case.
//
// Incremental in the `TranscriptUsageReader` manner: a byte offset and running totals per session in
// a small cache file, recomputable from scratch whenever it is missing or corrupt.

import Darwin
import Foundation
import TkzCore

public actor GrokUsageReader {
    /// xAI's `cost_in_usd_ticks` unit.
    public static let ticksPerUSD: Double = 10_000_000_000

    private let cacheDirectory: String

    public init(cacheDirectory: String) {
        self.cacheDirectory = cacheDirectory
    }

    /// `~/Library/Application Support/tkzmux/usage-grok`.
    public static func standardDirectory(supportDirectory: URL) -> String {
        supportDirectory.appendingPathComponent("usage-grok").path
    }

    /// Grok's own per-model totals, in Grok's shape. Converted to `ModelUsage` only on the way out.
    private struct RawModelUsage: Codable, Sendable {
        var inputTokens = 0
        var outputTokens = 0
        var cachedReadTokens = 0
        var cacheCreationTokens = 0
        var reasoningTokens = 0
        var costUsdTicks: Int64 = 0
    }

    private struct Cache: Codable, Sendable {
        /// The file the offset belongs to. A different path (the row was rebound to another Grok
        /// session) starts over rather than seeking into an unrelated file.
        var path: String = ""
        var byteOffset: Int = 0
        var perModel: [String: RawModelUsage] = [:]
        var lastUpdatedAt: Date = Date()

        var sessionUsage: SessionUsage? {
            guard !perModel.isEmpty else { return nil }
            let models = perModel.map { modelId, raw in
                ModelUsage(
                    modelId: modelId,
                    inputTokens: max(0, raw.inputTokens - raw.cachedReadTokens),
                    outputTokens: raw.outputTokens,
                    cacheCreationTokens: raw.cacheCreationTokens,
                    cacheReadTokens: raw.cachedReadTokens,
                    thinkingTokens: raw.reasoningTokens,
                    costUSD: Double(raw.costUsdTicks) / GrokUsageReader.ticksPerUSD)
            }.sorted { $0.modelId < $1.modelId }
            let total = models.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
            return SessionUsage(perModel: models, totalCostUSD: total, lastUpdatedAt: lastUpdatedAt)
        }
    }

    /// Folds whatever `updatesPath` gained since the last call into `sessionId`'s totals and returns
    /// them. `nil` until at least one turn has completed — never a "$0 spent" for a session that
    /// simply has not finished a turn yet.
    @discardableResult
    public func refresh(sessionId: String, updatesPath: String?) -> SessionUsage? {
        var cache = readCache(sessionId: sessionId) ?? Cache()
        guard let updatesPath, !updatesPath.isEmpty,
              let handle = FileHandle(forReadingAtPath: updatesPath)
        else {
            return cache.sessionUsage
        }
        defer { try? handle.close() }
        if cache.path != updatesPath { cache = Cache(path: updatesPath) }

        let size = Int((try? handle.seekToEnd()) ?? 0)
        let startOffset = cache.byteOffset <= size ? cache.byteOffset : 0
        if startOffset == 0 { cache.perModel = [:] }
        guard size > startOffset else { return cache.sessionUsage }

        try? handle.seek(toOffset: UInt64(startOffset))
        let unread = (try? handle.readToEnd()) ?? Data()
        // Only whole lines: Grok may be mid-write to the last one.
        guard let lastNewline = unread.lastIndex(of: 0x0A) else { return cache.sessionUsage }
        let complete = unread[unread.startIndex...lastNewline]

        for line in TranscriptReader.lines(of: complete) {
            guard let object = TranscriptReader.decode(line),
                  let params = object["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed",
                  let usage = update["usage"] as? [String: Any]
            else { continue }
            Self.fold(usage, into: &cache.perModel)
        }
        cache.byteOffset = startOffset + complete.count
        cache.lastUpdatedAt = Date()
        writeCache(sessionId: sessionId, cache: cache)
        return cache.sessionUsage
    }

    /// One turn's `usage`. Per model when Grok broke it down (it always has so far); the turn's
    /// top-level figures under the model `grok` otherwise, so a format change loses the split but
    /// not the spend.
    private static func fold(_ usage: [String: Any], into perModel: inout [String: RawModelUsage]) {
        let byModel = (usage["modelUsage"] as? [String: Any])?
            .compactMapValues { $0 as? [String: Any] } ?? [:]
        let entries = byModel.isEmpty ? ["grok": usage] : byModel
        for (modelId, fields) in entries {
            var raw = perModel[modelId] ?? RawModelUsage()
            raw.inputTokens += int(fields["inputTokens"])
            raw.outputTokens += int(fields["outputTokens"])
            raw.cachedReadTokens += int(fields["cachedReadTokens"])
            raw.cacheCreationTokens += int(fields["cacheCreationTokens"])
            raw.reasoningTokens += int(fields["reasoningTokens"])
            raw.costUsdTicks += Int64(int(fields["costUsdTicks"]))
            perModel[modelId] = raw
        }
    }

    private static func int(_ any: Any?) -> Int {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let n = any as? Double { return Int(n) }
        return 0
    }

    // MARK: - Cache file

    private func cachePath(sessionId: String) -> String {
        (cacheDirectory as NSString).appendingPathComponent("\(sessionId).json")
    }

    private func readCache(sessionId: String) -> Cache? {
        guard let data = FileManager.default.contents(atPath: cachePath(sessionId: sessionId)) else {
            return nil
        }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func writeCache(sessionId: String, cache: Cache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            atPath: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: cachePath(sessionId: sessionId)), options: .atomic)
    }
}

/// Where the Grok CLI keeps its state, and how a running Grok is found and tied to a pty.
public enum GrokSessions {
    /// One entry of `~/.grok/active_sessions.json`.
    public struct Active: Hashable, Sendable {
        public var sessionId: String
        public var pid: pid_t
        public var cwd: String

        public init(sessionId: String, pid: pid_t, cwd: String) {
            self.sessionId = sessionId
            self.pid = pid
            self.cwd = cwd
        }
    }

    /// `~/.grok`.
    public static func home(userHome: String) -> String {
        (userHome as NSString).appendingPathComponent(".grok")
    }

    /// The running Grok sessions. Empty when Grok is not installed or the file does not parse.
    public static func active(grokHome: String) -> [Active] {
        let path = (grokHome as NSString).appendingPathComponent("active_sessions.json")
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return parseActive(data)
    }

    static func parseActive(_ data: Data) -> [Active] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard let id = entry["session_id"] as? String, !id.isEmpty,
                  let pid = (entry["pid"] as? NSNumber)?.int32Value
            else { return nil }
            return Active(sessionId: id, pid: pid, cwd: entry["cwd"] as? String ?? "")
        }
    }

    /// Grok's directory name for a working directory: every byte but `A-Z a-z 0-9 - . _ ~`
    /// percent-encoded, so `/Users/me/My App` → `%2FUsers%2Fme%2FMy%20App`.
    public static func encodedDirectoryName(cwd: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return cwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? cwd
    }

    /// `updates.jsonl` for `sessionId`: under `cwd`'s directory when one is given and exists there,
    /// else the first `sessions/*/<sessionId>` that has one (a session whose cwd is unknown, or was
    /// started from a subdirectory). `nil` when no such file exists.
    public static func updatesPath(sessionId: String, cwd: String?, grokHome: String) -> String? {
        let fileManager = FileManager.default
        let sessions = (grokHome as NSString).appendingPathComponent("sessions")
        func candidate(_ directory: String) -> String? {
            let path = ((sessions as NSString).appendingPathComponent(directory) as NSString)
                .appendingPathComponent("\(sessionId)/updates.jsonl")
            return fileManager.fileExists(atPath: path) ? path : nil
        }
        if let cwd, !cwd.isEmpty, let hit = candidate(encodedDirectoryName(cwd: cwd)) { return hit }
        let directories = (try? fileManager.contentsOfDirectory(atPath: sessions)) ?? []
        return directories.sorted().lazy.compactMap(candidate).first
    }

    /// The first of `pid` and its ancestors (up to `maxDepth` levels) that is in `roots` —
    /// how a Grok process is attributed to the pty shell it runs under.
    public static func owningRoot(
        of pid: pid_t, in roots: Set<pid_t>, maxDepth: Int = 16,
        parent: (pid_t) -> pid_t? = ProcessTree.parent(of:)
    ) -> pid_t? {
        var current = pid
        for _ in 0..<maxDepth {
            if roots.contains(current) { return current }
            guard let next = parent(current), next > 1, next != current else { return nil }
            current = next
        }
        return nil
    }
}
