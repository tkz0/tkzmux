// TerminalInputControllerTests — the NSEvent → KeyPress translation, headless (M1.7 / TKZ-13).
//
// Everything here runs without a window, a pty or a terminal: `NSEvent.keyEvent(with:…)` synthesizes
// events and `TerminalInputController.keyPress(…)` is a pure function over one. The *encoding* of a
// `KeyPress` is TkzTerminalCoreTests' job (docs/keys.md); what is asserted here is the half AppKit
// owns, which is where the traps are.
//
// ## Why almost nothing is compared against a literal character
//
// `characters(byApplyingModifiers:)` re-runs the *user's* active keyboard layout, so Option+B is `∫`
// on a US layout and `›` on others. A test that hardcoded `∫` would pass on the author's machine and
// fail on the next one. Expectations are therefore computed from the same API on the same event —
// which still proves the thing that matters: *which* modifiers the text was translated with.

import AppKit
import GhosttyVt
import Testing
import TkzTerminalCore
import TkzTerminalRender
@testable import TkzTerminalView

// MARK: - Fixtures

/// A synthesized `keyDown`/`keyUp`. `characters` is what AppKit would have put in the event;
/// `byApplyingModifiers` ignores it and re-derives from `keyCode`, which is exactly the behaviour
/// the controller relies on.
@MainActor
private func key(
    _ keyCode: UInt16,
    characters: String,
    unmodified: String? = nil,
    flags: NSEvent.ModifierFlags = [],
    type: NSEvent.EventType = .keyDown,
    isARepeat: Bool = false
) -> NSEvent {
    NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters,
        charactersIgnoringModifiers: unmodified ?? characters,
        isARepeat: isARepeat, keyCode: keyCode)!
}

/// Raw flags with the IOKit device (side) bits set, as a real right-hand modifier press has them.
private func flags(_ base: NSEvent.ModifierFlags, deviceBits: Int32...) -> NSEvent.ModifierFlags {
    var raw = base.rawValue
    for bit in deviceBits { raw |= UInt(bit) }
    return NSEvent.ModifierFlags(rawValue: raw)
}

private let kVK_B: UInt16 = 0x0B
private let kVK_C: UInt16 = 0x08
private let kVK_P: UInt16 = 0x23
private let kVK_Tab: UInt16 = 0x30
private let kVK_Return: UInt16 = 0x24
private let kVK_RightShift: UInt16 = 0x3C
private let kVK_Shift: UInt16 = 0x38

/// A stand-in for TKZ-14's `MouseController`.
@MainActor
private final class StubMouseHandler: TerminalMouseHandling {
    var consume = true
    private(set) var seen: [NSEvent.EventType] = []
    private(set) var focusChanges: [Bool] = []

    func handle(_ event: NSEvent, in view: TerminalMetalView) -> Bool {
        seen.append(event.type)
        return consume
    }

    func focusDidChange(_ isFocused: Bool, in view: TerminalMetalView?) {
        focusChanges.append(isFocused)
    }
}

/// A view with no window, no Metal work and no session — enough for the delegate plumbing.
@MainActor
private func makeView() throws -> TerminalMetalView {
    let context = try TerminalRenderContext()
    return TerminalMetalView(renderContext: context, frame: NSRect(x: 0, y: 0, width: 400, height: 300))
}

// MARK: - Modifiers and side bits

@MainActor
@Test("modifiers map the four macOS modifiers plus caps lock")
func modifiersMapDeviceIndependentFlags() {
    let mods = TerminalInputController.modifiers(from: [.shift, .control, .option, .command, .capsLock])
    #expect(mods.contains(.shift))
    #expect(mods.contains(.control))
    #expect(mods.contains(.alt))
    #expect(mods.contains(.super_))
    #expect(mods.contains(.capsLock))
}

