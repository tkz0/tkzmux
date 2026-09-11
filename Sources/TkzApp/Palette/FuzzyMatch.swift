// FuzzyMatch.swift — the subsequence matcher behind ⌘P / ⇧⌘P (design.md → App architecture →
// Palette: "fuzzy over sessions (title, branch, cwd, group), groups, commands").
//
// Pure value code: no AppKit, no state, no I/O. Two properties matter beyond "does it match":
//
//   * **Ranking.** A prefix match must beat a word-boundary match must beat a mid-word match, and a
//     contiguous run must beat the same characters scattered across separators. The constants below
//     are ordered to guarantee exactly that (`consecutive` > `separator` — with the two the other way
//     round, `abc` scores higher in `a_b_c` than in `abcdef`, which is the wrong answer).
//   * **Grapheme correctness.** Everything works on `Character`s and real `String.Index`es, never on
//     UTF-16 offsets: session titles come from Claude and contain emoji, and an index-based matcher
//     mis-highlights (or traps) the moment a grapheme is more than one code unit. Comparison folds
//     case *and* diacritics per character, which keeps the folded array the same length as the
//     original — `lowercased()` on the whole string does not (ß → ss) and would desynchronise the
//     ranges.
//
// Cost is O(query × candidate) via a running-maximum with linear gap decay, so preparing a target
// once (``FuzzyMatch/Target``) and matching many queries against it is cheap — see `PaletteDataSource`.

import Foundation

public enum FuzzyMatch {

    // MARK: Scoring constants

    /// Every matched character is worth this much before bonuses.
    public static let matchBase = 16
    /// The candidate starts with the query character.
    public static let startBonus = 32
    /// This character continues the previous match with no gap.
    public static let consecutiveBonus = 24
    /// The character follows a separator (`-`, `_`, `/`, `.`, space …).
    public static let separatorBonus = 16
    /// camelCase hump, or the first digit of a number.
    public static let camelBonus = 12
    /// Subtracted per skipped character between two matches (linear decay, floored by the run).
    public static let gapDecay = 3
    /// Every character skipped before the *first* match costs this, capped at ``leadingPenaltyCap``.
    public static let leadingPenalty = 1
    public static let leadingPenaltyCap = 12
    /// The whole candidate is the query (after folding).
    public static let exactBonus = 24

    private static let separators: Set<Character> = [
        " ", "-", "_", "/", ".", ":", ",", "\\", "|", "(", ")", "[", "]", "{", "}", "@", "#", "+", "\t",
    ]

    // MARK: Types

    /// One ranked hit: a score, and the ranges of the candidate the query matched.
    public struct Match: Hashable, Sendable {
        public let score: Int
        /// Ranges into the *original* candidate string, merged so that a contiguous run is one range.
        /// Ready for `NSRange(range, in: text)` when styling an `NSAttributedString`.
        public let ranges: [Range<String.Index>]

        public init(score: Int, ranges: [Range<String.Index>]) {
            self.score = score
            self.ranges = ranges
        }
    }

    /// A query, folded once. Cheap to copy; build it per keystroke, not per candidate.
    public struct Pattern: Hashable, Sendable {
        /// Per-character folded keys (case- and diacritic-insensitive).
        let folded: [String]
        public let text: String

        public init(_ query: String) {
            text = query
            folded = query.map(FuzzyMatch.fold)
        }

        public var isEmpty: Bool { folded.isEmpty }
        public var count: Int { folded.count }
    }

    /// A candidate, folded once. Prepare these when the item list changes, never per keystroke.
    public struct Target: Hashable, Sendable {
        public let text: String
        let folded: [String]
        let characters: [Character]
        let indices: [String.Index]

        public init(_ text: String) {
            self.text = text
            var folded: [String] = []
            var characters: [Character] = []
            var indices: [String.Index] = []
            var i = text.startIndex
            while i < text.endIndex {
                let ch = text[i]
                characters.append(ch)
                folded.append(FuzzyMatch.fold(ch))
                indices.append(i)
                i = text.index(after: i)
            }
            self.folded = folded
            self.characters = characters
            self.indices = indices
        }

        public var isEmpty: Bool { folded.isEmpty }
        public var count: Int { folded.count }
    }

    // MARK: Entry points

    /// Convenience for one-off matches (tests, small lists). Prepare ``Pattern``/``Target`` for lists.
    public static func match(_ query: String, in text: String) -> Match? {
        match(Pattern(query), in: Target(text))
    }

