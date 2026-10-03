# Linux port: user decisions

These are the decisions the user made for the tkzmux Linux port. Each one is binding on every Linux issue (WOR-299 to WOR-325) and is applied by the ADRs listed with it. To change a decision, add a new dated entry that supersedes the old one. Never edit an old entry in place.

## Decision log

| # | Date | Decision | Applied in |
|---|---|---|---|
| 1 | 2026-10-02 | Architecture: Option B | [ADR-0001](adr-0001-charter.md) §1-5; [ADR-0002](adr-0002-platform-defaults.md) D3, D9, D10; [ADR-0005](adr-0005-window-controls.md) §1 |
| 2 | 2026-10-02 | The Mac app stays exactly as it is | [ADR-0001](adr-0001-charter.md) §10; [ADR-0003](adr-0003-parity.md) Context 5, §6; [ADR-0004](adr-0004-keys-input.md) §11 |
| 3 | 2026-10-02 | UI font: Inter, bundled on Linux only | [ADR-0001](adr-0001-charter.md) §7; [ADR-0003](adr-0003-parity.md) §6 (substitutes) |
| 4 | 2026-10-02 | Accessibility (AT-SPI) is deferred | [ADR-0001](adr-0001-charter.md) §11 |
| 5 | 2026-10-02 | Super acts as ⌘ while tkzmux has focus | [ADR-0004](adr-0004-keys-input.md) §1-7; [ADR-0005](adr-0005-window-controls.md) §4 (Hyprland snippet) |
| 6 | 2026-10-02 | Linux conventions: PRIMARY, IME, Shift+Insert | [ADR-0004](adr-0004-keys-input.md) §8-9 |
| 7 | 2026-10-02 | Window: Hyprland first, Linux window controls | [ADR-0005](adr-0005-window-controls.md) §1-3 |
| 8 | 2026-10-02 | Linear: about 25 milestone-sized issues | [ADR-0001](adr-0001-charter.md) §12 |

## Decisions

### 1. Architecture: Option B (2026-10-02)

GTK4 is the Linux platform layer: window, input, IME, clipboard, popups, portals, GDBus, the frame clock and a future accessibility path. **GTK never draws a visible pixel.** All pixels come from one tkzmux Vulkan renderer: the terminal plus all chrome, drawn from shared design tokens, with text through tkzmux's own FreeType, HarfBuzz and fontconfig path.

On Linux, "OS frameworks" means glibc, GTK4/GLib/GIO, Vulkan, FreeType, HarfBuzz and fontconfig, plus Pango for paragraph itemization and line breaking only if ADR-0002 picks it. There are still no SwiftPM packages. libcurl, libsystemd, libdbus, libcanberra, libpulse, libdecor and X11 are not linked.

### 2. The Mac app stays exactly as it is (2026-10-02)

There is no convergence milestone. Every Mac-side refactor must keep its goldens byte-identical. Differences that cannot be closed are documented, not fixed by changing the Mac.

### 3. UI font: Inter, bundled on Linux only (2026-10-02)

SF Pro may not ship on non-Apple systems, so Linux bundles Inter (OFL). Its per-size tracking is calibrated against NSFont advance dumps, so that truncation and wrapping decisions match the Mac. The Mac keeps the system font.

### 4. Accessibility (AT-SPI) is deferred (2026-10-02)

A seam is kept in the canvas toolkit, and one backlog issue (WOR-325) is filed.

### 5. Super acts as ⌘ while tkzmux has focus (2026-10-02)

- This uses keyboard-shortcuts-inhibit (`gdk_toplevel_inhibit_system_shortcuts`, Hyprland v1).
- Mac-style glyph hints (⌘⇧P) are kept for parity, Option maps to Alt, and the ⌘-hold cheat sheet becomes a Super hold.
- Ctrl stays with the terminal.
- The shipped Hyprland snippet carries `bindp` (bypass-inhibit) guidance, so the user keeps an escape hatch for critical window-manager binds.

### 6. Linux conventions (2026-10-02)

- Copy-on-select goes into PRIMARY, and middle-click pastes it.
- IME (fcitx5 through text-input-v3) is on by default, with a Settings switch to xkb compose instead.
- Shift+Insert pastes CLIPBOARD.

### 7. Window: Hyprland first, Linux window controls (2026-10-02)

- The window should feel like a Linux app. There are no Mac traffic lights.
- Native window controls (close and so on) appear where the desktop expects them, honouring `gtk-decoration-layout` and xdg_toplevel `wm_capabilities`.
- Everything inside the window matches the Mac.
- Other compositors are best effort.

### 8. Linear: about 25 milestone-sized issues (2026-10-02)

