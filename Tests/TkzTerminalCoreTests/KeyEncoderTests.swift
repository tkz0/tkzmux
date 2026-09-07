// KeyEncoderTests.swift — the encoder half of M1.7 (TKZ-13), headless.
//
// Also generates docs/keys.md: `TKZMUX_UPDATE_KEYS_DOC=1 swift test --filter TkzTerminalCoreTests`
// rewrites the doc, a plain run asserts the committed doc still matches the encoder.
import Foundation
import GhosttyVt
import Testing

@testable import TkzTerminalCore

// MARK: - Helpers

/// A terminal in a known mode. `kitty` feeds `CSI > 1 u` (the disambiguate flag), which is exactly
/// what Claude Code requests; `applicationCursorKeys` sets DECCKM (mode 1).
private func makeTerminal(kitty: Bool = false, applicationCursorKeys: Bool = false) throws
    -> GhosttyTerminalHandle
{
    let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
    if kitty { terminal.write("\u{1b}[>1u") }
    if applicationCursorKeys { terminal.write("\u{1b}[?1h") }
    return terminal
}

private func encode(
    _ press: KeyPress,
    kitty: Bool = false,
    applicationCursorKeys: Bool = false,
    optionAsAlt: OptionAsAlt = .never
) throws -> [UInt8] {
    let terminal = try makeTerminal(kitty: kitty, applicationCursorKeys: applicationCursorKeys)
    let encoder = try KeyEncoder()
    return try encoder.encode(press, terminal: terminal, optionAsAlt: optionAsAlt)
}

private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

// MARK: - Acceptance criteria

@Test("Shift+Enter is CSI 13;2u with kitty flags on, and the fixterm form without")
func shiftEnter() throws {
    let press = KeyPress(key: GHOSTTY_KEY_ENTER, mods: [.shift], consumedMods: [.shift])
    // The behaviour Claude Code depends on: kitty disambiguate on → CSI 13;2u.
    #expect(try encode(press, kitty: true) == bytes("\u{1b}[13;2u"))
    // In legacy mode libghostty does NOT collapse Shift+Enter to CR: its PC-style function-key
    // table (src/input/function_keys.zig) maps shift+enter to the fixterm CSI 27;2;13~ form, so
    // shift+enter stays distinguishable even without the kitty protocol. Plain Enter is CR.
    #expect(try encode(press) == bytes("\u{1b}[27;2;13~"))
    #expect(try encode(KeyPress(key: GHOSTTY_KEY_ENTER)) == [0x0D])
    #expect(try encode(KeyPress(key: GHOSTTY_KEY_ENTER), kitty: true) == [0x0D])
}

/// Ctrl+<letter> as the view layer will actually deliver it: `event.characters` would be the C0
/// control, so the view re-reads it without Control and passes the plain letter.
private func controlLetter(_ key: GhosttyKey, _ letter: String) -> KeyPress {
    KeyPress(
        key: key,
        mods: [.control],
        consumedMods: [],  // control never contributes to the translation
        text: letter,
        unshiftedCodepoint: letter.unicodeScalars.first!.value
    )
}

@Test("Ctrl-C and Ctrl-A encode as C0 controls")
func controlLetters() throws {
    #expect(try encode(controlLetter(GHOSTTY_KEY_C, "c")) == [0x03])
    #expect(try encode(controlLetter(GHOSTTY_KEY_A, "a")) == [0x01])

    // The unfiltered form the view must never send (\x03 is a C0 control) is neutralised by
    // KeyEncoder.filteredText and encodes identically — the safety net changes nothing.
    let raw = KeyPress(key: GHOSTTY_KEY_C, mods: [.control], text: "\u{03}", unshiftedCodepoint: 0x63)
    let empty = KeyPress(key: GHOSTTY_KEY_C, mods: [.control], unshiftedCodepoint: 0x63)
    #expect(try encode(raw) == [0x03])
    #expect(try encode(empty) == [0x03])
}

