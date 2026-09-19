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
(`Sources/AgentBridge/HookServer.swift`, `Sources/tkzmux-hook/Socket.swift`).

It also reaches the network **indirectly, in two places**. The PR badge shells out to
`gh pr view` (`Sources/GitStatus/PRLookup.swift`), and `gh` talks to GitHub under your own
credentials. That call is gated — the origin's host is checked with `git remote get-url origin` and
cached per directory first, so `gh` is never invoked for a repo whose origin is not GitHub, not even
to fail. When it may run, it runs for the selected session and for any session whose PR is still
open, at most once per five minutes per session, plus once when a Claude turn ends (at least 15 s
apart) so a PR the session just created shows up promptly. The second place is `git fetch` of a
repo's base branch (`Sources/GitStatus/GitRebase.swift`), under your own git credentials: it runs
when you open the rebase sheet from the `⤿ 7 behind main` chip, and — only if you turn *Check Origin
Periodically* on, which is off by default — every five minutes per repo. Apart from those and
Claude Code's own traffic from the `claude` process in your terminal, nothing leaves the machine.

**Processes it starts.** Your login shell, on a pty (`Sources/TkzPtyShim/TkzPtyShim.c`,
`Sources/TkzTerminalCore/Pty.swift`) — everything else *inside* a session is something you typed.
Plus these, in the background, on repos backing your sessions:

| Command | Why |
|---|---|
| `git status --porcelain=v2 --branch -z`, `git diff HEAD --shortstat` | branch, ahead/behind and diff counts (`GitStatusService.swift`) |
| `git symbolic-ref -q refs/remotes/origin/HEAD`, `git for-each-ref …` | find the repo's base branch (`origin/main`), once per repo and again every 60 s while it is unresolved (`BaseBranch.swift`) |
| `git rev-list --left-right --count <base>...HEAD` | how far the branch is behind its base — the `⤿ 7 behind main` chip — against whatever `BaseBranch.resolve` found locally: `origin/HEAD`/`origin/main`/`origin/master` when the repo has one, else a local `main`/`master`. For a remote base that count is only as fresh as the last fetch; a local-only base has nothing to go stale (`GitStatusService.swift`) |
| `git worktree list --porcelain` | notice when a worktree behind a row is removed (`WorktreeList.swift`) |
| `git remote get-url origin` | decide whether the PR lookup may run at all (`PRLookup.swift`) |
| `gh pr view --json …` | the PR badge — **GitHub origins only**; ≤ 1 per 5 min per session with an open PR, plus one per Claude turn (`PRLookup.swift`) |

All of them run with `--no-optional-locks` / `GIT_OPTIONAL_LOCKS=0` so a background refresh cannot
contend with git commands you run yourself.

And this one, **only if you turn it on** (*Check origin periodically* in Settings (⌘,) › General,
off by default):

| Command | Why |
|---|---|
| `git fetch --quiet origin <base>` | at once when you turn the preference on, then every 5 minutes per repo with a session, and on wake/activation when the last check is older than that, so the `⤿ 7 behind main` chip reflects the remote. Under your own git credentials; a missing credential fails at once rather than prompting (`GitRebase.swift`, `GitIntegration.swift`) |

And these, **only when you invoke** — the rebase sheet (⌥⌘R, the Session menu, or the `⤿ 7 behind main`
chip) or the update card — never on their own. The rebase ones, plus the opt-in `git fetch` above,
are **the only commands in the app that write to a repository**; that opt-in `fetch` only updates
remote-tracking refs and repository metadata, never your working tree or history:

| Command | Why |
|---|---|
| `git fetch --quiet origin <base>`, `git rev-list --left-right --count …` | opening the rebase sheet (⌥⌘R or the `⤿ 7 behind main` chip): fetch the base branch, then count what "Pulls in N commits" says. Skipped when the repo was fetched within the last minute (`GitRebase.swift`) |
| `git status --porcelain=v2 -z`, `git rebase --autostash <base>`, and on a rebase conflict `git diff --name-only --diff-filter=U` then `git rebase --abort` | the sheet's *Rebase* button. Uncommitted tracked changes are stashed and put back; a rebase conflict counts the conflicted files, aborts and leaves the tree as it was. A timeout or a failure to launch git aborts without counting the conflicts. If the rebase itself goes through but reapplying the stash conflicts, the rebase stands instead: the tree keeps those conflict markers and the change stays in `git stash` rather than being aborted. Refused on a detached HEAD or while a rebase or merge is already in progress, and the button is off while the row's Claude is mid-turn (`GitRebase.swift`, `GitIntegration.swift`) |
| `brew update`, then `brew upgrade --cask tkz0/tap/tkzmux` | "Update via Homebrew" — offered only when the running app is the cask's `/Applications/tkzmux.app` and `brew` is installed; everything brew prints goes to `~/Library/Logs/tkzmux/update.log` (`Sources/TkzApp/Update/UpgradeRunner.swift`) |
| `/bin/sh -c 'while kill -0 <pid> …; do sleep 0.2; done; exec /usr/bin/open <app>'` | "Restart to update" — waits for tkzmux to quit, then reopens it (`UpdateRelaunch.swift`). Restarting closes every session's shell; the rows are kept and ⌘R resumes Claude |

