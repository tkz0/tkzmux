# Desktop services on Linux

How tkzmux reaches the desktop's services on Linux (WOR-320). On the Mac these are UNUserNotificationCenter, NSSound, the Dock tile, NSWorkspace and NSOpenPanel; on Linux almost all of them are D-Bus services, reached through GIO's GDBus, which GTK already links (ADR-0001: no libdbus, libsystemd, libnotify, libcanberra or libcurl). This page starts with the GDBus wrapper (S1). Notifications (S2), sound and badge (S3), open, reveal and the folder picker (S4), sleep and wake (S5) and the update check (S6) extend it, with the manual checklist.

## The GDBus wrapper (S1)

`Sources/TkzGtkShell/DBus/`, with two C helpers in TkzLinuxShim (`TkzDBus.c`). It is the only D-Bus client in tkzmux; WOR-321's `StartTransientUnit` uses it too.

| Type | Role |
|---|---|
| `DBusConnection` | `@MainActor`. `bus(.session/.system)` (`g_bus_get`), `open(address:)` (a private connection, for tests and second clients), `close()`, `call`, `emitSignal`, `subscribe`, `watchName`, `ownName`, `exportObject` |
| `DBusToken` | A subscription, name watch, name ownership or exported object. Ends on `cancel()` or when released |
| `DBusValue`, `DBusType` | A D-Bus value as plain Swift data, and the type grammar. Sendable; no GVariant ever reaches a caller |
| `DBusRepresentable` | The typed layer: `String` is `s`, `UInt32` is `u`, `[String]` is `as`, `[String: DBusVariant]` is `a{sv}`, `DBusObjectPath` is `o`, `DBusVariant` is `v`, and so on |
| `DBusError` | Every failure: `.remote(name:message:)` for a D-Bus error reply, `.timedOut`, `.cancelled`, `.closed`, `.failure(domain:code:message:)` for any other GError, `.typeMismatch`, `.unsupportedType`, `.invalidSignature`, `.invalidValue`, `.invalidName` |

```swift
let bus = try await DBusConnection.bus(.session)
let owner = try await bus.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                               interface: "org.freedesktop.DBus", method: "GetNameOwner",
                               arguments: [.string("org.freedesktop.Notifications")],
                               returning: String.self)
let token = try bus.subscribe(interface: "org.freedesktop.Notifications", member: "NotificationClosed") { signal in
    let id = try? signal.arguments.decode(UInt32.self, at: 0)
}
```

### Rules

- **Asynchronous only.** Every bus operation is the async GIO form; nothing blocks the GTK thread on the bus. `emitSignal` queues the message; `exportObject` and the token calls are local bookkeeping.
- **Callbacks land on the main actor without a hop.** GDBus delivers a reply, signal or name event in the thread-default GMainContext of the thread that started the operation. The wrapper is `@MainActor`, and under `g_application_run` the main actor is the GTK thread iterating the default context (MainQueueBridge), so that is where they arrive. Handlers are entered through `MainActor.assumeIsolated`, which traps rather than races if that ever stops holding. Never push a thread-default context around a wrapper call.
- **The reply type is checked before anything is read.** `call(…, reply: "(su)")` tests the reply with `g_variant_is_of_type` (`tkz_variant_is_of_type`, which also never asserts on an invalid type string) and throws `.typeMismatch(expected:actual:)` without unpacking anything; `returning: T.self` does the same for a single value. Reading is total: each node is read by its own type string, and a type outside `DBusType` (`h`, `m`) throws `.unsupportedType`.
- **Values are validated before GLib sees them.** `DBusValue.validate()` refuses what `g_variant_new_*` would assert on or silently truncate (a NUL in a string, a malformed object path or signature, an array element of the wrong type, a non-basic dictionary key, an empty structure, the D-Bus nesting and length limits), and names and paths are checked with `g_dbus_is_name` and friends. This matters beyond criticals: a failed GIO precondition returns without calling back, which would strand a continuation and leak its box.
- **Floating references.** Building returns a floating GVariant, and every consumer (`g_dbus_connection_call`, `_emit_signal`, `g_dbus_method_invocation_return_value`, the container constructors) sinks it, so a built tree has exactly one owner. A value is validated in full before the first `g_variant_new_*`, so no half-built tree is ever abandoned. Reading borrows the caller's reference; children are new references, dropped as they are read.
- **One release per box.** Each callback's state is a Swift box retained once with `Unmanaged` and released in one place: the completion of a one-shot operation (GIO calls a `GAsyncReadyCallback` exactly once), or the GDestroyNotify GIO calls after a subscription, watch, ownership or export ends, from the main context. `ClosureBoxes.live(.dbus)` counts them, and every bus test ends with the count back at its baseline. `tkz_dbus_register_object` guarantees one release even though GLib's behaviour on a failed registration is not part of its API (2.88 calls the free function, as measured; the helper is correct either way).
- **Exit-on-close is off** for `bus(_:)`: GIO's default would end tkzmux, and every session in it, if the bus went away. A closed connection fails its calls with `.closed`.

### Not covered (additions, not changes)

