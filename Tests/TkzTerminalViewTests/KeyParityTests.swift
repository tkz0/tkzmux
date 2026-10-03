// KeyParityTests — the Mac half of the key-parity fixture (WOR-315 S1).
//
// Tests/TkzTerminalCoreTests/Fixtures/key-parity.json lists keystrokes as AppKit reports them and
// as GDK reports them, with the one `KeyPress` both adapters must build. The Linux half
// (LinuxKeyTranslatorTests) runs on both OSes; this half drives `TerminalInputController.keyPress`
// with synthesized `NSEvent`s, with Option acting as Alt, which is what Linux always does (the
// Linux translator never consumes Alt).
//
// The rows are US-layout keystrokes, and `characters(byApplyingModifiers:)` re-runs the *active*
// input source (see TerminalInputControllerTests), so the rows are only compared when that source
// types US characters. The macOS CI runner's does.

import AppKit
import Foundation
import GhosttyVt
import IOKit.hidsystem
import Testing
import TkzTerminalCore
@testable import TkzTerminalView

private struct ParityFixture: Decodable {
    struct Row: Decodable {
        struct Mac: Decodable {
            let keyCode: UInt16
            let flags: [String]
            let characters: String
            let charactersIgnoringModifiers: String
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
        let mac: Mac
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

/// `NSEvent.ModifierFlags` for the fixture's flag names; the `right*` names are the IOKit device
/// (side) bits, as a real right-hand modifier press has them.
private func modifierFlags(_ names: [String]) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    var device = UInt(0)
    for name in names {
        switch name {
        case "shift": flags.insert(.shift)
        case "control": flags.insert(.control)
        case "option": flags.insert(.option)
        case "command": flags.insert(.command)
        case "rightShift": device |= UInt(NX_DEVICERSHIFTKEYMASK)
        case "rightControl": device |= UInt(NX_DEVICERCTLKEYMASK)
        case "rightOption": device |= UInt(NX_DEVICERALTKEYMASK)
        case "rightCommand": device |= UInt(NX_DEVICERCMDKEYMASK)
        default: Issue.record("unknown flag \(name)")
        }
    }
    return NSEvent.ModifierFlags(rawValue: flags.rawValue | device)
}

@MainActor
private func keyEvent(
    _ keyCode: UInt16, characters: String, unmodified: String,
    flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown, isARepeat: Bool = false
) -> NSEvent {
    NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: unmodified,
        isARepeat: isARepeat, keyCode: keyCode)!
}

/// Whether the active input source types what the rows assume (US).
@MainActor
private func activeLayoutIsUS() -> Bool {
    let probes: [(UInt16, NSEvent.ModifierFlags, String)] = [
        (0x00, [], "a"), (0x00, .shift, "A"), (0x0B, [], "b"), (0x1C, [], "8"), (0x12, .shift, "!"),
        (0x1B, [], "-"), (0x18, [], "="), (0x21, [], "["), (0x23, .shift, "P"),
    ]
    for (keyCode, flags, expected) in probes {
        let event = keyEvent(keyCode, characters: expected, unmodified: expected)
        if event.characters(byApplyingModifiers: flags) != expected { return false }
    }
    return true
}

@MainActor
@Test("key-parity.json: TerminalInputController builds the expected KeyPress for every row")
func keyParityMac() throws {
    guard activeLayoutIsUS() else {
        print("KeyParityTests: the active input source is not US; the parity rows were not compared")
        return
    }
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TkzTerminalCoreTests/Fixtures/key-parity.json")
    let fixture = try JSONDecoder().decode(ParityFixture.self, from: Data(contentsOf: url))
    #expect(fixture.rows.count >= 20)

    for row in fixture.rows {
        let action: KeyPress.Action = row.action == "repeated" ? .repeated : row.action == "release" ? .release : .press
        let event = keyEvent(
            row.mac.keyCode, characters: row.mac.characters, unmodified: row.mac.charactersIgnoringModifiers,
            flags: modifierFlags(row.mac.flags), type: action == .release ? .keyUp : .keyDown,
            isARepeat: action == .repeated)
        // As the controller does: a keyUp carries no text (handleKeyUp), a keyDown takes its text
        // from the option-as-alt translation (handleKeyDown).
        let press = TerminalInputController.keyPress(
            event: event, action: action, optionAsAlt: .both, text: action == .release ? "" : nil)

        let expected = KeyPress(
            action: action,
            key: try #require(parityKeys[row.expected.key], "key \(row.expected.key)"),
            mods: KeyModifiers(try row.expected.mods.map { try #require(parityMods[$0], "mod \($0)") }),
            consumedMods: KeyModifiers(try row.expected.consumedMods.map { try #require(parityMods[$0], "mod \($0)") }),
            text: row.expected.text,
            unshiftedCodepoint: row.expected.unshiftedCodepoint)
        #expect(press == expected, "\(row.name)")
    }
}
