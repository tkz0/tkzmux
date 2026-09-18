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
// Nothing here talks to the terminal,
// git or Claude: creating a `Session` is a model edit, launching its pty is `TerminalHost`'s job.

import Foundation

// MARK: - Sessions

extension AppState {
    /// Appends a session to a group. `order` is one past the group's current last row.
    ///
    /// A collapsed target group is **expanded**: every caller is a user asking for a new row, and a
    /// row nobody can see is worse than a group that reopened. It happens in the same mutation as
    /// the insert, so the sidebar gets one change set carrying both `structure` and `groups`.
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
        agent: AgentKind = .claude,
        accountKey: String? = nil,
        now: Date = Date()
    ) -> Session {
        let group = groups[groupID]
        // The group's default account only applies to a row of *its own* agent: the key names one
        // agent's config dir, and handing a Codex row `claude-work` would point `CODEX_HOME` at
        // Claude's. Any other agent falls back to its own primary. (A per-agent default map would
        // be a v5 lift; this keeps `Group.defaultAccountKey` a scalar.)
        let groupDefault = group?.defaultAccountKey
        let groupDefaultFits = groupDefault.map { accounts[$0]?.agent ?? .claude } == agent
        let session = Session(
            id: id,
            groupID: groupID,
            order: nextSessionOrder(in: groupID),
            title: title,
            cwd: cwd,
            repoRoot: repoRoot ?? group?.repoRoot,
            worktreePath: worktreePath,
            isWorktree: isWorktree,
            agent: agent,
            accountKey: accountKey
                ?? (groupDefaultFits ? groupDefault : nil)
                ?? Account.defaultKey(for: agent),
            createdAt: now,
            lastActiveAt: now
        )
        sessions[id] = session
        groups[groupID]?.isCollapsed = false
        return session
    }

    /// Binds a discovered agent observation to a session: the "adopt" half of
    /// the identity join. Creates `live` if the session had none, and
    /// refreshes `conversationId` (which rotates on `/clear`, resume and fork).
    ///
    /// Does nothing if the session is unknown.
    public mutating func adoptDescriptor(
        _ observation: AgentObservation,
        for id: SessionID,
        now: Date = Date()
    ) {
        guard var session = sessions[id] else { return }
        var live = session.live ?? LiveSessionState()
        live.pid = observation.pid
        live.observation = observation
        session.live = live
        session.conversationId = observation.conversationId
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

    /// The account a session actually runs on, as the shim's `launch` frame reports it — which can
    /// differ from what the launcher asked for when the user's environment picks another config
    /// dir (M5.2, GUI pass 2026-09-08). The chip and every later resume follow the truth.
    public mutating func setSessionAccount(_ id: SessionID, key: String) {
        guard !key.isEmpty, sessions[id]?.accountKey != key else { return }
        sessions[id]?.accountKey = key
    }

    /// The shell reported its working directory (OSC 7). Title-only: nothing is persisted.
    public mutating func setShellCwd(_ id: SessionID, path: String?) {
        guard sessions[id]?.live != nil else { return }
        updateLive(id) { $0.shellCwd = path?.isEmpty == true ? nil : path }
    }

    /// What `GitStatusService` (M4.1) learned for this row's directory. `nil` = not a repo.
    ///
    /// Only rows with live state take a summary: a restored row has no shell, no cwd being watched
    /// and nothing to show a branch for, and giving it one would make the status bar describe a
    /// directory nobody is standing in.
    public mutating func setGitSummary(_ summary: GitSummary?, for id: SessionID) {
        guard sessions[id]?.live != nil else { return }
        updateLive(id) { $0.git = summary }
    }

    /// The listening TCP ports of the row's process tree (M4.3), ascending, with the owning
    /// process name per port for the badge tooltip. The scanner sorts and dedupes; this stores what
    /// it is given, so an unchanged scan diffs as unchanged and costs no re-render.
    public mutating func setPorts(
        _ ports: [UInt16],
        owners: [UInt16: String] = [:],
        for id: SessionID
    ) {
        guard sessions[id]?.live != nil else { return }
        updateLive(id) {
            $0.ports = ports
            $0.portOwners = owners
        }
    }

    /// Records where a session's worktree is (or that it has none). `isWorktree` drives the `WT`
    /// badge; the path is kept even when the badge is cleared, for the error message.
    public mutating func setWorktree(_ id: SessionID, path: String?, isWorktree: Bool) {
        guard var session = sessions[id] else { return }
        session.worktreePath = path ?? session.worktreePath
        session.isWorktree = isWorktree
        sessions[id] = session
    }

    /// The worktree is gone from disk (Claude removed it on exit, or the user deleted it by hand):
    /// the `WT` badge comes off and a resume lands in the repo root. The path stays for the record.
    public mutating func clearWorktreeBadge(_ id: SessionID) {
        setWorktree(id, path: nil, isWorktree: false)
    }

    /// **Remove** — the only way a row leaves the sidebar (⌘W, the row's ×, a shell that ended;
    /// decision 2026-09-08: there is no "closed but kept" state). Never touches a worktree on disk.
    /// If the removed session was selected, selection moves to the next row in sidebar order (or
    /// the previous one at the end).
    public mutating func removeSession(_ id: SessionID) {
        guard let session = sessions[id] else { return }
        let ordered = orderedSessions
        let successor = successorOfSession(id, in: ordered)
        sessions[id] = nil
        normalizeSessionOrder(in: session.groupID)
        if selection == id { selection = successor }
        // A feed entry that can jump nowhere is dead.
        activity.removeAll { $0.sessionID == id }
    }

    /// Records that the user looked at a session — the `attendedAt` half of the NEEDS YOU rule.
    /// Re-derives afterwards, so a `doneUnattended` row the user just selected becomes `idle`
    /// (unless something else, e.g. a pending permission prompt, still needs them).
    ///
    /// `attention` and `isDone` are not reset by hand here: `rederiveStatus` recomputes both from
    /// `attendedAt`, and a prompt that is still pending re-raises `attention` anyway. Resetting
    /// first would make every re-select of such a row look like a fresh flip into NEEDS YOU to the
    /// activity feed, which appends on exactly that transition.
    public mutating func markAttended(_ id: SessionID, now: Date = Date()) {
        guard var session = sessions[id] else { return }
        session.lastActiveAt = now
        session.live?.attendedAt = now
        // The prompt's own words are answered with the prompt: a later descriptor-only flip must
        // fall back to the generic text, not repeat a line about a tool that is long done.
        session.live?.lastNotificationMessage = nil
        sessions[id] = session
        rederiveStatus(for: id, now: now)
        markActivityRead(id)
    }

    // MARK: Activity feed

    /// The row was looked at: every feed entry of its thread is read.
    public mutating func markActivityRead(_ id: SessionID) {
        for index in activity.indices where activity[index].sessionID == id && activity[index].unread {
            activity[index].unread = false
        }
    }

    /// *Mark as unread* on the feed: the row's whole thread is bold again. A no-op for a row with
    /// no entries.
    public mutating func markActivityUnread(_ id: SessionID) {
        for index in activity.indices
        where activity[index].sessionID == id && activity[index].kind.isActionable && !activity[index].unread {
            activity[index].unread = true
        }
    }

    /// Appends one feed entry for `id`, naming the row and its group as they are now, and drops
    /// the oldest past `activityCap`. An entry's `unread` starts as its kind's `isActionable`.
    mutating func appendActivity(_ kind: ActivityEvent.Kind, for id: SessionID, now: Date) {
        guard let session = sessions[id] else { return }
        activity.append(
            ActivityEvent(
                sessionID: id, kind: kind, at: now,
                sessionTitle: session.displayTitle,
                groupName: groups[session.groupID]?.name ?? "",
                unread: kind.isActionable))
        if activity.count > Self.activityCap {
            activity.removeFirst(activity.count - Self.activityCap)
        }
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

    /// Attaches (or clears) a group's repo. `nil` turns a repo group back into a bucket.
    public mutating func setGroupRepoRoot(_ id: GroupID, path: String?) {
        groups[id]?.repoRoot = path
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

    public mutating func setAutoResumeOnLaunch(_ enabled: Bool) {
        autoResumeOnLaunch = enabled
    }

    /// The periodic base-branch fetch (2026-09-13). Nothing else in the state depends on it: the
    /// timer that reads it lives in `GitIntegration`, which observes `ChangeSet.chrome`.
    public mutating func setCheckOriginPeriodically(_ enabled: Bool) {
        checkOriginPeriodically = enabled
    }

    /// The "Claude finished" notification switch (2026-09-15). Nothing in the state depends on it:
    /// the observer that reads it lives in `AttentionNotifier`, which watches `ChangeSet.chrome`.
    public mutating func setNotifyOnDone(_ enabled: Bool) {
        notifyOnDone = enabled
    }

    /// The global on/off for token usage/spend (design: enable/disable, all sessions). Turning it
    /// off clears every session's already-summed `live.usage` right away, rather than leaving a
    /// stale figure on screen until the next hook fires; turning it back on needs a fresh read,
    /// which the reducer cannot itself trigger (`ClaudeIntegration.refreshAllUsage()` is the
    /// caller's job after this returns).
    public mutating func setShowSessionSpend(_ enabled: Bool) {
        showSessionSpend = enabled
        guard !enabled else { return }
        // Only a session that already has live state *and* an already-summed figure: `updateLive`
        // creates live state for a session that has none, and a restored-but-never-shown row
        // (no `live` at all — see `Session.status`) must not be woken into existence just because
        // the global switch flipped off.
        for id in sessions.keys where sessions[id]?.live?.usage != nil {
            updateLive(id) { $0.usage = nil }
        }
    }

    /// One session's own opt-out, alongside the global switch (design: enable/disable, per
    /// session). Same immediate-clear rule as `setShowSessionSpend(_:)` — including the same
    /// "only if there is live state to clear" guard — and the same "the caller re-triggers a read
    /// to turn it back on" split.
    public mutating func setSpendTrackingDisabled(_ id: SessionID, _ disabled: Bool) {
        guard sessions[id] != nil else { return }
        sessions[id]?.spendTrackingDisabled = disabled ? true : nil
        if disabled, sessions[id]?.live?.usage != nil {
            updateLive(id) { $0.usage = nil }
        }
    }

    /// One session's mute: no macOS notifications for it, badge and tint untouched.
    /// `nil` when unmuted, not `false` — the one value a file written before this field existed
    /// can decode to.
    public mutating func setNotificationsMuted(_ id: SessionID, _ muted: Bool) {
        guard sessions[id] != nil else { return }
        sessions[id]?.notificationsMuted = muted ? true : nil
    }

    public mutating func setStatuslineOffered(_ offered: Bool) {
        statuslineOffered = offered
    }

    public mutating func setCodexHooksOffered(_ offered: Bool) {
        codexHooksOffered = offered
    }

    public mutating func setThemePreset(_ preset: Theme.Preset) {
        themePreset = preset
    }

    /// Flips to the preset's light/dark counterpart. The pairing is `Theme.toggled`, so nothing
    /// outside `Theme.swift` names a preset.
    public mutating func toggleTheme() {
        themePreset = Theme.toggled(themePreset)
    }

    // MARK: Update card

    /// What the release check found: a newer release, or `nil` when the running build is current
    /// (a withdrawn release clears the card). A failed check calls nothing.
    public mutating func setAvailableUpdate(_ available: AvailableUpdate?) {
        update.available = available
    }

    public mutating func setUpgradePhase(_ phase: UpgradePhase) {
        update.phase = phase
    }

    public mutating func setCanUpgradeInPlace(_ can: Bool) {
        update.canUpgradeInPlace = can
    }

    /// The card's `✕`: this version is never offered again. A later release is a new card.
    public mutating func dismissUpdate(version: String) {
        dismissedUpdateVersion = version
    }

    // MARK: Accounts, usage

    public mutating func setAccount(_ account: Account) {
        accounts[account.key] = account
    }

    /// Publishes a usage snapshot, and takes the plan and the *fallback* name it carries.
    ///
    /// `dash-usage-<key>.json` names its account and plan, which is worth having: an account nobody
    /// has named reads better as its usage file's name than as `claude-alt`. But that name is
    /// **generated**, so it must not overwrite one a human wrote in `dash-accounts.json` — hence
    /// the `label == key` guard, which is precisely "this account still has no name of its own"
    /// (`ClaudeIntegration.accountLabels` is the configured source).
    ///
    /// Relabels an account the state already knows; never invents one. Discovery is
    /// `ClaudeIntegration`'s job, and a usage file for a config dir that is not there is not
    /// evidence that it is.
    public mutating func setUsage(_ snapshot: UsageSnapshot) {
        usage[snapshot.accountKey] = snapshot
        guard var account = accounts[snapshot.accountKey] else { return }
        if account.label == account.key, let label = snapshot.label, !label.isEmpty {
            account.label = label
        }
        if let plan = snapshot.plan, !plan.isEmpty { account.plan = plan }
        accounts[snapshot.accountKey] = account
    }

    /// Drops an account's quota entirely: its sidecar was deleted, aged into a ghost, or every
    /// window in it has expired. Holding the last known percentage instead would be worse than the
    /// empty badge — a stale quota reading looks exactly like a current one.
    public mutating func clearUsage(for accountKey: String) {
        usage[accountKey] = nil
    }

    /// The per-session statusline sidecar (context %, model, PR), joined on Claude's own session id
    /// rather than on ours: the sidecar is written by a statusline that knows nothing about tkzmux
    /// rows. A session that has since been resumed under a new conversation id simply stops matching.
    ///
    /// `agent` narrows the join alongside the id: `conversationId` is an opaque token minted by
    /// whichever agent produced it, so nothing stops a Codex id and a Claude id from colliding by
    /// chance. Both agents' rows share this one `Session` table and nothing else, so the id alone is
    /// not enough to say which row a sidecar belongs to.
    public mutating func setSessionSidecar(_ sidecar: SessionSidecar, agent: AgentKind = .claude) {
        guard let id = sessions.values
            .first(where: { $0.agent == agent && $0.conversationId == sidecar.sessionId })?.id
        else { return }
        updateLive(id) { $0.context = sidecar }
    }

    /// See ``setSessionSidecar(_:agent:)`` — same cross-agent id collision risk, so the same filter.
    public mutating func clearSessionSidecar(conversationId: String, agent: AgentKind = .claude) {
        guard let id = sessions.values
            .first(where: { $0.agent == agent && $0.live?.context?.sessionId == conversationId })?.id
        else { return }
        updateLive(id) { $0.context = nil }
    }

    /// What `TranscriptUsageReader` (ClaudeBridge) summed off a session's transcript, joined on
    /// Claude's own session id — same reasoning as ``setSessionSidecar(_:agent:)``: the reader knows
    /// nothing about tkzmux rows, only about a Claude session id and its transcript, and the id is
    /// opaque per agent so the join needs `agent` too.
    public mutating func setSessionUsage(_ usage: SessionUsage, conversationId: String, agent: AgentKind = .claude) {
        guard let id = sessions.values
            .first(where: { $0.agent == agent && $0.conversationId == conversationId })?.id
        else { return }
        updateLive(id) { $0.usage = usage }
    }
}

// MARK: - Status: hooks, descriptors, liveness

extension AppState {
    /// Folds one already-translated agent event into a session's live state, then re-derives its
    /// status. What each kind clears/sets is exactly the table below; the wire-level decisions
    /// (which notification types exist, which ending reasons are an exit) belong to the adapter
    /// that produced the event, not here — see `AgentEvent`.
    public mutating func applyEvent(_ event: AgentEvent, to id: SessionID, now: Date = Date()) {
        guard let session = sessions[id] else { return }
        let wasEnded = session.live?.ended ?? false
        updateLive(id) { live in
            live.lastEvent = event
            switch event.kind {
            case .sessionStart:
                live.ended = false
                live.pendingNotification = nil
                // The agent is up: whatever launch this row was waiting on has arrived.
                live.agentStartup = nil
            case .sessionEnd(let exited):
                live.ended = exited
                live.pendingNotification = nil
            case .promptSubmitted:
                live.lastPromptAt = now
                live.attendedAt = now
                live.pendingNotification = nil
            case .turnEnded:
                live.lastStopAt = now
                if let message = event.lastAssistantMessage {
                    live.lastStopMessage = message
                }
                live.pendingNotification = nil
            case .attention(let kind):
                live.pendingNotification = PendingNotification(kind: kind, receivedAt: now)
                // Claude's own line for the banner ("Claude needs your permission to use Bash").
                // Only the three prompts that become NEEDS YOU keep it.
                if kind.waitReason != nil, let message = event.message, !message.isEmpty {
                    live.lastNotificationMessage = message
                }
            case .attentionCleared:
                live.pendingNotification = nil
                live.lastNotificationMessage = nil
            case .unknown:
                break
            }
        }
        if event.kind == .sessionStart, let conversationId = event.conversationId {
            sessions[id]?.conversationId = conversationId
        }
        // The feed: a finished turn, an exit (once — a `sessionEnd(exited: false)` is not one, and
        // a second exit on an already-ended row says nothing new), and typing a prompt as proof the
        // user is looking at the row. NEEDS YOU entries come from `rederiveStatus` below, which
        // also sees the flips no event announces.
        switch event.kind {
        case .turnEnded:
            appendActivity(
                .stop(message: ActivityEvent.storedMessage(event.lastAssistantMessage ?? "")),
                for: id, now: now)
        case .sessionEnd:
            if !wasEnded, sessions[id]?.live?.ended == true {
                appendActivity(.sessionEnded(reason: event.reason), for: id, now: now)
            }
        case .promptSubmitted:
            markActivityRead(id)
        case .sessionStart, .attention, .attentionCleared, .unknown:
            break
        }
        rederiveStatus(for: id, now: now)
    }

    /// Binds a discovered observation and its liveness together — the M3.4 successor to
    /// `adoptDescriptor`, which callers that only have the observation (no liveness signal yet)
    /// may keep using.
    public mutating func applyObservation(
        _ observation: AgentObservation, alive: Bool, to id: SessionID, now: Date = Date()
    ) {
        guard var session = sessions[id] else { return }
        var live = session.live ?? LiveSessionState()
        let rebound = live.observation?.conversationId != observation.conversationId
            || live.observation?.pid != observation.pid
        live.pid = observation.pid
        live.observation = observation
        live.alive = alive
        // A *live* observation bound to this row means the agent is running in it — the launch is
        // over, whether or not a `sessionStart` event got here first. A dead one is no such
        // evidence: a stale `sessions/<pid>.json` from before a crash matches a resumed row by
        // its conversation id, and must not take the overlay down before the new agent is up.
        if alive {
            live.agentStartup = nil
        }
        if rebound {
            live.ended = false
        }
        if observation.activity == .busy,
            let statusUpdatedAt = observation.statusUpdatedAt,
            let pendingAt = live.pendingNotification?.receivedAt,
            statusUpdatedAt > pendingAt
        {
            live.pendingNotification = nil
        }
        session.live = live
        session.conversationId = observation.conversationId
        session.lastActiveAt = now
        // `claude -w` starts Claude *inside* the worktree it just created, so the observation's
        // cwd is the first thing that says where it went.
        if let cwd = observation.cwd, !cwd.isEmpty {
            // Where the agent runs is where `--resume` must run, and what the row is named after
            // even before the next observation binds — so it becomes the session's directory of
            // record.
            session.cwd = cwd
            if let worktree = session.worktreeRoot(ofPath: cwd) {
                session.worktreePath = worktree
                session.isWorktree = true
            }
        }
        sessions[id] = session
        rederiveStatus(for: id, now: now)
    }

    /// The observation is gone (the agent's own process exited, or the discovery watcher lost its
    /// descriptor file), but the pty/shell underneath may still be there — `alive` stays `true`.
    public mutating func agentLost(for id: SessionID, now: Date = Date()) {
        guard sessions[id]?.live != nil else { return }
        updateLive(id) { live in
            live.observation = nil
            live.pid = nil
            live.alive = true
            live.agentTerminal = nil
        }
        rederiveStatus(for: id, now: now)
    }

    /// Which pane's shell is running the bound agent process, from the shim's `launch` frame
    /// (`ClaudeIntegration.bind`). `nil` when the frame could not be placed in a pane.
    public mutating func setAgentTerminal(_ id: SessionID, _ terminal: TerminalID?) {
        guard sessions[id]?.live != nil else { return }
        updateLive(id) { $0.agentTerminal = terminal }
    }

    /// Sets whether the process behind this session (the `claude` process when bound, else the
    /// shell) is running.
    public mutating func setAlive(_ alive: Bool, for id: SessionID, now: Date = Date()) {
        guard sessions[id] != nil else { return }
        updateLive(id) { $0.alive = alive }
        rederiveStatus(for: id, now: now)
    }

    // MARK: Agent startup

    /// A boot command was handed to `terminal`'s shell: the row is now waiting on the agent to
    /// come up there. `SessionLauncher.start`/`reopen(bootCommand:)` are the callers.
    public mutating func beginAgentStartup(
        _ id: SessionID, terminal: TerminalID, command: String, now: Date = Date()
    ) {
        guard sessions[id]?.live != nil else { return }
        updateLive(id) {
            $0.agentStartup = AgentStartup(terminal: terminal, command: command, startedAt: now)
        }
    }

    /// The launch is over — the agent is up, the command returned, or the edge gave up waiting.
    /// A no-op when nothing was pending, so it never costs a `sessions` delivery.
    public mutating func endAgentStartup(_ id: SessionID) {
        guard sessions[id]?.live?.agentStartup != nil else { return }
        updateLive(id) { $0.agentStartup = nil }
    }

    /// Re-derives one session's status/attention/isDone from its current live state.
    ///
    /// Also where the activity feed learns that a row started needing the user: attention is
    /// raised here from every path — a `Notification` hook, a descriptor-only `waiting`, the 5 s
    /// tick that ages an unattended Stop, `setAlive` — so this is the one place that sees them all.
    /// An entry is appended on the flip *into* attention, and when the reason changes while it is
    /// up (an unattended Stop answered by a permission prompt on resume).
    public mutating func rederiveStatus(for id: SessionID, now: Date = Date()) {
        guard let live = sessions[id]?.live else { return }
        let outcome = StatusDerivation.derive(live, now: now)
        guard live.status != outcome.status || live.attention != outcome.attention
            || live.isDone != outcome.isDone
        else { return }
        sessions[id]?.live?.status = outcome.status
        sessions[id]?.live?.attention = outcome.attention
        sessions[id]?.live?.isDone = outcome.isDone
        if outcome.attention, !live.attention || live.status != outcome.status,
            case .waiting(let reason) = outcome.status
        {
            let message: String? =
                switch reason {
                case .doneUnattended: live.lastStopMessage
                default: live.lastNotificationMessage
                }
            appendActivity(
                .needsYou(reason: reason, message: message.map(ActivityEvent.storedMessage)),
                for: id, now: now)
        }
    }

    /// The periodic tick for the 60 s "done → NEEDS YOU" rule. Touches only the sessions whose
    /// derived outcome actually changed, so a quiet sidebar costs nothing in `ChangeSet` terms.
    public mutating func rederiveStatuses(now: Date = Date()) {
        for id in sessions.keys where sessions[id]?.live != nil {
            rederiveStatus(for: id, now: now)
        }
    }
}
