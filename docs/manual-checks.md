# Manual verification checklist

Everything that a headless session cannot verify. Each item says what to run, what a **pass** looks
like, and what a **fail** looks like — so a failure is reportable without guesswork.

Why these are manual: an automated session's window reports occluded and never key
(`window[visible=true occlusion=8192 key=false]`), so the display link correctly parks and **no
frame is ever presented**. Anything whose acceptance depends on pixels reaching a screen has to be
done at a real login. Two real bugs were found this way on 2026-09-08 that the 557-test suite could
not have caught.

## How to launch — this matters

Build the bundle first (only needed again after a code change):

```sh
cd ~/dev/tkzmux
make app
```

Then pick the right launch for what you are testing. They are **not** interchangeable:

| Command | Use it for | Why |
|---|---|---|
| `open build/tkzmux.app` | Notifications (§2b), general use | A real LaunchServices launch. `UNUserNotificationCenter` needs this; it **traps** in a non-bundled process. No stderr, though. |
| `build/tkzmux.app/Contents/MacOS/tkzmux` | Anything with env vars or log output — §1f, §3, the resize diagnostic | Still a proper bundle (`Bundle.main` is the `.app`, so terminfo and fonts resolve from inside it), but stderr comes back to your shell so you can see `TKZMUX_DEV …` and `TKZMUX_RESIZE …` lines. |
| `make run` / `swift run tkzmux` | **Not these checks** | No `.app` bundle: resources resolve from `.build`, not `Contents/Resources`, so §2c is meaningless, and notifications would trap. Fine for quick iteration, wrong for verification. |

To pass env vars *and* get a proper launch, prefix the direct binary:

```sh
TKZMUX_RESIZE_DEBUG=1 build/tkzmux.app/Contents/MacOS/tkzmux 2>/tmp/resize.log
```

⌘Q quits (or Ctrl-C in the shell for the direct-binary form).

**Click the window first.** An unfocused window is occluded as far as the display link is concerned,
and drawing nothing is correct behaviour there, not a bug.

---

## Already verified — 2026-09-08

Kept for the record so they are not re-tested by mistake.

| Item | Result |
|---|---|
| **Live resize** | **FIXED.** Was: window only resized on mouse-up. Two causes — the display link ran *during* the drag and competed with the synchronous `setFrameSize` render for a 2-drawable pool, so each step blocked ~1 s in `nextDrawable()`. Now the link is vetoed during a drag and the pool is 3. Confirmed: **270 frames, ~12 ms apart, slowest render 6 ms** (was 4 frames total). |
| **⌘Q / ⌘M / ⌘W** | **FIXED.** The app had no menu bar at all, so `NSApplication` had nothing to match ⌘-equivalents against. Minimal menu bar installed; M2.2 replaces it with the `ShortcutsTable`-driven one. |
| **pty winsize** | **PASS.** `stty size` → `51 158`, self-consistent with the earlier 125×40 window (same cell aspect ratio). |
| **Terminal size report** | **PASS.** `printf '\e[18t'` → `ESC[8;51;158t`, matching `stty size` exactly. Kernel and VT agree. |
| **vttest menu 1 "failure"** | **NOT A BUG.** The border framed only ~24 rows of a taller window. `vttest --help` says it all: `Usage: vttest [options] [24x80.132]`, and the man page lists "24 lines, 80 minimum columns". **vttest defaults to 24 lines**; columns come from the terminal, rows do not. That matches the original screenshot exactly — full-width border, 24 rows. Pass the geometry (all three parts) to use the whole window — see §2d. (An earlier guess that this was a stale size from the resize bug was wrong; `stty size` and `\e[18t` both verified correct.) |
| **TKZ-16 on-screen run** | **PASS** (2026-09-08). `drawablesAcquired=886`, `key=true`, 0/600 switches over 8.3 ms, 0.24 % sustained CPU. Also resolved the open "does the compressor stall the visible session" caveat: 9.88 ms worst overshoot on an 8 ms heartbeat across 13 498 samples. Full record in `docs/perf.md` §10. |
| **TKZ-12 §1a–1e** | **PASS** (2026-09-08). Interactive terminal, resize, idle CPU, occlusion, scale change. |

---

## Remaining

### 1. TKZ-12 — view, display link, dev window

**1a. Interactive terminal**
```sh
ls --color
top          # q to quit
cat /usr/share/dict/words     # long scrolling output
```
**Pass**: correct colours, `top` repaints in place, the long `cat` scrolls without corruption or
dropped rows.

