// KeymapFixtureTests — the layout fixtures for LinuxKeyTranslator, from libxkbcommon (WOR-315 S1).
//
// Linux only, and the only code that links libxkbcommon (test-only, decision S6-3). It compiles
// the `se` (the reference machine's layout), `us`, `us(intl)`, `de` and `fr` keymaps headlessly
// with `xkb_keymap_new_from_names2`, presses modifier chords on an `xkb_state` and records, for
// every key that matters, the keysym GDK would report as the keyval. The result is committed as
// JSON under Tests/TkzTerminalCoreTests/Fixtures/keymaps/, so LinuxKeyTranslatorTests runs on
// macOS too. Regenerate with:
//
//     TKZMUX_UPDATE_KEYMAP_FIXTURES=1 swift test --build-system native --filter LinuxKeymapTests
//
// A plain run regenerates in memory and compares. The keymaps come from the host's
// xkeyboard-config, so the byte comparison only runs when its version is the one the fixtures
// record; on any other version a fixed set of long-stable facts (AltGr brackets on `se`, the `fr`
// digit row, …) is checked against the live keymaps instead.
//
// The GDK state of a chord is what GDK derives on Wayland from the xkb modifiers: Shift → SHIFT,
// Lock → LOCK, Control → CONTROL, Mod1 → ALT, Mod4 → SUPER. Mod5 (AltGr, `LevelThree`) has no GDK
// bit. WOR-315 S2 checks this against live GDK events.
import CXKBCommon
import Foundation
import Testing
import TkzTerminalCore

// MARK: - What is recorded

/// One layout, as RMLVO names (rules `evdev`, model `pc105`, no options).
struct FixtureLayout {
    let file: String
    let layout: String
    let variant: String
}

let fixtureLayouts: [FixtureLayout] = [
    FixtureLayout(file: "se", layout: "se", variant: ""),
    FixtureLayout(file: "us", layout: "us", variant: ""),
    FixtureLayout(file: "us-intl", layout: "us", variant: "intl"),
    FixtureLayout(file: "de", layout: "de", variant: ""),
    FixtureLayout(file: "fr", layout: "fr", variant: ""),
]

/// A modifier chord: physical keys held, in press order, after the locks are toggled on.
struct FixtureChord {
    let held: [UInt32]
    let locks: [UInt32]

    var name: String {
        (locks + held).map { evdevName[$0] ?? "\($0)" }.joined(separator: "+")
    }
}

private let evdevName: [UInt32: String] = [
    29: "leftctrl", 42: "leftshift", 54: "rightshift", 56: "leftalt", 58: "capslock",
    69: "numlock", 97: "rightctrl", 100: "rightalt", 125: "leftmeta",
]

let fixtureChords: [FixtureChord] = [
    FixtureChord(held: [], locks: []),
    FixtureChord(held: [42], locks: []),
    FixtureChord(held: [54], locks: []),
    FixtureChord(held: [100], locks: []),
    FixtureChord(held: [42, 100], locks: []),
    FixtureChord(held: [29], locks: []),
    FixtureChord(held: [29, 42], locks: []),
    FixtureChord(held: [97], locks: []),
    FixtureChord(held: [56], locks: []),
    FixtureChord(held: [56, 42], locks: []),
    FixtureChord(held: [29, 56], locks: []),
    FixtureChord(held: [125], locks: []),
    FixtureChord(held: [125, 42], locks: []),
    FixtureChord(held: [], locks: [58]),
    FixtureChord(held: [42], locks: [58]),
    FixtureChord(held: [], locks: [69]),
    FixtureChord(held: [42], locks: [69]),
]

/// The keys recorded: the whole alphanumeric block, the keypad, the navigation keys, F1-F12 and
/// every modifier key (input-event-codes.h numbering).
let fixtureKeys: [UInt32] =
    Array(1...14)                               // Esc, digit row, Backspace
    + Array(15...28)                            // Tab, top letter row, Enter
    + Array(30...41)                            // home row, ', `
    + Array(43...53)                            // \, bottom row
    + [57, 86, 127]                             // Space, 102ND, Compose/Menu
    + [55] + Array(71...83) + [96, 98, 117]     // keypad
    + Array(102...111)                          // Home … Delete
    + Array(59...68) + [87, 88]                 // F1 … F12
    + [29, 42, 54, 56, 58, 69, 97, 100, 125, 126]  // modifiers and locks

