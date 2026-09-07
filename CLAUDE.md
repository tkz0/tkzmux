# tkzmux

Native macOS Claude Code session manager (personal cmux replacement). Swift 6.2, AppKit-first, own Metal renderer, **libghostty-vt** as the only third-party dependency, vendored as a prebuilt xcframework. Pure SwiftPM, no `.xcodeproj`; the `.app` is assembled by `make app`. macOS 26+, arm64 only.

The architecture is in **`docs/design.md`**. Read the section a ticket points to before writing code.

## Commands

```sh
swift build                 # debug build of everything
swift test                  # all test targets (Swift Testing)
swift run tkzmux            # run the app outside a bundle (window still appears)
make app                    # release build → build/tkzmux.app (ad-hoc signed)
open build/tkzmux.app
SIGN_IDENTITY="Developer ID Application: …" make app   # real signing = one variable
make vendor                 # rebuild vendor/ghostty-vt (needs zig 0.16.x; lands in M1.1)
make clean                  # rm -rf .build build
```

`codesign -dv build/tkzmux.app` shows `Signature=adhoc` for a default build.

## Module map

| Target | Kind | Role |
|---|---|---|
| `TkzPtyShim` | C | fork/exec in the child, no Swift after `fork()` |
| `TkzShaderTypes` | C header | structs shared by Swift and Metal shaders |
| `GhosttyVt` | binary (M1.1) | `vendor/ghostty-vt/ghostty-vt.xcframework`, pinned commit |
| `TkzTerminalCore` | Swift | `Pty`, `TerminalEnvironment`, `TerminalSession` (VT bridge, IO loop, snapshots) |
| `TkzTerminalRender` | Swift | fonts, glyph atlas, `FrameBuilder`, Metal renderer |
| `TkzTerminalView` | Swift | `TerminalMetalView`, keyboard/IME, mouse/selection |
| `TkzCore` | Swift | models, `AppStore`/`ChangeSet`, status derivation, theme tokens — no AppKit |
| `ClaudeBridge` | Swift | session watcher, hook server, shim installer, usage reader |
| `GitStatus` | Swift | git status service, FSEvents, PR lookup, port scanner |
| `Persistence` | Swift | `state.json`, snapshots |
| `TkzApp` | Swift | `AppDelegate`, window, sidebar, status bar, palette, `TerminalHost` |
| `tkzmux` | exe | the app |
| `tkzmux-vtdump` | exe | headless record/replay/render/abi tooling |
| `tkzmux-hook` | exe | Claude Code hook relay; `import Darwin` only, < 20 ms |

Tests: one target per Swift library module under `Tests/<Module>Tests`, using Swift Testing (`import Testing`, `@Test`, `#expect`).

## Rules

- **One Linear ticket = one Claude Code session in a worktree** (`claude -w <name>` from the main checkout). Start from the ticket, finish with its acceptance criteria green, then close it.
- Swift 6 strict concurrency stays on (tools-version 6.2 default). Do not add `-strict-concurrency=minimal` or `@unchecked Sendable` to make warnings go away.
- No SwiftUI on hot paths; no `@Observable` for the store (explicit change sets).
- No third-party dependencies beyond libghostty-vt. No Sparkle, Sentry, telemetry.
- **Never copy code from cmux** (GPL-3). Ghostty (MIT) may be read for reference; libghostty-vt is used only through its public C API from the files listed in `docs/design.md` → *Spike checklist*.
- No personal names or account labels in code; they come from config.
- Keep `tkzmux-hook` free of Foundation.
- When a spike (M1.1–M1.3) settles an open question, write the result back into `docs/design.md`.
