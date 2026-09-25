// TerminalInputModes.swift — the three modes that say a full-screen program owns the keyboard.
//
// A pty carries no "a TUI is running" flag, and the foreground process group does not answer the
// question either: `claude -w` is the foreground job from its first instruction, long before it
// has drawn anything. What does answer it is the input protocols a TUI turns on for itself before
// it can read a key. Measured on 2026-09-19 through `tkzmux-vtdump record`, at each program's
// first prompt:
//
// | mode                   | interactive zsh | Claude Code | Codex CLI |
// | ---------------------- | --------------- | ----------- | --------- |
// | kitty keyboard flags   | 0               | 5           | 5         |
// | focus events (1004)    | reset           | set         | set       |
// | alternate screen(1049) | reset           | reset       | reset     |
// | bracketed paste (2004) | **set**         | set         | set       |
//
// Bracketed paste is therefore useless here — every line editor sets it, including the shell the
// boot command was typed into. The other three are not set by a shell at a prompt, and any one of
// them alone is enough: a TUI that takes the alternate screen without the kitty protocol (`vim`,
// `less`) still owns the keyboard, and so does one that does the reverse.
//
// Neither agent took the alternate screen at startup, which is why it cannot be the only test —
// the reading that motivated this type in the first place.
import Foundation

/// The input protocols a terminal currently has switched on, as far as they distinguish a
/// full-screen program from a shell sitting at its prompt.
public struct TerminalInputModes: Hashable, Sendable {
    /// DEC private mode 1049 — the alternate screen.
    public var alternateScreen: Bool
    /// DEC private mode 1004 — focus in/out reporting.
    public var focusReporting: Bool
    /// The kitty keyboard protocol flags, non-zero once a program has pushed a set of its own.
    public var kittyKeyboardFlags: UInt8

    public init(alternateScreen: Bool, focusReporting: Bool, kittyKeyboardFlags: UInt8) {
        self.alternateScreen = alternateScreen
        self.focusReporting = focusReporting
        self.kittyKeyboardFlags = kittyKeyboardFlags
    }

    /// Nothing switched on: what a freshly spawned terminal reads as, before its shell has even
    /// printed a prompt.
    ///
    /// Named `nothingSet` rather than `none` on purpose. `none` on a type that is routinely passed
    /// as an `Optional` resolves to `Optional.none` at a call site that means this value, silently
    /// turning an assertion about a quiet terminal into an assertion about no terminal at all.
    public static let nothingSet = TerminalInputModes(
        alternateScreen: false, focusReporting: false, kittyKeyboardFlags: 0)

    /// Whether a full-screen program has taken over the keyboard. See this file's header for the
    /// measurements behind the three terms, and for why bracketed paste is not one of them.
    public var hasFullScreenProgram: Bool {
        alternateScreen || focusReporting || kittyKeyboardFlags != 0
    }
}

extension TerminalSession {
    /// The terminal's current input modes. Three reads of live VT state, cheap enough to poll.
    public var inputModes: TerminalInputModes {
        TerminalInputModes(
            alternateScreen: mode(1049),
            focusReporting: mode(1004),
            kittyKeyboardFlags: kittyKeyboardFlags)
    }

    /// Switches off every input protocol a program can turn on for itself — what that program
    /// would have sent on a clean exit — for a terminal whose program is gone and whose next
    /// reader is a fresh shell. A `.ghsnap` carries the modes of whatever was running when it was
    /// taken; restored under a new zsh, Claude Code's any-motion SGR mouse turned every hover into
    /// `ESC[<35;x;yM` typed at the prompt.
    ///
    /// Sent as VT sequences through the parser, so the terminal's own bookkeeping stays
    /// consistent. The alternate screen is deliberately left alone: it decides *which* screen is
    /// showing, and leaving it would swap the restored content for whatever was underneath.
    public func resetInputModes() {
        write(ptyText: Self.inputModeReset)
    }

    /// Mouse tracking (X10, normal, highlight, button, any-motion) and its encodings (UTF-8, SGR,
    /// urxvt, SGR-pixels); focus events; bracketed paste; synchronized output; application cursor
    /// keys; application keypad (`ESC >`); the kitty keyboard flags of the current stack entry.
    static let inputModeReset =
        "\u{1b}[?9l\u{1b}[?1000l\u{1b}[?1001l\u{1b}[?1002l\u{1b}[?1003l"
        + "\u{1b}[?1005l\u{1b}[?1006l\u{1b}[?1015l\u{1b}[?1016l"
        + "\u{1b}[?1004l\u{1b}[?2004l\u{1b}[?2026l\u{1b}[?1l\u{1b}>"
        + "\u{1b}[=0;1u"
}
