// Turning a path printed in a pane into a file on disk.
//
// A relative path is relative to *something*: usually the pane's shell, but Claude Code prints
// paths relative to the project it was started in, which is the worktree even when the shell
// underneath never left the main checkout. So a candidate is tried against an ordered list of
// directories and the first regular file wins.

import Foundation
import TkzCore

enum FilePathResolver {
    /// The first existing regular file `candidate` names, or nil.
    ///
    /// `a/…` and `b/…` are also tried without their prefix, since that is how `git diff` prints
    /// every path. Directories never resolve: a directory has nothing to show read-only.
    static func resolve(
        _ candidate: String,
        bases: [String],
        home: String,
        fileManager: FileManager = .default
    ) -> URL? {
        var variants = [candidate]
        if candidate.hasPrefix("a/") || candidate.hasPrefix("b/") {
            variants.append(String(candidate.dropFirst(2)))
        }
        for variant in variants {
            for path in expansions(of: variant, bases: bases, home: home) {
                let standardized = (path as NSString).standardizingPath
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
                    !isDirectory.boolValue
                {
                    return URL(fileURLWithPath: standardized)
                }
            }
        }
        return nil
    }

    private static func expansions(of path: String, bases: [String], home: String) -> [String] {
        if path.hasPrefix("~/") {
            return [(home as NSString).appendingPathComponent(String(path.dropFirst(2)))]
        }
        if path.hasPrefix("/") { return [path] }
        return bases.filter { !$0.isEmpty }.map { ($0 as NSString).appendingPathComponent(path) }
    }

    /// Where a path printed in `terminal` may be relative to, best first: the pane's own
    /// directory, the worktree it sits in, then the directories the row was started from.
    static func bases(for terminal: TerminalID, in session: Session) -> [String] {
        let pane = session.paneDirectory(terminal)
        var candidates = [pane]
        if let worktree = session.worktreeRoot(ofPath: pane) { candidates.append(worktree) }
        if session.isWorktree, let worktree = session.worktreePath { candidates.append(worktree) }
        candidates.append(session.effectiveCwd)
        if let repoRoot = session.repoRoot { candidates.append(repoRoot) }
        candidates.append(session.cwd)

        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
