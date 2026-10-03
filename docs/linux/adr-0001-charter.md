# ADR-0001: Linux port charter and dependency policy

- **Status:** Accepted (2026-10-02)
- **Date:** 2026-10-02
- **Issue:** WOR-299 S1, ratified in WOR-299 S6
- **Applies decisions:** 1, 2, 3, 4 and 8 from [decisions.md](decisions.md)
- **Related:** [ADR-0002](adr-0002-platform-defaults.md) (platform defaults), [ADR-0003](adr-0003-parity.md) (parity), [ADR-0004](adr-0004-keys-input.md) (keys and input), [ADR-0005](adr-0005-window-controls.md) (window controls), [linkage-policy.txt](linkage-policy.txt), [index](README.md)

## Context

tkzmux is a macOS-only app today. It is written in Swift 6.2 on AppKit, draws with its own Metal renderer and CoreText fonts, and vendors libghostty-vt as an arm64 xcframework (`Package.swift:27-30`, `CLAUDE.md:3`). Its dependency rule is short: "No third-party dependencies beyond libghostty-vt" (`CLAUDE.md:53`), and the manifest declares no package dependencies (`Package.swift:7-130` has no package-level `dependencies:` argument).

On 2026-10-02 the user decided to port tkzmux to Linux (decisions 1-8 in [decisions.md](decisions.md)). The target is their own machine: Omarchy/Hyprland on Wayland at fractional scale 1.6, x86_64. The goals stay the same as on the Mac: near pixel parity, full feature parity, one repo building both binaries, and runtime speed ahead of development speed.

Three architectures were researched and scored (raw research and fact-check corrections in the WOR-299 research set; summary in `designs[1]`):

- **A:** GTK4 widgets with CSS and a GtkGLArea terminal.
- **B:** GTK4 as the platform shell only, with every pixel drawn by tkzmux.
- **C:** raw Wayland with no toolkit.

The user chose **Option B**. Every later Linux issue needs fixed answers to the questions this ADR settles:

- What "OS frameworks only" means on Linux.
- Which libraries may appear as direct `NEEDED` entries, and which may not.
- What the app relies on at runtime without linking it.
- What "the Mac app stays unchanged" means in practice.

Two facts from the research shape the answers:

1. **GTK's closure is large.** `ldd /usr/lib/libgtk-4.so.1` lists 112 lines on the development host (GTK 4.22.4, measured again on 2026-10-02). Among them are libX11, libsystemd, libdbus-1, libtiff, gstreamer, cups and glycin. Option B is only consistent with the dependency goal if GTK is treated as the Linux counterpart of AppKit. Gating on the full closure would fail every build, so gates look at direct `NEEDED` entries only.
2. **Foundation on Linux carries extra links.** `URLSession` lives in FoundationNetworking, which links libcurl dynamically. SE-0342 says it "cannot be statically linked at this time". The repo's only `URLSession` is `Sources/TkzApp/Update/UpdateChecker.swift:99`, behind the injectable `Fetch` seam at `:29`. The repo has no `XMLParser` use, so FoundationXML and libxml2 are never needed.

## Decision

### 1. Option B: GTK never draws a visible pixel

GTK4 is the Linux platform layer. It supplies the window, input, IME, clipboard, popup surfaces, portals, GDBus, the frame clock and a future accessibility path. All visible pixels come from one tkzmux Vulkan renderer: the terminal and all chrome, drawn from shared design tokens, with text through tkzmux's own FreeType, HarfBuzz and fontconfig path.

Concretely:

- **No visible GtkWidget.** The only widgets are the canvas host (a GtkGraphicsOffload holding the tkzmux canvas) and invisible containers. Popovers and windows that exist for platform reasons hold a tkzmux canvas and nothing else.
- **No GTK client-side decorations.** No GTK titlebar, no GTK shadow, no GtkHeaderBar. Window controls are drawn by tkzmux (ADR-0005).
- **No in-process file chooser.** GtkFileDialog draws its own in-process GtkFileChooserDialog when no portal is available, and does so silently. To prevent that:
  - The folder picker calls `GtkFileDialog` only when the session bus name `org.freedesktop.portal.Desktop` has an owner and that owner exposes `org.freedesktop.portal.FileChooser`.
  - Otherwise it falls back to a tkzmux-drawn `DialogSpec` with a path field and logs why (WOR-320 S4).
  - A portal chooser is drawn by the portal's own process, not by tkzmux. On Hyprland, `xdg-desktop-portal-hyprland` has no FileChooser, so the GTK portal backend serves it. That window is a documented parity exclusion (ADR-0003).

