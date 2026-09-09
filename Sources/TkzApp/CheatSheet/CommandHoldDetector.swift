// CommandHoldDetector.swift — "hold ⌘ alone for two seconds" as a pure state machine.
//
// The rule: hold ⌘ by itself and the cheat sheet appears; release ⌘, or press any other key while
// ⌘ is still down, and it goes away.
//
// No clock and no `NSEvent` live here. `SelectionController` (TkzTerminalCore) set the precedent:
// time-dependent logic is a value type driven by explicit inputs, and the real timer stays at the
// AppKit edge — here, `CheatSheetOverlayController`. So the tests never sleep; they call
// ``timerFired()`` by hand.
import Foundation

/// Decides when the cheat sheet should appear and disappear. Feed it modifier changes, key presses
/// and focus loss; it answers with what the AppKit edge should do.
public struct CommandHoldDetector: Sendable, Equatable {

    /// What the edge should do next. `arm` starts the hold timer, `cancel` stops it.
    public enum Effect: Equatable, Sendable {
        case arm
        case cancel
        case show
        case hide
    }

    /// How long ⌘ must be held alone before the cheat sheet appears.
    public static let holdDelay: Duration = .seconds(2)

    private enum Phase: Equatable { case idle, armed, showing }
    private var phase: Phase = .idle

    /// Set by anything that means "this ⌘ press is not a bare hold any more" — another key, or
    /// another modifier joining. Cleared *only* by ⌘ actually coming back up.
    private var spoiled = false

    public init() {}

    public var isShowing: Bool { phase == .showing }

    /// A modifier changed.
    ///
    /// Both flags are needed, and that is the subtle part. With only `commandOnly` there is no way
    /// to tell "⌘ was released" from "⇧ joined ⌘", and the difference decides whether ``spoiled``
    /// may be cleared. Consider ⌘ down (armed), ⌘P (spoiled), then ⇧ down and ⇧ up with ⌘ never
    /// leaving the key: `commandOnly` goes false and then true again. Treating that second edge as
    /// a fresh ⌘ press would re-arm and pop the sheet two seconds later — exactly what ``spoiled``
    /// exists to prevent. So suppression survives until `commandHeld` is false.
    public mutating func flagsChanged(commandHeld: Bool, commandOnly: Bool) -> [Effect] {
        guard commandHeld else {
            spoiled = false
            return reset()
        }
        guard commandOnly else {
            spoiled = true
            return reset()
        }
        guard !spoiled, phase == .idle else { return [] }
        phase = .armed
        return [.arm]
    }

    /// A key press. The keystroke is still delivered either way — this only decides what happens
    /// to the card.
    ///
    /// `commandHeld` matters because the monitor sees *every* key in the window, most of them
    /// ordinary typing into the terminal. Suppressing on those would leave ``spoiled`` set with ⌘
    /// nowhere near the keyboard, and since only a ⌘ release clears it, the next deliberate hold
    /// would silently do nothing. So typing resets; a chord suppresses.
    public mutating func keyDown(commandHeld: Bool) -> [Effect] {
        spoiled = commandHeld
        return reset()
    }

    /// The window stopped being key — ⌘-Tab, Spotlight, another app.
    ///
    /// Deliberately does **not** set ``spoiled``. The ⌘ release happens while we are inactive and
    /// no local monitor sees it, so a suppression set here would never be cleared and the cheat
    /// sheet would stay dead for the rest of the session.
    public mutating func resignedKey() -> [Effect] {
        spoiled = false
        return reset()
    }

    /// The hold timer elapsed. A timer that outlived its cancellation is a no-op.
    public mutating func timerFired() -> [Effect] {
        guard phase == .armed else { return [] }
        phase = .showing
        return [.show]
    }

    private mutating func reset() -> [Effect] {
        switch phase {
        case .idle:
            return []
        case .armed:
            phase = .idle
            return [.cancel]
        case .showing:
            phase = .idle
            return [.hide]
        }
    }
}
