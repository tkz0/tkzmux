// LinuxKeyTranslator.swift — GDK key event facts → `KeyPress` (WOR-315 S1). Pure, no GTK.
//
// The Linux half of what `TerminalInputController.keyPress(event:…)` does for an `NSEvent`. The
// GTK layer (WOR-315 S2) reads a handful of plain facts off each `GdkEvent` into `LinuxKeyFacts`;
// everything that decides bytes happens here, so it unit-tests headlessly on both OSes against the
// layout fixtures generated with libxkbcommon (Tests/LinuxKeymapTests, committed as JSON).
//
// Lives in TkzTerminalCore next to `KeyEncoder` until WOR-310 creates TkzTerminalInput, which may
// move it there unchanged.
//
// ## The rules, and why
//
// * **Text comes from the keyval, with no Ctrl transform.** GDK's keyval for Ctrl+C is `c`, and
//   control-character encoding is libghostty's job from `key` + `mods` (`KeyPress.text`). Control
//   characters, DEL and the keysyms with no character (ISO_Left_Tab, arrows, dead keys) give "".
// * **Only Shift is ever consumed, and it is consumed whenever it is held** (on a non-modifier
//   key). That is the Mac's heuristic with Option acting as Alt (`translationModifiers` minus
//   Control and Command), so a `KeyPress` is identical on both OSes (Tests/.../key-parity.json).
//   GDK's own consumed set is deliberately not read: xkb leaves Shift unconsumed on one-level
//   keys, and libghostty then encodes Shift+Space as `CSI 32;2u` under Claude Code's `CSI > 5 u`
//   where the Mac sends a space (measured, LinuxKeyTranslatorTests). Lock is never consumed
//   either; whether it is changes no byte (also measured there).
// * **Alt is never consumed, and AltGr is never Alt.** Right Alt on `se`, `de`, `fr` and
//   `us(intl)` is `ISO_Level3_Shift`: a level shift that composes text (`AltGr+8` → `[` on `se`)
//   and has no GDK modifier bit. GDK_ALT_MASK is Mod1, which only the Alt keys set, so
//   left Alt+B is `ESC b` / `CSI 98;3u` on every layout. There is no option-as-alt setting on
//   Linux: a Linux build of libghostty never reads `MACOS_OPTION_AS_ALT` (a Darwin build does,
//   which is why LinuxKeyTranslatorTests encode with `.both` when they run on macOS).
// * **`unshiftedCodepoint` comes from the level-0 keyval** of the active layout (the GTK layer
//   looks it up with `gdk_display_map_keycode`). On `se` the key labelled 8 is `8` even with
//   AltGr held, which is what kitty's alternate-key reporting wants.
// * **NumLock is never reported.** libghostty adds `num_lock` (128) to every kitty CSI it writes,
//   so with NumLock on — the normal state of a Linux desktop — Up would become `CSI 1;129A` and
//   Ctrl+C `CSI 99;133u`. The Mac never reports it. NumLock reaches the translator only through
//   the keyval, which decides whether a keypad key is a digit or a navigation key
//   (`LinuxKeyCodes.key(forEvdevCode:keyval:)`), so the GTK layer need not read it for keys.
// * **Super is `.super_`, Meta is ignored.** GDK_SUPER_MASK is ⌘'s modifier (ADR-0004 §1);
//   GDK_META_MASK and GDK_HYPER_MASK never contribute.
// * **Side bits come from the keys held**, which xkb does not track: `ModifierSideTracker`.
// * **`.repeated` is inferred**: a press of a code that is already down. Hyprland never sends
//   wl_keyboard `repeated` (wl_seat v9), so GDK's client-side repeat re-delivers presses.
// * **A modifier key's own event carries the modifier state after it**, as the Mac's
//   `flagsChanged` does: on Wayland GDK reports the state from before the event (the compositor
//   sends wl_keyboard.modifiers after the key), so a Shift press arrives without Shift and its
//   release with it, and the translator adds or removes the key's own bit. WOR-315 S2 checks
//   this against live events.

import GhosttyVt

// MARK: - GDK modifier state