@MainActor
@Test("side bits come from the IOKit device masks, not from NSEvent.ModifierFlags")
func modifiersReadDeviceSideBits() {
    // Left-hand: the device-independent bits alone carry no side, so no `*Right` bit may appear.
    let left = TerminalInputController.modifiers(from: [.shift, .control, .option, .command])
    #expect(!left.contains(.shiftRight))
    #expect(!left.contains(.controlRight))
    #expect(!left.contains(.altRight))
    #expect(!left.contains(.superRight))

    let right = TerminalInputController.modifiers(
        from: flags([.shift, .control, .option, .command],
                    deviceBits: NX_DEVICERSHIFTKEYMASK, NX_DEVICERCTLKEYMASK,
                    NX_DEVICERALTKEYMASK, NX_DEVICERCMDKEYMASK))
    #expect(right.contains(.shiftRight))
    #expect(right.contains(.controlRight))
    #expect(right.contains(.altRight))
    #expect(right.contains(.superRight))
}

@MainActor
@Test("a side bit without its modifier is ignored")
func sideBitWithoutModifierIsIgnored() {
    // Stale device bits can linger in the raw flags; `.altRight` is only meaningful with `.alt`.
    let mods = TerminalInputController.modifiers(from: flags([.shift], deviceBits: NX_DEVICERALTKEYMASK))
    #expect(mods.contains(.shift))
    #expect(!mods.contains(.alt))
    #expect(!mods.contains(.altRight))
}

// MARK: - Text filtering

@MainActor
@Test("Shift+Tab's U+0019 is filtered to empty text so the key alone encodes it")
func shiftTabTextIsFiltered() {
    // The live case: AppKit reports U+0019 for Shift+Tab, and re-reading without Control yields
    // U+0009 — still C0. Both must be dropped, or `\e[Z` / `\e[9;2u` never happens.
    let event = key(kVK_Tab, characters: "\u{19}", flags: .shift)
    #expect(TerminalInputController.filteredText(of: event) == "")

    let press = TerminalInputController.keyPress(event: event, action: .press, optionAsAlt: .never)
    #expect(press.text == "")
    #expect(press.key == GHOSTTY_KEY_TAB)
    #expect(press.mods.contains(.shift))
}

@MainActor
@Test("a control character is re-read without Control; libghostty does the Ctrl encoding")
func controlCharacterIsReReadWithoutControl() {
    let event = key(kVK_C, characters: "\u{03}", unmodified: "c", flags: .control)
    // The layout decides the letter, so compare against the layout, not against "c".
    let expected = event.characters(byApplyingModifiers: [])
    #expect(TerminalInputController.filteredText(of: event) == expected)

    let press = TerminalInputController.keyPress(event: event, action: .press, optionAsAlt: .never)
    #expect(press.mods == [.control])
    // Control never counts as consumed, or the encoder would drop it from the effective mods.
    #expect(press.consumedMods.isEmpty)
    #expect(press.unshiftedCodepoint == expected?.unicodeScalars.first?.value)
}

@MainActor
@Test("DEL and the macOS function-key PUA never reach the encoder")
func delAndPuaAreFiltered() {
    #expect(TerminalInputController.sanitize("\u{7F}") == "")
    #expect(TerminalInputController.sanitize("\u{F700}") == "")  // NSUpArrowFunctionKey
    #expect(TerminalInputController.sanitize("\u{F8FF}") == "")
    #expect(TerminalInputController.sanitize("a") == "a")
    #expect(TerminalInputController.sanitize("😀") == "😀")
}

// MARK: - unshiftedCodepoint

@MainActor
@Test("unshiftedCodepoint uses byApplyingModifiers([]), not charactersIgnoringModifiers")
func unshiftedCodepointIgnoresControl() {
    // `charactersIgnoringModifiers` changes behaviour under Control on some layouts; the codepoint
    // must be the bare key either way, which is what makes Option+B encode as ESC + the letter.
    let plain = key(kVK_B, characters: "b")
    let withControl = key(kVK_B, characters: "\u{02}", unmodified: "b", flags: .control)
    let bare = plain.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value

    #expect(bare != nil)
    #expect(TerminalInputController.keyPress(event: plain, action: .press, optionAsAlt: .never)
        .unshiftedCodepoint == bare)
    #expect(TerminalInputController.keyPress(event: withControl, action: .press, optionAsAlt: .never)
        .unshiftedCodepoint == bare)
}

// MARK: - Option as Alt

