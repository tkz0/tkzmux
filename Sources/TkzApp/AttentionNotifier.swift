// AttentionNotifier — the sidebar's two signals, as macOS notifications.
//
// Watches the store for a row flipping into NEEDS YOU for one of the three *blocked* reasons
// (permission prompt, elicitation, agent input), or getting its "done" tint (Claude finished a
// turn nobody was watching), and posts one macOS notification for it — unless the user is looking
// at that very row. The 60 s "done unattended" ageing is not an event: the done banner is already
// up, and it stays until the row is dealt with.
//
// ## One banner per row
//
// Every row has one identifier, so its banner always describes its *latest* state: a done banner
// is replaced by the NEEDS YOU banner when a prompt follows, and either goes away the moment the
// user looks at the row or the row stops needing anything. A busy day therefore never piles up
// stale banners in Notification Center. Several rows flipping to NEEDS YOU in one delivery share
// a single "N sessions need you" banner instead of N.
//
// ## Why a store observer
//
// `LiveSessionState.attention`/`isDone` are written in exactly one place (`AppState.rederiveStatus`),
// but that place is reached from six reducers, and three of them bypass `ClaudeIntegration`
// entirely (`setAlive` on a pty exit, `markAttended` from the window, `setLive` from the
// launcher). Every flip lands in `ChangeSet.sessions` because `Session` is `Equatable` including
// `live`, so the one seam that sees them all is a store observer with a shadow map of the last
// signal it saw per row.
//
// ## Why the shadow map has no entry for a row without live state
//
// A restored row has `live == nil` until its descriptor arrives — and that first descriptor may
// already say `waiting`. Firing on "first seen, already waiting" would turn every relaunch with a
// waiting session into a burst of banners for prompts the user has already seen. Only a change
// *from a known state* fires: the row had live state, was not blocked / done, and now is.
//
// ## When a banner comes back
//
// Two moments, whichever is first: the row stops needing anything (the prompt was answered, the
// row was removed), or the user looks at the row — selected, in a key window that is on screen.
// The second is its own rule because a pending prompt keeps the badge on through `markAttended`;
// the badge is right to stay (the prompt is still up), the banner is not. Muting a row from its
// context menu (`Session.notificationsMuted`) counts as the second: its banner goes at once, and
// nothing is posted for it until it is unmuted.

import Foundation
import TkzCore
import os

@MainActor
public final class AttentionNotifier {
    /// What a row's banner, if any, is about.
    enum Signal: Equatable {
        /// Nothing to say.
        case none
        /// NEEDS YOU for a permission prompt, a question or an agent-input request.
        case blocked
        /// Claude finished a turn nobody was watching — the "done" tint, or, after 60 s, the
        /// `doneUnattended` badge that grows out of it. One signal: the banner does not change.
        case done
    }