/// The `GdkModifierType` bits the translator reads, bit for bit (`gdk/gdkenums.h`), so the GTK
/// layer passes `gdk_event_get_modifier_state()` straight through.
public struct LinuxModifierMask: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = LinuxModifierMask(rawValue: 1 << 0)     // GDK_SHIFT_MASK
    public static let lock = LinuxModifierMask(rawValue: 1 << 1)      // GDK_LOCK_MASK (Caps Lock)
    public static let control = LinuxModifierMask(rawValue: 1 << 2)   // GDK_CONTROL_MASK
    public static let alt = LinuxModifierMask(rawValue: 1 << 3)       // GDK_ALT_MASK (Mod1)
    public static let super_ = LinuxModifierMask(rawValue: 1 << 26)   // GDK_SUPER_MASK
    public static let hyper = LinuxModifierMask(rawValue: 1 << 27)    // GDK_HYPER_MASK (ignored)
    public static let meta = LinuxModifierMask(rawValue: 1 << 28)     // GDK_META_MASK (ignored)
}

// MARK: - Facts

/// What the GTK layer reads off one key event (WOR-315 S2 fills it in).
public struct LinuxKeyFacts: Sendable, Hashable {
    /// `true` for `key-released`, `false` for `key-pressed` (repeats included).
    public var isRelease: Bool
    /// The evdev code: `gdk_key_event_get_keycode() - 8`.
    public var evdevCode: UInt32
    /// The keyval for this event, in the active layout and current modifier state
    /// (`gdk_key_event_get_keyval`).
    public var keyval: UInt32
    /// The keyval of the same key at level 0 of the active layout, or 0 if it has none
    /// (`gdk_display_map_keycode`, filtered to `gdk_key_event_get_layout`).
    public var levelZeroKeyval: UInt32
    /// The modifier state, as GDK reports it: from *before* this event.
    public var state: LinuxModifierMask

    public init(
        isRelease: Bool = false,
        evdevCode: UInt32,
        keyval: UInt32,
        levelZeroKeyval: UInt32,
        state: LinuxModifierMask = []
    ) {
        self.isRelease = isRelease
        self.evdevCode = evdevCode
        self.keyval = keyval
        self.levelZeroKeyval = levelZeroKeyval
        self.state = state
    }
}

// MARK: - Modifier keys

/// Which modifier a key event's keyval is, if any. Decided by keyval, not by code: Right Alt is
/// Alt on `us` and AltGr (no modifier) on `se`, and a remapped key (`caps:ctrl_modifier`) is the
/// modifier it types. `Meta_L`/`Meta_R` count as Alt: they are what the Alt keys report on some
/// keymaps.
enum LinuxModifierKey {
    static func modifier(forKeyval keyval: UInt32) -> KeyModifiers? {
        switch keyval {
        case LinuxKeysyms.shiftL, LinuxKeysyms.shiftR: return .shift
        case LinuxKeysyms.controlL, LinuxKeysyms.controlR: return .control
        case LinuxKeysyms.altL, LinuxKeysyms.altR, LinuxKeysyms.metaL, LinuxKeysyms.metaR: return .alt
        case LinuxKeysyms.superL, LinuxKeysyms.superR: return .super_
        default: return nil
        }
    }

    /// The `*Right` side bit that goes with a modifier.
    static func rightBit(of modifier: KeyModifiers) -> KeyModifiers {
        switch modifier {
        case .shift: return .shiftRight
        case .control: return .controlRight
        case .alt: return .altRight
        case .super_: return .superRight
        default: return []
        }
    }
}

// MARK: - ModifierSideTracker

/// Which side of each modifier is held, from the key events themselves.
///
/// xkb has no modifier sides, so GDK cannot say whether Shift is the left or the right one. The
/// tracker remembers each modifier key that is down by evdev code; a right-hand code (KEY_RIGHT*),
/// or a `*_R` keysym on a remapped key, makes the `*Right` bit. Like the Mac's device masks, the right bit is set whenever the right
/// key is down, and absent means "left" (libghostty cannot say "both").
///
/// A Right Alt that produced `ISO_Level3_Shift` (AltGr) is not Alt and is not tracked, so it can
/// never turn a left Alt into `.altRight`.
///
/// Reset it on focus-out (WOR-315 S2): a release that happens in another window never arrives.
public struct ModifierSideTracker: Sendable, Hashable {
    /// Down modifier keys: evdev code → (modifier, right-hand).
    private var held: [UInt32: Held] = [:]

    private struct Held: Sendable, Hashable {
        var modifier: KeyModifiers
        var isRight: Bool
    }

    public init() {}

    /// Record a key event. Non-modifier keys are ignored.
    public mutating func update(evdevCode: UInt32, keyval: UInt32, isRelease: Bool) {
        if isRelease {
            held[evdevCode] = nil
            return
        }
        guard let modifier = LinuxModifierKey.modifier(forKeyval: keyval) else { return }
        let isRight = LinuxKeyCodes.isRightModifier(evdevCode)
            || keyval == LinuxKeysyms.shiftR || keyval == LinuxKeysyms.controlR
            || keyval == LinuxKeysyms.altR || keyval == LinuxKeysyms.metaR
            || keyval == LinuxKeysyms.superR
        held[evdevCode] = Held(modifier: modifier, isRight: isRight)
    }

