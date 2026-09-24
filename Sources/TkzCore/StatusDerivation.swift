// TkzCore — status derivation.
//
// Pure and table-driven: no clock (`now` is always a parameter), no I/O, no AppKit. `Reducers.swift`
// is the only caller inside TkzCore; `AgentBridge` and `TkzApp` never derive status themselves —
// they feed `AppState.applyEvent`/`applyObservation`/… and read `LiveSessionState.status` back.
//
// Rule order (first match wins):
//
//   1. `!alive`                                                        → `.idle` (the row is about to be removed)
//   1b. `ended` (the agent exited; the shell is still there)           → `.idle`
//   2. a pending `AttentionKind` with a `waitReason`                    → `.waiting(reason)`
//   2b. `observation.activity == .waiting` (the agent's own prompt flag) → `.waiting(.permission)`
//   3. `observation.parked == true`                                     → `.idle` (parked)
//   4. `observation.activity == .busy`                                  → `.working`
//   4a. a sub-agent the agent reported starting is still running, or
//      `observation.activity == .backgroundShell`                      → `.working`
//   4b. no observation, and `lastPromptAt` is newer than `lastStopAt`
//      (or there is a `lastPromptAt` and no `lastStopAt` at all)        → `.working`
//   5. a `Stop` newer than `attendedAt`, and (an `.idleNudge` after it,
//      or ≥ `unattendedGrace` since it)                                 → `.waiting(.doneUnattended)`
//   6. a `Stop` newer than `attendedAt`, still fresh                    → `.idle`, `isDone = true`
//   7. otherwise                                                        → `.idle`
//
// Rule 4b exists for an agent like Codex that has hooks but writes no descriptor file: with no
// observation to trust, a submitted prompt that has not yet been followed by a `Stop` is the only
// evidence available that a turn is in progress. It is gated on `observation == nil` because an
// agent that *does* write a descriptor has strictly better evidence — Claude always has an
// observation while it runs, so 4b never fires for it, and a lagging descriptor or a cancelled
// prompt cannot flip an idle Claude row to working through this rule.
//
// Rule 4a exists because a turn can end with work still running: Claude Code launches sub-agents in
// the background, its `Stop` fires and its descriptor goes `idle`, and the agents keep going for
// minutes. Without it the row read as done — and after 60 s as NEEDS YOU — while three agents were
// still working (reported 2026-09-23: "I have to prompt Claude 'are you done?'"). It sits below the
// waiting rules on purpose: a sub-agent's permission prompt is still a prompt. Background *shells*
// count too (decision 2026-09-24, reversing 2026-09-23's): Claude backgrounds a CI watcher, says
// "I'll report back when it completes", and the row read as done. The price is that a dev server
// Claude started keeps its row pulsing; the status bar's "⟳ 1 shell" segment says why. The
// evidence is the agent's own descriptor, not the hook's list: it flips back to idle the moment
// the last shell exits, where no hook fires at all.
//
// Without any events this degrades to observation-only (busy → working, idle → idle); with
// neither events nor an observation (a plain shell) it is `.idle` while alive — both asserted in
// `StatusDerivationTests`.

import Foundation

/// Everything `StatusDerivation.derive` needs, in one value. Built either directly (tests) or via
/// the `LiveSessionState` convenience below.
public struct StatusInput: Hashable, Sendable {
    public var observation: AgentObservation?
    public var alive: Bool
    public var ended: Bool
    public var pending: PendingNotification?
    public var lastStopAt: Date?
    public var attendedAt: Date?
    /// `UserPromptSubmit`'s timestamp — rule 4b's only evidence for an agent with no observation.
    public var lastPromptAt: Date?
    /// How many sub-agents are still running — rule 4a.
    public var runningSubagents: Int
    public var now: Date

    public init(
        observation: AgentObservation? = nil,
        alive: Bool = true,
        ended: Bool = false,
        pending: PendingNotification? = nil,
        lastStopAt: Date? = nil,
        attendedAt: Date? = nil,
        lastPromptAt: Date? = nil,
        runningSubagents: Int = 0,
        now: Date
    ) {
        self.observation = observation
        self.alive = alive
        self.ended = ended
        self.pending = pending
        self.lastStopAt = lastStopAt
        self.attendedAt = attendedAt
        self.lastPromptAt = lastPromptAt
        self.runningSubagents = runningSubagents
        self.now = now
    }
}

/// The derived status, the `NEEDS YOU` badge, and the "done" tint — one call, three answers, so
/// callers never derive one without the others and let them drift.
public struct StatusOutcome: Hashable, Sendable {
    public var status: SessionStatus
    public var attention: Bool
    public var isDone: Bool