**1b. Live resize — tearing check** *(the freeze is fixed; this is the other half)*
Drag the bottom-right corner slowly across several cell boundaries.
**Pass**: text reflows continuously, no tearing, shimmer or black bands.
**Fail**: horizontal tear lines or a half-old/half-new frame — that is a different bug from the
freeze and needs the `presentsWithTransaction` path revisited.

Then confirm the grid follows:
```sh
stty size     # must match the new window
```

**1c. Idle CPU — the headline claim**
Leave the window open and **unfocused** (click another app). A *focused* window blinks the cursor
twice a second, which deliberately wakes the display link — measuring focused would measure the
blink, not the idle path.

Activity Monitor → CPU → `tkzmux`, watch 60 s.
**Pass**: 0.0–0.1 %. **Fail**: anything sustained above ~0.5 %.

Cross-check in Console.app, subsystem `se.tkz.tkzmux`, category `displaylink`: pause/resume lines
must **stop** while idle.

**1d. Occlusion**
Fully cover the window with another app's window (do not minimise).
**Pass**: `displaylink` logs a pause; uncovering logs a resume.

**1e. Retina ↔ non-Retina**
Drag the window to a display of the other scale and back.
**Pass**: one full repaint at the new scale, glyphs crisp, column count changes, no crash. This path
frees and rebuilds every atlas position, so a crash here is a real bug.

**1f. Is it rendering at 1×?** *(new — from the resize log)*
The log showed `drawable=983x674`, i.e. **1×**. Correct if your 7680×2160 display is genuinely
non-Retina; wrong if it is HiDPI, in which case the glyph atlas is rasterised at half resolution.
**Check**: put a line of text side by side with Terminal.app or Ghostty on the same display.
**Pass**: equally sharp. **Fail**: noticeably soft — report it, that is an atlas/backing-scale bug.

---

### 2. TKZ-15 — session semantics and the bundle

**2a. Claude Code inside the bundle**
```sh
claude
```
**Pass**: boots into its fullscreen TUI, renders correctly, a tool call runs and displays, `/exit`
returns cleanly.
Then the keyboard behaviour that could not be verified headlessly: **Shift+Enter inserts a newline**
(does not submit), Enter submits, Ctrl-C interrupts, Esc cancels.

**2b. OSC 9 notification — and its suppression**
```sh
sleep 5; printf '\e]9;tkzmux notification test\e\\'
```
Immediately ⌘M or switch apps so the window is not visible.
**Pass**: a banner appears. (First run asks for notification permission — allow it.)

Now the negative half, which matters as much:
```sh
sleep 5; printf '\e]9;should not appear\e\\'
```
and **leave the window visible**. **Pass**: no banner.

**2c. The bundle uses its own terminfo**
```sh
echo $TERM                       # xterm-ghostty
echo $TERMINFO                   # …/build/tkzmux.app/Contents/Resources/terminfo
infocmp -1 xterm-ghostty | head -1
```
**Pass**: the `infocmp` header names a path **inside** `build/tkzmux.app/`. A `/usr/share/terminfo`
or Homebrew path means the bundled copy is not winning.

**2d. vttest — conformance**
```sh
brew install vttest
```
Then **inside a tkzmux window** — the point is to test our terminal, not Terminal.app.

**Pass the terminal's real size**, or vttest uses its documented default of **24 lines** (columns it
takes from the terminal, rows it does not) and its full-screen frames will only cover the top 24
rows of a taller window — which looks like a failure and is not one:

**Do not invent a column count.** The `24x80.132` in vttest's usage is not a template for arbitrary
numbers: **80 and 132 are the DECCOLM modes vttest understands**, and the two column fields are the
narrow and wide modes, not a window size. Passing e.g. `58x176.176` makes vttest lay text out for
176 columns while drawing its frame at 80 — a garbled display that looks like a cursor-positioning
bug and is not one (observed 2026-09-08).

Either run it plain, which uses the terminal's real width and vttest's default 24 lines:

```sh
vttest
```

or raise only the line count, keeping the columns standard:

```sh
vttest 58x80.132        # lines from `stty size`, columns left alone
```

Type the menu number, press Return. Inside a test, Return advances through screens. `0` exits.

| Menu | Name | Watch for |
|---|---|---|
| `1` | Test of cursor movements | The border should now frame the **whole** window. Boxes align, no smearing or off-by-one rows |
| `2` | Test of screen features | **Expected to FAIL** — no DECDWL/DECDHL support |
| `3` | Test of character sets | Line-drawing glyphs render as lines, not letters |

