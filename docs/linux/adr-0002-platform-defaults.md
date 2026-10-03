# ADR-0002: Linux platform defaults

- **Status:** Accepted (2026-10-02)
- **Date:** 2026-10-02 (written in WOR-299 S2, ratified in WOR-299 S6; D10 was decided in S6 under the user's delegation, see [decisions.md](decisions.md))
- **Issue:** WOR-299 (M0). It builds on [ADR-0001](adr-0001-charter.md), which covers the charter and dependency allow-list.
- **Related:** [ADR-0003](adr-0003-parity.md) (determinism under the private FcConfig), [ADR-0004](adr-0004-keys-input.md) (IME), [ADR-0005](adr-0005-window-controls.md) (app-id in the Hyprland rule, 4.20 capabilities), [linkage-policy.txt](linkage-policy.txt), [index](README.md)
- **Scope:** Linux only. The Mac app, its toolchain and its goldens stay unchanged (user decision 2, see [decisions.md](decisions.md)).

## Context

User decision 1 (2026-10-02) chose Option B. GTK4 is the platform shell only, and tkzmux draws every pixel itself with Vulkan and its own FreeType/HarfBuzz/fontconfig text. Before any Linux code lands, later issues need fixed answers to these questions:

- which glibc and CPU baseline to build for;
- which Swift toolchain to use;
- which GTK version is the minimum, and how to use newer APIs;
- which CI image is authoritative;
- the application id;
- where installed files, user data, caches and sockets live;
- where the UI scale comes from;
- whether chrome text uses Pango;
- how linkage is enforced.

Each question below needs no user input, unless it says so. The facts behind these answers:

- **Mac toolchain.** The package is `swift-tools-version: 6.2` (`Package.swift:1`). Mac CI and release builds select Xcode 26.1, which is Swift 6.2 (`.github/workflows/ci.yml:28-30`, `.github/workflows/release.yml:151-153`). The code already compiles under Swift 6.3: the only 6.3-specific fixes are listed as done in `TESTS.md:110-118`.
- **libghostty-vt.** It is pinned at `vendor/ghostty-vt/COMMIT` (`82232ecd…`). Its SIMD kernels stop at AVX2 whatever `-Dcpu` is set to. Ghostty disables highway's AVX-512 targets and simdutf's icelake kernel (`HWY_DISABLED_TARGETS`, ziglang/zig#20414). `-Dcpu` changes only Zig-side codegen.
- **This machine** (verified 2026-10-02):
  - glibc 2.44 and GTK 4.22.4.
  - pango 1.58.2, harfbuzz 14.4.0, fontconfig 2.18.3 (`pkg-config --modversion`).
  - `GDK_SCALE=2` in the session environment, while the monitor runs at fractional scale 1.6.
  - `/etc/fonts/conf.d/50-omarchy.conf` remaps sans-serif and monospace with `binding="strong"`.
  - `text-scaling-factor` is 0.7273.
- **Ubuntu 24.04** ships GTK 4.14, which is below the floor (research: tests-verification-infra).
- **Toolchain landscape.**
  - Swift 6.4 was released 2026-09-15. It makes Swift Build the default build system, ships with Xcode 27, and is preinstalled on the `ubuntu-24.04` runner image.
  - Official Docker images `swift:6.2.4-noble` and `swift:6.3.3-noble` exist.
  - There is no official Arch Swift image.
- **Current Mac paths.**
  - User data: `~/Library/Application Support/tkzmux` (`Sources/Persistence/StateFile.swift:83-94`, `Sources/Persistence/Snapshots.swift:92-106`).
  - Update log: `~/Library/Logs/tkzmux/update.log` (`Sources/TkzApp/Update/UpgradeRunner.swift:41-45`).
  - Hook sockets: per pid, `tkzmux-<pid>.sock`, inside the support directory (`Sources/TkzCore/HookSocket.swift:8-32`).

## Decision

### D1. CPU baseline and glibc floor

- **libghostty-vt Linux archive:** `zig build … -Dtarget=x86_64-linux-gnu.2.35 -Dcpu=x86_64_v3 -Doptimize=ReleaseFast` (WOR-300 S4 spike, WOR-302 vendoring). Never `-Dtarget=native`, because this host's glibc 2.44 would raise the floor silently.
- **glibc floor 2.35.**
  - `shm_open` has been in libc since 2.34.
  - The floor avoids `arc4random*` (2.36) and the `__isoc23_*` redirects (2.38).
  - It also covers Ubuntu 22.04 and `swift:*-jammy`.
- **The ceiling is a recorded number, not a hope.** `glibc-max 2.35` is set per section in [linkage-policy.txt](linkage-policy.txt). WOR-302's `check-binary.sh` enforces it on the final ELF, not on the archive: the archive carries no symbol versions, so the real floor is set at the Swift link. If the pinned toolchain's static runtime pulls in a newer `GLIBC_` version, WOR-300 S4 records it, and this ADR and the policy raise the number to the measured value. WOR-300 S4 measured it ([spikes.md](spikes.md#glibc-ceiling)): the static runtime of the ubuntu24.04 build of 6.3.3 needs 2.38 (`__isoc23_*`, `strlcpy`, `strlcat`) wherever it is linked, and the ubuntu22.04 build of the same version needs nothing newer than 2.35. The number stays 2.35 only if WOR-323 S1 links releases with the ubuntu22.04 build on a glibc ≤ 2.35 system; otherwise it becomes 2.38 here and in the policy. Running the GTK app also needs a distro with GTK ≥ 4.16 (D3).
- **CPU `x86_64_v3`** (AVX2, BMI2, FMA) for the archive and for C targets. WOR-323 S1 adds `-march=x86-64-v3` to `TkzPtyShim`/`TkzLinuxShim` cSettings in the Linux branch only.
- **znver5 is a WOR-323 S6 experiment only.** With `avx512f`, Zig's `std.simd.suggestVectorLength` produces 512-bit `@Vector` code. That code gets SIGILL on CI runners and other machines without AVX-512. The highway/simdutf kernels gain nothing, because they are capped at AVX2. WOR-323 S1's `check-binary.sh --no-avx512` keeps release binaries free of `zmm`/EVEX code.

### D2. Swift toolchain pin (recommendation; WOR-300 S1 commits it)

- **Recommend Swift 6.3.x on Linux, built with `--build-system native` passed explicitly.**
  - 6.3 is the newest release whose default build system is still the native one. Swift Build was a preview in 6.3 and became the default in 6.4.
  - The repo already builds with it (`TESTS.md:110-118`).
  - It has an official `swift:6.3.3-noble` image.
  - Passing `--build-system native` explicitly means a later toolchain bump cannot silently switch backends.
  - WOR-303 S1 checks both backends and records any failure in `docs/linux/build.md`.
- **Record the skew; do not fix it here.** The Mac compiles with Xcode 26.1 (Swift 6.2), and Linux with 6.3.x. Rules that follow:
  - Shared code must compile under both compilers. Mac CI is the 6.2 gate and Linux CI is the 6.3 gate.
  - No language or library feature newer than 6.2 may be used in shared targets.
  - Moving the Mac off Xcode 26.1 is a separate decision. Under decision 2, nothing here changes it.
- **Never use an unpinned 6.4.** It ships with Xcode 27, defaults to Swift Build, and is the runner image default. CI always names the exact tag. WOR-300 S1 records the tag and its digest, and only verifies that the image exists.
- **Fallback:** if 6.3.x fails WOR-300's spikes, 6.2.x (`swift:6.2.4-noble`) is the fallback. It matches the Mac compiler exactly, at the cost of an older Linux toolchain. Cross-compiling Linux binaries from the Mac is unsupported.

### D3. GTK floor 4.16

- **The floor is 4.16** (`pkg-config gtk4 >= 4.16`). Option B's presentation path needs two 4.16 APIs:
  - `gtk_graphics_offload_set_black_background` (`gtk/gtkgraphicsoffload.h:70-74`, `GDK_AVAILABLE_IN_4_16`);
  - `gdk_dmabuf_texture_builder_set_color_state` (`gdk/gdkdmabuftexturebuilder.h:103-107`).
- 4.16 is also the first release where Vulkan is the default GSK renderer on Wayland.
- Ubuntu 24.04's GTK 4.14 cannot build this path, which is why Ubuntu builds only non-GTK targets (D5).

### D4. APIs newer than 4.16: a runtime gate only

- **`GTK_CHECK_VERSION` is compile-time only.** It compares against the headers used for the build, not the GTK on the host. A direct reference to a 4.18 or 4.20 symbol compiles against 4.22, and the binary then fails to load on 4.16 with an undefined symbol.
- **Every API above 4.16 goes through one helper.** It is `tkz_gtk_symbol(name, minor)` in `TkzLinuxShim` (WOR-314 S1), and it:
  - checks `gtk_get_minor_version()`;
  - then calls `dlsym(RTLD_DEFAULT, name)`;
  - caches the function pointer, or NULL.

  Known users:
  - `gtk_accessible_update_platform_state` (4.18, `gtk/gtkaccessible.h:283-284`), in WOR-325.
  - `gdk_toplevel_get_capabilities` (4.20, `gdk/gdktoplevel.h:305-318`), in WOR-314. Without it, only the close button shows (ADR-0005).
- **A unit test covers the missing-symbol path.** It forces minor version 16, or a failing lookup, and asserts the fallback behaviour.
- **Compile-time guard (recommended to WOR-314).** `CGtk`'s shim header defines `GDK_VERSION_MIN_REQUIRED` and `GDK_VERSION_MAX_ALLOWED` as `GDK_VERSION_4_16` before including `<gtk/gtk.h>`. Any direct use of a newer API then triggers the header's "Not available before 4.x" warning (`gdk/version/gdk-visibility.h:362-367`, `glib/gmacros.h:1321`). The runtime gate is still required, because the guard only warns.

### D5. CI shape

- **Required full build: Arch.** An `archlinux:base-<date>` container pinned by digest, with the D2 toolchain installed as WOR-300 documents. It runs `swift build`, `swift test --no-parallel`, the release build, `check-linkage.sh` and `check-binary.sh` (WOR-303 S2). The image matches the user's machine (GTK 4.22, Hyprland libraries), and it is the only common image that meets the 4.16 floor.
- **Ubuntu noble** (`ubuntu-24.04` + `swift:<pin>-noble`, never the preinstalled 6.4) builds and tests the non-GTK targets only, through an explicit `--target` list. It never links `CGtk`. WOR-314 S1 restricts the list or retires the job; it restricted it to `--target` builds, with no tests ([build.md](build.md#linux-ci)).
- **A scheduled, non-required `archlinux:latest` job** catches rolling-release breakage early.
- **The real presentation path is local only.** Runners have no GPU. Dmabuf, offload, direct scanout and key-to-photon run only in the Hyprland-local script (WOR-322, WOR-323). CI gates use in-app readback (ADR-0003).

### D6. Application id

- **`AppIdentity.id`** is `se.tkz.tkzmux` in release builds and `se.tkz.tkzmux.Devel` in debug builds (WOR-303 S4). It is used as:
  - the GApplication id and xdg_toplevel app_id;
  - the `.desktop` basename;
  - the notification `desktop-entry` hint;
  - the Hyprland rule key (ADR-0005: `^se\.tkz\.tkzmux(\.Devel)?$`).

  The Mac keeps `CFBundleIdentifier` `se.tkz.tkzmux` (`Resources/Info.plist:18`) and does not change.
- **Some runs are non-unique.** Runs with `TKZMUX_FIXTURE`, `TKZMUX_SUPPORT_DIR` or any `TKZMUX_DEV_*` variable set add `G_APPLICATION_NON_UNIQUE` (WOR-314 S3). Without it, GApplication forwards a second process's activation to the instance that already owns the bus name. A dev or fixture build started from a pane of the installed app would then run inside the installed app. That defeats the per-pid sockets that keep two instances apart (`Sources/TkzCore/HookSocket.swift:8-16`).

### D7. XDG layout: installed files and user data never overlap

| What | Linux | Mac equivalent | Owner |
|---|---|---|---|
| Executables | `<prefix>/bin/tkzmux`, `<prefix>/bin/tkzmux-hook`, side by side, because `ShimInstaller.standardHookBinary()` looks next to the executable (`Sources/AgentBridge/ShimInstaller.swift:118-122`) | `Contents/MacOS/` | WOR-324 |
| Read-only resources: terminfo, fonts, sound, `version.plist` | `<prefix>/lib/tkzmux/`, resolved from `/proc/self/exe/../../lib/tkzmux` | `Contents/Resources/` | WOR-303 S3 resolves, WOR-324 installs |
| User data: `state.json`, `sessions/`, `usage/`, `statusline/`, `bin/`, `zsh/`, `terminfo/` | `$XDG_DATA_HOME/tkzmux/` (default `~/.local/share/tkzmux/`) | `~/Library/Application Support/tkzmux/` | WOR-304 S3 (`AppPaths.support`) |
| `update.log` | `$XDG_CACHE_HOME/tkzmux/update.log` (default `~/.cache/tkzmux/`) | `~/Library/Logs/tkzmux/update.log` | WOR-320 |
| Hook sockets | `$XDG_RUNTIME_DIR/tkzmux/tkzmux-<pid>.sock`, in a directory created 0700 | `<support>/tkzmux-<pid>.sock` | WOR-305 |
| `$XDG_STATE_HOME` | unused, unless a later issue documents the file it holds (WOR-304 S3 / WOR-320) | – | – |

Why each row is where it is:

- **Resources in `lib/tkzmux`, not `share/tkzmux`.** With `PREFIX=$HOME/.local`, `share/tkzmux` would be the same directory as the default `$XDG_DATA_HOME/tkzmux`. `make install` and `ShimInstaller` would then overwrite each other's `terminfo/` and `bin/`. Under `lib/`, an install tree that writes user data, or reads state from the install tree, is visibly a bug.
- **User data mirrors the Mac's support directory one to one.**
  - Subdirectories, for reference: `Sources/AgentBridge/ShimInstaller.swift:154` (`bin`), `Sources/AgentBridge/StatuslineInstaller.swift:101` (`statusline`), `Sources/AgentBridge/TranscriptUsageReader.swift:63` (`usage`), `Sources/Persistence/Snapshots.swift:106` (`sessions`), `Sources/TkzApp/TerminalHost.swift:273` (`zsh`).
  - swift-foundation already maps `.applicationSupportDirectory` to `$XDG_DATA_HOME` on Linux.
  - The hard-coded `Library/Application Support` fallbacks (`StateFile.swift:94`, `Snapshots.swift:102`, `Sources/tkzmux-hook/StatuslineCommand.swift:51`) go through `AppPaths`, and the hook mirrors the same rule (WOR-304, WOR-305).
  - `TKZMUX_SUPPORT_DIR` keeps overriding all of them.
- **XDG variables that are unset, empty or relative are ignored**, as the Base Directory spec requires, and the documented defaults apply instead.
- **The socket moves to the runtime directory.** `$XDG_RUNTIME_DIR` is a per-user 0700 tmpfs that is cleared at logout, so a crash can no longer leave a stale socket in persistent storage. The path stays short (about 40 bytes) against `sun_path`'s 108-byte limit.
  - The `tkzmux/` subdirectory is created with mode 0700. An existing directory is accepted only if it is owned by the user and has mode 0700.
  - If `$XDG_RUNTIME_DIR` is unset or invalid, the socket falls back to the support directory, as on the Mac, and `HookServer.sweepStaleInstanceSockets` (`Sources/AgentBridge/HookServer.swift:181`) still cleans up.
  - Both sides must use one resolver, so the paths agree byte for byte: the listener (`Sources/TkzApp/AgentIntegration.swift:222`) and the pty environment (`Sources/TkzTerminalCore/TerminalEnvironment.swift:140`).
- **`update.log` goes in the cache directory**, matching the Mac's `Logs`. The XDG spec would allow `$XDG_STATE_HOME`, but no state file justifies a fourth root yet.

### D8. Scale comes only from the Wayland surface

- **`GDK_SCALE` and `GDK_DPI_SCALE` are saved and then unset before `gtk_init`.** This happens before any thread starts, because `setenv`/`unsetenv` are not thread-safe. WOR-314 S3 passes the saved values to WOR-305's `TerminalEnvironment.make(…, baseEnvironment:)` (`Sources/TkzTerminalCore/TerminalEnvironment.swift:95-106`), so child shells see the user's original values. The unset is unconditional. WOR-301 S1 measures whether GDK honours the variables on Wayland, but removing them costs nothing either way. The device scale is the surface scale from `wp_fractional_scale_v1`, which GDK reports (192/120 = 1.6 here).
- **`text-scaling-factor` is never read.** Points map to logical pixels 1:1, and FreeType gets px = pt × surface scale.
- **Fonts ignore desktop configuration.** A private `FcConfig` (bundled faces first) bypasses `50-omarchy.conf`'s strong remaps. After `FT_Init_FreeType`, `FT_Property_Set` overrides anything `FREETYPE_PROPERTIES` sets (`/etc/profile.d/freetype2.sh`) (WOR-312).
- **`VK_LOADER_DRIVERS_SELECT`.** If WOR-323 S2 sets it, WOR-323 S2 also adds it to WOR-305's environment strip list, next to `strippedKeyPrefixes` (`Sources/TkzTerminalCore/TerminalEnvironment.swift:48`), so it never reaches a pane.

### D9. Linkage enforcement

- **One policy file.** [linkage-policy.txt](linkage-policy.txt) is the only allow/deny source. It has four sections:
  - `[tkzmux]`: the app, `stdlib static`, provisional until WOR-323 S2.
  - `[tkzmux-hook]`: `stdlib static`, no RUNPATH at all.
  - `[tkzmux-vtdump]`: an in-tree tool, `stdlib dynamic`, headless, so no GTK.
  - `[tests]`: `stdlib dynamic`, plus the test-only libxkbcommon (ratified in WOR-299 S6).
  - `[tkzmux-default-stdlib]`: temporary, added in WOR-303 S2 for CI's default-stdlib release build until WOR-323 S1 (see Consequences).

  Shared groups hold glibc, the C++ runtime, GTK/GLib, Vulkan and text, Pango for paragraph layout (D10), the Swift runtime, and the deny list.
- **What the policy encodes.**
  - Every rule carries a justification, and every allow line also names its Arch and Ubuntu 24.04 package.
  - `libstdc++.so.6`, `libgcc_s.so.1` and `ld-linux-x86-64.so.2` carried `measured-by: WOR-300 S4` until the `-static-stdlib` NEEDED measurement confirmed them. WOR-300 S4 measured them and removed the marks ([spikes.md](spikes.md#needed-pt_interp-and-runpath)).
  - `libwayland-*` is denied everywhere.
  - Toolchain and build-tree RUNPATHs are denied in shipped binaries.
  - If the hook must be libc-only, WOR-305 S6 adopts the Static Linux SDK (musl). A fully static hook has no NEEDED entries and passes `[tkzmux-hook]` unchanged.
- **One checker.** [`scripts/linux/check-linkage.sh <elf>... <section>`](../../scripts/linux/check-linkage.sh) is the only NEEDED check.
  - It reads `readelf -d` NEEDED and RUNPATH/RPATH entries, lints the policy on every run, and exits 0 (pass), 1 (violation) or 2 (usage, policy or tool error).
  - It prints the `ldd` closure count as information only. On this machine it is 112 objects for a GTK binary. X11, systemd and dbus enter that closure through GTK, so gating on the closure would fail every build.
  - `check-binary.sh` (WOR-302), CI (WOR-303), the hook (WOR-305), release (WOR-323) and packaging (WOR-324) call it. They never copy the lists.
- **Self-test (2026-10-02, this machine):**

  | Command | Result |
  |---|---|
  | `check-linkage.sh /usr/bin/curl tkzmux` | exit 1, `libcurl.so.4 DENIED` |
  | `check-linkage.sh /usr/bin/true tkzmux-hook` | exit 0 |
  | `check-linkage.sh /usr/bin/ls tkzmux` | exit 1, `libcap.so.2 NOT ALLOWED` |
  | `check-linkage.sh /usr/bin/gtk4-launch tkzmux` | exit 0; NEEDED gtk/glib/gobject/gio/libc, closure 112 |
  | `check-linkage.sh /usr/bin/gtk4-rendernode-tool tkzmux` | exit 1, `libcairo.so.2` denied (pango passes since D10) |
  | `check-linkage.sh /usr/bin/gtk4-launch tkzmux-hook` | exit 1 |
  | `gcc -static` probe vs `[tkzmux-hook]` | exit 0 (no dynamic section) |
  | Probe with NEEDED `libswiftCore.so` and a toolchain RUNPATH vs `[tkzmux]` | exit 1 |
  | Same probe vs `[tkzmux-vtdump]` | exit 0 |
  | C probe linked `--no-as-needed` with `pkg-config --libs gtk4` vs `[tkzmux]` | exit 1, five violations (pangocairo, cairo, cairo-gobject, gdk_pixbuf, graphene) |
  | Same probe linked `--as-needed` vs `[tkzmux]` | exit 0 |
  | C probe linked with `pkg-config --libs pangoft2` vs `[tkzmux]` / `[tkzmux-vtdump]` | exit 0 / exit 1 (vtdump draws no chrome text) |

  The table was re-run after the WOR-299 S6 policy changes (Pango allowed, explicit cairo and image-codec denies).

### D10. Text layout: Pango for paragraph layout, tkzmux for pixels

Decided in WOR-299 S6 (2026-10-02) under the user's delegation ([decisions.md](decisions.md), S6-1). The S2 draft recommended in-repo line breaking instead; that option is now the rejected alternative below.

- **Pango does paragraph layout only.** Chrome text goes through a `TextLayout` protocol (WOR-317 S3a: `Sources/TkzCanvasUI/Text/TextLayout.swift`) whose one backend is `PangoTextLayout`. Pango does itemization, UAX #14 line breaking, bidi (UAX #9, which settles WOR-317 S3b's scope) and glyph positions. It never draws.
- **Rasterization stays tkzmux's.** Glyph IDs and positions from Pango are drawn by TkzFontsFT through the atlas (WOR-312); faces are mapped with `pango_font_get_hb_font`. `libpangocairo` and cairo stay denied.
- **Desktop state is neutralized explicitly.** Pango picks up state that would break parity, so WOR-317 S3a does all of the following, and its acceptance checks identical output under `GDK_SCALE=2` and `text-scaling-factor` 0.7273:
  - the font map is pangoft2/PangoFc bound to the private `FcConfig` (`pango_fc_font_map_set_config`), so `50-omarchy.conf` never applies;
  - sizes are absolute (`pango_font_description_set_absolute_size`), so Pango's 96-DPI point conversion (1.333×) never applies;
  - hinting is off and `pango_context_set_round_glyph_positions(FALSE)` is set;
  - the context is tkzmux's own, never a GtkWidget's, so GtkSettings (including `gtk-xft-dpi` and the text-scaling factor) never reach it.
- **Tracking is compensated.** Pango letter-spacing is not CoreText `.kern`: it splits the spacing around each cluster, trims it at line edges and disables optional ligatures. WOR-317 S3a applies WOR-312's Inter per-size tracking and run `.kern` so that advances match WOR-316's single-line path bit for bit, as its acceptance requires.
- **Linkage.** `libpango-1.0.so.0` and `libpangoft2-1.0.so.0` are allowed as direct NEEDED entries in `[tkzmux]` and `[tests]` ([linkage-policy.txt](linkage-policy.txt) group `[@text-layout]`). Both are already in GTK's closure, so no library is added to the process. `[tkzmux-vtdump]` and `[tkzmux-hook]` do not allow them.
- **GTK's pkg-config link flags still have to be contained.** `pkg-config --libs gtk4` lists `-lpangocairo-1.0 -lpango-1.0 -lgdk_pixbuf-2.0 -lcairo-gobject -lcairo -lgraphene-1.0`. A `.systemLibrary(pkgConfig: "gtk4")` link without `--as-needed` records all of them as NEEDED; in the self-test a probe linked `--no-as-needed` failed `[tkzmux]` with five violations, and with `--as-needed` it kept only `libc.so.6`. WOR-314 S1 (CGtk) links with `-Xlinker --as-needed` in the Linux branch, or otherwise keeps these entries out. (It does the latter: SwiftPM puts `--as-needed` after gtk4's `-l` flags, so CGtk links through its own `.pc` instead; [build.md](build.md#linux-ci).) `check-linkage.sh` catches it either way.
- **IME preedit attributes.** `gtk_im_context_get_preedit_string` returns a `PangoAttrList` (`gtk/gtkimcontext.h:118-121`). WOR-315 may read or free it directly now that libpango is allowed; tkzmux still draws the preedit style itself from theme tokens (ADR-0004 §9).

## Consequences

- **WOR-300:**
  - S1 commits the D2 pin (tag and digest) without re-arguing it.
  - S4 measures the NEEDED/PT_INTERP set and the highest `GLIBC_` version. If a measurement differs from the policy, the change is made in [linkage-policy.txt](linkage-policy.txt) and D1, and nowhere else.
- **Default-stdlib release build vs `[tkzmux]` (decided in WOR-303 S2).** `[tkzmux]` says `stdlib static`, but WOR-303 S2's CI checks a release build made with the default stdlib, and that build NEEDs `libswiftCore.so` and carries a toolchain RUNPATH. Until WOR-323 S1 adds per-product `-static-stdlib`, that check fails by design. WOR-303 S2 had to pick one of:
  - add the same Linux-only per-product flag early;
  - check against a deliberately marked temporary section.

  It picked the temporary section, `[tkzmux-default-stdlib]` in [linkage-policy.txt](linkage-policy.txt): `[tkzmux]`'s rules with `stdlib dynamic` and the toolchain RUNPATH allowed. The early flag was measured and rejected: a `-static-stdlib` stub linked on the Arch CI image needs `GLIBC_2.44`, so `check-binary.sh` would fail the `glibc-max 2.35` line until WOR-323 S1 moves the release link to a glibc ≤ 2.35 environment ([build.md](build.md#linux-ci)). WOR-323 S1 deletes the section and points CI at `[tkzmux]`. The global `--static-swift-stdlib` stays forbidden.
- **The hook has no RUNPATH.** SwiftPM's local `$ORIGIN` rpath has to be turned off for it, for example with `--disable-local-rpath` or a linker flag. WOR-305 S6 confirms the mechanism.
- **Mac and Linux use different compilers (6.2 vs 6.3.x).** Shared code is written to the older one. TESTS.md keeps listing toolchain-specific errors.
- **CI follows the user's distro.** Breakage from a rolling Arch update surfaces in the scheduled job, and the required job stays reproducible through the digest pin.
- **Users on Ubuntu 24.04 or older cannot run the GTK app** (GTK 4.14). The non-GTK targets and the hook still build there.
- **Scale and fonts are deterministic.** Scale and font output do not depend on the user's `GDK_SCALE`, text scaling, fontconfig or FreeType environment. Child shells still see the user's environment unchanged.
- **Installed files and user data never mix.** `make uninstall` (WOR-324) removes only manifest paths under the prefix and never touches `$XDG_DATA_HOME/tkzmux`.

## Alternatives considered

- **`-Dcpu=znver5` or `native`:** rejected for committed artifacts. They SIGILL without AVX-512 and gain nothing in the AVX2-capped kernels. They stay a local WOR-323 measurement.
- **`-Dcpu=baseline` (Ghostty's distro default):** rejected. It costs AVX2 codegen on the Zig side for no portability anyone here needs. x86-64-v3 excludes only pre-Haswell CPUs and low-end parts without AVX2.
- **glibc floor 2.34 (RHEL 9) or 2.39 (noble only):** 2.34 adds RHEL 9 coverage that nothing here targets. 2.39 would drop jammy-built toolchains for no gain.
- **Swift 6.4:** rejected for now. Its build system changes, it is two minors from the Mac, and Swift Build's handling of SE-0482 static-library bundles on Linux is unproven.
- **Swift 6.2.x:** kept as the fallback (D2).
- **GTK 4.14 floor (noble):** rejected. It has no `set_black_background` or `set_color_state`, so Option B's offload path cannot be built.
- **`GTK_CHECK_VERSION` for newer APIs:** rejected (D4). It is compile-time only.
- **Ubuntu as the required CI image:** rejected. It fails the GTK floor.
- **Two required jobs (Arch + noble full build):** impossible for the same reason.
- **A single `se.tkz.tkzmux` id for debug builds:** rejected (D6). Dev runs would be absorbed by the installed instance.
- **Resources in `share/tkzmux`:** rejected (D7). It collides with `$XDG_DATA_HOME/tkzmux` under `PREFIX=~/.local`.
- **Sockets in `$XDG_DATA_HOME`:** rejected. That is persistent storage, so stale sockets survive crashes.
- **`update.log` in `$XDG_STATE_HOME`:** deferred. It is allowed by the spec, but it would add a root for one file.
- **Honouring `GDK_SCALE`, system fontconfig, or `FREETYPE_PROPERTIES`:** rejected. Each one breaks pixel parity on this machine.
- **In-repo UAX #14 line breaking plus UAX #9 bidi, with HarfBuzz shaping (the S2 recommendation):** rejected in S6 (D10). It makes the layout rules explicit, but it costs line-break tables generated from pinned Unicode data, a bidi implementation and hit-testing, all in WOR-317, for no linkage gain: Pango is already in GTK's closure. The `TextLayout` protocol keeps the door open if Pango's behaviour cannot be matched to the Mac fixtures.
- **Pango with its cairo backend, or a GtkWidget's Pango context:** rejected. Cairo would draw pixels, and a widget context inherits GtkSettings DPI and scaling.
- **Gating on the `ldd` closure:** rejected (D9). GTK's closure contains X11, systemd and dbus.
- **Per-script allow-lists:** rejected. One policy file means one place to change.

## References

**Repository**

- `Package.swift:1` (tools-version 6.2), `Package.swift:113-116` (hook target).
- `.github/workflows/ci.yml:28-30` and `.github/workflows/release.yml:151-153` (Xcode 26.1).
- `TESTS.md:110-118` (Swift 6.3 fixes).
- `vendor/ghostty-vt/COMMIT` (82232ecde55405559dec29c5466cb9e39938cb41).
- `Resources/Info.plist:18` (bundle id).
- `Sources/TkzCore/HookSocket.swift:8-32`, `Sources/AgentBridge/HookServer.swift:181`, `Sources/TkzApp/AgentIntegration.swift:222` (sockets).
- `Sources/TkzTerminalCore/TerminalEnvironment.swift:48,95-106,140`.
- `Sources/Persistence/StateFile.swift:83-94`, `Sources/Persistence/Snapshots.swift:92-106`, `Sources/tkzmux-hook/StatuslineCommand.swift:36-51` (support paths).
- `Sources/AgentBridge/ShimInstaller.swift:118-122,154,203`, `Sources/AgentBridge/StatuslineInstaller.swift:101`, `Sources/AgentBridge/TranscriptUsageReader.swift:63`, `Sources/TkzApp/TerminalHost.swift:247-249,273` (support subdirectories).
- `Sources/TkzApp/Update/UpgradeRunner.swift:41-45` (update log).

**System headers and files** (GTK 4.22.4, as installed)

- `/usr/include/gtk-4.0/gtk/gtkgraphicsoffload.h:70-74`
- `/usr/include/gtk-4.0/gdk/gdkdmabuftexturebuilder.h:103-107`
- `/usr/include/gtk-4.0/gdk/gdktoplevel.h:305-318`
- `/usr/include/gtk-4.0/gtk/gtkaccessible.h:283-284`
- `/usr/include/gtk-4.0/gtk/gtkimcontext.h:118-121`
- `/usr/include/gtk-4.0/gdk/version/gdk-visibility.h:362-367`
- `/usr/include/gtk-4.0/gdk/version/gdkversionmacros.h:243-262`
- `/usr/include/glib-2.0/glib/gmacros.h:1321`
- `/etc/fonts/conf.d/50-omarchy.conf`, `/etc/profile.d/freetype2.sh`

**Sources** (from the WOR-299 research set, with fact-check corrections applied)

- Ghostty build at the pinned commit:
  - PACKAGING.md: https://raw.githubusercontent.com/ghostty-org/ghostty/82232ecde55405559dec29c5466cb9e39938cb41/PACKAGING.md
  - SharedDeps.zig: https://raw.githubusercontent.com/ghostty-org/ghostty/82232ecde55405559dec29c5466cb9e39938cb41/src/build/SharedDeps.zig
  - Zig AVX-512 workaround issue: https://github.com/ziglang/zig/issues/20414
- Swift releases and images:
  - Swift 6.3: https://www.swift.org/blog/swift-6.3-released/
  - Swift 6.4: https://www.swift.org/blog/swift-6.4-released/
  - Swift 6.4 coverage (Xcode 27, Swift Build default): https://www.infoq.com/news/2026/09/swift-6-4-released/
  - ubuntu-24.04 runner image: https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md
  - Docker images: https://hub.docker.com/_/swift
  - mise on Arch: https://mise.jdx.dev/lang/swift.html
- Swift Evolution and static linking:
  - SE-0482 (static-library artifact bundles, Swift 6.2): https://github.com/swiftlang/swift-evolution/blob/main/proposals/0482-swiftpm-static-library-binary-target-non-apple-platforms.md
  - SE-0342 (static runtime, FoundationNetworking): https://github.com/swiftlang/swift-evolution/blob/main/proposals/0342-static-link-runtime-libraries-by-default-on-supported-platforms.md
  - Static Linux SDK: https://www.swift.org/documentation/articles/static-linux-getting-started.html
- swift-foundation XDG mapping: https://raw.githubusercontent.com/swiftlang/swift-foundation/main/Sources/FoundationEssentials/FileManager/SearchPaths/FileManager%2BXDGSearchPaths.swift
- GTK:
  - GTK 4.16 NEWS (Vulkan default on Wayland): https://download.gnome.org/sources/gtk/4.16/gtk-4.16.0.news
  - gtk-font-rendering: https://docs.gtk.org/gtk4/property.Settings.gtk-font-rendering.html
  - GTK blog on fractional scales and hinting: https://blog.gtk.org/2024/03/07/on-fractional-scales-fonts-and-hinting/
- Wayland fractional scale protocol: https://wayland.app/protocols/fractional-scale-v1
- XDG Base Directory spec: https://specifications.freedesktop.org/basedir-spec/latest/
- Pango API: https://docs.gtk.org/PangoFc/method.FontMap.set_config.html, https://docs.gtk.org/Pango/method.FontDescription.set_absolute_size.html, https://docs.gtk.org/Pango/method.Context.set_round_glyph_positions.html
- Other WOR-299 docs: [ADR-0001 charter](adr-0001-charter.md), [ADR-0003 parity](adr-0003-parity.md), [ADR-0004 keys and input](adr-0004-keys-input.md), [ADR-0005 window controls](adr-0005-window-controls.md), [decisions.md](decisions.md), [linkage-policy.txt](linkage-policy.txt), [check-linkage.sh](../../scripts/linux/check-linkage.sh).
