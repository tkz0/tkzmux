# tkzmux on Linux: docs index

This directory holds the tracked documents for the Linux port of tkzmux: Option B, with GTK4 as the platform shell and every pixel drawn by tkzmux through Vulkan. The work is tracked as Linear issues WOR-299 to WOR-325, grouped in milestones M0-M11. Start with the charter, then the decision log.

Linux docs live here and are committed. `docs/perf.md` stays local-only (see `.gitignore`), and Linux performance budgets go in `perf-budgets.md` instead.

## Decisions

| Document | Covers | Status | Written in |
|---|---|---|---|
| [decisions.md](decisions.md) | User decisions 1-8 (2026-10-02), the WOR-299 S6 ratification verdicts, and every open item with its owner | Living log | WOR-299 S1; S6 verdicts added in WOR-299 S6 |
| [ADR-0001: charter and dependency policy](adr-0001-charter.md) | Option B, allow-list and deny-list of direct NEEDED libraries, GTK closure, stdlib linking, runtime reliance, image formats, test-only libxkbcommon, Mac unchanged, accessibility deferral | Accepted (2026-10-02) | WOR-299 S1 |
| [ADR-0002: platform defaults](adr-0002-platform-defaults.md) | glibc floor and CPU baseline, Swift pin, GTK 4.16 floor, CI images, APIs newer than 4.16, app-id, XDG layout, scale handling, text layout (Pango for layout, tkzmux for pixels), linkage enforcement | Accepted (2026-10-02) | WOR-299 S2 |
| [ADR-0003: parity](adr-0003-parity.md) | Parity definition in logical points, snapping rules, layer thresholds and tools, reference machine and budget, in-app readback, unreachable items and substitutes | Accepted (2026-10-02) | WOR-299 S3 |
| [ADR-0004: keys and input](adr-0004-keys-input.md) | Super as ⌘, the 39-chord table with Super and fallback rows, reserved chords, `se` layout matching, clipboard and PRIMARY, IME, Alt | Accepted, provisional on WOR-301 S6 | WOR-299 S4 |
| [ADR-0005: window controls](adr-0005-window-controls.md) | Linux window controls, header strip, Hyprland snippet policy, the `terminal` tag, Omarchy bind collisions | Accepted, provisional on WOR-301 S6 | WOR-299 S5 |
| [linkage-policy.txt](linkage-policy.txt) | The single machine-readable allow/deny list per product (`[tkzmux]`, `[tkzmux-hook]`, `[tkzmux-vtdump]`, `[tests]`, and the temporary `[tkzmux-default-stdlib]` until WOR-323 S1), enforced by `scripts/linux/check-linkage.sh` | Living policy; `[tkzmux]` provisional until WOR-323 S2 | WOR-299 S2; amended by WOR-300 S4, WOR-302 S4, WOR-323 S2 |

All five ADRs were ratified in WOR-299 S6 on 2026-10-02. ADR-0004 and ADR-0005 are accepted provisionally, and WOR-301 S6 fills their open fields and amends them to `Accepted (final)` or records the fallback. An ADR changes only through a reviewed PR that amends it; a change to a user decision is a new dated entry in decisions.md.

## Other docs, by milestone

Docs that do not exist yet are listed by file name and become links when they are written. Each is created by the session listed with it. Later sessions may extend a doc, but they do not start a second doc on the same topic.