**Menu 2 will fail**: `FrameBuilder` has no double-width/double-height support as of M1.9. Known
gap, already recorded in `docs/conformance.md`; not a regression.

**Status 2026-09-08**: menu 1 rendered correctly on a plain `vttest` run — unbroken border around the
edge, E-frame exactly in the middle with one free position around it, text inside the frame. It
occupied 24 rows, which is vttest's default and not a defect. Treated as a **pass**; one confirmation
run with `vttest 58x80.132` would close it beyond doubt. Menus 2 and 3 not yet run.

Record results in `docs/conformance.md` §2.2, or just tell me which sub-tests failed and I will
fill it in.

---

### 3. TKZ-16 — 30 sessions in a real window

One command (also in `docs/perf.md` §9). Note `TKZMUX_DEV_WINDOW=1` — the perf harness lives in the
dev window, which M2.2 no longer opens by default:

```sh
SNAP=$(mktemp -d)
TKZMUX_DEV_WINDOW=1 TKZMUX_DEV_SNAPSHOT_DIR="$SNAP" \
TKZMUX_DEV_SPAWN=30 TKZMUX_DEV_BUSY=5 \
TKZMUX_DEV_COMPRESS_IDLE_MS=20000 TKZMUX_DEV_COMPRESS_TICK_MS=5000 \
TKZMUX_DEV_SWITCH_BENCH=600 TKZMUX_DEV_HEARTBEAT_MS=8 \
TKZMUX_DEV_AUTOQUIT_MS=120000 \
build/tkzmux.app/Contents/MacOS/tkzmux
```

**Click the window** so it becomes key, then leave it for two minutes. It prints a `TKZMUX_DEV …`
summary and quits.

**Pass**:
- `drawablesAcquired > 0` and `framesRendered ≈ framesEncoded` — **the only criterion still missing**;
  everything else in TKZ-16 is already measured.
- `occluded=false`.
- `switch[…]`: `show` over 8.3 ms should be 0 or near it.

Then the control run, for "does the idle compressor stall the visible session":
```sh
TKZMUX_DEV_COMPRESS=0   …same flags…
```

**Caveat**: the headless runs showed unexplained tens-of-ms main-thread stalls in **both**
compressor-on and compressor-off runs, not coinciding with a compression pass. If you see occasional
hitches, do not attribute them to the compressor without the control run.

Already measured and in `docs/perf.md`: 158.9 MiB `phys_footprint`, 5 threads, 0.015–0.018 % idle
CPU, 0/3600 switches over budget, 30/30 restored in 87.8 ms.

---

### 4. M2 — the new main window (TKZ-19, TKZ-20)

Only possible once M2.2 assembles the window.

**4a. Sidebar against artboard 2c**
Open the app, put it beside the Claude Design artboard *2c Midnight indigo* at 300 pt sidebar width.
Compare: group header height, uppercase name, 2.5 pt colour edge, count and `＋`; 44 pt rows; dot
size and vertical centring; the two text baselines; `⎇ branch` + `WT`; `NEEDS YOU` right-aligned on
the title line; account chip; summary strip.
Then drag the split to the **240 pt minimum**: titles must truncate without badges moving off the row.
Also check the collapsed-group chevron (`▸`, 9 pt) — it reads as a small dot in the offscreen render.

**4b. Sidebar pulse cost**
≥10 `working` rows visible, Activity Monitor 60 s. **Pass**: ≤1 % CPU; ~0 % when the window is fully
covered. **Not measured yet** — do not quote a number until it is.

**4c. Palette and shortcuts**
⇧⌘P → panel centred, vibrancy visible, first row selected. Type `rounding` → one session row,
`branch: fix/rounding`, match tinted accent. ↓/↑ skip section headers, Return selects, Esc closes.
⌘P → same panel, sessions only, empty query lists everything in sidebar order.
Then every row of `docs/shortcuts.md`.

**4d. `state.json` survives quit, corruption and `kill -9` (M5.1 / TKZ-29)**

The scripted half is automated and was run on 2026-09-08:

```sh
scripts/state-crash-test.sh          # 50 SIGKILL rounds
```
**Result: 50 rounds, every survivor parsed, no round lost its state.** A quarter of the rounds start
from "primary missing, `.bak` present" on purpose — the state a naive rotation loses. The run also
caught a `state.json.bak.new` stranded by a kill between the `link` and the final `rename` in
roughly one round in seven; that is now swept at load, and the script asserts the sweep.

