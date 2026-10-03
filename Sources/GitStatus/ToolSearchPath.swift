// ToolSearchPath — where `gh` and git's credential helpers are looked for beyond `PATH` (WOR-306 S4).
//
// The `PATH` itself should be the login shell's (`UserPath.resolve()` in the app, passed in as
// `PRLookup(searchPath:)` and `GitRebase.Request.searchPath`): a desktop-launched process inherits
// the session manager's, which on Linux usually lacks `~/.local/bin` and every mise or nvm
// directory. These are the directories still searched after it, for when it is not passed or the
// probe failed. macOS keeps its Homebrew lists inline in `PRLookup` and `GitRebase`, unchanged.

enum ToolSearchPath {
    /// Linux: `~/.local/bin` (pipx, the official installers, a `PREFIX=~/.local` build), then the
    /// two system directories.
    static func fallbacks(home: String) -> [String] {
        [(home.hasSuffix("/") ? home : home + "/") + ".local/bin", "/usr/local/bin", "/usr/bin"]
    }
}