@Test("Shift+Tab survives the C0 text AppKit reports for it")
func shiftTab() throws {
    // macOS reports Shift+Tab's characters as U+0019, and subtracting .control does not change
    // that — so the view-side filter rule alone is not enough; filteredText is load-bearing here.
    let press = KeyPress(
        key: GHOSTTY_KEY_TAB, mods: [.shift], consumedMods: [.shift], text: "\u{19}")
    #expect(try encode(press) == bytes("\u{1b}[Z"))
    #expect(try encode(press, kitty: true) == bytes("\u{1b}[9;2u"))
}

/// Build Option+<letter> exactly the way the AppKit layer must: the text (and therefore the
/// consumed modifiers) depend on whether Option is acting as Alt for this press.
///
/// - Parameter composed: what the layout produces *with* Option (US layout: Option+B → "∫").
/// - Parameter plain: what it produces *without* Option ("b").
private func optionLetter(
    _ key: GhosttyKey,
    plain: String,
    composed: String,
    rightSide: Bool = false,
    optionAsAlt: OptionAsAlt
) -> KeyPress {
    var mods: KeyModifiers = [.alt]
    if rightSide { mods.insert(.altRight) }
    let translationMods = KeyEncoder.translationModifiers(for: mods, optionAsAlt: optionAsAlt)
    return KeyPress(
        key: key,
        mods: mods,
        consumedMods: translationMods.subtracting([.control, .super_]),
        text: translationMods.contains(.alt) ? composed : plain,
        unshiftedCodepoint: plain.unicodeScalars.first?.value ?? 0
    )
}

@Test("Option+B is ESC b when option-as-alt is on, and the composed character when off")
func optionAsAltBehaviour() throws {
    // With option-as-alt on, the view translates *without* Option, so text is "b" and Option is
    // left unconsumed; libghostty then keeps `alt` in the effective mods and adds the ESC prefix.
    let asAlt = optionLetter(GHOSTTY_KEY_B, plain: "b", composed: "∫", optionAsAlt: .both)
    #expect(try encode(asAlt, optionAsAlt: .both) == bytes("\u{1b}b"))

    // With it off, macOS composes U+222B INTEGRAL and reports Option as consumed; the encoder
    // passes the composed character straight through.
    let composed = optionLetter(GHOSTTY_KEY_B, plain: "b", composed: "∫", optionAsAlt: .never)
    #expect(try encode(composed, optionAsAlt: .never) == bytes("∫"))
}

@Test("Consuming Option would swallow the ESC prefix")
func optionMustNotBeConsumedWhenActingAsAlt() throws {
    // The trap the view layer must avoid: reporting Option as consumed while asking for
    // option-as-alt. libghostty's effectiveMods = mods − consumedMods (whenever text is
    // non-empty), so the alt prefix silently disappears.
    let wrong = KeyPress(
        key: GHOSTTY_KEY_B, mods: [.alt], consumedMods: [.alt], text: "b", unshiftedCodepoint: 0x62)
    #expect(try encode(wrong, optionAsAlt: .both) == bytes("b"))
}

@Test("Option side bits select which Option acts as Alt")
func optionAsAltSides() throws {
    let left: KeyModifiers = [.alt]
    let right: KeyModifiers = [.alt, .altRight]
    #expect(OptionAsAlt.both.applies(to: left))
    #expect(OptionAsAlt.both.applies(to: right))
    #expect(OptionAsAlt.left.applies(to: left))
    #expect(!OptionAsAlt.left.applies(to: right))
    #expect(!OptionAsAlt.right.applies(to: left))
    #expect(OptionAsAlt.right.applies(to: right))
    #expect(!OptionAsAlt.both.applies(to: []))

    for setting in [OptionAsAlt.left, .right] {
        for onRight in [false, true] {
            let press = optionLetter(
                GHOSTTY_KEY_B, plain: "b", composed: "∫", rightSide: onRight, optionAsAlt: setting)
            let expected = setting.applies(to: press.mods) ? bytes("\u{1b}b") : bytes("∫")
            #expect(try encode(press, optionAsAlt: setting) == expected, "\(setting) right=\(onRight)")
        }
    }
}

