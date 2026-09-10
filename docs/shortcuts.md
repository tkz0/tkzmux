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
| `searchSessions` | ⌘P | Palette, sessions only |
| `commandPalette` | ⇧⌘P | Palette, everything (sessions, groups, commands, presets) |
| `toggleSidebar` | ⌘B | Show/hide the sidebar |
| `renameSession` | ⇧⌘R | Rename the selected session |
| `closeTerminal` | ⌘W | Close the focused pane; the session's **last** terminal closes the session |
| `closeSession` | ⇧⌘W | Close the session, however many panes it has |
| `selectSession1` … `selectSession9` | ⌘1 … ⌘9 | Select the n-th visible session |
| `jumpToNeedsYou` | ⇧⌘U | Jump to the next session that needs you |
| `notifications` | ⌘I | Notifications |
| `settings` | ⌘, | Settings |
| `openFolder` | ⌘O | Open folder |
| `reloadConfig` | ⇧⌘, | Reload config |
| `copyLastMessage` | ⇧⌘C | Copy the selected session's last Stop message (M3.4) |
| `showFirstPrompt` | ⌥⌘P | Glass card over the terminal with the selected session's first prompt and Claude's recap (design 2c.5); again or Esc closes. Scrolling up a few rows in a Claude session *peeks* the same card without taking the keyboard; scrolling back down (or typing) hides it, and the chord pins it |
| `removeShellIntegration` | — | Delete the claude shim and zsh wrappers under Application Support (M3.3); app menu |
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
> menu item carries the *unshifted* character with `.shift` in its mask. `reloadConfig` (⇧⌘,) is
> the precedent that this shape works, but it was verified by hand and so must these be. Every
> other binding in the table above is asserted by `MainMenuTests`.

Modifiers: `cmd`/`command`/`meta`, `shift`, `alt`/`opt`/`option`, `ctrl`/`control` (any order,
case-insensitive). Keys: a single character, `up`/`down`/`left`/`right`, `home`/`end`,
`pageup`/`pagedown`, `return`, `tab`, `space`, `escape`, `delete`, `comma`, `period`, `slash`, or
`f1`–`f20`. A letter is always stored lower case with an explicit `.shift` bit, never as `"P"`.
An override that cannot be parsed is ignored and the default stands.