@MainActor
@Test("option-as-alt translates without Option and leaves Option unconsumed")
func optionAsAltLeavesOptionUnconsumed() {
    let event = key(kVK_B, characters: "\u{222B}", unmodified: "b", flags: .option)

    // The translation event must have dropped Option, so the IME and the text see the plain letter.
    let translation = TerminalInputController.translationEvent(for: event, optionAsAlt: .both)
    #expect(!translation.modifierFlags.contains(.option))

    let press = TerminalInputController.keyPress(event: event, action: .press, optionAsAlt: .both)
    #expect(press.mods.contains(.alt))
    // THE trap: libghostty computes effectiveMods = mods − consumedMods whenever text is non-empty.
    // Option consumed here would encode the composed character instead of ESC + letter.
    #expect(!press.consumedMods.contains(.alt))
    #expect(press.text == event.characters(byApplyingModifiers: []))
}

@MainActor
@Test("option not acting as alt translates with Option and consumes it")
func optionNotAsAltConsumesOption() {
    let event = key(kVK_B, characters: "\u{222B}", unmodified: "b", flags: .option)

    let translation = TerminalInputController.translationEvent(for: event, optionAsAlt: .never)
    // No flags changed, so the *same* event object is reused — object identity keeps the Korean
    // input method working (Ghostty hit this too).
    #expect(translation === event)

    let press = TerminalInputController.keyPress(event: event, action: .press, optionAsAlt: .never)
    #expect(press.consumedMods.contains(.alt))
    // Translated *with* Option, so the text is the composed character the event already carries —
    // and specifically not the bare letter the option-as-alt path produces.
    #expect(press.text == event.characters)
    #expect(press.text != event.characters(byApplyingModifiers: []))
}

@MainActor
@Test("option-as-alt honours the side setting")
func optionAsAltHonoursSides() {
    let leftOption = key(kVK_B, characters: "\u{222B}", unmodified: "b", flags: .option)
    let rightOption = key(kVK_B, characters: "\u{222B}", unmodified: "b",
                          flags: flags(.option, deviceBits: NX_DEVICERALTKEYMASK))

    // `.left`: the left Option is Alt (unconsumed), the right one is not (consumed).
    #expect(!TerminalInputController
        .keyPress(event: leftOption, action: .press, optionAsAlt: .left)
        .consumedMods.contains(.alt))
    #expect(TerminalInputController
        .keyPress(event: rightOption, action: .press, optionAsAlt: .left)
        .consumedMods.contains(.alt))
}

@MainActor
@Test("Control and Command never count as consumed")
func controlAndCommandAreNeverConsumed() {
    let event = key(kVK_P, characters: "p", flags: [.control, .command, .shift])
    let press = TerminalInputController.keyPress(event: event, action: .press, optionAsAlt: .never)
    #expect(!press.consumedMods.contains(.control))
    #expect(!press.consumedMods.contains(.super_))
    #expect(press.consumedMods.contains(.shift))
}

// MARK: - Actions

@MainActor
@Test("a repeat is .repeated and a keyUp is .release")
func actionsMapFromTheEventType() {
    let repeated = key(kVK_B, characters: "b", isARepeat: true)
    let up = key(kVK_B, characters: "b", type: .keyUp)
    #expect(TerminalInputController.keyPress(event: repeated, action: .repeated, optionAsAlt: .never)
        .action == .repeated)
    #expect(TerminalInputController.keyPress(event: up, action: .release, optionAsAlt: .never)
        .action == .release)
}

// MARK: - performKeyEquivalent routing

@MainActor
@Test("⌘ shortcuts are declined so they reach the app, Ctrl combos are taken")
func commandShortcutsAreDeclined() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    view.inputDelegate = controller

    var encoded: [KeyPress] = []
    controller.encodeKey = { press in
        encoded.append(press)
        return []
    }

    // ⌘P (the palette) must fall through to the app: `performKeyEquivalent` returns false, the view
    // calls super, AppKit keeps walking the responder chain.
    let commandP = key(kVK_P, characters: "p", flags: .command)
    #expect(!controller.acceptsKeyDown(commandP, in: view))
    #expect(!view.performKeyEquivalent(with: commandP))
    #expect(encoded.isEmpty)

    // Ctrl-C must be taken here: the terminal, not the app, decides what an interrupt means.
    let controlC = key(kVK_C, characters: "\u{03}", unmodified: "c", flags: .control)
    #expect(controller.acceptsKeyDown(controlC, in: view))
    #expect(view.performKeyEquivalent(with: controlC))
    #expect(encoded.count == 1)
    #expect(encoded.first?.mods == [.control])
}

