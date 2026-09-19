// StartupOverlayPolicy.swift — when the "Starting the agent…" overlay shows, as pure functions.
//
// A launch that is quick must not flash a spinner, so the overlay waits `showDelay` before it
// appears; one that never reports back must not sit under a spinner forever, so it gives up after
// `giveUp`. Both edges are decided here from two dates and nothing else — no clock, no timer — in
// the `CommandHoldDetector` manner: the real `DispatchSourceTimer` stays in
// `MainWindowController.applyStartupOverlay`, and the tests never sleep.
//
// The clock is not the only thing that ends the wait, and for one of the two agents it is the only
// thing that *could*, which is the bug this second half exists to fix. Codex writes no descriptor
// file, its hooks stay silent until the user has trusted them in Codex itself, and its boot command
// is a TUI that never returns — so none of the three store-side signals that clear `agentStartup`
// can ever arrive. The spinner sat for the full two minutes on top of Codex's own startup prompt,
// telling the user we were still starting an agent that was in fact waiting on them.
//
// So the pane itself is asked. Once a full-screen program has switched on the input protocols it
// needs to read a key, whatever is on screen is the agent's own UI and a spinner over it is a
// lie — `TerminalInputModes` carries the three modes and the measurements behind them.
import Foundation
import TkzTerminalCore

public enum StartupOverlayPolicy {
    /// How long a launch must have been pending before the overlay appears.
    public static let showDelay: TimeInterval = 2
    /// How long the edge waits for *any* signal before it stops believing the agent is coming.
    /// Generous on purpose: a worktree launch creates the worktree before the agent starts.
    public static let giveUp: TimeInterval = 120
    /// How often the pane is re-examined while the overlay is up.
    ///
    /// A poll rather than an event because the VT publishes no mode-change event and giving it one
    /// is a change to the terminal layer for a single caller. The cost is bounded and small: one
    /// pane, three reads of live VT state, only between a launch and the moment the agent's UI
    /// appears — in practice a handful of polls, at worst `giveUp / recheck` of them.
    public static let recheck: TimeInterval = 0.25

    public enum Phase: Equatable, Sendable {
        /// Too early to show; re-evaluate at `showAt`.
        case pending(showAt: Date)
        /// Show; re-evaluate at `expiresAt`.
        case visible(expiresAt: Date)
        /// Nothing came in time: the launch should be forgotten.
        case expired
    }

    /// `showDelay` is inclusive (the timer fires *at* `showAt`), `giveUp` exclusive.
    public static func phase(startedAt: Date, now: Date) -> Phase {
        let elapsed = now.timeIntervalSince(startedAt)
        if elapsed < showDelay {
            return .pending(showAt: startedAt.addingTimeInterval(showDelay))
        }
        if elapsed < giveUp {
            return .visible(expiresAt: startedAt.addingTimeInterval(giveUp))
        }
        return .expired
    }

    /// Whether the pane is showing the agent's own UI rather than a shell that has not started it
    /// yet. `nil` — a pane the host holds no terminal for — is not evidence either way, so it reads
    /// as "not yet" and the clock stays in charge.
    public static func agentIsOnScreen(_ modes: TerminalInputModes?) -> Bool {
        modes?.hasFullScreenProgram ?? false
    }

    /// When to look at the pane again, given the phase's own deadline. Before the agent appears
    /// that is the next poll; after it there is nothing further to watch for, so the only date
    /// still worth a timer is the give-up.
    public static func nextLook(agentIsOnScreen: Bool, deadline: Date, now: Date) -> Date {
        agentIsOnScreen ? deadline : min(deadline, now.addingTimeInterval(recheck))
    }
}

/// What the overlay shows. The same shape as `PaneHeaderModel`: a value with no `TkzCore` model
/// inside it, so the view renders from data a test can construct.
public struct PaneStartupModel: Hashable, Sendable {
    /// The boot command, as the overlay's caption.
    public var command: String

    public init(command: String) {
        self.command = command
    }
}