### 2. No SwiftPM packages

libghostty-vt stays the only third-party code (`CLAUDE.md:53`). On Linux it comes in as a vendored SE-0482 static-library artifact bundle (WOR-302), not as a package. System libraries enter through `.systemLibrary` targets with `pkgConfig` names. These are the OS frameworks of the Linux build, not packages.

### 3. Allow-list: direct NEEDED entries

"OS frameworks" on Linux means the libraries below. A product may NEED only these, plus whatever its stdlib mode and WOR-300 S4's measurements add (see section 6). [linkage-policy.txt](linkage-policy.txt) (WOR-299 S2) is the single machine-readable source, and `scripts/linux/check-linkage.sh` enforces it. This table is the rationale and must not be copied into other checks.

| Library (soname) | Justification | Arch package | Ubuntu 24.04 runtime (headers) |
|---|---|---|---|
| glibc: `libc.so.6`, `libm.so.6` | The C runtime every Linux process uses. The Static Linux SDK (musl) is ruled out for the app because `dlopen` does not work there and the Vulkan loader needs it to load ICDs. | `glibc` | `libc6` (`libc6-dev`) |
| `libgtk-4.so.1`, **≥ 4.16** | Platform shell: window, input, IME, clipboard, popups, portals, frame clock. 4.16 is the floor because `gtk_graphics_offload_set_black_background` and `gdk_dmabuf_texture_builder_set_color_state` are `GDK_AVAILABLE_IN_4_16` (`/usr/include/gtk-4.0/gtk/gtkgraphicsoffload.h:70-74`, `gdk/gdkdmabuftexturebuilder.h:103-107`). ADR-0002 owns the floor. | `gtk4` | `libgtk-4-1` (`libgtk-4-dev`). Noble ships 4.14.2, below the floor, so noble builds only non-GTK targets (ADR-0002). |
| `libglib-2.0.so.0`, `libgobject-2.0.so.0`, `libgio-2.0.so.0` | GObject subclassing in TkzLinuxShim, the GLib main loop that owns the main thread, and GDBus. GDBus replaces libdbus-1 and libsystemd. | `glib2` | `libglib2.0-0t64` (`libglib2.0-dev`) |
| `libvulkan.so.1` | The loader for the one renderer. Drivers (ICDs) are loaded by the loader at runtime and are never NEEDED. | `vulkan-icd-loader` | `libvulkan1` (`libvulkan-dev`) |
| `libfreetype.so.6` | Glyph loading and rasterization, replacing CoreText. | `freetype2` | `libfreetype6` (`libfreetype-dev`) |
| `libharfbuzz.so.0` | Shaping for terminal grapheme clusters and chrome labels. | `harfbuzz` | `libharfbuzz0b` (`libharfbuzz-dev`) |
| `libfontconfig.so.1` | Fallback-font discovery through a private `FcConfig`, with bundled faces first. | `fontconfig` | `libfontconfig1` (`libfontconfig-dev`) |
| `libpango-1.0.so.0`, `libpangoft2-1.0.so.0` | Paragraph itemization, line breaking, bidi and glyph positions for chrome text only, on pangoft2 over the private `FcConfig`. Rasterization stays in tkzmux's FreeType path. Chosen in ADR-0002 D10 and ratified in WOR-299 S6 (2026-10-02). Already in GTK's closure, so it adds no new library to the process. `libpangocairo` stays denied. | `pango` | `libpango-1.0-0`, `libpangoft2-1.0-0` (`libpango1.0-dev`) |

### 4. Deny-list: never a direct NEEDED entry

Some of these sit in GTK's transitive closure, and that is accepted (section 5). They must never be NEEDED by a tkzmux binary. The checker fails any soname that is not on the allow-list anyway. The deny-list names the libraries most likely to creep in and records why each one is refused, so that adding one later means removing a deny line deliberately.

Two other groups are allowed only conditionally, and only through linkage-policy.txt:

- The Swift runtime libraries (`libswift*.so`, `libFoundation*.so`, `libdispatch.so` and so on), only in a section that declares `stdlib dynamic`.
- `libstdc++.so.6`, `libgcc_s.so.1` and `ld-linux-x86-64.so.2`, only as measured by WOR-300 S4 (section 6).

| Library (soname) | Why denied, and what replaces it | Arch package | Ubuntu 24.04 package |
|---|---|---|---|
| `libcurl.so.4`, and FoundationNetworking (`libFoundationNetworking.so`, or the static archive with its libcurl NEEDED) | Third-party HTTP/TLS stack, and it cannot be linked statically (SE-0342). The update check spawns `/usr/bin/curl` through the existing `Fetch` seam (`UpdateChecker.swift:29`; WOR-320 S6). | `curl` | `libcurl4t64` |
| FoundationXML (`libFoundationXML.so`), `libxml2.so.*` | No XML parsing exists in the repo. libxml2's soname also differs between Arch (`libxml2.so.16`) and Ubuntu (`libxml2.so.2`), so linking it would break portability. Plists are read through CoreFoundation's own parser. | `libxml2` | `libxml2` |
| `libsystemd.so.0` | sd-bus is a second D-Bus stack. The systemd user manager is reached over GDBus. | `systemd-libs` | `libsystemd0` |
| `libdbus-1.so.3` | A second D-Bus stack. GDBus covers every bus call. | `dbus` | `libdbus-1-3` |
| `libcanberra.so.0` | Event-sound library. The ready sound spawns `pw-play` (falling back to `paplay`) on a bundled CC0 sample (WOR-320). | `libcanberra` | `libcanberra0t64` |
| `libpulse.so.0`, `libpipewire-0.3.so.0` | Audio client libraries for one short sample. Spawning a player costs nothing at idle. | `libpulse`, `libpipewire` | `libpulse0`, `libpipewire-0.3-0t64` |
| `libdecor-0.so.0` | Client-side decoration library. GTK negotiates xdg-decoration and tkzmux draws its own controls (ADR-0005). | `libdecor` | `libdecor-0-0` |
| `libX11.so.6` (direct) | tkzmux is Wayland-only. X11 is reachable only through GTK. | `libx11` | `libx11-6` |
| `libwayland-client.so.0` (direct) | GTK owns the `wl_display`. Wayland state is read through GDK API, for example `gdk_display_get_dmabuf_formats()`. WOR-313's `vtdump gpu` is headless. | `wayland` | `libwayland-client0` |
| `libadwaita-1.so.0` | A widget and style library. It draws pixels, which Option B forbids. | `libadwaita` | `libadwaita-1-0` |
| `libnotify.so.4` | Notifications go over GDBus to `org.freedesktop.Notifications` (WOR-320). | `libnotify` | `libnotify4` |
| SDL (`libSDL2-2.0.so.0`, `libSDL3.so.0`) | A second platform layer next to GTK. | `sdl2-compat`, `sdl3` | `libsdl2-2.0-0`; SDL3 is not packaged in noble |
| Telemetry and crash reporting (Sentry, analytics SDKs, any phone-home library) | Forbidden on both platforms (`CLAUDE.md:53`). | none (must stay absent) | none (must stay absent) |
| Image codecs: `libheif.so.1`, `librsvg-2.so.2`, `libtiff.so.6` (direct) | Images decode through GdkTexture at runtime (section 8). | `libheif`, `librsvg`, `libtiff` | `libheif1`, `librsvg2-2`, `libtiff6` |
| `libcairo.so.2`, `libcairo-gobject.so.2`, `libpangocairo-1.0.so.0` (direct) | 2D drawing. GTK may use cairo internally, but tkzmux draws every pixel with Vulkan, and Pango is allowed for layout only. `pkg-config --libs gtk4` lists all three, so CGtk links through its own `.pc`, which leaves them out (ADR-0002 D10; WOR-314 S1 found `--as-needed` ineffective under SwiftPM). | `cairo`, `pango` | `libcairo2`, `libcairo-gobject2`, `libpangocairo-1.0-0` |

### 5. GTK's transitive closure is accepted

