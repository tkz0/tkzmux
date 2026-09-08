# Manual verification checklist

Everything in M1 that a headless session cannot verify. Each item says what to run, what a **pass**
looks like, and what a **fail** looks like — so a failure is reportable without guesswork.

Why these are manual: every launch in an automated session reports the window occluded and never
key (`window[visible=true occlusion=8192 key=false]`), so the display link correctly parks and
**no frame is ever presented**. Anything whose acceptance depends on pixels reaching a screen has to
be done at a real login.

Build once:

```sh
cd ~/dev/tkzmux
make app
open build/tkzmux.app
```

The dev window opens with one login zsh. **Click it first** — an unfocused window is occluded as far
as the display link is concerned, and drawing nothing is correct behaviour there, not a bug.

---

## 0. Live resize — OPEN BUG, do this one first

Reported 2026-09-08: dragging a window edge does not resize live; the window only jumps to its new
size on mouse-up. One fix has already been attempted and did **not** work, so this is now an
experiment rather than a re-test. Two runs, five minutes.

### 0a. Capture what actually happens

```sh
TKZMUX_RESIZE_DEBUG=1 build/tkzmux.app/Contents/MacOS/tkzmux 2>/tmp/resize.log
```

Click the window, drag the **bottom-right corner** slowly for two or three seconds, release, then
quit (⌘Q). Send me `/tmp/resize.log`.

Each line is one of:

```
TKZMUX_RESIZE willStartLiveResize mode=transaction
TKZMUX_RESIZE setFrameSize 1012x680 inLiveResize=true drawable=2024x1360 pwt=true needsDisplay=true attached=true
TKZMUX_RESIZE   render 1.83 ms (frame 12)
TKZMUX_RESIZE didEndLiveResize frames=37 slowest=4.10 ms
```

What the log settles, before you send it — worth a glance yourself:

| What you see | What it means |
|---|---|
| No `willStartLiveResize` line at all | AppKit is not routing live resize to the view. The rendering code is innocent. |
| `willStartLiveResize` but no `setFrameSize` lines during the drag | The view is never asked to resize — a window/layout problem, not a Metal one. |
| Many `setFrameSize` lines, `render` times in the tens of ms | We are stalling the drag. Blocking present or GPU contention. |
| Many `setFrameSize` lines, `render` under ~2 ms, still frozen | We draw fine and something downstream swallows the frame. |

### 0b. The decisive A/B

```sh
TKZMUX_RESIZE_DEBUG=1 TKZMUX_RESIZE_MODE=async build/tkzmux.app/Contents/MacOS/tkzmux 2>/tmp/resize-async.log
```

Drag the same way. `async` drops `presentsWithTransaction` and presents through the command buffer.

- **Live resize now works** → the synchronous transactional present is the cause. Tearing may appear
  during a fast drag; that is expected in this mode and is the trade we then fix properly.
- **Still frozen** → the present path is *not* the cause, and the two logs together say where to
  look next.

Tell me which, and send both logs.

---

## 1. TKZ-12 — view, display link, dev window

### 1a. Interactive terminal
Type in the window:
```sh
ls --color
top          # q to quit
cat /usr/share/dict/words     # long scrolling output
```
**Pass**: text renders correctly, colours are right, `top` repaints in place, the long `cat` scrolls
without corruption or dropped rows.

### 1b. `stty size` follows the window
Resize the window, then:
```sh
stty size
```
**Pass**: rows/cols match the new window. (Blocked until §0 is fixed.)

### 1c. Idle CPU — the headline claim
Leave the window open and **unfocused** (click another app). A *focused* window blinks the cursor
twice a second, which deliberately wakes the display link — measuring focused would be measuring the
blink.

Activity Monitor → CPU → `tkzmux`. Watch 60 s.

**Pass**: 0.0–0.1 %. **Fail**: anything sustained above ~0.5 %.

Cross-check the link is genuinely parked — Console.app, subsystem `se.tkz.tkzmux`, category
`displaylink`: pause/resume lines must **stop** while idle.

### 1d. Occlusion
Fully cover the window with another app's window (do not minimise).
**Pass**: `displaylink` logs a pause; uncovering logs a resume.

### 1e. Retina ↔ non-Retina
Drag the window to a 1x display and back.
**Pass**: one full repaint at the new scale, glyphs crisp (not blurry or doubled), column count
changes, no crash. This path frees and rebuilds every atlas position, so a crash here is a real bug.

### 1f. Job control (TKZ-8's remaining item)
```sh
sleep 100
# press Ctrl-Z
jobs        # [1]  + suspended  sleep 100
fg          # resumes
# press Ctrl-C
```
**Pass**: exactly that. Headlessly we verified only the invariant beneath it (the shell owns a
controlling tty and `tcgetpgrp` returns a different pgid while a job runs).

---

## 2. TKZ-15 — session semantics and the bundle

### 2a. Claude Code inside the bundle
In the window: `claude`
**Pass**: boots into its fullscreen TUI, renders correctly, a tool call runs and displays, `/exit`
returns to the prompt cleanly.
Then check the keyboard behaviour TKZ-13 could not verify: **Shift+Enter inserts a newline** (does
not submit), Enter submits, Ctrl-C interrupts, Esc cancels.

