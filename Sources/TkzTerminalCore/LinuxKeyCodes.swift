// LinuxKeyCodes.swift — Linux evdev key code (`KEY_*`) → `GhosttyKey`. The sibling of MacKeyCodes.
//
// GTK reports the X11/xkb keycode, which is the evdev code + 8; the GTK layer subtracts the 8
// (`gdk_key_event_get_keycode() - 8`, WOR-315 S2) and everything here speaks evdev. The values
// are the `KEY_*` constants of `/usr/include/linux/input-event-codes.h` (named in the comments),
// mapped to the W3C UI Events `code` values `GhosttyKey` is derived from. Written from those two
// sources; not copied from Ghostty, cmux or any other keycode table.
//
// Like the Mac table this is physical and layout independent: KEY_Q is the key labelled "A" on
// AZERTY and still reports `GHOSTTY_KEY_Q`. The layout reaches the encoder through the keyval
// (`KeyPress.text`, `KeyPress.unshiftedCodepoint`) in `LinuxKeyTranslator`.
//
// No GTK, no Linux headers: the codes are literals, so the table lives in TkzTerminalCore and
// tests headlessly on both OSes.
import GhosttyVt

/// The Linux evdev key code table.
public enum LinuxKeyCodes {
    // MARK: Codes the translator and its tests name (input-event-codes.h)

    public static let leftCtrl: UInt32 = 29        // KEY_LEFTCTRL
    public static let leftShift: UInt32 = 42       // KEY_LEFTSHIFT
    public static let rightShift: UInt32 = 54      // KEY_RIGHTSHIFT
    public static let leftAlt: UInt32 = 56         // KEY_LEFTALT
    public static let rightCtrl: UInt32 = 97       // KEY_RIGHTCTRL
    public static let rightAlt: UInt32 = 100       // KEY_RIGHTALT (AltGr on most non-US layouts)
    public static let leftMeta: UInt32 = 125       // KEY_LEFTMETA (Super)
    public static let rightMeta: UInt32 = 126      // KEY_RIGHTMETA

    /// The right-hand modifier codes. `ModifierSideTracker` sets a `*Right` side bit from these.
    public static func isRightModifier(_ code: UInt32) -> Bool {
        code == rightShift || code == rightCtrl || code == rightAlt || code == rightMeta
    }

