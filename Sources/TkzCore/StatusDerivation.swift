// TkzCore — status derivation. See docs/design.md → *Claude integration → Status derivation*.
//
// Pure and table-driven: no clock (`now` is always a parameter), no I/O, no AppKit. `Reducers.swift`
// is the only caller inside TkzCore; `ClaudeBridge` and `TkzApp` never derive status themselves —
// they feed `AppState.applyHook`/`applyDescriptor`/… and read `LiveSessionState.status` back.
//
// Rule order (first match wins — see the table in design.md):
//
//   1. `!alive`                                                        → `.exited`
//   1b. `ended` (SessionEnd, reason ∉ clear/resume: Claude quit, the
//      shell is still there)                                          → `.idle`
//   2. a pending permission/elicitation/agent-input prompt              → `.waiting(reason)`
//   2b. `descriptor.status == .waiting` (Claude's own prompt flag)      → `.waiting(.permission)`
//   3. `descriptor.parkedJobId != nil`                                  → `.idle` (parked)
//   4. `descriptor.status == .busy`                                     → `.working`
//   5. a `Stop` newer than `attendedAt`, and (an `idle_prompt` after it,
//      or ≥ `unattendedGrace` since it)                                 → `.waiting(.doneUnattended)`
//   6. a `Stop` newer than `attendedAt`, still fresh                    → `.idle`, `isDone = true`
//   7. otherwise                                                        → `.idle`
//
// Without any hooks this degrades to descriptor-only (busy → working, idle → idle); with neither
// hooks nor a descriptor (a plain shell) it is `.idle` while alive — both asserted in
// `StatusDerivationTests`.

import Foundation

/// Everything `StatusDerivation.derive` needs, in one value. Built either directly (tests) or via
/// the `LiveSessionState` convenience below.
public struct StatusInput: Hashable, Sendable {
    public var descriptor: ClaudeSessionInfo?
    public var alive: Bool
    public var ended: Bool
    public var pending: PendingNotification?
    public var lastStopAt: Date?
    public var attendedAt: Date?
    public var now: Date

    public init(
        descriptor: ClaudeSessionInfo? = nil,
        alive: Bool = true,
        ended: Bool = false,
        pending: PendingNotification? = nil,
        lastStopAt: Date? = nil,
        attendedAt: Date? = nil,
        now: Date
    ) {
        self.descriptor = descriptor
        self.alive = alive
        self.ended = ended
        self.pending = pending
        self.lastStopAt = lastStopAt
        self.attendedAt = attendedAt
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
        // 1. Not running. `exited` means the *terminal* is gone: the scrim, the hollow dot and the
        // suppressed cursor all read it that way.
        if !input.alive {
            return StatusOutcome(status: .exited, attention: false, isDone: false)
        }

        // 1b. Claude ended (Ctrl-C twice, /exit, logout) but the shell underneath is alive: the
        // row is a plain terminal again. Not `exited` — reported 2026-09-08: the row said Exited
        // and the screen dimmed while the prompt was blinking and taking input. Nothing Claude
        // left behind (a prompt, a Stop) can need the user any more.
        if input.ended {
            return StatusOutcome(status: .idle, attention: false, isDone: false)
        }

        // 2. A prompt is on screen and unanswered.
        if let pending = input.pending {
            switch pending.type {
            case .permissionPrompt:
                return StatusOutcome(status: .waiting(.permission), attention: true, isDone: false)
            case .elicitationDialog:
                return StatusOutcome(status: .waiting(.elicitation), attention: true, isDone: false)
            case .agentNeedsInput:
                return StatusOutcome(status: .waiting(.agentInput), attention: true, isDone: false)
            case .idlePrompt, .elicitationComplete, .unknown:
                break  // handled below (idlePrompt) or not status-bearing at all
            }
        }

        // 2b. The descriptor says Claude is waiting on a prompt. Claude Code writes
        // `status: waiting` while a permission prompt is up (measured 2026-09-08), so a session
        // without hooks (`--bare`, a bypassed shim, a session started elsewhere) still lights up.
        if input.descriptor?.status == .waiting {
            return StatusOutcome(status: .waiting(.permission), attention: true, isDone: false)
        }

        // 3. A background job parked under this session — not busy, not waiting.
        if input.descriptor?.parkedJobId != nil {
            return StatusOutcome(status: .idle, attention: false, isDone: false)
        }

        // 4. The descriptor itself says Claude is working.
        if input.descriptor?.status == .busy {
            return StatusOutcome(status: .working, attention: false, isDone: false)
        }

        // 5 & 6. A Stop the user has not yet attended to.
        if let lastStopAt = input.lastStopAt {
            let stopIsUnattended = input.attendedAt.map { lastStopAt > $0 } ?? true
            if stopIsUnattended {
                let idlePromptAfterStop = input.pending?.type == .idlePrompt
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
                descriptor: live.descriptor,
                alive: live.alive,
                ended: live.ended,
                pending: live.pendingNotification,
                lastStopAt: live.lastStopAt,
                attendedAt: live.attendedAt,
                now: now
            ))
    }
}
