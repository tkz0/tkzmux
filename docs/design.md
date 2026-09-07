# tkzmux — design

> Living document. Started as the approved planning document (2026-09-07); the design sections were moved here in M0.1 (TKZ-5). Spike results from M1.1–M1.3 are written back into the relevant sections. Tickets live in Linear (see *Roadmap*) and point at sections of this file.

## Executive summary

- **What**: a personal cmux replacement. Sidebar of Claude Code sessions grouped by repo, one terminal per session, app-level git/Claude status bar, Thomas' own design (Claude Design project `452d6955…`, theme *2c Midnight indigo*).
- **Stack**: Swift 6.2, AppKit-first, own Metal renderer, **libghostty-vt** (Ghostty's headless VT core, MIT) as the *only* third-party dependency, vendored as a prebuilt xcframework so daily builds are plain `swift build`. No SwiftUI on hot paths, no Sparkle/Sentry/telemetry.
- **Why this split**: the VT state machine is where decades of correctness live (Claude Code alone needs DEC 2026, kitty keyboard, SGR mouse, OSC 8/52, alt screen). The renderer and surface lifecycle are where cmux's cost lives (2.47 GB, 167 threads, 7–9 % idle CPU for 31 panels). Reuse the former, own the latter.
- **Target**: macOS 26+, arm64 only. Replace cmux as daily driver within weeks; sharing with friends later needs no structural change (see *Sharing readiness*).
- **v1 scope**: one surface per session (no splits), two Claude accounts, session restore, plain groups, cmux keybindings.

## Context

Thomas runs 20 cmux workspaces / 31 panels with ~7 live Claude Code sessions across two subscriptions (`~/.claude` "Private", `~/.claude-alt` "Almi"). cmux (Swift + a 30-patch libghostty fork, GPL-3) is noisy, UX-opaque and heavy. He has a finished design: grouped session sidebar with colour-edged groups, "N working · N need you" strip, one Claude Code terminal per session, status bar (branch, WT badge, model badge, diff stats, ahead/behind, ports, context %, usage %). Motivation for owning the renderer: performance on an M4 Max (36 GB, 7680×2160, macOS 26.6, Xcode 26.1, Swift 6.2). Goal: daily driver within weeks; not (yet) public.

## Decisions (all confirmed with Thomas)

| Decision | Choice | Why |
|---|---|---|
| Language / UI | Swift 6.2, AppKit-first, Metal | Only zero-dependency native stack; Rust needs objc2/metal crates just to open a window. |
| Terminal | **libghostty-vt** headless core + **own** Metal renderer, NSView, pty, surface lifecycle | Reuse validated behaviour, own the architecture. Full libghostty embed = per-surface threads + fork pressure (cmux). From-scratch VT = debugging Unicode/reflow/IME inside live work. |
| Tooling | Pure SwiftPM + `make app` (metallib via `xcrun metal`, bundle, codesign). No .xcodeproj | CLI-driven, Claude-Code-friendly. |
| Deployment | **macOS 26+, arm64 only** | Thomas' pick; universal/older is a flag away if ever needed. |
| Theme | **2c Midnight indigo** default; 2a/2b/1a/1b as presets from the same token set | Thomas' pick. |
| Shortcuts | **cmux bindings** (from `~/.config/cmux/cmux.json`), workspace→session, tab→terminal: ⌘N new session (picker), ⌘P go to session (= design's "Search sessions…"), ⇧⌘P command palette, ⌘B sidebar, ⇧⌘R rename session, ⌘W close terminal / ⇧⌘W close session, ⌘1-9 select session, ⇧⌘U jump to needs-you, ⌘I notifications, ⌘, settings, ⌘O open folder, ⇧⌘, reload config; ⌘T/⌘D reserved. User-editable. | Muscle memory. |
| v1 scope | One surface/session, **two accounts**, **session restore**; groups are plain containers | Thomas' pick. Splits, browser pane, scheduled-session detection, telemetry: not v1. |
| Linear | Project + milestone per phase, area labels, one issue = one Claude Code session | Team **Tkzmux** `6421dba9-a6a5-4b6d-9e27-1671bb81dcd6`; statuses Backlog/Todo/In Progress/Done. |
| Repo | `git init ~/dev/tkzmux` + `gh repo create tkzmux --private` (gh = tkz0, repo scope) | Thomas' OK. |
| Identity to programs | `TERM=xterm-ghostty`, `TERM_PROGRAM=ghostty`, ship terminfo | Claude Code gates Shift+Enter (kitty) and sync output on a TERM_PROGRAM allow-list; we literally run Ghostty's VT. |
| Sharing readiness (cheap now) | `make app` takes `SIGN_IDENTITY` (default ad-hoc `-`); `LICENSE` (MIT) from day one; the per-session sidecar (`~/.claude/dash-sessions/<id>.json`) is a **tkzmux-owned contract** that the Claude Dash shim happens to write today, later a `tkzmux-statusline` wrapper; no personal names in code (account labels from config); zsh-only shell integration is a known gap | Friends/coworkers later without redesign. Distribution later = Homebrew cask + notarization. |

## Evidence (why the plan is not guesswork)

- **What runs in Thomas' terminals** (last 5000 zsh commands): git 762, claude 452, pnpm 155, dotnet 34, pico 38, more 32; no vim/htop/tmux. Terminal must be perfect for zsh + Claude Code.
- **Claude Code 2.1.263 emits** (binary strings): DEC 2026, alt screen 1049 (fullscreen mode), kitty keyboard `CSI > 1 u` / `CSI ? u`, SGR mouse 1000/1006, OSC 8, OSC 52, OSC 0 title, OSC 9 notifications, 24-bit + 256 colour, DECRQM, modifyOtherKeys, bracketed paste.
- **cmux now**: 2.47 GB, 167 threads (Ghostty = renderer + io + io-reader + io-gather per surface), 7–9 % CPU idle, 20 workspaces / 31 panels, 7 live Claude sessions. **This is the baseline M1.10 must beat.**
- **Claude Code publishes live session state**: `~/.claude/sessions/<pid>.json` and `~/.claude-alt/sessions/<pid>.json` = `{pid, sessionId, cwd, startedAt(ms), version, kind: interactive|bg, entrypoint, name, nameSource: auto|derived, status: idle|busy, updatedAt, statusUpdatedAt, messagingSocketPath, bridgeSessionId, parkedJobId?, jobId?}` + sibling `<pid>.<sha>.key` (never read). Rewritten **in place** (same inode). `~/.claude-alt/projects` → symlink to `~/.claude/projects`; `sessions/` dirs are separate.
- **Quota**: only via statusline stdin. Thomas' Claude Dash shim (`~/dev/mac-dash/scripts/statusline-capture.js`, installed copy `~/.claude/dash-statusline-capture.js`, overwritten by `npm run install:app`) writes `~/.claude/dash-usage-<account>.json`; reconcile rules in `~/dev/mac-dash/CLAUDE.md` + `src/data/parsers/quota-parser.ts`. Statusline payload also carries `session_id, session_name, model.display_name, workspace.git_worktree, context_window.used_percentage, pr.*`.
- **Hooks** (code.claude.com/docs/en/hooks): `Notification.notification_type` ∈ permission_prompt | idle_prompt (60 s idle) | elicitation_dialog | agent_needs_input…; `Stop.last_assistant_message`; `SessionStart.source`; `SessionEnd.reason`; hooks from `--settings` **merge** with user hooks; hooks inherit env.
- **CLI**: `-w/--worktree [name]` → `<repo>/.claude/worktrees/<name>` (must run from main checkout); `-r/--resume <id|name>`; `--settings <file|json>`; `--session-id` unused by us (sessionId rotates on /clear, resume, fork).
- **Shell env on this machine**: `/etc/zprofile` `path_helper`, `.zprofile` `brew shellenv`, `.zshrc` ends by sourcing `~/.local/bin/env` (prepends `~/.local/bin`) → a PATH prepend from the pty parent loses; hence the ZDOTDIR wrapper. `~/.local/bin/claude` → `~/.local/share/claude/versions/2.1.263`; a second `claude` in `/opt/homebrew/bin`.
- **Toolchain**: `brew` zig **0.16.0** installed (M0.2 / TKZ-6; = Ghostty main minimum); Xcode 26.1 + `xcrun metal` present; `xterm-ghostty` terminfo already system-wide (cmux ships `Resources/terminfo/78/xterm-ghostty`); **JetBrains Mono 2.304** installed via cask `font-jetbrains-mono`, `CTFontCreateWithName("JetBrainsMono-Regular")` resolves (verified M0.2); Menlo fallback stays the rule for machines without it; gh logged in as tkz0.
- **libghostty-vt** (Ghostty `main` 1.3.2-dev; latest tag 1.3.1): full headless terminal (`terminal.h`), render-state API (`render.h`: tri-state dirty, `row_iterator_next_dirty`, per-cell style/graphemes/fg/bg/selected), key + mouse encoders, selection gestures, formatter, `snapshot.h`, `ghostty_type_json()` ABI manifest. API explicitly unstable → **pin a commit**, diff the manifest on upgrade. Official `example/swift-vt-xcframework` does `import GhosttyVt`.
- **Design source**: file `Terminal Main Window.dc.html` (5 artboards, JetBrains Mono, SF system UI). Intent from the design chat: auto-group by repo + worktree parent, colour = group, collapsible, status dot + summary strip + pulse, titles from Claude's own name, palette (also transcript search later), presets per repo with startup command, keyboard-first, native vibrancy.

---

## Terminal engine (TkzTerminalCore / TkzTerminalRender / TkzTerminalView)

### Packaging (chosen: xcframework → `.binaryTarget`)
- `scripts/build-ghostty-vt.sh` (needs `zig` 0.16.x, `xcodebuild`): clone/fetch pinned `GHOSTTY_COMMIT`, `zig build -Demit-lib-vt -Dxcframework-target=native -Doptimize=ReleaseFast -Demit-terminfo=true` → copy `zig-out/lib/ghostty-vt.xcframework` to `vendor/ghostty-vt/`, `zig-out/share/terminfo/{78,67}` to `Resources/terminfo/`, Ghostty `LICENSE`, write `COMMIT`, dump `ghostty_type_json()` to `abi-types.json` (via `tkzmux-vtdump abi`). Network only at vendoring time.
- `Package.swift`: `platforms: [.macOS("26.0")]`; targets `GhosttyVt` (binary), `TkzPtyShim` (C), `TkzShaderTypes` (C header-only, shared Swift/Metal structs), `TkzTerminalCore`, `TkzTerminalRender`, `TkzTerminalView`, `tkzmux` (exe), `tkzmux-vtdump` (exe), tests. If link fails on `std::__1` symbols (SIMD build has C++), add `.linkedLibrary("c++")`.
- `make app`: `xcrun -sdk macosx metal -c Shaders/Terminal.metal -I Sources/TkzShaderTypes/include -o build/Terminal.air && xcrun metallib … -o tkzmux.app/Contents/Resources/default.metallib`; `swift build -c release`; copy binary, `Resources/terminfo`, `Info.plist`, SwiftPM resource bundles; `codesign --force --sign "$SIGN_IDENTITY"` (default `-`). `swift run`/tests fall back to `device.makeLibrary(source:)` from the `.metal` resource.

### Pty (`TkzPtyShim` C + `Pty.swift`)
- C only in the forked child (no Swift runtime after fork): `openpty(&m,&s,NULL,NULL,&ws)` → `fork()` → child `setsid()`, `ioctl(s, TIOCSCTTY, 0)`, `dup2`, reset signal mask/handlers, `chdir(cwd)`, `execve(path, argv, envp)`; exec failure reported via a `FD_CLOEXEC` pipe. Parent: `O_NONBLOCK|FD_CLOEXEC` on master. (Ghostty's own approach; posix_spawn can't do tty setup.)
- Spawn **zsh directly**: `path=/bin/zsh`, `argv=["-zsh","-l"]` (login semantics without `/usr/bin/login`, so env survives). Env from `TerminalEnvironment.make(sessionID:accountConfigDir:)`: `TERM=xterm-ghostty`, `TERM_PROGRAM=ghostty`, `TERM_PROGRAM_VERSION`, `COLORTERM=truecolor`, `TERMINFO=<bundle>/terminfo`, `LANG`, `ZDOTDIR=<tkzmux>/zsh`, `TKZMUX_ZDOTDIR`, `TKZMUX_USER_ZDOTDIR=$HOME`, `TKZMUX_BIN=<tkzmux>/bin`, `TKZMUX_SOCKET`, `TKZMUX_SESSION_ID`, `CLAUDE_CONFIG_DIR` (non-primary accounts only); remove `TERM_SESSION_ID`, `TERMINFO_DIRS`. **No PATH prepend** — the ZDOTDIR wrapper does it last (see Claude section).
- `Pty`: read via `DispatchSource.makeReadSource(masterFD, queue: ioQueue)` draining ≤4×64 KiB per wakeup (`EIO` = EOF); writes only on `ioQueue`, `EAGAIN` → pending buffer + write source; `resize(TerminalSize{rows, cols, cellWidthPx, cellHeightPx})` → `TIOCSWINSZ` after `ghostty_terminal_resize`; exit via `DispatchSource.makeProcessSource(pid, .exit)` (kqueue) + `waitpid`; `foregroundProcess()` = `tcgetpgrp` + `proc_pidpath` + `PROC_PIDVNODEPATHINFO` cwd (no shell integration needed).

### VT bridge (`TerminalSession`)
- `ghostty_terminal_new(nil, &t, cols, rows)`; options via `ghostty_terminal_set`: `USERDATA`, `WRITE_PTY` (append to IO-thread-owned `pendingPtyOutput` — callbacks run synchronously inside `vt_write` and must not re-enter), `BELL`, `TITLE_CHANGED`, `PWD_CHANGED`, `CLIPBOARD_WRITE` (OSC 52 → NSPasteboard, reply SUCCESS; non-standard → UNSUPPORTED), `CLIPBOARD_READ` (DENIED), `DESKTOP_NOTIFICATION` (OSC 9/777/99 → sidebar badge + UNUserNotification when not visible), `PROGRESS_REPORT` (OSC 9;4), `COLOR_SCHEME` (DARK), `SIZE`, `XTVERSION` (`tkzmux <ver>`), `TERMINFO_NAME` (`xterm-ghostty`), `COLOR_FOREGROUND/BACKGROUND/CURSOR/PALETTE` (from theme; base 16 from theme, rest `ghostty_color_palette_default`), `SCROLLBACK_MAX_BYTES` (24 MiB; NULL = unlimited), cursor style block/blink, `KITTY_IMAGE_STORAGE_LIMIT` small, `TITLE_REPORT` false.
- **Threading**: per session a serial `ioQueue` (`.userInteractive`) + `OSAllocatedUnfairLock` guarding the terminal and encoders. IO thread: `lock { ghostty_terminal_vt_write }` → flush pending pty output → publish events (`AsyncStream<TerminalEvent>` consumed on main) → `renderSignal` (`DispatchSourceUserDataOr` on main). Main: only marks `needsUpdate` and un-pauses the display link **if this session is visible**. Render tick: `lock { begin_update; end_update; iterate dirty rows into CPU row caches }`, GPU encode unlocked. Input: `lock { encoder setopt_from_terminal; encode }` → pty. Background sessions: IO loop only, no render state, no display link, optional `ghostty_terminal_compress(INCREMENTAL)` from an idle timer (under the lock).
- **DEC 2026**: libghostty-vt does **not** hide unsynchronized frames; Ghostty's renderer skips frames while mode 2026 is set and its IO thread resets it after 1 s. tkzmux: `ghostty_terminal_get(DATA_MODE, {mode: ghostty_mode_new(2026,false)})` per tick; active < 1 s → skip `begin_update`, keep link running; ≥ 1 s → force the mode off and render.
- **Snapshot**: `ghostty_snapshot_encode_alloc` under lock → `~/Library/Application Support/tkzmux/sessions/<id>.ghsnap` (lower `SCROLLBACK_MAX_BYTES` first to bound size); restore `ghostty_snapshot_decoder_new_buf` → `decoder_ready(&terminal)` (new terminal, renderable immediately) → re-apply options → decode history pages → spawn a fresh shell (old content + new prompt).

### Metal renderer (`TkzTerminalRender`)
- `FontSet` (CoreText only): JetBrains Mono → Menlo fallback; `CTFontCreateForString` per-scalar fallback cache; colour fonts via `kCTFontTraitColorGlyphs`. `CellMetrics` = max ASCII advance × round(ascent+descent+leading), underline/strike from CTFont, integer device px, rebuilt on backing-scale change.
- `GlyphRasterizer`: `CGBitmapContext` (8-bit alpha for grayscale, BGRA premultiplied for colour), `CTFontDrawGlyphs`, synthetic bold via fillStroke; wide graphemes get the 2-cell box. `GraphemeShaper`: single scalar → `CTFontGetGlyphsForCharacters`; multi-scalar (ZWJ, VS16, combining) → `CTLine`/`CTRun`, cached. **No ligatures in v1.**
- `GlyphAtlas`: `r8Unorm` 2048² + `bgra8Unorm` 1024²→2048², shelf packer, batched `replace(region:)`, shared across sessions.
- `TerminalSurface` (only for the **visible** session): `ghostty_render_state_new`, row iterator, per-row caches of `TkzGlyphInstance`/`TkzRectInstance` + bg cell grid. Per tick: `begin_update/end_update`, `get(DIRTY)` (FULL → re-read COLS/ROWS/COLORS/CURSOR), `row_iterator_next_dirty` → `row_get(SELECTION)`, `row_cells_get_multi(RAW, STYLE, GRAPHEMES_LEN/BUF, FG_COLOR, BG_COLOR, SELECTED, HAS_STYLING)`, `ghostty_cell_get(WIDE / HAS_HYPERLINK)`; `BG_COLOR` returns `GHOSTTY_INVALID_VALUE` when unset → theme bg; bold-bright is app-side (verified not applied by the lib); then `render_state_clean`. Cursor/selection/hover-link are overlays, not baked into rows.
- Shaders (`TkzShaderTypes.h` shared structs `TkzUniforms`, `TkzBgCell`, `TkzGlyphInstance`, `TkzRectInstance`): bg full-screen pass sampling the cell grid; instanced rects (fill/hollow/underline single·double·curly·dotted·dashed/strike, procedural); instanced glyphs (gray = `rgb, a*tex.r`; colour = premultiplied). Order: bg → rects-below (block cursor, selection) → glyphs → rects-above. `.bgra8Unorm`, opaque layer, sRGB, 3-deep shared `MTLBuffer` ring + semaphore. **Dirty FALSE + no overlay change → no drawable acquired** (idle = zero GPU work).

### View & input (`TkzTerminalView`)
- `TerminalMetalView: NSView, NSTextInputClient`; `makeBackingLayer → CAMetalLayer` (`displaySyncEnabled`, `maximumDrawableCount = 2`, `framebufferOnly`); `NSView.displayLink(target:selector:)` paused unless `needsUpdate` / blink / drag / 2026 deadline; `preferredFrameRateRange` 60…120; occlusion pauses; `presentsWithTransaction` only during live resize (commit → `waitUntilScheduled` → `present`). `show(session)` detaches the previous `TerminalSurface` and attaches a new one (FULL rebuild); one `TerminalRenderer` (pipelines, atlases, buffers) app-wide.
- **Keyboard**: IME first (`inputContext.handleEvent`; marked text = preedit overlay), then one `GhosttyKeyEvent` (action, physical key via the macOS keycode table from Ghostty's `keycodes.zig`, mods incl. side bits, utf8 filtered of control/PUA, unshifted codepoint, consumed mods, composing) → `lock { ghostty_key_encoder_setopt_from_terminal; re-set MACOS_OPTION_AS_ALT (setopt_from_terminal resets it); encode }` → pty. `keyUp` → RELEASE, `flagsChanged` → modifier press/release, `performKeyEquivalent` lets ⌘-shortcuts through to the app, `doCommand(by:)` no-op. Non-keyDown text (emoji picker, dictation) → `ghostty_terminal_paste(source: TEXT)`.
- **Mouse**: tracking area; if `DATA_MOUSE_TRACKING` and no Shift → `GhosttyMouseEvent` → `ghostty_mouse_encoder_encode` (options synced via `setopt_from_terminal`, size via `OPT_SIZE`); else selection via `GhosttySelectionGesture` (PRESS/DRAG/RELEASE, CELL/WORD/LINE behaviours, Option = rectangle, autoscroll ticks) → `ghostty_terminal_set(OPT_SELECTION)`. Copy = `ghostty_terminal_selection_format_alloc` (PLAIN, unwrap, trim). Wheel: tracking on → buttons 4/5 (verify bytes); off → `ghostty_terminal_scroll_viewport(DELTA)`. Paste = `ghostty_terminal_paste` (bracketed + chunking inside the lib) after `ghostty_paste_is_safe` (confirm sheet if unsafe). OSC 8: hover with ⌘ → `ghostty_terminal_grid_ref` + `ghostty_grid_ref_hyperlink_uri` → pointing-hand + underline overlay, ⌘-click opens. Focus in/out → `ghostty_focus_encode` when mode 1004; hollow cursor when unfocused.

### TerminalHost — the seam between halves (protocol in `TkzApp`)
```swift
protocol TerminalHost: AnyObject {
  func open(_ id: SessionID, cwd: String, env: [String: String], size: TerminalSize) throws -> pid_t   // shell pid
  func run(_ id: SessionID, command: String)          // types command + "\r"
  func show(_ id: SessionID?)                          // attach the single renderer; nil = none
  func resize(_ id: SessionID, _ size: TerminalSize)
  func close(_ id: SessionID, signal: Int32)           // SIGHUP default; row stays resumable
  func snapshot(_ id: SessionID) throws -> Data        // .ghsnap
  func restore(_ id: SessionID, from: Data, cwd: String, env: [String: String]) throws -> pid_t
  var events: AsyncStream<(SessionID, TerminalEvent)> { get }
    // .title(String) .pwd(String) .bell .notification(title, body) .progress(state, value) .exited(ExitStatus) .foreground(pgid, path?, cwd?)
}
```

### Spike checklist (M1.1–M1.3; these confirm the architecture)
Build & link (c++?), render-state iteration needs the lock?, 2026 dirty semantics + `DECRQM 2026` reply, `FG_COLOR` inverse handling, cursor/selection dirtiness, WIDE/SPACER_TAIL on CJK/emoji, hyperlink ref cost while scrolled, kitty flags after `CSI > 1 u` + Shift+Enter → `CSI 13;2u` + `CSI ? u` reply, wheel button 4/5 bytes, `GhosttyMimeReader` contract, pty job control (`tty`, Ctrl-C to fg pgrp, `EIO` at exit), default scrollback + RSS per idle session (24 MiB cap, after `compress(FULL)`), snapshot size/restore time, display-link pause behaviour + `presentsWithTransaction` path + `Bundle.module` inside a hand-built .app, Menlo/emoji/CJK fallback, kitty-graphics storage limit, ABI-manifest diff procedure. All C calls confined to `GhosttyVt+Swift.swift`, `KeyEncoder.swift`, `MouseEncoder.swift`, `SelectionController.swift`, `FrameBuilder.swift`.

### Testing without UI
`tkzmux-vtdump record --cols 120 --rows 40 --out claude-boot.tkzrec -- claude` (tees raw pty bytes + timestamps under the tkzmux env so TERM_PROGRAM gating is real); `replay --format plain|vt|html` via `ghostty_formatter_format_alloc`; `--modes` prints 1049/2004/1000/1006/2026/25/1004 + kitty flags; `render --png` offscreen; `abi`; `version`. Fixtures: `zsh-ls-color`, `claude-boot`, `claude-tool-run`, `vttest-menu1` with golden screens; encoder tests (Shift+Enter with/without kitty, Option+B, SGR press); pty tests (`stty size`, `tty`, exit code, resize, no zombies); render-state tests (styles, wide, hyperlink, dirty semantics); render tests (metrics, fallback, atlas regrow, PNG hash). Dev-time conformance: `brew install vttest` menus 1/2/3/6/11 and esctest subsets, results in `docs/conformance.md`.

---

## App architecture (TkzCore / TkzApp)

```
Package.swift · Makefile · LICENSE (MIT) · CLAUDE.md · docs/design.md (this document) · docs/conformance.md
scripts/  build-ghostty-vt.sh · make-app.sh · record-vt.sh
vendor/ghostty-vt/  COMMIT · LICENSE · abi-types.json · ghostty-vt.xcframework/
Resources/  Info.plist · terminfo/ · shim/claude.sh · zsh/{.zshenv,.zprofile,.zshrc,.zlogin} · Shaders/Terminal.metal
Sources/
  TkzPtyShim (C) · TkzShaderTypes (C)
  TkzTerminalCore · TkzTerminalRender · TkzTerminalView          (see Terminal engine)
  TkzCore        models + pure reducers: Group, Session, SessionStatus, Account, GitSummary, UsageSnapshot,
                 ClaudeSessionInfo, Preset, HookEvent; AppState/AppStore/ChangeSet; StatusDerivation; Theme tokens
  ClaudeBridge   ClaudeSessionWatcher · HookServer · ShimInstaller · SettingsMerge · UsageReader · SessionSidecarReader
  GitStatus      GitStatusService · RepoInfo · FSEventsWatcher · PRLookup · PortScanner (libproc)
  Persistence    StateFile (state.json v1, atomic, .bak, migrations) · Snapshots
  TkzApp         AppDelegate · MainWindowController · Sidebar/ · StatusBar/ · Palette/ · Toolbar/ · TerminalHost (impl over TkzTerminalView)
  tkzmux (exe) · tkzmux-vtdump (exe) · tkzmux-hook (exe, `import Darwin` only)
Tests/  TkzCoreTests · TkzTerminalCoreTests · TkzTerminalRenderTests · ClaudeBridgeTests · GitStatusTests · PersistenceTests
```

- **Store**: `AppStore` (`@MainActor`) owns `AppState` (groups, sessions, accounts, usage, selection, sidebarVisible, windowFrame, presets, shortcuts). `store.update { … }` diffs into `ChangeSet {sessions, groups, structure, selection, usage}` delivered once per run-loop turn. Services run on their own queues/actors and post into the store; they never touch views. No `@Observable` (row-granular reloads need explicit change sets).
- **Sidebar** = view-based `NSOutlineView`, fixed heights (group 28 pt, session 44 pt), items keyed by IDs; per-row `reloadData(forRowIndexes:)`, structural `insert/remove/moveItem`. Group header: uppercase name, 2–3 pt colour edge (`CALayer`), chevron, ＋. Row: status dot, title, `⎇ branch` + `WT` (JetBrains Mono 10 pt), `NEEDS YOU` amber badge, account chip. **Pulse** = one `CABasicAnimation` on a layer (GPU-side, zero app CPU), only on visible `working` rows, paused when occluded. Summary strip “5 working · 2 need you”.
- **Status bar**: `⎇ branch` · `WT` · model badge · `+142 −38 · 12 files` · `↑0 ↓2` · ports · `Context 62%` · `Usage 5% · resets 4d 12h`; re-renders only when the selected session's ChangeSet intersects.
- **Toolbar**: title “<session> — <group>”; `NSMenuToolbarItem` “＋ New session…” scoped to the selected group (*New worktree (claude -w)*, *In repo root (claude)*, *In another repo…*, *From preset… (n saved)*, Account submenu); “Search sessions…” (⌘P); the four right-hand buttons from the design (`>_` new terminal, `◍` browser, `◫`/`⬓` splits — last three disabled in v1).
- **Palette** (⇧⌘P; `NSPanel` + `NSVisualEffectView`): fuzzy over sessions (title, branch, cwd, group), groups, commands, presets.
- **Theme** (`TkzCore/Theme.swift`, M0.2 / TKZ-6): one `struct Theme` with the tokens below; the five artboards are `static let` presets of the same struct (`Theme.default = .midnightIndigo`, `Theme.allPresets`). `RGB` (`TkzCore/RGB.swift`) is sRGB + straight alpha with `hexString`, `mixed(with:amount:)`, `over(_:)`, WCAG `relativeLuminance` / `contrastRatio(against:)`. No AppKit in TkzCore: NSColor conversion belongs to the consumer. `terminalForeground` is one token beyond the ticket's list because every artboard draws terminal text dimmer than UI titles and libghostty's `COLOR_FOREGROUND` needs the terminal one. Fonts are the same in every preset: UI = system font 12.5 (title) / 11 (body) / 10.5 (caption) pt; mono = JetBrains Mono (`JetBrainsMono-Regular`, fallback Menlo) 12.5 (terminal) / 10 (sidebar branch line) / 10.5 (status bar) pt. Extraction rules per token are in the source comments; the table below is generated by `ThemeTests.printsDesignTable` (`swift test --filter ThemeTests/printsDesignTable`) — regenerate it after any token change.

  **Terminal palette rule** (ANSI 0–15; 16–255 = `ghostty_color_palette_default`): mapped by artboard *swatch*, not by token (2b's accent is coral). 1 red = diffRemove, 2 green = working, 3 yellow = waiting, 4 blue = the "● Update(…)" tool dot, 5 magenta = the "● Bash(…)" dot, 6 cyan = the teal of the plan-mode line / group edge. Dark presets: 0 = statusBarBackground, 7 = terminalForeground, 8 = foregroundDim, 15 = foreground, bright 9–14 = base mixed 25 % toward white. Light: 0 = foreground, 7 = foregroundMuted, 8 = foregroundDim, 15 = terminalForeground, bright 9–14 = base mixed 15 % toward black (never toward the white background). The Claude orange has no ANSI slot. Contrast (tested, all five presets): foreground and terminalForeground ≥ 7:1 on terminalBackground, foregroundMuted ≥ 4.5:1, chromatic slots ≥ 3:1 (dark) / ≥ 2.5:1 (light — yellow on white is 2.7:1).

  | Token | 2c Midnight indigo (default) | 2a Graphite | 2b Warm charcoal | 1a Dark | 1b Light |
  |---|---|---|---|---|---|
  | windowBackground | #141624 | #141519 | #191512 | #1b1d21 | #f5f5f7 |
  | titlebar | rgba(31,34,54,.95) | rgba(30,32,37,.95) | rgba(40,33,28,.95) | rgba(38,40,45,.92) | rgba(246,246,248,.95) |
  | sidebarBackground | #1a1d31 | #1b1d22 | #201b17 | rgba(32,34,38,.96) | rgba(236,238,241,.96) |
  | terminalBackground | #0e101c | #0f1013 | #141110 | #17181b | #ffffff |
  | statusBarBackground | #1e2136 | #191b20 | #241e19 | #1f2125 | #eff0f3 |
  | foreground | #edf0fd | #f5f7fa | #f4eee7 | #f4f6f9 | #26292e |
  | terminalForeground | #e2e6f8 | #e3e8f0 | #e9e2da | #dde1e8 | #3a3e45 |
  | foregroundMuted | #98a0c2 | #98a2b3 | #a1968a | #8b93a0 | #6a7280 |
  | foregroundDim | #8890b4 | #8791a0 | #93887c | #8b93a0 | #9ba1aa |
  | accent | #8b93f8 | #5b8def | #e28666 | #4d7fd6 | #4d7fd6 |
  | accentText | #14162a | #ffffff | #2a1c14 | #ffffff | #ffffff |
  | selection | rgba(139,147,248,.22) | rgba(91,141,239,.24) | rgba(226,134,102,.22) | rgba(77,127,214,.20) | rgba(77,127,214,.14) |
  | working | #4ade80 | #3ddc74 | #4cc97e | #34b060 | #2c9e53 |
  | waiting | #fbbf54 | #ffb454 | #ffb454 | #f0a03a | #dd8a1e |
  | idle | rgba(255,255,255,.30) | rgba(255,255,255,.30) | rgba(255,255,255,.30) | rgba(255,255,255,.25) | rgba(0,0,0,.22) |
  | needsYouText | #fbbf54 | #ffb454 | #ffb454 | #f0a03a | #b06e10 |
  | needsYouBackground | rgba(251,191,84,.16) | rgba(255,180,84,.16) | rgba(255,180,84,.16) | rgba(240,160,58,.14) | rgba(221,138,30,.14) |
  | wtText | #c3c8fd | #b9cdf5 | #f0b39c | #8fb0e8 | #3a66b5 |
  | wtBackground | rgba(139,147,248,.20) | rgba(91,141,239,.22) | rgba(226,134,102,.20) | rgba(77,127,214,.16) | rgba(77,127,214,.13) |
  | groupEdgeDefault | #41c6a8 | #3fbf9f | #3fbf9f | #3fa08c | #2c8a74 |
  | diffAdd | #4ade80 | #3ddc74 | #4cc97e | #34b060 | #2c9e53 |
  | diffRemove | #f28b8b | #f07a7a | #e87f7f | #d16a6a | #c04a4a |
  | border | rgba(255,255,255,.08) | rgba(255,255,255,.08) | rgba(255,255,255,.08) | rgba(255,255,255,.06) | rgba(0,0,0,.08) |
  | ansi 0 | #1e2136 | #191b20 | #241e19 | #1f2125 | #26292e |
  | ansi 1 | #f28b8b | #f07a7a | #e87f7f | #d16a6a | #c04a4a |
  | ansi 2 | #4ade80 | #3ddc74 | #4cc97e | #34b060 | #2c9e53 |
  | ansi 3 | #fbbf54 | #ffb454 | #ffb454 | #f0a03a | #dd8a1e |
  | ansi 4 | #8b93f8 | #5b8def | #7aa2e8 | #4d7fd6 | #3a66b5 |
  | ansi 5 | #c084fc | #a58bf0 | #b58fd9 | #9a6fc9 | #8352b8 |
  | ansi 6 | #41c6a8 | #3fbf9f | #3fbf9f | #3fa08c | #2c8a74 |
  | ansi 7 | #e2e6f8 | #e3e8f0 | #e9e2da | #dde1e8 | #6a7280 |
  | ansi 8 | #8890b4 | #8791a0 | #93887c | #8b93a0 | #9ba1aa |
  | ansi 9 | #f5a8a8 | #f49b9b | #ee9f9f | #dd8f8f | #a33f3f |
  | ansi 10 | #77e6a0 | #6ee597 | #79d79e | #67c488 | #258647 |
  | ansi 11 | #fccf7f | #ffc77f | #ffc77f | #f4b86b | #bc751a |
  | ansi 12 | #a8aefa | #84aaf3 | #9bb9ee | #7a9fe0 | #31579a |
  | ansi 13 | #d0a3fd | #bca8f4 | #c8abe3 | #b393d7 | #6f469c |
  | ansi 14 | #71d4be | #6fcfb7 | #6fcfb7 | #6fb8a9 | #257563 |
  | ansi 15 | #edf0fd | #f5f7fa | #f4eee7 | #f4f6f9 | #3a3e45 |

## Claude integration (ClaudeBridge)

- **Discovery**: watch `~/.claude/sessions` and `~/.claude-alt/sessions` with a directory `DispatchSource` (add/remove) **and** a per-file `DispatchSource` (`.write|.extend|.delete|.rename|.attrib`) since descriptors are rewritten in place; 100 ms debounce; torn JSON keeps the previous value; liveness 5 s `kill(pid,0)`; pid-reuse guard `proc_pidinfo(PROC_PIDTBSDINFO).pbi_start_tvsec` vs `startedAt`; show `kind=="interactive"`, attach `bg` to its parent via `parkedJobId==jobId`. Idle cost ≈ 40 syscalls / 5 s.
- **Identity**: the shim `exec`s the real `claude`, so the shim's `$$` **is** the descriptor pid; it sends a `launch` frame `{sid, pid, cwd, config_dir, argv}` first, so `pid → SessionID` is known before `<pid>.json` exists. Fallback: `proc_listchildpids` walk from the shell pid. `--session-id` not used; latest `sessionId` recorded for `--resume`.
- **Status derivation** (first match): not alive / SessionEnd(reason ∉ clear,resume) → `exited`; pending permission_prompt|elicitation → `waiting(.permission)`; agent_needs_input → `waiting(.agentInput)`; `parkedJobId` → `idle` (parked); descriptor `busy` → `working`; Stop newer than `attendedAt` and (idle_prompt or ≥60 s) → `waiting(.doneUnattended)` = NEEDS YOU; Stop <60 s → idle “done”; else `idle`. Pending clears on UserPromptSubmit/Stop/SessionEnd/elicitation_complete/descriptor busy newer than the notification. Degrades to descriptor-only without hooks.
- **Titles**: user rename → descriptor `name` when `nameSource != "derived"` → worktree name → `basename(cwd)`.
- **Shim install** at `~/Library/Application Support/tkzmux/{bin/claude, bin/tkzmux-hook, zsh/…, tkzmux.sock, state.json, sessions/, VERSION}`, idempotent, never touches `~/.claude/settings.json`. **ZDOTDIR wrapper** (the single mechanism; no PATH prepend from the pty): each wrapper sources the user's file with `ZDOTDIR` restored, `.zshrc` ends with `export PATH="$TKZMUX_BIN:$PATH"`, `.zlogin` restores `ZDOTDIR` for nested shells. zsh only.
- **Shim** (`bin/claude`, bash): find real `claude` skipping `$TKZMUX_BIN`; pass through for subcommands, `-p`, `--bare`, `--safe-mode`, `-v`, `-h`, or unset `TKZMUX_SESSION_ID`/`TKZMUX_SOCKET`; strip user `--settings`, deep-merge via `tkzmux-hook settings-merge` (hook arrays concatenated, user first; failure → exec untouched); `tkzmux-hook launch`; `exec real … --settings <merged>`. Injected hooks: SessionStart, SessionEnd (timeout 1), UserPromptSubmit, Stop, Notification (matcher `permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|elicitation_complete|elicitation_response|agent_needs_input`) → `"<bin>/tkzmux-hook <Event>"`.
- **`tkzmux-hook`** (< 20 ms, `import Darwin`): stdin → single line → `AF_UNIX` connect, 200 ms poll → one NDJSON frame `{"v":1,"type":"hook","event","sid","ppid","ts","payload"}` → exit 0 on every path, never writes stdout. App: POSIX listener + DispatchSource, 256 KiB frame cap, keeps 4 KiB of `last_assistant_message` for UI; attribution `sid` → `payload.session_id` → pid tree.
- **Usage**: `UsageReader` watches `~/.claude/dash-usage-*.json` (key = filename), overlay `dash-accounts.json`; reconcile ported verbatim from `quota-parser.ts` (dead-window guard, high-water keyed on `resets_at`, 10-min confirmation TTL, 14-day ghost) with the mac-dash scenarios as tests. Status bar shows `seven_day` for the selected session's account.
- **Per-session sidecar (tkzmux-owned contract)**: `~/.claude/dash-sessions/<session_id>.json` = `{updated_at, session_id, account_key, context_used_percentage, model{id,display_name}, session_name, workspace{git_worktree,project_dir,repo}, worktree?, pr{number,url,review_state}?, cost}`. Producer today: **edit the mac-dash source** `~/dev/mac-dash/scripts/statusline-capture.js` (add `writeSessionSidecar` after `writeSnapshot`, same throttle/tmp+rename/try-catch) and `npm run install:statusline` (the `~/.claude` copy is generated). Later: a `tkzmux-statusline` wrapper for other users. Join on `descriptor.sessionId`; ignore sidecars > 24 h; housekeeping deletes > 7 d.

## Git integration (GitStatus)

- Repo detection per cwd: `git -C <cwd> rev-parse --show-toplevel --git-dir --git-common-dir --abbrev-ref HEAD`; `repoRoot = parent(common-dir)`; `isWorktree = realpath(git-dir) != realpath(common-dir)`.
- Always `--no-optional-locks` / `GIT_OPTIONAL_LOCKS=0`: `status --porcelain=v2 --branch -z` (branch, upstream, `branch.ab`, changed/untracked) and `diff HEAD --shortstat` (~22 ms on CoreInvest). No auto-fetch (optional 10-min pref, off).
- Triggers: one `FSEventStream` per repoRoot (common-dir + session cwds; ignore `.git/objects`, `node_modules`), 300 ms debounce, ≤1/2 s in bursts; after each Stop hook; on selection if >10 s old. Per-repo serial queue; rows re-render only on `GitSummary` change.
- PR: sidecar `pr.*` first; `gh pr view --json number,state,url,isDraft,reviewDecision` only for github.com origins (CoreInvest = Azure DevOps → never), selected session only, throttled, failures cached 10 min.
- Ports via **libproc**: `proc_listchildpids` from the shell pid → `proc_pidinfo(PROC_PIDLISTFDS)` → `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` → `SOCKINFO_TCP && TSI_S_LISTEN` → `ntohs(insi_lport)`; selected session on selection, after Stop, 10 s timer. (lsof = 30–70 ms + fork; rejected.)

## Session flows & persistence

Start: create `Session` (persist) → `TerminalHost.open` → `run(command)` → shim `launch` binds pid → descriptor appears → SessionStart confirms `claudeSessionId`.
- **New worktree** (cwd = repoRoot, `claude -w [name]`, optional name sheet; descriptor cwd `<repo>/.claude/worktrees/<name>` sets `worktreePath`; `git worktree list --porcelain` on exit). **Repo root** (`claude`). **Another repo…** (palette: known repos, recents, `NSOpenPanel` → new Group). **Preset** `{name, command, cwdMode: repoRoot|worktree(name?)|fixed(path), accountKey?, env}`. Account submenu → `CLAUDE_CONFIG_DIR`.
- **Restore**: sidebar rebuilt from state.json with rows `exited`; terminal content from `.ghsnap`; “Resume” / “Resume all in group” / auto-resume pref → `claude --resume <claudeSessionId>` in `worktreePath ?? repoRoot ?? cwd` (worktree gone → repoRoot, WT badge cleared).
- **Close** (confirm if working/waiting; SIGHUP; row stays resumable) vs **Remove** (deletes from state; never touches the worktree). **Rename** sets `Session.title` only.
- `state.json` v1 `{schemaVersion, groups[], sessions[], presets[], selection, sidebar, windowFrame, shortcuts}`; 500 ms debounced atomic write + `.bak`; corrupt → `.bak` + notice.


---

## Roadmap

Milestones and tickets are tracked in Linear — project **tkzmux** (team Tkzmux): https://linear.app/tkzmux/project/tkzmux-4c5798217c26. The tickets are the source of truth for scope and acceptance; this document is the source of truth for the architecture.

- **M0 Foundation** — repo, SwiftPM skeleton, `make app`, this document; toolchain, fonts, theme tokens.
- **M1 Terminal surface** — vendor libghostty-vt, pty + environment, `TerminalSession` + vtdump, fonts/atlas, Metal renderer, `TerminalMetalView`, keyboard + IME, mouse/selection/clipboard, session semantics + bundle, multi-session lifecycle (must beat the cmux baseline).
- **M2 App shell & sidebar** — `TkzCore` models + `AppStore`, main window/toolbar/status-bar shell, sidebar outline view, new-session menu / ⌘P / ⇧⌘P palette / rename / groups.
- **M3 Claude integration** — `ClaudeSessionWatcher`, `tkzmux-hook` + `HookServer`, shim + ZDOTDIR wrappers + installer, status derivation, usage + per-session sidecar.
- **M4 Git & status bar** — `GitStatusService`, status-bar content + PR badge, `PortScanner`.
- **M5 Persistence & restore** — `StateFile` v1, restore flow / presets / close-remove semantics, Elsewhere group + housekeeping.
- **Later (sharing readiness)** — `tkzmux-statusline` wrapper, bash/fish integration, Developer ID + notarization + Homebrew cask, light theme + settings UI, splits.

Priority in Linear: **High** = daily-driver cut line (M0, M1, M2, M3.1–M3.4, M5.1–M5.2); **Medium** = after the cut; **Low** = Later.
