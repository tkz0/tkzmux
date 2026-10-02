# Building tkzmux on two platforms

How one `Package.swift` builds the Mac app and the Linux port, which build system Linux uses, and how the macOS graph is kept unchanged. Written in WOR-303 S1. WOR-303 S2 adds Linux CI, WOR-303 S3 adds resource lookup and the `Bundle.main` findings, and WOR-303 S4 adds version stamping and `AppIdentity`.

## Package.swift: one manifest, two graphs

- **Host-branched.** The manifest selects its target graph with `#if os(Linux)`. SwiftPM evaluates a manifest on the machine that runs it, so only native builds are supported: a cross-compile from a Mac would silently take the macOS branch. `make` refuses `--triple`, `--swift-sdk`, `--sdk`, `--destination` and `--arch` in `SWIFT_FLAGS`.
- **Why not `.when(platforms:)`.** `swift build` and `swift test` compile every root non-test target (SwiftPM's `build(subset: .allExcludingTests)`), whatever its platform conditions. The AppKit, Metal and CoreText targets therefore must not be in the Linux graph at all.
- **Three arrays** each for products and targets:

  | Array | Contents today | Grows in |
  |---|---|---|
  | `shared` | `GhosttyVt`, `TkzPlatform`, `TkzCore`, `Persistence`, `TkzPlatformTests`, `TkzCoreTests`; product `TkzCore` | WOR-304 to WOR-310, as targets compile on Linux |
  | `linuxOnly` | `TkzmuxLinux` (product `tkzmux`), `GhosttyVtSmokeTests`, and the Linux `PersistenceTests`, which depends only on `Persistence` and `TkzCore` (the Mac entry also lists `TkzTerminalCore` and `GhosttyVt`, which none of its files import) | WOR-311 to WOR-314 |
  | `macOnly` | everything else, as before | shrinks as targets move to `shared` |

- **`GhosttyVt` keeps one name.** On macOS it is `vendor/ghostty-vt/ghostty-vt.xcframework`; on Linux it is the SE-0482 bundle `vendor/ghostty-vt/ghostty-vt-linux.artifactbundle` ([vendoring.md](vendoring.md)). Linux consumers add `.linkedLibrary("m")`, because the bundle's localized compiler_rt leaves `exp`, `log` and friends to libm.
- **The Linux `tkzmux`** is the product name of target `TkzmuxLinux` (`Sources/tkzmux-linux/main.swift`), so the binary is `tkzmux` under both build systems. Until WOR-314 it is a synchronous stub:
  - `--version`/`-v` prints the same banner as the Mac app: `tkzmux 0.0.0-dev (0) libghostty-vt unknown` from `.build`, the stamped values from an install ([Version stamping](#version-stamping-and-app-identity));
  - the hidden `--vt-smoke` writes `hello` to an 80×24 libghostty-vt terminal and prints the plain-text screen;
  - the hidden `--locate-resources` prints `<module> <path>` for every resource bundle as the process resolves it, and exits 1 if one is missing;
  - anything else prints `tkzmux: not yet implemented on Linux` to stderr and exits 69, so `make run` fails on Linux for now.
- **`hygiene-scan` marker.** The `shared` and `linuxOnly` target arrays carry `// hygiene-scan` on their declaration line. `Tests/TkzCoreTests/RunLoopHygieneTests.swift` reads every `Sources/…`/`Tests/…` path from those arrays and fails on `Timer.scheduledTimer`, `RunLoop`, `CFRunLoop…(`, `.add(to: .main`, `Timer(timeInterval:/fire:`, `perform(_:afterDelay:)` and `dispatchMain()` there, because none of them fire under the GTK main loop ([spikes.md](spikes.md#runloop-inventory)). A target moved into either array is covered without touching the test. The only allowed site is the Mac display link at `Sources/TkzTerminalView/TerminalMetalView.swift:546`, which is not scanned today. An injected `Timer.scheduledTimer` in `Sources/TkzCore` fails the test (verified once, not committed).

### What TkzCore needed on Linux

| Change | Why | Removed by |
|---|---|---|
| `#if canImport(CoreGraphics)` around `import CoreGraphics` in `AppState.swift`, `Models.swift`, `Panes.swift` and `Tests/TkzCoreTests/PaneTests.swift` | There is no CoreGraphics on Linux; `CGFloat`/`CGRect` come from Foundation there | Removed in WOR-304 S3: the files import Foundation only, and `SourceHygieneTests` forbids `import CoreGraphics` in TkzCore, even behind a guard |
| `RGB.swift`: `import Darwin`, else `import Glibc` | `pow` | Removed in WOR-304 S3: `import Foundation`, which provides `pow` on both OSes |
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
- **Summary-line guard ([Linux CI](#linux-ci)).** Under Swift Build there is one `Test run with N tests` line per test target, so a guard that reads only the first line sees a partial count, and with `--filter` a target the filter empties prints `N = 0`. CI runs native, which prints one line; the guard still reads every line and requires each `N > 0`.
- `swift package describe` works on Linux and lists `GhosttyVt` as a `BinaryTarget` at the artifact bundle path.
- No AppKit, Metal or CoreText module is compiled on Linux: the build directory holds only `TkzCore`, `TkzCoreTests`, `TkzmuxLinux`, `GhosttyVtSmokeTests` and the test runner.

## Linux CI

`.github/workflows/ci-linux.yml` (WOR-303 S2) runs beside the macOS `ci.yml`, which stays byte-identical, stale comments included. Same triggers, `permissions: contents: read` and no secrets, so it runs on fork PRs. Its concurrency group is `ci-linux-<ref>`: groups are repository-wide, so reusing `ci-<ref>` would let the two workflows cancel each other.

| Job | Image | Steps | Required |
|---|---|---|---|
| `arch` | `archlinux:base-20260927.0.600689` by digest; `pacman -Syu` against the Arch Linux Archive snapshot of the same day (`ARCH_SNAPSHOT`) | the `pin swift` toolchain from [dev.md](dev.md) (tarball, signature, ncurses links, `libxml2-legacy`); `check-linkage.sh --lint`; `swift build`; `swift test --no-parallel` with the guard; test runner vs `[tests]`; `swift build -c release --product tkzmux` (default stdlib) with `--version` and `--vt-smoke`; `InstalledStubTests` against that release stub (the same guarded step, `TKZMUX_TEST_STUB` set); `check-linkage.sh` and `check-binary.sh` vs `[tkzmux-default-stdlib]` | yes |
| `ubuntu` | `ubuntu-24.04` + the dev.md `pin image` (`swift:6.3.3-noble` by digest); asserts the image's Swift equals the pin | apt `zsh fish git python3 ncurses-bin binutils pkg-config`; one `swift build --target` per entry of `NON_GTK_TARGETS`; `swift test --no-parallel` with the guard | no; WOR-314 S1 restricts or retires it |
| `arch-latest` | `archlinux:latest`, live mirrors | the `arch` steps (a YAML anchor), no `.build` cache | no; schedule (Mondays) and manual runs only |

- **Bumping the Arch pin.** Change the tag, the digest and `ARCH_SNAPSHOT` together. The digest is the OCI index digest, read as in [dev.md](dev.md#pins) with `repository:library/archlinux` and the new tag; the snapshot is the tag's date as `YYYY/MM/DD`. A failing `arch-latest` is the signal to bump.
- **Caches.** `.build` is keyed on the job, the Swift pin and the hash of `Package.swift` + `vendor/ghostty-vt/COMMIT`, with the commit appended and that prefix as the restore key. The `arch` job also caches the 1.07 GB toolchain tarball, keyed on the pin; it is still signature-checked on every run.
- **Summary-line guard.** After every `swift test` the step reads the Swift Testing `Test run with N tests` lines from the log. None, or any `N = 0`, fails the step even when `swift test` exited 0: the async main can `exit(0)` mid-run (`Tests/TkzAppTests/SheetTestSupport.swift`), which is the rule `scripts/test-memory-probe.sh` applies too. The steps run under `bash -eo pipefail` (`defaults.run.shell`), so a failing `swift test | tee` is not masked.
- **Linkage gate.** `readelf -d` NEEDED and RUNPATH only, through `check-linkage.sh`; its `ldd` closure count is printed and never gates (ADR-0002 D9). The release stub is linked with the default stdlib, which `[tkzmux]` (`stdlib static`) fails by design, so CI checks the temporary `[tkzmux-default-stdlib]`: `[tkzmux]`'s rules with `stdlib dynamic` and the toolchain RUNPATH allowed. Adding per-product `-static-stdlib` early was measured instead and rejected: the stub then passes `[tkzmux]`'s NEEDED rules (`libc`, `libm`, `libstdc++`, `libgcc_s`, `ld-linux`) but needs `GLIBC_2.44` on Arch (`__isoc23_*` at 2.38, `acosf` and friends at 2.43), above `glibc-max 2.35`. WOR-323 S1 owns the release link environment, deletes the temporary section and points CI at `[tkzmux]`.
- **`[tests]` confirmed.** The first Linux test runner (`tkzmuxPackageTests.xctest`) NEEDs `libswiftSwiftOnoneSupport`, `libswiftCore`, `libswift_Concurrency`, `libswift_StringProcessing`, `libswift_RegexParser`, `libswiftGlibc`, `libBlocksRuntime`, `libdispatch`, `libswiftDispatch`, `libFoundation`, `libFoundationEssentials`, `libFoundationInternationalization`, `libTesting`, `libXCTest`, `lib_Testing_Foundation`, `libm.so.6` and `libc.so.6`, with RUNPATH `<toolchain>/usr/lib/swift/linux:$ORIGIN`. All pass `[tests]`, which CI now gates.

Verified on the reference machine on 2026-10-03 by running each job's `run:` steps from the YAML in order on a fresh copy of the tree, outside a container (no package install, checkout or cache; the toolchain installed from the tarball into a scratch `$HOME`, with `libxml2.so.2` copied in where the container gets `libxml2-legacy`):

| Run | Result |
|---|---|
| `arch`, cold | passes in 26 s: toolchain unpack 8 s, `swift build` 3 s, `swift test` 7 s (355 tests), release build 8 s, checks < 1 s |
| `ubuntu`, cold, with the host toolchain | passes in 10 s: four `--target` builds 9 s, `swift test` 2 s |
| `swift test` as uid 0 (`unshare -r`), as in the containers | 355 tests pass |
| injected `import FoundationNetworking` + `URLSession.shared` in the stub | `check-linkage.sh` fails: NEEDED `libFoundationNetworking.so` denied. With the dynamic stdlib, `libcurl.so.4` is NEEDED by that library, not by the stub; a `--static-swift-stdlib` build of the same injection NEEDs `libcurl.so.4` directly and fails `[tkzmux]` on it |
| injected TkzCoreTests test calling `exit(0)` | `swift test` exits 0 after 81 tests; the guard fails the step: no summary line |
| guard on synthetic logs | passes for `1 test` (singular) and for colored output; fails on `0 tests` and on a missing line |

`actionlint` 1.7.12 (with shellcheck on the `run:` scripts) and PyYAML accept the file. The containers themselves, GitHub-hosted wall times and the warm-cache budget (≤ 15 min per job) are checked on the first runs; this machine has no container runtime.

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

## Resource lookup

`Sources/TkzCore/ResourceLocator.swift` (WOR-303 S3) is the one place that knows where read-only resources live outside `Bundle.module`. The three `ModuleResources.swift` files (`TkzTerminalCore`, `TkzTerminalRender`, `AgentBridge`) call `ResourceLocator.current.bundleURL(forModule:)` and fall back to `Bundle.module` last. `TerminalEnvironment.bundledTerminfoDirectory` probes the `TkzTerminalCore` bundle and then every candidate directory with `ResourceLocator.terminfoDirectory(in:)`, which accepts `<dir>/terminfo` holding `78/xterm-ghostty` or `x/xterm-ghostty`.

| | Candidate directories, in order | Bundle names tried in each |
|---|---|---|
| macOS | `Bundle.main.resourceURL` only, exactly as before | `tkzmux_<Module>.bundle` |
| Linux | 1. `$TKZMUX_RESOURCE_DIR`, if non-empty; 2. `<prefix>/lib/tkzmux` for `<prefix>/bin/tkzmux`, from `readlink(/proc/self/exe)` with symlinks resolved (ADR-0002 D7); 3. the executable's directory; 4. `Bundle.main.resourceURL` (duplicates dropped) | `tkzmux_<Module>.resources`, then `tkzmux_<Module>.bundle` |

- **`/proc/self/exe`, never `argv[0]`.** A `~/.local/bin/tkzmux` symlink to `/opt/bin/tkzmux` finds `/opt/lib/tkzmux`. A ` (deleted)` suffix, which the kernel adds after an upgrade replaced the file, is stripped.
- **Both extensions.** The native build system names a resource bundle `.resources` on Linux (a flat directory). Swift Build names it `.bundle` on Linux too (flat, with an `Info.plist`). Within one directory `.resources` wins; an earlier directory wins over a later one.
- **Pure.** The locator is a value over the platform, executable path, environment and `Bundle.main.resourceURL`, so `Tests/TkzCoreTests/ResourceLocatorTests.swift` checks the Linux order, both extensions, both terminfo layouts and the symlinked launcher on both OSes. On Linux it also runs `TERMINFO=<located dir> infocmp xterm-ghostty` against the committed database and asserts the file ncurses reports is `<dir>/./x/xterm-ghostty`.
- **`Bundle.module` stays last.** It is a `static let` that traps, so anything after it is dead code. On Linux the generated accessor tries `Bundle.main.bundleURL/tkzmux_<Module>.resources` and then the absolute `.build` path of the machine that built it, so a relocated tree "works" while `.build` exists. Hide `.build` when testing a relocated tree.

### What `Bundle.main` returns on Linux

Measured on the reference machine on 2026-10-03 with the pinned 6.3.3 toolchain, from a scratch package with resources:

| Context | `executableURL` | `bundleURL` and `resourceURL` |
|---|---|---|
| `swift run`, native | `.build/x86_64-unknown-linux-gnu/debug/<exe>` | `.build/x86_64-unknown-linux-gnu/debug` |
| `swift run`, swiftbuild | `.build/out/Products/Debug-linux/<exe>` | `.build/out/Products/Debug-linux` |
| `swift test`, native | `.build/x86_64-unknown-linux-gnu/debug/tkzmuxPackageTests.xctest` | `.build/x86_64-unknown-linux-gnu/debug` |
| `swift test`, swiftbuild | `.build/out/Products/Debug-linux/<Target>-test-runner` | `.build/out/Products/Debug-linux` |
| plain executable, started from `/` | its path | its directory |
| through a symlink in another directory | the symlink's target | the target's directory: corelibs resolves the link |
| copied tree `<T>/bin/<exe>` | `<T>/bin/<exe>` | `<T>/bin` |

- In every case `bundleURL` equals `resourceURL`, which is the executable's directory, `bundleIdentifier` is nil and `infoDictionary` is empty (not nil). There is no Linux equivalent of `Contents/Resources`, hence candidate 2.
- `Bundle(url:)` opens a `.resources` or `.bundle` directory anywhere, including `<prefix>/lib/tkzmux/`, and returns nil for a missing one. `url(forResource:withExtension:)` and `urls(forResourcesWithExtension:subdirectory:)` work in it, and its `resourceURL` is the directory itself.

The real `ModuleResources.swift` and `TerminalEnvironment.swift` were compiled on Linux in a scratch package (with `TerminalSize`/`PtySpawn` stubbed, since `TkzTerminalCore` is not in the Linux graph until WOR-305) and resolved as follows:

| Run | All three bundles | `bundledTerminfoDirectory` |
|---|---|---|
| `swift run`, native | `.build/…/debug/tkzmux_<Module>.resources` | `…/tkzmux_TkzTerminalCore.resources/terminfo` |
| `swift run`, swiftbuild | `.build/out/Products/Debug-linux/tkzmux_<Module>.bundle` | `…/tkzmux_TkzTerminalCore.bundle/terminfo` |
| `<T>/bin/<exe>` with `<T>/lib/tkzmux/tkzmux_*.resources`, `.build` hidden | `<T>/lib/tkzmux/…` | the bundle's `terminfo`, or `<T>/lib/tkzmux/terminfo` when the bundle has none |
| the same through `~/.local/bin` symlink | `<T>/lib/tkzmux/…` | same |
| `TKZMUX_RESOURCE_DIR` holding only `tkzmux_AgentBridge.bundle` | that one from the override, the rest from `<T>/lib/tkzmux` | unchanged |

`TERMINFO=<located dir> infocmp xterm-ghostty` succeeds for the located directory of the relocated tree.

## Version stamping and app identity

WOR-303 S4. The Mac stamps three keys into the `.app`'s Info.plist; Linux has no Info.plist (`Bundle.main.infoDictionary` is empty), so the same keys go into `<prefix>/lib/tkzmux/version.plist`, beside the resource bundles.

| | Mac | Linux |
|---|---|---|
| Derivation | `scripts/lib/version.sh` (`version_stamp`, `version_from_describe`), sourced by `scripts/make-app.sh` | the same file, sourced by `scripts/linux-version-plist.sh` |
| Written by | PlistBuddy into `Contents/Info.plist` | `scripts/linux-version-plist.sh [OUT]`: plain-text XML plist, no PlistBuddy or plutil, stdout without `OUT`; WOR-324's install runs it |
| Keys | `CFBundleShortVersionString` (`git describe`, or `VERSION`), `CFBundleVersion` (`git rev-list --count HEAD`), `TkzGhosttyCommit` (`vendor/ghostty-vt/COMMIT`) | same; the script also refuses a commit that is not 40 hex characters and a non-numeric build |
| Read by `AppVersion.current` | `Bundle.main.infoDictionary` (unchanged) | `PropertyListSerialization` over `ResourceLocator.versionPlistURL`: `$TKZMUX_RESOURCE_DIR/version.plist`, then `<prefix>/lib/tkzmux/version.plist`; never the executable's own directory, where a file would be stale |
| Without it | `0.0.0-dev (0) … unknown` (`swift run`) | the same, also for an unreadable file |

- **`make app` is unchanged.** `version_from_describe` moved verbatim. Replaying the version block of the old and new `make-app.sh` in a scratch repository gives identical `==> version …` lines for no tag (clean and dirty), an exact tag, an exact prerelease tag (clean and dirty), commits past a tag (clean and dirty), a `VERSION` override and an empty `VERSION`. The PlistBuddy calls and self-checks read the same three variables.
- **One table, two implementations.** `AppVersionTests.shellAgreesWithTheTable` sources `scripts/lib/version.sh` and runs `version_from_describe` against the Swift `AppVersion.marketingVersion(fromGitDescribe:)` table, on both OSes.
- **Bash 5.2.** `${s//&/&amp;}` does not escape on bash ≥ 5.2 (`patsub_replacement` substitutes the match for an unquoted `&`), so the script escapes with `sed`.

`Sources/TkzCore/AppIdentity.swift`:

| | macOS | Linux release | Linux debug (`swift build`, `swift run`, `swift test`) |
|---|---|---|---|
| `AppIdentity.id` | `se.tkz.tkzmux` (`CFBundleIdentifier`) | `se.tkz.tkzmux` | `se.tkz.tkzmux.Devel` |
| `AppIdentity.isInstalled` | `Bundle.main.bundleIdentifier != nil` | `<prefix>/lib/tkzmux` exists beside `<prefix>/bin` | same |

- `DEBUG` is SwiftPM's own define for `-c debug`. Checked under both configurations: `swift test -c release --filter AppIdentityTests` asserts `id == releaseID`, the debug run asserts `.Devel`.
- `SystemNotificationPresenter.isAvailable` (`Sources/TkzApp/SessionSeams.swift`) now reads `AppIdentity.isInstalled`, which on the Mac is the expression it replaced.

**Relocated install.** `Tests/TkzCoreTests/InstalledStubTests.swift` (Linux) copies the stub to `<tmp>/bin/tkzmux`, checks the dev fallback and that no bundle resolves, then writes `<tmp>/lib/tkzmux/version.plist` with the script and one empty `tkzmux_<Module>.resources` per `ResourceLocator.resourceModules`. Run with only `PATH` and `HOME` in its environment and `<tmp>` as its working directory, directly and through `<tmp>/home/.local/bin/tkzmux` → `<tmp>/bin/tkzmux`, it prints `tkzmux <ver> (<build>) libghostty-vt <40-char commit>` and resolves every bundle in `<tmp>/lib/tkzmux`. The stub is `$TKZMUX_TEST_STUB` when set (CI: the release build), else the debug `tkzmux` that `swift test` builds beside the test runner (both build systems). `resourceModules` is checked against the `resources:` of Package.swift's non-test targets.

## Tests on Linux

- Always `swift test --no-parallel`. Parallel runs pass today too, but serial runs keep memory bounded as more suites arrive (see the `test-memory-probe.sh` rule in CLAUDE.md).
- Under Swift Testing's async main on Linux, `@MainActor` code runs on a libdispatch worker, not the process main thread. Waits that suspend (`await`, continuations, `Task.sleep`) work; nested `RunLoop.run`, `Timer` and `perform(afterDelay:)` do not ([spikes.md](spikes.md#s3-swift-testing-mainactor-on-linux)).