The user explicitly accepts GTK's closure, about 112 shared objects on the development host. It includes glib, pango, cairo, gdk-pixbuf/glycin, graphene, epoxy, gstreamer, cups, colord, tinysparql, X11/xcb, libsystemd and libdbus-1. Consequences:

- Checks gate on `readelf -d` NEEDED only. The `ldd` closure count is printed for information and never gates (`check-linkage.sh`, WOR-299 S2).
- A denied library that appears only transitively, through GTK, is not a violation.
- No tkzmux code may call into a denied library through GTK's closure, for example by `dlopen`ing it.

### 6. Swift standard library linking

- **Static stdlib is a per-product setting**, never the global `swift build --static-swift-stdlib`. The global flag applies to every product, including test runners, and puts the policy on the command line instead of in the manifest. Each product that wants it declares:

  ```swift
  linkerSettings: [.unsafeFlags(["-static-stdlib"], .when(platforms: [.linux]))]
  ```

  `unsafeFlags` is allowed because tkzmux is the root package.
- **`tkzmux-hook`** stays Foundation-free (`CLAUDE.md:56`; every file in `Sources/tkzmux-hook/` imports only `Darwin`) and under 20 ms (`CLAUDE.md:43`). On Linux it imports Glibc instead (WOR-305) and links its stdlib statically. Whether it can be libc-only is measured, not assumed:
  - A `-static-stdlib` binary may still NEED `libstdc++.so.6`, `libgcc_s.so.1` and `ld-linux-x86-64.so.2`. These enter linkage-policy.txt only as WOR-300 S4 measures them.
  - If the hook must be libc-only, WOR-305 S6 adopts the Static Linux SDK (musl) for the hook alone. `dlopen` is not needed there.
- **The app's** static or dynamic stdlib mode is decided in WOR-323 S2. Its `[tkzmux]` section in linkage-policy.txt stays provisional until then. With a static stdlib the Swift runtime also binds to libghostty-vt's compiler_rt symbols. WOR-302 S4's `check-binary.sh` checks for that.

### 7. What the app relies on at runtime without linking

| Kind | Item | Used for | Repo anchor / owner |
|---|---|---|---|
| Spawned tool | `git` | Git status, worktrees | `Sources/GitStatus/GitProcess.swift:53` (`/usr/bin/git`) |
| Spawned tool | `gh` | PR lookup | `Sources/GitStatus/PRLookup.swift:276-285` (PATH search) |
| Spawned tool | `curl` | Update check through the `Fetch` seam | WOR-320 S6 |
| Spawned tool | `pw-play`, falling back to `paplay` | Ready sound | WOR-320 |
| GDBus service | systemd user manager (`org.freedesktop.systemd1`) | Transient scope and per-session cgroups | WOR-321 |
| GDBus service | xdg-desktop-portal (`org.freedesktop.portal.Desktop`) | Folder picker (FileChooser), open URI | WOR-320 |
| GDBus service | Also over GDBus, with no new link: `org.freedesktop.Notifications`, `org.freedesktop.login1` (PrepareForSleep) | Notifications, sleep and wake | WOR-320 |
| Bundled data | JetBrains Mono (OFL), already bundled | Terminal and monospace text | `Sources/TkzTerminalRender/Resources/Fonts/` with `OFL.txt` |
| Bundled data | Inter (OFL), **Linux only** | Chrome text in place of SF Pro, which may not ship on non-Apple systems | WOR-312 S8 (pinned 4.x release, SHA-256 recorded) |
| Bundled data | OFL symbol subset | Glyphs that JetBrains Mono and Inter lack | WOR-312 |
| Bundled data | CC0 ready sound with its licence note | Ready sound. The Mac keeps `NSSound(named: "Glass")` (`Sources/TkzApp/AppDelegate.swift:135`), which cannot ship on Linux | WOR-320 |
| Bundled data | terminfo (`xterm-ghostty`) | `TERM` for child shells | `Sources/TkzTerminalCore/Resources/terminfo/`, in both the hex layout (`78/ 67/`, macOS ncurses) and the letter layout (`x/ g/`, Linux ncurses), byte-identical |

A missing spawned tool or service turns the feature off and logs why. It never crashes the app, and it is never replaced by linking a library.

### 8. Image decoding for the file viewer

