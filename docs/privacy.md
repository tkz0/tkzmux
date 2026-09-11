# What tkzmux touches

The full privacy accounting behind the README's *Privacy* section. Every claim below is a claim
about the code in this repository; the file that backs it is named so you can check it yourself.

**No telemetry, no analytics, no crash reporting.** tkzmux makes exactly **one** kind of network
request of its own: the update check. A release build asks GitHub for the latest release —
`GET https://api.github.com/repos/tkz0/tkzmux/releases/latest` — 15 seconds after launch, then
every 4 hours, and again on wake or activation if the last check is older than that
(`Sources/TkzApp/Update/UpdateChecker.swift`, `UpdateIntegration.swift`). The request carries an
`Accept` header and `User-Agent: tkzmux/<version>` and nothing else: nothing about you, your
sessions or your machine. The answer only ever shows the "Update available" card at the foot of
the sidebar; closing that card hides it for that version for good. Builds made with `make app`
or `swift run` never check (their version is not a release), unless `TKZMUX_UPDATE_URL` points
them at a feed on purpose. That is the whole `URLSession` story — there is no other one, and no
`Network.framework` or `AF_INET` socket anywhere else in `Sources/`. The only other socket it
creates is an `AF_UNIX` one — a file in its own support directory, used by the hook relay
(`Sources/ClaudeBridge/HookServer.swift`, `Sources/tkzmux-hook/Socket.swift`).

It also reaches the network **indirectly, in one place**: the PR badge shells out to
`gh pr view` (`Sources/GitStatus/PRLookup.swift`), and `gh` talks to GitHub under your own
credentials. That call is gated — the origin's host is checked with `git remote get-url origin` and
cached per directory first, so `gh` is never invoked for a repo whose origin is not GitHub, not even
to fail. When it may run, it runs for the selected session and for any session whose PR is still
open, at most once per five minutes per session, plus once when a Claude turn ends (at least 15 s
apart) so a PR the session just created shows up promptly. Apart from that and Claude Code's own
traffic from the `claude` process in your terminal, nothing leaves the machine.

**Processes it starts.** Your login shell, on a pty (`Sources/TkzPtyShim/TkzPtyShim.c`,
`Sources/TkzTerminalCore/Pty.swift`) — everything else *inside* a session is something you typed.
Plus these, in the background, on repos backing your sessions:

| Command | Why |
|---|---|
| `git status --porcelain=v2 --branch -z`, `git diff HEAD --shortstat` | branch, ahead/behind and diff counts (`GitStatusService.swift`) |
| `git worktree list --porcelain` | notice when a worktree behind a row is removed (`WorktreeList.swift`) |
| `git remote get-url origin` | decide whether the PR lookup may run at all (`PRLookup.swift`) |
| `gh pr view --json …` | the PR badge — **GitHub origins only**; ≤ 1 per 5 min per session with an open PR, plus one per Claude turn (`PRLookup.swift`) |

All of them run with `--no-optional-locks` / `GIT_OPTIONAL_LOCKS=0` so a background refresh cannot
contend with git commands you run yourself.

And these, **only when you click** on the update card, never on their own:

| Command | Why |
|---|---|
| `brew update`, then `brew upgrade --cask tkz0/tap/tkzmux` | "Update via Homebrew" — offered only when the running app is the cask's `/Applications/tkzmux.app` and `brew` is installed; everything brew prints goes to `~/Library/Logs/tkzmux/update.log` (`Sources/TkzApp/Update/UpgradeRunner.swift`) |
| `/bin/sh -c 'while kill -0 <pid> …; do sleep 0.2; done; exec /usr/bin/open <app>'` | "Restart to update" — waits for tkzmux to quit, then reopens it (`UpdateRelaunch.swift`). Restarting closes every session's shell; the rows are kept and ⌘R resumes Claude |

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

- `state.json` (+ `.bak`) — groups, sessions, window frame, shortcuts, preferences.
  Process state (pids, descriptors, statuses, last messages) is deliberately **not** persisted:
  `Session.live` is cleared on the way to disk *and* in memory before comparison
  (`Sources/Persistence/PersistedState.swift`, `StateFile.swift`).
- `sessions/<id>.ghsnap` — terminal snapshots, taken at quit and every 5 minutes
  (`Sources/Persistence/Snapshots.swift`). **These contain your terminal's screen and scrollback
  verbatim, unencrypted.** Anything printed in a tkzmux terminal — including whatever Claude Code
  prints — can end up in one of these files. They are deleted with the session.
- `bin/claude`, `bin/tkzmux-hook`, `zsh/.{zshenv,zprofile,zshrc,zlogin}`, `bash/tkzmux.bashrc`,
  `fish/tkzmux.fish`, `VERSION` — the shell integration (`Sources/ClaudeBridge/ShimInstaller.swift`).
- `statusline/usage-<account>.json`, `statusline/context-<session id>.json` — what the status line
  command captures: quota percentages and reset times, and per session the context percentage,
  model name, session name, working directory, repo and open PR
  (`Sources/tkzmux-hook/StatuslineCommand.swift`). Written only while the status line is installed.
- `statusline/previous-<account>.json` — the `statusLine` you had before, kept so it can be restored.
- `tkzmux.sock` — the local hook socket.

**Shell integration and hooks.** Terminals tkzmux opens run your login shell (`$SHELL`, else the
account database) with a wrapper that runs *after* your own startup files and puts tkzmux's `bin/`
first on `PATH`, so inside a tkzmux terminal `claude` resolves to a small bash shim
(`Sources/ClaudeBridge/Resources/shim/claude.sh`). For zsh the wrapper is a set of `ZDOTDIR` files
that source your real rc files (`Sources/ClaudeBridge/Resources/zsh/`); for bash it is an `--rcfile`
that sources `/etc/profile` and your `.bash_profile` itself (`Resources/bash/tkzmux.bashrc`); for
fish it is an `--init-command` that runs after `config.fish` (`Resources/fish/tkzmux.fish`). None
of them touches a file in your home directory. The shim `exec`s the real `claude` with a
`--settings` document that adds tkzmux's own hooks (SessionStart, SessionEnd, UserPromptSubmit, Stop,
and a Notification matcher) pointing at `tkzmux-hook`. It **never edits `~/.claude/settings.json`**,
and it passes straight through for `-p`, `--bare`, subcommands and anything else it does not
recognise. The zsh wrappers also point `HISTFILE` back at your own `~/.zsh_history` so tkzmux shells
share your history rather than starting a private one. The command a session is opened to run
(`claude`, `claude -w`, `claude --resume`) is run at the shell's first prompt, after hooks such as
direnv's have exported their environment, so Claude sees your `.envrc`. *Remove Shell Integration*
in the app menu deletes `bin/` and the wrapper directories again.

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
*reads* are refused. ⌘V pastes the clipboard's text; when the clipboard holds an image and no text
(a screenshot), ⌘V instead sends the Ctrl-V keystroke Claude Code reads the clipboard image on, so
⌘V attaches a screenshot the way it does in cmux. Text always wins when both are present. The app
is not sandboxed and ships no entitlements; a default build is ad-hoc
signed.

## Shell integration, per shell

bash is started as an interactive non-login shell with `--rcfile` (a login bash ignores it), so the
wrapper reads `/etc/profile` and your `.bash_profile` itself; `shopt -q login_shell` is false and
`$0` is `bash`. In fish the command a session was opened to run goes into the history with
`history append`. Any other login shell (tcsh, dash…) is spawned as a plain login shell with `bin/`
prepended to `PATH` from the outside, which your own startup files can undo.
