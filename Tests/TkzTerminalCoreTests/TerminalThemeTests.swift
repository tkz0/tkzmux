// TerminalThemeTests — re-colouring a *live* terminal, the toggle's terminal half.
//
// The chrome half of a theme switch is just layer colours; this is the half that has to go through
// libghostty, because `TerminalSurface` reads the effective colours back out of the VT on every
// tick and those win over anything `Theme` says.
import Foundation
import Testing
import GhosttyVt
import TkzCore
@testable import TkzTerminalCore

/// Collects a session's pty writes, so a query reply or an unsolicited report can be asserted.
private final class ThemePtySink: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    var isEmpty: Bool { lock.withLock { bytes.isEmpty } }
    func reset() { lock.withLock { bytes.removeAll() } }
}

private func makeThemedSession(
    cols: UInt16 = 80, rows: UInt16 = 24
) throws -> (TerminalSession, ThemePtySink) {
    let session = try TerminalSession(options: TerminalSessionOptions(cols: cols, rows: rows))
    let sink = ThemePtySink()
    session.setOnWritePty { data in sink.append(data) }
    return (session, sink)
}

@Test func reThemingPushesTheNewDefaultsIntoTheVT() throws {
    let (session, _) = try makeThemedSession()
    try session.setTheme(.light)

    let background = session.colorForTesting(GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT)
    let expected = Theme.light.terminalBackground.bytes
    #expect(background.r == expected.r)
    #expect(background.g == expected.g)
    #expect(background.b == expected.b)

    let palette = session.paletteForTesting(GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT)
    for (index, color) in Theme.light.terminalPalette16.enumerated() {
        let want = color.bytes
        #expect(palette[index].r == want.r, "slot \(index) red")
        #expect(palette[index].g == want.g, "slot \(index) green")
        #expect(palette[index].b == want.b, "slot \(index) blue")
    }
}

/// libghostty's colour options set the *default*; a program's own OSC override wins and must
/// survive. That guarantee is why the toggle re-themes through the VT rather than the renderer.
@Test func anOSCOverrideSurvivesAReTheme() throws {
    let (session, _) = try makeThemedSession()
    // OSC 11: the program picks its own background.
    session.write(ptyText: "\u{1b}]11;rgb:ff/00/00\u{1b}\\")

    try session.setTheme(.light)

    let effective = session.colorForTesting(GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND)
    #expect(effective.r == 255 && effective.g == 0 && effective.b == 0,
            "a theme change must not stomp the program's own background")
    // …while the default underneath it did move.
    let fallback = session.colorForTesting(GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT)
    #expect(fallback.r == Theme.light.terminalBackground.bytes.r)
}

@Test func theColorSchemeQueryFollowsTheTheme() throws {
    let (session, sink) = try makeThemedSession()
    // The default preset is dark, so the reply says dark (1).
    session.write(ptyText: "\u{1b}[?996n")
    #expect(sink.text == "\u{1b}[?997;1n")

    sink.reset()
    try session.setTheme(.light)
    session.write(ptyText: "\u{1b}[?996n")
    #expect(sink.text == "\u{1b}[?997;2n")
}

/// Unsolicited reports are gated on mode 2031; the vendored header is explicit about it. Claude
/// Code sets 2031 at startup, which is what lets it re-render for the new scheme unprompted.
@Test func aThemeChangeReportsOnlyWhenMode2031IsSet() throws {
    let (quiet, quietSink) = try makeThemedSession()
    try quiet.setTheme(.light)
    #expect(quietSink.isEmpty, "no unsolicited report without mode 2031")

    let (session, sink) = try makeThemedSession()
    session.write(ptyText: "\u{1b}[?2031h")
    sink.reset()
    try session.setTheme(.light)
    #expect(sink.text == "\u{1b}[?997;2n")
}

/// The guard for "which parts of `applyOptions` must not re-run": a re-theme re-applies only the
/// colour options, so scrollback (and the continuation tracking a snapshot depends on) is untouched.
@Test func reThemingLeavesScrollbackAlone() throws {
    let (session, _) = try makeThemedSession(cols: 20, rows: 4)
    for line in 0..<50 { session.write(ptyText: "line \(line)\r\n") }
    let before = session.scrollbackRows
    #expect(before > 0)

    try session.setTheme(.light)

    #expect(session.scrollbackRows == before)
}

/// The reported colour scheme follows the theme by construction rather than by every call site
/// remembering to pass it — it used to default to `true` and was set by nobody, so a light theme
/// would still have told Claude Code "dark".
@Test func theColorSchemeDefaultsFromTheTheme() {
    #expect(TerminalSessionOptions(theme: .light).darkColorScheme == false)
    #expect(TerminalSessionOptions(theme: .midnightIndigo).darkColorScheme)
    // An explicit value still wins, for a caller that genuinely wants to say otherwise.
    #expect(TerminalSessionOptions(theme: .light, darkColorScheme: true).darkColorScheme)
}
