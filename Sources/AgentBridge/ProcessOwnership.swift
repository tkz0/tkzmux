// ProcessOwnership — "is this pid one of ours?" for the descriptor join.
//
// `~/.claude/sessions/<pid>.json` is global: every running tkzmux sees every Claude's descriptor,
// including those started in another tkzmux's panes. The `launch` frame binds our own Claudes by
// pid, but the two fallbacks in `ClaudeIntegration.sessionID(forDescriptor:)` — the conversation
// id and the parent-pid walk — cannot tell a foreign Claude from ours by themselves: two instances
// restore the same `conversationId`s from one `state.json`, and a dev build started from a pane
// is itself a descendant of that pane, so a walk from *its* Claude climbs straight through it into
// the outer instance's row.
//
// The rule: a pid is ours when walking its parents reaches this process before reaching launchd —
// and before passing through another process with our executable name, which is the dev build
// sitting in a pane. Every pty child of this app is a direct child of the app, so for anything a
// pane actually runs the walk is two or three steps.

import Darwin

/// Parent and name lookups for the ownership walk, injected so it can be driven without real
/// processes — the same seam `ClaudeSessionWatcher` has in `ProcessLiveness`.
public protocol ProcessAncestry: Sendable {
    func parent(of pid: pid_t) -> pid_t?
    func name(of pid: pid_t) -> String?
}

/// The `libproc`-backed implementation.
public struct SystemProcessAncestry: ProcessAncestry {
    public init() {}
    public func parent(of pid: pid_t) -> pid_t? { ProcessTree.parent(of: pid) }
    public func name(of pid: pid_t) -> String? { ProcessTree.name(of: pid) }
}

public enum ProcessOwnership {
    /// Deeper than the join's own 8-level walks: a nested shell or two under a pane is normal,
    /// and a false "not ours" is worse than a few extra `proc_pidinfo` calls.
    public static let maxDepth = 16

    /// Whether `pid` runs under the process `selfPid`.
    ///
    /// Walks parents from `pid` inclusive. `selfPid` → `true`. Launchd (pid ≤ 1), a failed
    /// lookup, a self-parented pid, the depth limit, or a process named `selfName` that is not
    /// `selfPid` (another tkzmux between us and the pid) → `false`. The self-pid test comes first
    /// so this process never reads as a foreign one. An empty `selfName` disables only the name
    /// test.
    public static func owns(
        _ pid: pid_t, selfPid: pid_t, selfName: String, ancestry: any ProcessAncestry,
        maxDepth: Int = ProcessOwnership.maxDepth
    ) -> Bool {
        var current = pid
        for _ in 0..<maxDepth {
            if current == selfPid { return true }
            guard current > 1 else { return false }
            if !selfName.isEmpty, ancestry.name(of: current) == selfName { return false }
            guard let parent = ancestry.parent(of: current), parent != current else { return false }
            current = parent
        }
        return false
    }
}