**Processes it inspects.** To show a dev server's port on a row, tkzmux walks the descendant
processes of a session and looks at their open file descriptors for listening TCP sockets
(`Sources/GitStatus/PortScanner.swift`, via `libproc`). It reads local kernel state about processes
you started — it opens no connection to those ports and sends nothing anywhere.

**What it reads.** `~/.claude` — and any sibling `~/.claude-*` directory that looks like a second
config dir — is read, never written:

- `<config dir>/sessions/<pid>.json`, the session descriptors Claude Code publishes, are read and
  watched for changes (`Sources/AgentBridge/ClaudeSessionWatcher.swift`). Only files whose basename
  is an integer pid are opened; the sibling `<pid>.<sha>.key` files are ignored.
- `settings.json`, `sessions/` and `.claude.json` are used **only as existence markers** when
  discovering accounts — `FileManager.fileExists`, never opened or parsed
  (`Sources/AgentBridge/Claude/ClaudeAdapter.swift`, `discoverAccounts`). `.claude.json` is Claude
  Code's own configuration file; the one thing tkzmux ever reads out of it is `oauthAccount`, and
  only to put a name and plan on an account badge (`Sources/tkzmux-hook/StatuslineCommand.swift`).
  It is read only when the account's own sidecar carries no label yet, and never written.
- If you pass `claude --settings <file-or-json>`, the shim reads that document in order to merge
  tkzmux's hooks into it (`Sources/tkzmux-hook/SettingsMerge.swift`).
- `<config dir>/projects/*/<session id>.jsonl` — each session's own Claude Code transcript — is read
  in two places: `TranscriptReader` reads the head and tail of the file for the first-prompt card
  and Claude's own recap (`Sources/AgentBridge/TranscriptReader.swift`), and
  `TranscriptUsageReader` reads every `"type":"assistant"` line's `message.usage` object to sum
  token counts for the *Usage and spend* feature below. Neither ever writes to a transcript.

**Codex.** `~/.codex` — and any sibling `~/.codex-*` directory that looks like a second config
dir — is read the same way, and only while `codex` is actually on your `PATH`
(`Sources/AgentBridge/Codex/CodexAdapter.swift`, `discoverAccounts`): a leftover `~/.codex` from
an agent you have since uninstalled produces no account. `config.toml` and `auth.json` are used
only as existence markers, `FileManager.fileExists`, never opened or parsed by account discovery.
Codex writes no session-descriptor file of its own, so there is nothing there for tkzmux to watch —
its status comes entirely from hooks (below). `<config dir>/sessions/**/rollout-*.jsonl` — Codex's
own transcript — is read the same two ways Claude Code's is, by a Codex-specific implementation of
the same reader interface (`Sources/AgentBridge/Codex/CodexTranscriptReader.swift`).

**What it writes.** Everything lives under `~/Library/Application Support/tkzmux`:

- `state.json` (+ `.bak`) — groups, sessions, window frame, shortcuts, preferences.
  Process state (pids, descriptors, statuses, last messages) is deliberately **not** persisted:
  `Session.live` is cleared on the way to disk *and* in memory before comparison
  (`Sources/Persistence/PersistedState.swift`, `StateFile.swift`).
- `sessions/<id>.ghsnap` — terminal snapshots, taken at quit and every 5 minutes
  (`Sources/Persistence/Snapshots.swift`). **These contain your terminal's screen and scrollback
  verbatim, unencrypted.** Anything printed in a tkzmux terminal — including whatever Claude Code
  prints — can end up in one of these files. They are deleted with the session.
- `bin/claude`, `bin/codex`, `bin/tkzmux-hook`, `zsh/.{zshenv,zprofile,zshrc,zlogin}`,
  `bash/tkzmux.bashrc`, `fish/tkzmux.fish`, `VERSION` — the shell integration
  (`Sources/AgentBridge/ShimInstaller.swift`). Both shims are written whether or not you have that
  agent installed; only the one whose name a shell actually resolves to ever runs.
- `codex-hooks/previous-<account>.json` — the Codex `hooks.json` you had before, kept so it can be
  restored (`Sources/AgentBridge/Codex/CodexHooksInstaller.swift`). Written only while Codex's
  hooks integration is installed — see below.