@Test("translationModifiers drops Option only when it acts as Alt")
func translationModifiers() throws {
    #expect(KeyEncoder.translationModifiers(for: [.alt], optionAsAlt: .both) == [])
    #expect(KeyEncoder.translationModifiers(for: [.alt], optionAsAlt: .never) == [.alt])
    #expect(KeyEncoder.translationModifiers(for: [.alt, .altRight], optionAsAlt: .left) == [.alt, .altRight])
    #expect(KeyEncoder.translationModifiers(for: [.alt, .altRight], optionAsAlt: .right) == [])
    #expect(KeyEncoder.translationModifiers(for: [.shift, .control], optionAsAlt: .both) == [.shift, .control])
}

@Test("Arrows follow DECCKM (application vs normal cursor keys)")
func cursorKeyMode() throws {
    let up = KeyPress(key: GHOSTTY_KEY_ARROW_UP)
    let down = KeyPress(key: GHOSTTY_KEY_ARROW_DOWN)
    #expect(try encode(up) == bytes("\u{1b}[A"))
    #expect(try encode(down) == bytes("\u{1b}[B"))
    #expect(try encode(up, applicationCursorKeys: true) == bytes("\u{1b}OA"))
    #expect(try encode(down, applicationCursorKeys: true) == bytes("\u{1b}OB"))
}

@Test("option-as-alt survives setopt_from_terminal, which resets it")
func optionAsAltIsReappliedEveryCall() throws {
    // encoder.h: setopt_from_terminal "cannot be determined from terminal state and is reset to
    // GHOSTTY_OPTION_AS_ALT_FALSE by this call". Re-using one encoder across calls must not leak
    // the previous option-as-alt setting, and must not lose the requested one.
    let terminal = try makeTerminal()
    let encoder = try KeyEncoder()
    let asAlt = optionLetter(GHOSTTY_KEY_B, plain: "b", composed: "∫", optionAsAlt: .both)
    let composed = optionLetter(GHOSTTY_KEY_B, plain: "b", composed: "∫", optionAsAlt: .never)

    #expect(try encoder.encode(asAlt, terminal: terminal, optionAsAlt: .both) == bytes("\u{1b}b"))
    #expect(try encoder.encode(composed, terminal: terminal, optionAsAlt: .never) == bytes("∫"))
    #expect(try encoder.encode(asAlt, terminal: terminal, optionAsAlt: .both) == bytes("\u{1b}b"))
}

// MARK: - Encoder mechanics

@Test("A reused encoder does not carry state between presses")
func reusedEncoderIsClean() throws {
    let terminal = try makeTerminal()
    let encoder = try KeyEncoder()
    let ctrlC = controlLetter(GHOSTTY_KEY_C, "c")
    let plainC = KeyPress(key: GHOSTTY_KEY_C, text: "c", unshiftedCodepoint: 0x63)

    #expect(try encoder.encode(ctrlC, terminal: terminal) == [0x03])
    #expect(try encoder.encode(plainC, terminal: terminal) == bytes("c"))
    #expect(try encoder.encode(ctrlC, terminal: terminal) == [0x03])
}

@Test("Empty output is a normal result, not an error")
func emptyResults() throws {
    // A bare modifier press produces nothing in legacy mode …
    let shift = KeyPress(key: GHOSTTY_KEY_SHIFT_LEFT, mods: [.shift])
    #expect(try encode(shift).isEmpty)
    // … and neither does a release.
    let release = KeyPress(action: .release, key: GHOSTTY_KEY_A, text: "a", unshiftedCodepoint: 0x61)
    #expect(try encode(release).isEmpty)
    // A composing key must not echo its preedit to the pty.
    let composing = KeyPress(key: GHOSTTY_KEY_E, text: "e", unshiftedCodepoint: 0x65, composing: true)
    #expect(try encode(composing).isEmpty)
}

@Test("Key repeat encodes like a press in legacy mode")
func repeatAction() throws {
    let press = KeyPress(action: .repeated, key: GHOSTTY_KEY_A, text: "a", unshiftedCodepoint: 0x61)
    #expect(try encode(press) == bytes("a"))
}

