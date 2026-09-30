// FileLinkDetector — finding a file path printed as plain text under the pointer.
//
// OSC 8 links are announced by the program; a path in `git status`, a compiler error or Claude
// Code's `⏺ Update(Sources/Foo.swift)` is just text. This file only decides *which characters*
// around the pointer look like a path. Whether that path names a real file is the app's call
// (`MouseController.resolveFilePath`), because only the app knows the pane's directory.
//
// Pure and total over rows of cells, so it is table-tested without a terminal.

/// A path-shaped run of cells on one row.
public struct FileLinkCandidate: Sendable, Equatable {
    /// The path as printed, with any `:line[:column]` suffix removed.
    public var path: String
    /// The `:line` suffix, when there was one.
    public var line: Int?
    /// The cells the whole token covers (suffix included), for the hover underline.
    public var columns: ClosedRange<UInt16>

    public init(path: String, line: Int? = nil, columns: ClosedRange<UInt16>) {
        self.path = path
        self.line = line
        self.columns = columns
    }

    /// For an elided path — `…/shot-7.jpg` or `.../shot-7.jpg`, which Claude Code prints for "the
    /// same place as the path above" — the part after the elision; nil for an ordinary path.
    public var elidedTail: String? {
        for prefix in FileLinkDetector.elisionPrefixes where path.hasPrefix(prefix) {
            let tail = path.dropFirst(prefix.count)
            return tail.isEmpty ? nil : String(tail)
        }
        return nil
    }
}

public enum FileLinkDetector {
    /// Punctuation that ends a sentence around a path rather than belonging to it:
    /// `see Sources/Foo.swift.` or `Sources/Foo.swift:12:`.
    private static let trailingTrim: Set<String> = [".", ",", ":", ";"]
    private static let leadingTrim: Set<String> = [":", ","]

    /// Whether one cell can be part of a path. Brackets, quotes and backticks deliberately cannot,
    /// so `(Sources/Foo.swift)` and `` `README.md` `` resolve to what is inside them.
    static func isPathCell(_ cell: String) -> Bool {
        guard cell.count == 1, let character = cell.first else { return false }
        if character.isLetter || character.isNumber { return true }
        return "._-/~+@#%=:,".contains(character)
    }

    /// The ellipsis Claude Code puts in front of a path whose leading directories it left out.
    static let ellipsis = "\u{2026}"
    static let elisionPrefixes = ["\u{2026}/", ".../"]

    /// The path-shaped token containing `column`, or nil when the pointer is not on one.
    ///
    /// A token must contain a `/` or a `.` to count: a bare word such as `hello` is far more often
    /// prose than a file, and every candidate costs the resolver a `stat`.
    ///
    /// `…` is not a path cell (`wait…` is prose), but directly in front of a `/` it is the elision
    /// marker of `…/name` and belongs to the token, so the path is not mistaken for `/name`.
    public static func candidate(in cells: [String], column: Int) -> FileLinkCandidate? {
        var column = column
        if cells.indices.contains(column), cells[column] == ellipsis,
            column + 1 < cells.count, cells[column + 1] == "/"
        {
            column += 1
        }
        guard cells.indices.contains(column), isPathCell(cells[column]) else { return nil }
        var start = column
        var end = column
        while start > 0, isPathCell(cells[start - 1]) { start -= 1 }
        while end + 1 < cells.count, isPathCell(cells[end + 1]) { end += 1 }
        let run = trimmed(cells, start...end)
        guard run.contains(column) else { return nil }
        start = isElided(cells, at: run.lowerBound) ? run.lowerBound - 1 : run.lowerBound
        end = run.upperBound

        let token = cells[start...end].joined()
        guard !token.contains("://") else { return nil }

        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        let path = String(parts[0])
        guard !path.isEmpty, path.contains("/") || path.contains(".") else { return nil }
        guard path != "." && path != ".." else { return nil }
        let line = parts.count > 1 ? Int(parts[1]) : nil
        // `foo:bar` with a non-numeric suffix is not `path:line`; refuse rather than guess.
        if parts.count > 1, line == nil { return nil }

        return FileLinkCandidate(
            path: path, line: line, columns: UInt16(start)...UInt16(end))
    }

    /// Every absolute (`/…`) or home-relative (`~/…`) path printed on `rows`, which are given
    /// nearest first; the result keeps that order, without duplicates or `:line` suffixes. These
    /// are the anchors an elided `…/name` is resolved against.
    public static func absolutePaths(in rows: [[String]]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for cells in rows {
            var index = 0
            while index < cells.count {
                guard isPathCell(cells[index]) else {
                    index += 1
                    continue
                }
                var end = index
                while end + 1 < cells.count, isPathCell(cells[end + 1]) { end += 1 }
                let run = trimmed(cells, index...end)
                index = end + 1
                // `…/name` is itself elided, not an absolute path.
                guard !isElided(cells, at: run.lowerBound) else { continue }
                let token = cells[run].joined()
                guard !token.contains("://") else { continue }
                let path = String(token.split(separator: ":", omittingEmptySubsequences: false)[0])
                guard path.count > 1, path.hasPrefix("/") || path.hasPrefix("~/") else { continue }
                if seen.insert(path).inserted { out.append(path) }
            }
        }
        return out
    }

    /// Where `…/tail` may be, best first: next to each anchor, then in each of the anchor's
    /// ancestors, since `…` can stand for more than one directory (`…/Sources/Foo.swift` under a
    /// project path printed above). Stops short of `/` and `~`: a path elided down to those would
    /// have been printed as `/tail` or `~/tail`.
    public static func elisionExpansions(tail: String, anchors: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for anchor in anchors {
            var directory = Substring(anchor)
            while let slash = directory.lastIndex(of: "/") {
                directory = directory[..<slash]
                guard !directory.isEmpty, directory != "~" else { break }
                let path = String(directory) + "/" + tail
                if seen.insert(path).inserted { out.append(path) }
            }
        }
        return out
    }

    /// `range` without sentence punctuation at either end (never emptier than one cell).
    private static func trimmed(_ cells: [String], _ range: ClosedRange<Int>) -> ClosedRange<Int> {
        var start = range.lowerBound
        var end = range.upperBound
        while end > start, trailingTrim.contains(cells[end]) { end -= 1 }
        while start < end, leadingTrim.contains(cells[start]) { start += 1 }
        return start...end
    }

    /// Whether a run starting at `start` is the `/name` half of `…/name`.
    private static func isElided(_ cells: [String], at start: Int) -> Bool {
        start > 0 && cells[start] == "/" && cells[start - 1] == ellipsis
    }
}
