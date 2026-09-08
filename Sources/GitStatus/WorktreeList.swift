// WorktreeList — `git worktree list --porcelain`, parsed (M5.2 / TKZ-30).
//
// design.md → *Session flows → New worktree*: on session exit the app re-reads the repo's
// worktree list and drops the `WT` badge from any row whose worktree is gone. `claude -w` offers to
// remove its worktree when the conversation ends, so "the row says WT but the directory is not
// there any more" is the normal case after a finished session, not an edge case.
//
// The parser is a pure function over the porcelain text so it is tested against literal output;
// `list(repoRoot:)` is the only thing here that runs a process. It runs `git` with
// `GIT_OPTIONAL_LOCKS=0` and `--no-optional-locks`, as every git call in this app must
// (design.md → *Git integration*), so a background refresh never contends with the user's own git.

import Foundation

public enum WorktreeList {
    /// The `worktree <path>` entries of `--porcelain` output, in the order git printed them. The
    /// first entry is the main checkout. Paths come back as git prints them (absolute, symlinks
    /// not resolved); the caller compares after `standardizingPath`.
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

    public enum Failure: Error, Equatable, Sendable {
        case gitExited(status: Int32, stderr: String)
        case launchFailed(String)
    }

    /// Runs `git -C <repoRoot> worktree list --porcelain` and parses it. Synchronous; call it off
    /// the main thread. A directory that is not a repo surfaces as `.gitExited`.
    public static func list(repoRoot: String, gitPath: String = "/usr/bin/git") throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", repoRoot, "--no-optional-locks", "worktree", "list", "--porcelain"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // A pager or an editor must never be what a background call waits on.
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(String(describing: error))
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.gitExited(
                status: process.terminationStatus,
                stderr: String(decoding: errorOutput, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parse(String(decoding: output, as: UTF8.self))
    }

    /// Whether `path` is one of `worktrees`, comparing standardized paths so a trailing slash or a
    /// `..` component cannot make a present worktree look absent.
    public static func contains(_ worktrees: [String], path: String) -> Bool {
        let wanted = (path as NSString).standardizingPath
        return worktrees.contains { ($0 as NSString).standardizingPath == wanted }
    }
}
