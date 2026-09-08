// RepoInfo — "which repo is this directory in?", answered in one git call (M4.1 / TKZ-26).
//
// design.md → *Git integration*: `git -C <cwd> rev-parse --show-toplevel --git-dir --git-common-dir`,
// `repoRoot = parent(common-dir)`, `isWorktree = realpath(git-dir) != realpath(git-common-dir)`.
// One call rather than three because detection happens on every session retarget and each `git`
// launch costs more than the work it does.
//
// Two things make this fiddly enough to deserve its own type:
//
//  * `--git-dir` and `--git-common-dir` are printed **relative to the cwd** when the cwd is the
//    repo root (`.git`), and absolute otherwise. Both forms have to end up absolute before they
//    can be compared, or every plain checkout looks like a worktree.
//  * The comparison has to be on *resolved* paths, and the resolution has to be Darwin's
//    `realpath(3)` — not `NSString.resolvingSymlinksInPath`, which deliberately strips the
//    `/private` prefix on macOS. git (which resolves via `getcwd`) prints `/private/var/folders/…`
//    for a temp dir while Foundation would hand back `/var/folders/…`, and the two would never
//    compare equal. Every path in this type goes through the same `resolve`, `toplevel` included,
//    so `repoRoot == toplevel` holds in a plain checkout no matter where it lives.

import Foundation

/// Where a session's working directory sits in git: the checkout it is in, and the *main* checkout
/// behind it (`repoRoot`) which is the same for every worktree of the same repo and is therefore
/// what the app groups rows by and what one `FSEventStream` is opened per.
public struct RepoInfo: Hashable, Sendable {
    /// `git rev-parse --show-toplevel` — the top of *this* checkout (a worktree's own directory).
    public var toplevel: String
    /// `--git-dir`, absolute and resolved. For a worktree: `<main>/.git/worktrees/<name>`.
    public var gitDir: String
    /// `--git-common-dir`, absolute and resolved — the shared `.git` of the main checkout.
    public var commonDir: String
    /// `parent(commonDir)` — the MAIN checkout, even when `toplevel` is a worktree.
    public var repoRoot: String
    /// `realpath(gitDir) != realpath(commonDir)`.
    public var isWorktree: Bool
    /// `basename(toplevel)` when `isWorktree`, else `nil` — what the sidebar shows as the `WT` badge.
    public var worktreeName: String?

    public init(
        toplevel: String,
        gitDir: String,
        commonDir: String,
        repoRoot: String,
        isWorktree: Bool,
        worktreeName: String?
    ) {
        self.toplevel = toplevel
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.repoRoot = repoRoot
        self.isWorktree = isWorktree
        self.worktreeName = worktreeName
    }

    /// Runs the one `rev-parse` and derives everything from it. `nil` when `cwd` is not inside a
    /// repo (git exits non-zero), when the directory is gone, or when git could not be launched.
    ///
    /// Synchronous — it launches a process, so call it from a background queue.
    /// `GitStatusService` caches the result per cwd; there is deliberately no cache here.
    public static func detect(cwd: String, gitPath: String = GitProcess.gitPath) -> RepoInfo? {
        let output = try? GitProcess.git(
            ["rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir"],
            in: cwd, gitPath: gitPath)
        guard let output, output.succeeded else { return nil }

        let lines = output.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3 else { return nil }

        let toplevel = resolve(absolute(lines[0], relativeTo: cwd))
        let gitDir = resolve(absolute(lines[1], relativeTo: cwd))
        let commonDir = resolve(absolute(lines[2], relativeTo: cwd))
        let repoRoot = (commonDir as NSString).deletingLastPathComponent
        let isWorktree = gitDir != commonDir

        return RepoInfo(
            toplevel: toplevel,
            gitDir: gitDir,
            commonDir: commonDir,
            repoRoot: repoRoot.isEmpty ? commonDir : repoRoot,
            isWorktree: isWorktree,
            worktreeName: isWorktree ? (toplevel as NSString).lastPathComponent : nil)
    }

    /// Makes a git-printed path absolute. git prints `--git-dir` relative to the directory it was
    /// run in, which is the `-C` directory, i.e. `cwd`.
    static func absolute(_ path: String, relativeTo cwd: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        return (cwd as NSString).appendingPathComponent(path)
    }

    /// `realpath(3)`. Falls back to the input when the path does not exist (a `.git` file pointing
    /// at a removed worktree), so a detect never fails purely because of resolution.
    static func resolve(_ path: String) -> String {
        guard let buffer = Darwin.realpath(path, nil) else {
            return (path as NSString).standardizingPath
        }
        defer { free(buffer) }
        return String(cString: buffer)
    }
}