@Test("Text is filtered of C0 controls, DEL and the macOS function-key PUA range")
func textFiltering() throws {
    #expect(KeyEncoder.filteredText("\u{03}") == "")
    #expect(KeyEncoder.filteredText("\u{7f}") == "")
    #expect(KeyEncoder.filteredText("\u{F700}") == "")
    #expect(KeyEncoder.filteredText("\u{F8FF}") == "")
    #expect(KeyEncoder.filteredText("a") == "a")
    #expect(KeyEncoder.filteredText("∫") == "∫")

    // Unfiltered PUA text must not reach the pty even if the view layer forgets.
    let bad = KeyPress(key: GHOSTTY_KEY_ARROW_UP, text: "\u{F700}")
    #expect(try encode(bad) == bytes("\u{1b}[A"))
}

// MARK: - Keycode table

@Test("The macOS keycode table maps representative keys")
func keycodeTable() throws {
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x00) == GHOSTTY_KEY_A)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x06) == GHOSTTY_KEY_Z)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x1D) == GHOSTTY_KEY_DIGIT_0)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x24) == GHOSTTY_KEY_ENTER)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x30) == GHOSTTY_KEY_TAB)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x31) == GHOSTTY_KEY_SPACE)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x33) == GHOSTTY_KEY_BACKSPACE)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x35) == GHOSTTY_KEY_ESCAPE)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x3F) == GHOSTTY_KEY_FN)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x4C) == GHOSTTY_KEY_NUMPAD_ENTER)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x75) == GHOSTTY_KEY_DELETE)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x7A) == GHOSTTY_KEY_F1)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x6F) == GHOSTTY_KEY_F12)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x5A) == GHOSTTY_KEY_F20)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x7B) == GHOSTTY_KEY_ARROW_LEFT)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x7E) == GHOSTTY_KEY_ARROW_UP)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x0A) == GHOSTTY_KEY_INTL_BACKSLASH)
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0x66) == GHOSTTY_KEY_UNIDENTIFIED)  // JIS eisu
    #expect(MacKeyCodes.key(forVirtualKeyCode: 0xFF) == GHOSTTY_KEY_UNIDENTIFIED)
}

@Test("Every side of every modifier key has its own keycode")
func modifierKeycodes() throws {
    let sided: [(UInt16, GhosttyKey)] = [
        (0x38, GHOSTTY_KEY_SHIFT_LEFT), (0x3C, GHOSTTY_KEY_SHIFT_RIGHT),
        (0x3B, GHOSTTY_KEY_CONTROL_LEFT), (0x3E, GHOSTTY_KEY_CONTROL_RIGHT),
        (0x3A, GHOSTTY_KEY_ALT_LEFT), (0x3D, GHOSTTY_KEY_ALT_RIGHT),
        (0x37, GHOSTTY_KEY_META_LEFT), (0x36, GHOSTTY_KEY_META_RIGHT),
        (0x39, GHOSTTY_KEY_CAPS_LOCK), (0x3F, GHOSTTY_KEY_FN),
    ]
    for (code, key) in sided {
        #expect(MacKeyCodes.key(forVirtualKeyCode: code) == key, "keycode 0x\(String(code, radix: 16))")
    }
}

@Test("The keycode table has no duplicate GhosttyKey values")
func keycodeTableIsInjective() throws {
    var seen: [UInt32: UInt16] = [:]
    for code in UInt16(0)...UInt16(0x7F) {
        let key = MacKeyCodes.key(forVirtualKeyCode: code)
        guard key != GHOSTTY_KEY_UNIDENTIFIED else { continue }
        if let previous = seen[key.rawValue] {
            Issue.record("keycodes 0x\(String(previous, radix: 16)) and 0x\(String(code, radix: 16)) map to the same key")
        }
        seen[key.rawValue] = code
    }
    // Sanity: the table is substantially populated (letters, digits, punctuation, F-keys, numpad …).
    #expect(seen.count > 100)
}

// MARK: - docs/keys.md

/// One documented row: a label, the press, and the option-as-alt setting used for it.
private struct DocRow {
    let label: String
    let press: KeyPress
    let optionAsAlt: OptionAsAlt