Also verified headlessly on 2026-09-08, at `~/Library/Application Support/tkzmux/state.json`:
quit writes a pretty-printed v1 file with no `live` keys; a relaunch restores the window frame,
sidebar width and visibility, groups, session rows and the selection (`sessions=1
selection=2222…`); a corrupt primary starts from `.bak` and leaves a `state.json.corrupt-<ts>`;
both corrupt starts empty and keeps both copies; an unknown top-level key survives a rewrite; the
sidebar comes up at 300 pt on three consecutive launches with **no drift**.

What still needs a real login, because it needs a screen and a mouse:

1. Open two sessions, rename one, collapse a group, **drag the sidebar to ~380 pt**, move and resize
   the window, select the second session, ⌘Q. **Pass**: the sidebar stays where you dropped it, and
   `state.json` holds both rows, the collapsed group, `sidebar.width` ≈ 380 and the frame you left.
   **Fail**: the sidebar snaps back on mouse-up (reported and fixed 2026-09-08 — the seeding width
   constraint was re-asserting itself on every layout pass after the drag ended), or
   `sidebar.width` is 240 or 300. Confirmed working by hand on 2026-09-08.
2. Relaunch. **Pass**: everything above is back; the selected row's last screen is visible with a
   fresh prompt under it (M5.2 reopens the selected row on first show); every other row reads
   `exited` until it is selected. **Fail**: a blank black rectangle, or an empty terminal grid
   under the exited scrim. (Before M5.2 the pass condition here was the empty state reading
   *"Session not running · resume arrives in M5.2"*.)
3. `printf 'x' > "$HOME/Library/Application Support/tkzmux/state.json"`, relaunch. **Pass**: the
   sidebar is back and the status strip reads *"Restored sidebar from backup"* for ~10 s.
4. `kill -9` the app while working, relaunch. **Pass**: the sidebar is back (the last ≤500 ms of
   changes may be missing, and the sidebar width will be whatever the previous quit recorded).

Known gap: the palette has no `didResignKey` observer, so clicking the main window hides it without
firing `onDismiss`. If "click outside dismisses" is wanted, say so.

---

### 5. M3 — Claude integration (TKZ-21, TKZ-22, TKZ-23, TKZ-24)

Verified headlessly on 2026-09-08 (see design.md → *Claude integration*): the installer writes
`bin/claude`, `bin/tkzmux-hook`, the four dotted wrappers and `VERSION`; a login zsh under the
wrappers with the real rc files has `$TKZMUX_BIN` first on PATH and `which claude` → the shim;
`settings-merge` keeps the git-ai hooks and appends tkzmux's; a real `claude` started through the
shim delivers the `launch` frame and the `SessionStart` hook to the running app. What is left needs
the window:

*GUI pass 2026-09-08: 5b, 5c, 5e, 5f pass; 5a (title stayed on the home directory), 5c (no done tint) and 5d (⇧⌘R unwired) fixed afterwards — re-check 5a, 5c, 5d.*

**5a. A row follows Claude.** `>_` → in the new terminal run `which claude` (expect
`…/tkzmux/bin/claude`), then `claude`. **Pass**: within a second the row's title becomes the
directory name and the dot is idle; ask for something → dot turns green (`working`) while Claude
runs; when the answer lands with the row selected and the window key, the dot goes back to idle
with the "done" tint (accent colour) and no amber badge. Also: `cd` into a repo *before* running
`claude` — the row should take that directory's name, not the home directory's.

**5b. NEEDS YOU on a permission prompt.** Ask Claude to run a shell command that needs approval.
**Pass**: `NEEDS YOU` and the amber dot within 1 s of the prompt; answering clears both within 1 s
(the descriptor flips `waiting → busy`). The summary strip counts it.

**5c. Finished while you were elsewhere.** Start a long request, select another row (or another
app), wait. **Pass**: amber `NEEDS YOU` at 60 s after the answer landed (immediately on an
`idle_prompt` notification); selecting the row clears it. Then ⇧⌘C copies the last message, and
clicking the done/waiting dot opens the popover with the full text.

**5d. Auto-naming.** Let a session run long enough for Claude to name it (`nameSource: auto`).
**Pass**: the row re-titles live; ⇧⌘R still wins over it.

**5e. Nothing changes outside tkzmux.** In Terminal.app: `which claude` is unchanged and
`claude` runs without tkzmux hooks. Then *Remove Shell Integration* from the app menu: a new
tkzmux terminal is a plain login shell (`which claude` → the real one); relaunching the app
reinstalls.

**5f. Idle cost.** 10 live sessions, Activity Monitor 60 s. **Pass**: the watcher's share is
invisible (< 0.3 % total for the app at idle).

