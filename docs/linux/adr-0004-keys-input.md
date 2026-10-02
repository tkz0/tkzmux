# ADR-0004: Keybindings and input conventions — Super as ⌘, fallback table, layouts, clipboard, IME

- **Status:** Accepted, provisional on WOR-301 S6
- **Date:** 2026-10-02 (written in WOR-299 S4, ratified in WOR-299 S6; final once WOR-301 S6 fills the open fields)
- **Issue:** WOR-299 S4 (M0 gate)
- **Applies:** user decisions 5 (shortcuts) and 6 (Linux conventions) in [decisions.md](decisions.md)
- **Implemented by:** WOR-310 (toolkit-free shortcut model, matcher, routers, `CommandHoldDetector`), WOR-315 (Linux keyboard, inhibitor, shortcut tables, IME, pointer, clipboard, `docs/linux/input.md`), WOR-317 (text fields), WOR-318 S6 (link underline), WOR-319 (cheat sheet, palette, Settings switch), WOR-324 S2 (`bindp` lines)
- **Related:** [ADR-0001](adr-0001-charter.md) (charter, Mac unchanged, test-only libxkbcommon), [ADR-0002](adr-0002-platform-defaults.md) (GTK floor, `dlsym` gate for 4.20 capabilities), [ADR-0003](adr-0003-parity.md) (L5 component parity, fixtures), [ADR-0005](adr-0005-window-controls.md) (Omarchy collision verdicts, `terminal` tag, window menu), [index](README.md)
- **Change control:** the two tables in [§3](#3-the-shortcut-tables) are normative. WOR-315 S3 encodes them as data and tests them against [§6](#6-reserved-chords). A chord changes only by amending this file in the same PR that changes the table.

### Open fields (WOR-301 S6 fills these, then sets the status to `Accepted (final)` or records the fallback)

| Field | Value | Filled by |
|---|---|---|
| Inhibit grant on Hyprland 0.56.2: `shortcuts-inhibited` becomes TRUE on focus; Super+W, Super+C, Super+digit and bare Super reach the app, with fcitx5 running and stopped | _open_ | WOR-301 S6 |
| `GDK_TOPLEVEL_CAPABILITIES_INHIBIT_SHORTCUTS` bit from `gdk_toplevel_get_capabilities` (4.20) | _open_ | WOR-301 S6 |
| Mouse-bind coverage under inhibit: Super+LMB click, Super+LMB drag, Super+RMB drag (Omarchy `SUPER + mouse:272/273`, `tiling.lua:70-71`) — delivered to the client or consumed by the WM | _open_ | WOR-301 S6 |
| Omarchy SUPER+C/V universal clipboard under inhibit: fires or not, and what it injects tagged and untagged (`clipboard.lua:45-46`) | _open_ | WOR-301 S6 |
| Bare Super press/release delivered while inhibit is denied (Super-hold in fallback mode) | _open_ | WOR-301 S6 |
| Name of the Hyprland window rule that stops a window from inhibiting (the bind-side flag `dont_inhibit` is confirmed in `/usr/share/hypr/stubs/hl.meta.lua:444`; the window-rule name is not) | _open_ | WOR-301 S6 |
| With fcitx5 active on `se`: Super/Ctrl chords on dead keys (⇧⌘] = Super+Shift+¨, ⌃⌘= = Super+Ctrl+´) arrive as key events and do not start a compose sequence | _open_ | WOR-301 S6, WOR-315 S2 |

## Context

Every app command on the Mac is a ⌘ chord. The Linux build has to decide what a PC keyboard presses instead, and how the Linux input conventions that macOS lacks fit in. The facts that constrain the answer:

