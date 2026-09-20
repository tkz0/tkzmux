# App shortcuts

The cmux bindings the app ships with (design.md → Decisions → Shortcuts), owned as data by
`Sources/TkzApp/Menus/ShortcutsTable.swift` (M2.4). The main menu (wave 3) is built from
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
| `closeSession` | ⇧⌘W | Close the session, however many panes it has. A worktree row whose pull request is merged asks first, with **Close and Delete Worktree** as the default button and **Close Only** beside it; every other idle row still closes with no prompt at all, and a working row is never offered the delete. ⇧⌘W never force-removes a worktree with uncommitted changes — use *Delete worktree…* for that |
| `selectSession1` … `selectSession9` | ⌘1 … ⌘9 | Select the n-th visible session |
| `jumpToNeedsYou` | ⇧⌘U | Jump to the next session that needs you |
| `notifications` | ⌘I | The activity feed: a catch-up inbox over the terminal, newest first — every row's finished turns (the first two lines of Claude's reply), NEEDS YOU flips (permission / question / unattended) and Claude exits, one thread per row with older entries folded under the newest. Rows that are working are pinned at the top with their elapsed time. An entry is **unread** (bold) until its row is looked at — selected, typed into, or a Stop arriving while it is on screen; right-click › *Mark as Unread* raises it again, and the log (200 entries) survives a relaunch in `state.json`. Inside: typing filters by session title, group and message text (contiguous, like ⌘F); ↑/↓ walk the list, ↵ selects the row and closes, → / ← unfold and fold the selected thread (⌥→ / ⌥← still move the caret), esc or the chord again closes |
| `settings` | ⌘, | The Settings window (design 7a–d): General, Shell and Appearance pages. Every preference that used to be an app-menu checkmark lives here as a switch with a sentence — resume on launch, the periodic origin check, the "Claude finished" notification, token usage & spend, the status line per account, shell integration status and removal, the colour scheme. Esc or ⌘W closes it |
| `openFolder` | ⌘O | Directory picker; the chosen folder becomes a group and `claude` starts in it — the same flow as ＋ New session… › In another repo… |
| `reloadConfig` | ⇧⌘, | **No handler yet — hidden**. See *Hidden commands* below |
| `copyLastMessage` | ⇧⌘C | Copy the selected session's last Stop message (M3.4) |
| `showFirstPrompt` | ⌥⌘P | Glass card over the terminal with the selected session's first prompt and Claude's recap (design 2c.5); again or Esc closes. Scrolling up a few rows in a Claude session *peeks* the same card without taking the keyboard; scrolling back down (or typing) hides it, and the chord pins it |
| `showChanges` | ⇧⌘G | View-only changes viewer over the terminal (design 2c.2): the changed files of the selected session's repo with per-file `+/−`, each file's diff inline or split, against `HEAD` or the branch's upstream. Also opened by clicking the `+142 −38` / `12 files` chips in the status bar. Inside: ↑/↓ walk the files, Page Up/Down and Home/End scroll the diff, Esc, the header's ✕ or the chord again returns to the terminal. The artboard says ⌘D, which is *Split Vertically* here |
| `rebaseOntoBase` | ⌥⌘R | The rebase sheet (design 5a/5b) for the selected session's branch: fetches the repo's base branch — `origin/HEAD`, else `origin/main`/`master`, else a local `main`/`master` — says how many commits it pulls in, and *Rebase* runs `git rebase --autostash` onto it, out of band. Also the amber `⤿ 7 behind main` chip in the status bar, shown only while the branch is behind its base. A rebase conflict aborts and restores the tree; if reapplying the autostashed changes conflicts instead, the rebase stands and the tree keeps those conflict markers with the change kept in `git stash` rather than being restored. The button is off while the row's Claude is working. The artboard says ⌘R, which is *Resume Session* here |
| — | Row context menu | ***Delete worktree…*** — on a `WT` row, a sheet in the rebase sheet's family naming the worktree path, its branch, and one of *PR #12 merged*, *Branch fully merged into main* or *2 commits not on main*. **Delete** removes the worktree and, when the branch has landed, the branch too; when it has commits the base lacks the button reads **Delete, keep branch** and a red **Delete branch too** appears next to it. A worktree with uncommitted changes needs *Discard them and delete anyway* ticked first. The row is closed first (with the normal working/waiting confirmation), then git runs out of band — never in a pane. Disabled, with the reason as a tooltip, while the row's agent is working, while a rebase runs on that worktree, and for anything that is not a `.claude/worktrees` directory tkzmux itself opened |
| — | Group context menu | ***Delete merged worktrees…*** — lists every worktree row in the group whose PR is merged or whose branch is fully merged into the base, pre-checked, and runs the same per-row delete for the checked ones. Rows whose agent is working are listed but off; rows with uncommitted changes are listed unchecked — delete those one at a time from the row menu, which is the only place that can force |
| — | Settings › General | *Check origin periodically*: fetch every session repo's base branch every 5 minutes so the `⤿ 7 behind main` chip stays honest without a manual fetch. **Off by default** (background network under your git credentials) |
| — | Settings › General | *Notify when Claude finishes*: post a macOS notification when Claude finishes a turn in a session you are not looking at — the moment the row gets its *done* tint — with the first line of the reply as the body. The same banner stays when the row ages into NEEDS YOU after 60 s, and goes away when you look at the row. **On by default.** The **NEEDS YOU** banner (permission prompt, question, agent input; Claude's own line as the body; several flips in one tick share one "N sessions need you" banner) has no switch of its own — macOS's per-app notification setting is the master switch for both, and macOS asks for it once at launch |
| — | Settings › Shell | *Remove shell integration*: delete the claude shim and the zsh/bash/fish wrappers under Application Support (M3.3) until the next launch, when they are installed again |
| — | Settings › General | *Status line integration*, one row per account: install or remove tkzmux's `statusLine` command, behind a consent sheet |
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
its command rows on the same set. So `reloadConfig` is in the table above and in `ShortcutsTable`,
but nowhere on screen — it was greyed out in the menu and *live* in the palette and the cheat sheet,
where choosing it did nothing at all. `settings` and `notifications` were hidden the same way until
the Settings window and the activity feed gave them handlers.

Its id stays, because `AppState.shortcuts` is keyed by id and an override for an unknown one must
keep parsing; its chord stays in `ShortcutsTable.defaults`, so ⇧⌘, is **reserved, not free**.
Registering a handler is the whole of bringing one back — it reappears in the menu, the palette and
the cheat sheet at once, with no change here or to the table.

The six preference toggles that were app-menu items until the Settings window (`toggleAutoResume`,
`toggleSessionSpend`, `toggleOriginCheck`, `toggleDoneNotification`, `statusLineIntegration`,
`removeShellIntegration`) are gone from the vocabulary: they are rows in the Settings window, not
commands. An old override for one of those ids still parses and is simply never bound.

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
example above used `cmd+t` and `alt+cmd+down` until the pane split bound both to the terminal;
`AppState.fixture` carries the same three overrides and a test asserts the resolved fixture table
has no two actions sharing a chord, because a `TKZMUX_FIXTURE` run is the one place a collision
could be introduced without any menu being built.

> ⌘T, ⌘D and the ⌥⌘ arrows were held unbound from M2.4 as "reserved for the terminal". The pane split is
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