- `statusline/usage-<account>.json`, `statusline/context-<session id>.json` — what the status line
  command captures: quota percentages and reset times, and per session the context percentage,
  model name, session name, working directory, repo, open PR and cumulative session cost
  (`Sources/tkzmux-hook/StatuslineCommand.swift`). Written only while the status line is installed.
- `statusline/previous-<account>.json` — the `statusLine` you had before, kept so it can be restored.
- `usage/<session id>.json` — **Usage and spend.** A running per-model token count (input, output,
  cache write, cache read) for the session, summed off its own transcript, plus the byte offset
  already parsed so a relaunch resumes instead of re-reading the file
  (`Sources/AgentBridge/TranscriptUsageReader.swift`). Estimated USD cost is *not* stored here — it
  is computed from the token counts against a hand-maintained price table
  (`Sources/TkzCore/ModelPricing.swift`) each time the status bar reads it, so an edit to that table
  is retroactive. This file is a recomputable cache, not a record: deleting it just costs one re-read
  of the transcript, the same as `statusline/*` and unlike `state.json`.
- `tkzmux-<pid>.sock` — the local hook socket, one per running tkzmux (named after its pid so two
  instances never share one). Removed on quit; one left by a crash is swept at the next launch.

**Shell integration and hooks.** Terminals tkzmux opens run your login shell (`$SHELL`, else the
account database) with a wrapper that runs *after* your own startup files and puts tkzmux's `bin/`
first on `PATH`, so inside a tkzmux terminal `claude` resolves to a small bash shim
(`Sources/AgentBridge/Resources/shim/claude.sh`). For zsh the wrapper is a set of `ZDOTDIR` files
that source your real rc files (`Sources/AgentBridge/Resources/zsh/`); for bash it is an `--rcfile`
that sources `/etc/profile` and your `.bash_profile` itself (`Resources/bash/tkzmux.bashrc`); for
fish it is an `--init-command` that runs after `config.fish` (`Resources/fish/tkzmux.fish`). None
of them touches a file in your home directory. The shim `exec`s the real `claude` with a
`--settings` document that adds tkzmux's own hooks (SessionStart, SessionEnd, UserPromptSubmit, Stop,
and a Notification matcher) pointing at `tkzmux-hook`. It **never edits `~/.claude/settings.json`**,
and it passes straight through for `-p`, `--bare`, subcommands and anything else it does not
recognise. The zsh wrappers also point `HISTFILE` back at your own `~/.zsh_history` so tkzmux shells
share your history rather than starting a private one. The command a session is opened to run
(`claude`, `claude -w`, `claude --resume`) is run at the shell's first prompt, after hooks such as
direnv's have exported their environment, so Claude sees your `.envrc`. *Remove shell integration*
in Settings (⌘,) › Shell deletes `bin/` and the wrapper directories again, until the next launch
installs them afresh.

Codex's own shim (`Sources/AgentBridge/Resources/shim/codex.sh`) works the same way up through
finding the real `codex` and passing through untouched for a subcommand, a flag, or outside a
tkzmux session — but it never merges a settings document, because Codex has no `--settings`
equivalent to merge one into. All it adds is one `launch` announcement over the same socket before
`exec`ing the real binary with `argv` completely unmodified; whatever relays Codex's own hooks is
the separate, consent-gated `hooks.json` write described below, not this shim.

**The status line and Codex's hooks — the two files tkzmux writes outside its own directory, both
opt-in.** Claude Code hands rate
limits and context usage to the `statusLine` command on stdin and writes them nowhere else, so the
*Context*, model and *Usage* segments cannot work without tkzmux being that command. Nothing happens
until you say yes: the app asks once, shows the exact before/after of the `statusLine` key, and only
then sets `statusLine.command` in `<config dir>/settings.json` to `"…/bin/tkzmux-hook" statusline`
(`Sources/AgentBridge/StatuslineInstaller.swift`). Every other key in that file — and its key order,
and its number formatting — is preserved byte for byte, because the rewrite goes through the hook's
own JSON parser rather than `JSONSerialization`.

If you already had a status line, it keeps running: the whole original `statusLine` object is saved
to `statusline/previous-<account>.json` first, and tkzmux runs your command under `/bin/sh -c` with
the identical stdin bytes and passes its output through unchanged. *Status line integration* in
Settings (⌘,) › General puts your original back exactly, and refuses rather than guessing if the saved copy is
missing or you have rewired `statusLine` yourself since. Two things it does not handle: a `statusLine`
in a **project** `.claude/settings.json` overrides the user-level one and is not detected, and if you
delete `~/Library/Application Support/tkzmux` by hand the `statusLine` key is left pointing at a
binary that is gone — `/statusline remove` in Claude Code, or deleting the key, fixes that.

