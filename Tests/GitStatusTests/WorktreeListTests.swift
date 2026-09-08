// WorktreeListTests — `git worktree list --porcelain` parsing (M5.2 / TKZ-30).

import Foundation
import Testing

@testable import GitStatus

@Suite struct WorktreeListTests {

    /// Real output shape: blocks separated by blank lines, `worktree` first in each.
    static let porcelain = """
        worktree /Users/x/dev/repo
        HEAD 0123456789abcdef0123456789abcdef01234567
        branch refs/heads/main

        worktree /Users/x/dev/repo/.claude/worktrees/review
        HEAD 89abcdef0123456789abcdef0123456789abcdef
        branch refs/heads/review

        worktree /Users/x/dev/repo/.claude/worktrees/detached
        HEAD 89abcdef0123456789abcdef0123456789abcdef
        detached

        """

    @Test func parsesEveryWorktreePathInOrder() {
        #expect(WorktreeList.parse(Self.porcelain) == [
            "/Users/x/dev/repo",
            "/Users/x/dev/repo/.claude/worktrees/review",
            "/Users/x/dev/repo/.claude/worktrees/detached",
        ])
    }

    @Test func ignoresEverythingThatIsNotAWorktreeLine() {
        #expect(WorktreeList.parse("").isEmpty)
        #expect(WorktreeList.parse("HEAD abc\nbranch refs/heads/x\n").isEmpty)
        #expect(WorktreeList.parse("worktree \n").isEmpty)
        #expect(WorktreeList.parse("  worktree /a/b  \n") == ["/a/b"])
    }

    @Test func containsComparesStandardizedPaths() {
        let list = WorktreeList.parse(Self.porcelain)
        #expect(WorktreeList.contains(list, path: "/Users/x/dev/repo/.claude/worktrees/review"))
        #expect(WorktreeList.contains(list, path: "/Users/x/dev/repo/.claude/worktrees/review/"))
        #expect(WorktreeList.contains(list, path: "/Users/x/dev/repo/.claude/worktrees/other/../review"))
        #expect(WorktreeList.contains(list, path: "/Users/x/dev/repo/.claude/worktrees/gone") == false)
    }

    @Test func listsARealRepository() throws {
        // A throwaway repo with one worktree, so `list(repoRoot:)` is exercised against real git.
        let base = FileManager.default.temporaryDirectory
            .appending(path: "tkzmux-wt-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        try git("init", "-q", "-b", "main")
        try git("-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
        let worktree = repo.appending(path: ".claude/worktrees/one", directoryHint: .isDirectory)
        try git("worktree", "add", "-q", "-b", "one", worktree.path)

        let listed = try WorktreeList.list(repoRoot: repo.path)
        #expect(listed.count == 2)
        #expect(WorktreeList.contains(listed, path: worktree.path))

        // Not a repo → a git failure, not a crash and not an empty list mistaken for "no worktrees".
        let plain = base.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(throws: WorktreeList.Failure.self) { try WorktreeList.list(repoRoot: plain.path) }
    }
}
