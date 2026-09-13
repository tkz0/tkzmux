# Testing tkzmux

How to run the test suites, how to run the app to check a change by eye, and the toolchain
problems you are likely to hit on the way.

## Layout

One test target per Swift library module, under `Tests/<Module>Tests`, written with Swift Testing
(`import Testing`, `@Test`, `#expect`) — not XCTest.

| Target | Covers |
|---|---|
| `TkzCoreTests` | models, `AppStore`, status derivation, theme tokens |
| `PersistenceTests` | `state.json`, migrations, snapshots |
| `ClaudeBridgeTests` | session watcher, hook server, transcript search |
| `GitStatusTests` | git status, FSEvents, PR lookup |
| `TkzTerminalCoreTests` | pty, VT bridge, key encoding |
| `TkzTerminalRenderTests` | fonts, glyph atlas, frame building |
| `TkzTerminalViewTests` | keyboard/IME, mouse/selection |
| `TkzAppTests` | window, toolbar, menus, shortcuts, palette, cheat sheet |

## Before you start: which toolchain

```sh
xcode-select -p
```

* **`/Applications/Xcode.app/...`** — everything works as-is.
* **`/Library/Developer/CommandLineTools`** (no Xcode installed) — the app builds, but tests fail
  with `error: no such module 'Testing'`. CommandLineTools *does* ship Swift Testing, in
  `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`; SwiftPM just does not look
  there. Pass the path yourself (below). `scripts/test-memory-probe.sh` detects this and adds the
  flags on its own.

The flags, for any `swift build --build-tests` or `swift test` under CommandLineTools:

```sh
CLT=/Library/Developer/CommandLineTools
CLT_TEST_FLAGS="-Xswiftc -F$CLT/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib"
```

Use the **same** flags for the build and the test run, or SwiftPM rebuilds everything in between.

## Running tests

### The safe default: the memory probe

```sh
scripts/test-memory-probe.sh                  # every target, one at a time
scripts/test-memory-probe.sh TkzAppTests      # just one (or several) targets
scripts/test-memory-probe.sh ALL              # the unfiltered `swift test`, under the watchdog
```

It builds the tests once, then runs each target while watching the test helper's memory. A target
that passes 4 GB (`LIMIT_MB`) or 420 s (`TIMEOUT_S`) is diagnosed with `vmmap`/`heap`/`sample` and
then killed. Logs and reports go to `.build/memory-probe/` (`OUT_DIR`); on a build failure read
`.build/memory-probe/build.log`, not the 20-line tail it prints.

**Why not just `swift test`:** anything started from a tkzmux terminal runs in tkzmux's process
coalition, and macOS bills the coalition to its leader. On 2026-09-09 one unfiltered `swift test`
grew a helper to ~40 GB, which showed up as "tkzmux: 40 GB" and took the machine into swap. See
`docs/perf.md`.

### A few suites directly

Fine for small, filtered runs while iterating:

```sh
swift test --filter 'MainToolbarTests|ShortcutsTableTests'            # Xcode
swift test --filter 'MainToolbarTests|ShortcutsTableTests' $CLT_TEST_FLAGS   # CommandLineTools
```

`--filter` is a regex over suite and test names. Keep it narrow; for anything wide, use the probe.

## Checking a change visually

The app runs fine outside a bundle — no test flags needed:

```sh
swift run tkzmux                    # debug build, window appears
make app && open build/tkzmux.app   # release .app, ad-hoc signed
```

```sh
TKZMUX_FIXTURE=1 swift run tkzmux   # fixed sample groups and sessions; loads and saves nothing
```

`TKZMUX_FIXTURE=1` seeds the window with `AppState.fixture` (`Sources/TkzCore/FixtureState.swift`)
instead of your saved state, and never writes `state.json` — so a screen looks the same every time
and a test run cannot touch your real sessions.

Example — the session search shortcut:

1. Launch the app.
2. The toolbar's search field reads **"Search sessions…  ⌘F"**; hovering shows "Search sessions (⌘F)".
3. ⌘F puts the caret in the field; typing opens the results overlay.
4. Hold ⌘ for the cheat sheet: *Search Sessions…* is listed as ⌘F.

The chord in the placeholder comes from the resolved shortcut table, so an override in
`AppState.shortcuts` (e.g. `"searchSessions": "shift+cmd+k"`) shows its own keys.

## Where you are building matters

Worktrees under `.claude/worktrees/<name>` are separate checkouts. Changes made in a worktree are
**not** in the main checkout until they are merged — running the probe from
`~/Documents/Projects/tkzmux` tests `main`, not the worktree. Check the paths in the error output.

## Toolchain errors seen with Swift 6.3

Newer compilers are stricter than the 6.2 this repo targets. Fixed so far:

| Error | Where | Fix |
|---|---|---|
| `no such module 'Testing'` | every test file | CommandLineTools only — the flags above |
| `sending 'sweep' risks causing data races` | `Sources/TkzApp/TerminalHost.swift` | copy the `var` into a `let` before the queue hop |
| `cannot convert value of type 'Int32' to expected argument type 'UInt32'` | `KeyEncoderTests.swift` | key on `GhosttyKey.RawValue`; the C enum's raw type varies by toolchain |
| `no calls to throwing functions occur within 'try' expression` (warning) | `tkzmux-vtdump/FrameBenchCommand.swift` | `write(ptyBytes:)` does not throw; drop the `try` |

Do not silence concurrency errors with `@unchecked Sendable` or `-strict-concurrency=minimal`
(CLAUDE.md); fix the capture instead.