    init(_ label: String, _ press: KeyPress, optionAsAlt: OptionAsAlt = .never) {
        self.label = label
        self.press = press
        self.optionAsAlt = optionAsAlt
    }
}

/// `cat -v`-ish escaping: `\e`, `\r`, `\n`, `\t`, `\xNN` for other controls, raw UTF-8 otherwise.
private func escaped(_ bytes: [UInt8]) -> String {
    guard !bytes.isEmpty else { return "(nothing)" }
    var out = ""
    var index = bytes.startIndex
    while index < bytes.endIndex {
        let byte = bytes[index]
        switch byte {
        case 0x1B: out += "\\e"
        case 0x0D: out += "\\r"
        case 0x0A: out += "\\n"
        case 0x09: out += "\\t"
        case 0x00...0x1F, 0x7F: out += String(format: "\\x%02x", byte)
        case 0x20: out += "\\x20"
        case 0x80...0xFF:
            // Multi-byte UTF-8: emit the whole scalar as-is.
            let rest = Array(bytes[index...])
            out += String(decoding: rest, as: UTF8.self)
            index = bytes.endIndex
            continue
        default: out.append(Character(UnicodeScalar(byte)))
        }
        index += 1
    }
    return out
}

private func docRows() -> [(section: String, rows: [DocRow])] {
    func plain(_ key: GhosttyKey, text: String = "", codepoint: UInt32 = 0) -> KeyPress {
        KeyPress(key: key, text: text, unshiftedCodepoint: codepoint)
    }

    let navigation: [DocRow] = [
        .init("Up", plain(GHOSTTY_KEY_ARROW_UP)),
        .init("Down", plain(GHOSTTY_KEY_ARROW_DOWN)),
        .init("Right", plain(GHOSTTY_KEY_ARROW_RIGHT)),
        .init("Left", plain(GHOSTTY_KEY_ARROW_LEFT)),
        .init("Shift+Up", KeyPress(key: GHOSTTY_KEY_ARROW_UP, mods: [.shift], consumedMods: [.shift])),
        .init("Ctrl+Right", KeyPress(key: GHOSTTY_KEY_ARROW_RIGHT, mods: [.control])),
        .init("Home", plain(GHOSTTY_KEY_HOME)),
        .init("End", plain(GHOSTTY_KEY_END)),
        .init("PageUp", plain(GHOSTTY_KEY_PAGE_UP)),
        .init("PageDown", plain(GHOSTTY_KEY_PAGE_DOWN)),
        .init("Insert", plain(GHOSTTY_KEY_INSERT)),
    ]

    let functionKeys: [DocRow] = [
        GHOSTTY_KEY_F1, GHOSTTY_KEY_F2, GHOSTTY_KEY_F3, GHOSTTY_KEY_F4, GHOSTTY_KEY_F5,
        GHOSTTY_KEY_F6, GHOSTTY_KEY_F7, GHOSTTY_KEY_F8, GHOSTTY_KEY_F9, GHOSTTY_KEY_F10,
        GHOSTTY_KEY_F11, GHOSTTY_KEY_F12,
    ].enumerated().map { index, key in DocRow("F\(index + 1)", plain(key)) }

    let editing: [DocRow] = [
        .init("Enter", plain(GHOSTTY_KEY_ENTER)),
        .init("Shift+Enter", KeyPress(key: GHOSTTY_KEY_ENTER, mods: [.shift], consumedMods: [.shift])),
        .init("Escape", plain(GHOSTTY_KEY_ESCAPE)),
        .init("Tab", plain(GHOSTTY_KEY_TAB)),
        .init("Shift+Tab", KeyPress(key: GHOSTTY_KEY_TAB, mods: [.shift], consumedMods: [.shift])),
        .init("Backspace", plain(GHOSTTY_KEY_BACKSPACE)),
        .init("Shift+Backspace", KeyPress(key: GHOSTTY_KEY_BACKSPACE, mods: [.shift], consumedMods: [.shift])),
        .init("Ctrl+Backspace", KeyPress(key: GHOSTTY_KEY_BACKSPACE, mods: [.control])),
        .init("Delete (forward)", plain(GHOSTTY_KEY_DELETE)),
        .init("Space", plain(GHOSTTY_KEY_SPACE, text: " ", codepoint: 0x20)),
    ]

    // Ctrl-A … Ctrl-Z, in the shape the view layer produces: `event.characters` would be the C0
    // control, which key/event.h forbids passing, so the view re-reads the key without Control
    // and hands over the plain letter.
    let letterKeys: [GhosttyKey] = [
        GHOSTTY_KEY_A, GHOSTTY_KEY_B, GHOSTTY_KEY_C, GHOSTTY_KEY_D, GHOSTTY_KEY_E, GHOSTTY_KEY_F,
        GHOSTTY_KEY_G, GHOSTTY_KEY_H, GHOSTTY_KEY_I, GHOSTTY_KEY_J, GHOSTTY_KEY_K, GHOSTTY_KEY_L,
        GHOSTTY_KEY_M, GHOSTTY_KEY_N, GHOSTTY_KEY_O, GHOSTTY_KEY_P, GHOSTTY_KEY_Q, GHOSTTY_KEY_R,
        GHOSTTY_KEY_S, GHOSTTY_KEY_T, GHOSTTY_KEY_U, GHOSTTY_KEY_V, GHOSTTY_KEY_W, GHOSTTY_KEY_X,
        GHOSTTY_KEY_Y, GHOSTTY_KEY_Z,
    ]
    let control: [DocRow] = letterKeys.enumerated().map { index, key in
        let letter = String(UnicodeScalar(UInt8(0x61 + index)))
        return DocRow("Ctrl+\(letter.uppercased())", controlLetter(key, letter))
    }

    // Option+letter. The composed text is a *US layout* sample — the encoder never consults a
    // keyboard layout, the view layer supplies the string — so these rows show what the encoder
    // does with it on a US keyboard. Note the two cases feed *different* text and consumed mods,
    // exactly as the AppKit layer must (see KeyEncoder.translationModifiers).
    // Option+E/N are dead keys: no text, `composing` true.
    let usOptionLayout: [(GhosttyKey, String, String, Bool)] = [
        (GHOSTTY_KEY_A, "a", "å", false),
        (GHOSTTY_KEY_B, "b", "∫", false),
        (GHOSTTY_KEY_C, "c", "ç", false),
        (GHOSTTY_KEY_E, "e", "", true),
        (GHOSTTY_KEY_N, "n", "", true),
        (GHOSTTY_KEY_O, "o", "ø", false),
        (GHOSTTY_KEY_P, "p", "π", false),
        (GHOSTTY_KEY_S, "s", "ß", false),
    ]
    var option: [DocRow] = []
    for (key, plainText, composedText, composing) in usOptionLayout {
        for setting in [OptionAsAlt.both, .never] {
            let translationMods = KeyEncoder.translationModifiers(for: [.alt], optionAsAlt: setting)
            var press = KeyPress(
                key: key,
                mods: [.alt],
                consumedMods: translationMods.subtracting([.control, .super_]),
                text: translationMods.contains(.alt) ? composedText : plainText,
                unshiftedCodepoint: plainText.unicodeScalars.first?.value ?? 0,
                composing: composing && translationMods.contains(.alt)
            )
            if composing && !translationMods.contains(.alt) { press.text = plainText }
            let label = setting == .both ? "as alt" : "not as alt"
            option.append(DocRow("Option+\(plainText.uppercased()) — \(label)", press, optionAsAlt: setting))
        }
    }

    return [
        ("Cursor and navigation keys", navigation),
        ("Function keys", functionKeys),
        ("Editing keys", editing),
        ("Control + letter", control),
        ("Option + letter (US layout sample)", option),
    ]
}

