# tkzmux-hook on Linux

How the hook relay is linked on Linux, and what it costs to start. Written in WOR-305 S6. The source port (Glibc/Musl imports, the XDG support path) is WOR-305 S5; the socket location, `HookServer` and the installer are WOR-306.

## What ships

The shipped hook is the **fully static musl build** from the Static Linux SDK:

```sh
swift build --build-system native -c release --product tkzmux-hook --swift-sdk x86_64-swift-linux-musl
# .build/x86_64-swift-linux-musl/release/tkzmux-hook
```

- It has no dynamic section, so it has no NEEDED entries, no RUNPATH and no program interpreter. It runs from any directory under `env -i`, on any x86_64 Linux kernel, whatever the distribution's glibc.
- It passes `scripts/linux/check-linkage.sh <hook> tkzmux-hook` and `scripts/linux/check-binary.sh <hook> --section tkzmux-hook` unchanged: `check-binary.sh` reports its four glibc checks as not applicable and checks `PT_GNU_STACK` (RW).
- ci-linux (`arch` job) installs the pinned SDK, builds this binary, runs it under `env -i` from a copy in `<HOME>/.local/share/tkzmux/bin`, and runs both checks.

Every other build of the hook, including the one `swift build` and `swift test` make, is the glibc build below. Tests run it, and `TKZMUX_HOOK_BIN` points a test at another binary.

## The glibc build: per-product `-static-stdlib`

`Package.swift` gives the hook target `linkerSettings: [.unsafeFlags(["-static-stdlib"], .when(platforms: [.linux]))]`. This applies to this product alone and never through the global `--static-swift-stdlib` (ADR-0001). The flag does nothing on macOS. A musl build ignores it, because the SDK links statically anyway.

Linked on the reference machine (glibc 2.44), the release build:

- NEEDs `libm.so.6`, `libstdc++.so.6`, `libgcc_s.so.1`, `libc.so.6` and `ld-linux-x86-64.so.2`, all of which `[tkzmux-hook]` allows. That is the WOR-300 S4 set ([spikes.md](spikes.md#needed-pt_interp-and-runpath)), and nothing from `libswift*` or `libFoundation*`;
- carries SwiftPM's `$ORIGIN` RUNPATH with `--build-system native`, which `[tkzmux-hook]` rejects. `--disable-local-rpath` removes it, leaving 0 RUNPATH/RPATH entries. The `swiftbuild` backend adds no RUNPATH to this product at all, so its build passes `check-linkage.sh` as it is (checked for debug and release);
- needs `GLIBC_2.43`, so `check-binary.sh` fails it on `glibc-max 2.35`. The newer symbols are `__isoc23_sscanf`, `__isoc23_strtol` and `__isoc23_strtoll` at 2.38, which come from the ubuntu24.04 static runtime and appear wherever the hook is linked, and `acosf`, `acoshf`, `asinf`, `atan2f` and `atanhf` at 2.43, which come from the host link ([spikes.md](spikes.md#glibc-ceiling)).

So the glibc build passes `check-linkage.sh` only with `--disable-local-rpath` (native) or through `swiftbuild`, and passes `check-binary.sh` only with a release link on glibc ≤ 2.35 using the ubuntu22.04 toolchain build (WOR-323 S1). Neither CI job can produce that link.

## Measurements

Measured on the reference machine (Ryzen 9 9950X, kernel 7.2, glibc 2.44) on 2026-10-03 with `scripts/hook-latency.sh --budget`, three runs of 200 invocations per binary. The spread across runs was 0.02 ms or less.

| Build | Size | Stripped | NEEDED | RUNPATH | GLIBC max | socket p50 / p99 | no-socket p50 / p99 |
|---|---|---|---|---|---|---|---|
| **musl, Static Linux SDK 0.1.0** | 42.0 MB | 7.2 MB | none (static) | none | n/a | **0.46 / 0.71 ms** | **0.44 / 0.69 ms** |
| glibc, `-static-stdlib` (`--disable-local-rpath`) | 9.4 MB | 6.2 MB | the five above | none (`$ORIGIN` without the flag) | 2.43 | 0.81 / 1.07 ms | 0.79 / 1.07 ms |

- Stripping does not change the timings.
- The figures include bash's fork and the exec of `env -i`. `env -i /bin/true` alone takes 0.35 ms per call on this machine, so the musl hook's own share is about 0.1 ms and the glibc hook's about 0.45 ms. The difference is the dynamic loader mapping `libstdc++` and resolving its relocations.
- The socket run is at most 0.03 ms slower than the no-socket run at p50: one `connect` and one `send` are noise next to the exec.
- All 200 frames of every socket run reached the listener as one JSON line each.
- Budget (WOR-305 S6): socket p50 < 3 ms and p99 < 20 ms, no-socket p50 < 3 ms. Both builds meet it with plenty of headroom.
- Release builds of both variants compile with zero warnings.

## Why musl

- **It passes the policy as written.** The glibc build fails `glibc-max 2.35` wherever CI links it (Arch glibc 2.44, noble glibc 2.39, and the ubuntu24.04 static runtime needs 2.38 on any host). It would also need `--disable-local-rpath` in every build that produces the shipped binary.
- **It is about twice as fast to start**, with no loader and no `libstdc++` to map.
- **It cannot break when the system changes.** The hook always exits 0, so a hook that fails to load is silent. A fully static binary has nothing to resolve, whether the distribution's `libstdc++` changes or the toolchain moves (a dynamic-stdlib hook RUNPATHs into it, and `mise upgrade` would remove it).
- **The cost** is a pinned 305 MB SDK download (cached in CI), a separate `--swift-sdk` build for the shipped binary, a 7.2 MB stripped binary instead of 6.2 MB, and one musl-only code path (below).

## The musl-only code path

`statusline` hands the payload to the user's previous statusline command through `/bin/sh -c`, passing on the hook's own environment. Darwin and Glibc do this with `posix_spawn(…, environ)`, where `environ` is a computed accessor in their Swift overlays. The Musl overlay has no such accessor, and Swift 6 rejects the raw C global as shared mutable state. On musl, `forkExec` in `StatuslineCommand.swift` therefore forks and calls `execv`, which passes the environment implicitly. That avoids `nonisolated(unsafe)` and `@preconcurrency`.

- Exit status, stdout and the stdin bytes behave identically. This was checked on both builds with a previous command that prints an inherited variable and its stdin, then exits 3: the output was identical and the exit status was 3 on both.
- The one difference: if `/bin/sh` cannot be executed, `posix_spawn` reports the error and the hook exits 0, while the musl child exits 127.

## Building it locally

Install the SDK once, verified against the swift.org signing key and the pin in [dev.md](dev.md#pins):

```sh
cd "$HOME/.cache" && n=swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
base=https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE
curl -fLO "$base/$n" && curl -fLO "$base/$n.sig"
gpg --verify "$n.sig" "$n"            # with the swift.org keys imported (dev.md, Install)
sha256sum "$n"                        # must equal the `pin static-sdk` checksum
swift sdk install "$PWD/$n"           # lands in ~/.config/swiftpm/swift-sdks
swift sdk list                        # swift-6.3.3-RELEASE_static-linux-0.1.0
```

- The SDK links with the toolchain's `ld.lld`, and `ld.lld` looks for `libxml2.so.2` in its own `RUNPATH` (`usr/lib`), not in `usr/lib/swift/linux` where dev.md's compat copy lives ([dev.md](dev.md#compat-libraries)). Either install `libxml2-legacy`, or run the musl build with `LD_LIBRARY_PATH="$HOME/.local/share/swift/6.3.3/usr/lib/swift/linux"`. The native build system passes the variable through. CI has the package.
- The musl build lands in `.build/x86_64-swift-linux-musl/release`, and `.build/release` then points there until the next host release build.

## `scripts/hook-latency.sh`

```sh
scripts/hook-latency.sh [--runs N] [--budget] [<hook>]   # default hook: .build/release/tkzmux-hook
```

- It runs N invocations of `tkzmux-hook Stop` (default 200) against a python3 `AF_UNIX` listener, then N more with `TKZMUX_SOCKET` unset.
- Every invocation runs under `env -i`, with only `HOME`, `TKZMUX_SESSION_ID` and the socket variable set.
- It prints p50, p99 and max for each run, and fails if any frame is lost. With `--budget`, it also fails when a run misses the budget above.
- CI does not run it: GitHub's shared runners are too noisy for a millisecond gate, and the `arch` container has no python3.

## Follow-ups

- **Strip on install.** Unstripped, the musl hook is 42 MB, almost all of it debug info from the SDK's static libraries. Whatever copies it to `$XDG_DATA_HOME/tkzmux/bin` or the FHS prefix should strip it (WOR-306's installer, WOR-324's packaging).
- **Release.** WOR-323 builds the release hook with the command above, and WOR-324 installs that binary, not the glibc build.
- **`dev-env.sh`** does not check for the Static Linux SDK yet.
