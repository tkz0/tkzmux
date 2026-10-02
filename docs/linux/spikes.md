# Linux spikes: main loop, Swift Testing, libghostty-vt link

Measured results of the three WOR-300 spikes that later issues build on. Everything here was run on the reference machine (Omarchy, x86_64, glibc 2.44, GTK 4.22.4, Hyprland 0.56.2) on 2026-10-02 with the pinned Swift 6.3.3 ([dev.md](dev.md)) and zig 0.16.0. The spike code lived in scratch SwiftPM packages outside the repo and is not committed; this page keeps the facts, the commands and the decisions they feed.

## Go/no-go

| Question | Verdict | Consequence |
|---|---|---|
| Can GTK own the process main thread while libdispatch's main queue and the `@MainActor` keep working? (S2) | **Go** | A GSource drains the main queue. It must read the eventfd itself, and `DispatchSource`s must be retained. WOR-314 builds the production GSource in `TkzLinuxShim`. |
| Do `@MainActor` tests in Swift Testing run on Linux? (S3) | **Go** for tests that wait by suspending; **no-go** for nested run-loop waits | `SessionKillTests.waitFor` must become an async poll (WOR-309). GTK-touching tests need a harness where GTK owns the main thread. |
| Does the libghostty-vt Linux archive link into a Swift executable? (S4) | **Go** under both build systems, with gold and lld | The archive must be re-packed and its libc/libm names localized (WOR-302). Swift Build needs two workarounds ([S4 matrix](#link-matrix)). |
| What does a `-static-stdlib` binary NEED? (S4) | `libc.so.6`, `libm.so.6`, `libstdc++.so.6`, `libgcc_s.so.1`, `ld-linux-x86-64.so.2`, with or without Foundation | linkage-policy.txt is confirmed as written, and the `measured-by` marks are removed. A libc-only hook needs the musl Static Linux SDK (WOR-305 S6). |
| Does a release binary stay within glibc 2.35? (S4) | **Only with the ubuntu22.04 build of the toolchain** | The pinned ubuntu24.04 build's static runtime needs glibc 2.38 wherever it is linked. WOR-323 S1 decides ([glibc ceiling](#glibc-ceiling)). |

## S2: GtkApplication owns the main thread

**Setup.** A scratch executable built with plain `swiftc -swift-version 6 -O`, because SwiftPM did not run yet on this host (it needed `libxml2.so.2`, see [dev.md](dev.md#compat-libraries)). A `[system]` module map links gtk-4, gio-2.0, gobject-2.0 and glib-2.0. Its shim header declares the two libdispatch SPI functions that swift-corelibs-foundation's RunLoop uses and the `Dispatch` module does not expose:

```c
int  _dispatch_get_main_queue_handle_4CF(void);
void _dispatch_main_queue_callback_4CF(void *msg);
```

`main.swift` is synchronous (no `async` main, no `dispatchMain()`), adds a GLib unix-fd source on the handle, and calls `g_application_run` with `se.tkz.tkzmux` under `GDK_BACKEND=wayland`:

```swift
let handle = _dispatch_get_main_queue_handle_4CF()
_ = g_unix_fd_add(handle, G_IO_IN, { fd, _, _ in
    var counter: UInt64 = 0
    _ = read(fd, &counter, 8)   // libdispatch does not reset the eventfd; GLib spins if we don't
    _dispatch_main_queue_callback_4CF(nil)
    return 1                    // G_SOURCE_CONTINUE
}, nil)
```

**Results.**

- The main-queue handle is an eventfd (fd 3 in the spike).
- **`_dispatch_main_queue_callback_4CF` does not reset the eventfd.** Without the `read`, GLib dispatched the source 1,011,000 times in 1 s. With it, the whole primitive run took 7 dispatches.
- **An unretained `DispatchSource` never fires on Linux.** A source held only in a local `let` is deallocated. Keep sources in properties; AppStore already does.
- Each of these ran on the GTK thread (`pthread_equal` with the main thread):
  - the `activate` signal handler;
  - an unstructured `Task { @MainActor in … }`;
  - `Task.sleep`;
  - `makeUserDataAddSource(queue: .main)` + `MainActor.assumeIsolated` (the AppStore pattern);
  - a main-queue `makeTimerSource`;
  - `DispatchQueue.main.asyncAfter`;
  - `NotificationCenter.addObserver(queue: .main)`, posted from a global queue;
  - `MainActor.assumeIsolated` inside a GLib timeout callback (no trap).
- A Foundation `Timer` added to `RunLoop.main` in `.common` mode does **not** fire under `g_application_run`, as expected.
- **Latency** (10,000 posts from a background queue, GTK idle): p50 1.9 µs, p99 4.9 µs, max 8.7 ms (a first-frame outlier). The target was p99 < 1 ms.
- **Idle:** 0 GSource dispatches in 10 s with nothing posted.
- Swift 6 strict concurrency, no `@unchecked Sendable`. Three things to know for WOR-314:
  - Glibc's `stdout` is a mutable global, so `fflush(stdout)` is a Swift 6 error. Use `fflush(nil)`, `write(2)` or `FileHandle`.
  - `G_APPLICATION_NON_UNIQUE` does not import as a constant. Use `GApplicationFlags(rawValue: 1 << 5)` or a C shim.
  - GTK pointers import as typed `UnsafeMutablePointer<GtkX>`. Casting between `GtkWidget` and `GtkWindow` needs a raw-pointer helper (C shim macros in `TkzLinuxShim`).

### RunLoop inventory

The only run-loop-bound code in the repo today is:

| Site | What | Linux owner |
|---|---|---|
| `Sources/TkzTerminalView/TerminalMetalView.swift:546` | `link.add(to: .main, forMode: .common)`, the Mac display link | Mac-only; WOR-314 replaces it with the GTK frame clock |
| `Tests/TkzAppTests/SessionKillTests.swift:94` | `RunLoop.current.run(until:)` inside `waitFor` | Does not drain the main queue on Linux ([S3](#s3-swift-testing-mainactor-on-linux)); WOR-309 rewrites it |

The grep, for WOR-303's RunLoop hygiene test (it must print exactly these two lines until they are fixed):

```sh
grep -rnE '\bRunLoop\b|CFRunLoop[A-Za-z]*\(|\.add\(to: *\.main|Timer\.scheduledTimer|Timer\((timeInterval|fire)|afterDelay:' Sources Tests \
  | grep -vE '^[^:]+:[0-9]+: *//'
```

## S3: Swift Testing `@MainActor` on Linux

**Setup.** A scratch package (tools-version 6.2, Swift 6 mode, no dependencies) with:

- `MiniStore`, the AppStore shape: `makeUserDataAddSource(queue: .main)` + `assumeIsolated`;
- `TimerDebouncer`, a main-queue `makeTimerSource`;
- `TaskDebouncer`, StateAutosaver's `Task.sleep` debounce;
- a `.systemLibrary(pkgConfig: "gtk4")` target and a C shim for `gettid()`.

It declares 14 `@Test`s (13, plus one parameterized ×8). A runner script checks the exit code, the summary line, and that the executed count equals the declared count. Swift Testing is 6.3.3 (48d727cc1cf4eda).

**Results.**

- `swift test --no-parallel`: 20/20 green. Plain `swift test` (parallel): 20/20 green. Every run printed `✔ Test run with 14 tests in 3 suites passed after …`, and 14 equals the declared count. The XCTest half prints `Executed 0 tests`.
- **The main actor does not run on the process main thread.** SwiftPM's generated runner calls `_runAsyncMain`, and on Linux the async-main drain is `dispatch_main()`. The original thread (tid == pid) is `(Exiting)`, parked in `_dispatch_sig_thread → sigsuspend` (gdb), /proc state S. `@MainActor` jobs run on a libdispatch worker: `gettid() != getpid()`, `Thread.isMainThread == false`, `RunLoop.main !== RunLoop.current`.
- **The main-actor thread is not pinned.** Distinct tids seen by `@MainActor` code within one run: 1 in 37 of 40 runs, 2 in 3 of 40 (once inside a 300-hop loop of yield/sleep/detached). Main-queue serialization holds; thread identity does not.
- **Suspend-not-spin waits work as written:**
  - a store delivery awaited by a `Task.sleep` poll (`StateAutosaverTests.settle`) or by `withCheckedContinuation`;
  - 40 pokes of a main-queue `DispatchSourceTimer` debounce give exactly 1 fire, and the `Task.sleep` debounce gives 1 fire;
  - the AgentIntegrationTests yield loop (`for _ in 0..<20 where deliveries.isEmpty { Task.sleep(10 ms) }`) sees the delivery after 1 spin;
  - coalescing (two updates, one delivery of the last value) is identical to macOS.
- **A nested RunLoop does not drain the main queue.** `RunLoop.current.run(until: +0.3 s)` inside a `@MainActor` test returns after 20-85 µs, because the worker thread's run loop has no sources, and a `DispatchQueue.main.async` block posted before it has not run. `SessionKillTests.waitFor`, copied verbatim, never sees a store delivery in 0.5 s and hot-spins the CPU for its whole timeout; one `await` afterwards delivers immediately. `RunLoop.main.run(until:)` from the main actor does not fire a Foundation `Timer` either. WOR-309's rewrite of `waitFor` as an async poll is therefore required, not optional.
- **Compile time.** corelibs Foundation marks `RunLoop.current`, `RunLoop.run(until:)` and `Thread.sleep` unavailable from async contexts, which is a hard error in Swift 6 mode. All 15 `RunLoop.current`/`RunLoop.*.run`/`Thread.sleep` sites in `Sources/` and `Tests/` are in synchronous functions, so they compile. There is no `isMainThread`, `pthread_main_np` or `dispatchPrecondition` in the repo.
- **The async-main `exit(0)` mid-run (`SheetTestSupport.swift:6-13`) cannot happen on Linux.** There is no `CFRunLoopRun` under the async-main drain to be stopped, and `dispatch_main` never returns. 40 of 40 runs printed the summary line and the full count, including tests that call `RunLoop.current.run` and `RunLoop.main.run` mid-suite.
- **GLib and GTK from a `@MainActor` test.** `g_main_context_iteration` runs idle and timeout sources (1 turn, ≤ 10 ms), both on a private context (`push_thread_default`) and on the default context. `gtk_init_check()` from the main actor succeeded against the live Hyprland session, and `gtk_window_new` + `ref_sink`/`unref` worked. But this runs on a dispatch worker thread that can change between jobs, which GTK does not support. The headless-sway run is still open (sway was not installed).
- A clean `swift build --build-tests` has no Swift warnings. `.systemLibrary(pkgConfig: "gtk4")` prints `prohibited flag(s): -pthread … -mfpmath=sse -msse -msse2` (from `pkg-config --cflags gtk4`) on every build. It is harmless, because the flags are dropped, but it is noise in CI logs (WOR-303).

**Verdict for the WOR-309/WOR-310 coordinator tests.** Toolkit-free `@MainActor` coordinator and model tests that wait by suspending (`Task.sleep` polls, continuations, confirmations) run on Linux as written. These do not:

- anything that waits with a nested `RunLoop.run` (`SessionKillTests.waitFor`);
- Foundation `Timer` or `perform(afterDelay:)`;
- real GTK widgets inside a plain `@MainActor` test.

GTK-touching tests need a harness in which GTK owns the process main thread: a subprocess running `g_application_run` with the S2 GSource, under headless sway in CI.

## S4: libghostty-vt Linux archive

### Build

At `vendor/ghostty-vt/COMMIT` (82232ecd), with zig 0.16.0 and no `-fsys=simdutf`:

```sh
zig build -Demit-lib-vt -Demit-xcframework=false -Dtarget=x86_64-linux-gnu.2.35 -Dcpu=x86_64_v3 -Doptimize=ReleaseFast
```

- 40 s wall on the reference machine (16-core Zen 5). The output is `zig-out/lib/libghostty-vt.a` (17.4 MB, unstripped) plus a `.so`.
- The headers in `include/ghostty/` are byte-identical to the xcframework's `Headers/ghostty/`.
- The archive has 12 members: abort, base64, codepoint_width, compiler_rt, index_of, libghostty-vt-static_zcu, libhighway_zcu, per_target, simdutf, targets, vt, wuffs-v0.4.
- **Member names carry directories,** and compiler_rt's is an absolute path into the zig global cache (under the user's home). GNU `ar`, `objcopy` and `strip` cannot process the archive in place, and the path is personal data. The archive is therefore unpacked with the toolchain's `llvm-ar`, which writes basenames, and re-packed.

### Localizing the libc/libm names

`compiler_rt.o` defines 72 names that glibc also exports (bcmp, memcpy, memmove, memset, memcmp, strlen, exp, log, the pow/sin/cos families, `__*_chk`, `__stack_chk_fail`, …) as WEAK HIDDEN. `libghostty-vt-static_zcu.o` defines a second weak hidden `memset`. Hidden symbols do not stop a dynamic libswiftCore from binding to glibc, but the executable's own objects and the static Swift runtime would bind to these copies, so they are localized. The list is the intersection of what the members define and what libc/libm export, and every member is processed:

```sh
llvm_ar=$(dirname "$(command -v swift)")/llvm-ar
mkdir objs && (cd objs && "$llvm_ar" x ../raw.a)
ls objs | sort > members.txt
nm -A --defined-only -g objs/*.o | awk '{print $NF}' | sort -u > defined.txt
{ nm -D --defined-only /usr/lib/libc.so.6; nm -D --defined-only /usr/lib/libm.so.6; } \
  | awk '{print $NF}' | sed 's/@.*//' | sort -u > libc.txt
comm -12 defined.txt libc.txt > localize.txt            # 72 names
for o in objs/*.o; do objcopy --localize-symbols=localize.txt --strip-debug "$o"; done
(cd objs && ar rcsD ../libghostty-vt.a $(cat ../members.txt))
```

- Result: 3,264,766 bytes, 0 of the 72 names left global, 0 build paths in `strings`. Re-running the pipeline on a fresh zig build gave the same list and the same size.
- After localization, `exp`, `expf`, `log` and `logf` are undefined in the archive, so every link needs `-lm` (`.linkedLibrary("m")`). Without it the dynamic-stdlib link fails.
- The remaining undefined names are glibc only (malloc family, mmap/mremap/munmap, open/read/write family, `shm_open`/`shm_unlink`, `getenv`, `realpath`, `__errno_location`, the mem*/str* calls, exp/log) plus compiler builtins that the localized `compiler_rt.o` still provides.
- WOR-302 S2 turns this into `scripts/build-ghostty-vt-linux.sh`, with checked-in symbol lists and deterministic output.

### SE-0482 artifact bundle

```text
ghostty-vt-linux.artifactbundle/
  info.json
  x86_64-unknown-linux-gnu/libghostty-vt.a
  include/module.modulemap           # module GhosttyVt { umbrella header "ghostty/vt.h"  export * }
  include/ghostty/…                  # the xcframework's headers
```

```json
{
  "schemaVersion": "1.0",
  "artifacts": {
    "GhosttyVt": {
      "type": "staticLibrary",
      "version": "82232ecde55405559dec29c5466cb9e39938cb41",
      "variants": [
        {
          "path": "x86_64-unknown-linux-gnu/libghostty-vt.a",
          "supportedTriples": ["x86_64-unknown-linux-gnu"],
          "staticLibraryMetadata": {
            "headerPaths": ["include"],
            "moduleMapPath": "include/module.modulemap"
          }
        }
      ]
    }
  }
}
```

- The manifest uses `.binaryTarget(name: "GhosttyVt", path: "ghostty-vt-linux.artifactbundle")`, and the executable adds `linkerSettings: [.linkedLibrary("m")]`. The module name matches the Mac xcframework's, so `import GhosttyVt` is unchanged.
- `swift package describe` lists the binary target. `swift package experimental-audit-binary-artifact ghostty-vt-linux.artifactbundle` prints `Artifact is safe to use on the platforms runtime compatible with triple: x86_64-unknown-linux-gnu`.
- **A wrong `schemaVersion` gives a misleading error.** With `"2.0"`, both build systems report `local binary target 'GhosttyVt' at '…' does not contain a binary artifact.`, and `describe` says the same. The message does not mention the schema.

### Link matrix

**Test programs.** `vt-hello` prints `ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_STRING, …)`, creates an 80×24 terminal, feeds it 21 bytes with SGR sequences, and calls `memcpy` itself. `hook-hello` imports only Glibc (the `tkzmux-hook` shape), and `app-hello` imports Foundation (the `tkzmux` shape).

**Builds.** Every cell is `swift build -c release --build-system <bs> [--static-swift-stdlib] [-Xswiftc -use-ld=<ld>]`, each in its own scratch path, using the toolchain with the recommended compat route ([dev.md](dev.md#compat-libraries)) and `LD_LIBRARY_PATH` unset.

| Cell | native | swiftbuild |
|---|---|---|
| dynamic stdlib, default linker | links, runs (gold) | links, runs (gold) |
| dynamic stdlib, `-Xswiftc -use-ld=gold` | links, runs (gold) | links, runs (gold) |
| dynamic stdlib, `-Xswiftc -use-ld=lld` | links, runs (**lld**) | links, runs, but **with gold**: the flag is dropped |
| `--static-swift-stdlib`, default linker | links, runs (gold) | vt-hello and hook-hello link and run; **app-hello fails to link** |
| `--static-swift-stdlib`, lld | links, runs (lld) | as above, and the two that link use **gold**: the flag is dropped |
| `--static-swift-stdlib -Xswiftc -static-stdlib` | links, runs | **all three link and run** (gold) |
| lld through `linkerSettings: [.unsafeFlags(["-use-ld=lld"])]` | links, runs (lld), static and dynamic | **links, runs (lld)**, static and dynamic |

- **The default linker is gold** (`.note.gnu.gold-version`: gold 1.16, from binutils) under both build systems. The linker was identified from the binary, not from the command line.
- **`-use-ld=lld` picks the toolchain's own `ld.lld`** (clang searches its own directory first), not the system `lld` package. The toolchain's `ld.lld` NEEDs `libxml2.so.2` and has `RUNPATH $ORIGIN/../lib`, so links in the toolchain's `lib/swift/linux` directory do not reach it. The `libxml2-legacy` package in `/usr/lib` does.
- **Swift Build drops `-Xswiftc -use-ld=…`.** It appears in neither the compile nor the link command, and a `--toolset` file with `swiftCompiler.extraCLIOptions` or `linker.path`, or an `ALTERNATE_LINKER` environment variable, are ignored too. A per-target `linkerSettings: [.unsafeFlags(["-use-ld=lld"])]` works under both build systems. `-Xlinker -fuse-ld=lld` passes the flag to gold, which still links with gold: it is the wrong form, as the issue said.
- **Swift Build + `--static-swift-stdlib` cannot link a Foundation executable.** The link fails on `_platform_shims_*`, `_stringshims_*` and `_FoundationCollections` symbols (about 320 errors). Swift Build passes `-static-stdlib` only to the link and not to the compile, so the frontend never gets `-use-static-resource-dir`. The object's autolink entries are then the dynamic Foundation set, which lacks `-l_FoundationCShims -l_FoundationCollections -l_FoundationICU -lCoreFoundation -lswiftSynchronization`. Adding `-Xswiftc -static-stdlib` fixes it.
- **Per-product static stdlib (the policy's form, never the global flag).** A Foundation executable needs `-static-stdlib` in **both** `swiftSettings` and `linkerSettings` under **both** build systems; linker-only fails exactly like the Swift Build case. Measured:
  - `linkerSettings: [.unsafeFlags(["-static-stdlib"])]` alone: the Foundation-free executable links, the Foundation executable fails;
  - the same plus `swiftSettings: [.unsafeFlags(["-static-stdlib"])]` on the executable target: both link and run;
  - an executable that does not import Foundation itself, but depends on a library target that does, also links when only the executable target carries both flags. Without the swiftSettings flag it fails.
- **lld does not drop unused ICU.** A static Foundation `app-hello` is 20.8 MB with gold and 70.3 MB with lld. An executable that really uses ICU (a `sv_SE` `DateFormatter`) is 70.3 MB with both linkers and prints `torsdag 1 januari 1970` with both. An executable that uses ICU-backed Foundation API pays the size with either linker.
- Swift Build puts products in `<scratch>/out/Products/Release-linux/`; native puts them in `<scratch>/x86_64-unknown-linux-gnu/release/`.

### Checks on every linked vt-hello

| Check | Result |
|---|---|
| Runs | `ghostty_build_info rc=0 version=0.1.0-dev`, `terminal_new rc=0 wrote 21 bytes`, `memcpy ok=true` in every cell |
| TEXTREL (`readelf -d`) | none in any cell |
| Exported libc names (`nm -D --defined-only`: memcpy, memmove, memset, memcmp, bcmp, strlen, exp, expf, log, logf) | 0 in every cell |
| `objdump -d`: calls to `<memcpy@plt>` vs calls to a local `<memcpy>` | 1,215 vs 0 (dynamic stdlib); 2,087 vs 0 (static stdlib) |
| `strings`: zig cache, ghostty source or `zig-out` paths | 0 in every cell |
| `strings`: any absolute build path | Unstripped binaries contain the package's own build paths in DWARF (13-17 strings). After `strip`, no path of the build machine is left. What remains comes from the static runtime: the swift.org builder's `/home/build-user/swift/lib/Demangling/Demangler.cpp`, libdispatch's `/var/tmp/libdispatch.%d.log`, and with Foundation four `/home/build-user/swift-experimental-string-processing/…` source paths and `/tmp/`. WOR-302's `check-binary.sh` runs on stripped release binaries and looks for the build machine's paths, not for `/home/` in general. |
| Highest `GLIBC_` (`objdump -T`) | 2.34 with the dynamic stdlib; 2.43 with the static stdlib on this host. See [glibc ceiling](#glibc-ceiling). |

### Fallback: module-map target, `-L` and `linkedLibrary`

If SE-0482 bundles fail somewhere, a header-only C target plus a by-name link works under both build systems, with the dynamic and the static stdlib:

```swift
let libDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("lib").path
.target(name: "GhosttyVt", path: "Sources/GhosttyVt", publicHeadersPath: "include"),   // include/module.modulemap + include/ghostty/…, one stub .c
.executableTarget(name: "vt-hello", dependencies: ["GhosttyVt"],
                  linkerSettings: [.unsafeFlags(["-L", libDir]), .linkedLibrary("ghostty-vt"), .linkedLibrary("m")]),
```

- All four cells (native and swiftbuild, dynamic and `--static-swift-stdlib -Xswiftc -static-stdlib`) link and run, with the same check results as the bundle.
- A `.systemLibrary` target does **not** work here: it adds no include path, so `vt.h`'s `#include <ghostty/vt/types.h>` is not found. Hence the C target with `publicHeadersPath`.
- `unsafeFlags` is allowed only in a root package, which tkzmux is.

### ABI

`ghostty_type_json()` from the SwiftPM-linked Linux binary, compared with `vendor/ghostty-vt/abi-types.json` (macOS arm64): 159 types each, **0 differences** in `types`, and no difference in the other top-level keys except `abi` (os and target, as expected).

### NEEDED, PT_INTERP and RUNPATH

All built with `-c release --static-swift-stdlib` (plus `-Xswiftc -static-stdlib` under swiftbuild, see above), on glibc 2.44:

| Shape | Build system | NEEDED | PT_INTERP | RUNPATH | Size (gold) |
|---|---|---|---|---|---|
| Foundation-free (`tkzmux-hook` shape) | native | `libm.so.6 libstdc++.so.6 libgcc_s.so.1 libc.so.6 ld-linux-x86-64.so.2` | `/lib64/ld-linux-x86-64.so.2` | `$ORIGIN` | 10.0 MB |
| Foundation-free | swiftbuild | same five | same | none | 10.0 MB |
| Foundation-importing (`tkzmux` shape) | native | same five | same | `$ORIGIN` | 20.8 MB |
| Foundation-importing | swiftbuild | same five | same | none | 20.8 MB |
| vt-hello (archive, Foundation-free) | both | same five | same | as above | 12.4 MB |

- The NEEDED set is identical for gold and lld, with and without Foundation, and matches linkage-policy.txt's `[@glibc]` and `[@cxx-runtime]` groups. `check-linkage.sh` passes the static Foundation binary as `[tkzmux]` and the hook binary as `[tkzmux-hook]`.
- **The hook's `$ORIGIN` RUNPATH:** native adds it and `[tkzmux-hook]` rejects it. `swift build --disable-local-rpath` removes it (0 RUNPATH/RPATH entries, and the binary runs under `env -i`). Swift Build adds no RUNPATH to static binaries at all. This answers the decisions.md open item "`tkzmux-hook` with no RUNPATH at all" for WOR-305 S6.
- `ld-linux-x86-64.so.2` is NEEDED for one symbol, `__tls_get_addr` (the static runtime's TLS).
- **libstdc++ and libgcc_s stay.** A "libc and libm only" hook is impossible with the glibc static stdlib; it needs the musl Static Linux SDK (WOR-305 S6).
- For reference, dynamic-stdlib builds NEED `libswiftCore.so libswift_Concurrency.so libswift_StringProcessing.so libswift_RegexParser.so libswiftGlibc.so libm.so.6 libc.so.6`, plus `libBlocksRuntime.so libdispatch.so libswiftDispatch.so libFoundation.so libFoundationEssentials.so libFoundationInternationalization.so` with Foundation. Their RUNPATH is the toolchain's `lib/swift/linux` (and `$ORIGIN` under native).

### glibc ceiling

The highest `GLIBC_` version of a static-stdlib binary comes from two different sources:

1. **The link environment.** Symbols whose default version is newer on the build host bind to that version. On glibc 2.44: `fmod`/`fmodf` (2.38) and `sqrtf`, `log10f`, `remainder`, `remainderf` (2.43) in every static binary; with Foundation also `acosf`, `asinf`, `atan2f`, `acoshf`, `atanhf`, `coshf`, `sinhf`, `tgammaf`, `lgammaf_r` (2.43); and `cosh`/`sinh` (2.44) in the lld Foundation build only. All of them also exist at 2.2.5, so linking against an older glibc binds the old versions. A host link therefore always fails `glibc-max 2.35`, whichever toolchain is used.
2. **The static Swift runtime.** It was compiled against its build distro's glibc, and that cannot be undone at link time:

| swift.org 6.3.3 build | Static runtime references newer than 2.35 (`nm -u` over `usr/lib/swift_static/linux/*.a`, oldest version from libc/libm) |
|---|---|
| **ubuntu24.04** (the pin in dev.md, and `swift:6.3.3-noble`) | `__isoc23_sscanf`, `__isoc23_strtol`, `__isoc23_strtoll`, `__isoc23_strtoul`, `strlcpy`, `strlcat`, all GLIBC_2.38. They come from libswiftCore, libswift_Concurrency, libdispatch, CoreFoundation and _FoundationICU. |
| **ubuntu22.04** (`swift:6.3.3-jammy@sha256:2f3a1d7bb74da95c4857514589667a58087fdaf34f11e424d47854bebd710cf2`) | none. Its libdispatch carries its own `strlcpy` (`shims.c.o`), and it uses `__isoc99_*`. |

The libghostty-vt archive needs nothing newer than 2.34 (`shm_open`). So:

- With the pinned ubuntu24.04 build, every static-stdlib binary needs **glibc ≥ 2.38**, wherever it is linked.
- `glibc-max 2.35` is reachable only by linking releases with the **ubuntu22.04 build of the same 6.3.3** on a glibc ≤ 2.35 system (for example `swift:6.3.3-jammy`). Development can stay on the ubuntu24.04 build, because the version is the same.
- WOR-323 S1 chooses between that release link and raising the ceiling to 2.38 in ADR-0002 D1 and the policy (decisions.md, open items). WOR-302 S4's `check-binary.sh` enforces whichever number results.

### Exact commands for WOR-302

- Archive: the `zig build` line under [Build](#build), then the localization block under [Localizing](#localizing-the-libclibm-names). `llvm-ar` comes from the Swift toolchain; `nm`, `objcopy` and `ar` come from binutils.
- Bundle: the layout and `info.json` under [SE-0482 artifact bundle](#se-0482-artifact-bundle). The headers are copied from the xcframework, and the module map is the xcframework's.
- Validation:

  ```sh
  swift package describe
  swift package experimental-audit-binary-artifact ghostty-vt-linux.artifactbundle
  swift build -c release --build-system native --static-swift-stdlib
  swift build -c release --build-system swiftbuild --static-swift-stdlib -Xswiftc -static-stdlib
  readelf -dW "$exe" | grep -E 'NEEDED|RUNPATH|RPATH|TEXTREL'
  readelf -lW "$exe" | grep 'program interpreter'
  objdump -T "$exe" | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1
  nm -D --defined-only "$exe" | awk '{print $NF}' | grep -xE 'memcpy|memmove|memset|memcmp|bcmp|strlen|exp|expf|log|logf'   # expect nothing
  objdump -d --no-show-raw-insn "$exe" | grep -cE 'call.*<memcpy>'                                                          # expect 0
  objdump -d --no-show-raw-insn "$exe" | grep -cE 'call.*<memcpy@plt>'                                                      # expect > 0
  strings -a "$exe" | grep -E 'zig-cache|\.cache/zig|zig-out'                                                               # expect nothing
  ```

## Still open

- **Headless sway.** S3's GTK-in-a-test check under `WLR_BACKENDS=headless` sway is not done (sway was not installed). WOR-314 S2 needs the same setup.
- **A release link on glibc ≤ 2.35.** Not run, because there is no container runtime on the reference machine yet (podman is in the [dev.md](dev.md#packages) install line). The ubuntu22.04 result above comes from symbol analysis of its static runtime, not from a link. WOR-323 S1.
- **Swift Build's lld support** through anything other than per-target `unsafeFlags` (for example a future `--linker` option). Recheck on each toolchain bump.