- **Unix fd passing** (`h`, `g_dbus_connection_call_with_unix_fd_list`). systemd's `PIDFDs` property needs it; `PIDs` (`au`) does not.
- **Peer-to-peer connections.** `open(address:)` always registers with a message bus.
- **Task cancellation of a pending call.** A call ends with its reply, an error or its timeout (`timeoutMilliseconds`, default GDBus's 25 s).

### For WOR-321: `StartTransientUnit`

```swift
let manager = (destination: "org.freedesktop.systemd1", path: "/org/freedesktop/systemd1",
               interface: "org.freedesktop.systemd1.Manager")
let bus = try await DBusConnection.bus(.session)
let jobs = try bus.subscribe(sender: manager.destination, interface: manager.interface,
                             member: "JobRemoved", path: manager.path) { signal in
    // (uoss): id, job, unit, result
}
let property = DBusType.structure([.string, .variant])
let job = try await bus.call(
    destination: manager.destination, path: manager.path, interface: manager.interface,
    method: "StartTransientUnit",
    arguments: [
        .string("app-tkzmux-\(pid).scope"), .string("fail"),
        .array(property, [
            .structure([.string("Delegate"), .variant(.boolean(true))]),
            .structure([.string("PIDs"), .variant(DBusValue([UInt32(pid)]))]),
        ]),
        .array(.structure([.string, .array(property)]), []),
    ],
    returning: DBusObjectPath.self, timeoutMilliseconds: 250)
```

The `(ssa(sv)a(sa(sv)))` body is one of the fuzzed signatures.

### Tests

`Tests/TkzGtkShellTests/GDBus*.swift`, run with `swift test --filter GDBus`; CI also runs them under `dbus-run-session` ([build.md](build.md#linux-ci)).

- **Marshalling, no bus** (`GDBusMarshallingTests`). For each of `s u i b o as a{sv} v y n q x t d g av aas a{us} a{oa{sv}} (sv) a(sv) a{sa{sv}} (ssa(sv)a(sa(sv)))`, plus `a{sv}` nested in its own variants, `v` inside `a{sv}` and `v` inside `v`, 1,000 seeded random values (SplitMix64, seeded by the case name) are built, put in a `GDBusMessage`, serialized to the D-Bus wire format, parsed back and read; the value, its signature and the GVariant (`g_variant_equal`) must survive. 2,000 bodies of random types up to four containers deep do the same. The type parser is fuzzed against `g_variant_is_signature` (20,000 strings). Wrong-typed bodies, `h` and `m` throw; invalid values are refused before any GVariant is built.
- **Over a bus** (`GDBusConnectionTests`). Each test starts its own `dbus-daemon --session` with two clients: call and reply, typed calls, every error mapping (ServiceUnknown, UnknownMethod, InvalidArgs from GDBus's argument check, a handler's own error name, Failed, a timeout from an unanswered call, `.closed`, invalid names), a reply of the wrong type (`(s)` where `(u)` is expected, from the bus driver's `GetNameOwner`), signal delivery with `arg0` and destination filters and after cancel or release, name watching with NameOwnerChanged on acquire, release and owner disconnect, queued and replacing owners, 100 fuzzed values per signature through an echo service, and 10,000 round trips of an `a{sv}` with nested variants. `bus(.session)` and `bus(.system)` run when the environment has those buses.

Results on the reference machine (2026-10-03, GLib 2.88.3): 25 tests green in 3.1 s; 10,000 round trips in 1.0 s with 0.3 MB of RSS growth after a 1,000-call warm-up (the bound is 1 MB); `swift test --sanitize=address --filter GDBus` green with no ASan error and no leak report (LSan with `scripts/linux/lsan.supp`; on this NVIDIA host the test runner's `--dump-tests-json` pass also needs a local `leak:libnvidia-glcore.so`, a driver tkzmux never calls, which CI's lavapipe image does not load). Under ASan the RSS bound is skipped, because the quarantine holds freed memory; LSan covers it.

### Findings

- **GLib 2.88.3's GDBus misreads some arrays that hold a signature (`g`).** `[('sssss', 1), ('u', 2)]` of type `a(gy)` comes back with one element, and some `a{yg}` dictionaries fail to parse ("Wanted to read 6553950 bytes but only got 0"). The blob GDBus writes is correct by hand (array length 12, no padding needed between the 8-byte first element and the second); its own reader drops the element. Pure GLib reproduces it, without this wrapper, and GVariant's own serialization round-trips the same value. tkzmux sends no `g`, so it does not matter here: the fuzz generators keep `g` out of arrays, and `glibMisreadsSignaturesInArrays` is a known-issue test that starts failing when a GLib update fixes it.
- **`g_variant_is_signature` is looser than D-Bus.** It accepts a dict entry outside an array (`i{qq}`), which the D-Bus specification forbids; `DBusType` refuses it.
- **A child spawned with Foundation's `Process` inherits libdispatch's blocked signals.** A `dbus-daemon` started that way had almost every signal blocked (`SigBlk: fffffffe3bfaca27`) and never saw SIGTERM, so the first test fixture outlived its tests. The fixture now spawns with `posix_spawn`, `POSIX_SPAWN_SETSIGMASK` (empty) and `POSIX_SPAWN_SETSIGDEF`, the same rule S3's `tkz_spawn_clean` makes for the app.
