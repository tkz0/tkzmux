// LinuxKeyTranslatorTests — evdev table, translator and parity, headless, on both OSes (WOR-315 S1).
//
// The layout facts come from Fixtures/keymaps/<layout>.json, which Tests/LinuxKeymapTests compiles
// with libxkbcommon on Linux and commits, so nothing here links xkb and every test also runs on
// macOS. A keystroke is simulated the way GDK delivers it: the chord's modifier keys are pressed
// first (each with the state from before it), then the key with the chord's state.
//
// Bytes are always the real encoder's: `KeyEncoder` against a libghostty terminal in the mode a
// test names.
import Foundation
import GhosttyVt
import Testing

@testable import TkzTerminalCore

// MARK: - Fixtures

/// One layout fixture: chords (held modifier keys and the GDK state they give) and, per key, the
/// keyval under every chord plus the level-0 keyval.
private struct LayoutFixture: Decodable {
    struct Chord: Decodable {
        let name: String
        let locks: [UInt32]
        let held: [UInt32]
        let state: UInt32
        let numLock: Bool
    }

    struct Key: Decodable {
        let evdev: UInt32
        let xkb: String
        let level0: UInt32
        let keyvals: [UInt32]
    }

    let layout: String
    let variant: String
    let chords: [Chord]
    let keys: [Key]

    func chordIndex(_ name: String) throws -> Int {
        try #require(chords.firstIndex { $0.name == name }, "no chord \(name) in \(layout)(\(variant))")
    }

    func key(_ evdev: UInt32) throws -> Key {
        try #require(keys.first { $0.evdev == evdev }, "no key \(evdev) in \(layout)(\(variant))")
    }

    /// The facts GDK would report for `evdev` under chord `index`.
    func facts(_ evdev: UInt32, chord index: Int, isRelease: Bool = false) throws -> LinuxKeyFacts {
        let key = try key(evdev)
        let chord = chords[index]
        return LinuxKeyFacts(
            isRelease: isRelease, evdevCode: evdev, keyval: key.keyvals[index], levelZeroKeyval: key.level0,
            state: LinuxModifierMask(rawValue: chord.state))
    }

    /// Press the chord's modifier keys into `translator`, each with the state of the chord made of
    /// the keys before it (every prefix of a recorded chord is itself recorded).
    func pressModifiers(of index: Int, into translator: inout LinuxKeyTranslator) throws {
        let chord = chords[index]
        for (position, code) in chord.held.enumerated() {
            let prefix = Array(chord.held.prefix(position))
            let before = try #require(
                chords.firstIndex { $0.locks == chord.locks && $0.held == prefix },
                "no prefix chord for \(chord.name)")
            _ = translator.translate(try facts(code, chord: before))
        }
    }
}

private let layoutFiles = ["se", "us", "us-intl", "de", "fr"]

private func fixturesDirectory(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Fixtures")
}

private func loadLayout(_ file: String) throws -> LayoutFixture {
    let url = fixturesDirectory().appendingPathComponent("keymaps/\(file).json")
    return try JSONDecoder().decode(LayoutFixture.self, from: Data(contentsOf: url))
}

/// One keystroke: a fresh translator, the chord's modifiers, then `evdev` pressed.
private func type(_ evdev: UInt32, chord: String = "", in layout: LayoutFixture) throws -> KeyPress {
    var translator = LinuxKeyTranslator()
    let index = try layout.chordIndex(chord)
    try layout.pressModifiers(of: index, into: &translator)
    return translator.translate(try layout.facts(evdev, chord: index))
}

// MARK: - Encoding helpers

private enum Mode: CaseIterable {
    case legacy, kitty1, kitty5
}

private func encode(_ press: KeyPress, _ mode: Mode = .legacy, applicationCursorKeys: Bool = false) throws -> [UInt8] {
    let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
    switch mode {
    case .legacy: break
    case .kitty1: terminal.write("\u{1b}[>1u")
    case .kitty5: terminal.write("\u{1b}[>5u")
    }
    if applicationCursorKeys { terminal.write("\u{1b}[?1h") }
    return try KeyEncoder().encode(press, terminal: terminal)
}

private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

// evdev codes the tests name (input-event-codes.h).
private let KEY_ESC: UInt32 = 1, KEY_1: UInt32 = 2, KEY_4: UInt32 = 5, KEY_5: UInt32 = 6
private let KEY_7: UInt32 = 8, KEY_8: UInt32 = 9, KEY_9: UInt32 = 10, KEY_0: UInt32 = 11
private let KEY_MINUS: UInt32 = 12, KEY_EQUAL: UInt32 = 13, KEY_TAB: UInt32 = 15, KEY_Q: UInt32 = 16
private let KEY_LEFTBRACE: UInt32 = 26, KEY_RIGHTBRACE: UInt32 = 27, KEY_A: UInt32 = 30
private let KEY_APOSTROPHE: UInt32 = 40, KEY_C: UInt32 = 46, KEY_B: UInt32 = 48, KEY_SPACE: UInt32 = 57
private let KEY_KP8: UInt32 = 72, KEY_KP1: UInt32 = 79, KEY_KPDOT: UInt32 = 83, KEY_UP: UInt32 = 103

// MARK: - The evdev table

@Test("the evdev table maps representative keys")
func linuxEvdevTable() {
    let cases: [(UInt32, GhosttyKey)] = [
        (30, GHOSTTY_KEY_A), (44, GHOSTTY_KEY_Z), (16, GHOSTTY_KEY_Q), (11, GHOSTTY_KEY_DIGIT_0),
        (2, GHOSTTY_KEY_DIGIT_1), (28, GHOSTTY_KEY_ENTER), (15, GHOSTTY_KEY_TAB), (57, GHOSTTY_KEY_SPACE),
        (14, GHOSTTY_KEY_BACKSPACE), (1, GHOSTTY_KEY_ESCAPE), (111, GHOSTTY_KEY_DELETE), (110, GHOSTTY_KEY_INSERT),
        (103, GHOSTTY_KEY_ARROW_UP), (105, GHOSTTY_KEY_ARROW_LEFT), (59, GHOSTTY_KEY_F1), (88, GHOSTTY_KEY_F12),
        (183, GHOSTTY_KEY_F13), (194, GHOSTTY_KEY_F24), (96, GHOSTTY_KEY_NUMPAD_ENTER),
        (0x1D0, GHOSTTY_KEY_FN), (99, GHOSTTY_KEY_PRINT_SCREEN),
    ]
    for (code, key) in cases {
        #expect(LinuxKeyCodes.key(forEvdevCode: code) == key, "KEY \(code)")
    }
    #expect(LinuxKeyCodes.key(forEvdevCode: 0) == GHOSTTY_KEY_UNIDENTIFIED)       // KEY_RESERVED
    #expect(LinuxKeyCodes.key(forEvdevCode: 122) == GHOSTTY_KEY_UNIDENTIFIED)     // KEY_HANGEUL
    #expect(LinuxKeyCodes.key(forEvdevCode: 0x2FF) == GHOSTTY_KEY_UNIDENTIFIED)
}

