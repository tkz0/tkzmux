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

* Idle CPU, frame pacing and memory of the **real app with a window and a display link** — requires
  the GUI harness (TKZ-16 part 2).
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
