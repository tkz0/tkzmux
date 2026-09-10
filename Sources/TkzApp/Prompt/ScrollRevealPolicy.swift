// ScrollRevealPolicy.swift — when scrolling up in the terminal should peek the first-prompt card.
//
// "Scrolled up a bit" means two different things depending on which screen the terminal is on:
//
//   * **Primary screen** (a shell, or Claude Code's classic renderer): the viewport moves through
//     the terminal's own scrollback, and `TerminalScrollMetrics` says exactly how far from the
//     bottom it is. Reveal at `revealRows` from the bottom; conceal only once it is back *at* the
//     bottom, so a viewport hovering around the threshold does not flicker the card.
//   * **Alternate screen** (Claude Code's default fullscreen renderer): there is no scrollback to
//     move — the wheel is reported to Claude Code, which scrolls its own transcript, and nothing
//     tells the terminal where that transcript is. So the wheel itself is the signal: net rows
//     scrolled up, floored at zero and capped so a long read up needs only a short scroll back
//     down to conceal. A typed key also conceals: typing means the user is at the prompt again.
//
// A pure value in the `CommandHoldDetector` mould: no clock, no view, every transition returns an
// `Effect` the AppKit edge acts on, so the rules are assertable without a window.

import TkzTerminalCore

struct ScrollRevealPolicy: Hashable, Sendable {
    enum Effect: Hashable, Sendable {
        case reveal
        case conceal
    }

    /// Rows from the bottom (primary screen) or net wheel rows up (alternate screen) that count as
    /// "scrolled up a bit".
    static let revealRows = 3
    /// The most net wheel rows the alternate-screen accumulator remembers.
    static let wheelCap = revealRows * 4

    private(set) var isRevealed = false
    private(set) var isAlternateScreen = false
    /// Net rows scrolled up on the alternate screen, floored at 0 and capped at `wheelCap`.
    private(set) var wheelRowsUp = 0

    /// A new scroll position from the renderer's per-frame poll.
    mutating func metrics(_ metrics: TerminalScrollMetrics) -> Effect? {
        if metrics.isAlternateScreen != isAlternateScreen {
            // A screen switch (Claude starting, or quitting back to the shell) invalidates
            // whatever the card was revealed for.
            isAlternateScreen = metrics.isAlternateScreen
            wheelRowsUp = 0
            return conceal()
        }
        guard !metrics.isAlternateScreen else { return nil }
        let fromBottom = metrics.isScrollable ? metrics.scrollableRows - metrics.offset : 0
        if fromBottom >= Self.revealRows { return reveal() }
        if fromBottom <= 0 { return conceal() }
        return nil
    }

    /// One wheel event, in the rows `MouseController.wheelRows` reports: **negative = up**.
    mutating func wheel(rows: Int) -> Effect? {
        guard isAlternateScreen, rows != 0 else { return nil }
        wheelRowsUp = min(Self.wheelCap, max(0, wheelRowsUp - rows))
        if wheelRowsUp >= Self.revealRows { return reveal() }
        if wheelRowsUp == 0 { return conceal() }
        return nil
    }

    /// A key went to the terminal: on the alternate screen that is the only "back at the prompt"
    /// signal there is. On the primary screen the metrics say where the viewport is.
    mutating func keyTyped() -> Effect? {
        guard isAlternateScreen else { return nil }
        wheelRowsUp = 0
        return conceal()
    }

    /// Another row or pane took over: forget everything.
    mutating func reset() -> Effect? {
        wheelRowsUp = 0
        isAlternateScreen = false
        return conceal()
    }

    private mutating func reveal() -> Effect? {
        guard !isRevealed else { return nil }
        isRevealed = true
        return .reveal
    }

    private mutating func conceal() -> Effect? {
        guard isRevealed else { return nil }
        isRevealed = false
        return .conceal
    }
}
