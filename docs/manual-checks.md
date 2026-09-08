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

Known gap: the palette has no `didResignKey` observer, so clicking the main window hides it without
firing `onDismiss`. If "click outside dismisses" is wanted, say so.

---

## Reporting back

For anything that fails: which step, what you saw instead, and — for rendering issues — whether the
window was focused and whether anything was covering it.

The resize diagnostic is still available if a drag ever misbehaves again:
```sh
TKZMUX_RESIZE_DEBUG=1 build/tkzmux.app/Contents/MacOS/tkzmux 2>/tmp/resize.log
```
Every line is stamped with milliseconds since the first, so a stall shows as a **gap between lines**.
`TKZMUX_RESIZE_MODE=async` drops `presentsWithTransaction` as an A/B.
