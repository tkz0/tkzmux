# Vendoring libghostty-vt for Linux

libghostty-vt is tkzmux's only third-party code. It is vendored twice, from one pinned commit:

| Variant | Built by | Built on | Contents |
|---|---|---|---|
| `vendor/ghostty-vt/ghostty-vt.xcframework` | `make vendor` (`scripts/build-ghostty-vt.sh`) | macOS (arm64) | arm64 static archive, headers, module map |
| `vendor/ghostty-vt/ghostty-vt-linux.artifactbundle` | `make vendor-linux` (`scripts/build-ghostty-vt-linux.sh`) | Linux (x86_64) | SE-0482 static-library bundle: `info.json`, `BUILDINFO`, `include/`, `x86_64-unknown-linux-gnu/libghostty-vt.a` |

Beside them in `vendor/ghostty-vt/`:

- `COMMIT`: the pin. Only `make vendor` moves it.
- `abi-types.aarch64-macos.json` and `abi-types.x86_64-linux-gnu.json`: the ABI manifest (`ghostty_type_json()`) of each variant.
- `linux-localize-symbols.txt`: the libc/libm names that the Linux archive's members define and that get localized.
- `linux-expected-undefined.txt`: every external symbol the Linux archive may reference.
- `ghostty.terminfo`: the terminfo source. The compiled entries live in `Sources/TkzTerminalCore/Resources/terminfo/` in both directory layouts (see [Terminfo](#terminfo)).

The bundle does not replace the xcframework on macOS: SE-0482 bundles are for non-Apple platforms only. WOR-303 wires the bundle to `GhosttyVt` in the Linux branch of Package.swift, with `.linkedLibrary("m")`.

## Bumping the pin

Order matters:

1. **macOS: `make vendor`** with `GHOSTTY_COMMIT=<sha>`. This moves `COMMIT`, rebuilds the xcframework, writes `abi-types.aarch64-macos.json` and recompiles terminfo. It must run on a Mac. Ghostty's `LibsystemOverrideStep` only runs when both host and target are Darwin, so a cross-built macOS archive would quietly lose the libSystem memmove/memcpy override.
2. **Linux x86_64: `make vendor-linux`** at the same `COMMIT`. It never moves the pin: if `GHOSTTY_COMMIT` is set and differs from `COMMIT`, it stops. It fails if its headers differ from the xcframework's, so step 1 must already be committed or present in the tree.
3. Commit both variants, both manifests and any list changes together. `GhosttyVtTests` (below) fails if the two variants drift apart.

`make vendor-linux` needs zig 0.16.x, git, GNU binutils (`ar nm objcopy strip readelf strings`), `llvm-ar` (it ships with the Swift toolchain) and the Swift toolchain itself, for the ABI probe. `GHOSTTY_SRC` points at a reusable ghostty checkout; zig's caches survive between runs. A cold zig build takes about 40 s.

What it does, and what fails the run, is listed in the script header. In short:

- `zig build -Demit-lib-vt -Demit-xcframework=false -Dtarget=x86_64-linux-gnu.2.35 -Dcpu=x86_64_v3 -Doptimize=ReleaseFast`, with the vendored simdutf and highway. Never `-fsys=simdutf`: Arch's system simdutf needs libc++. Never `-Dtarget=native`: the host's glibc would raise the floor ([ADR-0002](adr-0002-platform-defaults.md) D1).
- `llvm-ar x` extracts the members. Zig's member names carry directories, and one of them is an absolute path into the build machine's zig cache, so GNU tools cannot edit the archive in place.
- `objcopy --localize-symbols=linux-localize-symbols.txt` on each member that defines a listed name: `compiler_rt.o`, and `libghostty-vt-static_zcu.o` for its quirks `memset`. Then `strip -S`, and the members go back in their original order under their basenames with a deterministic `ar rcsD`.
- Gates on the archive: no listed name left global, no unlisted libc/libm definition, no `.debug_*` section, no `R_X86_64_32/32S` against a symbol, undefined symbols within `linux-expected-undefined.txt` (never `_Znw*`, `__cxa_*`, `arc4random*` or `__isoc23_*`), no build-machine path in `strings -a`, and at most 5 MiB.
- The ABI probe: a throwaway SwiftPM package links the staged bundle with `Sources/tkzmux-vtdump/AbiCommand.swift`. Both `--build-system native` and `--build-system swiftbuild` must build it and print the same manifest, and that manifest becomes `abi-types.x86_64-linux-gnu.json`. Only then is the bundle written into the tree. `--probe DIR` keeps the probe for the binary checks below.

A second run at the same `COMMIT` reproduces the archive bit for bit: sha256 `5042c26a…1d36` at `82232ecd`, 3,264,766 bytes, also from cold zig caches.

Swift Build does not pass `LD_LIBRARY_PATH` on to the tasks it runs, so the toolchain must start without it. An Ubuntu toolchain on Arch does once its compat libraries sit in the toolchain's RUNPATH directory ([dev.md](dev.md#compat-libraries)); then both probe builds run as they are, with no wrapper. A toolchain that still needs `LD_LIBRARY_PATH` fails the swiftbuild probe with `swiftc: error while loading shared libraries`, and `scripts/linux/dev-env.sh` reports it as a gap.

## Drift tests

These are part of `swift test` (`Tests/TkzTerminalCoreTests/`). They run on both OSes; on Linux since WOR-305 S2 moved TkzTerminalCore into the shared graph. JSON is always compared in canonical form, because corelibs `JSONSerialization` pretty-prints differently from Darwin's.

| Test | Fails when |
|---|---|
| `GhosttyVtTests.abiManifestMatchesVendoredFile` | The linked library's `ghostty_type_json()` differs from the committed manifest for this OS (`abi-types.x86_64-linux-gnu.json` under `#if os(Linux) && arch(x86_64)`, otherwise the macOS one). A vendor step was skipped. |
| `GhosttyVtTests.abiManifestsAgreeAcrossOSes` | `types`, `library_version` or `schema` differ between the two manifests. Only `abi` may differ. A failure names the type, e.g. `types.GhosttyAllocatorVtable differs`. |
| `GhosttyVtTests.linuxBundleBuiltAtVendoredCommit` | The bundle's `BUILDINFO` `commit=` is not `COMMIT`. |
| `GhosttyVtTests.headerTreesByteIdentical` | The xcframework's and the bundle's header trees (module map included) differ by one byte. |
| `GhosttyVtTests.terminfoVendored` | One of `78/xterm-ghostty`, `67/ghostty`, `x/xterm-ghostty`, `g/ghostty` is missing. |
| `GhosttyVtTests.terminfoLayoutsByteIdentical` | A letter-layout entry differs from its hex-layout twin. |
| `TerminalEnvironmentTests.terminfoPointsAtTheBundledDatabase` | `TERMINFO` does not point at a bundled directory holding either layout. |

The vendor scripts add their own gates: the header diff against the xcframework, the probe's native/swiftbuild agreement, and the two symbol lists.

## Regenerating the symbol lists

Both lists are generated from a build, then reviewed and committed:

```sh
scripts/build-ghostty-vt-linux.sh --update-lists
git diff vendor/ghostty-vt/linux-*.txt
```

- **`linux-localize-symbols.txt`**: every member's defined globals, intersected with `nm -D --defined-only` of the host's `libc.so.6` and `libm.so.6` (`GLIBC_LIBDIR` overrides where they are looked up). Today it has 72 names: `memcpy`, `memmove`, `memset`, `memcmp`, `bcmp`, `strlen`, the `__*_chk` family, `__stack_chk_fail`, and libm's `exp`/`log`/`sin`/`cos`/`fma`/`sqrt`/`ceil`/`floor` families. Without `--update-lists`, a run fails when a member defines a libc/libm name that is missing from the list.
- **`linux-expected-undefined.txt`**: the archive's undefined symbols minus the ones it defines itself (33 today, all glibc libc/libm). Without `--update-lists`, a run fails on any symbol missing from it.

Review the diff before committing. A new libc/libm definition means compiler_rt grew, and localizing it is usually right. A new undefined symbol means ghostty calls something new. It must exist in glibc 2.35 and must not be the C++ runtime: the forbidden patterns (`_Znw*`, `__cxa_*`, `__gxx_personality*`, `arc4random*`, `__isoc23_*`) fail the run even with `--update-lists`. After localizing, `exp`, `expf`, `log` and `logf` resolve to libm, which is why the package links `m`.

## Checking a final binary

Two scripts check a linked ELF. Both are read-only:

```sh
scripts/linux/check-binary.sh <elf> --section tkzmux|tkzmux-hook [--max-glibc 2.35]
scripts/linux/check-linkage.sh <elf> <section>
```

- [`scripts/linux/check-linkage.sh`](../../scripts/linux/check-linkage.sh) (WOR-299) is the only NEEDED and RUNPATH check. Its rules live only in [linkage-policy.txt](linkage-policy.txt).
- [`scripts/linux/check-binary.sh`](../../scripts/linux/check-binary.sh) checks what the archive gates cannot see, because the binding happens at the Swift link:

  | Check | Fails when |
  |---|---|
  | `exports` | `nm -D --defined-only` exports `memcpy`, `memmove` or `memset`. |
  | `glibc-bind` | `nm -D --undefined-only` has no `memcpy@GLIBC_*`, `memmove@GLIBC_*` or `memset@GLIBC_*`. |
  | `call-sites` | `objdump -d` shows a call or jump from a function outside compiler_rt to the entry of a local `memcpy`/`memmove` body. Bodies are found by address, because objdump prints any alias (`compiler_rt.memcpy.memcpyFast`). compiler_rt's own functions are read from the vendored archive's `compiler_rt.o` (`--archive` overrides it). A local `t memcpy` that only compiler_rt calls is harmless. The check needs `.symtab`, so run it before stripping. |
  | `glibc-max` | The highest `GLIBC_` version in `.gnu.version_r` exceeds the ceiling. The ceiling is the section's `glibc-max` line in linkage-policy.txt, or `--max-glibc`. The failure lists the symbols above it. |
  | `gnu-stack` | `PT_GNU_STACK` is missing or executable (RWE). |
  | `linkage` | `check-linkage.sh <elf> <section>` fails. check-binary.sh names no library itself. |

  Exit status: 0 pass, 1 violation, 2 usage, policy or tool error. A fully static ELF (no `.dynamic`) reports the four glibc checks as not applicable. WOR-323 S1 adds `--no-avx512` and PIE checks to the same option loop.

### Probe matrix (2026-10-02, Arch x86_64, glibc 2.44, Swift 6.3.3)

The probe is the one `scripts/build-ghostty-vt-linux.sh --probe DIR` keeps. It was built with `swift build -c release --build-system native` and the flags below. The default linker is gold. The Swift toolchain ships `ld.lld`, so `-Xswiftc -use-ld=lld` works without a system lld.

| Probe | Section | Result |
|---|---|---|
| dynamic stdlib, gold | `tkzmux-vtdump --max-glibc 2.35` | PASS. Max `GLIBC_2.34`. No local `memcpy`/`memmove` body is linked in. |
| dynamic stdlib, `-use-ld=lld` | `tkzmux-vtdump --max-glibc 2.35` | PASS, same as gold. |
| dynamic stdlib, gold, debug (the vendor script's own native probe) | `tkzmux-vtdump --max-glibc 2.35` | PASS. compiler_rt's `memcpy` is linked in, and its only caller is compiler_rt itself. |
| dynamic stdlib, gold | `tkzmux` | FAIL, linkage only: `[tkzmux]` says `stdlib static`, so `libswift*.so`, `libFoundation*.so` and the toolchain RUNPATH are denied. This is by design ([ADR-0002](adr-0002-platform-defaults.md), Consequences). |
| `-Xswiftc -static-stdlib`, gold or lld | `tkzmux` | FAIL, `glibc-max` only: it needs `GLIBC_2.44`. Every other check passes, including linkage: NEEDED is `libm`, `libstdc++`, `libgcc_s`, `libc` and `ld-linux-x86-64`, as measured in WOR-300 S4. With `--max-glibc 2.44` it passes. |
| unlocalized archive, dynamic stdlib | `tkzmux-vtdump --max-glibc 2.35` | FAIL: `glibc-bind` (no `memcpy`/`memmove`/`memset@GLIBC`) and `call-sites` (1,273 zig calls to `compiler_rt.memcpy.memcpyFast`). |
| unlocalized archive, `-static-stdlib` | `tkzmux --max-glibc 2.44` | FAIL: `glibc-bind`, and `call-sites` with 4,486 calls. The static Swift runtime's own value-witness code calls compiler_rt's `memcpy`. |
| dynamic stdlib with `-Xlinker --no-as-needed -Xlinker -lcurl` | `tkzmux-vtdump --max-glibc 2.35` | FAIL, linkage only: `libcurl.so.4 DENIED`. A `-lxkbcommon` link fails the same way. |

The `-static-stdlib` ceiling failure is a real finding, not a checker bug. The symbols above 2.35 come from the toolchain's static Foundation and runtime and from the host's libm: `__isoc23_strtol`/`__isoc23_sscanf`, `strlcpy`/`strlcat` and `fmod` at 2.38, and float math (`acosf`, `sinhf`, `sqrtf`, ...) re-versioned at 2.43/2.44. The archive is not the cause: the dynamic-stdlib probe tops out at 2.34. A `-static-stdlib` release therefore has to be linked in a glibc 2.35 environment with a jammy-built toolchain, or the ceiling is raised in ADR-0002 D1 and the policy. WOR-323 S1 makes that choice ([decisions.md](decisions.md)).

`swift package experimental-audit-binary-artifact vendor/ghostty-vt/ghostty-vt-linux.artifactbundle` (shipped with 6.3.3) reports "Artifact is safe to use on the platforms runtime compatible with triple: x86_64-unknown-linux-gnu". The `_Znw*`/`__cxa_*` gate in the vendor script stays the real check.

## Terminfo

`Sources/TkzTerminalCore/Resources/terminfo/` holds each entry twice: the hex layout (`78/xterm-ghostty`, `67/ghostty`) that macOS ncurses reads, and the letter layout (`x/xterm-ghostty`, `g/ghostty`) that Linux ncurses reads. Both are byte-identical copies of macOS tic output. `Resources/terminfo` at the repo root is a committed symlink to that directory, and neither vendor script replaces it.

- On macOS, `scripts/build-ghostty-vt.sh --terminfo-only` recompiles `vendor/ghostty-vt/ghostty.terminfo` into both layouts. It needs only tic.
- On Linux, never commit tic output: Linux and macOS tic write different bytes. Verify instead:

  ```sh
  out="$(mktemp -d)"
  scripts/build-ghostty-vt.sh --terminfo-only --out "$out"
  infocmp -x -d -A Sources/TkzTerminalCore/Resources/terminfo -B "$out" xterm-ghostty xterm-ghostty   # no differences
  TERMINFO="$PWD/Sources/TkzTerminalCore/Resources/terminfo" infocmp -x xterm-ghostty                  # succeeds
  ```

`TerminalEnvironment.bundledTerminfoDirectory` accepts either layout through `ResourceLocator.terminfoDirectory(in:)`, which looks for `78/xterm-ghostty` or `x/xterm-ghostty` ([build.md](build.md#resource-lookup)).