---

### 6. M5.2 — launch and restore flows (TKZ-30)

Verified headlessly on 2026-09-08: `SessionLauncherTests`, `MainWindowRestoreTests`,
`PresetsSheetTests` and `WorktreeListTests` cover start/reopen/resume/close/remove against a spy
host and real directories; a `swift run tkzmux` with `TKZMUX_DEV_AUTOQUIT_MS` over the real
`state.json` (10 rows) reopened the selected row and housekeeping removed 14 orphaned `.ghsnap`
files. What is left is the ticket's acceptance list, which needs a display and real Claude sessions.
Keep Console.app open on subsystem `se.tkz.tkzmux`, category `launch`, for every step — each
start/reopen logs its cwd, `CLAUDE_CONFIG_DIR` and command (docs/perf.md → *Launch audit*).

**6a. New worktree.** Select a repo group (＋ New group on CoreInvest if it is not there yet),
⌘N → *New worktree (claude -w)*. **Pass**: `<repo>/.claude/worktrees/<name>` exists within a few
seconds, the row shows the `WT` badge and the worktree name as its title, and Claude's auto-name
replaces the title later. **Fail**: no badge (the descriptor's cwd was not under
`.claude/worktrees`), or the title stays the repo's basename.

**6b. Quit and restore.** Open ~10 sessions across both accounts (Account submenu on ⌘N), some
worktree, some repo root, a couple of plain `>_` shells; rename one; ⌘Q. Relaunch. **Pass**:
groups, order and selection are identical; the selected row shows its last screen with a fresh
prompt; clicking any other row shows *its* last screen with a fresh prompt (a login zsh, so
~50 ms). ⌘R on a row → `claude --resume <id>` is typed, the conversation continues, the title is
kept, and in that Claude `/usage` shows the plan of the account the row was started on. In
Console the `launch` line for that row carries the right `CLAUDE_CONFIG_DIR` (`default` for the
primary account, `~/.<key>` otherwise). **Fail**: a row reopens in the wrong directory, on the
wrong account, or `--resume` starts a *new* conversation (the descriptor's `sessionId` changed).

**6c. Worktree deleted by hand.** Quit; `rm -rf <repo>/.claude/worktrees/<name>` (and
`git -C <repo> worktree prune`); relaunch; ⌘R on that row. **Pass**: the shell opens in the repo
root, the `WT` badge is gone, the status strip says nothing alarming. Also: let a `claude -w`
session end and answer "remove the worktree" — within a second the badge comes off that row without
a relaunch.

**6d. Preset.** ＋ → *From preset…* → *Manage presets…*: add one with command `claude`, start in
*New worktree*, name `preset-test`, account = the second account, env `TKZ_PRESET=1`; Done. Run it
from the presets submenu. **Pass**: a session in `<repo>/.claude/worktrees/preset-test` on the
second account (`/usage`), and `echo $TKZ_PRESET` in a `>_` shell of the same preset prints 1.

**6e. Close and remove.** ⌘W on a `working` row → an alert; Cancel keeps it running; Close hangs
it up, the screen dims, the row stays. ⌘W again on that (now exited) row → the row is gone, no
alert. ⇧⌘W (or right-click → Remove) on a live row → an alert; Remove deletes the row; its
`.ghsnap` under Application Support is gone; the worktree on disk is **not**.
Right-click a group header → *Resume all in <group>* resumes every resumable row and leaves the
selection alone.

**6f. Auto-resume.** App menu → *Auto-resume Sessions on Launch* (checkmark on). ⌘Q, relaunch.
**Pass**: every row with a conversation gets `claude --resume` typed, the status strip says
"Auto-resumed N sessions", and each lands on its own account.

**6g. A day of use.** ≥ 20 sessions over a working day. **Pass**: no lost rows after any quit or
crash, and in Console every `launch` line's `CLAUDE_CONFIG_DIR` matches the row's account chip.
Paste the `log show` extract into docs/perf.md → *Launch audit* → run notes.

## Reporting back

For anything that fails: which step, what you saw instead, and — for rendering issues — whether the
window was focused and whether anything was covering it.

The resize diagnostic is still available if a drag ever misbehaves again:
```sh
TKZMUX_RESIZE_DEBUG=1 build/tkzmux.app/Contents/MacOS/tkzmux 2>/tmp/resize.log
```
Every line is stamped with milliseconds since the first, so a stall shows as a **gap between lines**.
`TKZMUX_RESIZE_MODE=async` drops `presentsWithTransaction` as an A/B.
