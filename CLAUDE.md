# tkzmux

Native macOS session manager for coding agents — Claude Code and Codex CLI (personal cmux replacement). Swift 6.2, AppKit-first, own Metal renderer, **libghostty-vt** as the only third-party dependency, vendored as a prebuilt xcframework. Pure SwiftPM, no `.xcodeproj`; the `.app` is assembled by `make app`. macOS 26+, arm64 only.

## Commands

```sh
swift build                 # debug build of everything
swift test                  # all test targets (Swift Testing)
scripts/test-memory-probe.sh        # per-target, watched: RSS cap + stall timeout, diagnoses before killing
scripts/test-memory-probe.sh ALL    # the unfiltered `swift test`, under the same watchdog
swift run tkzmux            # run the app outside a bundle (window still appears)
make app                    # release build → build/tkzmux.app (ad-hoc signed, version stamped from git describe)
open build/tkzmux.app
SIGN_IDENTITY="Developer ID Application: …" make app   # real signing = one variable (adds hardened runtime + timestamp)
VERSION=1.2.3 make app      # override the derived version
make notarize               # notarize + staple an already-built, really-signed app (network)
make dist                   # tag → signed+notarized zip + sha256 → gh release (see docs/release.md)
make vendor                 # rebuild vendor/ghostty-vt at vendor/ghostty-vt/COMMIT (zig 0.16.x, xcodebuild, tic; network)
make vendor-linux           # Linux x86_64: rebuild vendor/ghostty-vt/ghostty-vt-linux.artifactbundle at the same COMMIT (zig 0.16.x, swift; network)
make clean                  # rm -rf .build build
```

`codesign -dv build/tkzmux.app` shows `Signature=adhoc` for a default build.

## Module map

| Target | Kind | Role |
|---|---|---|
| `TkzPtyShim` | C | fork/exec in the child, no Swift after `fork()` |
| `TkzShaderTypes` | C header | structs shared by Swift and Metal shaders |
| `GhosttyVt` | binary | `vendor/ghostty-vt/ghostty-vt.xcframework` (arm64 static, committed), commit pinned in `vendor/ghostty-vt/COMMIT`, ABI snapshots per OS in `abi-types.aarch64-macos.json` / `abi-types.x86_64-linux-gnu.json` |
| `TkzTerminalCore` | Swift | `Pty`, `TerminalEnvironment`, `TerminalSession` (VT bridge, IO loop, snapshots) |
| `TkzTerminalRender` | Swift | fonts, glyph atlas, `FrameBuilder`, Metal renderer |
| `TkzTerminalView` | Swift | `TerminalMetalView`, keyboard/IME, mouse/selection |
| `TkzPlatform` | Swift | OS seam below the UI: `TkzLogger`/`TkzSignposter` (aliases of `os.Logger`/`OSSignposter` on macOS); the only `import os` lives in `Sources/TkzPlatform/Darwin/` |
| `TkzCore` | Swift | models, `AppStore`/`ChangeSet`, status derivation, theme tokens — no AppKit |
| `AgentBridge` | Swift | `AgentAdapter` seam, session watcher, hook server, shim installer, usage reader |
| `Sources/AgentBridge/Codex/` | (in `AgentBridge`) | `CodexAdapter`, `CodexHooksInstaller`, `CodexTranscriptReader`, `CodexHookMapper` — everything Codex-specific, behind the same seam |
| `GitStatus` | Swift | git status service, FSEvents, PR lookup, port scanner |
| `Persistence` | Swift | `state.json`, snapshots |
| `TkzApp` | Swift | `AppDelegate`, window, sidebar, status bar, palette, `TerminalHost` |
| `tkzmux` | exe | the app |
| `tkzmux-vtdump` | exe | headless record/replay/render/abi tooling |
| `tkzmux-hook` | exe | hook relay, shared by every agent's shim; `import Darwin` only, < 20 ms |

Tests: one target per Swift library module under `Tests/<Module>Tests`, using Swift Testing (`import Testing`, `@Test`, `#expect`).

## Rules

- **One Linear ticket = one Claude Code session in a worktree** (`claude -w <name>` from the main checkout). Start from the ticket, finish with its acceptance criteria green, then close it.
- Swift 6 strict concurrency stays on (tools-version 6.2 default). Do not add `-strict-concurrency=minimal` or `@unchecked Sendable` to make warnings go away.
- **A runaway `swift test` is billed to tkzmux, not to itself.** Anything started from a tkzmux pty shares tkzmux's process coalition, and macOS charges a coalition to its leader — so a test process eating 40 GB shows up as "tkzmux: 40 GB" in Activity Monitor and takes the machine down with it. One unfiltered `swift test` was enough on 2026-09-09. Use `scripts/test-memory-probe.sh` when a run looks suspicious, and see docs/perf.md → *Session process memory* before blaming the app for a memory figure.
- No SwiftUI on hot paths; no `@Observable` for the store (explicit change sets).
- No third-party dependencies beyond libghostty-vt. No Sparkle, Sentry, telemetry.
- **Never copy code from cmux or Kitty** (both GPL-3). Ghostty (MIT) may be read for reference; libghostty-vt is used only through its public C API, never forked or patched.
- No personal names or account labels in code; they come from config.
- Keep `tkzmux-hook` free of Foundation.

## Linux port

A Linux build is in progress (Linear WOR-299 to WOR-325): GTK4 is the platform shell only, and tkzmux draws every pixel with Vulkan and its own FreeType/HarfBuzz text. Read the charter before changing anything Linux-related.

- Tracked Linux docs live in `docs/linux/`; start at [docs/linux/README.md](docs/linux/README.md). `docs/perf.md` stays local-only; Linux budgets go in `docs/linux/perf-budgets.md`.
- [ADR-0001](docs/linux/adr-0001-charter.md) charter and dependency policy · [ADR-0002](docs/linux/adr-0002-platform-defaults.md) platform defaults · [ADR-0003](docs/linux/adr-0003-parity.md) parity · [ADR-0004](docs/linux/adr-0004-keys-input.md) keys and input · [ADR-0005](docs/linux/adr-0005-window-controls.md) window controls · [decisions.md](docs/linux/decisions.md) user decisions and open items.
- `docs/linux/linkage-policy.txt` is the only allow/deny list for linked libraries; check binaries with `scripts/linux/check-linkage.sh`, never with a copied list.
- The Mac app does not change for Linux: Mac goldens stay byte-identical, and Linux-only gaps are documented, not fixed on the Mac.
