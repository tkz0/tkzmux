# TkzPlatform on Linux

The OS seam below the UI (`Sources/TkzPlatform/`): one API per primitive, a back-end per OS. The Darwin back-ends live in `Darwin/` and the Linux ones in `Linux/`. Written in WOR-304 S2 (logging and signposts) and extended in WOR-304 S3 (paths), S4 (SHA-256 and clocks), S5 (file and process-exit watching) and S6 (the process table and listening ports).

## Logging: `TkzLogger`

On macOS `TkzLogger` is `os.Logger` (WOR-304 S1). On Linux it is a `Sendable` struct with the same call shape, so a call site compiles unchanged on both OSes:

- `TkzLogger(subsystem:category:)`, and `debug`, `info`, `notice`, `warning`, `error` and `fault`;
- interpolation takes `privacy: .public`, `.private` or `.auto` (the default).

### Redaction

Linux redacts like the Mac's defaults, so a line reads the same in `journalctl` and `log stream`:

| Interpolated value | `.public` | `.auto` | `.private` |
|---|---|---|---|
| integer, `Double`, `Float`, `Bool` | shown | shown | `<private>` |
| `String` or any other `CustomStringConvertible` | shown | `<private>` | `<private>` |

- `TKZMUX_LOG_PRIVATE=1` shows every value. It is read once, at the first log line.
- A redacted value's autoclosure is never evaluated.

### Sinks

