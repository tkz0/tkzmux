// CheatSheetOverlayController.swift — the AppKit edge of the ⌘-hold cheat sheet.
//
// `CommandHoldDetector` decides *when*; this turns its effects into a real timer and a real view,
// and rebuilds the rows from the live menu on every show. It is deliberately the only part that
// knows about clocks, so the state machine stays testable without sleeping.
import AppKit
import TkzCore

@MainActor
final class CheatSheetOverlayController {

    let view: CheatSheetOverlayView

    /// The menu to read the shortcuts out of, asked for afresh on each show so an edited
    /// `AppState.shortcuts` needs no relaunch.
    var menuProvider: (() -> NSMenu?)?

    private var detector = CommandHoldDetector()
    private var holdTimer: DispatchSourceTimer?

    init(theme: Theme) {
        self.view = CheatSheetOverlayView(theme: theme)
    }

    func setTheme(_ theme: Theme) { view.setTheme(theme) }

    // MARK: Input

    /// A `.flagsChanged` from the local monitor. Caps Lock is a lock, not a chord — the same rule
    /// `handleCommandKey` applies.
    func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        apply(detector.flagsChanged(
            commandHeld: flags.contains(.command),
            commandOnly: flags == .command))
    }

    func keyDown(_ flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        apply(detector.keyDown(commandHeld: flags.contains(.command)))
    }

    func resignedKey() { apply(detector.resignedKey()) }

    /// Cancels the timer and drops the view. Called from `MainWindowController.shutdown()`.
    func stop() {
        cancelTimer()
        view.hide()
    }

    // MARK: Effects

    private func apply(_ effects: [CommandHoldDetector.Effect]) {
        for effect in effects {
            switch effect {
            case .arm: armTimer()
            case .cancel: cancelTimer()
            case .show: present()
            case .hide: view.hide()
            }
        }
    }

    private func armTimer() {
        cancelTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay = CommandHoldDetector.holdDelay
        let seconds = Double(delay.components.seconds)
            + Double(delay.components.attoseconds) / 1e18
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdTimer = nil
                self.apply(self.detector.timerFired())
            }
        }
        holdTimer = timer
        timer.resume()
    }

    private func cancelTimer() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func present() {
        // Re-check the hardware before committing. `windowDidResignKey` catches ⌘-Tab and
        // Spotlight, but any path that swallows a `flagsChanged` — dropping into a menu-bar
        // tracking loop with ⌘ down, for one — would otherwise strand the card on screen with no
        // release ever arriving. `NSEvent.modifierFlags` is the live hardware state, not an
        // event's snapshot, so this turns the worst failure from "stuck" into "did not appear".
        let flags = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        guard flags == .command else {
            apply(detector.keyDown(commandHeld: flags.contains(.command)))
            return
        }
        guard let menu = menuProvider?() else { return }
        view.setSections(CheatSheetModel.sections(from: menu))
        view.show()
    }
}