@Test("the spec's coverage: numpad, F1-F24, 102ND, RO, YEN, HENKAN/MUHENKAN, COMPOSE")
func linuxEvdevTableCoverage() {
    let numpad: [(UInt32, GhosttyKey)] = [
        (82, GHOSTTY_KEY_NUMPAD_0), (79, GHOSTTY_KEY_NUMPAD_1), (80, GHOSTTY_KEY_NUMPAD_2),
        (81, GHOSTTY_KEY_NUMPAD_3), (75, GHOSTTY_KEY_NUMPAD_4), (76, GHOSTTY_KEY_NUMPAD_5),
        (77, GHOSTTY_KEY_NUMPAD_6), (71, GHOSTTY_KEY_NUMPAD_7), (72, GHOSTTY_KEY_NUMPAD_8),
        (73, GHOSTTY_KEY_NUMPAD_9), (83, GHOSTTY_KEY_NUMPAD_DECIMAL), (55, GHOSTTY_KEY_NUMPAD_MULTIPLY),
        (78, GHOSTTY_KEY_NUMPAD_ADD), (74, GHOSTTY_KEY_NUMPAD_SUBTRACT), (98, GHOSTTY_KEY_NUMPAD_DIVIDE),
        (96, GHOSTTY_KEY_NUMPAD_ENTER), (117, GHOSTTY_KEY_NUMPAD_EQUAL), (121, GHOSTTY_KEY_NUMPAD_COMMA),
        (69, GHOSTTY_KEY_NUM_LOCK),
    ]
    for (code, key) in numpad { #expect(LinuxKeyCodes.key(forEvdevCode: code) == key, "KEY \(code)") }

    // F1-F10 are 59-68, F11/F12 87/88, F13-F24 183-194.
    let fKeys = Array(UInt32(59)...68) + [87, 88] + Array(UInt32(183)...194)
    for (index, code) in fKeys.enumerated() {
        let expected = GhosttyKey(rawValue: GHOSTTY_KEY_F1.rawValue + GhosttyKey.RawValue(index))
        #expect(LinuxKeyCodes.key(forEvdevCode: code) == expected, "F\(index + 1)")
    }

    #expect(LinuxKeyCodes.key(forEvdevCode: 86) == GHOSTTY_KEY_INTL_BACKSLASH)   // KEY_102ND
    #expect(LinuxKeyCodes.key(forEvdevCode: 89) == GHOSTTY_KEY_INTL_RO)          // KEY_RO
    #expect(LinuxKeyCodes.key(forEvdevCode: 124) == GHOSTTY_KEY_INTL_YEN)        // KEY_YEN
    #expect(LinuxKeyCodes.key(forEvdevCode: 92) == GHOSTTY_KEY_CONVERT)          // KEY_HENKAN
    #expect(LinuxKeyCodes.key(forEvdevCode: 94) == GHOSTTY_KEY_NON_CONVERT)      // KEY_MUHENKAN
    #expect(LinuxKeyCodes.key(forEvdevCode: 127) == GHOSTTY_KEY_CONTEXT_MENU)    // KEY_COMPOSE
}

@Test("both sides of every modifier key have their own code")
func linuxEvdevModifierSides() {
    let sided: [(UInt32, GhosttyKey)] = [
        (42, GHOSTTY_KEY_SHIFT_LEFT), (54, GHOSTTY_KEY_SHIFT_RIGHT),
        (29, GHOSTTY_KEY_CONTROL_LEFT), (97, GHOSTTY_KEY_CONTROL_RIGHT),
        (56, GHOSTTY_KEY_ALT_LEFT), (100, GHOSTTY_KEY_ALT_RIGHT),
        (125, GHOSTTY_KEY_META_LEFT), (126, GHOSTTY_KEY_META_RIGHT),
        (58, GHOSTTY_KEY_CAPS_LOCK),
    ]
    for (code, key) in sided { #expect(LinuxKeyCodes.key(forEvdevCode: code) == key, "KEY \(code)") }
    for code in [LinuxKeyCodes.rightShift, LinuxKeyCodes.rightCtrl, LinuxKeyCodes.rightAlt, LinuxKeyCodes.rightMeta] {
        #expect(LinuxKeyCodes.isRightModifier(code))
    }
    for code in [LinuxKeyCodes.leftShift, LinuxKeyCodes.leftCtrl, LinuxKeyCodes.leftAlt, LinuxKeyCodes.leftMeta] {
        #expect(!LinuxKeyCodes.isRightModifier(code))
    }
}

@Test("the evdev table has no duplicate GhosttyKey values")
func linuxEvdevTableIsInjective() {
    var seen: [GhosttyKey.RawValue: UInt32] = [:]
    for code in UInt32(0)...0x2FF {
        let key = LinuxKeyCodes.key(forEvdevCode: code)
        guard key != GHOSTTY_KEY_UNIDENTIFIED else { continue }
        if let previous = seen[key.rawValue] {
            Issue.record("KEY \(previous) and KEY \(code) map to the same key")
        }
        seen[key.rawValue] = code
    }
    #expect(seen.count > 140)
}

/// The xkb key names of xkeyboard-config's `evdev` keycodes (`<AC01>` …) are positional, so they
/// check the evdev numbers independently of input-event-codes.h.
private let xkbNameToKey: [String: GhosttyKey] = {
    var map: [String: GhosttyKey] = [
        "TLDE": GHOSTTY_KEY_BACKQUOTE, "BKSL": GHOSTTY_KEY_BACKSLASH, "LSGT": GHOSTTY_KEY_INTL_BACKSLASH,
        "ESC": GHOSTTY_KEY_ESCAPE, "BKSP": GHOSTTY_KEY_BACKSPACE, "TAB": GHOSTTY_KEY_TAB,
        "RTRN": GHOSTTY_KEY_ENTER, "SPCE": GHOSTTY_KEY_SPACE, "CAPS": GHOSTTY_KEY_CAPS_LOCK,
        "LFSH": GHOSTTY_KEY_SHIFT_LEFT, "RTSH": GHOSTTY_KEY_SHIFT_RIGHT,
        "LCTL": GHOSTTY_KEY_CONTROL_LEFT, "RCTL": GHOSTTY_KEY_CONTROL_RIGHT,
        "LALT": GHOSTTY_KEY_ALT_LEFT, "RALT": GHOSTTY_KEY_ALT_RIGHT,
        "LWIN": GHOSTTY_KEY_META_LEFT, "RWIN": GHOSTTY_KEY_META_RIGHT,
        "COMP": GHOSTTY_KEY_CONTEXT_MENU, "NMLK": GHOSTTY_KEY_NUM_LOCK,
        "KPDL": GHOSTTY_KEY_NUMPAD_DECIMAL, "KPAD": GHOSTTY_KEY_NUMPAD_ADD,
        "KPSU": GHOSTTY_KEY_NUMPAD_SUBTRACT, "KPMU": GHOSTTY_KEY_NUMPAD_MULTIPLY,
        "KPDV": GHOSTTY_KEY_NUMPAD_DIVIDE, "KPEN": GHOSTTY_KEY_NUMPAD_ENTER, "KPEQ": GHOSTTY_KEY_NUMPAD_EQUAL,
        "HOME": GHOSTTY_KEY_HOME, "END": GHOSTTY_KEY_END, "PGUP": GHOSTTY_KEY_PAGE_UP,
        "PGDN": GHOSTTY_KEY_PAGE_DOWN, "INS": GHOSTTY_KEY_INSERT, "DELE": GHOSTTY_KEY_DELETE,
        "UP": GHOSTTY_KEY_ARROW_UP, "DOWN": GHOSTTY_KEY_ARROW_DOWN, "LEFT": GHOSTTY_KEY_ARROW_LEFT,
        "RGHT": GHOSTTY_KEY_ARROW_RIGHT,
    ]
    for index in 0..<12 {
        map[String(format: "FK%02d", index + 1)] = GhosttyKey(rawValue: GHOSTTY_KEY_F1.rawValue + GhosttyKey.RawValue(index))
    }
    let rows: [(String, [GhosttyKey])] = [
        ("AE", [GHOSTTY_KEY_DIGIT_1, GHOSTTY_KEY_DIGIT_2, GHOSTTY_KEY_DIGIT_3, GHOSTTY_KEY_DIGIT_4,
                GHOSTTY_KEY_DIGIT_5, GHOSTTY_KEY_DIGIT_6, GHOSTTY_KEY_DIGIT_7, GHOSTTY_KEY_DIGIT_8,
                GHOSTTY_KEY_DIGIT_9, GHOSTTY_KEY_DIGIT_0, GHOSTTY_KEY_MINUS, GHOSTTY_KEY_EQUAL]),
        ("AD", [GHOSTTY_KEY_Q, GHOSTTY_KEY_W, GHOSTTY_KEY_E, GHOSTTY_KEY_R, GHOSTTY_KEY_T, GHOSTTY_KEY_Y,
                GHOSTTY_KEY_U, GHOSTTY_KEY_I, GHOSTTY_KEY_O, GHOSTTY_KEY_P, GHOSTTY_KEY_BRACKET_LEFT,
                GHOSTTY_KEY_BRACKET_RIGHT]),
        ("AC", [GHOSTTY_KEY_A, GHOSTTY_KEY_S, GHOSTTY_KEY_D, GHOSTTY_KEY_F, GHOSTTY_KEY_G, GHOSTTY_KEY_H,
                GHOSTTY_KEY_J, GHOSTTY_KEY_K, GHOSTTY_KEY_L, GHOSTTY_KEY_SEMICOLON, GHOSTTY_KEY_QUOTE]),
        ("AB", [GHOSTTY_KEY_Z, GHOSTTY_KEY_X, GHOSTTY_KEY_C, GHOSTTY_KEY_V, GHOSTTY_KEY_B, GHOSTTY_KEY_N,
                GHOSTTY_KEY_M, GHOSTTY_KEY_COMMA, GHOSTTY_KEY_PERIOD, GHOSTTY_KEY_SLASH]),
    ]
    for (row, keys) in rows {
        for (index, key) in keys.enumerated() { map[row + (index < 9 ? "0" : "") + "\(index + 1)"] = key }
    }
    let keypad: [GhosttyKey] = [
        GHOSTTY_KEY_NUMPAD_0, GHOSTTY_KEY_NUMPAD_1, GHOSTTY_KEY_NUMPAD_2, GHOSTTY_KEY_NUMPAD_3,
        GHOSTTY_KEY_NUMPAD_4, GHOSTTY_KEY_NUMPAD_5, GHOSTTY_KEY_NUMPAD_6, GHOSTTY_KEY_NUMPAD_7,
        GHOSTTY_KEY_NUMPAD_8, GHOSTTY_KEY_NUMPAD_9,
    ]
    for (digit, key) in keypad.enumerated() { map["KP\(digit)"] = key }
    return map
}()

@Test("every fixture key's xkb name agrees with the evdev table")
func linuxEvdevTableMatchesXkbKeyNames() throws {
    let us = try loadLayout("us")
    for key in us.keys {
        let expected = try #require(xkbNameToKey[key.xkb], "no expectation for <\(key.xkb)> (KEY \(key.evdev))")
        #expect(LinuxKeyCodes.key(forEvdevCode: key.evdev) == expected, "<\(key.xkb)> = KEY \(key.evdev)")
    }
}

@Test("a keypad key is its navigation key when the keyval says so")
func linuxKeypadRemapByKeyval() {
    #expect(LinuxKeyCodes.key(forEvdevCode: KEY_KP8, keyval: LinuxKeysyms.kpUp) == GHOSTTY_KEY_NUMPAD_UP)
    #expect(LinuxKeyCodes.key(forEvdevCode: KEY_KP1, keyval: LinuxKeysyms.kpEnd) == GHOSTTY_KEY_NUMPAD_END)
    #expect(LinuxKeyCodes.key(forEvdevCode: KEY_KPDOT, keyval: LinuxKeysyms.kpDelete) == GHOSTTY_KEY_NUMPAD_DELETE)
    #expect(LinuxKeyCodes.key(forEvdevCode: KEY_KP8, keyval: 0xFFB8) == GHOSTTY_KEY_NUMPAD_8)   // KP_8
    // Only keypad keys are remapped: the arrow pad stays the arrow pad whatever the keyval.
    #expect(LinuxKeyCodes.key(forEvdevCode: KEY_UP, keyval: LinuxKeysyms.kpUp) == GHOSTTY_KEY_ARROW_UP)
}

// MARK: - Keysyms

@Test("keysym → Unicode covers Latin-1, the legacy table, Unicode keysyms and the keypad")
func linuxKeysymCodepoints() {
    #expect(LinuxKeysyms.codepoint(ofKeysym: 0x61) == 0x61)            // a
    #expect(LinuxKeysyms.codepoint(ofKeysym: 0xE5) == 0xE5)            // aring
    #expect(LinuxKeysyms.codepoint(ofKeysym: 0x20AC) == 0x20AC)        // EuroSign
    #expect(LinuxKeysyms.codepoint(ofKeysym: 0x1B3) == 0x142)          // lstroke
    #expect(LinuxKeysyms.codepoint(ofKeysym: 0x7E1) == 0x3B1)          // Greek_alpha
    #expect(LinuxKeysyms.codepoint(ofKeysym: 0x0100_1E9E) == 0x1E9E)   // U+1E9E ẞ
    #expect(LinuxKeysyms.codepoint(ofKeysym: 0xFFB8) == 0x38)          // KP_8
    #expect(LinuxKeysyms.codepoint(ofKeysym: 0xFF0D) == 0x0D)          // Return
    #expect(LinuxKeysyms.codepoint(ofKeysym: LinuxKeysyms.isoLeftTab) == 0)
    #expect(LinuxKeysyms.codepoint(ofKeysym: 0xFE51) == 0)             // dead_acute
    #expect(LinuxKeysyms.codepoint(ofKeysym: 0xFF52) == 0)             // Up
    #expect(LinuxKeysyms.codepoint(ofKeysym: 0x0100_D800) == 0)        // a surrogate
    #expect(LinuxKeysyms.isDeadKey(0xFE51))
    #expect(!LinuxKeysyms.isDeadKey(LinuxKeysyms.isoLeftTab))

    // The legacy table is sorted, so the binary search finds every entry.
    let table = LinuxKeysyms.legacyTable
    #expect(table.count % 2 == 0)
    for index in stride(from: 2, to: table.count, by: 2) { #expect(table[index - 2] < table[index]) }
    for index in stride(from: 0, to: table.count, by: 2) {
        #expect(LinuxKeysyms.codepoint(ofKeysym: table[index]) == table[index + 1])
    }
}

@Test("text: no control characters, ISO_Left_Tab and dead keys type nothing")
func linuxTranslatorText() {
    #expect(LinuxKeyTranslator.text(forKeyval: 0x63) == "c")
    #expect(LinuxKeyTranslator.text(forKeyval: 0x20) == " ")
    #expect(LinuxKeyTranslator.text(forKeyval: 0x20AC) == "€")
    #expect(LinuxKeyTranslator.text(forKeyval: 0xFF0D) == "")          // Return
    #expect(LinuxKeyTranslator.text(forKeyval: 0xFF8D) == "")          // KP_Enter
    #expect(LinuxKeyTranslator.text(forKeyval: 0xFFFF) == "")          // Delete
    #expect(LinuxKeyTranslator.text(forKeyval: 0xFF1B) == "")          // Escape
    #expect(LinuxKeyTranslator.text(forKeyval: LinuxKeysyms.isoLeftTab) == "")
    #expect(LinuxKeyTranslator.text(forKeyval: 0xFE51) == "")          // dead_acute
    #expect(LinuxKeyTranslator.text(forKeyval: 0x0100_0085) == "")     // C1 NEL
    #expect(LinuxKeyTranslator.text(forKeyval: 0xFFB1) == "1")         // KP_1
}

// MARK: - The done-when cases

@Test("se: AltGr+8 types [ and AltGr+7 types {, as plain text in every mode")
func linuxSwedishAltGrBrackets() throws {
    let se = try loadLayout("se")
    let cases: [(UInt32, String, UInt32)] = [
        (KEY_8, "[", 0x38), (KEY_7, "{", 0x37), (KEY_9, "]", 0x39), (KEY_0, "}", 0x30),
        (KEY_MINUS, "\\", 0x2B),
    ]
    for (code, text, unshifted) in cases {
        let press = try type(code, chord: "rightalt", in: se)
        #expect(press.text == text)
        #expect(press.mods.isEmpty, "AltGr must not become a modifier: \(press.mods)")
        #expect(press.consumedMods.isEmpty)
        #expect(press.unshiftedCodepoint == unshifted)
        for mode in Mode.allCases { #expect(try encode(press, mode) == bytes(text), "\(text) \(mode)") }
    }
    // = is Shift+0, and Shift is consumed for it.
    let equal = try type(KEY_0, chord: "leftshift", in: se)
    #expect(equal.text == "=")
    #expect(equal.consumedMods == [.shift])
    #expect(try encode(equal, .kitty5) == bytes("="))
}

@Test("left Alt+B is ESC b in legacy and CSI 98;3u under kitty, on all five layouts")
func linuxLeftAltB() throws {
    for file in layoutFiles {
        let layout = try loadLayout(file)
        let press = try type(KEY_B, chord: "leftalt", in: layout)
        #expect(press.mods == [.alt], "\(file)")
        #expect(press.consumedMods.isEmpty, "\(file)")
        #expect(press.text == "b", "\(file)")
        #expect(try encode(press) == bytes("\u{1b}b"), "\(file)")
        #expect(try encode(press, .kitty1) == bytes("\u{1b}[98;3u"), "\(file)")
        #expect(try encode(press, .kitty5) == bytes("\u{1b}[98;3u"), "\(file)")
    }
}

@Test("Ctrl+C is 0x03 on all five layouts")
func linuxControlC() throws {
    for file in layoutFiles {
        let layout = try loadLayout(file)
        let press = try type(KEY_C, chord: "leftctrl", in: layout)
        #expect(press.mods == [.control], "\(file)")
        #expect(press.text == "c", "\(file): no Ctrl transform")
        #expect(try encode(press) == [0x03], "\(file)")
        #expect(try encode(press, .kitty5) == bytes("\u{1b}[99;5u"), "\(file)")
    }
}

@Test("Right Ctrl sets .controlRight, Right Shift .shiftRight; the left keys set no side bit")
func linuxRightSideBits() throws {
    for file in layoutFiles {
        let layout = try loadLayout(file)
        #expect(try type(KEY_C, chord: "rightctrl", in: layout).mods == [.control, .controlRight], "\(file)")
        #expect(try type(KEY_C, chord: "leftctrl", in: layout).mods == [.control], "\(file)")
        let rightShift = try type(KEY_A, chord: "rightshift", in: layout)
        #expect(rightShift.mods == [.shift, .shiftRight], "\(file)")
        #expect(rightShift.consumedMods == [.shift, .shiftRight], "\(file)")
    }
}

@Test("Right Alt is Alt (with its side bit) on us, and AltGr — no modifier at all — elsewhere")
func linuxRightAltPerLayout() throws {
    for file in layoutFiles {
        let layout = try loadLayout(file)
        let press = try type(KEY_B, chord: "rightalt", in: layout)
        if file == "us" {
            #expect(press.mods == [.alt, .altRight])
            #expect(press.text == "b")
            #expect(try encode(press) == bytes("\u{1b}b"))
        } else {
            #expect(!press.mods.contains(.alt), "\(file): AltGr became Alt")
            #expect(!press.mods.contains(.altRight), "\(file)")
        }
    }

    // Left Alt held together with AltGr: Alt, but never the right side.
    let se = try loadLayout("se")
    var translator = LinuxKeyTranslator()
    _ = translator.translate(try se.facts(LinuxKeyCodes.rightAlt, chord: try se.chordIndex("")))
    _ = translator.translate(try se.facts(LinuxKeyCodes.leftAlt, chord: try se.chordIndex("rightalt")))
    var facts = try se.facts(KEY_B, chord: try se.chordIndex("rightalt"))
    facts.state.insert(.alt)
    #expect(translator.translate(facts).mods == [.alt])
}

@Test("fr: digits need Shift, AltGr+5 is [; de: AltGr+8 is [ and AltGr+Q is @; us(intl): dead keys type nothing")
func linuxOtherLayouts() throws {
    let fr = try loadLayout("fr")
    #expect(try type(KEY_1, in: fr).text == "&")
    let frOne = try type(KEY_1, chord: "leftshift", in: fr)
    #expect(frOne.text == "1")
    #expect(frOne.unshiftedCodepoint == 0x26)   // the level-0 keyval, as GDK would map it
    #expect(try type(KEY_5, chord: "rightalt", in: fr).text == "[")
    #expect(try type(KEY_4, chord: "rightalt", in: fr).text == "{")
    #expect(try type(KEY_Q, in: fr).text == "a")
    #expect(try type(KEY_Q, in: fr).key == GHOSTTY_KEY_Q)   // physical, AZERTY or not

    let de = try loadLayout("de")
    #expect(try type(KEY_8, chord: "rightalt", in: de).text == "[")
    #expect(try type(KEY_Q, chord: "rightalt", in: de).text == "@")

    let intl = try loadLayout("us-intl")
    let acute = try type(KEY_APOSTROPHE, in: intl)
    #expect(acute.text == "")
    #expect(try encode(acute).isEmpty)
    #expect(try type(KEY_Q, chord: "rightalt", in: intl).text == "ä")

    let se = try loadLayout("se")
    #expect(try type(KEY_EQUAL, in: se).text == "")             // dead_acute
    #expect(try type(KEY_RIGHTBRACE, in: se).text == "")        // dead_diaeresis
    #expect(try type(KEY_LEFTBRACE, in: se).text == "å")
    #expect(try type(KEY_LEFTBRACE, chord: "leftshift", in: se).text == "Å")
}

@Test("Shift+Tab is ISO_Left_Tab: no text, and the encoder makes CSI Z from the key")
func linuxShiftTab() throws {
    let us = try loadLayout("us")
    let press = try type(KEY_TAB, chord: "leftshift", in: us)
    #expect(press.text == "")
    #expect(press.key == GHOSTTY_KEY_TAB)
    #expect(press.unshiftedCodepoint == 0x09)
    #expect(try encode(press) == bytes("\u{1b}[Z"))
    #expect(try encode(press, .kitty5) == bytes("\u{1b}[9;2u"))
}

// MARK: - Properties over every layout, chord and key

@Test("on every layout, chord and key: the translator's invariants")
func linuxTranslatorInvariants() throws {
    for file in layoutFiles {
        let layout = try loadLayout(file)
        for (index, chord) in layout.chords.enumerated() {
            for key in layout.keys where !chord.held.contains(key.evdev) {
                var translator = LinuxKeyTranslator()
                try layout.pressModifiers(of: index, into: &translator)
                let facts = try layout.facts(key.evdev, chord: index)
                let press = translator.translate(facts)
                let label = "\(file) \(chord.name) <\(key.xkb)>"
                let isModifierKey = LinuxModifierKey.modifier(forKeyval: facts.keyval) != nil

                #expect(press.action == .press, "\(label)")
                #expect(press.key == LinuxKeyCodes.key(forEvdevCode: key.evdev, keyval: facts.keyval), "\(label)")
                #expect(press.text == LinuxKeyTranslator.text(forKeyval: facts.keyval), "\(label)")
                #expect(press.unshiftedCodepoint == LinuxKeysyms.codepoint(ofKeysym: key.level0), "\(label)")
                // NumLock is read, never reported; Meta and Hyper never appear.
                #expect(!press.mods.contains(.numLock), "\(label)")
                // Only Shift is ever consumed, and only off a modifier key.
                #expect(press.consumedMods.isSubset(of: [.shift, .shiftRight]), "\(label)")
                if !isModifierKey {
                    #expect(press.consumedMods == press.mods.intersection([.shift, .shiftRight]), "\(label)")
                }
                // Alt only from an Alt key: left Alt anywhere, Right Alt only where it is Alt_R.
                let altHeld = chord.held.contains(LinuxKeyCodes.leftAlt)
                    || (chord.held.contains(LinuxKeyCodes.rightAlt) && file == "us")
                if !(isModifierKey && LinuxModifierKey.modifier(forKeyval: facts.keyval) == .alt) {
                    #expect(press.mods.contains(.alt) == altHeld, "\(label): \(press.mods)")
                }
                // Ctrl never changes the text (no Ctrl transform): same keyval as without Ctrl.
                // Not with Alt too: Ctrl+Alt on the keypad operators is xkb's XF86_*VMode/Grab.
                let ctrlHeld = chord.held.contains(LinuxKeyCodes.leftCtrl) || chord.held.contains(LinuxKeyCodes.rightCtrl)
                if ctrlHeld && !altHeld {
                    let withoutCtrl = chord.held.filter { $0 != LinuxKeyCodes.leftCtrl && $0 != LinuxKeyCodes.rightCtrl }
                    if let plain = layout.chords.firstIndex(where: { $0.locks == chord.locks && $0.held == withoutCtrl }) {
                        #expect(press.text == LinuxKeyTranslator.text(forKeyval: key.keyvals[plain]), "\(label)")
                    }
                }
            }
        }
    }
}

// MARK: - Actions, modifier keys, reset

@Test(".repeated is inferred from the pressed set, and a release ends it")
func linuxRepeatInference() throws {
    let us = try loadLayout("us")
    var translator = LinuxKeyTranslator()
    let a = try us.facts(KEY_A, chord: 0)
    #expect(translator.translate(a).action == .press)
    #expect(translator.translate(a).action == .repeated)
    #expect(translator.translate(a).action == .repeated)
    var release = a
    release.isRelease = true
    let up = translator.translate(release)
    #expect(up.action == .release)
    #expect(up.text == "")
    #expect(up.unshiftedCodepoint == 0x61)
    #expect(translator.translate(a).action == .press)

    // Repeats encode like presses in legacy mode; releases encode to nothing without REPORT_EVENTS.
    #expect(try encode(translator.translate(a)) == bytes("a"))
    #expect(try encode(up, .kitty5).isEmpty)

    // Focus-out forgets what was down, so the next press is a press.
    translator.reset()
    #expect(translator.translate(a).action == .press)
}

@Test("a modifier key's own event carries the state after it, as flagsChanged does")
func linuxModifierKeyEvents() throws {
    let us = try loadLayout("us")
    let se = try loadLayout("se")
    var translator = LinuxKeyTranslator()

    // Left Shift: GDK reports the press without Shift and the release with it.
    let shiftDown = translator.translate(try us.facts(LinuxKeyCodes.leftShift, chord: 0))
    #expect(shiftDown.key == GHOSTTY_KEY_SHIFT_LEFT)
    #expect(shiftDown.mods == [.shift])
    #expect(shiftDown.consumedMods.isEmpty)
    #expect(shiftDown.text == "")
    #expect(try encode(shiftDown).isEmpty)
    let shifted = try us.chordIndex("leftshift")
    let shiftUp = translator.translate(try us.facts(LinuxKeyCodes.leftShift, chord: shifted, isRelease: true))
    #expect(shiftUp.action == .release)
    #expect(shiftUp.mods == [])

    // Right Shift carries its side; releasing it while Left Shift is held leaves plain Shift.
    _ = translator.translate(try us.facts(LinuxKeyCodes.leftShift, chord: 0))
    let rightDown = translator.translate(try us.facts(LinuxKeyCodes.rightShift, chord: shifted))
    #expect(rightDown.mods == [.shift, .shiftRight])
    let rightUp = translator.translate(try us.facts(LinuxKeyCodes.rightShift, chord: shifted, isRelease: true))
    #expect(rightUp.mods == [.shift])

    // Super is ⌘'s modifier.
    var fresh = LinuxKeyTranslator()
    #expect(fresh.translate(try us.facts(LinuxKeyCodes.leftMeta, chord: 0)).mods == [.super_])

    // se's Right Alt is AltGr: its own press is no modifier.
    fresh = LinuxKeyTranslator()
    let altGr = fresh.translate(try se.facts(LinuxKeyCodes.rightAlt, chord: 0))
    #expect(altGr.key == GHOSTTY_KEY_ALT_RIGHT)
    #expect(altGr.mods == [])
    // us's Right Alt is Alt.
    fresh = LinuxKeyTranslator()
    #expect(fresh.translate(try us.facts(LinuxKeyCodes.rightAlt, chord: 0)).mods == [.alt, .altRight])
}

@Test("reset forgets held sides (focus-out)")
func linuxResetForgetsSides() throws {
    let us = try loadLayout("us")
    var translator = LinuxKeyTranslator()
    _ = translator.translate(try us.facts(LinuxKeyCodes.rightCtrl, chord: 0))
    #expect(translator.sides.applyingSides(to: [.control]) == [.control, .controlRight])
    translator.reset()
    #expect(translator.sides.applyingSides(to: [.control]) == [.control])
}

@Test("keypad: NumLock on types digits, NumLock off is navigation; NumLock is never reported")
func linuxKeypad() throws {
    let us = try loadLayout("us")
    #expect(us.chords[try us.chordIndex("numlock")].numLock)
    #expect(!us.chords[try us.chordIndex("")].numLock)
    let on = try type(KEY_KP8, chord: "numlock", in: us)
    #expect(on.key == GHOSTTY_KEY_NUMPAD_8)
    #expect(on.text == "8")
    #expect(on.mods.isEmpty)
    #expect(try encode(on) == bytes("8"))
    #expect(try encode(on, .kitty5) == bytes("8"))

    let off = try type(KEY_KP8, in: us)
    #expect(off.key == GHOSTTY_KEY_NUMPAD_UP)
    #expect(off.text == "")
    #expect(try encode(off) == bytes("\u{1b}[A"))
    #expect(try encode(off, applicationCursorKeys: true) == bytes("\u{1b}OA"))

    let dotOff = try type(KEY_KPDOT, in: us)
    #expect(dotOff.key == GHOSTTY_KEY_NUMPAD_DELETE)
    #expect(try encode(dotOff) == bytes("\u{1b}[3~"))
}

// MARK: - Why the rules are what they are (measured with the real encoder)

@Test("measured: xkb's consumed set would turn Shift+Space into CSI 32;2u under Claude Code's flags")
func linuxShiftSpaceNeedsShiftConsumed() throws {
    let us = try loadLayout("us")
    let press = try type(KEY_SPACE, chord: "leftshift", in: us)
    #expect(press.consumedMods == [.shift])
    for mode in Mode.allCases { #expect(try encode(press, mode) == bytes(" "), "\(mode)") }

    // What GDK's consumed set (GTK mode: Shift does not change Space's keysym) would give instead.
    var gdkConsumed = press
    gdkConsumed.consumedMods = []
    #expect(try encode(gdkConsumed, .kitty5) == bytes("\u{1b}[32;2u"))
}

@Test("measured: reporting NumLock would change Up, Escape and Ctrl+C under kitty flags")
func linuxNumLockMustNotBeReported() throws {
    let up = KeyPress(key: GHOSTTY_KEY_ARROW_UP, mods: [.numLock])
    #expect(try encode(up, .kitty1) == bytes("\u{1b}[1;129A"))
    let ctrlC = KeyPress(key: GHOSTTY_KEY_C, mods: [.control, .numLock], text: "c", unshiftedCodepoint: 0x63)
    #expect(try encode(ctrlC, .kitty5) == bytes("\u{1b}[99;133u"))

    // With NumLock on, the translator's Up and Ctrl+C are the plain ones.
    let us = try loadLayout("us")
    #expect(try encode(try type(KEY_UP, chord: "numlock", in: us), .kitty1) == bytes("\u{1b}[A"))
    let numLockC = try us.facts(KEY_C, chord: try us.chordIndex("numlock"))
    var translator = LinuxKeyTranslator()
    var withCtrl = numLockC
    withCtrl.state.insert(.control)
    #expect(try encode(translator.translate(withCtrl), .kitty5) == bytes("\u{1b}[99;5u"))
}

@Test("measured: the Mac leaving Right Ctrl's side bit in consumedMods changes no byte")
func linuxRightControlSideConsumptionIsInvisible() throws {
    let us = try loadLayout("us")
    for code in [KEY_C, KEY_A, KEY_1, KEY_LEFTBRACE] {
        let press = try type(code, chord: "rightctrl", in: us)
        #expect(press.consumedMods.isEmpty)
        var macStyle = press
        macStyle.consumedMods = [.controlRight]   // translationModifiers − [.control, .super_]
        for mode in Mode.allCases { #expect(try encode(press, mode) == (try encode(macStyle, mode)), "\(code) \(mode)") }
    }
}

@Test("measured: whether Caps Lock is consumed changes no byte")
func linuxCapsLockConsumptionIsInvisible() throws {
    let us = try loadLayout("us")
    for (code, chord) in [(KEY_A, "capslock"), (KEY_A, "capslock+leftshift"), (KEY_1, "capslock")] {
        let press = try type(code, chord: chord, in: us)
        #expect(press.mods.contains(.capsLock))
        #expect(!press.consumedMods.contains(.capsLock))
        var macStyle = press
        macStyle.consumedMods.insert(.capsLock)   // the Mac heuristic consumes it
        for mode in Mode.allCases { #expect(try encode(press, mode) == (try encode(macStyle, mode)), "\(chord) \(mode)") }
    }
}

// MARK: - docs/keys.md through the Linux translator

/// The inverse of docs/keys.md's `cat -v`-ish escaping.
private func unescapeDocCell(_ cell: String) -> [UInt8] {
    if cell == "(nothing)" { return [] }
    var out: [UInt8] = []
    var scalars = Substring(cell)
    while let first = scalars.first {
        if first == "\\" {
            let rest = scalars.dropFirst()
            switch rest.first {
            case "e": out.append(0x1B); scalars = rest.dropFirst()
            case "r": out.append(0x0D); scalars = rest.dropFirst()
            case "n": out.append(0x0A); scalars = rest.dropFirst()
            case "t": out.append(0x09); scalars = rest.dropFirst()
            case "x":
                let hex = rest.dropFirst().prefix(2)
                out.append(UInt8(hex, radix: 16)!)
                scalars = rest.dropFirst(3)
            default: out.append(0x5C); scalars = rest
            }
        } else {
            out.append(contentsOf: Array(String(first).utf8))
            scalars = scalars.dropFirst()
        }
    }
    return out
}

/// docs/keys.md rows → the `us` keystroke that types them on Linux. The "Option+X — not as alt"
/// rows are the Mac's option-composes mode, which Linux does not have (Alt is always Alt), so
/// they are the only rows left out.
private func linuxKeystroke(forDocRow label: String) -> (evdev: UInt32, chord: String)? {
    let letters: [Character: UInt32] = [
        "A": 30, "B": 48, "C": 46, "D": 32, "E": 18, "F": 33, "G": 34, "H": 35, "I": 23, "J": 36,
        "K": 37, "L": 38, "M": 50, "N": 49, "O": 24, "P": 25, "Q": 16, "R": 19, "S": 31, "T": 20,
        "U": 22, "V": 47, "W": 17, "X": 45, "Y": 21, "Z": 44,
    ]
    let named: [String: UInt32] = [
        "Up": 103, "Down": 108, "Right": 106, "Left": 105, "Home": 102, "End": 107, "PageUp": 104,
        "PageDown": 109, "Insert": 110, "Enter": 28, "Escape": 1, "Tab": 15, "Backspace": 14,
        "Delete (forward)": 111, "Space": 57, "F1": 59, "F2": 60, "F3": 61, "F4": 62, "F5": 63, "F6": 64,
        "F7": 65, "F8": 66, "F9": 67, "F10": 68, "F11": 87, "F12": 88, "1": 2,
    ]
    let chords: [(prefix: String, chord: String)] = [
        ("Ctrl+Shift+", "leftctrl+leftshift"), ("Shift+", "leftshift"), ("Ctrl+", "leftctrl"),
    ]
    if label.hasSuffix(" — not as alt") { return nil }
    if label.hasPrefix("Option+"), label.hasSuffix(" — as alt") {
        guard let letter = label.dropFirst("Option+".count).first, let code = letters[letter] else { return nil }
        return (code, "leftalt")
    }
    for (prefix, chord) in chords where label.hasPrefix(prefix) {
        let rest = String(label.dropFirst(prefix.count))
        if let code = named[rest] { return (code, chord) }
        if rest.count == 1, let code = letters[rest.first!] { return (code, chord) }
        return nil
    }
    if let code = named[label] { return (code, "") }
    if label.count == 1, let code = letters[label.first!] { return (code, "") }
    return nil
}

@Test("the us rows of docs/keys.md reproduce through LinuxKeyTranslator and KeyEncoder")
func linuxKeysDocRows() throws {
    let us = try loadLayout("us")
    let doc = try String(
        contentsOf: fixturesDirectory().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/keys.md"),
        encoding: .utf8)

    var checked = 0
    var skipped: [String] = []
    for line in doc.split(separator: "\n") where line.hasPrefix("| ") && line.contains("`") {
        let cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // ["", label, legacy, kitty1, kitty5, (DECCKM,) ""]
        let label = cells[1]
        if label.hasPrefix("**") { continue }   // the Columns table at the top
        let columns = cells.dropFirst(2).dropLast().map { cell -> [UInt8] in
            unescapeDocCell(String(cell.dropFirst().dropLast()))   // strip the backticks
        }
        guard let (evdev, chord) = linuxKeystroke(forDocRow: label) else {
            skipped.append(label)
            continue
        }
        let press = try type(evdev, chord: chord, in: us)
        #expect(try encode(press, .legacy) == columns[0], "\(label) legacy")
        #expect(try encode(press, .kitty1) == columns[1], "\(label) kitty(1)")
        #expect(try encode(press, .kitty5) == columns[2], "\(label) kitty(5)")
        if columns.count == 4 {
            #expect(try encode(press, applicationCursorKeys: true) == columns[3], "\(label) DECCKM")
        }
        checked += 1
    }
    // 11 navigation + 12 function + 10 editing + 26 Ctrl + 8 Option-as-alt + 4 alternates.
    #expect(checked == 71)
    #expect(skipped.count == 8 && skipped.allSatisfy { $0.hasSuffix(" — not as alt") }, "\(skipped)")
}

// MARK: - Parity with the Mac adapter

/// Fixtures/key-parity.json. The Mac half of the same rows runs in
/// Tests/TkzTerminalViewTests/KeyParityTests.swift.
private struct ParityFixture: Decodable {
    struct Row: Decodable {
        struct Linux: Decodable {
            let layout: String
            let chord: String
            let evdev: UInt32
        }

        struct Expected: Decodable {
            let key: String
            let mods: [String]
            let consumedMods: [String]
            let text: String
            let unshiftedCodepoint: UInt32
        }

        let name: String
        let action: String
        let linux: Linux
        let expected: Expected
    }

    let rows: [Row]
}

private let parityKeys: [String: GhosttyKey] = [
    "KeyA": GHOSTTY_KEY_A, "KeyB": GHOSTTY_KEY_B, "KeyC": GHOSTTY_KEY_C, "KeyP": GHOSTTY_KEY_P,
    "Digit1": GHOSTTY_KEY_DIGIT_1, "Digit8": GHOSTTY_KEY_DIGIT_8, "Minus": GHOSTTY_KEY_MINUS,
    "Equal": GHOSTTY_KEY_EQUAL, "BracketLeft": GHOSTTY_KEY_BRACKET_LEFT, "Space": GHOSTTY_KEY_SPACE,
    "Enter": GHOSTTY_KEY_ENTER, "Tab": GHOSTTY_KEY_TAB, "Escape": GHOSTTY_KEY_ESCAPE,
]

private let parityMods: [String: KeyModifiers] = [
    "shift": .shift, "control": .control, "alt": .alt, "super": .super_, "capsLock": .capsLock,
    "shiftRight": .shiftRight, "controlRight": .controlRight, "altRight": .altRight, "superRight": .superRight,
]

@Test("key-parity.json: the Linux translator builds the expected KeyPress for every row")
func linuxKeyParity() throws {
    let url = fixturesDirectory().appendingPathComponent("key-parity.json")
    let fixture = try JSONDecoder().decode(ParityFixture.self, from: Data(contentsOf: url))
    #expect(fixture.rows.count >= 20)

    for row in fixture.rows {
        let layout = try loadLayout(row.linux.layout)
        let index = try layout.chordIndex(row.linux.chord)
        var translator = LinuxKeyTranslator()
        try layout.pressModifiers(of: index, into: &translator)
        let facts = try layout.facts(row.linux.evdev, chord: index)
        var press = translator.translate(facts)
        switch row.action {
        case "press": break
        case "repeated": press = translator.translate(facts)
        case "release":
            var release = facts
            release.isRelease = true
            press = translator.translate(release)
        default: Issue.record("unknown action \(row.action)")
        }

        let expected = KeyPress(
            action: row.action == "repeated" ? .repeated : row.action == "release" ? .release : .press,
            key: try #require(parityKeys[row.expected.key], "key \(row.expected.key)"),
            mods: KeyModifiers(try row.expected.mods.map { try #require(parityMods[$0], "mod \($0)") }),
            consumedMods: KeyModifiers(try row.expected.consumedMods.map { try #require(parityMods[$0], "mod \($0)") }),
            text: row.expected.text,
            unshiftedCodepoint: row.expected.unshiftedCodepoint)
        #expect(press == expected, "\(row.name)")
    }
}
