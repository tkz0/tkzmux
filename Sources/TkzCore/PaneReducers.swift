// Pane and tab transitions (TKZ-36) — the `mutating` half of the split tree.
//
// Same contract as `Reducers.swift`: pure functions of `AppState`, no pty, no git, no Claude. A
// reducer that cannot do what it was asked (unknown id, an invariant it must not break) is a
// no-op, so a caller never has to check first.
//
// Two invariants are total, and everything else here leans on them:
//   * a session always has at least one tab;
//   * a tab always has at least one leaf.
// `closePane` and `closeTab` therefore *refuse* to empty a row and report it, which is how
// `SessionLauncher` learns that the row itself has to go.

import Foundation

extension AppState {

    // MARK: Finding a pane

    /// The session that owns a terminal. A linear scan over the rows — with a sidebar of tens of
    /// sessions that is nothing, and a reverse index would be a second truth for `diff` and every
    /// reducer here to keep in step.
    public func session(owning terminal: TerminalID) -> Session? {
        sessions.values.first { $0.terminalIDs.contains(terminal) }
    }

    public func sessionID(owning terminal: TerminalID) -> SessionID? {
        session(owning: terminal)?.id
    }

    /// The most panes one tab may hold. A bound so a stuck key cannot fork a thousand shells, not
    /// a considered policy — raise it freely.
    public static let maxPanesPerTab = 16

    // MARK: Splitting

    /// **Split** — replaces `terminal`'s leaf with a split of itself and a new, empty leaf, and
    /// focuses the new one. ⌘D (`.horizontal`, side by side) and ⇧⌘D (`.vertical`, stacked).
    ///
    /// Returns the new terminal's id, or nil when the id is unknown or the tab is already at
    /// `maxPanesPerTab`. The caller (`SessionLauncher.addPane`) then spawns a shell for it; the
    /// working directory it starts in is read from `live.paneCwds`, not from here — a reducer has
    /// no business knowing where a shell is standing.
    @discardableResult
    public mutating func splitPane(
        _ terminal: TerminalID,
        axis: PaneAxis,
        ratio: Double = 0.5,
        newID: TerminalID = .generate()
    ) -> TerminalID? {
        guard let sessionID = sessionID(owning: terminal),
            var session = sessions[sessionID],
            let tabIndex = session.tabs.firstIndex(where: { $0.root.contains(terminal) })
        else { return nil }
        guard session.tabs[tabIndex].terminalCount < Self.maxPanesPerTab else { return nil }

        guard session.tabs[tabIndex].root.split(terminal, axis: axis, ratio: ratio, newLeaf: newID)
        else { return nil }
        session.tabs[tabIndex].focusedLeaf = newID
        // Splitting a zoomed pane would otherwise be invisible: the new sibling exists but the
        // zoom still shows only one pane.
        session.tabs[tabIndex].zoomedLeaf = nil
        session.activeTab = session.tabs[tabIndex].id
        sessions[sessionID] = session
        return newID
    }

    // MARK: Closing

    /// **Close a pane.** Returns `false` — changing nothing — when `terminal` is the last leaf of
    /// the last tab of its session. That is not a failure: it is how the caller learns the row
    /// itself must go (`SessionLauncher.closeTerminal` falls through to `removeSession`), and it is
    /// what keeps "every session has a tab, every tab has a leaf" a total invariant rather than a
    /// case every reader has to handle.
    @discardableResult
    public mutating func closePane(_ terminal: TerminalID) -> Bool {
        guard let sessionID = sessionID(owning: terminal),
            var session = sessions[sessionID],
            let tabIndex = session.tabs.firstIndex(where: { $0.root.contains(terminal) })
        else { return false }

        if session.tabs[tabIndex].terminalCount == 1 {
            guard session.tabs.count > 1 else { return false }
            removeTab(at: tabIndex, in: &session)
            forgetPane(terminal, in: &session)
            sessions[sessionID] = session
            return true
        }

        guard let successor = session.tabs[tabIndex].root.closeLeaf(terminal) else { return false }
        if session.tabs[tabIndex].focusedLeaf == terminal {
            session.tabs[tabIndex].focusedLeaf = successor
        }
        if session.tabs[tabIndex].zoomedLeaf == terminal {
            session.tabs[tabIndex].zoomedLeaf = nil
        }
        forgetPane(terminal, in: &session)
        sessions[sessionID] = session
        return true
    }

    /// Drops everything the live state holds per pane. A launch waiting on this pane is over
    /// with it: the shell that was running the command is gone.
    private func forgetPane(_ terminal: TerminalID, in session: inout Session) {
        session.live?.panePids[terminal] = nil
        session.live?.paneCwds[terminal] = nil
        if session.live?.claudeStartup?.terminal == terminal {
            session.live?.claudeStartup = nil
        }
    }

