# TkzPlatform on Linux

The OS seam below the UI (`Sources/TkzPlatform/`): one API per primitive, a back-end per OS. The Darwin back-ends live in `Darwin/` and the Linux ones in `Linux/`. Written in WOR-304 S2 (logging and signposts) and extended in WOR-304 S3 (paths) and S4 (SHA-256 and clocks); later WOR-304 sessions add the other primitives.

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
| `runtime` | per-login files (the hook socket moves here in WOR-305) | `$XDG_RUNTIME_DIR/tkzmux`, created 0700; `support` if that is unavailable | `support` |

- **Ignored XDG values.** An XDG variable that is unset, empty or relative is ignored, as the Base Directory spec requires, and the default applies. Each variable is judged on its own.
- **No `state` root.** `$XDG_STATE_HOME` is not used. If WOR-320 wants it for `update.log`, WOR-320 adds the root and names the file.
- **Disjoint from the install tree.** `support` never overlaps the installed read-only tree, `<prefix>/lib/tkzmux/` (ResourceLocator). That holds even with `PREFIX=$HOME/.local`, so `make install` and `ShimInstaller` never write each other's `terminfo/` or `bin/`.
- **The runtime directory is private.** `runtime` is created with `mkdir(…, 0700)`. An existing entry must be a real directory (not a symlink) owned by the effective uid, and it is narrowed to 0700. `$XDG_RUNTIME_DIR` itself is never created. Anything else falls back to `support`, which matches the Mac.
- **Tilde abbreviation.** `AppPaths.abbreviatingHome(_:)` replaces `NSString.abbreviatingWithTildeInPath`, which corelibs Foundation does not have. On the Mac it still calls that method, so the output is the same as before. On Linux it writes `~` for `home` and `~/…` for paths under it, and leaves every other path unchanged.
- **Who routes through it.** `StateFile.standard()` and `SnapshotStore.standard()` take `support` (their `applicationSupport:` injection is unchanged). The tilde sites in `MainWindowController` use `abbreviatingHome`. The rest of the support-directory users, the socket and the hook's Foundation-free mirror of this table move in WOR-305 and WOR-306.
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
