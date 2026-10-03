// The rebase runner (design 5a/5b, 2026-09-13), over real repos: the happy path, the autostash,
// the two ways a conflict can happen, and every reason it refuses to start. The remote is a bare
// repo on disk, so `fetch` is real but needs no network.

import Foundation
import Testing
import TkzCore

@testable import GitStatus

@Suite(.serialized) struct GitRebaseTests {

    private static func request(for directory: String, remote: String? = "origin", skipFetch: Bool = false) -> GitRebase.Request {
        let info = RepoInfo.detect(cwd: directory)!
        return GitRebase.Request(
            toplevel: info.toplevel, gitDir: info.gitDir,
            base: BaseBranch(remote: remote, name: "main"), skipFetch: skipFetch)
    }

    private static func head(_ fixture: TKZ26Fixture, _ directory: String) -> String {
        fixture.git(["rev-parse", "HEAD"], in: directory).trimmedOutput
    }

    private static func count(_ fixture: TKZ26Fixture, _ range: String, in directory: String) -> Int {
        Int(fixture.git(["rev-list", "--count", range], in: directory).trimmedOutput) ?? -1
    }

    private static func hasRebaseInProgress(_ directory: String) -> Bool {
        let gitDir = RepoInfo.detect(cwd: directory)!.gitDir
        return ["rebase-merge", "rebase-apply"].contains {
            FileManager.default.fileExists(atPath: (gitDir as NSString).appendingPathComponent($0))
        }
    }

    // MARK: Happy paths

    @Test func rebasesAndCountsTheReplayedCommits() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, seed, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        fixture.commit("f1\n", to: "feature.txt", in: clone)
        fixture.commit("f2\n", to: "feature.txt", in: clone)
        fixture.commits(3, in: seed)
        fixture.git(["push", "origin", "main"], in: seed)

        // Not fetched yet: the runner's own fetch has to bring the three commits in.
        let outcome = GitRebase.run(Self.request(for: clone))