    /// Scores `pattern` against `target`, or `nil` when the query is not a subsequence of it.
    ///
    /// An empty query matches everything with score 0 and no ranges — callers that want "show
    /// everything" behaviour get it for free.
    public static func match(_ pattern: Pattern, in target: Target) -> Match? {
        if pattern.isEmpty { return Match(score: 0, ranges: []) }
        let m = pattern.folded.count
        let n = target.folded.count
        guard m <= n else { return nil }

        // best[i][j] — the best score for query[0...i] with query[i] matched at candidate[j].
        // parent[i][j] — the candidate index query[i-1] matched at, for the traceback.
        let none = Int.min
        var best = [[Int]](repeating: [Int](repeating: none, count: n), count: m)
        var parent = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)

        for j in 0..<n where pattern.folded[0] == target.folded[j] {
            best[0][j] = matchBase + boundaryBonus(target, j) - min(j * leadingPenalty, leadingPenaltyCap)
        }

        for i in 1..<m {
            // Running maximum of best[i-1][k] decayed by the distance to the current j.
            var running = none
            var runningParent = -1
            for j in 0..<n {
                if j > 0 {
                    if running != none { running -= gapDecay }
                    let previous = best[i - 1][j - 1]
                    if previous != none, previous > running {
                        running = previous
                        runningParent = j - 1
                    }
                }
                guard pattern.folded[i] == target.folded[j] else { continue }
                var value = running
                var from = runningParent
                // The decayed running maximum can prefer a distant, high-scoring parent; the
                // contiguous alternative is always considered explicitly so a run cannot be lost.
                if j > 0, best[i - 1][j - 1] != none {
                    let contiguous = best[i - 1][j - 1] + consecutiveBonus
                    if contiguous > value {
                        value = contiguous
                        from = j - 1
                    }
                }
                guard value != none, from >= 0 else { continue }
                best[i][j] = value + matchBase + boundaryBonus(target, j)
                parent[i][j] = from
            }
        }

        var endIndex = -1
        var score = none
        for j in 0..<n where best[m - 1][j] > score {
            score = best[m - 1][j]
            endIndex = j
        }
        guard endIndex >= 0, score != none else { return nil }
        if m == n { score += exactBonus }

        // Traceback to the matched positions, then merge adjacent ones into ranges.
        var positions = [Int](repeating: 0, count: m)
        var j = endIndex
        var i = m - 1
        while i >= 0 {
            positions[i] = j
            j = parent[i][j]
            i -= 1
        }
        return Match(score: score, ranges: ranges(in: target, positions: positions))
    }

    /// The best match over several candidates — used where an item exposes more than one field.
    public static func bestMatch(_ pattern: Pattern, in targets: [Target]) -> (index: Int, match: Match)? {
        var best: (index: Int, match: Match)?
        for (index, target) in targets.enumerated() {
            guard let match = match(pattern, in: target) else { continue }
            if best == nil || match.score > best!.match.score { best = (index, match) }
        }
        return best
    }

    // MARK: Internals

    /// Case- and diacritic-insensitive key for one `Character`. Folding per character (rather than
    /// per string) keeps the folded array index-aligned with the original characters.
    static func fold(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func boundaryBonus(_ target: Target, _ j: Int) -> Int {
        if j == 0 { return startBonus }
        let previous = target.characters[j - 1]
        if separators.contains(previous) { return separatorBonus }
        let current = target.characters[j]
        if current.isUppercase, previous.isLowercase || previous.isNumber { return camelBonus }
        if current.isNumber, !previous.isNumber { return camelBonus }
        return 0
    }

    private static func ranges(in target: Target, positions: [Int]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var runStart = positions[0]
        var runEnd = positions[0]
        for p in positions.dropFirst() {
            if p == runEnd + 1 {
                runEnd = p
            } else {
                out.append(range(in: target, from: runStart, through: runEnd))
                runStart = p
                runEnd = p
            }
        }
        out.append(range(in: target, from: runStart, through: runEnd))
        return out
    }

    private static func range(in target: Target, from start: Int, through end: Int) -> Range<String.Index> {
        let lower = target.indices[start]
        let upper = end + 1 < target.indices.count ? target.indices[end + 1] : target.text.endIndex
        return lower..<upper
    }
}

public extension FuzzyMatch.Match {
    /// The matched ranges as `NSRange`s over `text`, for `NSMutableAttributedString`.
    /// `text` must be the string the match was produced against.
    func nsRanges(in text: String) -> [NSRange] {
        ranges.map { NSRange($0, in: text) }
    }
}
