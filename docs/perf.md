# tkzmux performance — measured numbers

> Every number in this file was measured on this machine, on the date given, with the build
> configuration given. Nothing here is estimated, scaled, or copied from a spike. Where something
> could not be measured headlessly it says **not measured** and why.

**Machine** Apple M4 Max, 14 cores, 36 GiB RAM (`hw.memsize` 38 654 705 664), macOS 26.6.2 (25G83).
**Toolchain** Apple Swift 6.2.1 (swiftlang-6.2.1.4.8), target `arm64-apple-macosx26.0`.
**Repo** commit `b7720a6` + the M1.10 working tree; libghostty-vt pinned at `82232ec`.
**Date** 2026-09-08 (the JSON records carry UTC timestamps, so they read `2026-09-07T23:…Z`).
**Configuration** every number below is **release** (`swift build -c release`). No debug numbers appear
in this document.

## How to reproduce

The harness is `BenchCommands` in `Sources/tkzmux-vtdump/BenchCommands.swift`:

```sh
swift build -c release
.build/release/tkzmux-vtdump bench --sessions 30 --busy 30 --seconds 60 --json out.json
.build/release/tkzmux-vtdump bench --sessions 30 --busy 30 --seconds 60 --fill varied --json out.json
.build/release/tkzmux-vtdump bench --sessions 30 --busy 30 --no-compress --json control.json
```

At the time of measurement the `bench` case was not yet dispatched from `main.swift` (owned by
another ticket), so the runs below were produced by compiling **the same file, unmodified**, into a
one-line release executable that calls `BenchCommands.run`. The dispatch line needed is in the
ticket's report.

### What the harness measures, and what it does not

* All memory/thread/CPU numbers are for **the tkzmux host process only**. The N `zsh` children are
  separate processes; their own RSS and CPU are *not* included anywhere in this document.
* `RSS` = `mach_task_basic_info.resident_size`. `Footprint` = `task_vm_info.phys_footprint`, which is
  what Activity Monitor shows as "Memory" and what the memory-pressure system charges you for.
  These two diverge sharply once pages are `MADV_FREE`'d — see *Does compression pay?*.
* CPU = `proc_pid_rusage(RUSAGE_INFO_V4)` user + system time, delta over the wall-clock window,
  expressed as a percentage of **one** core. (`task_basic_info.user_time` excludes live threads and
  would have under-reported; `top` was not shelled out to.)
* Threads = `task_threads` count, with every returned port deallocated so the reading does not
  inflate itself.
* Sessions are 120×40, `SCROLLBACK_MAX_BYTES` = 24 MiB, spawned through
  `TerminalEnvironment.loginShellSpawn` → `Pty` → `TerminalSession`, i.e. the real production path.
* The `ZDOTDIR` the harness passes points at a directory that does not exist, so **zsh sources no
  user rc file**. That makes runs reproducible, but it is not the user's real shell startup cost.
* Liveness was gated, not assumed: every run below reports `alive_sessions == sessions` and a
  non-zero scrollback row count per session. An exited shell would have made RSS look wonderful.
* Each N ran in a **fresh process**, so memory freed by a smaller run cannot flatter a larger one.

Fill corpora:

| `--fill` | command | why |
|---|---|---|
| `uniform` (default) | `yes $'\e[32m<100 x's>\e[0m' \| head -n 20000` | worst case for memory, and the same shape the M1.3 spike used, so its 19 MiB anchor is comparable |
| `varied` | `{ ls -laRG /usr/share /usr/lib /usr/local; ls -laRG /System/Library/Frameworks; } \| head -n 20000` | real, non-repeating terminal output through a real pty |

---

## 1. Session scaling — RSS, threads, CPU

`--fill uniform`, 20 000 lines per busy session, 60 s idle window. Release. 2026-09-08.

| N sessions | RSS after fill | Footprint after fill | RSS delta ÷ N | scrollback rows/session | alive |
|---:|---:|---:|---:|---:|---:|
| 1 | 28.4 MiB | 22.3 MiB | 22.33 MiB | 19 963 | 1/1 |
| 5 | 106.0 MiB | 99.9 MiB | 19.98 MiB | 19 963 | 5/5 |
| 10 | 201.8 MiB | 195.6 MiB | 19.57 MiB | 19 963 | 10/10 |
| 30 | 584.4 MiB | 578.5 MiB | 19.27 MiB | 19 963 | 30/30 |

**Per-session slope** (the honest figure — it excludes dyld/GCD first-touch cost, which the N=1
column folds in): (584.19 − 106.0) MiB ÷ 25 = **19.13 MiB per filled session**. That matches the
M1.3 spike's 19.0 MiB anchor for one session filled with 20 000 lines.