There are no micro-tickets, because the workspace is near the free-plan issue cap. Each issue (WOR-299 to WOR-325) holds an ordered checklist of session-sized steps with acceptance criteria. The issues are grouped under project milestones M0-M11 and linked with blocking relations. One session is one worktree session, following the existing one-ticket rule (`CLAUDE.md:49`).

## Ratified in WOR-299 S6 (2026-10-02)

WOR-299 S6 ratified ADR-0001 to ADR-0005. ADR-0001, ADR-0002 and ADR-0003 are `Accepted (2026-10-02)`. ADR-0004 and ADR-0005 are `Accepted, provisional on WOR-301 S6`, and WOR-301 S6 amends them to `Accepted (final)` or records the fallback.

The user asked for continuous execution and delegated the remaining choices to the ADR recommendations. The items below were therefore accepted under that delegation on 2026-10-02. Each is a new entry, and none of decisions 1-8 was edited.

| # | Item | Verdict | Applied in | Follow-up owner |
|---|---|---|---|---|
| S6-1 | Pango, or in-repo UAX #14 line breaking plus HarfBuzz | **Pango** (pangoft2 on the private `FcConfig`) for paragraph itemization, line breaking, bidi and glyph positions only. tkzmux rasterizes every glyph. pangocairo and cairo stay denied. This settles decision 1's "Pango only if chosen". | [ADR-0002](adr-0002-platform-defaults.md) D10; [ADR-0001](adr-0001-charter.md) §3; [linkage-policy.txt](linkage-policy.txt) `[@text-layout]` | WOR-317 S3a/S3b (`PangoTextLayout`), WOR-314 S1 (CGtk's own `.pc`) |
| S6-2 | Omarchy SUPER+digits: claim or bypass | **Claim.** tkzmux keeps ⌘1-9 as Super+1-9 while focused. Omarchy workspace switching over tkzmux needs the bypass flag (`bindp` / `dont_inhibit`) on those binds, which is documented as an opt-out, not shipped. SUPER+0 is bypassed. | [ADR-0005](adr-0005-window-controls.md) §4; [ADR-0004](adr-0004-keys-input.md) Consequences | WOR-314 S3, WOR-324 S2 (`docs/linux/hyprland.md`) |
| S6-3 | Test-only libxkbcommon link | **Allowed** in `[tests]` only, for WOR-315 S1's `CXKBCommon` layout-fixture generator. Never an app NEEDED. | [ADR-0001](adr-0001-charter.md) §9; [linkage-policy.txt](linkage-policy.txt) `[tests]` | WOR-315 S1 |
| S6-4 | Hyprland `terminal` tag on the tkzmux window | **Apply it**, with a later `opacity 1 1` rule, as ADR-0005 recommends. | [ADR-0005](adr-0005-window-controls.md) §4 | WOR-314 S3 applies; WOR-301 S6 revisits with measurements |
| S6-5 | Parity reference machine | **The GitHub-hosted `macos-26` runner with Xcode 26.1.** No developer Mac is available. Recorded as a user decision in WOR-299 S3, and it replaces "the pinned dev Mac" in every issue. | [ADR-0003](adr-0003-parity.md) §5 | WOR-322 S2, WOR-312, WOR-316, WOR-311 (wording) |
| S6-6 | Conflicts between issue texts | Preedit **is drawn** on Linux (WOR-299 S4 wins over WOR-315 S4). The fallback *Keyboard Shortcuts* palette row is the **one** sanctioned Linux-only palette row. The search overlay accepts **Ctrl+Enter** in both modes. The committed reference budget is **9 MiB** (4 MiB + 5 MiB at the time; renegotiated 2026-10-03 to 4.5 MiB + 4.5 MiB, ADR-0003 §5), matching WOR-307, WOR-312 and WOR-322 rather than WOR-299's 5 MB. | [ADR-0004](adr-0004-keys-input.md) §3.3, §5, §9; [ADR-0003](adr-0003-parity.md) §5 | WOR-315 S4, WOR-319, WOR-322 S2 |

## Open items

Every item has an owner issue. Items marked *resolved* only need the owner to update its issue text or apply the verdict.