@MainActor
@Test("bytes from the encoder reach writeInput")
func encodedBytesReachWriteInput() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    view.inputDelegate = controller

    var written: [Data] = []
    controller.encodeKey = { _ in [0x1B, 0x5B, 0x41] }
    controller.writeInput = { written.append($0) }

    _ = view.performKeyEquivalent(with: key(kVK_Return, characters: "\r"))
    #expect(written == [Data([0x1B, 0x5B, 0x41])])
}

@MainActor
@Test("an empty encoding writes nothing — the normal result for a release in legacy mode")
func emptyEncodingWritesNothing() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    view.inputDelegate = controller

    var writes = 0
    controller.encodeKey = { _ in [] }
    controller.writeInput = { _ in writes += 1 }

    _ = view.performKeyEquivalent(with: key(kVK_Return, characters: "\r"))
    #expect(writes == 0)
}

// MARK: - flagsChanged

@MainActor
@Test("flagsChanged reports a press when the modifier's own side is down, a release otherwise")
func flagsChangedUsesSideBits() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    view.inputDelegate = controller

    var presses: [KeyPress] = []
    controller.encodeKey = { presses.append($0); return [] }

    // Right Shift down: `.shift` set *and* the right device bit set → press.
    let rightDown = key(kVK_RightShift, characters: "",
                        flags: flags(.shift, deviceBits: NX_DEVICERSHIFTKEYMASK), type: .flagsChanged)
    #expect(controller.terminalView(view, handle: rightDown))
    #expect(presses.last?.action == .press)
    #expect(presses.last?.key == GHOSTTY_KEY_SHIFT_RIGHT)
    #expect(presses.last?.mods.contains(.shiftRight) == true)

    // Both Shifts held, right one released: `.shift` is still set (the left one), but the *right*
    // device bit is gone — that is a release of the right Shift, not a second press.
    let rightUpLeftHeld = key(kVK_RightShift, characters: "", flags: .shift, type: .flagsChanged)
    #expect(controller.terminalView(view, handle: rightUpLeftHeld))
    #expect(presses.last?.action == .release)

    // Left Shift up: no `.shift` at all → release.
    let leftUp = key(kVK_Shift, characters: "", flags: [], type: .flagsChanged)
    #expect(controller.terminalView(view, handle: leftUp))
    #expect(presses.last?.action == .release)
    #expect(presses.last?.key == GHOSTTY_KEY_SHIFT_LEFT)
}

@MainActor
@Test("a non-modifier flagsChanged (Fn) is declined rather than encoded")
func flagsChangedIgnoresNonModifiers() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    view.inputDelegate = controller
    var presses = 0
    controller.encodeKey = { _ in presses += 1; return [] }

    let fn = key(0x3F, characters: "", flags: .function, type: .flagsChanged)
    #expect(!controller.terminalView(view, handle: fn))
    #expect(presses == 0)
}

// MARK: - Mouse router

@MainActor
@Test("every mouse and scroll event is forwarded to the mouse handler, verdict and all")
func mouseEventsAreRoutedToTheHandler() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    let mouse = StubMouseHandler()
    controller.mouseHandler = mouse
    view.inputDelegate = controller

    let types: [NSEvent.EventType] = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved,
    ]
    for type in types {
        let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        #expect(controller.terminalView(view, handle: event))
    }
    #expect(mouse.seen == types)

    // The router returns the handler's verdict verbatim, so declining reaches `super`.
    mouse.consume = false
    let declined = NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    #expect(!controller.terminalView(view, handle: declined))
}

@MainActor
@Test("with no mouse handler installed, mouse events are declined")
func mouseEventsWithoutHandlerAreDeclined() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    view.inputDelegate = controller
    let event = NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    #expect(!controller.terminalView(view, handle: event))
}

