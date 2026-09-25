# ▶ Run: detected dev-server button

## Context

Starting a project's dev server today means opening a split and typing `pnpm dev` by hand. The
goal is an IDE-style Run button that detects the project's start command and runs it in a real
terminal pane, with a menu for the project's other tasks.

Decisions already made in brainstorming:
- **Concept:** a ▶ button for the best guess, plus a ▾ menu listing every detected task.
- **Depth:** the repo root only (no workspace or subfolder scanning).
- **Target:** a stacked split in the current tab. The button toggles to ■ Stop.
- **Surfaces:** a toolbar split button, plus a keyboard shortcut.
- **Worktrees:** detect and run in the **worktree's own root**, never the main checkout.

Survey of `~/dev`:
- `pnpm dev` at the root: CoreInvest, aira, alfred, swedtech.
- `npm run dev`: mac-dash, which has no `packageManager` field.
- `npm start`: workamo-web (CRA).
- `just up`: workamo-app. Its `dev` is not a recipe.
- `.sln`/`.csproj`: many .NET repos.

## Design

### 1. Project root: the worktree's root, not the repo root
- `root = git.service.repoInfo(for: sessionID)?.toplevel ?? session.effectiveCwd`. This is the same
  resolution the changes viewer uses (`MainWindowController.swift:1339`, `GitIntegration.swift:337`).
- `RepoInfo.toplevel` (`Sources/GitStatus/RepoInfo.swift:27`) is `git rev-parse --show-toplevel`, so in
  a worktree it is `<repo>/.claude/worktrees/<name>`. It is never `RepoInfo.repoRoot` / `Session.repoRoot`,
  which are the main checkout.
- Detection reads the files in `root`, and the pane's shell starts with `cwd = root`. It does not start in
  the source pane's OSC 7 directory, which may be stale or `cd`'d elsewhere.
- Two worktrees of one repo therefore run their own servers from their own trees. The group default
  (§4) is a command string, so it applies in every worktree unchanged.

### 2. Detection: pure, testable, repo root only
New file `Sources/TkzCore/RunTasks.swift`, with no AppKit.

**Types and entry point:**
- `RunTask { id, label, command, source }`, e.g. `("dev", "pnpm dev", .packageJSON)`.
- `RunTaskDetector.detect(files: [String: String]) -> [RunTask]` takes the root's file contents,
  keyed by filename, so tests need no disk. It returns tasks ranked best-first.
- A thin reader in TkzApp lists the root once, reads only the known manifest names (each capped at
  about 256 KB), and caches the result per `root`. It re-detects on selection change and each time
  the menu opens. The reads are cheap and there is no watcher.

**Sources:**

| File | Tasks | Command form |
|---|---|---|
| `package.json` `scripts` | every script | Runner comes from `packageManager` (`pnpm@…`), else the lockfile (`pnpm-lock.yaml`, `yarn.lock`, `bun.lock`/`bun.lockb`, else npm) → `pnpm <s>` / `yarn <s>` / `bun run <s>` / `npm run <s>` (`npm start` for `start`) |
| `deno.json(c)` `tasks` | every task | `deno task <t>` |
| `justfile` / `Justfile` | recipes: `^name…:`, skipping `_private` and `default` | `just <r>` |
| `Makefile` | targets `^[A-Za-z][\w-]*:`, skipping `.`-prefixed names and variable assignments | `make <t>` |
| `Taskfile.yml` | top-level `tasks:` keys (line scan, no YAML parser) | `task <t>` |
| `Cargo.toml` / `go.mod` / `Package.swift` | one task | `cargo run` / `go run .` / `swift run` |
| `*.csproj` at root | one task | `dotnet watch run` |
| `manage.py` / `bin/dev` | one task | `python manage.py runserver` / `bin/dev` |
| `compose.yaml` / `docker-compose.yml` | one task | `docker compose up` |

**Best-guess rank:**
1. The group default (§4)
2. The script/recipe/target named `dev`
3. `start`
4. `serve`
5. `up`
6. `run`
7. The language one-liners
8. `docker compose up`

Results on the survey:
- `pnpm dev` everywhere it exists.
- `npm run dev` for mac-dash.
- `npm start` for workamo-web.
- `just up` for workamo-app.

