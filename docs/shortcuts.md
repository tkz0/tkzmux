# App shortcuts

The cmux bindings the app ships with (design.md → Decisions → Shortcuts), owned as data by
`Sources/TkzApp/Menus/ShortcutsTable.swift` (M2.4 / TKZ-20). The main menu (wave 3) is built from
this table; nothing hard-codes a key equivalent.

> `docs/keys.md` is a different document: it is **generated and CI-asserted** by
> `TkzTerminalCoreTests` and covers *terminal* key encoding (what goes down the pty). This file
> covers *app* shortcuts (what the main menu and the palette do). Do not merge the two.

## Defaults

| Action id | Keys | What it does |
|---|---|---|
| `newSession` | ⌘N | Opens the group-scoped “＋ New session…” menu |
| `searchSessions` | ⌘F | Puts the caret in the toolbar's “Search sessions…” field, whose placeholder prints the bound chord (an override shows its own); typing opens the results overlay (see below). With no toolbar (the field hidden), falls back to the centred palette in sessions mode |
| `commandPalette` | ⇧⌘P | Palette, everything (sessions, groups, commands) |
| `toggleSidebar` | ⌘B | Show/hide the sidebar |
| `toggleTheme` | — | Flip between the dark theme and its light twin. Also the ☀/☾ button at the right of the toolbar; the choice is remembered across launches |
| `renameSession` | ⇧⌘R | Rename the selected session |
| `closeTerminal` | ⌘W | Close the focused pane; the session's **last** terminal closes the session |
| `closeSession` | ⇧⌘W | Close the session, however many panes it has |
| `selectSession1` … `selectSession9` | ⌘1 … ⌘9 | Select the n-th visible session |
| `jumpToNeedsYou` | ⇧⌘U | Jump to the next session that needs you |
| `notifications` | ⌘I | **No handler yet — hidden** (TKZ-55). See *Hidden commands* below |
| `settings` | ⌘, | **No handler yet — hidden** (TKZ-35). See *Hidden commands* below |
| `openFolder` | ⌘O | Directory picker; the chosen folder becomes a group and `claude` starts in it — the same flow as ＋ New session… › In another repo… |
| `reloadConfig` | ⇧⌘, | **No handler yet — hidden** (TKZ-56). See *Hidden commands* below |
| `copyLastMessage` | ⇧⌘C | Copy the selected session's last Stop message (M3.4) |
| `showFirstPrompt` | ⌥⌘P | Glass card over the terminal with the selected session's first prompt and Claude's recap (design 2c.5); again or Esc closes. Scrolling up a few rows in a Claude session *peeks* the same card without taking the keyboard; scrolling back down (or typing) hides it, and the chord pins it |
| `removeShellIntegration` | — | Delete the claude shim and the zsh/bash/fish wrappers under Application Support (M3.3, TKZ-33); app menu |
| `statusLineIntegration` | — | Install or remove tkzmux's `statusLine` command, behind a consent sheet (TKZ-32); app menu |
| `newTerminal` | ⌘T | Another terminal in this session, as a new tab |
| `splitVertically` | ⌘D | Split the focused pane side by side (the toolbar's `◫`) |
| `splitHorizontally` | ⇧⌘D | Split it stacked (the toolbar's `⬓`) |
| `focusPaneLeft` … `focusPaneDown` | ⌥⌘← ↑ → ↓ | Move the keyboard to the neighbouring pane. No wrap: an arrow at the edge does nothing |
| `equalizeSplits` | ⌃⌘= | Every pane in the tab the same size |
| `zoomPane` | ⇧⌘↩ | One pane fills the tab; again to restore |
| — | click a pane's header | Focus that pane (the header appears once a tab has more than one pane) |
| `previousTab` / `nextTab` | ⇧⌘[ / ⇧⌘] | Previous / next terminal in this session |
| `nextSession` | — | Known action, **no default** (cmux binds none) |
| `previousSession` | — | Same |

## Hidden commands

A surface shows a command only when `MenuDispatcher` has a handler for it. `MainMenu.build` gives an
action with no handler no menu item at all; the ⌘-hold cheat sheet walks that menu, and ⇧⌘P filters
its command rows on the same set. So `notifications`, `settings` and `reloadConfig` are in the table
above and in `ShortcutsTable`, but nowhere on screen — they were greyed out in the menu and *live*
in the palette and the cheat sheet, where choosing them did nothing at all (TKZ-53).

Their ids stay, because `AppState.shortcuts` is keyed by id and an override for an unknown one must
keep parsing; their chords stay in `ShortcutsTable.defaults`, so ⌘I, ⌘, and ⇧⌘, are **reserved,
not free**. Registering a handler is the whole of bringing one back — it reappears in the menu, the
palette and the cheat sheet at once, with no change here or to the table.

## Inside the search overlay (⌘F, design 2c.6)

The overlay is a child window that never takes the keyboard: the toolbar field keeps the caret and
relays these keys to it (`MainToolbarController` → `MainWindowController` → `CommandPaletteController`).
They are **not** in the shortcuts table — they exist only while the field is being edited.

| Keys | What it does |
|---|---|
| ↑ / ↓ | Move the selection. Section headers are skipped; no wraparound |
| ↵ | Open the selected row. A transcript hit selects its session and shows that turn in the 2c.5 card |
| ⌘↵ | Run the Actions row — a new session in the named group, started with what you typed |
| ⇥ / ⇧⇥, → / ← | Cycle the scope chips: `All → Sessions → Transcripts → Files changed`, wrapping |
| esc | Close the overlay, empty the field, and hand the keyboard back to the terminal |

→ and ← only take the chips while the overlay is up; with it down they move the caret as usual.
⌥→ / ⌥← and Home/End always move the caret, so a typo mid-query is still reachable. ⇥ is consumed
either way — letting it through walks the responder chain out of the field.

Emptying the field closes the overlay too — the field is the only state, so nothing is left
filtered or floating. Transcript search covers the sessions currently in the sidebar; a query
shorter than two characters searches neither transcripts nor changed files, because a single
character matches almost every line and every path.

## Overrides

`AppState.shortcuts` (persisted in `state.json`) maps an action id to a cmux-style spec, and is
applied over the defaults by `ShortcutsTable.resolved(state:)`:

```json
{ "newSession": "ctrl+cmd+n", "toggleSidebar": "ctrl+cmd+s", "nextSession": "ctrl+cmd+down" }
```

An override that collides with another action's binding is not rejected — the table has no opinion
about that — so the two are resolved by menu order and one of them silently stops working. The
example above used `cmd+t` and `alt+cmd+down` until TKZ-36 bound both to the terminal;
`AppState.fixture` carries the same three overrides and a test asserts the resolved fixture table
has no two actions sharing a chord, because a `TKZMUX_FIXTURE` run is the one place a collision
could be introduced without any menu being built.

> ⌘T, ⌘D and the ⌥⌘ arrows were held unbound from M2.4 as "reserved for the terminal". TKZ-36 is
> what they were reserved *for*, so they are bound now, and `nextSession`/`previousSession` remain
> the two known actions with no default.

> **⇧⌘[ / ⇧⌘] need checking on a real keyboard.** They are the one pair of bindings a headless
> test cannot prove: a shifted punctuation key equivalent depends on the active layout, and the
> menu item carries the *unshifted* character with `.shift` in its mask. `reloadConfig` (⇧⌘,) was
> the precedent that this shape works — verified by hand, never by a test — but it is hidden until
> it has a handler, so ⇧⌘[ / ⇧⌘] are now the only shifted-punctuation chords in the menu and
> must be verified by hand on their own. Every other binding in the table above is asserted by
> `MainMenuTests`.

Modifiers: `cmd`/`command`/`meta`, `shift`, `alt`/`opt`/`option`, `ctrl`/`control` (any order,
case-insensitive). Keys: a single character, `up`/`down`/`left`/`right`, `home`/`end`,
`pageup`/`pagedown`, `return`, `tab`, `space`, `escape`, `delete`, `comma`, `period`, `slash`, or
`f1`–`f20`. A letter is always stored lower case with an explicit `.shift` bit, never as `"P"`.
An override that cannot be parsed is ignored and the default stands.