// MARK: - Focus reporting (DEC 1004)

@MainActor
@Test("focus in/out encodes CSI I / CSI O only when mode 1004 is set")
func focusReportingRespectsMode1004() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    view.inputDelegate = controller

    var written: [Data] = []
    controller.writeInput = { written.append($0) }

    // Mode off: nothing at all.
    controller.isFocusReportingEnabled = { false }
    controller.terminalView(view, didChangeFocus: true)
    #expect(written.isEmpty)

    controller.isFocusReportingEnabled = { true }
    controller.terminalView(view, didChangeFocus: true)
    controller.terminalView(view, didChangeFocus: false)
    #expect(written == [Data("\u{1B}[I".utf8), Data("\u{1B}[O".utf8)])
}

@MainActor
@Test("ghostty_focus_encode produces the documented CSI I / CSI O")
func focusEncodeBytes() {
    #expect(TerminalInputController.encodeFocus(gained: true) == Array("\u{1B}[I".utf8))
    #expect(TerminalInputController.encodeFocus(gained: false) == Array("\u{1B}[O".utf8))
}

// MARK: - NSTextInputClient

@MainActor
@Test("insertText inside a keyDown becomes a key press; outside one it becomes a TEXT paste")
func insertTextRoutesByContext() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    view.inputDelegate = controller

    // The isolated `@MainActor NSTextInputClient` conformance is what makes this non-nil, and a nil
    // input context means no IME at all — dead keys, Japanese, emoji picker, dictation.
    #expect(view.inputContext != nil)

    var pasted: [String] = []
    controller.insertPastedText = { pasted.append($0) }

    // Outside a keyDown — the emoji picker or dictation.
    view.insertText("😀", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(pasted == ["😀"])

    // Inside a keyDown the accumulator swallows it, so it can be sent as typed input instead.
    controller.keyTextAccumulator = []
    view.insertText("ü", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(controller.keyTextAccumulator == ["ü"])
    #expect(pasted == ["😀"])
    controller.keyTextAccumulator = nil
}

@MainActor
@Test("marked text is tracked as a preedit and cleared on commit")
func markedTextIsTracked() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    view.inputDelegate = controller

    var preedits: [String] = []
    controller.onPreeditChange = { preedits.append($0) }

    #expect(!view.hasMarkedText())
    view.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.hasMarkedText())
    #expect(controller.preedit == "にほんご")
    #expect(view.markedRange() == NSRange(location: 0, length: 4))

    view.unmarkText()
    #expect(!view.hasMarkedText())
    #expect(preedits == ["にほんご", ""])
}

@MainActor
@Test("while composing, releases and modifier changes are swallowed instead of encoded")
func composingSwallowsReleasesAndModifiers() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    view.inputDelegate = controller

    var presses: [KeyPress] = []
    controller.encodeKey = { presses.append($0); return [] }

    // Baseline: outside a composition both of these do encode something.
    #expect(controller.terminalView(view, handle: key(kVK_B, characters: "b", type: .keyUp)))
    #expect(controller.terminalView(
        view, handle: key(kVK_Shift, characters: "", flags: .shift, type: .flagsChanged)))
    #expect(presses.count == 2)
    presses.removeAll()

    // Inside one, the IME owns the keyboard: a release or a modifier change must not reach the pty
    // and must not fall through to `super` either.
    view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(controller.hasMarkedText)
    #expect(controller.terminalView(view, handle: key(kVK_B, characters: "b", type: .keyUp)))
    #expect(controller.terminalView(
        view, handle: key(kVK_Shift, characters: "", flags: .shift, type: .flagsChanged)))
    #expect(presses.isEmpty)
}

@MainActor
@Test("a composing press is flagged so libghostty suppresses the preedit echo")
func composingFlagReachesTheKeyPress() {
    let event = key(kVK_B, characters: "b")
    let press = TerminalInputController.keyPress(
        event: event, action: .press, optionAsAlt: .never, text: "b", composing: true)
    #expect(press.composing)
}

