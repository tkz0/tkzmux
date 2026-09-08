// Real repos in a temp directory, because the whole point of `RepoInfo` is the difference between
// what git *prints* (relative `--git-dir`, `/private/var/…` for a temp dir) and what a naive
// Foundation path helper would produce. A fixture-string test would prove nothing here.
//
// The fixture (`TKZ26Fixture`) lives in `GitStatusServiceTests.swift`.

import Foundation
import Testing

@testable import GitStatus

// Serialized: every test here launches `git` and blocks its thread until the process exits, and
// Swift Testing runs tests in parallel by default. Twenty of those at once starve libdispatch's
// thread pool badly enough that `GitProcess`'s timeout fires and detection returns `nil` — a flake
// that has nothing to do with the code under test. Serially the whole suite is well under a second.
@Suite(.serialized) struct RepoInfoTests {
    @Test func detectPlainCheckout() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()

        let info = RepoInfo.detect(cwd: checkout)
        #expect(info != nil)
        #expect(info?.toplevel == checkout)
        #expect(info?.isWorktree == false)
        #expect(info?.worktreeName == nil)
        // `parent(commonDir)` of a plain checkout is the checkout itself.
        #expect(info?.repoRoot == checkout)
        #expect(info?.gitDir == (checkout as NSString).appendingPathComponent(".git"))
        #expect(info?.commonDir == info?.gitDir)
    }

    @Test func detectFromASubdirectoryStillFindsTheToplevel() {
        // The case that exposes the relative-`--git-dir` trap from the other side: run from a
        // subdirectory and git prints an *absolute* git dir, run from the root and it prints `.git`.
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let nested = (checkout as NSString).appendingPathComponent("Sources/Deep")
        try? FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)

        let info = RepoInfo.detect(cwd: nested)
        #expect(info?.toplevel == checkout)
        #expect(info?.repoRoot == checkout)
        #expect(info?.isWorktree == false)
        #expect(info?.gitDir == (checkout as NSString).appendingPathComponent(".git"))
    }

    @Test func detectWorktreePointsAtTheMainCheckout() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout("main-checkout")
        let worktree = fixture.addWorktree("wt-feature", of: checkout, branch: "feature")

        let info = RepoInfo.detect(cwd: worktree)
        #expect(info != nil)
        #expect(info?.toplevel == worktree)
        #expect(info?.isWorktree == true)
        #expect(info?.worktreeName == "wt-feature")
        // `repoRoot` is the MAIN checkout even though we asked from inside the worktree.
        #expect(info?.repoRoot == checkout)
        #expect(info?.commonDir == (checkout as NSString).appendingPathComponent(".git"))
        #expect(
            info?.gitDir
                == (checkout as NSString).appendingPathComponent(".git/worktrees/wt-feature"))
        #expect(info?.gitDir != info?.commonDir)
    }

    @Test func detectMainCheckoutIsNotAWorktreeEvenWhenOneExists() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout("main-checkout")
        _ = fixture.addWorktree("wt-feature", of: checkout, branch: "feature")

        let info = RepoInfo.detect(cwd: checkout)
        #expect(info?.isWorktree == false)
        #expect(info?.repoRoot == checkout)
    }

    @Test func detectReturnsNilOutsideARepo() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let plain = fixture.makePlainDirectory("not-a-repo")
        #expect(RepoInfo.detect(cwd: plain) == nil)
    }

    @Test func detectReturnsNilForAMissingDirectory() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        #expect(RepoInfo.detect(cwd: fixture.path("never-created")) == nil)
    }

    @Test func absoluteResolvesGitsRelativeGitDir() {
        #expect(RepoInfo.absolute(".git", relativeTo: "/repo") == "/repo/.git")
        #expect(RepoInfo.absolute("/elsewhere/.git", relativeTo: "/repo") == "/elsewhere/.git")
    }
}
