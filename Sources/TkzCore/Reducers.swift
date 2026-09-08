// TkzCore — the pure reducers. Every state transition the app performs is a `mutating` method on
// `AppState`, so it can be tested without a store, a window or a pty:
//
//     var state = AppState.fixture
//     state.renameSession(id, title: "review")
//
// and through the store, which turns it into a `ChangeSet`:
//
//     store.update { $0.renameSession(id, title: "review") }
//
// Flows are in docs/design.md → *Session flows & persistence*. Nothing here talks to the terminal,
// git or Claude: creating a `Session` is a model edit, launching its pty is `TerminalHost`'s job.

import Foundation

// MARK: - Sessions

extension AppState {
    /// Appends a session to a group. `order` is one past the group's current last row.
    /// - Returns: the session as inserted (with its assigned `order`).
    @discardableResult
    public mutating func createSession(
        id: SessionID = .generate(),
        groupID: GroupID,
        cwd: String,
        title: String? = nil,
        repoRoot: String? = nil,
        worktreePath: String? = nil,
        isWorktree: Bool = false,
        accountKey: String? = nil,
        presetID: UUID? = nil,
        now: Date = Date()
    ) -> Session {
        let group = groups[groupID]
        let session = Session(
            id: id,
            groupID: groupID,
            order: nextSessionOrder(in: groupID),
            title: title,
            cwd: cwd,
            repoRoot: repoRoot ?? group?.repoRoot,
            worktreePath: worktreePath,
            isWorktree: isWorktree,
            accountKey: accountKey ?? group?.defaultAccountKey ?? Account.defaultKey,
            presetID: presetID,
            createdAt: now,
            lastActiveAt: now
        )
        sessions[id] = session
        return session
    }

    /// Binds a discovered Claude descriptor to a session: the "adopt" half of
    /// design.md → *Claude integration → Identity*. Creates `live` if the session had none, and
    /// refreshes `claudeSessionId` (which rotates on `/clear`, resume and fork).
    ///
    /// Does nothing if the session is unknown.
    public mutating func adoptDescriptor(
        _ descriptor: ClaudeSessionInfo,
        for id: SessionID,
        now: Date = Date()
    ) {
        guard var session = sessions[id] else { return }
        var live = session.live ?? LiveSessionState()
        live.pid = descriptor.pid
        live.descriptor = descriptor
        session.live = live
        session.claudeSessionId = descriptor.sessionId
        session.lastActiveAt = now
        sessions[id] = session
    }

    /// Replaces a session's live state (or clears it). The single entry point services use, so
    /// that "does this change the row?" stays one value comparison.
    public mutating func setLive(_ live: LiveSessionState?, for id: SessionID) {
        guard var session = sessions[id] else { return }
        session.live = live
        sessions[id] = session
    }

    /// Mutates a session's live state in place, creating it if the session is running but had none.
    public mutating func updateLive(_ id: SessionID, _ mutate: (inout LiveSessionState) -> Void) {
        guard var session = sessions[id] else { return }
        var live = session.live ?? LiveSessionState()
        mutate(&live)
        session.live = live
        sessions[id] = session
    }

    /// Sets the status dot. `attention` defaults to "amber badge iff the session is waiting to be
    /// picked up unattended" — callers that know better pass it explicitly.
    public mutating func setStatus(
        _ status: SessionStatus,
        for id: SessionID,
        attention: Bool? = nil
    ) {
        updateLive(id) { live in
            live.status = status
            live.attention = attention ?? (status == .waiting(.doneUnattended))
        }
    }

    /// A user rename. Empty or whitespace-only clears it back to the derived title.
    public mutating func renameSession(_ id: SessionID, title: String?) {
        guard var session = sessions[id] else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        session.title = (trimmed?.isEmpty ?? true) ? nil : trimmed
        sessions[id] = session
    }

    /// Moves a session within or between groups and renumbers both groups' rows.
    /// `index` is the destination row within the target group; `nil` appends.
    public mutating func moveSession(_ id: SessionID, toGroup groupID: GroupID, at index: Int? = nil) {
        guard var session = sessions[id], groups[groupID] != nil else { return }
        let sourceGroup = session.groupID
        var target = sessions(in: groupID).filter { $0.id != id }
        let clamped = min(max(index ?? target.count, 0), target.count)
        session.groupID = groupID
        target.insert(session, at: clamped)
        for (offset, item) in target.enumerated() {
            var moved = item
            moved.order = offset
            sessions[moved.id] = moved
        }
        if sourceGroup != groupID { normalizeSessionOrder(in: sourceGroup) }
    }

    /// Reorders a session inside its own group.
    public mutating func reorderSession(_ id: SessionID, to index: Int) {
        guard let session = sessions[id] else { return }
        moveSession(id, toGroup: session.groupID, at: index)
    }

    /// **Close**: the process is gone, the row stays and is resumable. Clearing `live` is what
    /// makes `Session.status` report `.exited` (see `Session`).
    public mutating func closeSession(_ id: SessionID, now: Date = Date()) {
        guard var session = sessions[id] else { return }
        session.live = nil
        session.lastActiveAt = now
        sessions[id] = session
    }

    /// **Remove**: the row goes away. Never touches a worktree on disk. If the removed session was
    /// selected, selection moves to the next row in sidebar order (or the previous one at the end).
    public mutating func removeSession(_ id: SessionID) {
        guard let session = sessions[id] else { return }
        let ordered = orderedSessions
        let successor = successorOfSession(id, in: ordered)
        sessions[id] = nil
        normalizeSessionOrder(in: session.groupID)
        if selection == id { selection = successor }
    }

