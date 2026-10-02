# Building tkzmux on two platforms

How one `Package.swift` builds the Mac app and the Linux port, which build system Linux uses, and how the macOS graph is kept unchanged. Written in WOR-303 S1. WOR-303 S3 adds resource lookup and the `Bundle.main` findings, and WOR-303 S4 adds version stamping.

## Package.swift: one manifest, two graphs

- **Host-branched.** The manifest selects its target graph with `#if os(Linux)`. SwiftPM evaluates a manifest on the machine that runs it, so only native builds are supported: a cross-compile from a Mac would silently take the macOS branch. `make` refuses `--triple`, `--swift-sdk`, `--sdk`, `--destination` and `--arch` in `SWIFT_FLAGS`.
- **Why not `.when(platforms:)`.** `swift build` and `swift test` compile every root non-test target (SwiftPM's `build(subset: .allExcludingTests)`), whatever its platform conditions. The AppKit, Metal and CoreText targets therefore must not be in the Linux graph at all.
- **Three arrays** each for products and targets:

  | Array | Contents today | Grows in |
  |---|---|---|
  | `shared` | `GhosttyVt`, `TkzCore`, `TkzCoreTests`; product `TkzCore` | WOR-304 to WOR-310, as targets compile on Linux |
  | `linuxOnly` | `TkzmuxLinux` (product `tkzmux`), `GhosttyVtSmokeTests` | WOR-311 to WOR-314 |
  | `macOnly` | everything else, as before | shrinks as targets move to `shared` |

- **`GhosttyVt` keeps one name.** On macOS it is `vendor/ghostty-vt/ghostty-vt.xcframework`; on Linux it is the SE-0482 bundle `vendor/ghostty-vt/ghostty-vt-linux.artifactbundle` ([vendoring.md](vendoring.md)). Linux consumers add `.linkedLibrary("m")`, because the bundle's localized compiler_rt leaves `exp`, `log` and friends to libm.
- **The Linux `tkzmux`** is the product name of target `TkzmuxLinux` (`Sources/tkzmux-linux/main.swift`), so the binary is `tkzmux` under both build systems. Until WOR-314 it is a synchronous stub:
  - `--version`/`-v` prints the same banner as the Mac app (`tkzmux 0.0.0-dev (0) libghostty-vt unknown` from `.build`; WOR-303 S4 stamps real values);
  - the hidden `--vt-smoke` writes `hello` to an 80×24 libghostty-vt terminal and prints the plain-text screen;
  - anything else prints `tkzmux: not yet implemented on Linux` to stderr and exits 69, so `make run` fails on Linux for now.
- **`hygiene-scan` marker.** The `shared` and `linuxOnly` target arrays carry `// hygiene-scan` on their declaration line. `Tests/TkzCoreTests/RunLoopHygieneTests.swift` reads every `Sources/…`/`Tests/…` path from those arrays and fails on `Timer.scheduledTimer`, `RunLoop`, `CFRunLoop…(`, `.add(to: .main`, `Timer(timeInterval:/fire:`, `perform(_:afterDelay:)` and `dispatchMain()` there, because none of them fire under the GTK main loop ([spikes.md](spikes.md#runloop-inventory)). A target moved into either array is covered without touching the test. The only allowed site is the Mac display link at `Sources/TkzTerminalView/TerminalMetalView.swift:546`, which is not scanned today. An injected `Timer.scheduledTimer` in `Sources/TkzCore` fails the test (verified once, not committed).

### What TkzCore needed on Linux

| Change | Why | Removed by |
|---|---|---|
| `#if canImport(CoreGraphics)` around `import CoreGraphics` in `AppState.swift`, `Models.swift`, `Panes.swift` and `Tests/TkzCoreTests/PaneTests.swift` | There is no CoreGraphics on Linux; `CGFloat`/`CGRect` come from Foundation there | WOR-304 S3, which drops the import for `import Foundation` |
| `RGB.swift`: `import Darwin`, else `import Glibc` | `pow` | stays |
| `AppStore.swift`: `@preconcurrency import Dispatch` on Linux only | swift-corelibs-libdispatch does not mark `DispatchSourceUserDataAdd` Sendable, so the nonisolated `deinit` could not cancel the source (a hard error in Swift 6 mode). Cancelling a source is thread-safe on both OSes, and the Mac import is unchanged | stays until corelibs Dispatch is annotated |

No TkzCoreTests test fails on Linux, so none is disabled. The two `AppStoreTests` that wait for the store's main-queue delivery carry `.timeLimit(.minutes(1))`, so a main queue that never drains on Linux fails instead of hanging the run (WOR-304 owns the rest of TkzCore's main-queue users).

### The macOS graph is unchanged

The shared targets now come first, so the raw `dump-package` output lists them in a different order. Sorted by name, the targets and products are identical:

```sh
git show main:Package.swift > /tmp/old/Package.swift   # with Sources, Tests, vendor linked beside it
norm='.targets|=sort_by(.name) | .products|=sort_by(.name) | del(.packageKind)'
diff <(cd /tmp/old && swift package dump-package | jq -S "$norm") <(swift package dump-package | jq -S "$norm")
```

On 2026-10-02 this was checked on Linux by forcing the macOS branch (`#if os(Linux) && false`) in a copy of the manifest: the normalized diff is empty, and `swift package describe` lists the full macOS graph. macOS CI confirms it on a Mac.

## Build system: native, passed explicitly

ADR-0002 D2 recommends `--build-system native`, passed explicitly so that a toolchain bump cannot switch backends. Both backends work on the pinned 6.3.3 toolchain with the compat route in [dev.md](dev.md#compat-libraries) (no `LD_LIBRARY_PATH`), measured on the reference machine on 2026-10-02:

| | `--build-system native` | `--build-system swiftbuild` |
|---|---|---|
| `swift build --build-tests`, clean | 8 s | 8 s |
| binary | `.build/debug/tkzmux` | `<scratch>/out/Products/Debug-linux/tkzmux` |
| `tkzmux --version`, `--vt-smoke`, no argument | banner, `hello`, exit 69 | same |
| `swift test --no-parallel` | `✔ Test run with 355 tests in 39 suites passed` | one run per test target: 354 tests in 38 suites (TkzCoreTests), then 1 test in 1 suite (GhosttyVtSmokeTests) |
| `--filter GhosttyVtSmoke` | 1 test passes | `Test run with 0 tests in 0 suites` (TkzCoreTests), then 1 test passes |
| build noise | `clang: warning: argument unused during compilation: '-F<bin dir>'` at each link (SwiftPM passes `-F` for the binary target) | `clang: warning: argument unused during compilation: '-rdynamic'` |
| NEEDED of the debug `tkzmux` | Swift runtime + Foundation + dispatch, `libm.so.6`, `libc.so.6` | same |

- **Default: native.** `make build`, `make test` and `make run` pass `--build-system native` on Linux. Plain `swift build` also picks native on 6.3.3, but only because 6.3 still defaults to it.
- **Summary-line guard (WOR-303 S2).** Under Swift Build there is one `Test run with N tests` line per test target, so a guard that reads only the first line sees a partial count, and with `--filter` a target the filter empties prints `N = 0`. CI runs native, which prints one line.
- `swift package describe` works on Linux and lists `GhosttyVt` as a `BinaryTarget` at the artifact bundle path.
- No AppKit, Metal or CoreText module is compiled on Linux: the build directory holds only `TkzCore`, `TkzCoreTests`, `TkzmuxLinux`, `GhosttyVtSmokeTests` and the test runner.

## Makefile

`make` dispatches on `uname -s`. It stays compatible with GNU Make 3.81, which macOS ships: plain `ifeq`/`else`/`endif`, and `$(error)` for the refusals.

| Target | macOS | Linux |
|---|---|---|
| `build`, `run` | `swift build`, `swift run tkzmux` | the same with `--build-system native` |
| `test` | `swift test` | `swift test --build-system native --no-parallel` |
| `app`, `notarize`, `dist` | as before | fail fast with a message (Linux packaging is WOR-324) |
| `vendor`, `vendor-linux`, `clean` | as before | as before |

- `SWIFT_FLAGS` passes extra flags to `build`, `test` and `run` on both OSes.
- On Linux, a host other than x86_64 is refused, because the artifact bundle has only an `x86_64-unknown-linux-gnu` variant.

## Tests on Linux

- Always `swift test --no-parallel`. Parallel runs pass today too, but serial runs keep memory bounded as more suites arrive (see the `test-memory-probe.sh` rule in CLAUDE.md).
- Under Swift Testing's async main on Linux, `@MainActor` code runs on a libdispatch worker, not the process main thread. Waits that suspend (`await`, continuations, `Task.sleep`) work; nested `RunLoop.run`, `Timer` and `perform(afterDelay:)` do not ([spikes.md](spikes.md#s3-swift-testing-mainactor-on-linux)).
