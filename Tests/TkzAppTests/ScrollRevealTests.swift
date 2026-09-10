// ScrollRevealTests — scrolling up in the terminal peeks the first-prompt card (design 2c.5).
//
// The policy is a pure value, so the primary-screen rules (viewport rows from the bottom, with
// hysteresis) and the alternate-screen rules (net wheel rows, a typed key) are asserted without a
// terminal. The controller half checks that a peek never takes the keyboard or the mouse, that
// the chord pins it, and that a pinned card ignores the scroll signals.

import AppKit
import ClaudeBridge
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite("Scroll reveal", .serialized)
struct ScrollRevealTests {

    private static func metrics(fromBottom: Int, alternate: Bool = false) -> TerminalScrollMetrics {
        // 200 rows of history under a 40-row viewport; `offset` counts from the top.
        TerminalScrollMetrics(total: 240, offset: 200 - fromBottom, visible: 40, isAlternateScreen: alternate)
    }

    // MARK: Policy

    @Test("Primary screen: reveal three rows from the bottom, conceal only back at the bottom")
    func primaryScreenHysteresis() {
        var policy = ScrollRevealPolicy()
        #expect(policy.metrics(Self.metrics(fromBottom: 0)) == nil)
        #expect(policy.metrics(Self.metrics(fromBottom: 2)) == nil, "not yet 'a bit'")
        #expect(policy.metrics(Self.metrics(fromBottom: 3)) == .reveal)
        #expect(policy.metrics(Self.metrics(fromBottom: 10)) == nil, "already revealed")
        #expect(policy.metrics(Self.metrics(fromBottom: 1)) == nil, "hovering near the bottom does not flicker")
        #expect(policy.metrics(Self.metrics(fromBottom: 0)) == .conceal)
        #expect(policy.metrics(Self.metrics(fromBottom: 0)) == nil)
    }

    @Test("An unscrollable terminal never reveals, and a screen switch conceals")
    func unscrollableAndScreenSwitch() {
        var policy = ScrollRevealPolicy()
        let flat = TerminalScrollMetrics(total: 40, offset: 0, visible: 40, isAlternateScreen: false)
        #expect(policy.metrics(flat) == nil)
        #expect(policy.metrics(Self.metrics(fromBottom: 5)) == .reveal)
        // Claude starts: the alternate screen takes over and whatever was shown is stale.
        #expect(policy.metrics(Self.metrics(fromBottom: 0, alternate: true)) == .conceal)
        #expect(policy.isAlternateScreen)
        // Back to the shell: nothing to conceal, and the shell's position is judged afresh.
        #expect(policy.metrics(Self.metrics(fromBottom: 0)) == nil)
        #expect(policy.metrics(Self.metrics(fromBottom: 4)) == .reveal)
    }

    @Test("Alternate screen: the wheel is the signal, net of scrolling back, capped, and a key ends it")
    func alternateScreenWheel() {
        var policy = ScrollRevealPolicy()
        #expect(policy.wheel(rows: -5) == nil, "not on the alternate screen yet: the metrics decide")
        _ = policy.metrics(Self.metrics(fromBottom: 0, alternate: true))
        #expect(policy.wheel(rows: -1) == nil)
        #expect(policy.wheel(rows: -1) == nil)
        #expect(policy.wheel(rows: -1) == .reveal)
        #expect(policy.wheel(rows: -100) == nil)
        #expect(policy.wheelRowsUp == ScrollRevealPolicy.wheelCap, "capped, so a short scroll down conceals")
        #expect(policy.wheel(rows: ScrollRevealPolicy.wheelCap - 1) == nil)
        #expect(policy.wheel(rows: 1) == .conceal)
        #expect(policy.wheel(rows: 2) == nil, "floored at zero")

        #expect(policy.wheel(rows: -3) == .reveal)
        #expect(policy.keyTyped() == .conceal)
        #expect(policy.wheelRowsUp == 0)
        #expect(policy.keyTyped() == nil)
    }

    @Test("A key on the primary screen is not a signal; reset conceals and forgets the screen")
    func keyOnPrimaryAndReset() {
        var policy = ScrollRevealPolicy()
        #expect(policy.metrics(Self.metrics(fromBottom: 6)) == .reveal)
        #expect(policy.keyTyped() == nil, "the viewport position says where the user is")
        #expect(policy.reset() == .conceal)
        #expect(policy.reset() == nil)
        #expect(!policy.isAlternateScreen)
    }

    // MARK: Controller