Menu order: tasks grouped by source. Recipes and targets appear in file order, JSON scripts
alphabetically (`JSONSerialization` keeps no order). The one ▶ runs carries a ✓. Lifecycle hooks
(`postinstall`, `prebuild`, …) are left out.

### 3. Running and stopping in a pane
- **Run** calls the new `SessionLauncher.runDevServer(_:in:for:)`. It splits the focused pane stacked
  (`.vertical`, like ⇧⌘D), gives focus back to the source pane, and opens the shell with
  `environment(accountKey:bootCommand:)`. *(As built: a method of its own rather than two more
  parameters on `addTerminal`, since it also keeps focus, records the run pane and respawns.)*
  - The existing `TKZMUX_BOOT_COMMAND` hook then runs the command at the first prompt, after
    direnv/mise, adds it to history, and brackets it in OSC 9;4 (`Sources/AgentBridge/Resources/zsh/zlogin:41-64`,
    with bash/fish equivalents).
  - It deliberately does **not** go through `start(spec)`, which would raise the "Starting Claude…"
    overlay.
- **Tracking:** new non-persisted `LiveSessionState.runPane: RunPane? { terminal, command, running }`,
  with the reducers `beginRunPane`/`runPaneReturned` in `Reducers.swift`. The diff delivers it in the
  `sessions` bucket, and `Group.runCommand` in `groups`, with no new bucket.
  - `running` goes to false on `.progress(.remove)` for that terminal. This extends the existing case at
    `MainWindowController.swift:4239`.
  - The pane closing (`closePane`) clears `runPane`.
- **Stop** (■) sends Ctrl-C (`0x03`) to that pane's pty through the existing `TerminalHost.writeInput`,
  the same as a user pressing it.
  - The pane stays at its prompt with the logs visible, and the button flips back to ▶ when the
    `.remove` marker arrives.
- **Run again** while the run pane sits idle: respawn that same leaf with the boot command, so the layout is
  kept and the progress bracket holds. This is the same discard-and-`host.open` pattern as
  `reopen(_:bootCommand:)` (:182).
  - Running a *different* task from the menu while one is running stops the first (Ctrl-C), then respawns
    the pane with the new command.
- **Row status is untouched.** The run pane never becomes `agentTerminal`. Ports need nothing new:
  `PortScanner` already walks every `panePids` entry, and `:5173` appears in the status bar, clickable.

### 4. The remembered command, per repo/group
- New optional `Group.runCommand: String?` (`Models.swift:108`). It decodes as `nil` with no migration,
  the same story as `Group.agent` (:133-137). There is a `setRunCommand` reducer, and `state.json` persists
  it.
- **Choosing is remembering.** Running any task from the ▾ menu, or entering a **"Custom command…"**,
  stores that command string on the row's group, and the ▶ button shows it from then on. There is no
  separate "Use as default" step.
  - "Custom command…" is a small text prompt, which covers `.sln` repos where the right `--project` is
    nested.
  - **"Reset to detected"** clears it, and the ▶ goes back to the best guess.
- It is per group (one repo), so every worktree row in that group picks it up and runs it in its own
  toplevel. This matches "the account default belongs to the group".
- A row with no group, or in a bucket group with no `repoRoot`, still runs its choice but remembers
  nothing. It falls back to detection each time.

### 5. UI surfaces
- **Toolbar** (`Sources/TkzApp/Toolbar/MainToolbarController.swift`): a new `NSToolbarItem.Identifier.tkzRun`
  placed before `.tkzViewCluster`. It is a two-segment control: `▶ pnpm dev` | `▾`.
  - The ▾ segment carries an `NSMenu`, with rows showing `label  command` and a ✓ on the remembered one.
    Picking a row runs it **and** remembers it (§4). Then come Custom command… and Reset to detected.
    If the remembered command is not among the detected tasks, it is listed first as its own row.
  - While running, the first segment reads `■ pnpm dev`.
  - The controller exposes `setRun(_ model: RunButtonModel?)` and closures `onRun`, `onStop`, `onRunTask(id)`,
    `onSetDefault`, keeping its "owns no state" rule.
  - It is hidden (a `nil` model) when the selected row has no directory. With no tasks detected it
    reads `▶ Run…` and click opens the menu, which offers "Custom command…".
