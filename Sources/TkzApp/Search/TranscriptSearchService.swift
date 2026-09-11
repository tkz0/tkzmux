// TranscriptSearchService.swift — the Transcripts section's engine (TKZ-52, design 2c.6).
//
// One `TranscriptIndex` per open session, kept off the main actor. A keystroke asks for hits; the
// service builds or tops up each index (reading only what the session appended since last time) and
// returns the rows the overlay draws.
//
// **Bounded, and it leaves by the same door it came in.** `ClaudeIntegration`'s per-session
// dictionaries exist under a rule — an unbounded cache keyed by session id is a leak, and
// `PerSessionCacheEvictionTests` is there to prove it is not one. The same rule applies here, twice
// over, because the values are megabytes rather than a struct:
//
//   * every search drops the index of any session that is no longer open, and
//   * a total over ``characterLimit`` evicts least-recently-searched sessions until it is not.
//
// Nothing is indexed until the user actually types, so a session that is never searched costs zero.

import ClaudeBridge
import Foundation
import TkzCore

public actor TranscriptSearchService {

    /// One session's transcript, as the main actor sees it.
    public struct Target: Sendable, Hashable {
        public let sessionID: SessionID
        public let title: String
        public let path: String

        public init(sessionID: SessionID, title: String, path: String) {
            self.sessionID = sessionID
            self.title = title
            self.path = path
        }
    }

    /// Retained text across every index, in characters (~2 bytes each in Swift's small-string and
    /// UTF-16 storage, so on the order of 16 MB). `TranscriptIndex` caps one file at 2 M; this caps
    /// the fleet.
    public static let characterLimit = 8_000_000
    /// A one-character substring matches nearly every line of every conversation, which is noise,
    /// not a result.
    public static let minimumQueryLength = 2
    /// Hits taken from any single session, before the cross-session ranking.
    public static let perSessionLimit = 20

    private var indexes: [SessionID: TranscriptIndex] = [:]
    /// Least-recently-searched first.
    private var recency: [SessionID] = []

    public init() {}

    // MARK: Searching

    /// Hits across `targets`, newest first. Returns nothing for a query too short to be meaningful,
    /// and gives up quietly when the task is cancelled — the next keystroke is already on its way.
    public func search(
        _ query: String, in targets: [Target], limit: Int
    ) -> [TranscriptSearchService.Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else { return [] }
        let needle = TranscriptIndex.fold(trimmed)

        var results: [Result] = []
        for target in targets {
            if Task.isCancelled { return [] }
            guard let index = index(for: target) else { continue }
            for hit in index.search(foldedNeedle: needle, limit: Self.perSessionLimit) {
                results.append(Result(target: target, hit: hit))
            }
        }

        evict(keeping: Set(targets.map(\.sessionID)))

        // Newest first across sessions, which is the order 2c.6 lists its hits in. An undated hit
        // sorts last rather than first — it is almost certainly an old line with no timestamp.
        results.sort { lhs, rhs in
            switch (lhs.hit.at, rhs.hit.at) {
            case (let l?, let r?): return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.hit.turn > rhs.hit.turn
            }
        }
        return Array(results.prefix(limit))
    }

    /// One hit, with the session it belongs to.
    public struct Result: Sendable {
        public let target: Target
        public let hit: TranscriptSearchHit
    }

    // MARK: Indexes

    private func index(for target: Target) -> TranscriptIndex? {
        touch(target.sessionID)
        let existing = indexes[target.sessionID]
        guard let built = try? TranscriptIndex.build(path: target.path, existing: existing) else {
            // A transcript that cannot be read (deleted, or a path from a stale hook frame) simply
            // contributes nothing; it is not an error the user needs to see mid-keystroke.
            indexes[target.sessionID] = nil
            return existing
        }
        indexes[target.sessionID] = built
        return built
    }

    private func touch(_ id: SessionID) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }

    // MARK: Eviction

    /// Drops every index outside `live`, then trims the rest down to ``characterLimit``.
    private func evict(keeping live: Set<SessionID>) {
        for id in indexes.keys where !live.contains(id) { drop(id) }

        var total = indexes.values.reduce(0) { $0 + $1.retainedCharacters }
        var index = 0
        while total > Self.characterLimit, index < recency.count {
            let id = recency[index]
            index += 1
            guard let dropped = indexes[id] else { continue }
            total -= dropped.retainedCharacters
            drop(id)
        }
    }

    private func drop(_ id: SessionID) {
        indexes[id] = nil
        recency.removeAll { $0 == id }
    }

    /// The session is gone — forget it now rather than at the next search.
    public func forget(_ id: SessionID) { drop(id) }

    public func forgetAll() {
        indexes.removeAll()
        recency.removeAll()
    }

    // MARK: Test access

    var indexedSessionsForTesting: Set<SessionID> { Set(indexes.keys) }
    var retainedCharactersForTesting: Int {
        indexes.values.reduce(0) { $0 + $1.retainedCharacters }
    }
}

extension TranscriptSearchService.Result {
    /// The row the overlay draws (design 2c.6).
    @MainActor
    public func row() -> TranscriptRow {
        TranscriptRow(
            sessionID: target.sessionID,
            sessionTitle: target.title,
            turn: hit.turn,
            kind: TranscriptRow.Kind(hit.kind),
            excerpt: hit.excerpt,
            matchRanges: hit.matchRange.map { [$0] } ?? [],
            at: hit.at)
    }
}

extension TranscriptRow.Kind {
    init(_ kind: TranscriptSearchHit.Kind) {
        switch kind {
        case .user: self = .user
        case .assistant: self = .assistant
        case .tool: self = .tool
        }
    }
}