**Codex's own hooks.** Codex has no status line to wrap, and its shim cannot inject hooks the way
Claude's does — a hook passed on the command line parses but never runs, measured against a real
codex-cli 0.155.0 — so getting the same session-relayed status out of Codex means writing into its
own `<config dir>/hooks.json` once, with consent, the same "ask first, show the exact before/after"
discipline as the status line. Settings (⌘,) › General shows the plan and only then appends one new
group under each of eight events (`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`,
`Interrupt`, `PermissionRequest`, `PreToolUse`, `PostToolUse`) running `"…/bin/tkzmux-hook" <event>`;
every other key already in the file — anyone else's hooks included — is preserved untouched, because
the rewrite goes through the same kind of order-preserving JSON parser the status line's rewrite
uses, never `JSONSerialization`. The whole prior document is saved to
`codex-hooks/previous-<account>.json` first, and *Hooks integration* in Settings puts it back
exactly (or deletes the file if there was none), refusing rather than guessing if `hooks.json` no
longer carries tkzmux's command for every one of those events (`Sources/AgentBridge/Codex/CodexHooksInstaller.swift`).

**A hook written this way does not run until Codex trusts it.** Codex keys hook trust by source and
skips an untrusted one silently — no error, the turn just completes without it — so a freshly
installed hook stays dark until you review it once inside Codex's own `/hooks` command. tkzmux
never bypasses this (`--dangerously-bypass-hook-trust` would waive trust for every hook of the
invocation, including your own, and nothing here ever passes it) and never writes to Codex's trust
ledger (`<config dir>/hooks.state`) or to `config.toml`; both are only ever read, as plain text, to
say in Settings whether a hook looks trusted yet and whether `config.toml` already configures hooks
of its own (Codex merges both files, so an install here never replaces what is already there — it
only adds alongside it).

**Hook payloads.** Each hook sends one NDJSON frame over the `AF_UNIX` socket — which agent sent it
(`Sources/AgentBridge/HookFrame.swift`), the event name, the agent's own session id, the hook
process's ppid, a timestamp, and that agent's own payload, which includes `cwd` and
`transcript_path`. Claude's and Codex's hooks share this one socket and one frame shape; only the
payload fields each agent actually sends differ. The app keeps up to 4 KiB of
`last_assistant_message` so a row can show what the agent last said. All of that lives in
`Session.live`, in memory, and is never written to
`state.json` (see above) — with one exception: the activity feed (⌘I) keeps a log of up to 200
entries in `state.json`, one per finished turn, NEEDS YOU flip or Claude exit, each carrying the
session's title, its group's name and the first 1 KiB of Claude's last reply (or its one-line
prompt message), so a relaunch still shows what happened while you were away. Closing a row
removes its entries. In hook-event mode the hook binary writes nothing to stdout and exits 0 on
every path; its `settings-merge` mode is the exception — that one prints the merged settings
document for the shim to pass on, and exits 1 without printing anything if your settings file cannot
be parsed, in which case the shim `exec`s `claude` untouched.

**Other system surfaces.** The app posts macOS user notifications, with the system's notification
sound, when a session flips to **NEEDS YOU** for a permission prompt, a question or an agent-input
request, and when the agent finishes a turn in a session you are not looking at
(`Sources/TkzApp/AttentionNotifier.swift`, `Sources/TkzApp/SessionEventHandler.swift`). Every banner
names the agent by the same adapter-supplied display name Settings and the sidebar use, never a
hard-coded product name. macOS asks for notification permission once at launch, and its per-app
setting is the master switch; the "finished" banner also has a switch in Settings (⌘,) › General, on
by default. A NEEDS YOU banner shows the session's title and, for Claude Code, its own one-line
`message` from its `Notification` hook — which names the tool it wants to run, e.g. "Claude needs
your permission to use Bash" (Codex sends no such notification text of its own yet, so its NEEDS YOU
banner names only what is waiting, not a tool); a finished banner shows the title and the first line
of the agent's reply. That text is visible in Notification Center and, per your macOS settings, on
the lock screen. Nothing else from
the conversation is put in a notification, and every banner is taken back as soon as you look at the
session. A session can be muted from its row's context menu (*Mute Notifications*), which is
remembered in `state.json`. The app plays no sound of its own. It writes to the
unified log under the subsystem `se.tkz.tkzmux` — one line per session launch carrying the working
directory, whichever config-dir variable the account's own agent actually uses (`CLAUDE_CONFIG_DIR`
for Claude, `CODEX_HOME` for Codex — logged generically, by whatever name the adapter produced, not
hard-coded), any extra environment and the command, all marked `privacy: .public` so they are
readable in Console.app like any other app's log (`Sources/TkzApp/SessionLauncher.swift`). A program running in a terminal can **set** your clipboard
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