| Document | Topic | Created by |
|---|---|---|
| [dev.md](dev.md) | Toolchain on Omarchy/Arch, container tag and digest, pacman and apt package table | WOR-300 S1 |
| [spikes.md](spikes.md) | GtkApplication, libdispatch, @MainActor and Swift Testing spike results; libghostty-vt link matrix, NEEDED table and glibc ceiling; go/no-go | WOR-300 S2-S4 |
| `spike-presentation.md` | Vulkan dmabuf → GdkDmabufTexture → GraphicsOffload spike, offload debug variable | WOR-301 S1 |
| [vendoring.md](vendoring.md) | libghostty-vt for Linux: artifact bundle, compiler_rt localization, ABI files, terminfo, binary checks | WOR-302 S4 |
| [build.md](build.md) | Two-platform Package.swift, build-system choice, Linux CI, resource lookup, version stamping | WOR-303 S1; extended by WOR-303 S2, S3, S4 |
| [platform.md](platform.md) | TkzPlatform: logging and signposts on Linux, the path table (XDG) and platform back-ends | WOR-304 S2; extended by WOR-304 S3 |
| [hook.md](hook.md) | `tkzmux-hook` on Linux: timing results and linkage choice | WOR-305 S6 |
| `agents.md` | AgentBridge on Linux, real-agent probe traces, dotfile-sync collisions | WOR-306 S1 |
| `parity.md` | Layout-dump schema, snapping kinds, golden update flow; then the parity runner and reference regeneration | WOR-307 S2; extended by WOR-322 |
| `seams.md` | Seam protocols and their Linux owners | WOR-308 S2 |
| `lifecycle.md` | Close, shutdown and signal handling mapped to the Mac lifecycle | WOR-309 S7 |
| `mainactor-audit.md` | @MainActor and main-queue audit for the GLib main loop | WOR-309 S7 |
| `test-matrix.md` | Which suites stay macOS-only and which run on Linux | WOR-309 |
| `markdown-parity.md` | Remaining Markdown-renderer differences | WOR-310 S7 |
| [perf-budgets.md](perf-budgets.md) | Linux performance budgets and measurements (Linux counterpart of the local-only `docs/perf.md`): `vkCreateInstance` per driver set, frame encode and GPU time (`vtdump bench-frame`) | WOR-313 S1; extended by WOR-313 S6, WOR-323 |
| `hyprland.md` | Hyprland snippet: opacity, `terminal` tag and Settings-float rules, plain-Hyprland form | WOR-314 S3; extended by WOR-324 |
| `input.md` | Linux shortcut table, colliding window-manager binds, IME setup | WOR-315 S3 |
| `canvas-toolkit.md` | Canvas toolkit core: display list, layout, overlays, glass parity numbers | WOR-316 S7 |
| `widgets.md` | Canvas widgets: measured timings, scroll recordings, token table, bidi scope | WOR-317 S3 |
| `window-geometry.md` | Window-geometry persistence policy (size only) | WOR-318 S1 |
| `services.md` | Desktop services over GDBus, sound, open and reveal, update check | WOR-320 |
| `memory-and-cgroups.md` | Per-session cgroups, glibc memory semantics, memory probe | WOR-321 S2 |
| `install.md` | Install layout, `.desktop` file, icon export steps | WOR-324 S2 |
| `parity-audit.md` | Final parity checklist, generated by `tkzmux-vtdump parity-checklist` | WOR-324 S5 |
| `accessibility.md` | AT-SPI bridge coverage and known gaps | WOR-325 S5 |

## Scripts

| Script | Role | Created by |
|---|---|---|
| `scripts/linux/check-linkage.sh <elf> <section>` | The only NEEDED check; reads [linkage-policy.txt](linkage-policy.txt) | WOR-299 S2 |
| `scripts/linux/dev-env.sh [--smoke] [--container]` | Read-only host check against [dev.md](dev.md): toolchain pin, every package later issues rely on, each gap with its install command | WOR-300 S1 |
| `scripts/linux/check-binary.sh` | compiler_rt `@plt`, GLIBC symbol ceiling and GNU_STACK checks; calls `check-linkage.sh` | WOR-302 S4 |

## Rules that apply to every Linux change

- The Mac app does not change: Mac goldens stay byte-identical, and macOS CI stays green ([ADR-0001](adr-0001-charter.md) §10).
- New libraries enter only through [linkage-policy.txt](linkage-policy.txt), each with a justification. Other docs and scripts refer to it and never copy its lists.
- cmux and Kitty are GPL-3, and their code is never copied. Ghostty (MIT) may be read for reference.
