// WatchPolicy — which filesystem changes can never change what `git status` prints (M4.1).
//
// Shared by both repo watchers (WOR-306 S4): `FSEventsWatcher` (macOS) drops matching event paths
// before they reach `GitStatusService`, and `InotifyRepoWatcher` (Linux) drops them too and, since
// inotify watches are per directory and a kernel-wide budget, adds no watch at all below a
// directory whose every entry would be dropped.
//
// The ignore list is not an optimisation, it is a correctness requirement. `.git/objects` churns
// on every fetch and every commit with hundreds of events, `node_modules` churns on every install,
// and `index.lock` is written by *our own* refresh — without dropping it a refresh would schedule
// the next refresh and the repo would never go quiet.

import Foundation

public enum WatchPolicy {
    /// Paths whose changes must never trigger a refresh.
    ///
    /// `index.lock` is matched by basename rather than by the literal `.git/index.lock`, because a
    /// linked worktree's index lives at `<main>/.git/worktrees/<name>/index.lock` and that spelling
    /// would slip through — and it is exactly our own refresh that writes it.
    public static func isIgnored(_ path: String) -> Bool {
        if path.contains("/.git/objects/") { return true }
        if (path as NSString).lastPathComponent == "index.lock" { return true }
        for directory in ignoredDirectories {
            if path.contains("/\(directory)/") || path.hasSuffix("/\(directory)") { return true }
        }
        return false
    }

    /// A directory everything below which `isIgnored`: `.git/objects`, `node_modules`, `.build`…
    /// The Linux watcher neither watches nor descends into one.
    public static func isPruned(directory path: String) -> Bool {
        isIgnored(path.hasSuffix("/") ? path : path + "/")
    }

    /// Directory names whose contents cannot change what `git status` prints.
    ///
    /// A session's working directory is watched recursively, so a build running *inside* a tkzmux
    /// session feeds this watcher thousands of events. Bounded by the 2 s per-session refresh floor
    /// that still meant two `git` subprocesses every two seconds for the whole build — over output
    /// that is ignored by the repo anyway, so the status could not have changed. The build was
    /// competing for CPU with the watcher watching it.
    ///
    /// Deliberately conservative: every name here is either dot-prefixed or unambiguous. `target/`
    /// and `build/` are **not** on the list — a repo can legitimately track a directory called
    /// either, and dropping real events is a correctness bug where keeping a few is only waste.
    static let ignoredDirectories = [
        "node_modules", ".build", ".venv", ".next", "__pycache__", "DerivedData",
    ]
}