// MARK: - Generation

/// The host's xkeyboard-config: data directory and version, from its pkg-config file.
private func xkeyboardConfig() -> (base: String, version: String?) {
    for dir in ["/usr/share/pkgconfig", "/usr/lib/pkgconfig", "/usr/lib/x86_64-linux-gnu/pkgconfig"] {
        guard let text = try? String(contentsOfFile: dir + "/xkeyboard-config.pc", encoding: .utf8) else {
            continue
        }
        var base = "/usr/share/X11/xkb"
        var version: String?
        var variables: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Version:") {
                version = line.dropFirst("Version:".count).trimmingCharacters(in: .whitespaces)
            } else if let eq = line.firstIndex(of: "="), !line.contains(":") {
                var value = String(line[line.index(after: eq)...])
                for (name, resolved) in variables { value = value.replacingOccurrences(of: "${\(name)}", with: resolved) }
                variables[String(line[..<eq])] = value
            }
        }
        if let xkbBase = variables["xkb_base"] { base = xkbBase }
        return (base, version)
    }
    return ("/usr/share/X11/xkb", nil)
}

/// A compiled keymap with every user and environment override shut out: no `~/.config/xkb`, no
/// `XKB_DEFAULT_*`, only the system xkeyboard-config.
final class CompiledKeymap {
    let context: OpaquePointer
    let keymap: OpaquePointer

    init(_ layout: FixtureLayout, xkbBase: String) throws {
        let flags = xkb_context_flags(
            rawValue: XKB_CONTEXT_NO_DEFAULT_INCLUDES.rawValue | XKB_CONTEXT_NO_ENVIRONMENT_NAMES.rawValue)
        guard let context = xkb_context_new(flags) else { throw FixtureError("xkb_context_new failed") }
        self.context = context
        guard xkb_context_include_path_append(context, xkbBase) == 1 else {
            xkb_context_unref(context)
            throw FixtureError("no xkeyboard-config at \(xkbBase)")
        }
        let compiled: OpaquePointer? = "evdev".withCString { rules in
            "pc105".withCString { model in
                layout.layout.withCString { name in
                    layout.variant.withCString { variant in
                        "".withCString { options in
                            var names = xkb_rule_names(
                                rules: rules, model: model, layout: name, variant: variant, options: options)
                            return xkb_keymap_new_from_names2(
                                context, &names, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS)
                        }
                    }
                }
            }
        }
        guard let compiled else {
            xkb_context_unref(context)
            throw FixtureError("cannot compile \(layout.layout)(\(layout.variant))")
        }
        keymap = compiled
    }

    deinit {
        xkb_keymap_unref(keymap)
        xkb_context_unref(context)
    }

    /// A fresh state with `chord` applied: locks pressed and released, then the held keys down.
    func state(for chord: FixtureChord) -> OpaquePointer {
        let state = xkb_state_new(keymap)!
        for lock in chord.locks {
            xkb_state_update_key(state, lock + 8, XKB_KEY_DOWN)
            xkb_state_update_key(state, lock + 8, XKB_KEY_UP)
        }
        for key in chord.held { xkb_state_update_key(state, key + 8, XKB_KEY_DOWN) }
        return state
    }

    /// The GdkModifierType GDK reports for this state, and whether the Num Lock LED is on.
    func gdkState(_ state: OpaquePointer) -> (mask: UInt32, numLock: Bool) {
        let effective = xkb_state_serialize_mods(state, XKB_STATE_MODS_EFFECTIVE)
        var mask: UInt32 = 0
        let bits: [(String, LinuxModifierMask)] = [
            (XKB_MOD_NAME_SHIFT, .shift), (XKB_MOD_NAME_CAPS, .lock), (XKB_MOD_NAME_CTRL, .control),
            ("Mod1", .alt), ("Mod4", .super_),
        ]
        for (name, gdk) in bits {
            let index = xkb_keymap_mod_get_index(keymap, name)
            if index < 32, effective & (1 << index) != 0 { mask |= gdk.rawValue }
        }
        return (mask, xkb_state_led_name_is_active(state, XKB_LED_NAME_NUM) == 1)
    }

