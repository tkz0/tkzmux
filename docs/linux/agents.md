# AgentBridge on Linux

How the agent side of tkzmux (hook socket, watchers, liveness, installers, shell integration) runs on Linux, and what real Claude Code, Codex and Antigravity sessions produce there. Created in WOR-306 S1, which covers the hook socket. WOR-306 S2-S6 add the watchers, liveness and installers, shell integration, and the real-agent probe traces and dotfile-sync notes.

## Bring-up

AgentBridge joined the Linux graph a file at a time. Until WOR-306 S3, `Package.swift` listed the sources that built on Linux and the tests that ran on them and excluded the rest. Since S3 every source builds, so AgentBridge is a shared target, with its resources (`shim`, `zsh`, `bash`, `fish`) on both OSes and `TkzPlatformShim` linked on Linux only. The Linux `AgentBridgeTests` target runs every test file except `ShellIntegrationHarnessTests` and `ZshWrapperTests` (`agentBridgeTestsLinuxExcludes`), which need zsh and fish and are ported in S5.

| Session | Linux sources | Linux tests |
|---|---|---|
| WOR-306 S1 | `HookFrame.swift`, `HookServer.swift` | `HookServerTests` (plus the hook's own `HookHygieneTests` and `HookSupportPathTests` from WOR-305) |
| WOR-306 S2 | `ClaudeSessionWatcher.swift`, `StatuslineReader.swift`, `TranscriptWatch.swift` (new), and what they need to build: `AgentAdapter.swift`, `ProcessLiveness.swift`, `QuotaReconciler.swift`, `PromptCommand.swift`, `TranscriptReader.swift`, `TranscriptSearch.swift`, `TranscriptUsageReader.swift`, `Claude/ClaudeSessionInfo.swift`, `Codex/CodexUsageExtractor.swift` | `ClaudeSessionWatcherTests`, `StatuslineReaderTests` (with `StatuslineTestSupport.swift`, split out of `StatuslineTests` so the reader tests build without `StatuslineInstaller`), `TranscriptWatchTests` |
| WOR-306 S3 | everything else: the adapters and mappers, `ProcessOwnership.swift`, `ShimInstaller.swift`, `StatuslineInstaller.swift`, `UserPath.swift`, `ModuleResources.swift`, `Codex/*`, `Antigravity/*` | everything but the shell harness and the zsh wrapper tests |

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
