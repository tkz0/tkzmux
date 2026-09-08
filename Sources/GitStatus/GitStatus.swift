// GitStatus — the module's git, PR and port services. See docs/design.md → *Git integration*.
//
// `GitProcess` (the one subprocess runner), `RepoInfo`, `GitStatusParsing`, `FSEventsWatcher` and
// `GitStatusService` are M4.1 (TKZ-26); `PRLookup` is the lookup half of M4.2 (TKZ-27);
// `PortScanner` is M4.3 (TKZ-28); `WorktreeList` came earlier, with M5.2 (TKZ-30).
//
// Nothing here knows what a `Session` is beyond its id: attribution to rows, the store and the
// status bar all live in `TkzApp/GitIntegration.swift`.

/// Module marker, kept because the smoke test names it — and because it is the one symbol that can
/// prove the module linked at all.
public enum GitStatusModule {
    public static let name = "GitStatus"
}