@MainActor
@Test("a bare control character during composition belongs to the IME, not the pty")
func bareControlDuringCompositionIsSuppressed() {
    #expect(TerminalInputController.isBareControl("\u{08}", composing: true))
    #expect(!TerminalInputController.isBareControl("\u{08}", composing: false))
    #expect(!TerminalInputController.isBareControl("a", composing: true))
    #expect(!TerminalInputController.isBareControl(nil, composing: true))
}

@MainActor
@Test("firstRect is the cursor cell, and is .zero without a window")
func firstRectNeedsAWindow() throws {
    let view = try makeView()
    // No window: there is no screen space to report, and returning a bogus rect would park the
    // candidate window in a corner.
    #expect(view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil) == .zero)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
    let metrics = view.cellMetrics
    let scale = max(view.backingScale, 1)
    #expect(abs(rect.width - CGFloat(metrics.width) / scale) < 0.01)
    #expect(abs(rect.height - CGFloat(metrics.height) / scale) < 0.01)
}

// MARK: - End to end, against the real libghostty encoder

/// The controller wired to a real `KeyEncoder` over a real (headless) terminal.
///
/// This is as close to "typing reaches the shell" as anything can get without the missing
/// `TerminalSession.encode` seam: it is the production `NSEvent` → `KeyPress` path, the production
/// encoder, and the production `writeInput` seam — only the pty is replaced by an array. The byte
/// expectations are the legacy column of docs/keys.md.
@MainActor
@Test("a synthesized keystroke travels NSEvent → KeyPress → libghostty → bytes")
func endToEndAgainstTheRealEncoder() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    view.inputDelegate = controller

    let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
    let encoder = try KeyEncoder()
    var written = Data()
    controller.encodeKey = { [controller] press in
        try encoder.encode(press, terminal: terminal, optionAsAlt: controller.optionAsAlt)
    }
    controller.writeInput = { written.append($0) }

    func bytes(_ event: NSEvent) -> Data {
        written.removeAll()
        _ = controller.terminalView(view, handle: event)
        return written
    }

    // Enter is CR; Shift+Enter is *not* — libghostty's PC-style table encodes it as fixterm
    // CSI 27;2;13~ in legacy mode (and CSI 13;2u under kitty). Claude Code relies on the difference.
    #expect(bytes(key(kVK_Return, characters: "\r")) == Data("\r".utf8))
    #expect(bytes(key(kVK_Return, characters: "\r", flags: .shift)) == Data("\u{1B}[27;2;13~".utf8))

    // Ctrl-C: the control byte is derived by libghostty from key + mods, never passed as text.
    #expect(bytes(key(kVK_C, characters: "\u{03}", unmodified: "c", flags: .control)) == Data([0x03]))

    // Shift+Tab: AppKit's U+0019 is filtered away and the key alone produces CSI Z.
    #expect(bytes(key(kVK_Tab, characters: "\u{19}", flags: .shift)) == Data("\u{1B}[Z".utf8))

    // Option-as-Alt: ESC + the *unshifted* letter, which is the whole point of leaving Option
    // unconsumed. The letter comes from the active layout so this holds on any keyboard.
    controller.optionAsAlt = .both
    let optionB = key(kVK_B, characters: "\u{222B}", unmodified: "b", flags: .option)
    let letter = try #require(optionB.characters(byApplyingModifiers: []))
    #expect(bytes(optionB) == Data("\u{1B}\(letter)".utf8))

    // The same key with Option *not* acting as Alt sends the composed character instead.
    controller.optionAsAlt = .never
    #expect(bytes(optionB) == Data("\u{222B}".utf8))
}

@MainActor
@Test("focus changes reach the mouse handler as well as the terminal")
func focusChangesReachTheMouseHandler() throws {
    let view = try makeView()
    let controller = TerminalInputController()
    let mouse = StubMouseHandler()
    controller.mouseHandler = mouse
    view.inputDelegate = controller

    controller.terminalView(view, didChangeFocus: false)
    // The mouse handler has to drop held buttons on focus loss; this delegate is its only route to
    // that event, because the controller is the sole `TerminalViewInputDelegate`.
    #expect(mouse.focusChanges == [false])
}