**30 sessions with no load at all** (`--busy 0`, shells spawned and left at a prompt; the sample is
taken after spawn + a 1.5 s settle, not after a fill): total RSS 12.2 MiB and footprint 6.1 MiB,
against a 6.1 MiB RSS / 1.7 MiB footprint process baseline → **≈ 208 KiB RSS (≈ 150 KiB footprint)
per idle session**. The M1.3 spike measured 32 KiB for a single terminal with no pty attached; the
difference is the pty read buffers and the shell's first screen, which the spike did not have.

### Threads

| N | baseline | after spawn | peak during simultaneous fill | at end of 60 s idle |
|---:|---:|---:|---:|---:|
| 1 | 1 | 3 | 3 | 2 |
| 5 | 1 | 3 | 6 | 2 |
| 10 | 1 | 3 | 11 | 2 |
| 30 | 1 | 3 | 26–27 | 2 |

**30 live sessions cost 3 Mach threads.** Each session has its own serial `DispatchQueue`, not its
own thread; GCD only widens the pool while many queues have work *at the same instant*, which is
what the "peak" column shows — 30 shells all dumping 2.2 MB each. It collapses back to 2 threads
within the idle window. There is no per-surface thread pool.

### CPU, 30 sessions, 60 s idle

| metric | value |
|---|---|
| idle window | 60.004 s |
| process CPU consumed in that window | **≤ 15 µs** (the record reads 0.000015 s at the formatter's 1 µs resolution — i.e. indistinguishable from zero) |
| as a percentage of one core | **< 0.0001 %** |
| total CPU for the whole run (spawn + 66.6 MB ingested + idle + snapshot + restore) | 0.138 s |

**Caveat that matters**: an idle `zsh` at a prompt emits *nothing*. A live Claude Code session
redraws a spinner and a status line continuously, so this figure is a **floor**, not a prediction of
the real app's idle CPU. Idle CPU with a window, a display link and live Claude sessions is
**not measured — requires the GUI harness in TKZ-16 part 2**.

## 2. Snapshot: size, save and restore

30 sessions, each holding 19 963 scrollback rows. Release, 2026-09-08. Times are the **sum over all
30 sessions**, single-threaded, sequential.

| corpus | total `.ghsnap` | per session | encode | write (tmp+fsync+rename) | read | `restore(from:)` |
|---|---:|---:|---:|---:|---:|---:|
| uniform | 230.7 MiB | 7.69 MiB | 76.9 ms | 77.9 ms | 16.6 ms | 230.5 ms |
| varied | 28.9 MiB | 0.96 MiB | 74.9 ms | 11.6 ms | 3.2 ms | 71.9 ms |

Correctness check on every one of the 30: the PLAIN-formatted active screen was byte-identical
before and after the disk round trip, and the scrollback row count was unchanged
(`active_screen_identical_after_restore: 30`, `scrollback_rows_identical_after_restore: 30`).
*(In the 30-idle run those counters read 30 and 0 — the row check requires rows > 0 and an idle
shell has none. Not a failure.)*

Restore *raises* process RSS (584 → 843 MiB across 30 restores): each `restore` builds a fresh
terminal and frees the old one to the allocator, not back to the OS.

### Snapshot size vs scrollback (one session, `--fill … --lines N`)

| lines fed | rows retained | live RSS delta | snapshot (uniform) | snapshot (varied) |
|---:|---:|---:|---:|---:|
| 500 | ~470 | 3.6–3.8 MiB | 0.193 MiB | 0.027 MiB |
| 2 000 | ~1 970 | 5.1 MiB | 0.770 MiB | 0.109 MiB |
| 5 000 | ~4 970 | 8.1 MiB | 1.924 MiB | 0.242 MiB |
| 20 000 | ~20 000 | 22.3–22.5 MiB | 7.690 MiB | 0.963 MiB |
| 60 000 | 23 927 / 23 740 (24 MiB cap reached) | 27.1 MiB | 9.215 MiB | 1.418 MiB |

Two facts fall out of this table, and they change how the "bound the snapshot" advice should be read:

1. **Live memory is page-based; snapshot size is content-based.** 20 000 rows cost the same
   ~22.4 MiB live whether the content is 100 identical columns or real `ls -laR` output, but the
   snapshot differs 8× (7.69 vs 0.96 MiB). The 24 MiB `SCROLLBACK_MAX_BYTES` cap also lands at
   roughly the same *row* count for both corpora (23 927 vs 23 740).
2. So design.md's "lower `SCROLLBACK_MAX_BYTES` first to bound size" bounds **live retention**, and
   only bounds the snapshot as a second-order effect. For realistic content the snapshot is already
   ~1 MiB, and even the worst case is 9.2 MiB — cheap next to 22–27 MiB of live scrollback.
   Whether lowering the option on a *live* terminal trims existing scrollback immediately is
   **not measured**: `TerminalSession` has no scrollback-limit setter today (see the ticket's
   required deltas). `SnapshotStore.save(for:bounding:encode:)` carries the bound through to the
   encoder so the policy is expressible the moment that setter exists.

The M1.3 spike's "snapshot ≈ 19 % of live RSS" was one corpus. Measured here: **36 %** (uniform),
**4.3 %** (varied). The ratio is a property of the content, not of the library.

## 3. Does compression pay? (the M1.3 re-measurement)

design.md, *Spike results* row 13: "`compress(FULL)` reclaimed nothing on synthetic uniform
scrollback … **do not assume `compress()` lowers RSS**; re-measure on a real `claude-boot` recording
before wiring the idle timer (M1.10)."

### First: the committed fixtures cannot be used for this

`Tests/TkzTerminalCoreTests/Fixtures/claude-boot.tkzrec` and `claude-tool-run.tkzrec` both end with
**mode ?1049 set (alt screen)** and `scrollback rows: 0` (verified with
`tkzmux-vtdump replay --modes`). Replaying `claude-boot` 300 times produces **0 scrollback rows** and
a 4 622-byte snapshot — the alt screen is overwritten each time and nothing is ever scrolled into
history. Compression on that terminal is a no-op by construction (0 → 0 rows, 0 B RSS change, both
INCREMENTAL and FULL). Claude Code's TUI lives in the alt screen; the scrollback a real session
accumulates is whatever is *behind* it, which these fixtures do not contain.

So the re-measurement was done where it is meaningful: on the **30 live sessions**, real `zsh`
output through a real pty, with a **control run that skips compression entirely**.

### Result: compression reclaims ~95 % of the footprint

30 sessions × 19 963 rows, INCREMENTAL looped to `COMPLETE`, release, 2026-09-08:

| | control (`--no-compress`) | compression enabled |
|---|---:|---:|
| INCREMENTAL steps | 0 | 1 710 (57 per session) |
| wall time for the whole pass | — | **112.9 ms** (≈ 66 µs per step, ≈ 3.8 ms per session) |
| footprint before → after | 577.0 → **577.0 MiB** | 577.1 → **26.4 MiB** |
| RSS before → after | 583.0 → 583.0 MiB | 583.0 → **629.9 MiB** (*rises*) |
| `task_vm_info.reusable` before → after | 0.0 → 0.0 MiB | 0.0 → **597.7 MiB** |
| scrollback rows before → after | 598 890 → 598 890 | 598 890 → 598 890 |

The control is the important column: with the identical workload and no `compress` calls, footprint
does not move. The drop is attributable to `ghostty_terminal_compress`.

**Why the spike saw nothing.** It measured `resident_size`. On Darwin, pages released with
`MADV_FREE` stay in `resident_size` until the kernel actually needs them — they move into
`task_vm_info.reusable`, which is exactly what happened here (0 → 597.7 MiB). `phys_footprint`,
which excludes reusable pages and is what Activity Monitor and memory pressure use, fell
**577 → 26 MiB**. RSS *rising* by 47 MiB is the compressed copies being allocated. The spike's
conclusion was a measurement artefact of the metric, not a property of the library.

Residual cost of a compressed background session: (26.4 − 6.1 MiB process baseline) ÷ 30 ≈
**0.68 MiB per session** for the uniform corpus (≈ 1.5 MiB for the varied corpus, footprint 50.3 MiB
in that run) — down from 19.3 MiB.

### The other half: rehydration is real

`terminal.h` says "accessing compressed history restores it transparently", and it does — with a
cost. Snapshotting all 30 sessions *after* compressing them brought footprint back to 269.7 MiB
(against 843.1 MiB for the same step in the uncompressed control). Scrolling, searching and
snapshot-at-quit all touch history and will re-inflate.

**Recommendation (changes design.md):**

* **Wire the idle timer.** On real pty output at 30 sessions it converts 577 MiB of footprint into
  26 MiB for 113 ms of CPU, with no change to logical content (row counts identical, snapshots
  identical afterwards).
* **Snapshot before compressing**, not after — snapshot walks the history and undoes the win.
* The step is far cheaper than the policy assumes: ~66 µs per INCREMENTAL step, ~3.8 ms to take one
  20 000-row session all the way to `COMPLETE`. `IdleCompressionPolicy.stepInterval` currently
  defaults to 1 s, which would take a minute per session; either loop to `COMPLETE` inside one tick
  (bounded at a few ms under the lock) or drop the interval to ~10 ms. **The default was left at
  1 s** — changing it belongs with the ticket that actually wires the timer and can measure the
  effect on frame pacing.

## 4. Comparison against the cmux baseline

design.md records the baseline this project exists to beat: **cmux at 2.47 GB RSS (≈ 2.30 GiB),
167 threads, 7–9 % CPU while idle, for 20 workspaces / 31 panels / 7 live Claude Code sessions.**

| | cmux baseline (from design.md) | tkzmux, measured 2026-09-08 |
|---|---|---|
| workload | 20 workspaces, 31 panels, **7 live Claude Code sessions** | **30 zsh sessions**, each fed 20 000 lines, then idle |
| memory | 2.47 GB RSS (≈ 2.30 GiB); basis not recorded — likely Activity Monitor, i.e. footprint | 584 MiB RSS / 578 MiB footprint with all 30 holding full scrollback; **26 MiB footprint** after the idle compression pass |
| threads | 167 | **3** (peak 27 while all 30 ingest simultaneously; 2 at idle) |
| CPU idle | 7–9 % | < 0.0001 % of one core over 60 s — **but with no program producing output** |
| origin | measured by the author on the real app | this document |

**This is not an apples-to-apples comparison, and should never be quoted as one:**

* cmux was running **7 live Claude Code sessions** — a TUI that redraws continuously, plus Electron,
  plus a Node process per session. The tkzmux harness runs **`zsh` sitting at a prompt**, which
  emits nothing at all once its shell has started. The CPU rows in particular are measuring two
  different things; the tkzmux figure is a floor.
* The tkzmux column is the **host process only**. cmux's 2.47 GB presumably included its renderer
  and helper processes. tkzmux's 30 `zsh` children are not counted here at all — their cost is
  **not measured** by this harness.
* The memory basis differs: tkzmux reports RSS and footprint separately and says which is which;
  the cmux figure's basis was not recorded.
* cmux's 167 threads was a steady-state reading with live sessions. tkzmux's "3" is also steady
  state, but with quiet sessions. The structural claim — **one serial queue per session, no
  per-surface thread pool** — is what the peak-27/idle-2 pattern supports, and that part does
  transfer.

What can be said without hedging: **30 sessions with full scrollback, in one process, on 3 threads,
is a different order of magnitude from 31 panels on 167 threads**, and the per-session cost is
19.1 MiB live / 0.7 MiB after compression rather than tens of MB.

## 5. Not measured

> Some of these were answered by the GUI half below (sections 6–9), which was measured later in the
> same ticket. Where that is the case the bullet says so; the rest still stand.

* Idle CPU, frame pacing and memory of the **real app with a window and a display link** — requires
  the GUI harness (TKZ-16 part 2). **Idle CPU and memory: now measured, section 7. Frame pacing:
  still not measured, section 9 — the display link parks when the window is occluded and this
  machine has no foreground GUI session.**
* Anything with **live Claude Code sessions** rather than `zsh`. Every Claude number above would
  need a rerun with `claude` as the spawned command.
* The RSS/CPU of the spawned `zsh` children.
* Whether lowering `SCROLLBACK_MAX_BYTES` on a live terminal trims retained scrollback immediately
  (no setter exists yet).
* `compress(FULL)` at scale: only INCREMENTAL-to-`COMPLETE` was measured on the live sessions, since
  that is what an idle timer would call.

## Raw records

Every table above comes from `bench --json` output. The records used were
`sessions-{1,5,10,30}-busy.json`, `sessions-30-idle.json`, `sessions-30-varied.json`,
`sessions-30-nocompress.json`, `sessions-30-compress.json` and the `curve-{uniform,varied}-*.json`
series. Re-running the commands in *How to reproduce* regenerates them.

---

# GUI half — 30 sessions in the real app process (M1.10 part 2, TKZ-16)

Everything above was measured by `tkzmux-vtdump bench`, a headless benchmark binary. Everything
below was measured **inside `tkzmux.app` itself** — a real `NSApplication`, a real `NSWindow`, a
real `TerminalMetalView`, a real `CAMetalLayer`, and the real `TerminalViewHost` the app uses — so
the two halves measure different processes and the numbers are not interchangeable.

**Date** 2026-09-08. **Configuration** release: `make app` (`swift build -c release`, ad-hoc
signed), run as `build/tkzmux.app/Contents/MacOS/tkzmux`. Machine and toolchain as at the top of
this document. No debug numbers appear below.

## 6. What could and could not be measured here

Every run in this section reported the same window state:

```
window[visible=true occlusion=8192 key=false]
link[pauses=0 resumes=0 currentlyPaused=true needsUpdate=true occluded=true session=true]
framesRendered=0 drawableRequests=… drawablesAcquired=0
```

The window is created and `isVisible`, but the session has no foreground GUI login, so the window
never becomes key and AppKit reports it occluded. `DisplayLinkPolicy` therefore parks the display
link — which is **correct behaviour**, and is the same reason `drawablesAcquired` is 0 in every
run: not one frame was ever presented to a screen. Launching through LaunchServices
(`open --env … build/tkzmux.app`) was tried and produced the identical state.

So, plainly:

* **Measured here**: memory (RSS *and* `phys_footprint`), thread count, CPU, the idle-compression
  timer's effect on all three, snapshot-at-quit, restore-at-launch, and session-switch cost —
  including the CPU-side frame rebuild, forced through an **offscreen** render so that "switch"
  means something with the link parked.
* **Not measured here, pending a human at a real GUI session**: presented-frame pacing, dropped
  frames against a live `CADisplayLink`, and anything involving `drawablesAcquired > 0`. The exact
  steps are in *9. Pending manual*.

### The harness

`DevWindowController` is driven entirely by environment variables (documented in its header
comment). The acceptance harness is `TKZMUX_DEV_SPAWN=30 TKZMUX_DEV_BUSY=5`: thirty login `zsh`
sessions, five of which run the busy command and then idle. It is also on a titlebar button
("Spawn 30") for interactive use.

```sh
make app
SNAP=$(mktemp -d)          # ALWAYS point the store somewhere disposable
TKZMUX_DEV_SNAPSHOT_DIR="$SNAP" TKZMUX_DEV_SPAWN=30 TKZMUX_DEV_BUSY=5 \
  TKZMUX_DEV_COMPRESS=0 TKZMUX_DEV_HEARTBEAT_MS=8 TKZMUX_DEV_SAMPLE_MS=10000 \
  TKZMUX_DEV_AUTOQUIT_MS=90000 build/tkzmux.app/Contents/MacOS/tkzmux
```

Three things about the corpus, because they make these numbers **not comparable** with section 1:

1. The busy command is `yes | head -c 5000000` — 5 MB of `y\n`, i.e. 2.5 M one-character lines, in
   **five** sessions. Section 1's `--fill uniform` is 20 000 hundred-column coloured lines in
   **thirty** sessions. Same cap (`SCROLLBACK_MAX_BYTES` = 24 MiB), radically different content.
   That is why the GUI harness sits at 159 MiB of footprint where the headless bench sat at 578.
2. The ticket spells the command `yes | head -c 5M`. BSD `head` rejects the suffix
   (`head: illegal byte count`) and silently produces nothing, so the harness writes the byte count
   out. Same 5 MB.
3. The busy command is typed **2 s after** the spawn, not immediately. A login `zsh` calls
   `tcsetattr(…, TCSAFLUSH, …)` while it sets up its line editor, which discards whatever is
   already in the tty input queue. Measured: with no delay all thirty snapshots came back at the
   same bare-prompt size and `head` never ran. This is a real constraint on
   `TerminalHost.run(_:command:)` and M2 must respect it when it auto-runs `claude` on session
   start.

Also note the harness spawns thirty shells; as in section 1, **every number is the tkzmux host
process only**. The thirty `zsh` children are not counted anywhere.

## 7. 30 sessions: memory, threads, CPU — and what the idle timer does to them

Two 90 s runs, identical except for the idle-compression timer. `TKZMUX_DEV_SAMPLE_MS=10000` writes
a `TKZMUX_SAMPLE` line to stderr every ten seconds; the rows below are those samples.

| t | control (`TKZMUX_DEV_COMPRESS=0`) | | | idle timer on (`IDLE_MS=20000 TICK_MS=5000`) | | |
|---:|---:|---:|---:|---:|---:|---:|
| | RSS | footprint | reusable | RSS | footprint | reusable |
| 10 s (fill in flight) | 215.1 | 158.9 | 0.2 | 219.8 | 159.2 | 0.2 |
| 20 s | 215.0 | 158.9 | 0.1 | 219.8 | 159.3 | 0.1 |
| 30 s | 215.0 | 158.9 | 0.1 | 220.2 | 159.7 | 0.1 |
| 40 s | 215.0 | 158.9 | 0.1 | 222.9 | **67.0** | **95.4** |
| 50–90 s | 215.0 | 158.9 | 0.1 | 222.9 | 67.0 | 95.4 |

All figures MiB. The compression pass ran between the 30 s and 40 s samples.

**The section-3 result reproduces in the app, on a different corpus.** `phys_footprint` fell
**159.3 → 67.0 MiB** while `resident_size` *rose* 219.8 → 222.9 MiB and `task_vm_info.reusable`
went 0.1 → 95.4 MiB. The control column, same workload with no `compress` calls, does not move at
all. Anyone reading RSS alone would again conclude that compression achieved nothing; it reclaimed
58 % of this process's footprint.

### Threads

| | control | idle timer on |
|---|---:|---:|
| t = 10 s (spawn + fill in flight) | 8 | 9 |
| t = 20 s onwards, 30 live sessions idle | **5** | **5** |

Thirty live pty sessions cost **5 Mach threads** in the app process — one serial `DispatchQueue`
per session, no per-surface thread pool, and the idle-compression timer's `.utility` queue does not
add a persistent thread (the timer-on column is 5 as well). Section 1 measured 3 in a binary with
no AppKit; what the difference is made of was not broken down.

### CPU while idle

Per-10-second sample, 30 sessions sitting at a `zsh` prompt after the fill drained:

| | control | idle timer on |
|---|---:|---:|
| 30 s → 90 s samples | 0.0153 – 0.0175 % of one core | 0.0163 – 0.0280 % of one core |
| whole 78 s post-settle window | 0.0586 % | 0.0702 % |
| whole run, spawn + 25 MB ingested + idle + quit snapshot | 1.21 % over 90.1 s | 1.24 % over 90.1 s |

The "whole post-settle window" row is higher than the per-sample rows because the settle baseline is
taken 12 s after launch and the last of the five 5 MB fills is still draining then.

**The caveat from section 1 applies unchanged and is the most important sentence here**: an idle
`zsh` at a prompt emits nothing. A live Claude Code session redraws a spinner continuously. These
CPU numbers are a **floor**, not a prediction. Idle CPU with live Claude sessions is
**not measured**.

### External cross-check

The in-process sampler is a duplicate of `BenchCommands`' one, so it was checked against the system
tools on a live 30-session run (pid 16823):

| | in-process | system tool |
|---|---:|---:|
| `phys_footprint` | 159.2 MiB | `/usr/bin/footprint -p` → `phys_footprint: 159 MB` |
| `resident_size` | 219.7 MiB | `ps -o rss` → 224 976 KiB = 219.7 MiB |

## 8. The measured GUI acceptance criteria

### Session switching: `show(id)` inside one frame

`show(_:)` is wrapped in an `os_signpost` interval (`subsystem se.tkz.tkzmux`, category
`terminalhost`, name `show`) and its wall time is also recorded in-process so a distribution can be
printed without Instruments. **The budget is one frame at 120 Hz: 8.3 ms.**

Two numbers are reported per switch, because with the link parked `show` alone would be
meaninglessly cheap:

* **show** — `TerminalViewHost.show(_:)` only: detach the old surface, attach the new one, rewire
  the render signal, re-apply the grid.
* **frame** — `show` **plus** the first frame after it: `FrameBuilder` rebuilding every row from the
  fresh render state, plus a full Metal encode to an offscreen texture. This is the honest "what
  the user waits for" figure minus the present.

600 switches round-robin across 30 sessions, six runs, milliseconds. The `>8.3 ms` columns are
counts of individual switches, not summary statistics — the acceptance criterion is stated per
switch, so it is counted per switch.

| run | compression | show min | show median | show p99 | show max | **show > 8.3 ms** | frame min | frame median | frame p99 | frame max | **frame > 8.3 ms** | `DIRTY_FULL` |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| D1 | off | 0.080 | 0.097 | 0.342 | 5.987 | **0** | 0.360 | 0.421 | 0.697 | 46.455 | **1** | 600/600 |
| D2 | off | 0.083 | 0.101 | 0.237 | 1.805 | **0** | 0.365 | 0.417 | 0.566 | 5.123 | **0** | 600/600 |
| D3 | off | 0.082 | 0.097 | 0.231 | 1.707 | **0** | 0.356 | 0.403 | 0.600 | 7.178 | **0** | 600/600 |
| E1 | on | 0.086 | 0.106 | 0.321 | 1.056 | **0** | 0.369 | 0.428 | 0.757 | 28.747 | **1** | 600/600 |
| E2 | on | 0.080 | 0.089 | 0.206 | 0.829 | **0** | 0.349 | 0.380 | 0.519 | 4.841 | **0** | 600/600 |
| E3 | on | 0.083 | 0.099 | 0.375 | 1.809 | **0** | 0.359 | 0.414 | 0.782 | 11.864 | **1** | 600/600 |

**Across 3 600 switches: `show` was never over budget (0/3 600), and `show` + a full frame rebuild
was over budget 3 times (3/3 600 — one with the idle timer off, two with it on).** Medians across the six runs are
0.089–0.106 ms (`show`) and 0.380–0.428 ms (`show` + frame); no p99 exceeds 0.375 ms and
0.782 ms respectively. The three over-budget samples are single
outliers on an unpinned machine with no realtime priority, and the worst of them (46.5 ms) came
from a run with the timer *disabled* — so nothing here attributes them to compression.

The busy sessions in these runs were **not** the same corpus as section 1: each had ingested 5 MB
of `y\n` and retained **23 122 scrollback rows** (the 24 MiB `SCROLLBACK_MAX_BYTES` cap, reached);
the other 25 sessions held 0 rows, for 115 610 rows in the process. Section 1's runs held 19 963
rows in *each* of 30 sessions.

**The sanity check the numbers needed.** A switch that was optimised away would look implausibly
fast, so every one of the 3 600 switches above was followed by a frame that had to report
`GHOSTTY_RENDER_STATE_DIRTY_FULL` with a non-zero glyph count — the signature of a freshly
allocated render state. All 3 600 did (`full=600` in every run). `TerminalHostTests` asserts the
same property, and additionally that the single `TerminalSurface` holds the visible session and no
other across all 30.

### Background sessions cost only IO

Asserted structurally rather than inferred from a number
(`Tests/TkzAppTests/TerminalHostTests.swift`):

* with 30 sessions open, `TerminalRenderContext.liveSurfaces().count == 1` — there is one
  `TerminalSurface` in the process, and after `show(nil)` it holds no libghostty memory at all
  (`isAttached == false`, `glyphCount == 0`);
* 64 KiB written into a **background** session leaves `DisplayLinkDriver.demand.needsUpdate` false
  and `resumeCount` unchanged; the same bytes into the visible session set it. A background session
  has no `renderSignal` closure to call, so this is structural, not a policy check.

### Snapshot on quit

Thirty sessions, five holding 23 122 scrollback rows each — the 24 MiB `SCROLLBACK_MAX_BYTES` cap,
measured with `TerminalSession.scrollbackRows` — encoding to 95 811 B each; the other 25 are 1 244 B
bare prompts.

| | control | idle timer on |
|---|---|---|
| sessions saved at quit | 30 | **1** |
| sessions skipped (already saved by the timer) | 0 | **29** |
| bytes written at quit | 510 155 | 95 811 |
| wall time for the sweep | **58.8 ms** | **8.1 ms** |
| `.ghsnap` files on disk afterwards | 30 (580 KiB) | 30 (580 KiB) |

This is the *snapshot-before-compressing* rule from section 3 turned into a mechanism. The idle
timer snapshots a session to disk immediately before it compresses it and records the
`ghostty_terminal_compression_activity` token it saved at; at quit, a session whose token has not
moved is skipped. Without that, quitting would walk 29 compressed histories and rehydrate every one
of them — undoing the 92 MiB the timer had just reclaimed, at the exact moment the user is trying
to quit.

### Restore on launch

A second launch of the same app against the same store, with `TKZMUX_DEV_SPAWN` unset:

| metric | value |
|---|---|
| sessions restored | **30 / 30**, 0 failed |
| bytes read | 510 155 |
| `restoreAll` wall time (load + `ghostty_snapshot_decoder` + 30 `posix_spawn`) | **87.8 ms** |
| RSS / footprint after restore, 30 sessions idle | 213.3 MiB / 152.9 MiB |
| threads | 6 |
| CPU, 10 s samples over the following 30 s | 0.0137 – 0.0159 % of one core |

Each restored session gets its old content **and a fresh shell** — the pid differs, and the new
shell prints a new prompt below the restored scrollback. `TerminalHostTests` asserts exactly that
end to end (write a marker → snapshot → new host over the same store → restore → the marker is in
the formatted screen and the pid changed).

### Does the idle timer disturb the visible session?

The direct measurement — dropped presented frames — **cannot be taken headlessly**, because the
display link correctly parks when the window is occluded and encodes no frames at all. What was
measured instead is a labelled **proxy**: an 8 ms `DispatchSourceTimer` on the *main* queue,
recording its worst delivery overshoot.

| window | control | idle timer on |
|---|---:|---:|
| the 10 s sample containing the compression pass | — (no pass) | **9.74 ms** worst overshoot |
| worst overshoot over the whole 78 s post-settle run | **47.46 ms** | **94.00 ms** |

The compression pass itself cost **20.5 ms of CPU in total** for 322 INCREMENTAL steps across 29
sessions (four further runs of the same shape: 12.4, 12.7, 15.7 and 16.8 ms, always 29 passes /
322 steps), with the **longest single session's pass at 5.25 ms** (4.44–5.05 ms in the other runs)
— and that pass runs on a
`.utility` queue holding *that background session's* lock, never the visible session's. The visible
session is excluded by `IdleCompressionPolicy` and the exclusion is unit-tested.

Conclusion, with its limits. Both runs show unexplained tens-of-millisecond main-thread stalls, and
**neither run's worst case lines up in time with a compression pass**: the control has no passes at
all and still hit 47 ms, and in the timer-on run the 10 s window that actually *contains* the pass
is the 9.74 ms row, not the 94 ms one. The cause of the outliers was not identified. What the data
supports is only this: the compression pass costs 20.5 ms of CPU on a background queue and never
takes the visible session's lock, and no main-thread stall coincides with it. A real dropped-frame
count is **not measured** and is listed below.

### Idle-timer parameters, as wired

`TerminalIdleCompressor` drives `IdleCompressionPolicy` with `idleThreshold` 60 s (design.md's
number) and a 5 s tick. `stepInterval` is set to **0** rather than the policy's 1 s default: section
3 measured ~66 µs per step, so a due session is taken all the way to `COMPLETE` inside one tick,
bounded by a 4 096-step budget. The measured cost of that decision is the 4.4–5.3 ms worst-case
single-session pass — one background session's lock, held once, for well under a frame.

Idleness is detected by polling `ghostty_terminal_compression_activity` on the timer's own tick, not
by instrumenting the pty read path: a shared lock on the hot IO path would serialize 30 sessions
against each other for no gain.

The compressor owns the token comparison rather than handing every token straight to
`IdleCompressionPolicy.noteActivityToken`. `terminal.h` does not say whether a compression pass
moves the activity token, and **measured, it does not** — at quit, all 29 compressed sessions were
skipped as already-fresh, which is precisely the check "current token == token at snapshot time".
Owning the comparison means it cannot matter either way: if a future libghostty did move the token
across a pass, a naive `noteActivityToken` would read the pass as user activity, restart the idle
delay, and re-snapshot (i.e. rehydrate) the session on every cycle. There is a unit test for that
failure mode.

## 9. Not measured (GUI half)

* **Presented-frame pacing and dropped frames against a live `CADisplayLink`.** Requires a
  foreground GUI session; every run here reported `occluded=true, key=false` and
  `drawablesAcquired=0`. To verify manually: log in at the Mac's own display, `make app`, then
  ```sh
  SNAP=$(mktemp -d)
  TKZMUX_DEV_SNAPSHOT_DIR="$SNAP" TKZMUX_DEV_SPAWN=30 TKZMUX_DEV_BUSY=5 \
    TKZMUX_DEV_COMPRESS_IDLE_MS=20000 TKZMUX_DEV_COMPRESS_TICK_MS=5000 \
    TKZMUX_DEV_SWITCH_BENCH=600 TKZMUX_DEV_AUTOQUIT_MS=120000 \
    build/tkzmux.app/Contents/MacOS/tkzmux
  ```
  and check that `drawablesAcquired > 0`, `framesRendered` is close to `framesEncoded`, and
  `occlusion` no longer reports occluded. The switch distribution printed by that run is then the
  on-screen one.
* **`os_signpost` traces in Instruments.** The intervals are emitted (`se.tkz.tkzmux` /
  `terminalhost` / `show`); the distributions above were computed in-process instead, because
  Instruments needs a GUI.
* **Anything with live Claude Code sessions** rather than `zsh` — every CPU number would need a
  rerun with `claude` as the command, and it is the number that matters most for the cmux
  comparison.
* **The RSS/CPU of the 30 spawned `zsh` children.**
* Whether the corpus difference explains the whole 578 → 159 MiB gap between the headless bench and
  this harness. The two runs differ in content *and* in how many sessions are filled; neither was
  re-run in the other's shape.