    /// The level-0 keysym of `key` in `state`'s layout, or 0.
    func levelZero(_ key: UInt32, in state: OpaquePointer) -> UInt32 {
        let layout = xkb_state_key_get_layout(state, key + 8)
        var syms: UnsafePointer<xkb_keysym_t>?
        let count = xkb_keymap_key_get_syms_by_level(keymap, key + 8, layout, 0, &syms)
        guard count > 0, let syms else { return 0 }
        return syms[0]
    }

    func keyName(_ key: UInt32) -> String {
        guard let name = xkb_keymap_key_get_name(keymap, key + 8) else { return "" }
        return String(cString: name)
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The fixture file for one layout. Hand-formatted for stable diffs: one chord and one key per
/// line, keyvals in `chords` order.
func fixtureJSON(_ layout: FixtureLayout, xkbBase: String, xkbVersion: String) throws -> String {
    let keymap = try CompiledKeymap(layout, xkbBase: xkbBase)
    let states = fixtureChords.map { keymap.state(for: $0) }
    defer { states.forEach { xkb_state_unref($0) } }

    var out = "{\n"
    out += "  \"generator\": \"Tests/LinuxKeymapTests/KeymapFixtureTests.swift\",\n"
    out += "  \"rules\": \"evdev\",\n  \"model\": \"pc105\",\n"
    out += "  \"layout\": \"\(layout.layout)\",\n  \"variant\": \"\(layout.variant)\",\n"
    out += "  \"xkeyboardConfig\": \"\(xkbVersion)\",\n"
    out += "  \"chords\": [\n"
    for (index, chord) in fixtureChords.enumerated() {
        let (mask, numLock) = keymap.gdkState(states[index])
        let held = chord.held.map(String.init).joined(separator: ", ")
        let locks = chord.locks.map(String.init).joined(separator: ", ")
        out += "    {\"name\": \"\(chord.name)\", \"locks\": [\(locks)], \"held\": [\(held)], "
        out += "\"state\": \(mask), \"numLock\": \(numLock)}"
        out += index == fixtureChords.count - 1 ? "\n" : ",\n"
    }
    out += "  ],\n  \"keys\": [\n"
    for (index, key) in fixtureKeys.enumerated() {
        let keyvals = states.map { String(xkb_state_key_get_one_sym($0, key + 8)) }.joined(separator: ", ")
        out += "    {\"evdev\": \(key), \"xkb\": \"\(keymap.keyName(key))\", "
        out += "\"level0\": \(keymap.levelZero(key, in: states[0])), \"keyvals\": [\(keyvals)]}"
        out += index == fixtureKeys.count - 1 ? "\n" : ",\n"
    }
    out += "  ]\n}\n"
    return out
}

/// `<repo>/Tests/TkzTerminalCoreTests/Fixtures/keymaps`, from this file's path.
func keymapFixtureDirectory(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TkzTerminalCoreTests/Fixtures/keymaps")
}

// MARK: - Tests

@Test("the committed layout fixtures are what libxkbcommon compiles from this host's xkeyboard-config")
func keymapFixturesAreCurrent() throws {
    let (base, hostVersion) = xkeyboardConfig()
    let directory = keymapFixtureDirectory()
    let update = ProcessInfo.processInfo.environment["TKZMUX_UPDATE_KEYMAP_FIXTURES"] != nil

    if update {
        let version = try #require(hostVersion, "regenerating needs xkeyboard-config.pc for its version")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for layout in fixtureLayouts {
            let json = try fixtureJSON(layout, xkbBase: base, xkbVersion: version)
            try json.write(to: directory.appendingPathComponent("\(layout.file).json"), atomically: true, encoding: .utf8)
        }
        return
    }

    for layout in fixtureLayouts {
        let url = directory.appendingPathComponent("\(layout.file).json")
        let committed = try String(contentsOf: url, encoding: .utf8)
        guard let recorded = committed.firstMatch(of: /"xkeyboardConfig": "([^"]*)"/)?.1,
              let hostVersion, recorded == hostVersion
        else { continue }  // another xkeyboard-config: the stable-facts test below covers it
        let generated = try fixtureJSON(layout, xkbBase: base, xkbVersion: hostVersion)
        guard generated != committed else { continue }
        // Name the first differing line instead of printing two 17 KB strings.
        let ours = generated.split(separator: "\n", omittingEmptySubsequences: false)
        let theirs = committed.split(separator: "\n", omittingEmptySubsequences: false)
        let line = zip(ours, theirs).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(ours.count, theirs.count)
        Issue.record("""
            \(layout.file).json differs from what xkeyboard-config \(hostVersion) compiles, first at line \(line + 1):
              committed: \(line < theirs.count ? theirs[line] : "<missing>")
              xkb:       \(line < ours.count ? ours[line] : "<missing>")
            Regenerate with TKZMUX_UPDATE_KEYMAP_FIXTURES=1 swift test --filter LinuxKeymapTests
            """)
    }
}