    @Test("A peek orders the panel front without the keyboard or the mouse; the chord pins it")
    func peekThenPin() throws {
        let controller = PromptCardController(theme: .default)
        controller.summaryProvider = { _, done in done(TranscriptSummary(firstPrompt: "Fix the build")) }
        let id = SessionID.generate()

        controller.peek(for: id, over: NSRect(x: 0, y: 0, width: 900, height: 600))
        let panel = try #require(controller.panelForTesting)
        #expect(controller.isShown)
        #expect(controller.mode == .peek)
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.isKeyWindow)
        let card = try #require(controller.cardViewForTesting)
        #expect(card.isPeeking)
        #expect(card.copyPromptButtonForTesting.isEnabled == false, "inert while the mouse passes through")

        // The same scroll again changes nothing; a scroll back down ends it.
        controller.peek(for: id, over: nil)
        #expect(controller.mode == .peek)
        controller.endPeek()
        #expect(!controller.isShown)

        // Peek, then the chord: same card, now interactive; the chord again dismisses.
        controller.peek(for: id, over: nil)
        controller.toggle(for: id, over: nil)
        #expect(controller.mode == .pinned)
        #expect(!panel.ignoresMouseEvents)
        #expect(!card.isPeeking)
        #expect(card.copyPromptButtonForTesting.isEnabled)
        controller.endPeek()
        #expect(controller.isShown, "a pinned card is the user's to close")
        controller.toggle(for: id, over: nil)
        #expect(!controller.isShown)
        #expect(controller.mode == nil)
    }

    @Test("A pinned card is not replaced by a peek for another row")
    func pinnedBeatsPeek() {
        let controller = PromptCardController(theme: .default)
        controller.summaryProvider = { _, done in done(TranscriptSummary()) }
        let a = SessionID.generate(), b = SessionID.generate()
        controller.present(for: a, over: nil)
        controller.peek(for: b, over: nil)
        #expect(controller.sessionID == a)
        #expect(controller.mode == .pinned)
        controller.dismiss()
    }

    @Test("The window controller peeks for the focused pane of a Claude row and not for a plain shell")
    func windowControllerPeeks() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let ids = harness.store.state.orderedGroups.flatMap { harness.store.state.sessions(in: $0.id) }.map(\.id)
        try #require(ids.count >= 2)
        // Every fixture row carries a Claude id; make the first one a plain shell.
        let shell = ids[0], claude = ids[1]
        harness.mutate { $0.sessions[shell]?.claudeSessionId = nil }
        #expect(harness.store.state.sessions[claude]?.claudeSessionId != nil)

        harness.mutate { $0.select(shell) }
        let shellPane = try #require(harness.store.state.sessions[shell]?.focusedTerminalID)
        controller.canPeek = { true }
        controller.terminalScrolled(shellPane) { $0.metrics(Self.metrics(fromBottom: 8)) }
        #expect(!controller.promptCard.isShown, "no prompt to show for a plain shell")

        harness.mutate { $0.select(claude) }
        let pane = try #require(harness.store.state.sessions[claude]?.focusedTerminalID)
        // A wheel over an inactive window scrolls the terminal but must not pop a floating panel
        // over whatever app is active — and must not count as "already shown" either.
        controller.canPeek = { false }
        controller.terminalScrolled(pane) { $0.metrics(Self.metrics(fromBottom: 8)) }
        #expect(!controller.promptCard.isShown, "not while another app is active")
        controller.canPeek = { true }
        controller.terminalScrolled(pane) { $0.metrics(Self.metrics(fromBottom: 9)) }
        #expect(controller.promptCard.isShown, "the next scroll while key reveals")
        controller.terminalScrolled(pane) { $0.metrics(Self.metrics(fromBottom: 0)) }
        #expect(!controller.promptCard.isShown)
        controller.terminalScrolled(TerminalID.generate()) { $0.metrics(Self.metrics(fromBottom: 8)) }
        #expect(!controller.promptCard.isShown, "an unfocused pane's scroll is not the user's")
        controller.terminalScrolled(pane) { $0.metrics(Self.metrics(fromBottom: 8)) }
        #expect(controller.promptCard.isShown)
        #expect(controller.promptCard.mode == .peek)
        #expect(controller.promptCard.sessionID == claude)
        controller.terminalScrolled(pane) { $0.metrics(Self.metrics(fromBottom: 0)) }
        #expect(!controller.promptCard.isShown)

        // Selecting another row while peeking closes the card and resets the policy.
        controller.terminalScrolled(pane) { $0.metrics(Self.metrics(fromBottom: 8)) }
        #expect(controller.promptCard.isShown)
        harness.mutate { $0.select(shell) }
        #expect(!controller.promptCard.isShown)
    }
}