    /// Map an evdev key code to a layout-independent `GhosttyKey`.
    ///
    /// Returns `GHOSTTY_KEY_UNIDENTIFIED` for codes with no `GhosttyKey` equivalent (the Korean
    /// Hangeul/Hanja keys, JIS Katakana/Hiragana/Zenkaku-Hankaku, most consumer-control keys).
    /// The encoder accepts it and works from `text` alone, as on the Mac.
    ///
    /// This is the physical key only. A keypad key with NumLock off is a navigation key, which
    /// only the keyval says: use ``key(forEvdevCode:keyval:)`` for real events.
    public static func key(forEvdevCode code: UInt32) -> GhosttyKey {
        switch code {
        // MARK: Writing system keys — letters (W3C § 3.1.1)
        case 30: return GHOSTTY_KEY_A                // KEY_A
        case 48: return GHOSTTY_KEY_B                // KEY_B
        case 46: return GHOSTTY_KEY_C                // KEY_C
        case 32: return GHOSTTY_KEY_D                // KEY_D
        case 18: return GHOSTTY_KEY_E                // KEY_E
        case 33: return GHOSTTY_KEY_F                // KEY_F
        case 34: return GHOSTTY_KEY_G                // KEY_G
        case 35: return GHOSTTY_KEY_H                // KEY_H
        case 23: return GHOSTTY_KEY_I                // KEY_I
        case 36: return GHOSTTY_KEY_J                // KEY_J
        case 37: return GHOSTTY_KEY_K                // KEY_K
        case 38: return GHOSTTY_KEY_L                // KEY_L
        case 50: return GHOSTTY_KEY_M                // KEY_M
        case 49: return GHOSTTY_KEY_N                // KEY_N
        case 24: return GHOSTTY_KEY_O                // KEY_O
        case 25: return GHOSTTY_KEY_P                // KEY_P
        case 16: return GHOSTTY_KEY_Q                // KEY_Q
        case 19: return GHOSTTY_KEY_R                // KEY_R
        case 31: return GHOSTTY_KEY_S                // KEY_S
        case 20: return GHOSTTY_KEY_T                // KEY_T
        case 22: return GHOSTTY_KEY_U                // KEY_U
        case 47: return GHOSTTY_KEY_V                // KEY_V
        case 17: return GHOSTTY_KEY_W                // KEY_W
        case 45: return GHOSTTY_KEY_X                // KEY_X
        case 21: return GHOSTTY_KEY_Y                // KEY_Y
        case 44: return GHOSTTY_KEY_Z                // KEY_Z

        // MARK: Writing system keys — digit row
        case 2: return GHOSTTY_KEY_DIGIT_1           // KEY_1
        case 3: return GHOSTTY_KEY_DIGIT_2           // KEY_2
        case 4: return GHOSTTY_KEY_DIGIT_3           // KEY_3
        case 5: return GHOSTTY_KEY_DIGIT_4           // KEY_4
        case 6: return GHOSTTY_KEY_DIGIT_5           // KEY_5
        case 7: return GHOSTTY_KEY_DIGIT_6           // KEY_6
        case 8: return GHOSTTY_KEY_DIGIT_7           // KEY_7
        case 9: return GHOSTTY_KEY_DIGIT_8           // KEY_8
        case 10: return GHOSTTY_KEY_DIGIT_9          // KEY_9
        case 11: return GHOSTTY_KEY_DIGIT_0          // KEY_0

        // MARK: Writing system keys — punctuation
        case 41: return GHOSTTY_KEY_BACKQUOTE        // KEY_GRAVE (§ on se, ^ on de, ² on fr)
        case 12: return GHOSTTY_KEY_MINUS            // KEY_MINUS
        case 13: return GHOSTTY_KEY_EQUAL            // KEY_EQUAL
        case 26: return GHOSTTY_KEY_BRACKET_LEFT     // KEY_LEFTBRACE (å on se)
        case 27: return GHOSTTY_KEY_BRACKET_RIGHT    // KEY_RIGHTBRACE (¨ on se)
        case 43: return GHOSTTY_KEY_BACKSLASH        // KEY_BACKSLASH (' on se, the ISO key by Enter)
        case 39: return GHOSTTY_KEY_SEMICOLON        // KEY_SEMICOLON
        case 40: return GHOSTTY_KEY_QUOTE            // KEY_APOSTROPHE
        case 51: return GHOSTTY_KEY_COMMA            // KEY_COMMA
        case 52: return GHOSTTY_KEY_PERIOD           // KEY_DOT
        case 53: return GHOSTTY_KEY_SLASH            // KEY_SLASH

        // MARK: International writing system keys
        case 86: return GHOSTTY_KEY_INTL_BACKSLASH   // KEY_102ND (the ISO <> key left of Z)
        case 89: return GHOSTTY_KEY_INTL_RO          // KEY_RO (JIS)
        case 124: return GHOSTTY_KEY_INTL_YEN        // KEY_YEN (JIS)
        case 92: return GHOSTTY_KEY_CONVERT          // KEY_HENKAN (JIS 変換)
        case 94: return GHOSTTY_KEY_NON_CONVERT      // KEY_MUHENKAN (JIS 無変換)
        case 93: return GHOSTTY_KEY_KANA_MODE        // KEY_KATAKANAHIRAGANA (W3C "KanaMode")
        // KEY_HANGEUL (122) and KEY_HANJA (123) are W3C "Lang1"/"Lang2", and KEY_KATAKANA (90),
        // KEY_HIRAGANA (91) and KEY_ZENKAKUHANKAKU (85) "Lang3"/"Lang4"/"Lang5": no GhosttyKey.

        // MARK: Functional keys (W3C § 3.1.2)
        case 28: return GHOSTTY_KEY_ENTER            // KEY_ENTER
        case 15: return GHOSTTY_KEY_TAB              // KEY_TAB
        case 57: return GHOSTTY_KEY_SPACE            // KEY_SPACE
        case 14: return GHOSTTY_KEY_BACKSPACE        // KEY_BACKSPACE
        case 1: return GHOSTTY_KEY_ESCAPE            // KEY_ESC
        case 127: return GHOSTTY_KEY_CONTEXT_MENU    // KEY_COMPOSE (the PC Menu/Application key)

        // MARK: Modifier keys, both sides
        case 42: return GHOSTTY_KEY_SHIFT_LEFT       // KEY_LEFTSHIFT
        case 54: return GHOSTTY_KEY_SHIFT_RIGHT      // KEY_RIGHTSHIFT
        case 29: return GHOSTTY_KEY_CONTROL_LEFT     // KEY_LEFTCTRL
        case 97: return GHOSTTY_KEY_CONTROL_RIGHT    // KEY_RIGHTCTRL
        case 56: return GHOSTTY_KEY_ALT_LEFT         // KEY_LEFTALT
        case 100: return GHOSTTY_KEY_ALT_RIGHT       // KEY_RIGHTALT (physical; AltGr is still this key)
        case 125: return GHOSTTY_KEY_META_LEFT       // KEY_LEFTMETA (Super, ⌘ on Linux)
        case 126: return GHOSTTY_KEY_META_RIGHT      // KEY_RIGHTMETA
        case 58: return GHOSTTY_KEY_CAPS_LOCK        // KEY_CAPSLOCK
        case 0x1D0: return GHOSTTY_KEY_FN            // KEY_FN

        // MARK: Control pad (W3C § 3.2)
        case 110: return GHOSTTY_KEY_INSERT          // KEY_INSERT
        case 102: return GHOSTTY_KEY_HOME            // KEY_HOME
        case 104: return GHOSTTY_KEY_PAGE_UP         // KEY_PAGEUP
        case 111: return GHOSTTY_KEY_DELETE          // KEY_DELETE
        case 107: return GHOSTTY_KEY_END             // KEY_END
        case 109: return GHOSTTY_KEY_PAGE_DOWN       // KEY_PAGEDOWN
        case 138: return GHOSTTY_KEY_HELP            // KEY_HELP
        case 99: return GHOSTTY_KEY_PRINT_SCREEN     // KEY_SYSRQ (Print / SysRq)
        case 70: return GHOSTTY_KEY_SCROLL_LOCK      // KEY_SCROLLLOCK
        case 119: return GHOSTTY_KEY_PAUSE           // KEY_PAUSE

        // MARK: Arrow pad (W3C § 3.3)
        case 105: return GHOSTTY_KEY_ARROW_LEFT      // KEY_LEFT
        case 106: return GHOSTTY_KEY_ARROW_RIGHT     // KEY_RIGHT
        case 108: return GHOSTTY_KEY_ARROW_DOWN      // KEY_DOWN
        case 103: return GHOSTTY_KEY_ARROW_UP        // KEY_UP

        // MARK: Numpad (W3C § 3.4)
        case 69: return GHOSTTY_KEY_NUM_LOCK         // KEY_NUMLOCK
        case 82: return GHOSTTY_KEY_NUMPAD_0         // KEY_KP0
        case 79: return GHOSTTY_KEY_NUMPAD_1         // KEY_KP1
        case 80: return GHOSTTY_KEY_NUMPAD_2         // KEY_KP2
        case 81: return GHOSTTY_KEY_NUMPAD_3         // KEY_KP3
        case 75: return GHOSTTY_KEY_NUMPAD_4         // KEY_KP4
        case 76: return GHOSTTY_KEY_NUMPAD_5         // KEY_KP5
        case 77: return GHOSTTY_KEY_NUMPAD_6         // KEY_KP6
        case 71: return GHOSTTY_KEY_NUMPAD_7         // KEY_KP7
        case 72: return GHOSTTY_KEY_NUMPAD_8         // KEY_KP8
        case 73: return GHOSTTY_KEY_NUMPAD_9         // KEY_KP9
        case 83: return GHOSTTY_KEY_NUMPAD_DECIMAL   // KEY_KPDOT
        case 55: return GHOSTTY_KEY_NUMPAD_MULTIPLY  // KEY_KPASTERISK
        case 78: return GHOSTTY_KEY_NUMPAD_ADD       // KEY_KPPLUS
        case 74: return GHOSTTY_KEY_NUMPAD_SUBTRACT  // KEY_KPMINUS
        case 98: return GHOSTTY_KEY_NUMPAD_DIVIDE    // KEY_KPSLASH
        case 96: return GHOSTTY_KEY_NUMPAD_ENTER     // KEY_KPENTER
        case 117: return GHOSTTY_KEY_NUMPAD_EQUAL    // KEY_KPEQUAL
        case 121: return GHOSTTY_KEY_NUMPAD_COMMA    // KEY_KPCOMMA (W3C "NumpadComma")
        case 179: return GHOSTTY_KEY_NUMPAD_PAREN_LEFT   // KEY_KPLEFTPAREN
        case 180: return GHOSTTY_KEY_NUMPAD_PAREN_RIGHT  // KEY_KPRIGHTPAREN
        // KEY_KPJPCOMMA (95) is a second NumpadComma; it stays unidentified so the table is
        // injective (one code per GhosttyKey), and the encoder still has its text.

        // MARK: Function keys (W3C § 3.5)
        case 59: return GHOSTTY_KEY_F1               // KEY_F1
        case 60: return GHOSTTY_KEY_F2               // KEY_F2
        case 61: return GHOSTTY_KEY_F3               // KEY_F3
        case 62: return GHOSTTY_KEY_F4               // KEY_F4
        case 63: return GHOSTTY_KEY_F5               // KEY_F5
        case 64: return GHOSTTY_KEY_F6               // KEY_F6
        case 65: return GHOSTTY_KEY_F7               // KEY_F7
        case 66: return GHOSTTY_KEY_F8               // KEY_F8
        case 67: return GHOSTTY_KEY_F9               // KEY_F9
        case 68: return GHOSTTY_KEY_F10              // KEY_F10
        case 87: return GHOSTTY_KEY_F11              // KEY_F11
        case 88: return GHOSTTY_KEY_F12              // KEY_F12
        case 183: return GHOSTTY_KEY_F13             // KEY_F13
        case 184: return GHOSTTY_KEY_F14             // KEY_F14
        case 185: return GHOSTTY_KEY_F15             // KEY_F15
        case 186: return GHOSTTY_KEY_F16             // KEY_F16
        case 187: return GHOSTTY_KEY_F17             // KEY_F17
        case 188: return GHOSTTY_KEY_F18             // KEY_F18
        case 189: return GHOSTTY_KEY_F19             // KEY_F19
        case 190: return GHOSTTY_KEY_F20             // KEY_F20
        case 191: return GHOSTTY_KEY_F21             // KEY_F21
        case 192: return GHOSTTY_KEY_F22             // KEY_F22
        case 193: return GHOSTTY_KEY_F23             // KEY_F23
        case 194: return GHOSTTY_KEY_F24             // KEY_F24

        // MARK: Media and browser keys (W3C § 3.6)
        case 115: return GHOSTTY_KEY_AUDIO_VOLUME_UP     // KEY_VOLUMEUP
        case 114: return GHOSTTY_KEY_AUDIO_VOLUME_DOWN   // KEY_VOLUMEDOWN
        case 113: return GHOSTTY_KEY_AUDIO_VOLUME_MUTE   // KEY_MUTE
        case 164: return GHOSTTY_KEY_MEDIA_PLAY_PAUSE    // KEY_PLAYPAUSE
        case 166: return GHOSTTY_KEY_MEDIA_STOP          // KEY_STOPCD
        case 163: return GHOSTTY_KEY_MEDIA_TRACK_NEXT    // KEY_NEXTSONG
        case 165: return GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS  // KEY_PREVIOUSSONG
        case 171: return GHOSTTY_KEY_MEDIA_SELECT        // KEY_CONFIG (AL Consumer Control Configuration)
        case 161: return GHOSTTY_KEY_EJECT               // KEY_EJECTCD
        case 158: return GHOSTTY_KEY_BROWSER_BACK        // KEY_BACK
        case 159: return GHOSTTY_KEY_BROWSER_FORWARD     // KEY_FORWARD
        case 156: return GHOSTTY_KEY_BROWSER_FAVORITES   // KEY_BOOKMARKS
        case 172: return GHOSTTY_KEY_BROWSER_HOME        // KEY_HOMEPAGE
        case 173: return GHOSTTY_KEY_BROWSER_REFRESH     // KEY_REFRESH
        case 217: return GHOSTTY_KEY_BROWSER_SEARCH      // KEY_SEARCH
        case 128: return GHOSTTY_KEY_BROWSER_STOP        // KEY_STOP
        case 155: return GHOSTTY_KEY_LAUNCH_MAIL         // KEY_MAIL
        case 157: return GHOSTTY_KEY_LAUNCH_APP_1        // KEY_COMPUTER (W3C "LaunchApp1")
        case 140: return GHOSTTY_KEY_LAUNCH_APP_2        // KEY_CALC (W3C "LaunchApp2")
        case 116: return GHOSTTY_KEY_POWER               // KEY_POWER
        case 142: return GHOSTTY_KEY_SLEEP               // KEY_SLEEP
        case 143: return GHOSTTY_KEY_WAKE_UP             // KEY_WAKEUP
        case 133: return GHOSTTY_KEY_COPY                // KEY_COPY
        case 137: return GHOSTTY_KEY_CUT                 // KEY_CUT
        case 135: return GHOSTTY_KEY_PASTE               // KEY_PASTE

        default: return GHOSTTY_KEY_UNIDENTIFIED
        }
    }