On the Mac, `FileViewerLoader.isImage` accepts any `UTType` that conforms to `.image` (`Sources/TkzApp/FileViewer/FileViewerLoader.swift:30-34`), and `NSImage` decodes it (`FileViewerView.swift:142`). On Linux, decoding goes through `GdkTexture` (`gdk_texture_new_from_filename`), and the pixels are then uploaded into the tkzmux renderer. Nothing new is linked.

| Format | Linux path | Guarantee |
|---|---|---|
| PNG | GTK's built-in loader (`libgtk-4.so.1` NEEDs `libpng16.so.16`) | Guaranteed |
| JPEG | GTK's built-in loader (`libgtk-4.so.1` NEEDs `libjpeg.so.8`) | Guaranteed |
| GIF | gdk-pixbuf → glycin loader (`glycin-image-rs`), out of process | Best effort |
| WebP | gdk-pixbuf → glycin loader (`glycin-image-rs`), out of process | Best effort |
| TIFF | GTK's built-in loader on this host (`libgtk-4.so.1` NEEDs `libtiff.so.6`), otherwise glycin | Best effort |
| HEIC | glycin loader (`glycin-heif`), when installed | Best effort |
| SVG | glycin loader (`glycin-svg`), when installed | Best effort |

- libheif, librsvg and libtiff are never linked directly (section 4).
- A format that fails to decode shows the Mac's notice, "This image could not be decoded." (`FileViewerView.swift:148`).
- WOR-319 S5 cites this table.

On the development host, `libgdk_pixbuf-2.0.so.0` NEEDs `libglycin-2.so.0` (gdk-pixbuf 2.44.7, glycin 2.1.5). The installed loaders are heif, image-rs, jxl and svg. Where gdk-pixbuf is built without glycin, its own loader modules decode instead. Either way the decoder belongs to GTK's closure, not to a tkzmux link.

### 9. Test-only libxkbcommon

`libxkbcommon.so.0` is already in GTK's closure (`libgtk-4.so.1` NEEDs it directly). The recommendation is to **allow it as a test-only link** for WOR-315 S1's `CXKBCommon` layout-fixture generator, which compiles `us` and `se` keymaps headlessly. It is never an app NEEDED. Packages: Arch `libxkbcommon`; Ubuntu `libxkbcommon0` (`libxkbcommon-dev`). The `[tests]` section of linkage-policy.txt carries it.

**Verdict: allowed as a test-only link** (ratified in WOR-299 S6, 2026-10-02; see [decisions.md](decisions.md)). WOR-315 S1 applies it. The fallback that was recorded in case of refusal stays documented for completeness: WOR-315 S1 would generate its layout fixtures offline with `xkbcli`/`xkbcomp`, commit them as JSON, and no test target would link libxkbcommon.

### 10. The Mac app stays unchanged

- Mac goldens stay byte-identical across every shared-code refactor (WOR-307 owns the characterization harness).
- No Mac behaviour or look changes to make Linux easier. There is no convergence milestone.
- A gap that exists only on Linux is listed in the parity docs (ADR-0003, `docs/linux/parity.md`) and never fixed by changing the Mac.
- macOS CI (`.github/workflows/ci.yml`, Xcode 26.1) must stay green on every Linux change.

### 11. Accessibility is deferred

AT-SPI support is deferred to WOR-325. The canvas toolkit keeps a seam for it: a view-tree node interface that a future `GtkAccessible` implementation (TkzA11yNode) can mirror. No toolkit design may close that seam off.

### 12. How the work is tracked (decision 8)

The port runs as about 25 milestone-sized Linear issues (WOR-299 to WOR-325) under milestones M0-M11, linked by blocking relations. Each issue holds an ordered checklist of session-sized steps, and each session is one worktree session (`CLAUDE.md:49`). Other issues refer to these ADRs and to linkage-policy.txt, and never restate their lists.

### 13. Code provenance

cmux and Kitty are GPL-3. Their code is never copied, and Kitty may at most be read to learn which Wayland protocols a terminal uses. Ghostty (MIT) may be read for reference, and libghostty-vt is used only through its public C API (`CLAUDE.md:54`).

## Consequences