private func generateKeysDoc() throws -> String {
    let legacyTerminal = try makeTerminal()
    let kittyTerminal = try makeTerminal(kitty: true)
    let applicationTerminal = try makeTerminal(applicationCursorKeys: true)
    let encoder = try KeyEncoder()

    var out = """
        # Keyboard encoding matrix

        **Generated — do not edit by hand.** Every cell below is produced by
        `TkzTerminalCore.KeyEncoder` (libghostty-vt's key encoder) in
        `Tests/TkzTerminalCoreTests/KeyEncoderTests.swift`. A normal `swift test --filter \
        TkzTerminalCoreTests` asserts this file still matches the encoder; regenerate it with:

        ```sh
        TKZMUX_UPDATE_KEYS_DOC=1 swift test --filter TkzTerminalCoreTests
        ```

        ## Columns

        | Column | Terminal state |
        |---|---|
        | **legacy** | a fresh terminal: no kitty protocol, DECCKM off |
        | **kitty** | after `CSI > 1 u` (kitty `disambiguate` flag) — what Claude Code requests |
        | **DECCKM** | after `CSI ? 1 h` (application cursor keys), legacy protocol; cursor keys only |

        Escaping is `cat -v`-ish: `\\e` = ESC (0x1b), `\\r` = 0x0d, `\\t` = 0x09, `\\xNN` for any
        other control byte and for the space character, everything else verbatim UTF-8.
        `(nothing)` means the encoder produced zero bytes — a normal outcome, not an error.

        The two Option rows per key are not the same input encoded twice. With Option acting as
        Alt the view translates the key *without* Option, so `text` is the plain letter and Option
        stays unconsumed; with it off, `text` is the composed character and Option is consumed.
        `KeyEncoder.translationModifiers(for:optionAsAlt:)` makes that choice. The composed
        characters here are a US-layout sample supplied by the test — this encoder never reads a
        keyboard layout.

        Note that libghostty does *not* collapse Shift+Enter to CR in legacy mode: its PC-style
        function-key table encodes it as the fixterm `CSI 27;2;13~`. Plain Enter is CR in both
        modes, as the kitty spec requires.


        """

    for (section, rows) in docRows() {
        let includeCursorColumn = section == "Cursor and navigation keys"
        out += "## \(section)\n\n"
        out += includeCursorColumn
            ? "| Key | legacy | kitty | DECCKM |\n|---|---|---|---|\n"
            : "| Key | legacy | kitty |\n|---|---|---|\n"
        for row in rows {
            let legacy = try encoder.encode(row.press, terminal: legacyTerminal, optionAsAlt: row.optionAsAlt)
            let kitty = try encoder.encode(row.press, terminal: kittyTerminal, optionAsAlt: row.optionAsAlt)
            out += "| \(row.label) | `\(escaped(legacy))` | `\(escaped(kitty))` |"
            if includeCursorColumn {
                let application = try encoder.encode(
                    row.press, terminal: applicationTerminal, optionAsAlt: row.optionAsAlt)
                out += " `\(escaped(application))` |"
            }
            out += "\n"
        }
        out += "\n"
    }
    return out
}

