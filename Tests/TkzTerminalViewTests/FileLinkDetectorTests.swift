// Plain-text file paths under the pointer: which cells ⌘-click treats as a path.

import Testing

@testable import TkzTerminalView

struct FileLinkDetectorTests {
    /// One cell per character, the way `RowTextLookup` returns an ASCII row.
    private static func cells(_ row: String) -> [String] { row.map { String($0) } }

    private static func candidate(_ row: String, at marker: String) -> FileLinkCandidate? {
        let column = row.distance(from: row.startIndex, to: row.range(of: marker)!.lowerBound)
        return FileLinkDetector.candidate(in: cells(row), column: column)
    }

    @Test func findsARelativePathAroundThePointer() {
        let found = Self.candidate("  modified: Sources/TkzApp/Foo.swift", at: "TkzApp")
        #expect(found?.path == "Sources/TkzApp/Foo.swift")
        #expect(found?.columns == 12...35)
    }

    @Test func stripsBracketsQuotesAndSentencePunctuation() {
        #expect(Self.candidate("⏺ Update(docs/design.md)", at: "design")?.path == "docs/design.md")
        #expect(Self.candidate("see `README.md`.", at: "READ")?.path == "README.md")
        #expect(Self.candidate("open docs/perf.md.", at: "perf")?.path == "docs/perf.md")
    }

    @Test func separatesALineNumberSuffix() {
        let found = Self.candidate("Sources/A.swift:42:7: error", at: "A.swift")
        #expect(found?.path == "Sources/A.swift")
        #expect(found?.line == 42)
    }

    @Test func refusesWordsURLsAndBlankCells() {
        #expect(Self.candidate("just some prose", at: "some") == nil)
        #expect(Self.candidate("go to https://example.com/a.md", at: "example") == nil)
        #expect(FileLinkDetector.candidate(in: ["", "a"], column: 0) == nil)
        #expect(FileLinkDetector.candidate(in: [], column: 3) == nil)
    }

    @Test func thePointerOnTrimmedPunctuationIsNotALink() {
        #expect(Self.candidate("docs/perf.md, then", at: ", then") == nil)
    }

    // MARK: Elided paths

    @Test func keepsTheEllipsisOfAnElidedPath() {
        let row = "- Phone drawer: …/screenshot-9.png"
        let found = Self.candidate(row, at: "screenshot")
        #expect(found?.path == "…/screenshot-9.png")
        #expect(found?.elidedTail == "screenshot-9.png")
        #expect(found?.columns == 16...33)
        // The pointer on the ellipsis itself is on the same link.
        #expect(Self.candidate(row, at: "…") == found)
    }

    @Test func threeDotsElideToo() {
        #expect(Self.candidate("see .../a/b.swift", at: "b.swift")?.elidedTail == "a/b.swift")
        #expect(Self.candidate("see Sources/a.swift", at: "a.swift")?.elidedTail == nil)
    }

    @Test func anEllipsisInProseIsNotAPath() {
        #expect(Self.candidate("wait… then", at: "…") == nil)
        #expect(Self.candidate("wait… then", at: "then") == nil)
    }

    @Test func absolutePathsAreFoundNearestFirstWithoutSuffixesOrDuplicates() {
        let rows = [
            "- Phone: …/shot-7.jpg and ~/dev/a.txt:12",
            "- Desktop: /var/folders/x/T/dir/shot-0.jpg, see Sources/Foo.swift",
            "https://example.com/x and /var/folders/x/T/dir/shot-0.jpg again",
        ].map(Self.cells)
        #expect(FileLinkDetector.absolutePaths(in: rows) == [
            "~/dev/a.txt", "/var/folders/x/T/dir/shot-0.jpg",
        ])
    }

    @Test func elisionExpansionsWalkUpEachAnchorInTurn() {
        let expansions = FileLinkDetector.elisionExpansions(
            tail: "b.png", anchors: ["/var/x/T/a.png", "~/dev/p/c.md"])
        #expect(expansions == [
            "/var/x/T/b.png", "/var/x/b.png", "/var/b.png",
            "~/dev/p/b.png", "~/dev/b.png",
        ])
    }
}