@Test("long-stable layout facts hold in the live keymaps, whatever the xkeyboard-config version")
func stableLayoutFacts() throws {
    let base = xkeyboardConfig().base
    // (layout file, chord held keys, evdev code, expected keysym)
    let facts: [(String, [UInt32], UInt32, UInt32)] = [
        ("se", [100], 9, 0x5B),        // AltGr+8 → bracketleft
        ("se", [100], 8, 0x7B),        // AltGr+7 → braceleft
        ("se", [100], 10, 0x5D),       // AltGr+9 → bracketright
        ("se", [100], 11, 0x7D),       // AltGr+0 → braceright
        ("se", [42], 11, 0x3D),        // Shift+0 → equal
        ("se", [], 13, 0xFE51),        // <AE12> → dead_acute
        ("se", [], 26, 0xE5),          // <AD11> → aring
        ("se", [], 100, 0xFE03),       // Right Alt → ISO_Level3_Shift
        ("us", [], 100, 0xFFEA),       // Right Alt → Alt_R
        ("us", [42], 15, 0xFE20),      // Shift+Tab → ISO_Left_Tab
        ("us-intl", [], 40, 0xFE51),   // ' → dead_acute
        ("de", [100], 9, 0x5B),        // AltGr+8 → bracketleft
        ("de", [], 21, 0x7A),          // KEY_Y → z (QWERTZ)
        ("fr", [], 2, 0x26),           // KEY_1 → ampersand (digits need Shift)
        ("fr", [42], 2, 0x31),         // Shift+KEY_1 → 1
        ("fr", [], 16, 0x61),          // KEY_Q → a (AZERTY)
    ]
    for (file, held, key, expected) in facts {
        let layout = try #require(fixtureLayouts.first { $0.file == file })
        let keymap = try CompiledKeymap(layout, xkbBase: base)
        let state = keymap.state(for: FixtureChord(held: held, locks: []))
        defer { xkb_state_unref(state) }
        let keysym = xkb_state_key_get_one_sym(state, key + 8)
        #expect(keysym == expected, "\(file) \(held) KEY \(key): 0x\(String(keysym, radix: 16))")
    }
}

@Test("AltGr is Mod5 on se, de, fr and us(intl): no GDK bit, so it can never become Alt")
func altGrHasNoGdkBit() throws {
    let base = xkeyboardConfig().base
    for file in ["se", "de", "fr", "us-intl"] {
        let layout = try #require(fixtureLayouts.first { $0.file == file })
        let keymap = try CompiledKeymap(layout, xkbBase: base)
        let state = keymap.state(for: FixtureChord(held: [100], locks: []))
        defer { xkb_state_unref(state) }
        #expect(keymap.gdkState(state).mask == 0, "\(file)")
    }
}

@Test("LinuxKeysyms.codepoint is xkb_keysym_to_utf32 over every keysym below 0x10000 and the Unicode range")
func keysymTableMatchesLibxkbcommon() {
    var mismatches: [String] = []
    func check(_ keysym: UInt32) {
        let expected = xkb_keysym_to_utf32(keysym)
        let actual = LinuxKeysyms.codepoint(ofKeysym: keysym)
        if expected != actual, mismatches.count < 20 {
            mismatches.append("0x\(String(keysym, radix: 16)): xkb 0x\(String(expected, radix: 16)), ours 0x\(String(actual, radix: 16))")
        }
    }
    for keysym in UInt32(0)..<0x1_0000 { check(keysym) }
    for scalar in stride(from: UInt32(0), through: 0x11_0000, by: 0x101) { check(0x0100_0000 + scalar) }
    for keysym: UInt32 in [0x0100_0000, 0x0100_D800, 0x0100_DFFF, 0x0110_FFFF, 0x0111_0000, 0x1008_FF00] {
        check(keysym)
    }
    #expect(mismatches.isEmpty, "\(mismatches)")
}