    /// The key for a real event: the physical key, except that a keypad key producing a keypad
    /// *navigation* keysym is that navigation key.
    ///
    /// With NumLock off, KEY_KP8 produces `KP_Up` and must encode as an arrow (`ESC [ A`, or the
    /// kitty keypad code), not as the digit key with no text. The keysym decides, not the NumLock
    /// bit: which level a keypad key is on depends on the keymap (`numpad:*` and `keypad:*`
    /// options change it), and the keyval GDK reports already has the answer.
    public static func key(forEvdevCode code: UInt32, keyval: UInt32) -> GhosttyKey {
        let physical = key(forEvdevCode: code)
        guard isKeypadDigitOrDecimal(physical) else { return physical }
        switch keyval {
        case LinuxKeysyms.kpHome: return GHOSTTY_KEY_NUMPAD_HOME
        case LinuxKeysyms.kpLeft: return GHOSTTY_KEY_NUMPAD_LEFT
        case LinuxKeysyms.kpUp: return GHOSTTY_KEY_NUMPAD_UP
        case LinuxKeysyms.kpRight: return GHOSTTY_KEY_NUMPAD_RIGHT
        case LinuxKeysyms.kpDown: return GHOSTTY_KEY_NUMPAD_DOWN
        case LinuxKeysyms.kpPageUp: return GHOSTTY_KEY_NUMPAD_PAGE_UP
        case LinuxKeysyms.kpPageDown: return GHOSTTY_KEY_NUMPAD_PAGE_DOWN
        case LinuxKeysyms.kpEnd: return GHOSTTY_KEY_NUMPAD_END
        case LinuxKeysyms.kpBegin: return GHOSTTY_KEY_NUMPAD_BEGIN
        case LinuxKeysyms.kpInsert: return GHOSTTY_KEY_NUMPAD_INSERT
        case LinuxKeysyms.kpDelete: return GHOSTTY_KEY_NUMPAD_DELETE
        default: return physical
        }
    }

    private static func isKeypadDigitOrDecimal(_ key: GhosttyKey) -> Bool {
        switch key {
        case GHOSTTY_KEY_NUMPAD_0, GHOSTTY_KEY_NUMPAD_1, GHOSTTY_KEY_NUMPAD_2, GHOSTTY_KEY_NUMPAD_3,
             GHOSTTY_KEY_NUMPAD_4, GHOSTTY_KEY_NUMPAD_5, GHOSTTY_KEY_NUMPAD_6, GHOSTTY_KEY_NUMPAD_7,
             GHOSTTY_KEY_NUMPAD_8, GHOSTTY_KEY_NUMPAD_9, GHOSTTY_KEY_NUMPAD_DECIMAL:
            return true
        default:
            return false
        }
    }
}
