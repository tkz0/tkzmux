// Fixtures are literal `git` output. Porcelain v2 with `-z` terminates *every* line with a NUL,
// headers included, which is why each fixture ends with one — a parser that assumed LF-separated
// headers and NUL-separated records would pass a hand-written fixture and fail on real git.

import Foundation
import Testing

@testable import GitStatus

// MARK: - porcelain v2

@Test func porcelainReportsBranchUpstreamAndAheadBehind() {
    let text = """
        # branch.oid 3b1a9c1f\0# branch.head main\0# branch.upstream origin/main\0\
        # branch.ab +2 -1\0\
        1 .M N... 100644 100644 100644 a1 a1 Sources/A.swift\0\
        1 M. N... 100644 100644 100644 b2 b3 Sources/B.swift\0
        """
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(status.branch == "main")
    #expect(status.upstream == "origin/main")
    #expect(status.ahead == 2)
    #expect(status.behind == 1)
    #expect(status.changedFiles == 2)
    #expect(status.untrackedFiles == 0)
    #expect(status.oid == "3b1a9c1f")
    #expect(status.isDetached == false)
    #expect(status.isUnborn == false)
}

@Test func porcelainWithoutUpstreamLeavesAheadBehindNil() {
    // No `# branch.upstream` means no `# branch.ab` either: "no upstream" and "in sync" are
    // different facts and must not both flatten to 0 in the parsed value.
    let text = """
        # branch.oid 3b1a9c1f\0# branch.head feature/x\0\
        1 .M N... 100644 100644 100644 a1 a1 README.md\0
        """
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(status.branch == "feature/x")
    #expect(status.upstream == nil)
    #expect(status.ahead == nil)
    #expect(status.behind == nil)
    #expect(status.changedFiles == 1)
}

@Test func porcelainUpstreamWithoutAheadBehind() {
    // An upstream that git cannot resolve (never fetched) prints `branch.upstream` and no
    // `branch.ab`.
    let text = "# branch.oid 3b1a9c1f\0# branch.head main\0# branch.upstream origin/main\0"
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(status.upstream == "origin/main")
    #expect(status.ahead == nil)
    #expect(status.behind == nil)
}

@Test func porcelainDetachedHeadHasNoBranch() {
    let text = """
        # branch.oid 3b1a9c1f\0# branch.head (detached)\0\
        1 .M N... 100644 100644 100644 a1 a1 README.md\0
        """
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(status.branch == nil)
    #expect(status.isDetached)
    #expect(status.changedFiles == 1)
}

@Test func porcelainUnbornBranchKeepsTheHeadName() {
    // A repo with no commit yet: `branch.oid` is `(initial)` but `branch.head` still names the
    // branch that the first commit will create.
    let text = "# branch.oid (initial)\0# branch.head main\0? first.txt\0"
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(status.isUnborn)
    #expect(status.oid == nil)
    #expect(status.branch == "main")
    #expect(status.ahead == nil)
    #expect(status.behind == nil)
    #expect(status.untrackedFiles == 1)
    #expect(status.changedFiles == 0)
}

@Test func porcelainRenameCountsOnceDespiteTwoPaths() {
    // THE `-z` TRAP: a `2` record is followed by a second NUL-separated field holding the original
    // path. Two changed files here, not three.
    let text = """
        # branch.oid 3b1a9c1f\0# branch.head main\0\
        2 R. N... 100644 100644 100644 a1 a2 R100 new/path.swift\0old/path.swift\0\
        1 .M N... 100644 100644 100644 b1 b1 other.swift\0
        """
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(status.changedFiles == 2)
    #expect(status.untrackedFiles == 0)
}

@Test func porcelainRenameOriginalPathIsNeverParsedAsARecord() {
    // The original path is arbitrary user text; a file really can be named `1 old.swift`. Unless
    // the second field is *consumed*, this fixture counts three changed files instead of one.
    let text = """
        # branch.oid 3b1a9c1f\0# branch.head main\0\
        2 R. N... 100644 100644 100644 a1 a2 R100 renamed.swift\01 old.swift\0
        """
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(status.changedFiles == 1)
}

@Test func porcelainCountsUnmergedAndUntrackedAndSkipsIgnored() {
    let text = """
        # branch.oid 3b1a9c1f\0# branch.head main\0\
        u UU N... 100644 100644 100644 100644 a1 a2 a3 conflict.txt\0\
        ? untracked-one.txt\0? untracked-two.txt\0! build/ignored.o\0
        """
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(status.changedFiles == 1)
    #expect(status.untrackedFiles == 2)
}

@Test func porcelainCleanRepoHasNoChanges() {
    let text = """
        # branch.oid 3b1a9c1f\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +0 -0\0
        """
    let status = GitStatusParsing.parsePorcelainV2(text)
    #expect(status.branch == "main")
    #expect(status.ahead == 0)
    #expect(status.behind == 0)
    #expect(status.changedFiles == 0)
    #expect(status.untrackedFiles == 0)
}

@Test func porcelainEmptyOutputIsAllZeros() {
    let status = GitStatusParsing.parsePorcelainV2("")
    #expect(status.branch == nil)
    #expect(status.changedFiles == 0)
    #expect(status.untrackedFiles == 0)
}

// MARK: - shortstat

@Test func shortstatParsesAllThreeClauses() {
    let stat = GitStatusParsing.parseShortstat(" 12 files changed, 142 insertions(+), 38 deletions(-)\n")
    #expect(stat.files == 12)
    #expect(stat.insertions == 142)
    #expect(stat.deletions == 38)
}

@Test func shortstatInsertionsOnly() {
    let stat = GitStatusParsing.parseShortstat(" 2 files changed, 9 insertions(+)\n")
    #expect(stat.files == 2)
    #expect(stat.insertions == 9)
    #expect(stat.deletions == 0)
}

@Test func shortstatDeletionsOnly() {
    let stat = GitStatusParsing.parseShortstat(" 3 files changed, 7 deletions(-)\n")
    #expect(stat.files == 3)
    #expect(stat.insertions == 0)
    #expect(stat.deletions == 7)
}

@Test func shortstatSingularWordsStillParse() {
    // Under `LC_ALL=C` git writes the singular for 1 — matching the plural would silently read 0.
    let stat = GitStatusParsing.parseShortstat(" 1 file changed, 1 insertion(+), 1 deletion(-)\n")
    #expect(stat.files == 1)
    #expect(stat.insertions == 1)
    #expect(stat.deletions == 1)
}

@Test func shortstatEmptyOutputIsZeros() {
    let stat = GitStatusParsing.parseShortstat("")
    #expect(stat.files == 0)
    #expect(stat.insertions == 0)
    #expect(stat.deletions == 0)
}