/// Repo root, from this file's path (`<root>/Tests/TkzTerminalCoreTests/KeyEncoderTests.swift`).
private func repoRoot(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
}

@Test("docs/keys.md matches what the encoder actually produces")
func keysDocIsCurrent() throws {
    let generated = try generateKeysDoc()
    let url = repoRoot().appendingPathComponent("docs/keys.md")

    if ProcessInfo.processInfo.environment["TKZMUX_UPDATE_KEYS_DOC"] != nil {
        try generated.write(to: url, atomically: true, encoding: .utf8)
        return
    }

    let committed = try String(contentsOf: url, encoding: .utf8)
    if committed != generated {
        let expectedLines = generated.split(separator: "\n", omittingEmptySubsequences: false)
        let actualLines = committed.split(separator: "\n", omittingEmptySubsequences: false)
        for index in 0..<max(expectedLines.count, actualLines.count) {
            let expected = index < expectedLines.count ? String(expectedLines[index]) : "<missing>"
            let actual = index < actualLines.count ? String(actualLines[index]) : "<missing>"
            if expected != actual {
                Issue.record(
                    """
                    docs/keys.md is stale at line \(index + 1).
                      committed: \(actual)
                      encoder:   \(expected)
                    Regenerate with TKZMUX_UPDATE_KEYS_DOC=1 swift test --filter TkzTerminalCoreTests
                    """)
                break
            }
        }
    }
    #expect(committed == generated)
}