    public init(status: SessionStatus, attention: Bool, isDone: Bool) {
        self.status = status
        self.attention = attention
        self.isDone = isDone
    }
}

public enum StatusDerivation {
    /// How long an unattended `Stop` sits as plain "done" before it becomes `NEEDS YOU`.
    public static let unattendedGrace: TimeInterval = 60

    /// The table above, exactly. First match wins.
    public static func derive(_ input: StatusInput) -> StatusOutcome {
        // 1. Not running. There is no "exited" status any more (decision 2026-09-08): a terminal
        // whose shell ended is removed from the sidebar by the window, so a dead row is only ever
        // seen for the instant before that. Plain idle, nothing to attend to.
        if !input.alive {
            return StatusOutcome(status: .idle, attention: false, isDone: false)
        }

        // 1b. Claude ended (Ctrl-C twice, /exit, logout) but the shell underneath is alive: the
        // row is a plain terminal again. Not `exited` — reported 2026-09-08: the row said Exited
        // and the screen dimmed while the prompt was blinking and taking input. Nothing Claude
        // left behind (a prompt, a Stop) can need the user any more.
        if input.ended {
            return StatusOutcome(status: .idle, attention: false, isDone: false)
        }

        // 2. A prompt is on screen and unanswered. `.idleNudge` has no `waitReason` and falls
        // through by construction — it is not status-bearing on its own, only rule 5 reads it.
        if let pending = input.pending, let reason = pending.kind.waitReason {
            return StatusOutcome(status: .waiting(reason), attention: true, isDone: false)
        }

        // 2b. The observation says the agent is waiting on a prompt. Claude Code writes
        // `status: waiting` while a permission prompt is up (measured 2026-09-08), so a session
        // without hooks (`--bare`, a bypassed shim, a session started elsewhere) still lights up.
        if input.observation?.activity == .waiting {
            return StatusOutcome(status: .waiting(.permission), attention: true, isDone: false)
        }

        // 3. A background job parked under this session — not busy, not waiting.
        if input.observation?.parked == true {
            return StatusOutcome(status: .idle, attention: false, isDone: false)
        }

        // 4. The observation itself says the agent is working.
        if input.observation?.activity == .busy {
            return StatusOutcome(status: .working, attention: false, isDone: false)
        }

        // 4a. The main turn may be over, but sub-agents or background shells it started are still
        // running. Not done, and not NEEDS YOU either: the agent will pick their results up itself.
        if input.runningSubagents > 0 || input.observation?.activity == .backgroundShell {
            return StatusOutcome(status: .working, attention: false, isDone: false)
        }

        // 4b. No observation to trust, and a prompt was submitted more recently than the last
        // `Stop` (or there is a prompt and no `Stop` at all): the only evidence available says a
        // turn is still in progress. Gated on `observation == nil` — an agent that writes a
        // descriptor has strictly better evidence than a submitted-prompt timestamp, and Claude
        // always has an observation while it runs, so this rule is inert for it and every
        // existing Claude expectation holds. It exists for an agent like Codex, which has hooks
        // but no descriptor file of its own.
        if input.observation == nil, let lastPromptAt = input.lastPromptAt {
            let promptIsNewer = input.lastStopAt.map { lastPromptAt > $0 } ?? true
            if promptIsNewer {
                return StatusOutcome(status: .working, attention: false, isDone: false)
            }
        }

        // 5 & 6. A Stop the user has not yet attended to.
        if let lastStopAt = input.lastStopAt {
            let stopIsUnattended = input.attendedAt.map { lastStopAt > $0 } ?? true
            if stopIsUnattended {
                let idlePromptAfterStop = input.pending?.kind == .idleNudge
                    && input.pending!.receivedAt > lastStopAt
                let elapsed = input.now.timeIntervalSince(lastStopAt)
                if idlePromptAfterStop || elapsed >= unattendedGrace {
                    return StatusOutcome(status: .waiting(.doneUnattended), attention: true, isDone: false)
                }
                return StatusOutcome(status: .idle, attention: false, isDone: true)
            }
        }

        // 7. Nothing else applies.
        return StatusOutcome(status: .idle, attention: false, isDone: false)
    }

    /// Convenience over a session's live state.
    public static func derive(_ live: LiveSessionState, now: Date) -> StatusOutcome {
        derive(
            StatusInput(
                observation: live.observation,
                alive: live.alive,
                ended: live.ended,
                pending: live.pendingNotification,
                lastStopAt: live.lastStopAt,
                attendedAt: live.attendedAt,
                lastPromptAt: live.lastPromptAt,
                runningSubagents: live.runningSubagents.count,
                now: now
            ))
    }
}
