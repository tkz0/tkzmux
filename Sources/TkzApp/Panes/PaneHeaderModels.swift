// The pane header's presentation model (design 2c.3 / 2c.4).
//
// Same shape as `TabStripModels` and `SidebarRowModels`: a value type with no `TkzCore` model
// inside it, so the view renders deterministically from data a test can construct, and the one
// place that knows both vocabularies (`PaneHeaderAdapter`) is a pure function over `AppState`.

import CoreGraphics
import Foundation
import TkzCore

public enum PaneHeaderMetrics {
    /// The artboard's 28 pt strip: dot · title · path · badge, a 1 pt border below.
    public static let height: CGFloat = 28
    public static let insetX: CGFloat = 12
    public static let gap: CGFloat = 8
    /// The header's dot is 6 pt, one smaller than the sidebar row's.
    public static let dotDiameter: CGFloat = 6
    /// The `×` at the header's right edge: a square hit box this wide, always drawn.
    public static let closeSize: CGFloat = 16
    /// The 1.5 pt inset ring around the focused pane.
    public static let focusRingWidth: CGFloat = 1.5
    /// The artboards draw the unfocused pane's terminal at 85 %.
    public static let inactiveContentAlpha: CGFloat = 0.85
}

public struct PaneHeaderModel: Hashable, Sendable {
    /// The last path segment of the pane's directory — the row-title rule, per pane.
    public var title: String
    /// The pane's directory, home abbreviated to `~`.
    public var path: String
    /// The row's status: every pane of a row shares its Claude session, so every header shows
    /// the same dot.
    public var status: SidebarStatus
    /// The row's `NEEDS YOU`, for the same reason.
    public var needsAttention: Bool
    /// Whether this pane has the keyboard. Drives the header's palette and the pane's ring.
    public var isFocused: Bool

    public init(
        title: String, path: String, status: SidebarStatus = .idle,
        needsAttention: Bool = false, isFocused: Bool = false
    ) {
        self.title = title
        self.path = path
        self.status = status
        self.needsAttention = needsAttention
        self.isFocused = isFocused
    }
}

// MARK: - Adapter

public enum PaneHeaderAdapter {
    /// The header for one pane, or nil when the terminal belongs to no session.
    ///
    /// The pane's own cwd (OSC 7) comes first; a pane that has not reported yet — a split in its
    /// first second — shows the row's `effectiveCwd`, which is what its shell is about to start
    /// in anyway. The pane running Claude shows Claude's cwd instead (`Session.paneDirectory`):
    /// after `claude -w` the shell's OSC 7 still names the main checkout, and the header would
    /// otherwise contradict the git strip beneath it.
    public static func model(
        for terminal: TerminalID, in state: AppState, home: String
    ) -> PaneHeaderModel? {
        guard let session = state.session(owning: terminal),
            let tab = session.tab(containing: terminal)
        else { return nil }
        let cwd = session.paneDirectory(terminal)
        return PaneHeaderModel(
            title: Session.title(forPath: cwd),
            path: abbreviatingHome(cwd, home: home),
            status: SidebarRowAdapter.status(of: session),
            needsAttention: session.needsAttention,
            isFocused: tab.focusedLeaf == terminal)
    }

    /// `/Users/x/dev/repo` → `~/dev/repo`; `/Users/x` → `~`; anything else unchanged. A trailing
    /// slash on either side is tolerated, and `/Users/xy` is not under `/Users/x`.
    public static func abbreviatingHome(_ path: String, home: String) -> String {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, home != "/" else { return path }
        if path == home || path == home + "/" { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
