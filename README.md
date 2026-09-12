# tkzmux

A native macOS session manager for [Claude Code](https://claude.com/claude-code). Every Claude Code
conversation gets its own real terminal in one window. A sidebar lists the sessions grouped by
repository, and each row shows a status derived from Claude Code's own session descriptors and
hooks: *working*, *done*, or **NEEDS YOU** when a permission prompt or an unattended answer is
waiting. The terminal is a from-scratch Metal renderer driving
[libghostty-vt](https://github.com/ghostty-org/ghostty), the project's only third-party dependency.
Sessions survive a quit: screen and scrollback are snapshotted, and a restored row reopens under a
fresh shell with `claude --resume` a keystroke away.

<!-- SCREENSHOT: a shot of the main window (sidebar + terminal) goes here. Not added yet. -->

## Status

A personal project, built for one person's workflow, developed in the open. It is **not a
supported product**: no roadmap, no compatibility promise, no commitment to answer issues. Use it
if it helps you, fork it if it nearly does.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon only.
- [Claude Code](https://claude.com/claude-code) installed and working in your shell.
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
`~/.claude` is read, never written; everything tkzmux writes lives under
`~/Library/Application Support/tkzmux`. The one exception is the status line integration, which
you opt into and which sets the `statusLine` key in Claude Code's `settings.json`.

**Terminal snapshots contain your screen and scrollback verbatim, unencrypted**, in that support
directory. They are deleted with the session.

The full accounting, file by file, is in [docs/privacy.md](docs/privacy.md).

## Known gaps

- **Usage and context need the status line installed.** Claude Code publishes that data nowhere
  else. The integration is offered once at startup and lives in the app menu.
- **The PR badge needs `gh`** and a GitHub origin. Branch, diff stats, ahead/behind and ports work
  without it.
- **Shell integration differs a little per shell.** bash runs as a non-login shell with `--rcfile`;
  shells other than zsh, bash and fish only get `bin/` prepended to `PATH`. Details in
  [docs/privacy.md](docs/privacy.md).
- **One Claude per session.** Splits and tabs share the row's Claude session and status.

## License and credits

MIT — see [LICENSE](LICENSE).

- **[libghostty-vt](https://github.com/ghostty-org/ghostty)** (MIT), vendored as a prebuilt
  xcframework under `vendor/ghostty-vt`, used only through its public C API. Ghostty is a separate
  project and is not affiliated with this one.
- **[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono)**, bundled under the SIL Open Font
  License 1.1 (`Resources/Fonts/OFL.txt`).
- Claude and Claude Code are products of Anthropic. This project is not affiliated with, endorsed
  by, or supported by Anthropic.
