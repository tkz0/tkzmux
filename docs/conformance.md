# VT conformance

What tkzmux's terminal emulation is actually *known* to do, and by what evidence.

tkzmux does not implement a VT: **libghostty-vt** does, pinned at `vendor/ghostty-vt/COMMIT`.
So this document is not a claim about how good our parser is — it is a record of which
behaviours we have observed through *our* embedding (options, callbacks, snapshots, renderer),
because that is where a wrong option or a missing callback would show up.

Two things are tracked separately and must not be conflated:

1. **Verified today** — assertions that run on every `swift test`. Regressions are impossible
   to miss.
2. **Not yet run** — the `vttest` matrix. `vttest` is deliberately **not installed** on this
   machine, so every cell below is empty. Do not fill any of it in from memory or from
   Ghostty's own conformance claims.

Last updated: M1.9 (TKZ-15), 2026-09-08, against `libghostty-vt` `82232ec`.

---

## 1. Verified today (automated)

### 1.1 Recorded-session replay against golden screens

`.tkzrec` fixtures are real pty recordings (see `Tests/TkzTerminalCoreTests/Fixtures/README.md`
for provenance and sanitization). Each is replayed byte-for-byte through a `TerminalSession`
and the rendered screen is compared to a committed golden `.txt` produced by
`ghostty_formatter_format_alloc(PLAIN)`. This is the strongest conformance evidence we have:
it covers a full-screen TUI (Claude Code) doing alternate screen, scroll regions, SGR colour,
wide characters, and cursor addressing.

```sh
swift test --filter "ReplaysToItsGoldenScreen|LeavesTheExpected"
```

| Fixture | What it exercises | Test | Result |
|---|---|---|---|
| `synthetic-basic` | hand-written control sequences, no pty | `syntheticFixtureReplaysToItsGoldenScreen` | **pass** |
| `zsh-ls-color` | SGR colour, tabs, wrapping from a real `zsh` + `ls -G` | `zshLsColorFixtureReplaysToItsGoldenScreen` | **pass** |
| `claude-boot` | Claude Code startup: alt screen, 2026 sync, bracketed paste, kitty keyboard | `claudeBootFixtureReplaysToItsGoldenScreen` | **pass** |
| `claude-boot` (modes) | 1049 / 2004 / 1000 / 1006 / 2026 / 25 / 1004 + kitty flags after startup | `claudeBootFixtureLeavesTheExpectedTerminalState` | **pass** |
| `claude-tool-run` | a tool invocation redrawing a scroll region | `claudeToolRunFixtureReplaysToItsGoldenScreen` | **pass** |
| — | mode state after a synthetic Claude-style startup | `replayOfClaudeStyleStartupLeavesTheExpectedModes` | **pass** |

Measured 2026-09-08: 6 tests, 6 passed.

### 1.2 Session semantics (M1.9)

`Tests/TkzAppTests/SessionEventHandlerTests.swift` drives real escape sequences through
`TerminalSession` and asserts both the emitted `TerminalEvent` and the app-level state it
produces in `SessionEventHandler`.

| Sequence | `printf` form | Asserted |
|---|---|---|
| OSC 0 | `printf '\e]0;hello\a'` | `.title("hello")`, handler title `hello` |
| OSC 2 (ST-terminated) | `printf '\e]2;window title\e\\'` | `.title("window title")` |
| OSC 7 | `printf '\e]7;file://localhost/tmp/a%%20b\e\\'` | `.pwd(raw)`, decoded to `/tmp/a b` |
| OSC 9 | `printf '\e]9;hello from the shell\e\\'` | `.notification(title: "", body: …)` |
| OSC 9;4 | `printf '\e]9;4;1;70\e\\'` | `.progress(state: .set, value: 70)` |
| BEL | `printf '\a\a'` | two `.bell` events, two visible flashes |

### 1.3 Other automated coverage that is conformance-adjacent

- **Key encoding**: the full modifier × key matrix is *generated* into `docs/keys.md` by the
  tests and re-asserted on every run, so encoding cannot drift silently.
- **Mouse encoding**: SGR press/drag/release byte sequences under modes 1000/1002/1006.
- **DA1 / DA2**: libghostty answers `ESC[?62;22c` and `ESC[>1;<version>;0c` itself; verified
  in M1.3, which is why tkzmux does not install a `DEVICE_ATTRIBUTES` callback.
- **XTVERSION** (`CSI > q`) is answered from `TerminalSessionOptions.xtversion`.
- **DECRQM `?2026$p`** returns `ESC[?2026;1$y` set / `;2$y` reset (M1.3 spike result 3).

---

## 2. Not yet run — the `vttest` matrix

**Status: not run. `vttest` is not installed and was deliberately not installed.**
Nothing in this section has been executed; every result cell is intentionally blank.

### 2.1 Procedure

```sh
brew install vttest
make app                       # or: swift run tkzmux
open build/tkzmux.app
```

Then, in a tkzmux session:

```sh
vttest
```

Run menus **1**, **2** and **3**, and record the outcome of every sub-screen. `vttest` is
interactive: it prints a screen, waits for RETURN, and asks yes/no questions about what was
displayed. Judge each screen against the reference drawings in vttest's own prompts, not
against what "looks fine".

| Menu | Name | What to watch for |
|---|---|---|
| 1 | Test of cursor movements | the eight framed boxes, autowrap at the right margin, DECOM origin mode, tab stops |
| 2 | Test of screen features | scroll regions (DECSTBM), origin mode, DECALN screen alignment, insert/delete line and character, double-width / double-height lines (DECDWL / DECDHL) |
| 3 | Test of character sets | US ASCII, UK, DEC special graphics (line-drawing), the shift in/out (SO/SI) and SCS designations, national replacement sets |

Known-suspect areas for a GPU renderer that this matrix is specifically meant to catch:

- **Double-width / double-height lines** (menu 2) — tkzmux's `FrameBuilder` has no DECDWL /
  DECDHL handling as of M1.9. Expect failures here and treat them as *renderer* gaps, not VT
  gaps: check whether `libghostty-vt`'s render state reports the line attribute before filing
  anything against the library.
- **DEC special graphics** (menu 3) — depends on the glyph atlas having the box-drawing
  codepoints from a font that contains them, so a failure may be a font-fallback bug rather
  than a charset-designation bug.

### 2.2 Results

| Menu | Screen | Result | Notes |
|---|---|---|---|
| 1 | Cursor movements | *not run* | |
| 2 | Screen features | *not run* | |
| 3 | Character sets | *not run* | |

### 2.3 Recording a run as a regression fixture

A vttest run is worth capturing so it stops being a one-off manual exercise:

```sh
swift run tkzmux-vtdump record --cols 80 --rows 24 --out vttest-menu1.tkzrec \
  --script scripts/vttest-menu1.txt --golden vttest-menu1.txt -- vttest
```

with a `--script` that drives the menu (`waitfor "Enter choice"`, `send "1\n"`, `wait`,
`send "\n"`, …). The fixture then joins §1.1 and is checked on every `swift test`. This is the
intended end state: `vttest` run **once** by a human, its result frozen as a golden screen.

`Tests/TkzTerminalCoreTests/Fixtures/` deliberately has no `vttest-menu1.tkzrec` today — see
`docs/design.md` → *Terminal engine*, which records the same "not installed, not installing"
decision.

---

## 3. esctest

Not attempted. `esctest` (the xterm/iTerm2 conformance suite) drives a terminal over a pty and
asserts programmatically, so unlike `vttest` it could run headlessly through
`tkzmux-vtdump record`. It is a bigger job than this ticket and has no ticket of its own yet.