    private let store: AppStore
    private let presenter: any NotificationPresenting
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "notifications")

    /// The last signal seen, per row that *has* live state.
    private var signals: [SessionID: Signal]
    /// Every banner posted and not yet taken back, by identifier → the rows it speaks for. A
    /// coalesced banner lists several; a click resolves to the first still needing attention.
    public private(set) var presented: [String: [SessionID]] = [:]
    private var batchCounter = 0
    private var doneSwitch: Bool
    private var token: AppStore.ObserverToken?

    /// "Is the user looking at this row right now?" — `MainWindowController.isSessionAttended`.
    /// A flip on that row posts nothing: the badge in front of them is enough.
    public var isSessionAttended: (SessionID) -> Bool = { _ in false }

    /// What a row's agent is called, for a banner that names it — `AgentAdapter.displayName`,
    /// keyed off `Session.agent`. This file never spells an agent's name itself: the assembler
    /// wires this from the adapter registry, and the fallback is honest about not knowing rather
    /// than guessing at a product name.
    public var agentDisplayName: (AgentKind) -> String = { _ in "the agent" }

    /// The user clicked a banner; the window reveals this row and comes to the front.
    public var onActivate: ((SessionID) -> Void)?

    /// macOS has tkzmux's notifications off. The window shows a notice once; without it the only
    /// symptom is silence.
    public var onDenied: (() -> Void)?
    private var deniedNoticed = false

    public init(
        store: AppStore,
        presenter: any NotificationPresenting = SystemNotificationPresenter()
    ) {
        self.store = store
        self.presenter = presenter
        signals = AttentionNotifier.snapshot(store.state)
        doneSwitch = store.state.notifyOnDone
        presenter.onActivate = { [weak self] identifier in self?.activate(identifier) }
        presenter.onDenied = { [weak self] in
            guard let self, !self.deniedNoticed else { return }
            self.deniedNoticed = true
            self.onDenied?()
        }
        token = store.addObserver { [weak self] change in self?.apply(change) }
        // The permission dialog at launch, not at the first prompt an hour in. Unconditional:
        // NEEDS YOU has no switch of its own, macOS's per-app setting is the master switch.
        presenter.requestAuthorization()
    }

    // MARK: Observation

    /// One delivery. Internal so tests drive it through the store and `flush()`.
    func apply(_ change: ChangeSet) {
        let state = store.state
        if change.chrome, state.notifyOnDone != doneSwitch {
            doneSwitch = state.notifyOnDone
            // Off takes the finished banners back; the NEEDS YOU ones are not its business.
            if !doneSwitch {
                for (identifier, ids) in presented where ids.allSatisfy({ signals[$0] == .done }) {
                    presenter.dismiss(identifier: identifier)
                    presented.removeValue(forKey: identifier)
                }
            }
        }
        guard !change.sessions.isEmpty else { return }

        var blocked: [SessionID] = []
        var done: [SessionID] = []
        for id in change.sessions {
            let old = signals[id]
            let new = state.sessions[id]?.live.map(AttentionNotifier.signal(of:))
            if let new { signals[id] = new } else { signals.removeValue(forKey: id) }
            guard let new, new != .none else {
                // Answered, cleared elsewhere, or the row is gone: the banner is stale.
                if old != nil, old != .none { dismiss(containing: id) }
                continue
            }
            // The user is looking at it. A pending prompt keeps the badge on through
            // `markAttended` (the derivation re-raises it until the prompt is answered), so the
            // banner cannot wait for the signal to drop: the row being selected in a key, visible
            // window *is* the moment it has done its job. Same check keeps a new banner off.
            // A muted row (its context menu) is treated the same way: nothing new, and whatever
            // it had up goes the moment it is muted.
            if isSessionAttended(id) || state.sessions[id]?.notificationsMuted == true {
                dismiss(containing: id)
                continue
            }
            guard let old, old != new else { continue }
            switch new {
            case .blocked: blocked.append(id)
            case .done: if old == .none { done.append(id) }
            case .none: break
            }
        }

        // Sidebar order, so a coalesced body reads top to bottom like the list does.
        let order = Dictionary(
            uniqueKeysWithValues: state.orderedSessions.enumerated().map { ($1.id, $0) })
        func sorted(_ ids: [SessionID]) -> [SessionID] {
            ids.sorted { (order[$0] ?? .max, $0.rawValue) < (order[$1] ?? .max, $1.rawValue) }
        }
        if state.notifyOnDone {
            for id in sorted(done) { post(doneRequest(for: id, in: state), for: [id]) }
        }
        if !blocked.isEmpty {
            let ids = sorted(blocked)
            post(needsYouRequest(for: ids, in: state), for: ids)
        }
    }

    private func post(_ request: NotificationRequest, for ids: [SessionID]) {
        // One banner per row: whatever these rows had up is superseded.
        for id in ids { dismiss(containing: id) }
        presented[request.identifier] = ids
        logger.info("notify → \(request.identifier, privacy: .public)")
        presenter.present(request) { _ in }
    }

    // MARK: Requests

    /// One row → its own banner under its stable identifier, so a later banner for the same row
    /// replaces it rather than stacking. Several rows → one banner.
    func needsYouRequest(for ids: [SessionID], in state: AppState) -> NotificationRequest {
        if ids.count == 1, let id = ids.first, let session = state.sessions[id] {
            return NotificationRequest(
                identifier: AttentionNotifier.identifier(for: id),
                title: session.displayTitle,
                body: AttentionNotifier.needsYouBody(
                    for: session, agentName: agentDisplayName(session.agent)))
        }
        batchCounter += 1
        let titles = ids.compactMap { state.sessions[$0]?.displayTitle }
        return NotificationRequest(
            identifier: "needs-you.batch.\(batchCounter)",
            title: "\(ids.count) sessions need you",
            body: titles.joined(separator: ", "))
    }

    func doneRequest(for id: SessionID, in state: AppState) -> NotificationRequest {
        let session = state.sessions[id]
        return NotificationRequest(
            identifier: AttentionNotifier.identifier(for: id),
            title: session?.displayTitle ?? "tkzmux",
            body: AttentionNotifier.doneBody(
                for: session, agentName: agentDisplayName(session?.agent ?? .claude)))
    }

    static func identifier(for id: SessionID) -> String { "session.\(id.rawValue)" }

    /// The agent's own words when a hook carried them; otherwise a line per reason. The descriptor
    /// file alone (no hook, e.g. the shim is not installed) only ever says `waiting`, which the
    /// derivation maps to `.permission`.
    static func needsYouBody(for session: Session, agentName: String) -> String {
        if let message = session.live?.lastNotificationMessage, !message.isEmpty { return message }
        switch session.status {
        case .waiting(.permission): return "\(agentName) is waiting for permission"
        case .waiting(.elicitation): return "\(agentName) is asking you a question"
        case .waiting(.agentInput): return "\(agentName) needs your input"
        default: return "Needs you"
        }
    }

    /// The first line of what the agent said, or a plain "finished" when there is none.
    static func doneBody(for session: Session?, agentName: String) -> String {
        guard let message = session?.live?.lastStopMessage,
            let firstLine = ActivityEvent.firstLines(of: message, count: 1).first
        else { return "\(agentName) finished" }
        let capped = firstLine.count > 120 ? String(firstLine.prefix(119)) + "…" : firstLine
        return "Finished: \(capped)"
    }

    /// The row's signal from its live state. Blocked outranks done: a prompt is a request.
    static func signal(of live: LiveSessionState) -> Signal {
        switch live.status {
        case .waiting(.permission), .waiting(.elicitation), .waiting(.agentInput):
            return live.attention ? .blocked : .none
        case .waiting(.doneUnattended):
            return .done
        default:
            return live.isDone ? .done : .none
        }
    }

    // MARK: Dismissal and activation

    private func dismiss(containing id: SessionID) {
        for (identifier, ids) in presented where ids.contains(id) {
            presenter.dismiss(identifier: identifier)
            presented.removeValue(forKey: identifier)
        }
    }

    /// A banner was clicked. A coalesced banner goes to the first of its rows still waiting; a
    /// banner this process no longer remembers (posted before a relaunch) is decoded from its
    /// identifier.
    private func activate(_ identifier: String) {
        let ids = presented[identifier] ?? AttentionNotifier.decode(identifier).map { [$0] } ?? []
        let target = ids.first { store.state.sessions[$0]?.needsAttention == true } ?? ids.first
        guard let target, store.state.sessions[target] != nil else { return }
        onActivate?(target)
    }

    private static func decode(_ identifier: String) -> SessionID? {
        let prefix = "session."
        guard identifier.hasPrefix(prefix) else { return nil }
        return SessionID(String(identifier.dropFirst(prefix.count)))
    }

    private static func snapshot(_ state: AppState) -> [SessionID: Signal] {
        var map: [SessionID: Signal] = [:]
        for (id, session) in state.sessions {
            if let live = session.live { map[id] = signal(of: live) }
        }
        return map
    }
}
