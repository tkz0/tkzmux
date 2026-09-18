// BoardDispatcher — hands board cards to agents: the one place a card's prompt reaches a pty.
//
// `AppState.nextBoardDispatches()` (TkzCore) decides *who gets what*; this type decides *when* and
// does the typing. It watches the store, and for every agent that is free and has a card waiting:
//
//   1. waits `settleDelay`, then asks the store again. A row is "ready" the instant its
//      `SessionStart` or `Stop` hook lands, which is a beat before Claude's input box is actually
//      listening — and a status that flips back inside that beat (a Stop followed straight away by
//      a permission prompt) must not get a prompt pasted into it;
//   2. marks the card *In Progress* in the store **before** writing, so a second evaluation in the
//      same turn cannot hand the same card out twice;
//   3. writes the prompt as a bracketed paste, so a multi-line card arrives as one message rather
//      than one submit per line, and sends ↵ as a separate write `submitDelay` later — Claude's
//      input treats a CR that arrives glued to a paste as part of it.
//
// The card moving on to *In Review* is not this type's business: `applyHook` does that on `Stop`.

import Foundation
import TkzCore

@MainActor
final class BoardDispatcher {
    private let store: AppStore
    private let host: any TerminalHost

    /// How long a row has to stay ready before it is given a card.
    var settleDelay: Duration = .milliseconds(1500)
    /// The gap between the paste and the ↵ that submits it.
    var submitDelay: Duration = .milliseconds(150)
    /// Called after a card's prompt has been written. The window controller posts the notice.
    var onDispatched: ((BoardDispatch) -> Void)?
    /// The rows that take no unassigned group card right now — the one the user is in. Asked on
    /// every evaluation *and again* when the settle timer fires: the user may have clicked into a
    /// terminal in between. It depends on what is on screen, which the store does not know, so
    /// whoever changes that calls ``evaluate()``.
    var reserved: () -> Set<SessionID> = { [] }

    private var token: AppStore.ObserverToken?
    /// One settle timer per agent; a second evaluation while one runs is ignored.
    private var settling: [SessionID: Task<Void, Never>] = [:]

    init(store: AppStore, host: any TerminalHost) {
        self.store = store
        self.host = host
        token = store.addObserver { [weak self] change in
            // `sessions` is the bucket a status flip arrives in, and it fires on every port scan
            // too; `nextBoardDispatches` returns at once when nothing is in To Do.
            // `selection`, because leaving a row is what frees it for a group card.
            guard change.board || change.structure || change.selection || !change.sessions.isEmpty
            else { return }
            self?.evaluate()
        }
    }

    /// Starts a settle timer for every agent that could take a card now.
    func evaluate() {
        let dispatches = store.state.nextBoardDispatches(reserved: reserved())
        for dispatch in dispatches where settling[dispatch.session] == nil {
            let session = dispatch.session
            settling[session] = Task { [weak self, settleDelay] in
                try? await Task.sleep(for: settleDelay)
                guard !Task.isCancelled else { return }
                self?.fire(session)
            }
        }
    }

    /// The settle timer ran out: if the agent is *still* free and still has a card, it gets it.
    private func fire(_ session: SessionID) {
        settling[session] = nil
        guard let dispatch = store.state.nextBoardDispatches(reserved: reserved())
            .first(where: { $0.session == session }),
            host.contains(dispatch.terminal)
        else { return }
        let accepted = store.updating { $0.markBoardTaskDispatched(dispatch.task, to: session) }
        guard accepted else { return }

        host.writeInput(dispatch.terminal, Self.pasteBytes(for: dispatch.prompt))
        let terminal = dispatch.terminal
        Task { [weak self, submitDelay] in
            try? await Task.sleep(for: submitDelay)
            self?.host.writeInput(terminal, Data([0x0D]))
        }
        onDispatched?(dispatch)
    }

    /// `ESC[200~ … ESC[201~` around the prompt, with everything that could break out of the
    /// bracket removed: ESC itself (so the text cannot carry its own `ESC[201~`) and every other
    /// C0 control except tab and newline. Newlines go out as CR, which is what a terminal sends
    /// for a pasted line break.
    static func pasteBytes(for prompt: String) -> Data {
        var body: [UInt8] = []
        body.reserveCapacity(prompt.utf8.count)
        var previousWasCR = false
        for byte in prompt.utf8 {
            switch byte {
            case 0x0A:
                if !previousWasCR { body.append(0x0D) }   // "\r\n" is one break, not two
            case 0x0D:
                body.append(0x0D)
            case 0x09:
                body.append(byte)
            case 0x00...0x1F, 0x7F:
                break
            default:
                body.append(byte)
            }
            previousWasCR = byte == 0x0D
        }
        return Data([0x1B] + Array("[200~".utf8) + body + [0x1B] + Array("[201~".utf8))
    }
}
