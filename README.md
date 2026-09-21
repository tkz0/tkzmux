# tkzmux

A native macOS session manager for coding agents — [Claude Code](https://claude.com/claude-code),
[Codex CLI](https://developers.openai.com/codex/cli) and the
[Antigravity CLI](https://antigravity.google) today. Every conversation gets its own real terminal
in one window, whichever agent is driving it. A sidebar lists the sessions grouped by repository,
and each row shows a status derived from that agent's own hooks — plus, for Claude Code, its
session descriptors too: *working*, *done*, or **NEEDS YOU** when a permission prompt or an
unattended answer is waiting. The terminal is a from-scratch Metal renderer driving
[libghostty-vt](https://github.com/ghostty-org/ghostty), the project's only third-party dependency.
Sessions survive a quit: screen and scrollback are snapshotted, and a restored row reopens under a
fresh shell with its own agent's resume command — `claude --resume`, `codex resume` or
`agy --conversation` — a keystroke away.

<!-- SCREENSHOT: a shot of the main window (sidebar + terminal) goes here. Not added yet. -->

## Status

A personal project, built for one person's workflow, developed in the open. It is **not a
supported product**: no roadmap, no compatibility promise, no commitment to answer issues. Use it
if it helps you, fork it if it nearly does.

## Agents

Every agent sits behind the same seam, so a row is a row whichever one started it: same terminal,
same snapshot and restore, same status vocabulary. What differs is how much each CLI is willing to
tell a session manager about itself, and tkzmux claims only what its adapter actually measured
against a real, logged-in binary.

|                       | Claude Code | Codex CLI | Antigravity CLI |
|---|---|---|---|
| Binary                | `claude`    | `codex`   | `agy`           |
| Status from hooks     | ✅          | ✅        | ✅              |
| Resume a conversation | ✅          | ✅        | ✅              |
| Live session descriptors | ✅       | —         | —               |
| Usage and context     | ✅ (status line) | ✅ (transcript) | — (records none) |
| Worktree launch flag  | ✅          | —         | —               |
| Several accounts      | ✅ `CLAUDE_CONFIG_DIR` | ✅ `CODEX_HOME` | — one per machine |

Each sidebar group remembers its own agent, so the New-session rows in the menu launch that one;
the other installed agents live under *Other agent* for a one-off launch. tkzmux only ever offers
the agents it finds on your `PATH`.

## Keyboard

The title bar carries the session name and four buttons (new shell, the two splits, the theme
toggle) and nothing else — no “＋ New session…” button, no permanently-empty search box. Those two
live on the keyboard instead, which is where they were always faster:

| Keys | |
|---|---|
| ⌘N | New session, in the selected group. A group's sidebar row has its own ＋ if you would rather click |
| ⇧⌘N | New group. It starts as a bucket; *Set Repo…* on its context menu attaches a repo |
| ⌘F | Search — sessions, transcripts and changed files, in one overlay in the middle of the window. ⇥ narrows it to one of those; ↵ opens the hit; ⌘↵ starts a new session with what you typed as the prompt |
| ⇧⌘P | Command palette: every command, session and group by name |
| ⌘B | Show/hide the sidebar |
| ⌘T / ⌘D / ⇧⌘D | New terminal in this session / split side by side / split stacked |
| ⌘1…⌘9 | Select the n-th session |
| ⌘I | Activity feed — what every session has been doing, newest first |
| ⌘, | Settings |

**Hold ⌘ alone** for two seconds at any time and a cheat sheet of every binding appears, read off the live
menu — so it always agrees with what is actually bound.

The full table, the keys that work *inside* the search overlay, and how to rebind anything through
`state.json` are in [docs/shortcuts.md](docs/shortcuts.md).

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon only.
- [Claude Code](https://claude.com/claude-code), [Codex CLI](https://developers.openai.com/codex/cli)
  or the [Antigravity CLI](https://antigravity.google) installed and working in your shell — one is
  enough, and tkzmux only ever looks for the ones it finds on `PATH`.
- `zsh`, `bash` or `fish` as your login shell, for the shell integration.
- Optional: the [GitHub CLI](https://cli.github.com) (`gh`), authenticated, for the PR badge.

## Install

```sh
brew tap tkz0/tap
brew trust --cask tkz0/tap/tkzmux
brew install --cask tkzmux
```

Since Homebrew 6.0 a cask from a third-party tap must be trusted before it is loaded; without the
`brew trust` step, `brew tap` fails with `invalid syntax in tap!`. See
[Tap Trust](https://docs.brew.sh/Tap-Trust). The app is signed with a Developer ID and notarized,
so it opens with no Gatekeeper prompt.

## Build from source

```sh
git clone https://github.com/tkz0/tkzmux
cd tkzmux
make app            # release build, ad-hoc signed → build/tkzmux.app
open build/tkzmux.app
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full local dev loop (testing, swapping a Homebrew
install for a local build, code conventions) and how to contribute a change.

Everything else is plain SwiftPM, no `.xcodeproj`: `swift build`, `swift test`, `swift run tkzmux`.

`make app` compiles the shaders with `xcrun metal`, which on Xcode 26 is a separate download:

```sh
xcodebuild -downloadComponent MetalToolchain
```

A real (non-ad-hoc) signature is one variable: `SIGN_IDENTITY="Developer ID Application: …" make app` adds the
hardened runtime and a secure timestamp. `make notarize` notarizes and staples an already-signed app,
and `make dist` cuts a tagged, notarized release.

## Privacy

No telemetry, analytics or crash reporting. tkzmux makes one network request of its own: a release
build periodically asks GitHub for the latest release, sending nothing about you or your sessions.
The PR badge shells out to `gh pr view`, under your own credentials and only for GitHub origins.
Each agent's config directory — `~/.claude`, `~/.codex` and, for Antigravity, `~/.gemini` — is
read, never written; everything tkzmux writes lives under
`~/Library/Application Support/tkzmux`. The exceptions are opt-in and asked for by name before
anything is touched: the status line integration sets the `statusLine` key in Claude Code's
`settings.json`, and the hooks integration writes tkzmux's hooks into Codex's own `hooks.json` and
into Antigravity's `~/.gemini/config/hooks.json`. Each agent is asked for separately, so declining
one does not answer for the others.

**Terminal snapshots contain your screen and scrollback verbatim, unencrypted**, in that support
directory. They are deleted with the session.

The full accounting, file by file, is in [docs/privacy.md](docs/privacy.md).

## Known gaps

- **Usage and context differ per agent.** Claude Code needs the status line installed — it
  publishes that data nowhere else; the integration is offered once at startup and lives in
  Settings (⌘,) › General. Codex is read straight from its transcript. Antigravity records no token
  or cost accounting at all, so its rows show no spend badge.
- **The PR badge needs `gh`** and a GitHub origin. Branch, diff stats, ahead/behind (against the
  upstream, and the `⤿ 7 behind main` chip against the base branch) and ports work without it.
- **Shell integration differs a little per shell.** bash runs as a non-login shell with `--rcfile`;
  shells other than zsh, bash and fish only get `bin/` prepended to `PATH`. Details in
  [docs/privacy.md](docs/privacy.md).
- **Antigravity is one account per machine.** Nothing but `HOME` relocates its config directory, so
  there is no second account to switch to and no account chip on its rows.
- **One agent session per row.** Splits and tabs share the row's agent session and status.

## License and credits

MIT — see [LICENSE](LICENSE).

- **[libghostty-vt](https://github.com/ghostty-org/ghostty)** (MIT), vendored as a prebuilt
  xcframework under `vendor/ghostty-vt`, used only through its public C API. Ghostty is a separate
  project and is not affiliated with this one.
- **[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono)**, bundled under the SIL Open Font
  License 1.1 (`Resources/Fonts/OFL.txt`).
- Claude and Claude Code are products of Anthropic. This project is not affiliated with, endorsed
  by, or supported by Anthropic.
- Codex and Codex CLI are products of OpenAI. This project is not affiliated with, endorsed by, or
  supported by OpenAI.
- Antigravity is a product of Google. This project is not affiliated with, endorsed by, or
  supported by Google.