1. **The Mac table.** `ShortcutsTable.defaults` has 30 bound actions plus ⌘1–9, which is 39 chords (`Sources/TkzApp/Menus/ShortcutsTable.swift:194-229`). Four more actions have no default (`nextSession`, `previousSession`, `resumeAllInGroup`, `toggleTheme`; `:176-188`). Every default includes ⌘. Ctrl appears only in ⌃⌘R and ⌃⌘=; Option only in ⌥⌘P, ⌥⌘R and the ⌥⌘ arrows. ⌘C/⌘V are hard-wired outside the table (`Sources/TkzApp/MainWindowController.swift:1514-1530`, `Sources/TkzApp/DevWindowController.swift:190-205`). ⌘Q, ⌘H and ⌥⌘H are AppKit items (`Sources/TkzApp/MainMenu.swift:193-211`), and so is ⌘M (`:298-299`).
2. **⌘ never reaches the terminal on the Mac.** `acceptsKeyDown` declines any event with ⌘ held (`Sources/TkzTerminalView/TerminalInputController.swift:178-183`, the rule at `:180`). Ctrl, Option and Shift chords all belong to the pty. So the Mac app never competes with a terminal program for a key.
3. **User decision 5 (2026-10-02).** Super acts as ⌘ while tkzmux has focus, through keyboard-shortcuts-inhibit (`gdk_toplevel_inhibit_system_shortcuts`, `/usr/include/gtk-4.0/gdk/gdktoplevel.h:202-206`; Hyprland implements protocol v1). Hints keep the Mac glyphs, Option maps to Alt, the ⌘-hold cheat sheet becomes a Super-hold, the Hyprland snippet ships `bindp` (bypass-inhibit) guidance, and Ctrl stays with the terminal.
4. **User decision 6 (2026-10-02).** Copy-on-select into PRIMARY with middle-click paste, IME (fcitx5 via text-input-v3) on by default with a Settings switch to xkb compose, and Shift+Insert pastes CLIPBOARD.
5. **Inhibit is a request, not a guarantee.** The protocol says the compositor "is however under no obligation to disable all of its shortcuts", may keep a combo to restore them, and reports the state with `active`/`inactive` events (`/usr/share/wayland-protocols/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml:78-139`). GNOME asks the user first. So a denied, unsupported or revoked inhibit is a normal state that needs a complete answer.
6. **Omarchy binds Super densely.** Tiling, applications, utilities and clipboard binds cover most Super letters, Super+digits and Super+mouse (`/usr/share/omarchy/default/hypr/bindings/{tiling,applications,utilities,clipboard}.lua`). SUPER+C/V inject Ctrl+Insert/Shift+Insert into windows tagged `terminal` and Ctrl+C/Ctrl+V into all others; SUPER+X always injects Ctrl+X (`clipboard.lua:45-47`). The injection uses `send_key_state` while SUPER is still physically held (`clipboard.lua:1-16`).
7. **fcitx5 owns global chords.** Verified on the installed fcitx5 5.1.22: core Ctrl+Space, Shift_L alone, Super+Space, Super+Shift+Space, Ctrl+Alt+P; unicode addon Ctrl+Shift+U and Ctrl+Alt+Shift+U; quickphrase Super+grave and Super+semicolon; clipboard addon Ctrl+semicolon (cleared in this machine's `clipboard.conf`, still a default elsewhere). With an input method active, fcitx5 sees keys before the client, so inhibit does not free them.
8. **The keyboard is Swedish.** The active layout is `se` pc105 (`/etc/vconsole.conf`). `xkbcli compile-keymap --layout se` shows `[ ] { }` on AltGr+8/9/7/0 (`<AE07>`–`<AE10>` level 3), `=` on Shift+0, `\` on AltGr+plus (`<AE11>`), dead keys on `<AE12>` (´ `) and `<AD12>` (¨ ^ ~), and Right Alt as `ISO_Level3_Shift`. Keysym-only matching breaks every chord on `[ ] =`.
9. **The Mac app does not change** (user decision 2). Everything here is Linux-only. Linux-only additions and gaps are listed in [§11](#11-linux-only-gaps-and-additions).

## Decision

### 1. Modifier mapping

| Mac | Linux | Notes |
|---|---|---|
| ⌘ Command | **Super** (either side) | Only while the inhibitor is granted ([§2](#2-inhibitor-lifecycle-and-table-selection)). Otherwise the fallback table applies. |
| ⌥ Option | **Left Alt** (either Alt on layouts without AltGr) | On `se` Right Alt is AltGr (`ISO_Level3_Shift`), a level-3 shift that composes text and never acts as Alt. |
| ⌃ Control | **Ctrl** | Belongs to the terminal unless it is part of a Super chord or a fallback chord. |
| ⇧ Shift | **Shift** | |

- **Ctrl stays with the terminal.** In Super mode no app chord uses Ctrl without Super, so Ctrl+letter, Ctrl+Shift+letter and Ctrl+Alt+letter all reach the pty. The only Ctrl chord the app takes in both modes is Ctrl+Insert ([§8](#8-clipboard)).
- **Unmatched Super chords are dropped.** They are never encoded to the pty, mirroring the Mac's ⌘ decline (`TerminalInputController.swift:180`). Nothing beeps.
- **Super from `GDK_SUPER_MASK` only.** `GDK_META_MASK` never contributes to a match (WOR-315 S2 verifies on `se` that Meta does not alias Alt).

### 2. Inhibitor lifecycle and table selection

WOR-315 S3 implements a `ShortcutInhibitor` with this contract:

- On toplevel focus-in it calls `gdk_toplevel_inhibit_system_shortcuts`; on focus-out it calls `gdk_toplevel_restore_system_shortcuts`. It observes the toplevel's `shortcuts-inhibited` property.
- **Exactly one table is active**, chosen by that property alone: TRUE selects the **Super table**, FALSE selects the **fallback table**. No timer is involved. Between focus-in and the compositor's `active` event the fallback table is live, which is safe: a Super chord in that window is still the WM's.
- It reports one of four states and logs each transition once, with the reason:

| State | How it is recognized | Active table |
|---|---|---|
| granted | `shortcuts-inhibited` TRUE while focused | Super |
| denied | FALSE after the request, with the capability bit set (GNOME "deny", a compositor policy) | fallback |
| unsupported | capability bit clear on GTK ≥ 4.20, or no `zwp_keyboard_shortcuts_inhibit_manager_v1` global | fallback |
| revoked | TRUE→FALSE while still focused (a compositor restore combo) | fallback; back to Super if it becomes TRUE again |

- Hints, the cheat sheet and palette subtitles always show the **active** table.
- Hyprland escape hatches stay the user's: a bind with `dont_inhibit` (hyprlang `bindp`; `/usr/share/hypr/stubs/hl.meta.lua:444`) still fires under inhibit. Which Omarchy binds get it is ADR-0005's verdict list; WOR-324 S2 writes the lines.

### 3. The shortcut tables

**Derivation rule D** (used for the defaults below and for user overrides, [§4](#4-parse-tokens-and-overrides)): replace ⌘ with **Ctrl+Shift**. If the Mac chord also has ⇧, ⌥ or ⌃, add **Alt** instead of that modifier (Ctrl and Shift are already taken). So ⌘X → Ctrl+Shift+X and ⇧⌘X / ⌥⌘X / ⌃⌘X → Ctrl+Shift+Alt+X. Four defaults are explicit exceptions (E1–E4) because D would collide or land on a reserved chord.

The Super table is the Mac table with ⌘ read as Super, unchanged in every other way. The "Omarchy bind" column names the default Omarchy bind that the Super chord takes while inhibit is granted; the claim or bypass verdict for each is ADR-0005's.

#### 3.1 The 39 default chords

| # | Action (`ShortcutsTable`) | Mac | Super table | Fallback table | Rule | Omarchy bind on the Super chord |
|---|---|---|---|---|---|---|
| 1 | `newSession` | ⌘N | Super+N | Ctrl+Shift+N | D | — |
| 2 | `newGroup` | ⇧⌘N | Super+Shift+N | Ctrl+Shift+Alt+N | D | `applications.lua:8` Editor |
| 3 | `searchSessions` | ⌘F | Super+F | Ctrl+Shift+F | D | `tiling.lua:7` Full screen |
| 4 | `commandPalette` | ⇧⌘P | Super+Shift+P | Ctrl+Shift+P | E1 | `applications.lua:30` Google Photos |
| 5 | `toggleSidebar` | ⌘B | Super+B | Ctrl+Shift+B | D | — |
| 6 | `renameSession` | ⇧⌘R | Super+Shift+R | Ctrl+Shift+F2 | E2 | — |
| 7 | `closeTerminal` | ⌘W | Super+W | Ctrl+Shift+W | D | `tiling.lua:1` Close window |
| 8 | `closeSession` | ⇧⌘W | Super+Shift+W | Ctrl+Shift+Alt+W | D | `applications.lua:19` Omawrite |
| 9 | `jumpToNeedsYou` | ⇧⌘U | Super+Shift+U | Ctrl+Shift+J | E3 | — |
| 10 | `notifications` | ⌘I | Super+I | Ctrl+Shift+I | D | — |
| 11 | `settings` | ⌘, | Super+, | Ctrl+Shift+, | D | `utilities.lua:24` Dismiss last notification |
| 12 | `openFolder` | ⌘O | Super+O | Ctrl+Shift+O | D | `tiling.lua:10` Pop window out |
| 13 | `reloadConfig` (hidden, no handler) | ⇧⌘, | Super+Shift+, | Ctrl+Shift+Alt+, | D | `utilities.lua:25` Dismiss all notifications |
| 14 | `copyLastMessage` | ⇧⌘C | Super+Shift+C | Ctrl+Shift+Alt+C | D | `applications.lua:24` Calendar |
| 15 | `showFirstPrompt` | ⌥⌘P | Super+Alt+P | Ctrl+Shift+Alt+P | D | — |
| 16 | `showChanges` | ⇧⌘G | Super+Shift+G | Ctrl+Shift+Alt+G | D | `applications.lua:17` Signal |
| 17 | `rebaseOntoBase` | ⌥⌘R | Super+Alt+R | Ctrl+Shift+Alt+R | D | — |
| 18 | `resumeSession` | ⌘R | Super+R | Ctrl+Shift+R | D | — |
| 19 | `runDevServer` | ⌃⌘R | Super+Ctrl+R | Ctrl+Shift+F5 | E4 | `utilities.lua:88` Set reminder |
| 20 | `newTerminal` | ⌘T | Super+T | Ctrl+Shift+T | D | `tiling.lua:6` Toggle floating |
| 21 | `splitVertically` | ⌘D | Super+D | Ctrl+Shift+D | D | — |
| 22 | `splitHorizontally` | ⇧⌘D | Super+Shift+D | Ctrl+Shift+Alt+D | D | `applications.lua:16` Docker |
| 23 | `focusPaneLeft` | ⌥⌘← | Super+Alt+← | Ctrl+Shift+Alt+← | D | `tiling.lua:76` Move into group |
| 24 | `focusPaneRight` | ⌥⌘→ | Super+Alt+→ | Ctrl+Shift+Alt+→ | D | `tiling.lua:77` |
| 25 | `focusPaneUp` | ⌥⌘↑ | Super+Alt+↑ | Ctrl+Shift+Alt+↑ | D | `tiling.lua:78` |
| 26 | `focusPaneDown` | ⌥⌘↓ | Super+Alt+↓ | Ctrl+Shift+Alt+↓ | D | `tiling.lua:79` |
| 27 | `equalizeSplits` | ⌃⌘= | Super+Ctrl+= | Ctrl+Shift+Alt+= | D | `tiling.lua:63` (`code:21` is KEY_EQUAL) Shrink window a lot |
| 28 | `zoomPane` | ⇧⌘↩ | Super+Shift+Enter | Ctrl+Shift+Alt+Enter | D | `applications.lua:3` Browser |
| 29 | `previousTab` | ⇧⌘[ | Super+Shift+[ | Ctrl+Shift+Alt+[ | D | — |
| 30 | `nextTab` | ⇧⌘] | Super+Shift+] | Ctrl+Shift+Alt+] | D | — |
| 31–39 | `selectSession1` … `selectSession9` (9 chords) | ⌘1 … ⌘9 | Super+1 … Super+9 | Ctrl+Shift+1 … Ctrl+Shift+9 | D | `tiling.lua:20-22` Switch to workspace 1–9 |

Count: 30 named actions + 9 digit chords = **39**, each with a Super row and a fallback row.

Exceptions:

- **E1** `commandPalette`: D gives Ctrl+Shift+Alt+P, which is `showFirstPrompt`'s. Ctrl+Shift+P is also the Linux palette convention (Ghostty, VS Code) and ⌘P is unbound, so the palette keeps the short chord.
- **E2** `renameSession`: D gives Ctrl+Shift+Alt+R, which is `rebaseOntoBase`'s (and `runDevServer`'s). Rename moves to F2, the Linux rename key, behind Ctrl+Shift so a bare F2 stays with TUIs.
- **E3** `jumpToNeedsYou`: Ctrl+Shift+U belongs to fcitx5's unicode addon and to GTK's simple input method, and D's Ctrl+Shift+Alt+U is fcitx5's Ctrl+Alt+Shift+U. J for "jump".
- **E4** `runDevServer`: the four R chords cannot all fit. F5 is "run" in IDEs.

#### 3.2 App chords outside `ShortcutsTable`

These are hard-wired (not overridable), as ⌘C/⌘V/⌘Q are on the Mac.

| Command | Mac | Super table | Fallback table | Notes |
|---|---|---|---|---|
| Copy selection → CLIPBOARD | ⌘C | Super+C | Ctrl+Shift+C | Omarchy `clipboard.lua:45` |
| Paste CLIPBOARD | ⌘V | Super+V | Ctrl+Shift+V | Omarchy `clipboard.lua:46`; image-only clipboard sends the Ctrl-V chord (`TerminalInputController.swift:333-352`) |
| Copy selection → CLIPBOARD | — | Ctrl+Insert | Ctrl+Insert | Both modes; matched with Super ignored ([§8](#8-clipboard)) |
| Paste CLIPBOARD | — | Shift+Insert | Shift+Insert | Both modes; matched with Super ignored |
| Quit | ⌘Q | Super+Q | Ctrl+Shift+Q | No Omarchy Super+Q bind |
| Cheat sheet | hold ⌘ alone 2 s | hold Super alone 2 s | palette row *Keyboard Shortcuts*, and Super-hold if bare Super is delivered (open field) | [§5](#5-hints-and-the-cheat-sheet) |
| Hide tkzmux | ⌘H | **unbound** | **unbound** | [§3.4](#34-verdicts-h-hide-others-m) |
| Hide Others | ⌥⌘H | **unbound** | **unbound** | |
| Show All | (no key) | not offered | not offered | |
| Minimize | ⌘M | **unbound** | **unbound** | |
| Close Window | (no key; ⌘W is `closeTerminal`, `MainMenu.swift:303-306`) | no key | no key | Header close button (ADR-0005) |

In fallback mode Ctrl+Shift+C and Ctrl+Shift+V are always consumed, even with nothing to copy or an empty clipboard, so they never reach a terminal program by accident. In Super mode an unusable Super+C/V is dropped like any Super chord.

#### 3.3 Overlay-local keys

These keys exist only while an overlay or window owns the keyboard (`docs/shortcuts.md:71-97`, `Sources/TkzApp/Changes/ChangesViewerView.swift:750-765`, `Sources/TkzApp/Settings/SettingsWindow.swift:44-53`). Since the terminal does not have focus, the fallback column may use plain Ctrl.

| Where | Mac | Super table | Fallback table |
|---|---|---|---|
| Search overlay: run the Actions row | ⌘↵ | Super+Enter, and Ctrl+Enter | Ctrl+Enter |
| Search overlay: refocus the field | ⌘F | Super+F | Ctrl+Shift+F |
| Search overlay, palette, activity feed, changes viewer: navigation | ↑ ↓ ↵ ⇥ ⇧⇥ ← → PageUp PageDown Home End esc | same keys | same keys |
| Search overlay, palette, activity feed: caret by word | ⌥← ⌥→ | Alt+← Alt+→ | Alt+← Alt+→ |
| Activity feed / changes viewer / prompt card: close | esc or the opening chord | esc or the Super chord | esc or the fallback chord |
| Settings window: close | ⌘W, esc | Super+W, esc | Ctrl+Shift+W, esc |
| Text fields (WOR-317): select all, copy, cut, paste, undo | ⌘A ⌘C ⌘X ⌘V ⌘Z | Super+A/C/X/V/Z | Ctrl+A/C/X/V/Z |

Ctrl+Enter runs the Actions row in both modes because ADR-0005 bypasses Omarchy's SUPER+RETURN (launch terminal), so on Omarchy Super+Enter never reaches tkzmux. The overlay owns the keyboard, so Ctrl+Enter takes nothing from the terminal. The hint keeps the Mac's ⌘↵.

Recommendation to WOR-317: in both modes, text fields also accept the Linux conventions Ctrl+A/C/X/V/Z and Ctrl+←/→ (word), because a focused field never competes with the terminal.

#### 3.4 Verdicts: H, Hide Others, M

| Mac item | Linux verdict | Reason |
|---|---|---|
| ⌘H Hide tkzmux (`MainMenu.swift:193-195`) | Unbound in both tables. Super+H is dropped. | Wayland has no application hide. |
| ⌥⌘H Hide Others (`:197-201`) | Unbound in both tables. | Same; a client cannot hide other clients. |
| Show All (`:203-206`) | Not offered. | No equivalent. |
| ⌘M Minimize (`:298-299`) | Unbound in both tables, on every compositor. | Hyprland has no minimize. Minimize stays reachable from the compositor's window menu where one exists (header right-click → `show_window_menu`, ADR-0005). One table for all compositors keeps the tests simple. |

WOR-315 S3 tests that ⌘H, ⌥⌘H and ⌘M (as Super+H, Super+Alt+H, Super+M) stay unbound in both tables.

### 4. Parse tokens and overrides

- `cmd`, `command`, `super` and `meta` all mean the primary modifier: ⌘ on macOS, Super on Linux (`ShortcutsTable.swift:324`; WOR-310 renames `.command` to `.primary` and keeps every token).
- **`meta` stays an alias of the primary modifier on Linux.** It is the ambiguous token: in X11/xkb usage Meta is often the Alt key, and Emacs users mean Alt by it. One parser for both OSes means a synced `state.json` binds the same chord on both, and `docs/shortcuts.md:139` already documents `meta` as a ⌘ alias. Users who mean Emacs Meta write `alt`. `GDK_META_MASK` is never read ([§1](#1-modifier-mapping)).
- `alt`/`opt`/`option` mean Alt (left Alt on `se`); `ctrl`/`control` and `shift` are unchanged. No new tokens.
- **Overrides** (`AppState.shortcuts`) are written in the Mac/Super vocabulary and replace the Super-table entry. The fallback entry for an overridden action is derived with rule D. If the derived chord collides with another fallback chord or is on the reserved list ([§6](#6-reserved-chords)), that action has no fallback chord, stays reachable from the palette, and one log line says why. There is no separate Linux or fallback override key.
- **Fall-through** follows `MenuDispatcher.canPerform` (`Sources/TkzApp/MainMenu.swift:89`): a matched chord whose action has no handler is not consumed. In Super mode it is then dropped; in fallback mode the key goes to the terminal encoder. A chord whose action has a handler but is disabled (`isEnabled`, `:85-87`) is consumed and does nothing, so a chord's effect on the terminal never depends on app state.

### 5. Hints and the cheat sheet

- **Hints keep the Mac glyphs**, in menu order ⌃⌥⇧⌘ (`ShortcutsTable.swift:136-143`): ⌘ means Super, ⌥ Alt, ⌃ Ctrl. Fallback chords render the same way, for example ⌃⇧P and ⌃⌥⇧R. This keeps palette and cheat-sheet text widths identical to the Mac (ADR-0003 L5).
- A key matched through the physical fallback ([§7](#7-layout-matching-se-and-us)) shows its US identity: on `se`, ⇧⌘[ is pressed as Super+Shift+Å. `docs/linux/input.md` (WOR-315) explains this.
- **Super-hold.** Holding Super alone for 2 s shows the cheat sheet (`Sources/TkzApp/CheatSheet/CommandHoldDetector.swift:25`), via WOR-310's generalized "primary held alone" detector. Another key, keyboard leave or focus loss cancels it. A focus change caused by a `bindp` chord cancels it too (WOR-319).
- **Fallback mode.** The cheat sheet is reachable from the palette through a *Keyboard Shortcuts* row, as WOR-299 S4 requires. It is a new action with no default chord whose handler is registered on Linux only, so on the Mac it has no menu item, palette row or cheat-sheet entry (`MainMenu.swift:312-325`, `docs/shortcuts.md:52-64`). It is the one sanctioned Linux-only palette row (ratified in WOR-299 S6): WOR-319's rule "add no Linux-only palette rows" applies to every other row. Super-hold also works in fallback mode if the compositor delivers bare Super (open field). Holding Ctrl+Shift is not used: it is the prelude of every fallback chord, and Shift_L alone is fcitx5's.

### 6. Reserved chords

No default chord in either table, no derived override chord and no hard-wired chord may be one of these. WOR-315 S3's reserved-chord test runs the whole list against both tables, including Shift_L alone.

| Owner | Chords |
|---|---|
| fcitx5 core (globalconfig) | Ctrl+Space, Shift_L alone, Super+Space, Super+Shift+Space, Ctrl+Alt+P |
| fcitx5 unicode addon | Ctrl+Shift+U, Ctrl+Alt+Shift+U |
| fcitx5 quickphrase addon (added by this ADR; read from the installed 5.1.22 addon) | Super+grave, Super+semicolon |
| fcitx5 clipboard addon (added by this ADR; default, cleared on this machine) | Ctrl+semicolon |
| GTK simple input method | Ctrl+Shift+U |
| Terminal-critical | Ctrl+letter, Alt+letter (and Alt+Shift+letter), Shift+Enter, Shift+Tab |
| System | Alt+Tab, Ctrl+Alt+Del, Ctrl+Alt+F1–F12 (VT switch, `XF86Switch_VT_n`), Ctrl+Alt+Backspace (`terminate:ctrl_alt_bksp` in `/etc/vconsole.conf`) |
| Omarchy non-Super | Alt+Shift+Tab, Ctrl+Alt+Tab, Ctrl+Alt+Shift+Tab (`tiling.lua:44-50`), Print, Alt+Print (`utilities.lua:37-38`), F9 when voxtype is installed (`voxtype.lua:3-4`) |

**Check of the fallback table against this list.** Every fallback chord is Ctrl+Shift+key, Ctrl+Shift+Alt+key, Ctrl+Shift+F2/F5, Ctrl+Shift+digit, Ctrl/Shift+Insert, or (overlay-local, field-focused only) Ctrl+Enter and Ctrl+A/C/X/V/Z. None has Ctrl without Shift on a letter, none is Alt+letter, none uses U, Space, semicolon or grave, and none includes Tab, Delete, Backspace, Print or a Ctrl+Alt F-key. Ctrl+Shift+Alt+P differs from fcitx5's Ctrl+Alt+P by Shift; WOR-315 S3 confirms by hand that fcitx5 matches the exact modifier set. The Super table uses no Space, grave or semicolon.

### 7. Layout matching (`se` and `us`)

The matcher (WOR-310 `ShortcutMatcher`, fed by WOR-315 S2) runs in the window's capture phase, before the input method, and compares chords in two steps:

1. **Level-0 keysym.** The chord key is compared with the level-0 keysym of the pressed key in the active layout group. Letters, comma and the named keys (arrows, Enter, F-keys, Insert) use this step only.
2. **Physical key, for digits, `[`, `]`, `=` and `\` only.** When no key in the active group carries that symbol at level 0, the chord matches the evdev key that carries it on `us` pc105. The per-layout level-0 table is rebuilt when the keymap or group changes (fcitx5 can replace the keymap at runtime).

Lock modifiers (Caps Lock, Num Lock) never affect a match.

| Chord | `us` keys pressed | `se` keys pressed | `se` match step |
|---|---|---|---|
| ⌘1 … ⌘9 | Super+1 … 9 | Super+1 … 9 | 1 (digits are level 0 on `<AE01>`–`<AE09>`) |
| fallback | Ctrl+Shift+1 … 9 | Ctrl+Shift+1 … 9 | 1 |
| ⇧⌘[ | Super+Shift+[ | Super+Shift+Å (`<AD11>`, KEY_LEFTBRACE) | 2 |
| fallback | Ctrl+Shift+Alt+[ | Ctrl+Shift+Alt+Å | 2 |
| ⇧⌘] | Super+Shift+] | Super+Shift+¨ (`<AD12>`, KEY_RIGHTBRACE, a dead key) | 2 |
| fallback | Ctrl+Shift+Alt+] | Ctrl+Shift+Alt+¨ | 2 |
| ⌃⌘= | Super+Ctrl+= | Super+Ctrl+´ (`<AE12>`, KEY_EQUAL, a dead key) | 2 |
| fallback | Ctrl+Shift+Alt+= | Ctrl+Shift+Alt+´ | 2 |
| ⌘, / ⇧⌘, | Super+, / Super+Shift+, | Super+, / Super+Shift+, | 1 (`<AB08>` comma is level 0) |
| `\` (overrides only) | Super+\ | Super+' (`<BKSL>`, KEY_BACKSLASH) | 2 |

On `fr` (AZERTY) digits are level 1, so ⌘1–9 match through step 2 on the digit row. Every ⌥ chord on `se` needs the left Alt. Non-Latin layouts get step 1 only for letters; a Latin fallback for letters is out of scope for M0.

Rejected refinement: matching a symbol at level 1 with Shift consumed (kitty's "shifted" fallback) would let `se` users press Super+Ctrl+Shift+0 for ⌃⌘=. It makes Shift meaningless on that key and does not help `[ ]`, which are level 3 on `se`.

### 8. Clipboard

- **Copy-on-select → PRIMARY.** A finished, non-empty terminal selection (drag release, double- or triple-click) is written to the PRIMARY selection. CLIPBOARD is never written by selecting. Text fields and viewers do the same (WOR-317, WOR-319).
- **Middle-click pastes PRIMARY** when the pointer route is select: no mouse tracking, or Shift held (`Sources/TkzTerminalView/MouseController.swift:111-113`). With tracking on and no Shift, the middle button is reported to the program. Middle-click paste is skipped when GtkSettings `gtk-enable-primary-paste` is FALSE.
- **Shift+Insert pastes CLIPBOARD** and **Ctrl+Insert copies to CLIPBOARD**, in both modes. This deliberately differs from Ghostty and kitty (Shift+Insert = PRIMARY) because Omarchy's SUPER+V injects Shift+Insert into terminal-tagged windows and means the clipboard (`clipboard.lua:46`). Both chords match with Super ignored, because Omarchy injects them while SUPER is still held (`clipboard.lua:1-6`).
- Every paste source (Super+V, Ctrl+Shift+V, Shift+Insert, middle-click) goes through the same `pasteText` path with the same unsafe-paste confirmation and bracketed-paste rules (`MouseController.swift:704-721`).
- Runtime reliance on `wl-clipboard`, OSC 52 while unfocused and the async paste seam are WOR-315 S6.

### 9. IME and text input

- **On by default.** One `GtkIMMulticontext` per canvas with `GTK_INPUT_PURPOSE_TERMINAL`, which uses text-input-v3 (Hyprland advertises v1) to reach fcitx5. `GTK_IM_MODULE` stays unset.
- **Settings switch** *Use input method* (model key `useInputMethod`, WOR-315 S4; UI WOR-319). Off selects `GtkIMContextSimple`: xkb compose and dead keys, no IME hop. On `se`, dead keys (´ ` ¨ ^ ~) work in both modes.
- **Preedit is drawn on Linux**, at the cursor cell, from theme tokens. On `se` every dead key is a preedit, so without it a pending ´ is invisible. The Mac tracks preedit but does not draw it (`TerminalInputController.swift:99-101`); this is a Linux-only addition and the Mac does not gain it. WOR-299 S6 confirmed this over WOR-315 S4's draft wording ("preedit is not drawn"), which WOR-315 S4 amends. Preedit is kept out of every fixture and parity capture (no IME runs under `TKZMUX_FIXTURE` or `TKZMUX_DEV_CAPTURE`).
- fcitx5's default Ctrl+Space trigger takes NUL from terminal programs; `docs/linux/input.md` (WOR-315 S4) documents freeing it.

### 10. Alt, Option-as-alt and the pointer

- **Option-as-alt is a macOS-only translator input.** `optionAsAlt` is a property of the Mac input controller with default `.never` (`TerminalInputController.swift:106-108`, `Sources/TkzTerminalCore/KeyEncoder.swift:45-53`), not a Settings row. The Linux translator never consumes Alt; AltGr is the composing modifier. There is no Settings change on either OS.
- **Rectangle selection is Alt+drag** (Option+drag on the Mac, `MouseController.swift:424,450`). Under mouse tracking it is Shift+Alt+drag. Omarchy binds no Alt+mouse.
- **Links.** Super+hover underlines and Super+click opens an OSC 8 link or a detected file path, ahead of mouse reporting, exactly as ⌘ does on the Mac (`MouseController.swift:391-403`, hover `:504-512`). **Ctrl+click is always an alias**, with this precedence (WOR-310's router confirms it before WOR-315 S5 and WOR-318 S6 implement it):
  - Ctrl+click opens a link only when the pointer is over one **and** the route is select (no tracking, or Shift held). With tracking on and no Shift, Ctrl+click is reported to the program, which can legitimately want it; Shift+Ctrl+click still opens the link.
  - Ctrl+hover underlines only under the same conditions, so the underline never promises a click that would be reported instead. Super+hover always underlines.
  - If WOR-301 S6 finds that Omarchy's `SUPER + mouse:272` drag is still consumed under inhibit, Super+click is unusable on Omarchy and Ctrl+click is the working path. Both stay implemented.

### 11. Linux-only gaps and additions

Per ADR-0001's "Mac app unchanged" rule these are listed, never closed on the Mac:

- Gaps: no Hide, Hide Others, Show All or Minimize chords; ⌘ is pressed as Super on a PC keyboard while the hint still shows ⌘.
- Additions: the fallback table, Ctrl+Enter in the search overlay, Ctrl+Insert/Shift+Insert, copy-on-select to PRIMARY, middle-click paste, drawn preedit, the IME switch, Ctrl+click links, and the *Keyboard Shortcuts* palette row.

## Consequences

- **Chord and hint parity.** Super-mode users press the Mac chord on the Mac key positions, and hints, palette and cheat sheet render with identical widths (ADR-0003 L5).
- **The terminal keeps Ctrl in Super mode.** Nothing the app binds competes with a terminal program, as on the Mac.
- **Omarchy Super binds are dead while tkzmux is focused** unless they bypass inhibit. 28 of the 39 default chords (plus Super+C/V) land on an Omarchy bind, including window close (Super+W), fullscreen (Super+F) and workspaces (Super+1–9). ADR-0005 records the claim or bypass verdict for each. Super+1–9 stay tkzmux's ⌘1–9 while it is focused (WOR-299 S6); a user who wants Omarchy workspace switching over tkzmux marks those binds with the bypass flag (`bindp`) and gives up ⌘1–9 there, as `docs/linux/hyprland.md` explains.
- **Two tables to test.** WOR-315 S3 asserts: no duplicate chord in either table; no chord on the reserved list; ⌘H/⌥⌘H/⌘M unbound; the inhibitor state machine selects the right table on granted, denied, unsupported and revoked; Shift+Insert and Ctrl+Insert match with Super set.
- **Fallback costs.** Ctrl+Shift and Ctrl+Shift+Alt chords are taken from terminal programs that ask for them through the kitty protocol (for example Neovim mappings). On GNOME, Ctrl+Shift+Alt+arrows also moves windows between workspaces; other compositors are best effort (decision 7).
- **`se` users press Å, ¨ and ´** for ⇧⌘[, ⇧⌘] and ⌃⌘=, and see the US glyph in the hint. Two of those keys are dead keys, which is why the capture-phase order and the fcitx5 open field matter.
- **Linux-only UI**: the palette row, the IME switch and the preedit overlay exist only on Linux.
- WOR-315 S3 writes the colliding-WM-bind table into `docs/linux/input.md`, and WOR-324 S2 turns the chosen bypasses into `bindp` lines.

## Alternatives considered

| Alternative | Why not |
|---|---|
| **Ctrl+Shift as the primary scheme** (the research's first proposal; Ghostty and kitty convention) | Different chords and longer hints than the Mac, and it takes chords from terminal programs all the time. User decision 5 chose Super; Ctrl+Shift survives as the fallback. |
| **Super without inhibit** | Omarchy binds most Super chords, so they would never reach the app. |
| **Ctrl as primary** (Windows style) | Takes Ctrl+letter, which the terminal needs. |
| **Super and Ctrl+Shift active together** (WezTerm binds both) | Takes Ctrl+Shift chords from the terminal even when Super works, and doubles hint and test surface. Exactly one table is active. |
| **Linux-style text hints** ("Ctrl+Shift+P") | Breaks L5 widths and the palette layout. Rejected by decision 5. |
| **Keysym-only matching** | Breaks `[ ] =` on `se` and digits on `fr`. **Physical-only matching** breaks letters on Dvorak, AZERTY and QWERTZ. The two-step matcher takes the best of each. |
| **Shift+Insert → PRIMARY** (Ghostty, kitty) | Conflicts with Omarchy SUPER+V and decision 6. PRIMARY stays on middle-click. |
| **IME off by default, xkb compose only** (kitty's default, lower latency) | Rejected by decision 6; the switch keeps it one click away. |
| **`meta` → Alt on Linux, or rejecting `meta`** | Gives one `state.json` different meanings per OS, or silently drops a user binding. |
| **Cheat sheet on a Ctrl+Shift hold in fallback mode** | Ctrl+Shift is held at the start of every fallback chord and Shift_L alone is fcitx5's, so the hold would pop constantly or never. |
| **⌘M → minimize where the capability bit is set** | Hyprland has none, and a per-compositor table doubles the tests. The window menu covers it. |
| **A separate Linux override vocabulary in `state.json`** | Not needed for M0: rule D derives fallback chords, and the palette covers any action without one. |

## Open items

Each item has an owner issue; [decisions.md](decisions.md) carries the same list.

| Item | Owner |
|---|---|
| The seven open fields in the header | WOR-301 S6 |
| **Resolved in WOR-299 S6:** preedit is drawn on Linux ([§9](#9-ime-and-text-input)), as WOR-299 S4 specifies. WOR-315 S4 and its Out list drop "preedit is not drawn (Mac parity)". | WOR-315 S4 |
| **Resolved in WOR-299 S6:** the fallback-mode *Keyboard Shortcuts* row ([§5](#5-hints-and-the-cheat-sheet)) is the one sanctioned Linux-only palette row. WOR-319's risk note gains that exception. | WOR-319 |
| **Resolved in WOR-299 S6:** the search overlay's ⌘↵ also accepts Ctrl+Enter in Super mode ([§3.3](#33-overlay-local-keys)), because ADR-0005 bypasses SUPER+RETURN. | WOR-319 (search overlay), WOR-315 S3 (table data) |
| Ctrl+click precedence against mouse reporting ([§10](#10-alt-option-as-alt-and-the-pointer)) | WOR-310 (router test), then WOR-315 S5 |
| fcitx5 matches exact modifier sets, so Ctrl+Shift+Alt+P is not taken by its Ctrl+Alt+P | WOR-315 S3 (manual check) |
| GTK's inspector bindings (Ctrl+Shift+I and Ctrl+Shift+D on GtkWindow, off unless the inspector keybinding setting is on) never fire before tkzmux's capture-phase match for `notifications`/`splitVertically` in fallback mode | WOR-315 S2 |
| SUPER+digits and the `terminal` tag | Decided in WOR-299 S6 (ADR-0005 §4); WOR-301 S6 revisits the tag with measurements |

## References

Repository (this worktree):
- `Sources/TkzApp/Menus/ShortcutsTable.swift:136-143` (glyph order), `:176-188` (actions), `:194-229` (defaults), `:311-333` (parser, tokens at `:324`)
- `Sources/TkzApp/MainMenu.swift:85-89` (enablement, `canPerform`), `:193-211` (Hide, Hide Others, Show All, Quit), `:296-307` (Window menu), `:312-325` (handlerless items are absent)
- `Sources/TkzApp/MainWindowController.swift:1479-1494` (cheat-sheet monitor), `:1514-1530` (⌘C/⌘V)
- `Sources/TkzApp/DevWindowController.swift:187-205` (⌘C/⌘V decline rules)
- `Sources/TkzApp/CheatSheet/CommandHoldDetector.swift:25` (2 s hold)
- `Sources/TkzApp/Settings/SettingsWindow.swift:44-53`, `Sources/TkzApp/Changes/ChangesViewerView.swift:750-765`
- `Sources/TkzTerminalView/TerminalInputController.swift:99-101` (preedit hook), `:106-108` (`optionAsAlt`), `:178-183` (⌘ decline), `:333-352` (image Ctrl-V chord)
- `Sources/TkzTerminalView/MouseController.swift:111-113` (route), `:391-403` (⌘-click), `:421-424,450` (Option rectangle), `:504-512` (⌘-hover), `:704-721` (paste and unsafe-paste)
- `Sources/TkzTerminalCore/KeyEncoder.swift:45-53` (`OptionAsAlt`)
- `docs/shortcuts.md:52-64` (hidden commands), `:71-97` (search overlay keys), `:139-143` (override tokens); `docs/keys.md:122-148` (Option and Ctrl+Shift rows)

Machine (Omarchy, Hyprland 0.56.2, GTK 4.22.4, fcitx5 5.1.22, libxkbcommon 1.13.2):
- `/usr/share/omarchy/default/hypr/bindings/tiling.lua`, `applications.lua`, `utilities.lua`, `clipboard.lua:1-48`, `voxtype.lua`
- `/usr/share/hypr/stubs/hl.meta.lua:444` (`dont_inhibit`)
- `/usr/share/wayland-protocols/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml:27-42,78-139`
- `/usr/include/gtk-4.0/gdk/gdktoplevel.h:202-206` (inhibit/restore), `:308` (`GDK_TOPLEVEL_CAPABILITIES_INHIBIT_SHORTCUTS`, 4.20), `:317-318` (`gdk_toplevel_get_capabilities`)
- `/etc/vconsole.conf` (`XKBLAYOUT=se`, `XKBOPTIONS=terminate:ctrl_alt_bksp`); `xkbcli compile-keymap --layout se`
- `/usr/lib/fcitx5/libquickphrase.so`, `libclipboard.so`, `libunicode.so` (default trigger strings)

Upstream (read only; Ghostty is MIT, kitty is GPL-3 and is never copied):
- Ghostty defaults, `ctrlOrSuper` link modifier, `performable` flag: https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/config/Config.zig
- Ghostty key encoder (macOS-only option-as-alt gates): https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/input/key_encode.zig
- kitty defaults (Shift+Insert, middle-click, IME latency note): https://raw.githubusercontent.com/kovidgoyal/kitty/master/kitty/options/definition.py
- WezTerm default keys (binds Super and Ctrl+Shift together): https://wezterm.org/config/default-keys.html
- fcitx5 global hotkeys: https://raw.githubusercontent.com/fcitx/fcitx5/master/src/lib/fcitx/globalconfig.cpp; unicode addon: https://raw.githubusercontent.com/fcitx/fcitx5/master/src/modules/unicode/unicode.h
- Hyprland protocol versions (text-input-v3 v1, wl_seat v9): https://raw.githubusercontent.com/hyprwm/Hyprland/main/src/managers/ProtocolManager.cpp; keyboard-shortcuts-inhibit in v0.56.2: https://raw.githubusercontent.com/hyprwm/Hyprland/v0.56.2/CMakeLists.txt
- GTK: https://docs.gtk.org/gdk4/method.Toplevel.inhibit_system_shortcuts.html, https://docs.gtk.org/gtk4/property.Settings.gtk-enable-primary-paste.html
- Research: `input-keyboard-shortcuts` dimension and its fact-check (39 chords, `se` layout, fcitx5 defaults, Omarchy SUPER+C/X behaviour, option-as-alt correction, inhibit as an unconsidered alternative)
