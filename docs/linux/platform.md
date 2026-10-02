# TkzPlatform on Linux

The OS seam below the UI (`Sources/TkzPlatform/`): one API per primitive, a back-end per OS. The Darwin back-ends live in `Darwin/` and the Linux ones in `Linux/`. Written in WOR-304 S2 (logging and signposts); WOR-304 S3 adds the path table, and later WOR-304 sessions add the other primitives.

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