    /// Whether any key acting as `modifier` is down.
    public func isHeld(_ modifier: KeyModifiers) -> Bool {
        held.values.contains { $0.modifier == modifier }
    }

    /// `mods` with the side bit of every present modifier whose right-hand key is down.
    public func applyingSides(to mods: KeyModifiers) -> KeyModifiers {
        var result = mods
        for modifier in [KeyModifiers.shift, .control, .alt, .super_] where mods.contains(modifier) {
            if held.values.contains(where: { $0.modifier == modifier && $0.isRight }) {
                result.insert(LinuxModifierKey.rightBit(of: modifier))
            }
        }
        return result
    }

    /// Forget every held key (focus-out).
    public mutating func reset() { held.removeAll() }
}

// MARK: - LinuxKeyTranslator

/// Turns `LinuxKeyFacts` into `KeyPress` values. One per keyboard focus target.
///
/// Stateful only in the two things a single GDK event cannot say: which modifier sides are held
/// and which keys are already down (for `.repeated`). Both are reset on focus-out.
public struct LinuxKeyTranslator: Sendable {
    public private(set) var sides = ModifierSideTracker()
    private var pressed: Set<UInt32> = []

    public init() {}

    /// Translate one event. `composing` is the input method's verdict (WOR-310's composing
    /// policy, WOR-315 S4); it is passed through to `KeyPress.composing`.
    public mutating func translate(_ facts: LinuxKeyFacts, composing: Bool = false) -> KeyPress {
        let action: KeyPress.Action
        if facts.isRelease {
            action = .release
            pressed.remove(facts.evdevCode)
        } else if pressed.contains(facts.evdevCode) {
            action = .repeated
        } else {
            action = .press
            pressed.insert(facts.evdevCode)
        }
        if action != .repeated {
            sides.update(evdevCode: facts.evdevCode, keyval: facts.keyval, isRelease: facts.isRelease)
        }
        return Self.keyPress(facts, action: action, sides: sides, composing: composing)
    }

    /// Forget held keys and sides (focus-out, WOR-315 S2).
    public mutating func reset() {
        sides.reset()
        pressed.removeAll()
    }

    /// The stateless core: `facts` plus an already-updated side tracker → `KeyPress`.
    public static func keyPress(
        _ facts: LinuxKeyFacts,
        action: KeyPress.Action,
        sides: ModifierSideTracker,
        composing: Bool = false
    ) -> KeyPress {
        var mods: KeyModifiers = []
        if facts.state.contains(.shift) { mods.insert(.shift) }
        if facts.state.contains(.lock) { mods.insert(.capsLock) }
        if facts.state.contains(.control) { mods.insert(.control) }
        if facts.state.contains(.alt) { mods.insert(.alt) }
        if facts.state.contains(.super_) { mods.insert(.super_) }

        // A modifier key's own event: report the state after it, as `flagsChanged` does.
        let ownModifier = LinuxModifierKey.modifier(forKeyval: facts.keyval)
        if let ownModifier {
            if action == .release {
                if !sides.isHeld(ownModifier) { mods.remove(ownModifier) }
            } else {
                mods.insert(ownModifier)
            }
        }
        mods = sides.applyingSides(to: mods)

        var consumed: KeyModifiers = []
        if ownModifier == nil, mods.contains(.shift) {
            consumed = mods.intersection([.shift, .shiftRight])
        }

        return KeyPress(
            action: action,
            key: LinuxKeyCodes.key(forEvdevCode: facts.evdevCode, keyval: facts.keyval),
            mods: mods,
            consumedMods: consumed,
            text: action == .release ? "" : text(forKeyval: facts.keyval),
            unshiftedCodepoint: LinuxKeysyms.codepoint(ofKeysym: facts.levelZeroKeyval),
            composing: composing)
    }

    /// The text a keyval types: its character, or "" for none and for anything `KeyPress.text`
    /// must never carry (C0 controls, DEL, C1 controls).
    public static func text(forKeyval keyval: UInt32) -> String {
        let value = LinuxKeysyms.codepoint(ofKeysym: keyval)
        guard value >= 0x20, value != 0x7F, !(0x80...0x9F).contains(value),
              let scalar = Unicode.Scalar(value) else { return "" }
        return String(Character(scalar))
    }
}
