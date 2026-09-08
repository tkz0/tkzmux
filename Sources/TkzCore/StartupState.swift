// TkzCore — the state a fresh install starts from, and the path helper the launcher needs.
//
// `AppState.fixture` (FixtureState.swift) is 40 fabricated rows for previews, the sidebar tests and
// the perf harness. It is deliberately **not launchable**: its cwds are tilde-literal paths into
// repos that need not exist. Seeding the real window with it shows a full sidebar where every row
// opens nothing, which reads as a broken app rather than an empty one — so the app starts from
// `AppState.startup` and the fixture moves behind `TKZMUX_FIXTURE=1` (M2.5 / TKZ-43).

import Foundation

extension AppState {
    /// The state a window with no persisted `state.json` (M5.1) comes up in: one group for the
    /// user's home directory and nothing else.
    ///
    /// The group carries `repoRoot = homeDirectory` rather than the `nil` of a plain bucket, and
    /// that is load-bearing: `NewSessionMenu` disables every launch row when `group.repoRoot` is
    /// nil, so a bucket would make ⌘N open a menu of dead entries. Home is not a git repo, so
    /// *New worktree (claude -w)* is enabled but will fail when picked — real repo groups arrive
    /// with *In another repo…* (TKZ-30).
    public static func startup(homeDirectory: String, now: Date = Date()) -> AppState {
        var state = AppState()
        let name = (homeDirectory as NSString).lastPathComponent
        state.addGroup(name: name.isEmpty ? "Home" : name, repoRoot: homeDirectory)
        return state
    }
}

/// Filesystem path helpers. Pure, so they live in `TkzCore` next to the models that carry paths.
public enum Paths {

    /// Expands a leading `~` against `home`. Everything else is returned unchanged.
    ///
    /// The models keep paths **as written** (`Group.repoRoot`, `Session.cwd` and
    /// `NewSessionMenu.Launch.cwd` are all tilde-literal by design, and `state.json` persists them
    /// that way), so expansion happens once, at the boundary where a path becomes a `chdir`
    /// argument. `NSString.expandingTildeInPath` is not used: it reads the *process's* home, which
    /// a test must be able to override.
    public static func expandingTilde(_ path: String, home: String) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" { return home }
        guard path.hasPrefix("~/") else { return path }  // `~user` is not ours to resolve
        let rest = path.dropFirst(2)
        if rest.isEmpty { return home }
        return home.hasSuffix("/") ? home + rest : home + "/" + rest
    }
}
