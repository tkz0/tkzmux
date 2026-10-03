# AgentBridge on Linux

How the agent side of tkzmux (hook socket, watchers, liveness, installers, shell integration) runs on Linux, and what real Claude Code, Codex and Antigravity sessions produce there. Created in WOR-306 S1, which covers the hook socket. WOR-306 S2-S6 add the watchers, liveness and installers, shell integration, and the real-agent probe traces and dotfile-sync notes.

## Bring-up

AgentBridge joined the Linux graph a file at a time. Until WOR-306 S3, `Package.swift` listed the sources that built on Linux and the tests that ran on them and excluded the rest. Since S3 every source builds, so AgentBridge is a shared target, with its resources (`shim`, `zsh`, `bash`, `fish`) on both OSes and `TkzPlatformShim` linked on Linux only. Since S5 the Linux `AgentBridgeTests` target runs every test file, the shell harness and the zsh wrapper tests included (see [Shell integration](#shell-integration)).

| Session | Linux sources | Linux tests |
|---|---|---|
| WOR-306 S1 | `HookFrame.swift`, `HookServer.swift` | `HookServerTests` (plus the hook's own `HookHygieneTests` and `HookSupportPathTests` from WOR-305) |
| WOR-306 S2 | `ClaudeSessionWatcher.swift`, `StatuslineReader.swift`, `TranscriptWatch.swift` (new), and what they need to build: `AgentAdapter.swift`, `ProcessLiveness.swift`, `QuotaReconciler.swift`, `PromptCommand.swift`, `TranscriptReader.swift`, `TranscriptSearch.swift`, `TranscriptUsageReader.swift`, `Claude/ClaudeSessionInfo.swift`, `Codex/CodexUsageExtractor.swift` | `ClaudeSessionWatcherTests`, `StatuslineReaderTests` (with `StatuslineTestSupport.swift`, split out of `StatuslineTests` so the reader tests build without `StatuslineInstaller`), `TranscriptWatchTests` |
| WOR-306 S3 | everything else: the adapters and mappers, `ProcessOwnership.swift`, `ShimInstaller.swift`, `StatuslineInstaller.swift`, `UserPath.swift`, `ModuleResources.swift`, `Codex/*`, `Antigravity/*` | everything but the shell harness and the zsh wrapper tests |
| WOR-306 S5 | – (the wrapper resources change) | `ShellIntegrationHarnessTests`, `ZshWrapperTests`, `BashWrapperTests` (new) |
| WOR-306 S6 | – (`CodexHooksDetection` gains `hooksFeatureDisabled`) | `AgentFixtureReplayTests` (new), `RealAgentProbeTests` (new, opt-in), and in TkzTerminalCoreTests `osc3008ContextReportsAreIgnored` |

## Hook socket

### Where it lives

| | Linux | macOS (unchanged) |
|---|---|---|
| Directory | `$XDG_RUNTIME_DIR/tkzmux`, created 0700 | the support directory |
| Fallback | the support directory, `$XDG_DATA_HOME/tkzmux` | – |
| Socket | `<directory>/tkzmux-<pid>.sock`, mode 0600 | same |

`HookSocket.directory(support:environment:)` (`Sources/TkzCore/HookSocket.swift`) decides. Everything that names the socket calls it:

- `TerminalEnvironment.make` exports `TKZMUX_SOCKET` from the environment the pane inherits (`baseEnvironment`). So inside a pane, `TKZMUX_SOCKET` is `$XDG_RUNTIME_DIR/tkzmux/tkzmux-<pid>.sock` for the pane's own `$XDG_RUNTIME_DIR`.
- `AgentIntegration` builds the `HookServer` path and sweeps stale sockets from the process environment. In the app that is the same environment, because `TerminalHost.baseEnvironment` defaults to the process environment.

The fallback to the support directory applies when `$XDG_RUNTIME_DIR` is unset, empty or relative (the XDG spec says to ignore it then), or when `<XDG_RUNTIME_DIR>/tkzmux` cannot be made private and writable. That covers a file or symlink in its place, an entry another user owns, a missing or read-only root, and a root this user cannot write. `AppPaths.privateRuntimeDirectory(environment:)` (`Sources/TkzPlatform/AppPaths.swift`) does the check. It never creates `$XDG_RUNTIME_DIR` itself. CI containers often have no `$XDG_RUNTIME_DIR`, so there the socket sits in the support directory, as on the Mac.

The runtime directory is a per-user tmpfs that logout clears, so a crash no longer leaves a stale socket in persistent storage. `HookServer.sweepStaleInstanceSockets` still runs on every start, in whichever directory was chosen. The path is about 40 bytes, well inside Linux's 108-byte `sun_path` (`MemoryLayout.size(ofValue: sockaddr_un().sun_path)`, 104 on macOS).

### Access boundary

There is **no peer-credential check** (`SO_PEERCRED`) on either OS. The boundary is the file system:

- the directory is 0700 and owned by the user (`makePrivateDirectory` narrows an existing one, and refuses a symlink or another owner's directory);
- the socket is `chmod 0600` right after `bind` (`HookServer.startOnQueue`);
- connecting to an `AF_UNIX` socket needs write permission on it, so only the user (and root) can send frames.

A peer check would add nothing against the same user: any process of that user can already write the support directory, `~/.claude` and the agents' configuration. The frames only change what a row shows. In the fallback case the support directory's own mode applies, as on the Mac.

### Socket flags

On Linux the listener is opened with `SOCK_CLOEXEC`, and connections are accepted with `accept4(SOCK_NONBLOCK | SOCK_CLOEXEC)`. A pane spawned while a hook is connected therefore never inherits the listener or a connection. Swift's Glibc module hides `accept4` (glibc declares it only under `_GNU_SOURCE`), so it is called through `tkz_accept4` in `TkzPlatformShim`. macOS keeps `accept` plus `fcntl(O_NONBLOCK)`. The server never writes to a connection, so it needs neither `SO_NOSIGPIPE` nor `MSG_NOSIGNAL`. Corelibs Dispatch does not mark sources `Sendable`, so the accept and read sources are created and resumed under the state lock, as in `Pty`.

On Linux a connection's read handler drains the socket, reading 64 KiB chunks until one comes back short. Corelibs Dispatch's epoll back-end does not signal again for bytes a handler left unread, so a hook that wrote a frame longer than one chunk (a 200 KiB `Stop` message) and closed would otherwise leave the rest in the socket and the frame would never arrive (found by `HookBinaryTests.longMessageArrivesIntactPrefixTruncated` in WOR-306 S3; `HookServerTests.aLineLongerThanOneReadChunkArrivesWhole` fails without the drain). kqueue signals again, so macOS keeps one read per event.

### Tests

- `HookSocketTests` (TkzCoreTests): on Linux, the private runtime directory and every fallback (unset, empty, relative, a file, a symlinked `tkzmux`, a missing root, and an unwritable root, which is skipped as root). On macOS, the directory is the support directory whatever `XDG_RUNTIME_DIR` says.
- `TerminalEnvironmentTests.hookSocketDirectoryFollowsTheRuntimeDirectory`: `TKZMUX_SOCKET == $XDG_RUNTIME_DIR/tkzmux/tkzmux-<pid>.sock` on Linux, the support path when the variable is unset, empty or relative, and the support path on macOS.
- `HookServerTests` on both OSes. `paneAndServerAgreeOnTheSocketDirectory` points `XDG_RUNTIME_DIR` at a temp directory, checks that the pane's `TKZMUX_SOCKET` is the server's path, checks the 0700/0600 modes, and delivers a frame there. On Linux, `listenerAndConnectionsAreCloseOnExec` checks `FD_CLOEXEC` on the listener and on an accepted connection. The test clients use `send(MSG_NOSIGNAL)` on Linux, where macOS sets `SO_NOSIGPIPE` and uses `write`.

## Liveness and ownership

`ProcessLiveness`, `ProcessOwnership` and the `SessionMemory` call sites use TkzPlatform's `ProcessTable` on both OSes; `AgentBridge.ProcessTree` is deleted (WOR-306 S3). On macOS `ProcessTable` is `LibprocProcessTable`, the same libproc code lifted verbatim, so the answers are unchanged.

### The exact pid-reuse guard

Claude Code stamps each Linux session descriptor with two fields that `ClaudeSessionInfo` now decodes:

- `procStart`: a decimal string, field 22 of `/proc/<pid>/stat` (clock ticks after boot). It matched `/proc/<pid>/stat` exactly on two live descriptors here.
- `pidDomain`: `linux:<machine-id>:pid:[<inode>]`, where the last part is `readlink /proc/self/ns/pid`. It names the pid namespace the pid belongs to.

`SystemProcessLiveness.isAlive(pid:startedAt:procStart:pidDomain:)` picks the guard (`identityCheck`), and `ClaudeSessionWatcher` calls it with the descriptor's fields:

| Descriptor | Guard |
|---|---|
| `pidDomain` equals this process's (`ownPidDomain`) and `procStart` is present | alive only if `kill(pid, 0)` does not fail with ESRCH and `ProcessTable.startTicks(of: pid) == procStart`; `startedAt` is not consulted |
| `pidDomain` present and different (a distrobox or other container sharing `~/.claude`, another machine through a synced home) | not ours: not alive |
| no `pidDomain`, no `procStart`, or no domain of our own | the one-sided 30 s `startedAt` window, as before |

`ownPidDomain` is nil on macOS, so a Mac descriptor always takes the window and Mac behaviour is unchanged. On Linux it is nil only when neither `/etc/machine-id` nor `/var/lib/dbus/machine-id` can be read. The protocol's default for the new method forwards to `isAlive(pid:startedAt:)`, so test fakes need no change. `AgentIntegration`'s launch-pid poll passes no descriptor and keeps the plain check.

`ProcessOwnership` walks `ProcessTable.parent`/`name`. On Linux pid 1 is the init system rather than launchd, and the rule is the same; names are `comm`, at most 15 bytes, on both sides of the comparison.

## Installers and paths

The installers and readers take `AppPaths.support` by default: `$XDG_DATA_HOME/tkzmux` (or `~/.local/share/tkzmux`) on Linux, `~/Library/Application Support/tkzmux` on macOS. That is `StatuslineInstaller(directory:)`, `CodexHooksInstaller(directory:)`, `StatuslineReader.standardDirectory(supportDirectory:)` and `TranscriptUsageReader.standardDirectory(supportDirectory:)`. The Mac app still hands them its own directory, which is the same path.

`ShimInstaller.standard(locator:)` builds the installer for the tkzmux a `ResourceLocator` describes. It only reads the install and only writes user data:

| | Read from (never written) | Written to |
|---|---|---|
| Shims and wrappers | the AgentBridge bundle the locator finds (`<prefix>/lib/tkzmux/tkzmux_AgentBridge.resources`), through `ShimResources.bundled(locator:)`, which has no `Bundle.module` fallback into `.build` | `AppPaths.support(environment: locator.environment)`: `bin/{claude,codex,agy}`, the wrappers, `VERSION` |
| Hook | `tkzmux-hook` beside the executable with symlinks resolved (`<prefix>/bin/tkzmux-hook`, ADR-0002) | `<support>/bin/tkzmux-hook` |

`AppPaths.support(environment:)` (new) resolves the XDG rule for an injected environment. `ShimInstaller.standardHookBinary()` takes the executable from `/proc/self/exe` on Linux, because `Bundle.main` is the test runner under `swift test`; macOS is unchanged. The atomic rename is `Glibc.rename` on Linux and `Foundation.rename` on macOS.

The wrapper resources (`Resources/{bash,fish,zsh}`) now name `<support>` for both OSes in their header comments. That edit changes `ShimInstaller.version`, so an existing install rewrites its shims and wrappers once on the next launch, on macOS too.

`ShimInstallerPrefixTests` (Linux) copies the built hook and bundle into a temporary `<prefix>`, runs the executable through a symlink with only `HOME` and `XDG_DATA_HOME` set and no resource override, and checks: `ensureInstalled()` is `.installed` then `.upToDate`; `bin/{agy,claude,codex,tkzmux-hook}`, every wrapper and `VERSION` are in `$XDG_DATA_HOME/tkzmux`; and every file under the prefix keeps its bytes, mode and mtime. It runs twice, once with a separate prefix and once with `PREFIX=$HOME/.local` and no `XDG_DATA_HOME`, where the install's `~/.local/lib/tkzmux` and the user data's `~/.local/share/tkzmux` share one `~/.local`. A prefix without a bundle is an error rather than a fall back to the build tree.

## Watchers

`ClaudeSessionWatcher` (`<configDir>/sessions/<pid>.json`), `StatuslineReader` (the `statusline` sidecars) and `TranscriptWatch` (one transcript while the prompt card is up) watch files that their writers create, rewrite in place, replace by rename and delete. On Linux all three use TkzPlatform's `FileWatcher` (`InotifyFileWatcher`). On macOS each keeps its kqueue `DispatchSource`s exactly as before, including the per-file `O_EVTONLY` source and the inode re-open after a rename-replace; `makeFileSystemObjectSource` and `O_EVTONLY` appear only under `#if os(macOS)`.

### One directory watch

| | Linux | macOS (unchanged) |
|---|---|---|
| `ClaudeSessionWatcher` | one inotify fd per watcher, one watch per `sessions` directory | a directory source per account, plus a source per live descriptor |
| `StatuslineReader` | one inotify fd, one watch on the directory | a directory source, plus a source per sidecar |
| `TranscriptWatch` | one inotify fd, one watch on the transcript's directory, filtered to its name | one source on the file |

The watch mask is `InotifyFileWatcher.eventMask`: IN_CREATE, IN_DELETE, IN_MOVED_FROM/TO, IN_CLOSE_WRITE, IN_MODIFY, IN_ATTRIB and IN_DELETE_SELF/IN_MOVE_SELF, on a directory (IN_ONLYDIR). An inotify directory watch names the entry behind every record, including in-place writes, so nothing is opened per file and nothing needs re-opening after a rename-replace. The cost is one watch per directory, whatever the number of sessions or sidecars, against `fs.inotify.max_user_watches`, and one inotify instance per watcher object against `max_user_instances`.

Each named record (filtered to `<pid>.json`, `usage-*.json`/`context-*.json`, or the transcript's name) arms that entry's debounce (100 ms; 150 ms for a transcript). The debounce settles through the same code as on macOS: `settleFile`/`settle` then `readAndApply`, or a removal when the file is gone. A create (IN_CREATE, IN_MODIFY, IN_CLOSE_WRITE), an in-place rewrite, a rename-replace (IN_MOVED_TO) and a delete therefore each produce exactly one event. On macOS a new file is read at once by the directory rescan; on Linux it goes through the debounce like every other change.

| inotify | `ClaudeSessionWatcher`, `StatuslineReader` | `TranscriptWatch` |
|---|---|---|
| a named change | arm that file's debounce | IN_MODIFY/IN_CLOSE_WRITE: fire after the debounce; IN_DELETE, IN_MOVED_FROM, or a rename over it (IN_MOVED_TO): end the watch, as IN_DELETE_SELF/IN_MOVE_SELF would on a file watch |
| a change to the directory itself | rescan the directory | ignored |
| IN_Q_OVERFLOW | rescan every directory and re-read every tracked file; only real changes are reported | fire once |
| the directory deleted or moved (IN_IGNORED, IN_MOVE_SELF) | drop the directory's entries; the sweep adds the watch again once it exists | end the watch |
| watch not added (ENOSPC, EACCES, …) | logged once per error; the sweep keeps listing the directory every `sweepInterval`, so new and removed files are still seen but in-place rewrites are not | `init` returns nil, as when the file cannot be opened on macOS |

A long-dead descriptor (`deadWatchGrace`) is released as on macOS, where releasing it closes its source: it stays in the snapshot but is no longer tracked, so a rewrite of it is ignored, and only its deletion is still acted on. `openWatchCount` counts tracked descriptors on Linux; `directoryWatchCount` (Linux only) counts inotify watches.

State stays in each type's `Mutex<Storage>`. The inotify watcher is created and changed under that lock, and it calls back on the owner's serial queue outside its own lock, so the lock order is always owner, then watcher. Corelibs Dispatch sources are not `Sendable`, so `TranscriptWatch` makes, swaps and cancels its debounce timer under its lock on both OSes.

### TranscriptWatch

`TranscriptWatch` moved from `TkzApp/Prompt/PromptCardController.swift` into AgentBridge as a public type, so the Linux views (WOR-310 S6) can use it. `PromptCardController` uses it unchanged, and on macOS its behaviour is the same: a `DispatchSource` on the file (write, extend, delete, rename), 150 ms debounce on a private utility queue, then one hop to the main actor.

### Tests

- `ClaudeSessionWatcherTests` on both OSes. `idleCostIsLow` measures CPU with `getrusage(RUSAGE_SELF)` on Linux in place of `proc_pid_rusage`; the `< 0.4 s` budget is unchanged. Linux only:
  - `eachChangeYieldsExactlyOneEvent`: create, in-place rewrite, rename-replace and delete of `<pid>.json` each give exactly one event after the debounce.
  - `watchCountDoesNotDependOnSessionCount`, the twin of the fd-retention test: with 200 sessions in one of two accounts, alive and then long dead, the watcher holds two watches, and `/proc/self/fdinfo` agrees. A released descriptor's rewrite is ignored, its deletion is not, and `stop` closes the inotify fd.
  - `aRemovedSessionsDirectoryIsWatchedAgainWhenItReturns`.
- `StatuslineReaderTests` on both OSes. On Linux the test writer publishes with `rename(2)`, because corelibs' `replaceItemAt` fails when the destination does not exist. `anUpdateArrivesWithin200Milliseconds` (Linux) uses the production 100 ms debounce. Measured: a median of 100.4 ms from `rename` to the event.
- `TranscriptWatchTests` on both OSes: a burst of appends fires once, a sibling file does not fire, a delete ends the watch, and `cancel` drops an armed debounce.
- `FileWatcherTests.descriptorsDoNotLeakOverAThousandCycles` (TkzPlatformTests) counts only the inotify fds that watch its own directories (from `/proc/self/fdinfo`), not every inotify fd of the process: in a parallel `swift test` these watchers hold inotify fds of their own in the same test process.

## Shell integration

The wrappers (`Resources/{bash,zsh,fish}`) are the same files on both OSes. WOR-306 S5 made them correct against Arch's system startup files and added one rule for all three shells.

### `$TKZMUX_BIN` first at every prompt

Each wrapper puts `$TKZMUX_BIN` first on PATH once at startup, as before, and now again before every prompt. A prompt hook the user's files installed can put its own directories in front again: mise with `activate_aggressive`, direnv. A `claude` resolved past the shim never binds its row. The re-assert is a no-op when `$TKZMUX_BIN` is already first, and builtins only.

| Shell | Hook | Runs after the user's hooks because |
|---|---|---|
| bash | first thing in `__tkzmux_precmd`, the last PROMPT_COMMAND element | mise and direnv prepend theirs; the wrapper appends after the login files ran |
| zsh | `__tkzmux_bin_first`, `add-zsh-hook precmd` in `.zshrc` | mise and direnv prepend to `precmd_functions`; `.zlogin`'s boot-command hook is appended after it |
| fish | `__tkzmux_bin_first --on-event fish_prompt` in `tkzmux.fish` | fish runs one event's handlers in definition order (checked with fish 4.9): `vendor_conf.d` (Arch's `mise-activate.fish`) and `config.fish` before `-C`, and the boot-command handler after it |

### bash on Arch

bash starts as `bash --rcfile <support>/bash/tkzmux.bashrc`, an interactive non-login shell. Three things in Arch's system files (bash 5.3, bash-completion 2.18, systemd 261) needed handling:

- **bash_completion loaded twice.** Arch's bash reads `/etc/bash.bashrc` (compiled in as SYS_BASHRC) *before* `--rcfile`, and `/etc/profile` sources it again whenever `PS1` is set (`/etc/profile`, lines 42–47). bash.bashrc's `BASHRCSOURCED` guard covers its prompt setup but not `. /usr/share/bash-completion/bash_completion`. So when bash_completion is already loaded (`BASH_COMPLETION_VERSINFO` set) on Linux, the wrapper sources `/etc/profile` with `PS1` unset and puts it back afterwards, unless the profile set one of its own. Otherwise `/etc/profile` runs with `PS1` as before: Debian and Ubuntu leave completion to `/etc/profile.d/bash_completion.sh`, which only runs with `PS1` set, and on macOS (`$OSTYPE` darwin) `/etc/profile` is what reads `/etc/bashrc`. One known difference from `bash -l` on Arch: a `SHELL_PROMPT_PREFIX`/`SUFFIX` that pam_systemd provisions from credentials is applied by `70-systemd-shell-extra.sh` to an unset `PS1`, so the prompt is the prefix alone.
- **The OSC 0 title.** For an xterm-like `TERM`, bash.bashrc appends `printf "\033]0;%s@%s:%s\007" …` to `PROMPT_COMMAND`. It replaces the title tkzmux derives from OSC 7 and counts as activity (`compressor.noteActivity`). The wrapper removes that exact element after the login files ran. A title the user's own files set is untouched.
- **OSC 3008.** `/etc/profile.d/80-systemd-osc-context.sh` adds `__systemd_osc_context_precmdline` to `PROMPT_COMMAND` and `$(__systemd_osc_context_ps0)` to `PS0`. They fork several command substitutions and a `sed` at every prompt and every command. tkzmux ignores OSC 3008, so the wrapper removes both, again by their exact text.

Measured on the reference machine on a pty, as `PROMPT_COMMAND` plus the `PS0`/`PS1` expansions, 300 prompts, three runs each:

| Shell | Per prompt |
|---|---|
| `bash --norc --noprofile` | 1 µs |
| `bash -l` (Arch's files, no tkzmux) | 8.46 ms |
| tkzmux bash before S5 | 8.51 ms |
| tkzmux bash after S5 | 12–18 µs |

The same machine's zsh and fish need nothing: Arch's `/etc/zsh/zprofile` only sources `/etc/profile` in sh emulation (the bash-only parts return early), there is no `/etc/zsh/zshrc`, and `/etc/fish/config.fish` is empty. On Arch a login zsh has no `HISTFILE` (only macOS's `/etc/zshrc` sets one), inside tkzmux and outside it.

### Tests

The tests find the shells on Linux from `/etc/shells` plus `PATH`, deduplicated by realpath (`harnessShellCandidates`), so a merged `/usr` runs each binary once. macOS keeps its fixed list (`/bin/zsh`, `/bin/bash`, Homebrew bash and fish).

- `ShellIntegrationHarnessTests`: every installed bash, zsh and fish on a real `Pty`, as before. The fixture's user files now also install a prompt hook that puts `~/.local/bin` first again at every prompt, and the PATH assertions run after it. New assertions: no OSC 0/2 title from bash or zsh (fish's default `fish_title` sends one on both OSes) and no OSC 3008 from any shell. `fishIsPresentForTheHarness` is skipped on Linux outside CI (`CI` unset), so a developer machine without fish runs what it has. Under CI a missing fish or zsh fails, as on macOS.
- `ZshWrapperTests`: the harness's first zsh rather than `/bin/zsh`, every test `.enabled(if:)` one exists. `histfileIsRedirectedToTheUsersHome` accepts an unset `HISTFILE` on Linux, and on both OSes it must never point into tkzmux's ZDOTDIR. New on both OSes: `tkzmuxBinStaysFirstAfterTheUsersPrecmdHooks`, with a mise-like precmd hook, over two prompts.
- `BashWrapperTests` (new), against the machine's own system files:
  - `bashCompletionLoadsOnce`: `SHELLOPTS=xtrace` in the environment turns tracing on before bash reads SYS_BASHRC, and the trace must hold at most one `. …/bash_completion`. Before S5 it held two.
  - `noSystemTitleOrContextReports`: the first prompts write OSC 7 and no OSC 0, 2 or 3008.
  - `perPromptOverheadIsUnderTwoMilliseconds`: tkzmux bash minus `bash --norc --noprofile`, both measured in the shell with `EPOCHREALTIME`, is under 2 ms a prompt. It is skipped for bash < 5 (macOS's `/bin/bash`). Before S5 the difference was 2.2 ms with output to `/dev/null`.

zsh and fish are not installed on the reference machine, so the Arch `zsh` 5.9.2 and `fish` 4.9.2 packages (signatures checked) were overlaid on `/usr` and `/etc` with `bwrap` for these runs, also as uid 0 like the CI container. All three fail against the wrapper as it was before S5 (checked), and so do the harness's PATH assertions for all three shells and its OSC 3008 assertion for bash. `ci-linux.yml` installs `zsh`, `fish`, `bash-completion`, `git` and `python` in the `arch` job; the `ubuntu` job already had `zsh`, `fish`, `git` and `python3`. The `arch` job then runs `--filter AgentBridgeTests` and `--filter GitStatusTests` as a separate step after the whole suite, through the same summary-line guard.

## Real agents

WOR-306 S6 ran real Claude Code 2.1.287 and codex-cli 0.160.0 through tkzmux's own pipeline on Linux, without a UI and without an account. What they sent is committed under `Tests/AgentBridgeTests/Fixtures/linux/` and replayed on every OS by `AgentFixtureReplayTests`. Antigravity (`agy`) was not installed on the reference machine, so it has no Linux run yet.

### Real-agent probe

`RealAgentProbeTests` is opt-in (`TKZMUX_REAL_AGENTS=1`). Each test runs one agent the way a pane does:

- a throwaway world under `/tmp/tkzp-*`, laid out like a user's: the project and the agents' config dirs under its HOME, `$XDG_DATA_HOME/tkzmux` and `$XDG_RUNTIME_DIR`;
- `ShimInstaller` with the **release** hook (`TKZMUX_HOOK_BIN`, else the static musl build on Linux and the release build on macOS), `StatuslineInstaller` for Claude and `CodexHooksInstaller` for Codex;
- a `HookServer` on the socket `HookSocket.directory` picks, `ClaudeSessionWatcher` through `ClaudeAdapter.makeObservationWatcher`, and `StatuslineReader`;
- the login shell from `TerminalEnvironment.loginShellSpawn` (bash, with the agent as `TKZMUX_BOOT_COMMAND`) on a real `Pty`, its output into libghostty-vt (`TerminalSession`), which answers the agents' terminal queries;
- `Fixtures/linux/fake-model-api.py` on loopback as the model API, through `ANTHROPIC_BASE_URL` with a made-up key for Claude and a custom `model_providers` entry for Codex. Every turn answers `pong`; the main turn is held for 1.5 s so the descriptor's `busy` is observable.

The probe types a prompt, waits for the turn, quits (`/exit`, `/quit`), and builds an `AgentTrace`: the launch frames, every hook frame with the event it maps to and the status `StatusDerivation` gives a row fed only those frames, the descriptor states, the statusline sidecars, and what the transcript readers find. Paths and ids are placeholders, pids and clocks are left out. The trace must equal `claude-code.trace` or `codex.trace`. Those were recorded on Linux; the same run on macOS against the same files is the Linux-equals-macOS check.

On Linux the probe refuses to run unless `lo` is the only network interface, so nothing an agent does at startup (update checks, telemetry, the Codex daemon's updater) can leave the machine. Run it in a network namespace of its own; the read-only binds are a second guard for the real config dirs, which the probe never names:

```sh
swift build --build-system native -c release --product tkzmux-hook --swift-sdk x86_64-swift-linux-musl
swift build --build-system native --build-tests
TKZMUX_REAL_AGENTS=1 bwrap --dev-bind / / --unshare-net \
    --ro-bind "$HOME/.claude" "$HOME/.claude" --ro-bind "$HOME/.codex" "$HOME/.codex" -- \
    .build/debug/tkzmuxPackageTests.xctest --testing-library swift-testing --filter RealAgentProbeTests
```

The first line is the static hook ([hook.md](hook.md#building-it-locally) has the SDK setup); leave out a `--ro-bind` whose directory does not exist. `claude` and `codex` are found on the test's PATH and the pane's PATH names the directory of the real binary, so mise's shims are not involved; tkzmux's own shims still come first, as in the app. Add `TKZMUX_REAL_AGENTS_CAPTURE=<dir>` to also write the fixtures (`Fixtures/linux/README.md`), `TKZMUX_REAL_AGENTS_KEEP=1` to keep the world of a passing run. `TKZMUX_REAL_AGENTS_ALLOW_NETWORK=1` skips the namespace check. macOS has no namespace check: there the loopback endpoints and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_AUTOUPDATER` and `DISABLE_TELEMETRY` are the only guards, and Codex's daemon may still look for updates.

Measured on the reference machine: the four tests take 20 s together and passed eight runs in a row.

### Claude Code 2.1.287

The Linux trace has the shape the Mac code expects, so nothing in AgentBridge changed for it:

- **Hooks**: `SessionStart` (source `startup`), `UserPromptSubmit`, `Stop` (with `last_assistant_message` and an empty `background_tasks`), `SessionEnd` (reason `prompt_input_exit` for `/exit`). Each is run through `sh -c`, which execs the hook, so the hook's parent is Claude Code itself: the probe checks `ppid` equals the launch pid on every frame.
- **Descriptor**: `sessions/<pid>.json` goes `idle`, `busy`, `idle`, then is removed on exit. It carries `procStart` and `pidDomain` (the S3 guard) and a `messagingSocketPath` under `$XDG_RUNTIME_DIR/cc-socks`.
- **Statusline**: one sidecar at startup and one after the turn, model `Opus 5.5`, account key `claude` from the config dir.
- **Transcript**: `<config>/projects/<slug>/<id>.jsonl`, the slug being the cwd with every character that is not a letter or digit turned into `-`, the same rule as on macOS. `TranscriptReader` finds it and reads the first prompt and the recap; `TranscriptUsageReader` sums the fake API's tokens.

#### `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`

`claudeCodeHooksSurviveTheSubprocessEnvScrub` runs the same session with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` and gets the same trace. Measured with a hook that dumps its environment: the scrub removes `ANTHROPIC_API_KEY`, `AWS_SECRET_ACCESS_KEY` and `SSH_AUTH_SOCK` from what hooks and the statusline command get, and keeps `TKZMUX_SOCKET`, `TKZMUX_SESSION_ID`, `TKZMUX_BIN`, `TKZMUX_AGENT`, `WAYLAND_DISPLAY`, `ANTHROPIC_BASE_URL` and `GH_TOKEN`. `TerminalEnvironment` strips every inherited `CLAUDE_CODE_*` variable, so the scrub applies only when the user's own shell files or Claude Code's `settings.json` `env` set it.

#### The environment lists (WOR-305)

The Claude test hands the pane `WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`, `SSH_AUTH_SOCK` and `XDG_ACTIVATION_TOKEN`, and no `LANG`, then reads `/proc/<pid>/environ` of the running Claude Code: the first three arrive unchanged, the activation token does not, and `LANG` is `TerminalEnvironment.fallbackLanguage` (`en_US.UTF-8` here, where that locale is generated).

### codex-cli 0.160

Codex 0.160 runs its sessions in an **app-server daemon**. The first `codex` started for a `CODEX_HOME` starts it, every later TUI connects to it, and it keeps running after `/quit` ("Disconnected from this task. Any running work continues."). It runs from a copy of Codex it installs under `CODEX_HOME/packages/app-server-daemon/`, and a `pid-update-loop` process started from that copy outlives the daemon itself; the probe kills both. The daemon runs the hooks. The probe opens two panes on one `CODEX_HOME`, one turn each, and the trace shows what follows from that:

- **Attribution.** Every hook frame carries the *first* pane's `TKZMUX_SESSION_ID`, because the daemon has the first pane's environment, and its `ppid` is the daemon (checked against `app-server-daemon/daemon.pid`), not the pane's `codex`. In the app the second pane's events would land on the first pane's row. This is codex-cli behaviour and not Linux-specific. `codex exec` still runs hooks in its own process (measured on 0.160: the hook's parent is the `codex exec` process, and `SessionEnd` fires when it exits), which is how the macOS fixtures were captured on 0.155.
- **SessionStart** runs when a thread's first turn starts, together with `UserPromptSubmit`, not when the TUI opens.
- **SessionEnd** runs for every thread when the daemon stops (the probe sends it SIGTERM), not on `/quit`. Its reason is `other`, as on 0.155.
- **notify** (`notify = ["<support>/bin/tkzmux-hook", "notify-argv"]`) runs twice per turn: once for the turn and once for the title Codex generates on a side thread. The payload carries a `client` field: `codex-tui` from the TUI, `codex_exec` from `codex exec`.
- **Rollouts** are `sessions/<yyyy>/<mm>/<dd>/rollout-<time>-<id>.jsonl` as before, and `CodexTranscriptReader.locate` finds them. Its first prompt is the `<environment_context>` block 0.160 writes as the first user message, a case its own comment already leaves to a later ticket.

#### Hooks run outside the sandbox

Codex runs hooks outside its sandbox, as its documentation says. Measured: in a hook's environment `CODEX_SANDBOX` and `CODEX_SANDBOX_NETWORK_DISABLED` are unset, its parent is the daemon rather than a sandboxed command, and every frame reaches the `AF_UNIX` socket under `$XDG_RUNTIME_DIR/tkzmux`. The sandbox risk from the research is moot.

#### Trust

Trusting happens in Codex's TUI: the first start after `CodexHooksInstaller` wrote `hooks.json` shows *Hooks need review*, and the probe answers *Trust all and continue*. Codex 0.160 then writes the ledger into **`config.toml`**, one table per hook:

```toml
[hooks.state."<CODEX_HOME>/hooks.json:stop:0:0"]
trusted_hash = "sha256:…"
```

The key is the absolute path of `hooks.json` plus the event and the group and entry index; the hash covers the command, so it changes with the absolute hook path (two worlds with different roots got different hashes for the same event). There is no `hooks.state` file any more, so `CodexHooksDetection.trust` stays `.unknown` on 0.160 (`linuxHooksJSONAndTrustLedgerDetect`). The `[hooks.state…]` headers are single-bracket tables and do not count as `configTomlHasHooks`.

#### `[features] hooks = false`

On 0.160 the `hooks` feature is on by default (`codex features list`: `hooks stable true`), and an explicit `false` switches every hook off, ours included. `CodexHooksDetection.hooksFeatureDisabled` reports it. It reads the three TOML spellings (`[features]` / `hooks = false`, `features.hooks = false`, `features = { hooks = false }`), and `codexHooksFeatureFlagAgreesWithTheInstaller` checks each against `codex features list`. It is model only: no Mac UI reads it yet, the installer never writes the flag, and nothing advises setting it to `true`.

### OSC 3008

libghostty-vt has no handler for OSC 3008, so systemd's context reports vanish: `osc3008ContextReportsAreIgnored` (TkzTerminalCoreTests) feeds the shell, command and three kinds of end reports in the shapes Arch's `80-systemd-osc-context.sh` prints and finds no event, no title or pwd change, no reply and an empty screen, with the parser back in ground state for the OSC 7 that follows. The bash wrapper still unhooks them (S5), because they cost forks at every prompt.

### Dotfile sync

Three files carry the absolute path of the hook in the support directory, which differs per OS (`~/Library/Application Support/tkzmux` on macOS, `~/.local/share/tkzmux` on Linux):

- `~/.claude/settings.json`: the statusline command (`StatuslineInstaller`);
- `~/.codex/hooks.json`: every hook command (`CodexHooksInstaller`);
- `~/.codex/config.toml`: Codex's own trust hashes over those commands.

Claude Code's hooks are injected per invocation (`--settings`) and are not affected. When these files are synced between a Mac and a Linux machine (a dotfile manager, a synced home), each side's tkzmux finds the other's path, reports it as `.stale`, and `repair` points it back at its own; the other side then does the same. For Codex each rewrite changes the command, so the trusted hash no longer matches and Codex stops running the hooks until the user trusts them again, on whichever machine rewrote last. Until there is an OS-neutral spelling (follow-up below), keep these keys out of the sync, or sync only one OS's copy.

### Follow-ups

Found or confirmed by S6, to be filed:

- **Exec-form hook injection.** `settings-merge` injects shell-form hooks (`"<bin>/tkzmux-hook" <Event>`), which Claude Code runs through `sh -c` (bash on Arch; the WOR-300 research measured about 0.5 ms per hook for it). With `"command": "<bin>/tkzmux-hook", "args": ["<Event>"]` Claude Code spawns the hook directly. Needs a minimum Claude Code version check; applies to both OSes.
- **Scrub regression guard.** `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` keeps `TKZMUX_*` today (2.1.287). The scrub list is Claude Code's and may grow; rerun `claudeCodeHooksSurviveTheSubprocessEnvScrub` on Claude Code upgrades, and if `TKZMUX_*` ever goes, pass the socket and session on the hook command line instead.
- **Codex daemon attribution.** With 0.160's shared daemon, `TKZMUX_SESSION_ID` and `ppid` no longer identify the pane. Attribute Codex frames by `session_id` (the thread), bound to a pane by something the pane knows, and handle `SessionStart` arriving at the first turn and `SessionEnd` only when the daemon exits. The daemon also lives outside any pane's process tree (WOR-321's per-session cgroup).
- **Codex trust ledger.** Read `[hooks.state."<hooks.json>:…"]` from `config.toml` for `CodexHooksTrustState` on 0.160 and later.
- **Codex first prompt.** Skip the `<environment_context>` user message in `CodexTranscriptReader`.
- **OS-neutral hook path** for the dotfile-sync collision above, for example `$HOME/.local/share/tkzmux/bin/tkzmux-hook` on both OSes.
- **corelibs `Process` and the signal mask.** On Linux a child started by Foundation's `Process` inherits the starting thread's blocked-signal mask; the probe's fake API server had SIGTERM blocked and ignored `terminate()`. `GitProcess` and `UserPath` stop a child with `terminate()` on a timeout, which then does nothing. `TkzPtyShim` already clears the mask for panes.