### 2b. OSC 9 notification, and its suppression
```sh
sleep 5; printf '\e]9;tkzmux notification test\e\\'
```
Immediately press ⌘M (or switch apps) so the window is not visible.
**Pass**: a macOS banner appears. First run will ask for notification permission — allow it.

Now the negative half, which matters as much:
```sh
sleep 5; printf '\e]9;should not appear\e\\'
```
and **leave the window visible**.
**Pass**: no banner.

### 2c. The bundle really uses its own terminfo
```sh
echo $TERM                       # xterm-ghostty
echo $TERMINFO                   # …/build/tkzmux.app/Contents/Resources/terminfo
infocmp -1 xterm-ghostty | head -1
```
**Pass**: the `infocmp` header names a path **inside** `build/tkzmux.app/`. If it names
`/usr/share/terminfo` or a Homebrew path, the bundled copy is not winning.

### 2d. vttest — conformance

Not installed, and deliberately not installed by an automated session.

```sh
brew install vttest
```

Then **inside a tkzmux window** (the point is to test our terminal, not Terminal.app):

```sh
vttest
```

You get a numbered menu. **Type the number, press Return.** Inside a test, press Return to advance
through screens; each test ends by returning to the menu. `0` + Return exits.

Run these three:

| Menu | Name | What to watch for |
|---|---|---|
| `1` | Test of cursor movements | Boxes and grids align; no smearing or off-by-one rows |
| `2` | Test of screen features | **Double-width/double-height lines are expected to FAIL** |
| `3` | Test of character sets | Line-drawing glyphs render as lines, not letters |

**Menu 2 will fail** — `FrameBuilder` has no DECDWL/DECDHL support as of M1.9. That is a known gap,
already written into `docs/conformance.md`; it is not a regression. Everything else in menus 1 and 3
should pass.

Record results in `docs/conformance.md` §2.2 — there is a table waiting with the procedure. For each
sub-test note pass/fail and a one-line symptom for failures. If you would rather not transcribe,
just tell me which sub-tests failed and I will fill it in.

---

## 3. TKZ-16 — 30 sessions in a real window

One command does the whole acceptance run (also in `docs/perf.md` §9):

```sh
SNAP=$(mktemp -d)
TKZMUX_DEV_SNAPSHOT_DIR="$SNAP" \
TKZMUX_DEV_SPAWN=30 TKZMUX_DEV_BUSY=5 \
TKZMUX_DEV_COMPRESS_IDLE_MS=20000 TKZMUX_DEV_COMPRESS_TICK_MS=5000 \
TKZMUX_DEV_SWITCH_BENCH=600 TKZMUX_DEV_HEARTBEAT_MS=8 \
TKZMUX_DEV_AUTOQUIT_MS=120000 \
build/tkzmux.app/Contents/MacOS/tkzmux
```

**Click the window** so it becomes key, then leave it alone for two minutes. It prints a
`TKZMUX_DEV …` summary line and quits.

**Pass**:
- `drawablesAcquired > 0` and `framesRendered ≈ framesEncoded` — this is the only criterion still
  missing; everything else in TKZ-16 is already measured.
- `occluded=false`.
- The `switch[…]` distribution: `show` over 8.3 ms should be 0 or very close to it.

Then the control run, to answer "does the idle compressor stall the visible session":

```sh
TKZMUX_DEV_COMPRESS=0 …same flags…
```
Compare `framesSkipped` and the frame-time distribution against the run above.

**Caveat, stated honestly**: the headless runs showed unexplained tens-of-ms main-thread stalls in
*both* the compressor-on and compressor-off runs, which do **not** line up with a compression pass.
So if you see occasional hitches, they are probably not the compressor — do not attribute them
without the control run.

Everything else in TKZ-16 is already measured and in `docs/perf.md`: 158.9 MiB `phys_footprint`,
5 threads, 0.015–0.018 % idle CPU, 0/3600 switches over budget, 30/30 sessions restored in 87.8 ms.

---

## 4. TKZ-10 — fonts on a machine without JetBrains Mono

This Mac has JetBrains Mono in `~/Library/Fonts`, so a bundled-font failure is invisible here.

```sh
mkdir -p /tmp/fonts-parked
mv ~/Library/Fonts/JetBrainsMono*.ttf /tmp/fonts-parked/
killall -HUP fontd      # or log out and back in
open build/tkzmux.app
```

**Pass**: terminal text is still JetBrains Mono, not Menlo. Menlo is noticeably wider with a
different `g` and `l`; if unsure, compare against a screenshot taken before parking the fonts.

Restore:
```sh
mv /tmp/fonts-parked/JetBrainsMono*.ttf ~/Library/Fonts/
killall -HUP fontd
```

---

## Reporting back

For anything that fails, the useful minimum is: which step, what you saw instead, and — for
rendering issues — whether the window was focused and whether anything was covering it. For §0,
both logs.
