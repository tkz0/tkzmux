# Keyboard encoding matrix

**Generated — do not edit by hand.** Every cell below is produced by
`TkzTerminalCore.KeyEncoder` (libghostty-vt's key encoder) in
`Tests/TkzTerminalCoreTests/KeyEncoderTests.swift`. A normal `swift test --filter TkzTerminalCoreTests` asserts this file still matches the encoder; regenerate it with:

```sh
TKZMUX_UPDATE_KEYS_DOC=1 swift test --filter TkzTerminalCoreTests
```

## Columns

| Column | Terminal state |
|---|---|
| **legacy** | a fresh terminal: no kitty protocol, DECCKM off |
| **kitty(1)** | after `CSI > 1 u` — `DISAMBIGUATE` alone, the minimal protocol |
| **kitty(5)** | after `CSI > 5 u` — `DISAMBIGUATE \| REPORT_ALTERNATES`, **what real Claude Code pushes** |
| **DECCKM** | after `CSI ? 1 h` (application cursor keys), legacy protocol; cursor keys only |

The flag bits (`ghostty/vt/key/encoder.h`) are `DISAMBIGUATE` 1, `REPORT_EVENTS` 2,
`REPORT_ALTERNATES` 4, `REPORT_ALL` 8, `REPORT_ASSOCIATED` 16 — so `CSI > 5 u` is
`DISAMBIGUATE | REPORT_ALTERNATES`, **not** `REPORT_ALL`. `CSI > 5 u` appears four times in
`Tests/TkzTerminalCoreTests/Fixtures/claude-boot.tkzrec`; `CSI > 1 u` never does. The two
kitty columns differ only where a key has a shifted alternate to report (see Ctrl+Shift
rows): with `REPORT_ALL` unset, printable keys still send their text and Enter/Tab/
Backspace keep their legacy bytes, and with `REPORT_EVENTS` unset no release is reported.

Escaping is `cat -v`-ish: `\e` = ESC (0x1b), `\r` = 0x0d, `\t` = 0x09, `\xNN` for any
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

## Cursor and navigation keys

| Key | legacy | kitty(1) | kitty(5) | DECCKM |
|---|---|---|---|---|
| Up | `\e[A` | `\e[A` | `\e[A` | `\eOA` |
| Down | `\e[B` | `\e[B` | `\e[B` | `\eOB` |
| Right | `\e[C` | `\e[C` | `\e[C` | `\eOC` |
| Left | `\e[D` | `\e[D` | `\e[D` | `\eOD` |
| Shift+Up | `\e[1;2A` | `\e[1;2A` | `\e[1;2A` | `\e[1;2A` |
| Ctrl+Right | `\e[1;5C` | `\e[1;5C` | `\e[1;5C` | `\e[1;5C` |
| Home | `\e[H` | `\e[H` | `\e[H` | `\eOH` |
| End | `\e[F` | `\e[F` | `\e[F` | `\eOF` |
| PageUp | `\e[5~` | `\e[5~` | `\e[5~` | `\e[5~` |
| PageDown | `\e[6~` | `\e[6~` | `\e[6~` | `\e[6~` |
| Insert | `\e[2~` | `\e[2~` | `\e[2~` | `\e[2~` |

## Function keys

| Key | legacy | kitty(1) | kitty(5) |
|---|---|---|---|
| F1 | `\eOP` | `\e[P` | `\e[P` |
| F2 | `\eOQ` | `\e[Q` | `\e[Q` |
| F3 | `\eOR` | `\e[13~` | `\e[13~` |
| F4 | `\eOS` | `\e[S` | `\e[S` |
| F5 | `\e[15~` | `\e[15~` | `\e[15~` |
| F6 | `\e[17~` | `\e[17~` | `\e[17~` |
| F7 | `\e[18~` | `\e[18~` | `\e[18~` |
| F8 | `\e[19~` | `\e[19~` | `\e[19~` |
| F9 | `\e[20~` | `\e[20~` | `\e[20~` |
| F10 | `\e[21~` | `\e[21~` | `\e[21~` |
| F11 | `\e[23~` | `\e[23~` | `\e[23~` |
| F12 | `\e[24~` | `\e[24~` | `\e[24~` |

## Editing keys

| Key | legacy | kitty(1) | kitty(5) |
|---|---|---|---|
| Enter | `\r` | `\r` | `\r` |
| Shift+Enter | `\e[27;2;13~` | `\e[13;2u` | `\e[13;2u` |
| Escape | `\e` | `\e[27u` | `\e[27u` |
| Tab | `\t` | `\t` | `\t` |
| Shift+Tab | `\e[Z` | `\e[9;2u` | `\e[9;2u` |
| Backspace | `\x7f` | `\x7f` | `\x7f` |
| Shift+Backspace | `\x7f` | `\e[127;2u` | `\e[127;2u` |
| Ctrl+Backspace | `\x08` | `\e[127;5u` | `\e[127;5u` |
| Delete (forward) | `\e[3~` | `\e[3~` | `\e[3~` |
| Space | `\x20` | `\x20` | `\x20` |

## Control + letter

| Key | legacy | kitty(1) | kitty(5) |
|---|---|---|---|
| Ctrl+A | `\x01` | `\e[97;5u` | `\e[97;5u` |
| Ctrl+B | `\x02` | `\e[98;5u` | `\e[98;5u` |
| Ctrl+C | `\x03` | `\e[99;5u` | `\e[99;5u` |
| Ctrl+D | `\x04` | `\e[100;5u` | `\e[100;5u` |
| Ctrl+E | `\x05` | `\e[101;5u` | `\e[101;5u` |
| Ctrl+F | `\x06` | `\e[102;5u` | `\e[102;5u` |
| Ctrl+G | `\x07` | `\e[103;5u` | `\e[103;5u` |
| Ctrl+H | `\x08` | `\e[104;5u` | `\e[104;5u` |
| Ctrl+I | `\e[105;5u` | `\e[105;5u` | `\e[105;5u` |
| Ctrl+J | `\n` | `\e[106;5u` | `\e[106;5u` |
| Ctrl+K | `\x0b` | `\e[107;5u` | `\e[107;5u` |
| Ctrl+L | `\x0c` | `\e[108;5u` | `\e[108;5u` |
| Ctrl+M | `\e[109;5u` | `\e[109;5u` | `\e[109;5u` |
| Ctrl+N | `\x0e` | `\e[110;5u` | `\e[110;5u` |
| Ctrl+O | `\x0f` | `\e[111;5u` | `\e[111;5u` |
| Ctrl+P | `\x10` | `\e[112;5u` | `\e[112;5u` |
| Ctrl+Q | `\x11` | `\e[113;5u` | `\e[113;5u` |
| Ctrl+R | `\x12` | `\e[114;5u` | `\e[114;5u` |
| Ctrl+S | `\x13` | `\e[115;5u` | `\e[115;5u` |
| Ctrl+T | `\x14` | `\e[116;5u` | `\e[116;5u` |
| Ctrl+U | `\x15` | `\e[117;5u` | `\e[117;5u` |
| Ctrl+V | `\x16` | `\e[118;5u` | `\e[118;5u` |
| Ctrl+W | `\x17` | `\e[119;5u` | `\e[119;5u` |
| Ctrl+X | `\x18` | `\e[120;5u` | `\e[120;5u` |
| Ctrl+Y | `\x19` | `\e[121;5u` | `\e[121;5u` |
| Ctrl+Z | `\x1a` | `\e[122;5u` | `\e[122;5u` |

## Option + letter (US layout sample)

| Key | legacy | kitty(1) | kitty(5) |
|---|---|---|---|
| Option+A — as alt | `\ea` | `\e[97;3u` | `\e[97;3u` |
| Option+A — not as alt | `å` | `å` | `å` |
| Option+B — as alt | `\eb` | `\e[98;3u` | `\e[98;3u` |
| Option+B — not as alt | `∫` | `∫` | `∫` |
| Option+C — as alt | `\ec` | `\e[99;3u` | `\e[99;3u` |
| Option+C — not as alt | `ç` | `ç` | `ç` |
| Option+E — as alt | `\ee` | `\e[101;3u` | `\e[101;3u` |
| Option+E — not as alt | `(nothing)` | `(nothing)` | `(nothing)` |
| Option+N — as alt | `\en` | `\e[110;3u` | `\e[110;3u` |
| Option+N — not as alt | `(nothing)` | `(nothing)` | `(nothing)` |
| Option+O — as alt | `\eo` | `\e[111;3u` | `\e[111;3u` |
| Option+O — not as alt | `ø` | `ø` | `ø` |
| Option+P — as alt | `\ep` | `\e[112;3u` | `\e[112;3u` |
| Option+P — not as alt | `π` | `π` | `π` |
| Option+S — as alt | `\es` | `\e[115;3u` | `\e[115;3u` |
| Option+S — not as alt | `ß` | `ß` | `ß` |

## Shifted alternates (where kitty(1) and kitty(5) differ)

| Key | legacy | kitty(1) | kitty(5) |
|---|---|---|---|
| Ctrl+Shift+A | `\e[97;6u` | `\e[97;6u` | `\e[97:65;6u` |
| Ctrl+Shift+1 | `\e[33;5u` | `\e[49;6u` | `\e[49:33;6u` |
| Shift+A | `A` | `A` | `A` |
| A | `a` | `a` | `a` |