- One reviewable list (linkage-policy.txt) and one checker (`check-linkage.sh`) gate every binary. Adding a library to a product means editing the policy with a justification, in a reviewed change.
- The process loads about 112 shared objects through GTK, and tkzmux owns none of them. Startup and memory cost are measured in WOR-323 against `docs/linux/perf-budgets.md`.
- Every pixel is tkzmux's, so parity can be measured (ADR-0003). The cost is a full in-house widget toolkit (WOR-316, WOR-317).
- Image support beyond PNG and JPEG depends on the user's installed loaders. The viewer degrades to the Mac's notice instead of failing.
- Spawned tools (curl, pw-play) keep the link small, but a missing tool turns a feature off. The app logs this and keeps running.
- Ubuntu 24.04 cannot run the app (GTK 4.14.2 < 4.16). It stays a build image for non-GTK targets only (ADR-0002).

## Alternatives considered

- **Option A: GTK4 widgets with CSS and a GtkGLArea terminal.** Lowest pixel parity, because GTK styles every control. It pulls in the same 112-library closure, and Ghostty dropped GtkGLArea for its terminal because it is bound to the main thread and fights triple buffering. Rejected.
- **Option C: raw Wayland with no toolkit.** The smallest link set: libwayland-client, libxkbcommon, libvulkan, the font libraries and one D-Bus choice. But tkzmux would own IME (text-input-v3), clipboard, popups, portals, a D-Bus client (estimated 1-1.5k lines of Swift) and accessibility. Rejected in favour of GTK as the "Linux AppKit".
- **FoundationNetworking for the update check.** Adds a dynamic libcurl link that cannot be made static (SE-0342). Rejected for a spawned `curl`.
- **libcanberra or libpulse for the ready sound.** A permanent link for one short sample. Rejected for spawning `pw-play`/`paplay`.
- **Directly linked image codecs (libpng, libjpeg-turbo, libwebp, libheif, librsvg).** New links for a secondary feature that GTK already covers. Rejected.
- **Global `--static-swift-stdlib`.** Applies to every product and lives outside the manifest. Rejected for the per-product `-static-stdlib` setting.
- **Static Linux SDK (musl) for the app.** `dlopen` does not work there, and the Vulkan loader needs it. Rejected for the app, and kept as the fallback for the hook only.

## References

- Repo: `CLAUDE.md:43,49,53,54,56`; `Package.swift:7-130`; `Sources/TkzApp/Update/UpdateChecker.swift:29,99`; `Sources/GitStatus/GitProcess.swift:53`; `Sources/GitStatus/PRLookup.swift:276-285`; `Sources/TkzApp/AppDelegate.swift:135`; `Sources/TkzApp/FileViewer/FileViewerLoader.swift:30-34`; `Sources/TkzApp/FileViewer/FileViewerView.swift:142,148`; `Sources/TkzApp/MainWindowController.swift:876-893` (NSOpenPanel folder picker); `Sources/tkzmux-hook/*.swift` (`import Darwin` only).
- GTK headers (GTK 4.22.4 on the development host): `gtk/gtkgraphicsoffload.h:70-74`, `gdk/gdkdmabuftexturebuilder.h:103-107`.
- Measurements on the development host (2026-10-02): `ldd /usr/lib/libgtk-4.so.1 | wc -l` = 112; `readelf -d` on libgtk-4 and libgdk_pixbuf-2.0 for the image-loader rows; `pacman -Qo` for Arch package names. Ubuntu names checked at https://packages.ubuntu.com/noble/.
- SE-0342, FoundationNetworking/libcurl cannot be linked statically: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0342-static-link-runtime-libraries-by-default-on-supported-platforms.md
- Static Linux SDK, `dlopen` unavailable: https://www.swift.org/documentation/articles/static-linux-getting-started.html
- SE-0482, static-library binary targets on non-Apple platforms: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0482-swiftpm-static-library-binary-target-non-apple-platforms.md
- swift-corelibs-foundation (FoundationNetworking links libcurl): https://github.com/swiftlang/swift-corelibs-foundation
- GTK 4.16 release notes: https://download.gnome.org/sources/gtk/4.16/gtk-4.16.0.news
- SF font licence (not for non-Apple OSes): https://developer.apple.com/fonts/ ; Inter (OFL): https://rsms.me/inter/
- Kitty Wayland backend, GPL-3, read only for protocol usage: https://raw.githubusercontent.com/kovidgoyal/kitty/master/glfw/wl_init.c
