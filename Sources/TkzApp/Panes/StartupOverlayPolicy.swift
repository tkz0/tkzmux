// StartupOverlayPolicy.swift — when the "Starting Claude…" overlay shows, as a pure function.
//
// A launch that is quick must not flash a spinner, so the overlay waits `showDelay` before it
// appears; one that never reports back (a pass-through `claude` with neither hooks nor a
// descriptor) must not sit under a spinner forever, so it gives up after `giveUp`. Both edges are
// decided here from two dates and nothing else — no clock, no timer — in the `CommandHoldDetector`
// manner: the real `DispatchSourceTimer` stays in `MainWindowController.applyStartupOverlay`, and
// the tests never sleep.
import Foundation

public enum StartupOverlayPolicy {
    /// How long a launch must have been pending before the overlay appears.
    public static let showDelay: TimeInterval = 2
    /// How long the edge waits for *any* signal before it stops believing Claude is coming.
    /// Generous on purpose: `claude -w` on a large repository creates a worktree first.
    public static let giveUp: TimeInterval = 120

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