    /// **Close a tab** and every pane in it. Refuses the last tab of a session, for the same
    /// reason and with the same meaning as `closePane`.
    @discardableResult
    public mutating func closeTab(_ tab: TabID) -> Bool {
        guard let sessionID = sessions.values.first(where: { $0.tabs.contains { $0.id == tab } })?.id,
            var session = sessions[sessionID],
            let index = session.tabs.firstIndex(where: { $0.id == tab }),
            session.tabs.count > 1
        else { return false }
        for terminal in session.tabs[index].terminalIDs {
            forgetPane(terminal, in: &session)
        }
        removeTab(at: index, in: &session)
        sessions[sessionID] = session
        return true
    }

    /// Drops a tab and moves `activeTab` to its successor, falling back to its predecessor at the
    /// end — the same rule `removeSession` uses for the sidebar, so the two feel alike.
    private func removeTab(at index: Int, in session: inout Session) {
        let wasActive = session.tabs[index].id == session.activeTab
        session.tabs.remove(at: index)
        guard wasActive else { return }
        session.activeTab = session.tabs[Swift.min(index, session.tabs.count - 1)].id
    }

    // MARK: Tabs

    /// **New tab** (⌘T) — one empty terminal, made active. Returns its id for the caller to spawn.
    @discardableResult
    public mutating func addTab(
        to sessionID: SessionID,
        id: TabID = .generate(),
        terminal: TerminalID = .generate()
    ) -> TerminalID? {
        guard var session = sessions[sessionID] else { return nil }
        session.tabs.append(Tab.single(terminal, tab: id))
        session.activeTab = id
        sessions[sessionID] = session
        return terminal
    }

    public mutating func selectTab(_ tab: TabID) {
        guard let sessionID = sessions.values.first(where: { $0.tabs.contains { $0.id == tab } })?.id
        else { return }
        sessions[sessionID]?.activeTab = tab
    }

    /// ⇧⌘] / ⇧⌘[. Wraps, like `selectAdjacentSession`: a tab strip is a flat list with no edges.
    public mutating func selectAdjacentTab(in sessionID: SessionID, offset: Int) {
        guard let session = sessions[sessionID], session.tabs.count > 1 else { return }
        let count = session.tabs.count
        let next = ((session.activeTabIndex + offset) % count + count) % count
        sessions[sessionID]?.activeTab = session.tabs[next].id
    }

    // MARK: Focus

    /// **Focus a pane** — a click, or a palette hit. Also makes its tab active, so "put the
    /// keyboard here" is one call whatever tab the pane is on.
    public mutating func focusPane(_ terminal: TerminalID) {
        guard let sessionID = sessionID(owning: terminal),
            var session = sessions[sessionID],
            let tabIndex = session.tabs.firstIndex(where: { $0.root.contains(terminal) })
        else { return }
        session.tabs[tabIndex].focusedLeaf = terminal
        session.activeTab = session.tabs[tabIndex].id
        sessions[sessionID] = session
    }

    /// **⌘⌥ arrows.** Geometric, over the ratios alone: the active tab is laid out in a unit
    /// rectangle and the nearest pane on that side wins.
    ///
    /// Ranking, in order: the smallest gap along the axis of travel; then the **largest
    /// perpendicular overlap** with the source pane; then the lowest edge, as a deterministic
    /// tie-break. Overlap before distance is what makes a 1-left / 2-right layout behave — both
    /// right panes reach the left one, and the left one reaches whichever right pane it shares
    /// more edge with.
    ///
    /// There is **no wrap**: an arrow at the edge does nothing. That is deliberately unlike
    /// `selectAdjacentSession`, which wraps because a flat list has no edges to speak of. Zoomed
    /// tabs are a no-op — there is only one pane on screen.
    @discardableResult
    public mutating func focusPaneInDirection(
        _ direction: PaneDirection, in sessionID: SessionID
    ) -> TerminalID? {
        guard let session = sessions[sessionID] else { return nil }
        let tab = session.activeTabValue
        guard tab.zoomedLeaf == nil else { return nil }

        let frames = tab.root.frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let source = frames[tab.focusedLeaf] else { return nil }

        let epsilon = 1e-9
        var best: (id: TerminalID, gap: Double, overlap: Double, edge: Double)?
        for (id, rect) in frames where id != tab.focusedLeaf {
            let gap: Double
            let overlap: Double
            switch direction {
            case .left:
                guard rect.maxX <= source.minX + epsilon else { continue }
                gap = source.minX - rect.maxX
                overlap = Self.overlap(source.minY, source.maxY, rect.minY, rect.maxY)
            case .right:
                guard rect.minX >= source.maxX - epsilon else { continue }
                gap = rect.minX - source.maxX
                overlap = Self.overlap(source.minY, source.maxY, rect.minY, rect.maxY)
            case .up:
                guard rect.minY >= source.maxY - epsilon else { continue }
                gap = rect.minY - source.maxY
                overlap = Self.overlap(source.minX, source.maxX, rect.minX, rect.maxX)
            case .down:
                guard rect.maxY <= source.minY + epsilon else { continue }
                gap = source.minY - rect.maxY
                overlap = Self.overlap(source.minX, source.maxX, rect.minX, rect.maxX)
            }
            guard overlap > epsilon else { continue }
            let edge = Double(direction.isHorizontal ? rect.minY : rect.minX)
            let candidate = (id: id, gap: Double(gap), overlap: Double(overlap), edge: edge)
            if let current = best {
                let better =
                    (candidate.gap, -candidate.overlap, candidate.edge)
                    < (current.gap, -current.overlap, current.edge)
                if better { best = candidate }
            } else {
                best = candidate
            }
        }

        guard let winner = best?.id else { return nil }
        focusPane(winner)
        return winner
    }