        #expect(outcome == .rebased(commits: 2, stashReapplied: false))
        #expect(Self.count(fixture, "origin/main..HEAD", in: clone) == 2)
        #expect(Self.count(fixture, "HEAD..origin/main", in: clone) == 0)
        #expect(!Self.hasRebaseInProgress(clone))
    }

    @Test func aDirtyTreeIsStashedAndPutBack() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, seed, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        fixture.commit("f1\n", to: "feature.txt", in: clone)
        fixture.commits(1, in: seed)
        fixture.git(["push", "origin", "main"], in: seed)
        // An uncommitted edit to a tracked file, and an untracked scratch file.
        let edited = (clone as NSString).appendingPathComponent("feature.txt")
        fixture.write("edited\n", to: edited)
        fixture.write("scratch\n", to: (clone as NSString).appendingPathComponent("notes.tmp"))

        let outcome = GitRebase.run(Self.request(for: clone))

        #expect(outcome == .rebased(commits: 1, stashReapplied: true))
        #expect((try? String(contentsOfFile: edited, encoding: .utf8)) == "edited\n")
        #expect(FileManager.default.fileExists(atPath: (clone as NSString).appendingPathComponent("notes.tmp")))
        #expect(fixture.git(["stash", "list"], in: clone).trimmedOutput.isEmpty)
        #expect(Self.count(fixture, "HEAD..origin/main", in: clone) == 0)
    }

    @Test func upToDateSkipsTheRebase() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, _, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        fixture.commits(2, in: clone)
        let before = Self.head(fixture, clone)

        #expect(GitRebase.run(Self.request(for: clone)) == .upToDate)
        #expect(Self.head(fixture, clone) == before)
    }

    @Test func aLocalBaseNeedsNoFetch() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addWorktree("feature-wt", of: checkout, branch: "feature")
        fixture.commit("w\n", to: "wt.txt", in: worktree)
        fixture.commits(2, in: checkout)

        let outcome = GitRebase.run(Self.request(for: worktree, remote: nil))

        #expect(outcome == .rebased(commits: 1, stashReapplied: false))
        #expect(Self.count(fixture, "main..HEAD", in: worktree) == 1)
        #expect(Self.count(fixture, "HEAD..main", in: worktree) == 0)
    }

    @Test func skipFetchUsesTheLocalRefs() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (bare, _, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        fixture.commits(1, in: clone)
        // The remote is gone: a fetch fails, but the sheet fetched a moment ago.
        try? FileManager.default.removeItem(atPath: bare)

        #expect(GitRebase.run(Self.request(for: clone, skipFetch: true)) == .upToDate)
        if case .fetchFailed = GitRebase.run(Self.request(for: clone)) {} else {
            Issue.record("a fetch of a missing remote should fail")
        }
        #expect(GitRebase.fetch(Self.request(for: clone, remote: nil)) == nil)
    }

    // MARK: Branch drift

    /// The worktree's own terminal switched branches after the sheet captured `expectedBranch` —
    /// the exact race `run` re-checks `HEAD` for immediately before the write.
    @Test func aBranchSwitchAfterTheRequestWasBuiltRefusesTheRebase() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, seed, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        fixture.commit("f1\n", to: "feature.txt", in: clone)
        fixture.commits(1, in: seed)
        fixture.git(["push", "origin", "main"], in: seed)
        let before = Self.head(fixture, clone)

        var request = Self.request(for: clone)
        request.expectedBranch = "feature"
        fixture.git(["switch", "-c", "other"], in: clone)

        let outcome = GitRebase.run(request)

        if case .failed(let message) = outcome {
            #expect(message.contains("moved"))
        } else {
            Issue.record("expected a refusal, got \(outcome)")
        }
        #expect(Self.head(fixture, clone) == before)
        #expect(!Self.hasRebaseInProgress(clone))
    }

    /// A detached `HEAD` reached the same way: `symbolic-ref` returns nothing, which must not
    /// match a non-nil `expectedBranch` either.
    @Test func aDetachAfterTheRequestWasBuiltRefusesTheRebase() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, seed, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        fixture.commit("f1\n", to: "feature.txt", in: clone)
        fixture.commits(1, in: seed)
        fixture.git(["push", "origin", "main"], in: seed)
        let before = Self.head(fixture, clone)

        var request = Self.request(for: clone)
        request.expectedBranch = "feature"
        fixture.git(["checkout", "HEAD~0"], in: clone)

        let outcome = GitRebase.run(request)

        if case .failed(let message) = outcome {
            #expect(message.contains("moved"))
        } else {
            Issue.record("expected a refusal, got \(outcome)")
        }
        #expect(Self.head(fixture, clone) == before)
    }

    // MARK: Conflicts

    @Test func aConflictAbortsAndRestoresTheTree() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, seed, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        fixture.commit("mine\n", to: "shared.txt", in: clone)
        fixture.commit("theirs\n", to: "shared.txt", in: seed)
        fixture.git(["push", "origin", "main"], in: seed)
        let before = Self.head(fixture, clone)

        let outcome = GitRebase.run(Self.request(for: clone))

        #expect(outcome == .conflicts(files: 1))
        #expect(Self.head(fixture, clone) == before)
        #expect(fixture.git(["status", "--porcelain"], in: clone).trimmedOutput.isEmpty)
        #expect(!Self.hasRebaseInProgress(clone))
        #expect((try? String(contentsOfFile: (clone as NSString).appendingPathComponent("shared.txt"), encoding: .utf8)) == "mine\n")
    }

    @Test func aStashThatDoesNotReapplyIsReportedAndKept() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, seed, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        fixture.commit("f\n", to: "feature.txt", in: clone)
        fixture.commit("theirs\n", to: "shared.txt", in: seed)
        fixture.git(["push", "origin", "main"], in: seed)
        // Uncommitted, on the line the remote also changed.
        fixture.write("local\n", to: (clone as NSString).appendingPathComponent("shared.txt"))

        let outcome = GitRebase.run(Self.request(for: clone))

        #expect(outcome == .rebasedStashConflict(commits: 1))
        // The commit was replayed; the local change is kept in the stash, not lost.
        #expect(Self.count(fixture, "origin/main..HEAD", in: clone) == 1)
        #expect(!fixture.git(["stash", "list"], in: clone).trimmedOutput.isEmpty)
        #expect(!Self.hasRebaseInProgress(clone))
    }

    // MARK: Preflight

    @Test func preflightRefusesForTheRightReasons() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let gitDir = RepoInfo.detect(cwd: checkout)!.gitDir

        #expect(GitRebase.preflight(summary: nil, gitDir: gitDir) == .noBase)
        #expect(GitRebase.preflight(summary: GitSummary(branch: "f"), gitDir: gitDir) == .noBase)
        #expect(GitRebase.preflight(
            summary: GitSummary(branch: nil, baseBranch: "origin/main"), gitDir: gitDir) == .detachedHead)
        #expect(GitRebase.preflight(
            summary: GitSummary(branch: "main", baseBranch: "origin/main"), gitDir: gitDir) == .onBase)

        let off = GitSummary(branch: "f", baseBranch: "origin/main", aheadOfBase: 1, behindBase: 2)
        #expect(GitRebase.preflight(summary: off, gitDir: gitDir) == nil)
        // A dirty tree is not a refusal: the rebase stashes.
        var dirty = off
        dirty.changedFiles = 3
        dirty.untrackedFiles = 1
        #expect(GitRebase.preflight(summary: dirty, gitDir: gitDir) == nil)

        let marker = (gitDir as NSString).appendingPathComponent("rebase-merge")
        try? FileManager.default.createDirectory(atPath: marker, withIntermediateDirectories: true)
        #expect(GitRebase.preflight(summary: off, gitDir: gitDir) == .rebaseInProgress)
        try? FileManager.default.removeItem(atPath: marker)

        let merge = (gitDir as NSString).appendingPathComponent("MERGE_HEAD")
        fixture.write("0000\n", to: merge)
        #expect(GitRebase.preflight(summary: off, gitDir: gitDir) == .mergeInProgress)
    }

    @Test func behindCountReadsTheLocalRefs() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, seed, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        fixture.commits(4, in: seed)
        fixture.git(["push", "origin", "main"], in: seed)

        #expect(GitRebase.behindCount(Self.request(for: clone)) == 0)
        #expect(GitRebase.fetch(Self.request(for: clone)) == nil)
        #expect(GitRebase.behindCount(Self.request(for: clone)) == 4)
        #expect(GitRebase.behindCount(GitRebase.Request(
            toplevel: clone, gitDir: "", base: BaseBranch(remote: "origin", name: "nope"))) == nil)
    }

    // MARK: Environment

    #if os(macOS)
    @Test func fetchEnvironmentPrependsHomebrewAndKeepsTheNoPromptRules() {
        let overrides = GitRebase.fetchEnvironment(path: "/usr/bin:/bin:/opt/homebrew/bin")
        #expect(overrides["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(GitRebase.fetchEnvironment(path: nil)["PATH"] == "/opt/homebrew/bin:/usr/local/bin")

        let env = GitProcess.environment(base: ["PATH": "/usr/bin", "HOME": "/Users/x"], overrides: overrides)
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["GIT_ASKPASS"] == "")
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/x")
    }
    #else
    @Test func fetchEnvironmentKeepsThePathFirstAppendsTheFallbacksAndTheNoPromptRules() {
        let userPath = "/h/.local/share/mise/installs/gh/2.63.0/bin:/usr/bin:/bin"
        let overrides = GitRebase.fetchEnvironment(path: userPath, home: "/h")
        #expect(overrides["PATH"] == userPath + ":/h/.local/bin:/usr/local/bin")
        #expect(GitRebase.fetchEnvironment(path: nil, home: "/h")["PATH"] == "/h/.local/bin:/usr/local/bin:/usr/bin")
        #expect(GitRebase.fetchEnvironment(path: "", home: "/h/")["PATH"] == "/h/.local/bin:/usr/local/bin:/usr/bin")

        let env = GitProcess.environment(base: ["PATH": "/usr/bin", "HOME": "/h"], overrides: overrides)
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["GIT_ASKPASS"] == "")
        #expect(env["PATH"] == userPath + ":/h/.local/bin:/usr/local/bin")
        #expect(env["HOME"] == "/h")
    }
    #endif

    @Test func lastLinePrefersStderr() {
        let output = GitProcess.Output(status: 128, standardOutput: "out\n", standardError: "fatal: a\nfatal: b")
        #expect(GitRebase.lastLine(of: output) == "fatal: b")
        let quiet = GitProcess.Output(status: 1, standardOutput: "", standardError: "")
        #expect(GitRebase.lastLine(of: quiet) == "exit status 1")
    }
}