| Item | Recommendation / state | Owner |
|---|---|---|
| Inhibit grant, `INHIBIT_SHORTCUTS` bit, Super+mouse coverage, SUPER+C/V under inhibit, bare Super in fallback mode, fcitx5 and `se` dead-key chords, the window-rule name that turns inhibiting off | Open fields in [ADR-0004](adr-0004-keys-input.md) | WOR-301 S6, which finalizes ADR-0004 |
| Capability bits, effective `gtk-decoration-layout`, `titlebar_gesture` result on Hyprland; `dont_inhibit` on mouse and temporary binds | Open fields in [ADR-0005](adr-0005-window-controls.md) | WOR-301 S6, which finalizes ADR-0005 (WOR-324 S2 for `dont_inhibit` if needed) |
| The `terminal` tag, with measured inputs | Applied (S6-4) | WOR-301 S6 revisits |
| Swift toolchain pin (6.3.x recommended, `--build-system native`) | Recommended in [ADR-0002](adr-0002-platform-defaults.md) D2 | WOR-300 S1 commits it |
| `libstdc++.so.6`, `libgcc_s.so.1` and `ld-linux-x86-64.so.2` under `-static-stdlib` | *Resolved:* measured in WOR-300 S4 ([spikes.md](spikes.md#needed-pt_interp-and-runpath)). Every `-static-stdlib` binary NEEDs exactly these three plus `libc.so.6` and `libm.so.6`, with or without Foundation, under both build systems; the `measured-by` marks are removed | WOR-305 S6 (hook: glibc or musl) |
| glibc ceiling of a release link. A `-static-stdlib` link on a glibc 2.44 host can reference symbols newer than the 2.35 floor. | `glibc-max 2.35` stays; the release link must run in a glibc ≤ 2.35 environment, or the ceiling is raised in [ADR-0002](adr-0002-platform-defaults.md) D1 and the policy. Measured in WOR-300 S4 ([spikes.md](spikes.md#glibc-ceiling)): the archive needs nothing newer than 2.34; the static runtime of the pinned **ubuntu24.04** build needs 2.38 (`__isoc23_*`, `strlcpy`) wherever it is linked; the **ubuntu22.04** build of the same 6.3.3 needs nothing newer than 2.35. So 2.35 holds only for a release link with the ubuntu22.04 toolchain (`swift:6.3.3-jammy`) on glibc ≤ 2.35; otherwise the ceiling becomes 2.38. `check-binary.sh` enforces it; a `-static-stdlib` probe linked on the Arch host reaches `GLIBC_2.44` ([vendoring.md](vendoring.md), Probe matrix) | WOR-302 S4 (`check-binary.sh`) enforces; WOR-323 S1 picks the release toolchain build and link environment |
| A default-stdlib release build fails `[tkzmux]` (`stdlib static`) | *Resolved in WOR-303 S2:* CI checks the temporary `[tkzmux-default-stdlib]` section; a per-product `-static-stdlib` linked on Arch needs `GLIBC_2.44` and would fail `glibc-max` ([ADR-0002](adr-0002-platform-defaults.md) Consequences, [build.md](build.md#linux-ci)) | WOR-323 S1 deletes the section and checks `[tkzmux]` |
| Swift runtime sonames allowed in `[tests]` | *Resolved in WOR-303 S2:* the first Linux test runner NEEDs 15 runtime sonames (Swift runtime, Foundation, dispatch, BlocksRuntime, Testing, `lib_Testing_Foundation`, XCTest) plus `libm.so.6` and `libc.so.6`, all matched by `[@swift-runtime]`; CI gates it against `[tests]` ([build.md](build.md#linux-ci)) | WOR-303 S2 |
| CGtk link must not record pangocairo, cairo, gdk_pixbuf or graphene as NEEDED | *Resolved in WOR-314 S1:* not with `--as-needed`, which SwiftPM places after gtk4's `-l` flags, where it changes nothing (measured). CGtk links through its own `Sources/CGtk/tkzmux-gtk4.pc` (gtk4's cflags via `Requires.private`, `Libs` only gtk-4, gio, gobject, glib); the `tkzmux` stub passes `[tkzmux-default-stdlib]` ([build.md](build.md#linux-ci)) | WOR-314 S1 |
| `tkz_gtk_symbol` helper: WOR-314 places it in S1, WOR-325 refers to S6 | S1 ([ADR-0002](adr-0002-platform-defaults.md) D4) | WOR-314 S1; WOR-325 updates its reference |
| `tkzmux-hook` with no RUNPATH at all | *Resolved in WOR-305 S6:* the shipped hook is the fully static musl build, which has no dynamic section and so no RUNPATH. The glibc `-static-stdlib` hook keeps SwiftPM's `$ORIGIN` under `--build-system native` unless built with `--disable-local-rpath`; the `swiftbuild` backend adds none ([hook.md](hook.md)) | WOR-305 S6 |
| `tkzmux-hook` libc-only, or the Static Linux SDK (musl) | *Resolved in WOR-305 S6:* the Static Linux SDK (musl), pinned in [dev.md](dev.md). It passes `[tkzmux-hook]` and `check-binary.sh` unchanged and execs in about half the time of the glibc link, which fails `glibc-max 2.35` wherever it is linked ([hook.md](hook.md)) | WOR-305 S6 |
| Static or dynamic stdlib for the app | `[tkzmux]` stays provisional in linkage-policy.txt | WOR-323 S2 |
| TkzPlatform `ProcessMetrics` sampler (WOR-311's text names WOR-304 S6; WOR-304 hands it to WOR-309 S1) | *Linux half landed in WOR-311 S7* ([platform.md](platform.md#process-metrics-processmetrics)), which `vtdump bench` needed. The macOS back-end and `HostProcessMetrics` moving onto it stay with WOR-309 S1. | WOR-309 S1 |
| `state-validate`'s schema check | It requires the version this build writes (`PersistedState.currentSchemaVersion`, 4 today), not the literal 1 in the WOR-311 text. The old `plutil` check compared against 1, and every file has failed it since schema v2. | WOR-311 S7 |
| `.mark` snapping kind | Added in [ADR-0003](adr-0003-parity.md) §2 | WOR-307 S3, WOR-316 S1 |
| "Dev Mac" wording in other issues | Reads as the reference runner (S6-5) | WOR-322 S2, WOR-312 S1-S2, WOR-316 S2, WOR-311 |
| Full-window capture on the macOS runner | Unproven; offscreen composition is the fallback ([ADR-0003](adr-0003-parity.md) Consequences) | WOR-322 S4 |
| Preedit drawn on Linux; the one Linux-only palette row; Ctrl+Enter in the search overlay | Resolved (S6-6) | WOR-315 S4, WOR-319 |
| Ctrl+click precedence against mouse reporting | [ADR-0004](adr-0004-keys-input.md) §10 | WOR-310 (router test), then WOR-315 S5 |
| fcitx5 matches exact modifier sets (Ctrl+Shift+Alt+P vs its Ctrl+Alt+P) | Manual check | WOR-315 S3 |
| GTK inspector bindings never fire before tkzmux's capture-phase match | Test | WOR-315 S2 |
| The compositor's dmabuf-feedback `main_device`, which GDK does not publish | *Resolved in WOR-314 S4:* read once on GDK's own `wl_display` through a private event queue (`tkz_dmabuf_main_device`, TkzLinuxShim), with every libwayland call looked up by dlsym, because libgtk-4 already has libwayland-client loaded. No NEEDED entry, so the `libwayland-*` deny holds ([presentation.md](presentation.md)) | WOR-314 S4 |
| "One persistent GdkTexture per ring slot makes GTK reuse wl_buffers" (WOR-301 probe) | *Refuted in WOR-314 S4:* GTK 4.22.4 creates a `wl_buffer` per attach (`create` and a roundtrip) and destroys it on release. 1,194 `create`s for 1,194 frames. Textures are still kept per slot, and their reference count is the slot's release signal. Removing the per-frame roundtrip needs an own subsurface ([presentation.md](presentation.md#slots-textures-and-wl_buffers)) | WOR-323 measures; WOR-301's raw-Wayland fallback if it matters |
| Offload at fractional scale needs whole device pixels (GTK `scaled_rect_is_integral`) | *Resolved in WOR-314 S4:* the canvas is snapped down to a multiple of 5 logical pixels at 1.6, and the strip of less than 5 px is the window's black background ([presentation.md](presentation.md#whole-device-pixels-the-5-pixel-rule-at-16)) | WOR-318 picks the strip's colour |
| Byte-exact checkerboard via `grim` on Hyprland 0.56.2 | Not reachable: at integral positions Hyprland reads black as 0x01 and white as 0xfe (a slight horizontal resample), the same through GSK composition. At fractional positions it resamples fully. The texel mapping itself is 1:1 ([presentation.md](presentation.md#results-on-the-reference-machine-2026-10-03-hyprland-0562-dp-4-at-16-120-hz)) | WOR-322 (in-app readback gate), WOR-323 |
| GNOME and KDE cells marked *inferred* | Non-gating smoke | WOR-314 S6 |
| SUPER+SHIFT+comma becomes a claim once `reloadConfig` has a handler | Bypassed until then | WOR-324 S5 (audit) |
| Rewording of the `tkzmux-hook` row in CLAUDE.md for Glibc | *Resolved:* "libc only (Darwin/Glibc/Musl), never Foundation"; HookHygieneTests and a ci-linux grep enforce it | WOR-305 S5 |
| Two-platform rewrite of CLAUDE.md and README (macOS-only wording at `CLAUDE.md:3`) | Unchanged until then | WOR-324 |
| Inter tracking calibration | Pinned Inter 4.x, tracking fitted to NSFont dumps | WOR-312 S8 |
| Folder picker without a FileChooser portal | Fall back to a tkzmux-drawn `DialogSpec` and log the reason | WOR-320 S4 |
| Accessibility bridge | Deferred, seam kept | WOR-325 |