    private static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat)
        -> Double
    {
        Double(Swift.max(0, Swift.min(a1, b1) - Swift.max(a0, b0)))
    }

    // MARK: Ratios and zoom

    /// **Divider drag.** The split is named by "the parent of this pane" (`levels: 1` for its
    /// grandparent), so the view layer never needs a node id it would have to keep in step.
    public mutating func setRatio(above terminal: TerminalID, levels: Int = 0, to ratio: Double) {
        guard let sessionID = sessionID(owning: terminal),
            var session = sessions[sessionID],
            let tabIndex = session.tabs.firstIndex(where: { $0.root.contains(terminal) })
        else { return }
        guard session.tabs[tabIndex].root.setRatio(above: terminal, levels: levels, to: ratio)
        else { return }
        sessions[sessionID] = session
    }

    /// **⌃⌘=** — every pane in the tab ends the same size, at any nesting depth.
    public mutating func equalizeSplits(in sessionID: SessionID) {
        guard var session = sessions[sessionID] else { return }
        let index = session.activeTabIndex
        session.tabs[index].root.equalize()
        sessions[sessionID] = session
    }

    /// **⇧⌘↩** — toggles one pane filling the tab. Zooming also focuses, so the pane that grows is
    /// the one that gets the keyboard.
    public mutating func zoomPane(_ terminal: TerminalID? = nil, in sessionID: SessionID) {
        guard var session = sessions[sessionID] else { return }
        let index = session.activeTabIndex
        let target = terminal ?? session.tabs[index].focusedLeaf
        guard session.tabs[index].root.contains(target) else { return }
        if session.tabs[index].zoomedLeaf == target {
            session.tabs[index].zoomedLeaf = nil
        } else {
            session.tabs[index].zoomedLeaf = target
            session.tabs[index].focusedLeaf = target
        }
        sessions[sessionID] = session
    }

    // MARK: Per-pane live state

    /// OSC 7 from a pane's shell. Live state: it must **not** count as a layout change, or every
    /// `cd` would rebuild the split container (see `ChangeSet.diff`).
    public mutating func setPaneCwd(_ terminal: TerminalID, path: String?) {
        guard let sessionID = sessionID(owning: terminal) else { return }
        let trimmed = (path?.isEmpty ?? true) ? nil : path
        sessions[sessionID]?.live?.paneCwds[terminal] = trimmed
    }

    /// Records a pane's login-shell pid, so the port scanner and the hook relay's ppid fallback
    /// can see shells outside the focused pane.
    public mutating func setPanePid(_ terminal: TerminalID, pid: pid_t?) {
        guard let sessionID = sessionID(owning: terminal) else { return }
        sessions[sessionID]?.live?.panePids[terminal] = pid
    }

    /// The directory a pane is standing in, for "split here" and for a status line.
    public func paneCwd(_ terminal: TerminalID) -> String? {
        session(owning: terminal)?.live?.paneCwds[terminal]
    }
}

/// Which way ⌘⌥ moves the keyboard.
public enum PaneDirection: String, Hashable, Sendable, CaseIterable {
    case left, right, up, down

    /// True when travel is along x, which decides which axis the overlap tie-break measures.
    public var isHorizontal: Bool { self == .left || self == .right }
}
