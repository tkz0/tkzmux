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
| `closeTerminal` | ⌘W | Close the terminal |
| `closeSession` | ⇧⌘W | Close the session |
| `selectSession1` … `selectSession9` | ⌘1 … ⌘9 | Select the n-th visible session |
| `jumpToNeedsYou` | ⇧⌘U | Jump to the next session that needs you |
| `notifications` | ⌘I | Notifications |
| `settings` | ⌘, | Settings |
| `openFolder` | ⌘O | Open folder |
| `reloadConfig` | ⇧⌘, | Reload config |
| `copyLastMessage` | ⇧⌘C | Copy the selected session's last Stop message (M3.4) |
| `removeShellIntegration` | — | Delete the claude shim and zsh wrappers under Application Support (M3.3); app menu |
| `statusLineIntegration` | — | Install or remove tkzmux's `statusLine` command, behind a consent sheet (TKZ-32); app menu |
| `nextSession` | — | Known action, **no default**: ⌘T/⌘D are reserved for the terminal |
| `previousSession` | — | Same |

## Overrides

`AppState.shortcuts` (persisted in `state.json`) maps an action id to a cmux-style spec, and is
applied over the defaults by `ShortcutsTable.resolved(state:)`:

```json
{ "newSession": "cmd+t", "toggleSidebar": "ctrl+cmd+s", "nextSession": "alt+cmd+down" }
```

Modifiers: `cmd`/`command`/`meta`, `shift`, `alt`/`opt`/`option`, `ctrl`/`control` (any order,
case-insensitive). Keys: a single character, `up`/`down`/`left`/`right`, `home`/`end`,
`pageup`/`pagedown`, `return`, `tab`, `space`, `escape`, `delete`, `comma`, `period`, `slash`, or
`f1`–`f20`. A letter is always stored lower case with an explicit `.shift` bit, never as `"P"`.
An override that cannot be parsed is ignored and the default stands.
