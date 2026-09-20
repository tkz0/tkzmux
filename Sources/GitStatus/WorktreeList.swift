// WorktreeList — `git worktree list --porcelain`, parsed (M5.2).
//
// On session exit the app re-reads the repo's
// worktree list and drops the `WT` badge from any row whose worktree is gone. `claude -w` offers to
// remove its worktree when the conversation ends, so "the row says WT but the directory is not
// there any more" is the normal case after a finished session, not an edge case.
//
// Since TKZ-70 tkzmux can also remove a worktree **itself** (`WorktreeRemoval`), and this list is
// what tells every other row pointing at that directory to drop its badge afterwards. It is also
// the safety check on the destructive path: a path git does not list here as a worktree of this
// repo is never removed. That is why `list` runs under a timeout now — it sits in front of a
// delete, and a repo on a stalled network mount must cost one abandoned process, not a hung queue.
//
// The parsers are pure functions over the porcelain text so they are tested against literal output;
// `porcelain(repoRoot:)` is the only thing here that runs a process. It goes through `GitProcess`,
// so it gets `--no-optional-locks` / `GIT_OPTIONAL_LOCKS=0` (and no pager, no prompt) like every
// other git call in this app, and a background refresh never contends with the user's own git.

import Foundation

public enum WorktreeList {
    /// The `worktree <path>` entries of `--porcelain` output, in the order git printed them. The
    /// first entry is the main checkout. Paths come back as git prints them (absolute, symlinks
    /// not resolved); the caller compares after `standardizingPath`, or — on the destructive path
    /// — after `containsResolved`.
    public static func parse(_ porcelain: String) -> [String] {
        var paths: [String] = []
        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("worktree ") else { continue }
            let path = line.dropFirst("worktree ".count).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// The paths of the entries carrying a `locked` line. `--porcelain` prints one record per
    /// worktree — `worktree <path>` first, its attributes after it, then a blank line — so a
    /// `locked` (bare, or `locked <reason>`) belongs to the last `worktree` seen.
    ///
    /// `git worktree remove` refuses a locked worktree, and a lock is the user saying "not this
    /// one" — so the delete refuses it before git does, with a reason worth reading.
    public static func parseLocked(_ porcelain: String) -> Set<String> {
        var locked: Set<String> = []
        var current: String?
        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("worktree ") {
                let path = line.dropFirst("worktree ".count).trimmingCharacters(in: .whitespaces)
                current = path.isEmpty ? nil : path
            } else if line == "locked" || line.hasPrefix("locked ") {
                if let current { locked.insert(current) }
            } else if line.isEmpty {
                current = nil
            }
        }
        return locked
    }

    public enum Failure: Error, Equatable, Sendable {
        case gitExited(status: Int32, stderr: String)
        case launchFailed(String)
    }

    /// How long `git worktree list` may take. It reads `.git/worktrees/*` and stats each path, so
    /// on a healthy repo it is milliseconds; the bound is there for a stalled network mount.
    public static let listTimeout: Double = 10

    /// Runs `git -C <repoRoot> worktree list --porcelain` and parses it. Synchronous; call it off
    /// the main thread. A directory that is not a repo surfaces as `.gitExited`.
    public static func list(repoRoot: String, gitPath: String = GitProcess.gitPath) throws -> [String] {
        parse(try porcelain(repoRoot: repoRoot, gitPath: gitPath))
    }

    /// The raw porcelain, for a caller that wants both `parse` and `parseLocked` out of one launch
    /// — which is what the delete's preflight needs.
    public static func porcelain(
        repoRoot: String, gitPath: String = GitProcess.gitPath
    ) throws -> String {
        let output: GitProcess.Output
        do {
            output = try GitProcess.git(
                ["worktree", "list", "--porcelain"], in: repoRoot, gitPath: gitPath,
                timeout: listTimeout)
        } catch {
            throw Failure.launchFailed(String(describing: error))
        }
        guard output.succeeded else {
            throw Failure.gitExited(
                status: output.status,
                stderr: output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.standardOutput
    }

    /// Whether `path` is one of `worktrees`, comparing standardized paths so a trailing slash or a
    /// `..` component cannot make a present worktree look absent.
    public static func contains(_ worktrees: [String], path: String) -> Bool {
        let wanted = (path as NSString).standardizingPath
        return worktrees.contains { ($0 as NSString).standardizingPath == wanted }
    }

    /// The same question, answered with `realpath(3)` on both sides.
    ///
    /// `standardizingPath` deliberately strips the `/private` prefix on macOS while git (which
    /// resolves via `getcwd`) prints `/private/var/folders/…` — so for anything under a temp
    /// directory, or behind any other symlink, `contains` reports a present worktree as absent.
    /// `contains` is fine for the badge (a false "gone" costs a badge); the destructive path uses
    /// this one, where a false "not listed" would refuse a legitimate delete and a false match
    /// must be impossible. Same resolution as `RepoInfo`, for the same reason.
    public static func containsResolved(_ worktrees: [String], path: String) -> Bool {
        let wanted = RepoInfo.resolve(path)
        return worktrees.contains { RepoInfo.resolve($0) == wanted }
    }
}