    /// Records that the user looked at a session — the `attendedAt` half of the NEEDS YOU rule.
    public mutating func markAttended(_ id: SessionID, now: Date = Date()) {
        guard var session = sessions[id] else { return }
        session.lastActiveAt = now
        session.live?.attention = false
        sessions[id] = session
    }

    /// Next `order` value for a group.
    public func nextSessionOrder(in groupID: GroupID) -> Int {
        (sessions.values.filter { $0.groupID == groupID }.map(\.order).max() ?? -1) + 1
    }

    /// Renumbers one group's sessions 0…n-1 in their current order.
    public mutating func normalizeSessionOrder(in groupID: GroupID) {
        for (offset, session) in sessions(in: groupID).enumerated() where session.order != offset {
            sessions[session.id]?.order = offset
        }
    }

    private func successorOfSession(_ id: SessionID, in ordered: [Session]) -> SessionID? {
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < ordered.count { return ordered[index + 1].id }
        if index > 0 { return ordered[index - 1].id }
        return nil
    }
}

// MARK: - Groups

extension AppState {
    /// Appends a group. `repoRoot` is what makes it a repo group rather than a bucket.
    @discardableResult
    public mutating func addGroup(
        id: GroupID = .generate(),
        name: String,
        repoRoot: String? = nil,
        color: RGB? = nil,
        defaultAccountKey: String? = nil
    ) -> Group {
        let group = Group(
            id: id,
            name: name,
            repoRoot: repoRoot,
            color: color,
            isCollapsed: false,
            order: (groups.values.map(\.order).max() ?? -1) + 1,
            defaultAccountKey: defaultAccountKey
        )
        groups[id] = group
        return group
    }

    public mutating func renameGroup(_ id: GroupID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups[id]?.name = trimmed
    }

    public mutating func setGroupColor(_ id: GroupID, color: RGB?) {
        groups[id]?.color = color
    }

    public mutating func setGroupDefaultAccount(_ id: GroupID, accountKey: String?) {
        groups[id]?.defaultAccountKey = accountKey
    }

    /// Collapse state is a group change, never a structural one.
    public mutating func setGroupCollapsed(_ id: GroupID, _ collapsed: Bool) {
        groups[id]?.isCollapsed = collapsed
    }

    public mutating func toggleGroupCollapsed(_ id: GroupID) {
        guard let collapsed = groups[id]?.isCollapsed else { return }
        groups[id]?.isCollapsed = !collapsed
    }

    /// Moves a group to a row index and renumbers all groups.
    public mutating func moveGroup(_ id: GroupID, to index: Int) {
        guard groups[id] != nil else { return }
        var ordered = orderedGroups.filter { $0.id != id }
        let clamped = min(max(index, 0), ordered.count)
        ordered.insert(groups[id]!, at: clamped)
        for (offset, group) in ordered.enumerated() where groups[group.id]?.order != offset {
            groups[group.id]?.order = offset
        }
    }

    /// Removes a group. Its sessions move to `reassignTo` (keeping their rows) or are removed with
    /// it. Never touches anything on disk.
    public mutating func removeGroup(_ id: GroupID, reassignTo destination: GroupID? = nil) {
        guard groups[id] != nil else { return }
        let members = sessions(in: id)
        if let destination, groups[destination] != nil {
            for session in members { moveSession(session.id, toGroup: destination) }
        } else {
            for session in members { removeSession(session.id) }
        }
        groups[id] = nil
        normalizeGroupOrder()
    }

    /// Renumbers groups 0…n-1 in their current order.
    public mutating func normalizeGroupOrder() {
        for (offset, group) in orderedGroups.enumerated() where group.order != offset {
            groups[group.id]?.order = offset
        }
    }

    /// The group whose `repoRoot` matches, used when adopting a session discovered elsewhere.
    public func group(forRepoRoot repoRoot: String) -> Group? {
        orderedGroups.first { $0.repoRoot == repoRoot }
    }
}

// MARK: - Selection & chrome

extension AppState {
    /// Selects a session (or nothing). Selecting an unknown id clears the selection rather than
    /// leaving a dangling one.
    public mutating func select(_ id: SessionID?, now: Date = Date()) {
        guard let id, sessions[id] != nil else {
            selection = nil
            return
        }
        selection = id
        markAttended(id, now: now)
    }

    /// ⌥⌘↓ / ⌥⌘↑ — walks the flat sidebar order, wrapping.
    public mutating func selectAdjacentSession(offset: Int) {
        let ordered = orderedSessions
        guard !ordered.isEmpty else { return }
        guard let current = selection, let index = ordered.firstIndex(where: { $0.id == current })
        else {
            select(ordered[0].id)
            return
        }
        let next = ((index + offset) % ordered.count + ordered.count) % ordered.count
        select(ordered[next].id)
    }

    public mutating func setSidebarVisible(_ visible: Bool) {
        sidebarVisible = visible
    }

    // MARK: Accounts, usage, presets

    public mutating func setAccount(_ account: Account) {
        accounts[account.key] = account
    }

    public mutating func setUsage(_ snapshot: UsageSnapshot) {
        usage[snapshot.accountKey] = snapshot
    }

    @discardableResult
    public mutating func addPreset(_ preset: Preset) -> Preset {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        return preset
    }

    public mutating func removePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
    }

    public func preset(_ id: UUID) -> Preset? {
        presets.first { $0.id == id }
    }
}