There is no libsystemd. Each line is one datagram in the [journal native protocol](https://systemd.io/JOURNAL_NATIVE_PROTOCOL/), sent to `/run/systemd/journal/socket`.

- **Fields.** Each datagram carries `MESSAGE`, `PRIORITY`, `SYSLOG_IDENTIFIER=tkzmux` and `TKZ_CATEGORY`.
  - A value that contains a newline is length-framed: `KEY\n`, a little-endian UInt64 length, the value, then `\n`.
  - The levels map to `PRIORITY` as follows: debug 7, info 6, notice 5, warning 4, error 3, fault 2.
- **Never blocking.** Sends use `MSG_DONTWAIT`, and a line that would block (`EAGAIN`) is dropped. `MESSAGE` is cut at 16 KiB on a UTF-8 boundary, so a datagram never needs the protocol's memfd path.
- **Choosing the sinks.** They are chosen once per process:

  | Journal socket | stderr | Lines go to |
  |---|---|---|
  | present | is the journal stream (`$JOURNAL_STREAM` names fd 2's `dev:ino`, as under uwsm or a systemd unit) | the journal only, so nothing is logged twice |
  | present | anything else (a terminal, a pipe) | the journal and stderr |
  | missing | any | stderr only |

  - A send that fails with anything other than `EAGAIN` (for example, journald being down) writes that line to stderr instead.
  - On stderr a line reads `tkzmux[<category>] <level>: <message>`. When stderr is the journal stream it also gets a `<priority>` prefix, which journald parses.
  - stderr is written with one `write(2)` per line, never through `FILE *stderr`.

### Checking by hand

CI runners may have no user journal, so these checks are run locally only:

```sh
journalctl --user -t tkzmux -o verbose      # each line once, with PRIORITY and TKZ_CATEGORY
journalctl --user -t tkzmux -p warning      # filter by level
```

On 2026-10-03 a probe binary that logs one line per level was run on the reference machine, in two ways:

- From a shell, where stderr is a pipe: `journalctl --user -t tkzmux` showed the 6 lines once each, with priorities 7 to 2. The multi-line value arrived intact, and the private string showed as `<private>`.
- Under `systemd-run --user -p StandardError=journal -E TKZMUX_LOG_PRIVATE=1`: the same 6 lines appeared, all with `_TRANSPORT=journal`. There were no `stdout` transport duplicates, and the string was shown.

## Signposts: `TkzSignposter`

On macOS `TkzSignposter` is `OSSignposter`. On Linux it is a struct with the same calls: `makeSignpostID()`, `beginInterval(_:id:)`, `endInterval(_:_:)` and `emitEvent(_:id:)`. `TkzSignpostID` and `TkzSignpostIntervalState` name the id and state types on both OSes.

- **Off by default.** A disabled signpost costs one relaxed atomic load.
- **`TKZMUX_TRACE=<file>`.** If this is set when the first signposter is created, the file is created or truncated and receives Chrome trace JSON in the object format: `{"displayTimeUnit":"ms","traceEvents":[…]}`.
  - Intervals are nestable async pairs (`"ph":"b"`/`"e"`), keyed by category and signpost id, because a begin and its end may run on different threads.
  - Events are thread instants (`"ph":"i"`).
  - `ts` is `CLOCK_MONOTONIC` in microseconds, and `tid` is the kernel thread id.
- **Always valid JSON.** Each event overwrites the closing `]}` and writes a new one, so the file stays loadable even if the process is killed.
- **Viewing a trace.** Open the file in [ui.perfetto.dev](https://ui.perfetto.dev) or `chrome://tracing`. On 2026-10-03 a probe trace loaded in Perfetto's `trace_processor_shell` v57.2, the engine behind the UI, with no error or data-loss stats. It showed 3 `show` slices of 2, 4 and 6 ms, and the process named `tkzmux`.

## Paths: `AppPaths`

`AppPaths` (`Sources/TkzPlatform/AppPaths.swift`) names tkzmux's own directories on both OSes. It applies [ADR-0002](adr-0002-platform-defaults.md) D7. Nothing in it creates a directory, except `runtime` on Linux.

| Root | Holds | Linux | macOS (unchanged) |
|---|---|---|---|
| `home` | – | `$HOME` if absolute, otherwise `pw_dir` from `getpwuid` (`/` if neither is absolute) | `NSHomeDirectory()` |
| `support` | user data: `state.json`, `sessions/`, `usage/`, `statusline/`, `bin/`, `zsh/`, `terminfo/` | `$XDG_DATA_HOME/tkzmux`, default `~/.local/share/tkzmux` | `.applicationSupportDirectory/tkzmux`, falling back to `~/Library/Application Support/tkzmux` |
| `cache` | regenerable files | `$XDG_CACHE_HOME/tkzmux`, default `~/.cache/tkzmux` | `.cachesDirectory/tkzmux` (`~/Library/Caches/tkzmux`) |
| `runtime` | per-login files: the hook socket ([agents.md](agents.md#hook-socket), WOR-306 S1) | `$XDG_RUNTIME_DIR/tkzmux`, created 0700; `support` if that is unavailable | `support` |

- **Ignored XDG values.** An XDG variable that is unset, empty or relative is ignored, as the Base Directory spec requires, and the default applies. Each variable is judged on its own.
- **No `state` root.** `$XDG_STATE_HOME` is not used. If WOR-320 wants it for `update.log`, WOR-320 adds the root and names the file.
- **Disjoint from the install tree.** `support` never overlaps the installed read-only tree, `<prefix>/lib/tkzmux/` (ResourceLocator). That holds even with `PREFIX=$HOME/.local`, so `make install` and `ShimInstaller` never write each other's `terminfo/` or `bin/`.
- **The runtime directory is private.** `runtime` is created with `mkdir(…, 0700)`. An existing entry must be a real directory (not a symlink) owned by the effective uid, and it is narrowed to 0700. It must also be writable (`access(W_OK|X_OK)`, which catches a read-only mount). `$XDG_RUNTIME_DIR` itself is never created. Anything else falls back to `support`, which matches the Mac. `privateRuntimeDirectory(environment:)` is the same check for a given environment, returning nil instead of falling back; `HookSocket.directory` uses it (WOR-306 S1).
- **Tilde abbreviation.** `AppPaths.abbreviatingHome(_:)` replaces `NSString.abbreviatingWithTildeInPath`, which corelibs Foundation does not have. On the Mac it still calls that method, so the output is the same as before. On Linux it writes `~` for `home` and `~/…` for paths under it, and leaves every other path unchanged.
- **Who routes through it.** `StateFile.standard()` and `SnapshotStore.standard()` take `support` (their `applicationSupport:` injection is unchanged). The tilde sites in `MainWindowController` use `abbreviatingHome`. The hook's Foundation-free mirror of this table moved in WOR-305 S5, and the socket in WOR-306 S1 (`HookSocket.directory`). The rest of the support-directory users move in WOR-306.
- **`TKZMUX_SUPPORT_DIR`.** `AppPaths` does not read it, because the Mac app never has. It is still the hook's override (`Sources/tkzmux-hook/StatuslineCommand.swift`).

### Why not `FileManager` and `NSHomeDirectory()` on Linux

This was checked on 2026-10-03 with a probe built by Swift 6.3.3 (corelibs Foundation) on the reference machine:

| Environment | `NSHomeDirectory()` | `.applicationSupportDirectory` |
|---|---|---|
| default | `/home/<user>` | `/home/<user>/.local/share` |
| `HOME=/tmp` | `/home/<user>`, so `$HOME` is ignored | `/home/<user>/.local/share` |
| `HOME=` (empty) or unset | `/home/<user>` | `/home/<user>/.local/share` |
| `XDG_DATA_HOME=/xd` | `/home/<user>` | `/xd` |
| `XDG_DATA_HOME=reldata` | `/home/<user>` | `/home/<user>/.local/share` |
| `HOME=rel XDG_DATA_HOME=reldata` | `/home/<user>` | `<cwd>/rel/.local/share` |

- `NSHomeDirectory()` and `homeDirectoryForCurrentUser` ignore `$HOME` and always answer from the account database. This confirms the research's inferred claim.
- `.applicationSupportDirectory` honours an absolute `$XDG_DATA_HOME`. When `$XDG_DATA_HOME` is relative, though, it falls back to the raw `$HOME`, even when `$HOME` is relative too.
- `NSString.abbreviatingWithTildeInPath` does not exist in corelibs Foundation at all.

So on Linux `AppPaths` resolves the table itself, from `ProcessInfo.processInfo.environment` and `getpwuid`, as a pure function (`AppPaths.xdgLayout`). That function is table-tested on both OSes (`Tests/TkzPlatformTests/AppPathsTests.swift`). On the Mac, `Tests/PersistenceTests/StandardLocationTests.swift` compares `StateFile.standard()`, `SnapshotStore.standard()` and `AppPaths.support` with the code they replaced, kept verbatim in the test.

## Hashing: `SHA256`

`SHA256` (`Sources/TkzPlatform/SHA256.swift`) is FIPS 180-4 SHA-256 in plain Swift. Both OSes use it, so the Mac no longer imports CryptoKit anywhere.

- **CryptoKit's call shape.** It has `init()`, `update(data:)`, `update(bufferPointer:)`, `hash(data:)`, and a non-mutating `finalize()` that returns a digest. The digest is a `Sequence` of 32 bytes, and its `description` is lowercase hex. `ShimInstaller` switched by changing its import, and nothing else.
- **No reinstall.** `ShimInstaller.version` hashes the same bytes as before, so the digest in an installed `VERSION` file still matches. `Tests/AgentBridgeTests/ShimVersionGoldenTests.swift` pins two versions, without and with a hook binary. Their digests were computed outside Swift, with Python's `hashlib`.
- **Checked against.** `Tests/TkzPlatformTests/SHA256Tests.swift` and `SHA256CryptoKitTests.swift` run these checks:
  - all 129 NIST CAVP SHAVS byte-oriented short- and long-message vectors (`Fixtures/SHAVS`, with provenance in its README);
  - the FIPS 180-4 examples, including one million `a`s;
  - seeded random inputs split at random `update` boundaries;
  - on the Mac, 1,000 random inputs compared with CryptoKit.
- **Fast enough.** Words are read with unaligned big-endian loads, and the message schedule lives in a stack allocation. On the reference machine (x86_64, Swift 6.3.3, `-O`), 1 MB hashes in a median of 2.2 ms. The test fails a release build (`swift test -c release`) above 10 ms. A debug build only prints its time, about 110 ms.
- **Not for secrets.** It is not constant-time. tkzmux uses it only to notice when its own files change.

## Clocks: `Clocks`

| | Stops while asleep | Keeps counting while asleep |
|---|---|---|
| API | `Clocks.monotonicNanos` | `Clocks.bootNanos` |
| Linux | `CLOCK_MONOTONIC` | `CLOCK_BOOTTIME` |
| macOS | `CLOCK_UPTIME_RAW` (`mach_absolute_time`) | `CLOCK_MONOTONIC_RAW` (`mach_continuous_time`) |

- `monotonicNanos` is the clock that `DispatchTime.now().uptimeNanoseconds` reads on both OSes, so intervals agree with Dispatch deadlines. The Linux signposter timestamps through it.
- `bootNanos` counts suspend, so it is the one for start times and sleep/wake gaps (WOR-320). On Linux it agrees with `/proc/uptime`. Read after `monotonicNanos`, it is never smaller.
- Neither is wall time, and neither carries across a reboot.

## File watching: `FileWatcher`

`FileWatcher` (`Sources/TkzPlatform/FileWatcher.swift`) reports changes to the entries of watched directories. One watcher holds many watches and calls one handler, on a queue its owner gives it. `SystemFileWatcher` is the back-end for the OS being built. ClaudeSessionWatcher, StatuslineReader and TranscriptWatch move onto it in WOR-306.

- **Directories only.** A watch follows an inode, so a watch on a file would stay on the old file after an atomic rename-replace. The directory sees the rename instead. To watch one file, watch its directory with a name filter.
- **Name filters.** Each watch has a filter, and only entries it accepts are reported. Filters run outside the watcher's lock, so a filter may call back into the watcher.
- **Events.**

  | Event | Meaning |
  |---|---|
  | `.changed(change)` | `change.name` was created (or renamed in, including a rename that replaces it), modified, had its attributes changed, or was removed (or renamed out). A nil name means "something in this directory changed: rescan it". |
  | `.overflow` | The kernel dropped events. Rescan every watched directory; the watches are intact. |
  | `.watchRemoved(id)` | The directory was deleted, renamed away or unmounted. The watch is gone; add it again once the directory is back. `remove(id)` does not produce this. |

- **Errors** are typed (`FileWatcherError`): `.watchLimitReached` (ENOSPC), `.instanceLimitReached` (EMFILE/ENFILE), `.noSuchDirectory`, `.notADirectory`, `.permissionDenied`, `.alreadyWatched` (the same inode, whatever the path), `.cancelled` and `.system(errno)`.

### Linux: inotify

`InotifyFileWatcher` (`Linux/InotifyFileWatcher.swift`) uses one inotify fd per watcher (`IN_NONBLOCK|IN_CLOEXEC`), drained by a dispatch read source on the owner's queue. Each watch is added with `IN_ONLYDIR|IN_MASK_CREATE` (Linux 4.18) and this mask:

| inotify event | Reported as |
|---|---|
| `IN_CREATE`, `IN_MOVED_TO` | `.created` |
| `IN_MODIFY`, `IN_CLOSE_WRITE` | `.modified` (in-place rewrites need no per-file watch) |
| `IN_ATTRIB` | `.attributes` |
| `IN_DELETE`, `IN_MOVED_FROM` | `.removed` |
| `IN_DELETE_SELF` | nothing; the `IN_IGNORED` that follows reports it |
| `IN_MOVE_SELF` | the watch is removed, then `.watchRemoved`: the path no longer names the directory |
| `IN_IGNORED` | `.watchRemoved`, unless `remove` asked for it |
| `IN_Q_OVERFLOW` (`wd == -1`) | `.overflow` |

- Records are variable length, so they are parsed with unaligned loads by a pure function that the tests feed synthetic buffers.
- `IN_ISDIR` sets `change.isDirectory`.
- The kernel limits are per user: `fs.inotify.max_user_watches` (524,288 on the reference machine) and `max_user_instances` (1,024 there, and 128 on many distributions). Share one watcher per owner rather than making one per directory.

### macOS: kqueue

`KqueueFileWatcher` (`Darwin/KqueueFileWatcher.swift`) keeps the vnode-source approach ClaudeSessionWatcher already uses:

- one `O_EVTONLY` source on the directory, whose events are reported with a nil name. The watcher also rescans the directory itself and reports accepted names that appeared (`.created`) or vanished (`.removed`);
- one `O_EVTONLY` source on every entry the filter accepts, because a directory vnode does not see a file rewritten in place. After an entry event the path is checked again: gone is `.removed`, a new inode (rename-replace) is `.created` and the source is re-opened on it, and anything else is `.modified` or `.attributes`.

Every accepted entry costs one fd and one kqueue registration, so filters should be narrow.

## Process exits: `ProcessExitWatcher`

`ProcessExitWatcher` (`Sources/TkzPlatform/ProcessExitWatcher.swift`) calls a handler once, on the watcher's queue, when a process exits. A process that has already exited, whether a zombie or gone altogether, is reported straight away. `SystemProcessExitWatcher` is the back-end for the OS being built.

- **It never reaps.** The owner calls `waitpid(pid, &status, WNOHANG)` in the exit handler, or its child stays a zombie. That keeps the exit status with the owner, and the watcher also works for processes that are not the owner's children.
- **Foreign pids.** A pid that is not the owner's child can be reused once its parent reaps it. Check its start time (`ProcessTable.startTicks`, below) before trusting it.
- **Linux** (`Linux/PidfdProcessExitWatcher.swift`): `pidfd_open` (Linux 5.3 or later; ENOSYS is `.unsupported`), wrapped in a dispatch read source. A pidfd stays readable after the exit, so the first event cancels the source, and its cancel handler closes the fd. ESRCH from `pidfd_open` means the process is already gone, which is reported as an exit.
- **macOS** (`Darwin/KqueueProcessExitWatcher.swift`): a NOTE_EXIT process source. kqueue never reports a process that exited before the registration, so the queue checks once after it, as Pty does. `waitid(WNOWAIT)` sees an exited child without reaping it, and `kill(pid, 0)` failing with ESRCH sees any other process that no longer exists.
- **Not for the pty child.** Pty keeps its own pidfd from `clone3` (WOR-305) and does not open a second one through here.

### The C shim: `TkzPlatformShim`

Swift's Glibc module has no `<sys/pidfd.h>`, and the variadic `syscall()` cannot be called from Swift. `Sources/TkzPlatformShim` therefore wraps `tkz_pidfd_open` and `tkz_pidfd_send_signal`. Both call `syscall()` directly, because the glibc wrappers need glibc 2.36, which is above the 2.35 floor. It also wraps `tkz_accept4` for `HookServer` (WOR-306 S1): glibc declares `accept4` only under `_GNU_SOURCE`, so the Glibc module does not see it. The target uses libc only, and it is empty on macOS. WOR-320 adds `tkz_spawn_clean` to it.

### Measured

On 2026-10-03, on the reference machine (Swift 6.3.3, debug build, `swift test --filter TkzPlatformTests`):

- The exit event arrived a median of 0.03 ms after `kill(SIGKILL)`, and at most 0.1 ms over 20 kills. The test budget is 50 ms for CI runners, and the local target was under 5 ms. Pinned to one CPU (`taskset -c 0`), the maximum was 0.07 ms.
- Holding the delivery queue while 9,192 files were created (18,384 events, against `max_queued_events` 16,384) produced `.overflow`, and the watch kept reporting afterwards.
- 100 children, each reaped from its own exit event, left none behind in `/proc/self/task/*/children`. With the reap removed, the same check failed with 100 zombies.
- The numbers of `anon_inode:inotify` and `anon_inode:[pidfd]` entries in `/proc/self/fd` were back at their starting values after 1,000 add/remove cycles, 1,000 whole watchers and 2,000 pidfd watches. The test counts these two kinds rather than every fd, so files opened by Swift Testing or by parallel suites do not move the count.

## Processes: `ProcessTable`

`ProcessTable` (`Sources/TkzPlatform/ProcessTable.swift`) answers read-only questions about other processes. It replaces `AgentBridge.ProcessTree` (deleted in WOR-306 S3, whose callers ProcessLiveness, ProcessOwnership and SessionMemory now use it) and the private walk in GitStatus's `PortScanner` (WOR-306 S4). Each back-end conforms to `ProcessTableBackend`, so both are held to one signature, and `ProcessTable` names the one for the OS being built.

| Call | Linux (`Linux/ProcfsProcessTable.swift`) | macOS (`Darwin/LibprocProcessTable.swift`) |
|---|---|---|
| `children(of:)` | `/proc/<pid>/task/*/children`; a scan of `/proc/*/stat` for the ppid when the kernel has no children files | `proc_listchildpids` |
| `descendants(of:maxDepth:maxProcesses:)` | breadth first over `children`, bounded by `maxProcesses` (512); shared code | the same |
| `parent(of:)` | field 4 of `/proc/<pid>/stat` | `pbi_ppid` |
| `name(of:)` | `/proc/<pid>/comm`, at most 15 bytes | `proc_name`, at most 2 × MAXCOMLEN |
| `startTicks(of:)` | field 22 of `/proc/<pid>/stat`: clock ticks after boot | `pbi_start_tvsec` and `pbi_start_tvusec` in microseconds since 1970 |
| `startTime(of:)` | `btime` from `/proc/stat` + `startTicks` / `sysconf(_SC_CLK_TCK)` | `pbi_start_tvsec` |
| `exe(of:)`, `cwd(of:)` | `readlink` of `/proc/<pid>/exe` and `cwd`, without ` (deleted)` | `proc_pidpath`; PROC_PIDVNODEPATHINFO |

- **Best-effort.** Nothing throws. A process that exits mid-call, or that may not be inspected (another user's under `hidepid`, where reads fail with EACCES), reads as nil or as having no children.
- **Parsed from the last `)`.** `stat` puts `comm` in parentheses, and `comm` may hold spaces and parentheses itself. Fields are therefore counted from after the last `)`, so a process named `a) b (c` parses correctly.
- **The children files.** Each thread has its own `children` file, listing the children it forked, so all of `task/*` is read. Kernels built without `CONFIG_PROC_CHILDREN` have none; whether they exist is decided once, from this process's own main thread. Without them, every `/proc/<n>/stat` is read instead.
- **An exact pid-reuse check.** `startTicks` is the value Claude Code writes as `procStart` in `~/.claude/sessions/<pid>.json` on Linux, so a descriptor can be matched to its process exactly. `startTime` is good to about a second (`btime` is whole seconds, ticks are 10 ms), which is enough for the existing 30 s window. On macOS `startTicks` is only an identity token: equal values for one pid mean the same process. Values are not comparable across OSes or reboots.
- **Deleted executables.** After an auto-update replaces the running executable, the kernel appends ` (deleted)` to the `exe` link. `exe` strips it, so the path is the one the process started from.

## Listening ports: `ListeningPorts`

`ListeningPorts.scan(pids:)` (`Sources/TkzPlatform/ListeningPorts.swift`) returns the TCP ports each pid listens on, over IPv4 and IPv6, as `ListeningSocket(port:pid:)`. Results are grouped by pid in the order given, ports ascend within a pid, and an IPv4 and an IPv6 listener on one port by one process count once. GitStatus's `PortScanner` keeps its tree walk, its one-owner-per-port rule and the process names, and moves onto this in WOR-306.

- **Linux** (`Linux/ProcfsListeningPorts.swift`): `/proc/<pid>/net/tcp` is the table of the whole network namespace, not of one process. So a scan reads `/proc/self/net/tcp` and `tcp6` once, keeps the rows whose state is LISTEN (`st` `0A`) as a map from socket inode to port, and joins it with each pid's `/proc/<pid>/fd` links (`socket:[<inode>]`).
  - A process in another network namespace, such as a container, reports no ports.
  - Only this user's processes can be read, which is all tkzmux asks about.
- **macOS** (`Darwin/LibprocListeningPorts.swift`): each pid's fds through PROC_PIDLISTFDS and PROC_PIDFDSOCKETINFO, lifted from `PortScanner`.
- **A socket held by several processes** (an inherited listener) is reported for each of them, as `ss -ltnp` does.

### Measured

On 2026-10-03, on the reference machine (Swift 6.3.3):

- **Matches `ss -ltnp`.** `ListeningPortsTests.matchesSs` holds an IPv4 and an IPv6 listener in the test process and an IPv6 listener in a child, then compares the scan with `ss -ltnpH` for the same pids. They matched. The same test also passed in a network namespace with IPv6 turned off (`unshare -rn` and `disable_ipv6=1`), which is how Docker runs a job whose network has no IPv6. The IPv6 listeners are skipped there. The ubuntu CI job installs `iproute2` for `ss`; Arch has it in `base`.
- **Fast enough.** The test process with 50 children was walked (`descendants`) and its ports joined (`scan`) in a median of 1.1 ms in a release build (`swift test -c release`) over 21 runs, and 1.5 ms in a debug build. The test fails a release build above 5 ms.
- **`startTicks` is `procStart`.** For the two live Claude Code 2.1.287 sessions in `~/.claude/sessions/`, `ProcessTable.startTicks` equalled the descriptor's `procStart` exactly (1147318 and 1630842). `startTime` was 1 to 2 s before the descriptor's `startedAt`. `exe` was Claude's binary under mise's installs, and `cwd` matched the descriptor's `cwd`.
- **The tree.** A 3-level tree (the test runner, `sh`, `sh`, `sleep`, with a second `sleep` beside the inner `sh`) came back exactly, from both the children files and the `/proc/*/stat` fallback.
