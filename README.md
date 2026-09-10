# tkzmux

A native macOS session manager for [Claude Code](https://claude.com/claude-code). tkzmux gives every
Claude Code conversation its own real terminal in one window: a sidebar lists the sessions grouped by
repository, each row shows a status derived from Claude Code's own session descriptors and hooks —
*working*, *done*, or **NEEDS YOU** when a permission prompt or a finished-and-unattended answer is
waiting for you — and the terminal itself is a from-scratch Metal renderer driving
[libghostty-vt](https://github.com/ghostty-org/ghostty), Ghostty's headless VT core, which is the
project's only third-party dependency. Sessions survive a quit: the screen and scrollback are
snapshotted to disk, the arrangement is stored in a `state.json`, and a restored row reopens lazily
under a fresh shell — with `claude --resume` a keystroke away.

<!-- SCREENSHOT: a shot of the main window (sidebar + terminal) goes here. Not added yet. -->

## Status

A personal project, built for one person's workflow and to replace one specific tool. It is developed
in the open, but it is **not a supported product**: there is no roadmap you can rely on, no promise of
backwards compatibility, and no commitment to answer issues. Parts of the design are built and daily
driven; parts are stubs (see *Known gaps*). Use it if it helps you, fork it if it nearly does.

## Requirements

- macOS 26 (Tahoe) or later — `LSMinimumSystemVersion` is 26.0 and the code targets it.
- Apple Silicon. The vendored libghostty-vt xcframework is **arm64 only**; there is no Intel build.
- [Claude Code](https://claude.com/claude-code) installed and working in your shell.
- `zsh` as your login shell, for the shell integration (see *Known gaps*).
- Optional: the [GitHub CLI](https://cli.github.com) (`gh`), authenticated, for the PR badge. Without
  it everything else works and the badge stays empty.

## Install

```sh
brew tap tkz0/tap
brew trust --cask tkz0/tap/tkzmux
brew install --cask tkzmux
```

**Why the `brew trust` step?** Since Homebrew 6.0, a cask from a third-party tap is not loaded until
you trust it — casks are executable Ruby, not metadata, and Homebrew runs them with your privileges.
Only Homebrew's own taps are trusted by default, so this applies to every third-party tap, not just
this one. Skip it and `brew tap` fails with `Cannot tap tkz0/tap: invalid syntax in tap!`, which
looks like a broken cask and is really the trust refusal.

`--cask tkz0/tap/tkzmux` trusts exactly this one cask. `brew trust tkz0/tap` would trust the whole
tap including anything added to it later, which is a lot to grant a stranger's repo — see
[Tap Trust](https://docs.brew.sh/Tap-Trust).

The app is signed with a Developer ID and notarized by Apple, so it opens with no Gatekeeper prompt
and needs no `xattr` incantation. Verify it yourself:

```sh
spctl -a -vv /Applications/tkzmux.app   # accepted, source=Notarized Developer ID
```

## Build from source

```sh
git clone https://github.com/tkz0/tkzmux
cd tkzmux
make app            # release build, assembled and ad-hoc signed → build/tkzmux.app
open build/tkzmux.app
```

Everything else is plain SwiftPM — there is no `.xcodeproj`:

```sh
swift build         # debug build
swift test          # the full test suite (Swift Testing)
swift run tkzmux    # run outside a bundle; the window still appears
```

**Metal Toolchain caveat.** `make app` compiles `Resources/Shaders/*.metal` into a
`default.metallib` with `xcrun metal`. On Xcode 26 that compiler ships as a separately downloaded
component, so without it the shader step fails and `make app` stops before producing an app. Install
it once with:

```sh
xcodebuild -downloadComponent MetalToolchain
```

(`swift run tkzmux` does not need it: outside the bundle the renderer falls back to compiling the
shader source at launch, which only costs a slower start.)

Signing is one variable — `SIGN_IDENTITY="Developer ID Application: …" make app`. A default build is
ad-hoc signed, which `codesign -dv build/tkzmux.app` reports as `Signature=adhoc`.

## What it touches

This is the whole privacy story. Every claim below is a claim about the code in this repository;
the file that backs it is named so you can check it yourself.

**No telemetry, no analytics, no crash reporting, no update check.** tkzmux itself opens no network
sockets: there is no `URLSession`, no `Network.framework`, no `AF_INET` socket anywhere in
`Sources/`. The only socket it creates is an `AF_UNIX` one — a file in its own support directory,
used by the hook relay (`Sources/ClaudeBridge/HookServer.swift`, `Sources/tkzmux-hook/Socket.swift`).

It does, however, reach the network **indirectly, in one place**: the PR badge shells out to
`gh pr view` (`Sources/GitStatus/PRLookup.swift`), and `gh` talks to GitHub under your own
credentials. That call is gated — the origin's host is checked with `git remote get-url origin` and
cached per directory first, so `gh` is never invoked for a repo whose origin is not GitHub, not even
to fail. Apart from that and Claude Code's own traffic from the `claude` process in your terminal,
nothing leaves the machine.

**Processes it starts.** Your login shell, on a pty (`Sources/TkzPtyShim/TkzPtyShim.c`,
`Sources/TkzTerminalCore/Pty.swift`) — everything else *inside* a session is something you typed.
Plus these, in the background, on repos backing your sessions:

| Command | Why |
|---|---|
| `git status --porcelain=v2 --branch -z`, `git diff HEAD --shortstat` | branch, ahead/behind and diff counts (`GitStatusService.swift`) |
| `git worktree list --porcelain` | notice when a worktree behind a row is removed (`WorktreeList.swift`) |
| `git remote get-url origin` | decide whether the PR lookup may run at all (`PRLookup.swift`) |
| `gh pr view --json …` | the PR badge — **GitHub origins only** (`PRLookup.swift`) |

All of them run with `--no-optional-locks` / `GIT_OPTIONAL_LOCKS=0` so a background refresh cannot
contend with git commands you run yourself.

**Processes it inspects.** To show a dev server's port on a row, tkzmux walks the descendant
processes of a session and looks at their open file descriptors for listening TCP sockets
(`Sources/GitStatus/PortScanner.swift`, via `libproc`). It reads local kernel state about processes
you started — it opens no connection to those ports and sends nothing anywhere.

**What it reads.** `~/.claude` — and any sibling `~/.claude-*` directory that looks like a second
config dir — is read, never written:

- `<config dir>/sessions/<pid>.json`, the session descriptors Claude Code publishes, are read and
  watched for changes (`Sources/ClaudeBridge/ClaudeSessionWatcher.swift`). Only files whose basename
  is an integer pid are opened; the sibling `<pid>.<sha>.key` files are ignored.
- `settings.json`, `sessions/` and `.claude.json` are used **only as existence markers** when
  discovering accounts — `FileManager.fileExists`, never opened or parsed
  (`Sources/TkzApp/ClaudeIntegration.swift`, `discoverAccounts`). `.claude.json` is Claude Code's
  own configuration file; the one thing tkzmux ever reads out of it is `oauthAccount`, and only to
  put a name and plan on an account badge (`Sources/tkzmux-hook/StatuslineCommand.swift`). It is
  read only when the account's own sidecar carries no label yet, and never written.
- If you pass `claude --settings <file-or-json>`, the shim reads that document in order to merge
  tkzmux's hooks into it (`Sources/tkzmux-hook/SettingsMerge.swift`).

**What it writes.** Everything lives under `~/Library/Application Support/tkzmux`:

- `state.json` (+ `.bak`) — groups, sessions, presets, window frame, shortcuts, preferences.
  Process state (pids, descriptors, statuses, last messages) is deliberately **not** persisted:
  `Session.live` is cleared on the way to disk *and* in memory before comparison
  (`Sources/Persistence/PersistedState.swift`, `StateFile.swift`).
- `sessions/<id>.ghsnap` — terminal snapshots, taken at quit and every 5 minutes
  (`Sources/Persistence/Snapshots.swift`). **These contain your terminal's screen and scrollback
  verbatim, unencrypted.** Anything printed in a tkzmux terminal — including whatever Claude Code
  prints — can end up in one of these files. They are deleted with the session.
- `bin/claude`, `bin/tkzmux-hook`, `zsh/.{zshenv,zprofile,zshrc,zlogin}`, `VERSION` — the shell
  integration (`Sources/ClaudeBridge/ShimInstaller.swift`).
- `statusline/usage-<account>.json`, `statusline/context-<session id>.json` — what the status line
  command captures: quota percentages and reset times, and per session the context percentage,
  model name, session name, working directory, repo and open PR
  (`Sources/tkzmux-hook/StatuslineCommand.swift`). Written only while the status line is installed.
- `statusline/previous-<account>.json` — the `statusLine` you had before, kept so it can be restored.
- `tkzmux.sock` — the local hook socket.

**Shell integration and hooks.** Terminals tkzmux opens run with `ZDOTDIR` pointed at its own `zsh/`
directory. Those wrappers source your real rc files and then put tkzmux's `bin/` first on `PATH`, so
inside a tkzmux terminal `claude` resolves to a small bash shim
(`Sources/ClaudeBridge/Resources/shim/claude.sh`). The shim `exec`s the real `claude` with a
`--settings` document that adds tkzmux's own hooks (SessionStart, SessionEnd, UserPromptSubmit, Stop,
and a Notification matcher) pointing at `tkzmux-hook`. It **never edits `~/.claude/settings.json`**,
and it passes straight through for `-p`, `--bare`, subcommands and anything else it does not
recognise. The wrappers also point `HISTFILE` back at your own `~/.zsh_history` so tkzmux shells
share your history rather than starting a private one
(`Sources/ClaudeBridge/Resources/zsh/zshrc`). *Remove Shell Integration* in the app menu deletes
`bin/` and `zsh/` again.

**The status line — the one file tkzmux writes outside its own directory.** Claude Code hands rate
limits and context usage to the `statusLine` command on stdin and writes them nowhere else, so the
*Context*, model and *Usage* segments cannot work without tkzmux being that command. Nothing happens
until you say yes: the app asks once, shows the exact before/after of the `statusLine` key, and only
then sets `statusLine.command` in `<config dir>/settings.json` to `"…/bin/tkzmux-hook" statusline`
(`Sources/ClaudeBridge/StatuslineInstaller.swift`). Every other key in that file — and its key order,
and its number formatting — is preserved byte for byte, because the rewrite goes through the hook's
own JSON parser rather than `JSONSerialization`.

If you already had a status line, it keeps running: the whole original `statusLine` object is saved
to `statusline/previous-<account>.json` first, and tkzmux runs your command under `/bin/sh -c` with
the identical stdin bytes and passes its output through unchanged. *Status Line Integration* in the
app menu puts your original back exactly, and refuses rather than guessing if the saved copy is
missing or you have rewired `statusLine` yourself since. Two things it does not handle: a `statusLine`
in a **project** `.claude/settings.json` overrides the user-level one and is not detected, and if you
delete `~/Library/Application Support/tkzmux` by hand the `statusLine` key is left pointing at a
binary that is gone — `/statusline remove` in Claude Code, or deleting the key, fixes that.

**Hook payloads.** Each hook sends one NDJSON frame over the `AF_UNIX` socket — event name, Claude's
session id, the hook process's ppid, a timestamp, and Claude Code's own payload, which includes
`cwd` and `transcript_path`. The app keeps up to 4 KiB of `last_assistant_message` so a row can show
what Claude last said. All of that lives in `Session.live`, in memory, and is never written to
`state.json` (see above). In hook-event mode the hook binary writes nothing to stdout and exits 0 on
every path; its `settings-merge` mode is the exception — that one prints the merged settings
document for the shim to pass on, and exits 1 without printing anything if your settings file cannot
be parsed, in which case the shim `exec`s `claude` untouched.

**Other system surfaces.** The app posts macOS user notifications when a session needs you, so macOS
will ask for notification permission (`Sources/TkzApp/SessionEventHandler.swift`). It writes to the
unified log under the subsystem `se.tkz.tkzmux` — one line per session launch carrying the working
directory, `CLAUDE_CONFIG_DIR`, any extra environment and the command, all marked `privacy: .public`
so they are readable in Console.app like any other app's log
(`Sources/TkzApp/SessionLauncher.swift`). A program running in a terminal can **set** your clipboard
through OSC 52, which tkzmux honours (`Sources/TkzTerminalView/MouseController.swift`); clipboard
*reads* are refused. The app is not sandboxed and ships no entitlements; a default build is ad-hoc
signed.

## Known gaps

- **Usage and context need the status line installed.** The *Context*, model badge and *Usage*
  segments stay empty until you accept the status line integration described above — Claude Code
  publishes that data nowhere else. It is offered once at startup and lives in the app menu.
- **The PR badge needs `gh`.** Branch, diff stats, ahead/behind and ports are live. The PR badge
  additionally needs the GitHub CLI installed and authenticated, and only appears for repos whose
  origin is on GitHub — on any other host the lookup is skipped by design, and the badge stays
  empty.
- **zsh only.** The shell integration is a set of `ZDOTDIR` wrappers; there is no bash or fish
  equivalent, and in another shell tkzmux degrades to descriptor-only status with no hooks
  (Linear TKZ-33).
- **One Claude per session.** Splits and tabs share the row's Claude session: every pane of a
  row shows the same status dot, and the status bar's Context and model are the row's. The
  git facts — the status bar and the row's `⎇ branch` line — follow the *focused* pane's
  directory; the row's title does not.
- **Apple Silicon, macOS 26+, and no light theme yet.**

## License and credits

MIT — see [LICENSE](LICENSE).

- **[libghostty-vt](https://github.com/ghostty-org/ghostty)** — Ghostty's headless terminal core
  (MIT), vendored as a prebuilt xcframework under `vendor/ghostty-vt` at the commit recorded in
  `vendor/ghostty-vt/COMMIT`. tkzmux uses it only through its public C API. Ghostty is a separate
  project and is not affiliated with this one.
- **[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono)** — bundled under the SIL Open Font
  License 1.1; the licence text ships with the fonts at `Resources/Fonts/OFL.txt`. It is registered
  process-scoped at launch and is not installed into your font library.
- Claude and Claude Code are products of Anthropic. This project is not affiliated with, endorsed
  by, or supported by Anthropic.
