// The paths behind the counts — what the search overlay's "Files changed" section lists (TKZ-52).
//
// Same fixture shape as `GitStatusParsingTests`: literal `git status --porcelain=v2 --branch -z`
// output, every line NUL-terminated, headers included.

import Foundation
import Testing

@testable import GitStatus

@Test func porcelainKeepsThePathsBehindTheCounts() {
    let text = """
        # branch.oid 3b1a9c1f\0# branch.head main\0\
        1 .M N... 100644 100644 100644 a1 a1 Sources/A.swift\0\
        1 M. N... 100644 100644 100644 b2 b3 Sources/B.swift\0\
        u UU N... 100644 100644 100644 100644 a1 a2 a3 conflict.txt\0\
        ? untracked.txt\0! build/ignored.o\0
        """
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(
        status.paths.map(\.path) == [
            "Sources/A.swift", "Sources/B.swift", "conflict.txt", "untracked.txt",
        ])
    // The first XY letter that is not `.`; `?` stays `?`. An ignored record contributes nothing.
    #expect(status.paths.map(\.status) == ["M", "M", "U", "?"])
    #expect(status.paths.count == status.changedFiles + status.untrackedFiles)
}

@Test func porcelainKeepsARenamesNewPathAndNotItsOld() {
    let text = """
        # branch.oid 3b1a9c1f\0# branch.head main\0\
        2 R. N... 100644 100644 100644 a1 a2 R100 new/path.swift\0old/path.swift\0\
        1 .M N... 100644 100644 100644 b1 b1 other.swift\0
        """
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(status.paths.map(\.path) == ["new/path.swift", "other.swift"])
    #expect(status.paths.first?.status == "R")
}

@Test func porcelainDoesNotMistakeARenamesOldPathForARecord() {
    // The original path is arbitrary user text; a file really can be named `1 old.swift`.
    let text = """
        # branch.oid 3b1a9c1f\0# branch.head main\0\
        2 R. N... 100644 100644 100644 a1 a2 R100 renamed.swift\01 old.swift\0
        """
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(status.paths.map(\.path) == ["renamed.swift"])
}

@Test func porcelainKeepsPathsThatContainSpaces() {
    // The path is the last field and may hold anything, so it cannot be split off by whitespace.
    let text = """
        # branch.oid 3b1a9c1f\0# branch.head main\0\
        1 .M N... 100644 100644 100644 a1 a1 Sources/My Folder/A File.swift\0\
        ? an untracked file.txt\0
        """
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(
        status.paths.map(\.path) == ["Sources/My Folder/A File.swift", "an untracked file.txt"])
}

@Test func porcelainStopsCollectingPathsAtTheCap() {
    // A tree with a huge untracked build directory must not be carried around in full.
    let records = (0..<(GitStatusParsing.pathLimit + 500))
        .map { "? file-\($0).txt\0" }
        .joined()
    let status = GitStatusParsing.parsePorcelainV2("# branch.head main\0" + records)
    #expect(status.untrackedFiles == GitStatusParsing.pathLimit + 500, "the count is still exact")
    #expect(status.paths.count == GitStatusParsing.pathLimit, "the list is not")
}

@Test func aTrackedSessionWithNoRefreshYetHasNoPaths() {
    let service = GitStatusService { _, _ in }
    #expect(service.changedPaths(for: .init(uuid: UUID())).isEmpty)
}