- **Shortcut:** `ShortcutAction.runDevServer`, **⌃⌘R** "Run / Stop Dev Server". ⌘R is Resume, ⌥⌘R is Rebase,
  and ⇧⌘R is Rename.
  - Add it to `allActions`, `defaults`, and `title(for:)` (`Sources/TkzApp/Menus/ShortcutsTable.swift`), and to
    the **Session** menu in `MainMenu.build`. `MainMenuTests` requires the menu item.
  - Register the handler in `MainWindowController` (:4273-4375). The palette row then comes for free.
- **Model builder:** `RunButtonModel { title, isRunning, tasks, defaultCommand }` is built alongside the
  status bar model (`MainWindowController.swift:~2707`) on selection changes and `runPane` changes.

### Out of scope (YAGNI)
Subfolder and workspace scanning, a hidden background mode, auto-open browser, per-worktree defaults,
file watching, and escalating Stop to SIGKILL.

## Critical files
- New: `Sources/TkzCore/RunTasks.swift`, `Tests/TkzCoreTests/RunTasksTests.swift`
- `Sources/TkzCore/Models.swift` (`Group.runCommand`, `LiveSessionState.runPane`), `Sources/TkzCore/Reducers.swift`
- `Sources/TkzApp/SessionLauncher.swift` (`runDevServer` / `stopDevServer`: split, respawn-in-place, Ctrl-C)
- `Sources/TkzApp/TerminalHost.swift` (restore resets the old program's input modes)
- `Sources/TkzApp/Toolbar/MainToolbarController.swift` (the run item)
- `Sources/TkzApp/Menus/ShortcutsTable.swift`, `Sources/TkzApp/Menus/MainMenu.swift`, `Sources/TkzApp/MainWindowController.swift`
- `docs/shortcuts.md` (the new ⌃⌘R)
- `docs/plans/2026-09-25-run-button-design.md` (this design, per the brainstorming skill)

## Process
- Build it test-first in this order: detector → reducers → launcher → toolbar/shortcut.
- Ask before committing. The commit goes on this worktree's branch, then a PR to main.

## Verification
1. **Detector unit tests** (`RunTasksTests`), using fixture file maps copied from the survey:
   - CoreInvest root → `pnpm dev` best, with `dev:web`, `dev:api`, `db:up`, … listed.
   - mac-dash (no `packageManager`, `package-lock`) → `npm run dev`.
   - workamo-web → `npm start`.
   - workamo justfile → `just up`, with `_clear-pids` and `default` excluded.
   - yarn/bun lockfiles; `Cargo.toml` → `cargo run`; an empty dir → `[]`.
2. **Reducer tests:**
   - `runPane` is set, cleared on `closePane`, and flipped by the remove marker.
   - The `Group.runCommand` round-trip works, including an old `state.json` that has no key.
   - Running a menu task writes `runCommand` on the group. A second worktree row in the same group then
     resolves the same command as its best guess.
3. **Launcher test** with the spy host: the Run in a **worktree row** opens with `cwd == RepoInfo.toplevel`
   (the worktree), not `repoRoot`, and the env carries `TKZMUX_BOOT_COMMAND`. The overlay is not raised.
4. `MainMenuTests` / shortcut tests green. Run `scripts/test-memory-probe.sh` per target, not an unfiltered
   `swift test`, and grep the logs for "Test run with".
5. **Manual:** `make app`, open a CoreInvest worktree row, and check:
   - ▶ reads `pnpm dev`.
   - Clicking it opens a split in the worktree dir, and `:5173` appears in the status bar.
   - ■ (or ⌃⌘R) Ctrl-Cs it and the button flips to ▶.
   - ▶ again respawns in place.
   - ▾ → `dev:web` runs it, and the ▶ now reads `pnpm dev:web`.
   - The same holds on another worktree row of CoreInvest and after an app relaunch.
   - Reset to detected brings back `pnpm dev`.
   - Custom command… on a .NET group runs in each worktree.
