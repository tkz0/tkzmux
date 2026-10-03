# ADR-0003: Pixel parity — definition, snapping, layers, thresholds and references

- **Status:** Accepted (2026-10-02)
- **Date:** 2026-10-02 (written in WOR-299 S3, ratified in WOR-299 S6)
- **Issue:** WOR-299 S3 (M0 gate)
- **Implemented by:** WOR-307 (Mac characterization harness), WOR-312 (fonts), WOR-313 (Vulkan renderer), WOR-316 (canvas toolkit), WOR-318/WOR-319 (views), WOR-322 (parity harness), WOR-323 (local hardware script), WOR-324 (final audit)
- **Related:** [ADR-0001](adr-0001-charter.md) (charter, bundled fonts), [ADR-0002](adr-0002-platform-defaults.md) (scale and FcConfig isolation, Pango text layout), [ADR-0004](adr-0004-keys-input.md) (hint glyphs, preedit kept out of fixtures), [ADR-0005](adr-0005-window-controls.md) (window controls, Hyprland snippet), [decisions.md](decisions.md), [index](README.md)
- **Change control:** this ADR is normative. Every threshold below has a named constant that WOR-322 S1 mirrors in `ParityThresholds.swift`. A threshold, rule or budget changes only by amending this file in the same PR that changes the constant. A threshold is never loosened to make a run pass.

## Context

The user's goal for the Linux build is "as close to full pixel parity with the Mac as possible", and every later Linux issue closes against that goal. So it has to be measurable. Six facts limit what parity can mean:

1. **The two platforms run at different scales.** The Mac renders at a backing scale of 2.0. The target Hyprland output runs at a fractional scale of 1.6 (192/120 through `wp_fractional_scale_v1`). At 2.0 every half-point edge lands on a whole device pixel. At 1.6, a 1 pt border is 1.6 px, the 1.5 pt focus ring is 2.4 px, a 44 pt row is 70.4 px and the 36 pt status bar is 57.6 px.
2. **Terminal cells are whole device pixels** (`Sources/TkzRenderCore/CellMetrics.swift:62-67`). JetBrains Mono at 14 pt (`Sources/TkzCore/Theme.swift:178`) is 17×37 px at 2.0 (8.5×18.5 pt) and 14×30 px at 1.6 (8.75×18.75 pt). The column counts therefore differ by design, and Linux@1.6 cannot be compared with the Mac at 2.0.
3. **The Mac does not agree with itself byte for byte.** The committed terminal goldens differ from the GitHub runner's output on 0.526 % and 0.529 % of pixels, against a 0.2 % tolerance. CI therefore skips the per-pixel check (`Tests/TkzTerminalRenderTests/TerminalRendererTests.swift:112-115,157-171`). The fact-check traces the drift to CoreGraphics/OS differences rather than the GPU: the atlas is rasterized on the CPU and sampled nearest, 1:1 (`Sources/TkzTerminalRender/Resources/Shaders/Terminal.metal:327-330`).
4. **Some Mac pixels cannot be reproduced on Linux.** SF Pro and SF Symbols cannot be used outside Apple platforms. NSVisualEffectView materials have no published parameters. Traffic lights, NSAlert, NSSegmentedControl capsules and system colours are drawn by AppKit, not by tkzmux.
5. **The Mac app does not change** (user decision 2). Mac goldens stay byte-identical. Linux-only gaps are documented, never closed on the Mac.
6. **Screenshots are not trustworthy on either OS.** Omarchy tags every window with `default-opacity` and applies `opacity 0.985 0.96` (`/usr/share/omarchy/default/hypr/windows.lua:6,25`). Mac chrome is colour-matched to the display profile, but the terminal `CAMetalLayer` has no colorspace and so is not colour-matched (`Sources/TkzTerminalView/TerminalMetalView.swift:162-174`).

**User decision (2026-10-02): the reference machine is the macOS CI runner only.** No developer Mac is available. The issue text assumed a pinned developer Mac; this ADR replaces that assumption everywhere (see [References and the reference machine](#5-references-and-the-reference-machine)). The decision is logged in [decisions.md](decisions.md) as S6-5.

## Decision

### 1. Definition

- **Parity is measured in logical points, with each OS at its native scale.** Geometry is compared in points. Pixels are compared only between renders made at the same scale.
- **The Linux@1.6 reference is the Mac renderer drawing offscreen at 1.6**, never the Mac at 2.0 resampled. The Linux@2.0 reference is the Mac at 2.0. Both scales are gated.
- **Expected terminal cells.** JetBrains Mono 14 pt is expected to be 14×30 px at 1.6 (22.4 px: width ⌈13.44⌉ = 14, height round(29.568) = 30, baseline round(22.848) = 23) and 17×37 px at 2.0 (28 px: ⌈16.8⌉ = 17, round(36.96) = 37, baseline 29). This uses hhea 1020/−300/0 and advance 600 at 1000 upem. WOR-312 confirms the figures with its `fontmetrics` dump. Cell width keeps the Mac's `.rounded(.up)` (`Sources/TkzRenderCore/CellMetrics.swift:67`), and every other metric keeps `.rounded()`.
- **Colour parity means equal gamma-encoded sRGB bytes**, not a colorimetric match:
  - Linux renders to a UNORM target (not `_SRGB`), with premultiplied alpha and gamma-space blending, exactly as Metal does with `bgra8Unorm` (`TerminalMetalView.swift:166`).
  - On the Mac, bytes are read per surface. Chrome comes from an sRGB bitmap context. The terminal comes from the raw render target, before any colour matching.
  - The Mac never gains a `layer.colorspace`.
  - ΔE2000 (mean and p99) is reported as a diagnostic only. It never gates.
- **Parity is a set of layer verdicts**, L0–L6 below. "Pixel-identical" is never an acceptance criterion for a Linux issue, except where a layer says "exact".

### 2. Snapping policy

There is one policy, implemented once in the Linux toolkit (`Snapper(scale:)`, WOR-316 S1). Every design token carries its snapping kind (WOR-307 S3). Snapping is computed on the CPU in surface (window) coordinates, never in a component's local coordinates and never in a shader.

**What the Mac code does today** (it is not changed):

- Placement arithmetic is rounded to whole points with Swift `.rounded()`. Examples: `SessionRowView.swift:547,557`, `PaneHeaderView.swift:139,151,174`, `GroupRowView.swift:174-192`, `CommandPaletteController.swift:475-476`.
- Metric tokens are whole or half points, for example `SidebarMetrics` in `SidebarRowModels.swift:260-290`.
- At 2.0 every half-point edge is a whole device pixel, so the Mac needs no explicit snapping and its edges are crisp by construction.
- The one device-pixel rule in the Mac UI is the status-bar top line, `1 / backingScaleFactor` (`StatusBarView.swift:676-677`).
- Borders are CALayer `borderWidth`s in points (for example `GlassSheet.swift:77`, `PaneChromeView.swift:102`), drawn inside the layer bounds.

**The rules.** At 2.0 they reproduce the Mac exactly. At 1.6 they are the chosen generalisation.

| Kind | Rule | Used for |
|---|---|---|
| `.hairline` | Exactly 1 device px, at every scale. | The status-bar top line, and every token that the Mac computes as `1 / backingScaleFactor`. |
| `.points(n)` | Each edge is converted on its own: `px = (edge_pt × s).rounded()`. Never origin plus rounded size. | Layout frames: rows, bars, sidebar, panes, dividers, cards, hit areas. |
| `.mark(d)` | The origin snaps as an edge. The extent is `max(1, (d × s).rounded())`, whatever the position. | Fixed-size marks whose shape must not depend on where they land: status dots, close boxes, badge capsules' height, icon boxes. |
| Strokes | Width is `max(1, (w × s).rounded())`, drawn inside the snapped rect. | Axis-aligned borders, focus rings and rules. |
| Baselines | `baseline_px = (baseline_pt × s).rounded()`. Glyph pen x stays subpixel and is quantized only by WOR-312's atlas key. | All UI text. Terminal baselines are already whole pixels (`Sources/TkzRenderCore/CellMetrics.swift:66`). |
| Vector paths | Drawn antialiased at `w × s`, not rounded. | The chevron (`StatusDotView.swift:244-262`), PR and merge glyphs, and the SF Symbol replacements. |

`.mark` is an addition to the two kinds named in WOR-307 and WOR-316 (see [Open items](#open-items)). Without it, per-edge rounding draws a 7 pt dot as 11×11 px on some rows and 11×12 px on others (worked example 3).

**Rounding.** Rounding is Swift `.rounded()`, that is `FloatingPointRoundingRule.toNearestOrAwayFromZero`. The following are forbidden:

- `rint`/`lrint` under the default FP environment, and `roundEven`, all of which are banker's rounding;
- `floor(x + 0.5)`, which is wrong for negative values;
- GLSL `round()`, whose behaviour at .5 is implementation-defined.

C `round()` is half away from zero, so it is allowed.

| Input | `.rounded()` (required) | Banker's (`rint`) | `floor(x + 0.5)` |
|---|---|---|---|
| 18.5 | **19** | 18 | 19 |
| 2.5 | **3** | 2 | 3 |
| −2.5 | **−3** | −2 | −2 |

The 18.5 case occurs in real code: the status dot in a 44 pt row is placed at `((44 − 7) / 2).rounded()` = 19 pt (`SessionRowView.swift:545-551`). Device-pixel ties hardly ever occur. At 1.6, a half-point edge times 1.6 has a fractional part of .0, .2, .4, .6 or .8, never .5. At 2.0 every half-point edge is a whole pixel. Ties therefore come from point-level centring like the one above, so a Linux layout must reproduce the Mac's point arithmetic, not just its snapping.

**y-axis.** The Mac row layers are y-up, and the Linux canvas is top-left. The tie above rounds the dot's bottom edge to 19 pt in y-up terms. In top-left terms its top edge is therefore 44 − 19 − 7 = 18 pt, not 19. Linux layout code must produce the Mac's logical frame (top = 18). The L0 comparison catches any difference.

**Worked examples.** Device pixels are written as half-open ranges `[a, b)` in surface coordinates, with the stated origin at 0.

1. **1 pt border** (glass sheet `GlassSheet.swift:77`; search-mode palette `CommandPaletteController.swift:524`):

   | Scale | Width | Note |
   |---|---|---|
   | 1.6 | `max(1, round(1.6))` = **2 px** | 1.25 pt logical; the Mac offscreen reference draws 1.6 px antialiased |
   | 2.0 | `max(1, round(2.0))` = **2 px** | identical to the Mac |

2. **1.5 pt focus ring** (`PaneHeaderModels.swift:21`, applied at `PaneChromeView.swift:102`):

   | Scale | Width |
   |---|---|
   | 1.6 | round(2.4) = **2 px** |
   | 2.0 | round(3.0) = **3 px** |

3. **7 pt status dot** (`StatusDotView.swift:37`) in a 44 pt session row. The Mac frame is x = `dotCenterX − 3.5` = 30 pt (`SessionRowView.swift:57`), y-up y = 19 pt, so the top-left frame is (30, 18, 7, 7) pt. Row k starts at 44k pt.

   | Scale | Row | `.mark` (required) | Per-edge (rejected for marks) |
   |---|---|---|---|
   | 1.6 | k = 0 | x [48, 59), y [29, 40): **11×11** | top 28.8→29, bottom 40.0→40: 11×11 |
   | 1.6 | k = 4 | x [48, 59), y [310, 321): **11×11** | top 310.4→310, bottom 321.6→322: **11×12** |
   | 2.0 | any | x [60, 74), y [88k+36, 88k+50): **14×14** | 14×14 |

4. **Ten 44 pt rows** from y = 0 (`SidebarRowModels.swift:266`):

   | Scale | Edges (px) | Row heights (px) | Total |
   |---|---|---|---|
   | 1.6 | 0, 70, 141, 211, 282, 352, 422, 493, 563, 634, 704 | 70, 71, 70, 71, 70, 70, 71, 70, 71, 70 | 704 = 440 pt × 1.6 |
   | 2.0 | 0, 88, 176, …, 880 | 88 each | 880 |

   Origin plus rounded size would give 10 × 70 = 700 px, which is 4 px short after ten rows. That is the drift the per-edge rule exists to prevent. If the list starts below the 28 pt sidebar header (`SidebarRowModels.swift:272`), the same rule is applied to the absolute edges, so the 70/71 pattern shifts phase. This is expected.

5. **300 pt sidebar** (`SidebarRowModels.swift:287-288`; maximum `MainWindowController.swift:693`), x from 0:

   | Scale | Range | Min 240 pt | Max 520 pt | A dragged width of 300.5 pt |
   |---|---|---|---|---|
   | 1.6 | **[0, 480)** | 384 px | 832 px | round(480.8) = 481 px |
   | 2.0 | **[0, 600)** | 480 px | 1040 px | 601 px |

6. **36 pt status bar** (`StatusBarView.swift:168`) at the bottom of an 820 pt window (`MainWindowController.swift:328`), so y from 784 to 820 pt:

   | Scale | Bar | Height | Top hairline |
   |---|---|---|---|
   | 1.6 | **[1254, 1312)** (1254.4→1254) | 58 px | [1254, 1255) |
   | 2.0 | **[1568, 1640)** | 72 px | [1568, 1569) |

**Verification** is an acceptance criterion of WOR-307 S2, not of this issue:

- WOR-307's layout dump records the Mac's logical frames.
- A reference implementation of these rules, applied to those frames, must reproduce examples 1–6 at 1.6 and 2.0.
- At 2.0 the test also lists every dumped edge that is off the 0.5 pt grid. Such edges are exceptions to "the Mac is snap-exact at 2.0" and are added to the exception table below.
- A mismatch is fixed by amending this ADR, never by changing the Mac.

### 3. Layers and thresholds

All comparisons run through `tkzmux-vtdump compare <a> <b> [--mask m.json] [--json out]` (TkzParity, WOR-322 S1). Thresholds apply at both 1.6 and 2.0. `Tests/Parity/layers.json` holds one row per layer and scale (L0 is split into component and window). Each row is `pending` or `enforced` and names its owner issue.

| Layer | What is compared | Threshold | Constants | Mac producer | Linux producer |
|---|---|---|---|---|---|
| **L0** layout | Logical-point frame tree, visibility, truncation and wrap decisions (for example `SessionRowView.detailWraps`: 44 vs 59 pt) | Exact: JSON byte-equal after canonical key order. Measured text-run widths ±0.5 pt, diagnostic only. The window-controls zone is excluded (ADR-0005). | `l0Exact`, `l0TextWidthTolerancePt = 0.5` | WOR-307 S1 `LayoutDump` | WOR-316–WOR-319 (components), WOR-318 S7 (window) |
| **L1** cell metrics | Every `CellMetrics` field, including a rounding tie case that tells half-away-from-zero apart from banker's rounding | Exact | `l1Exact` | `vtdump fontmetrics --json` (WOR-312 S1) | same command on Linux (WOR-312) |
| **L2** FrameBuilder buffers | Instance buffers built from the same metrics and atlas glyph table | Byte-identical | `l2Exact` | WOR-322 S2 dump | WOR-322 S3 runner |
| **L3** shaders | The same instance and atlas bytes through Metal and Vulkan (lavapipe, RADV, NVIDIA): 8 rect styles, min-contrast, curly underline | Every pixel within ±1 LSB per channel; no outliers allowed | `l3ChannelTolerance = 1`, `l3PixelTolerance = 0` | WOR-313 S3 (`TKZMUX_WRITE_CONFORMANCE_REFS`) | WOR-313 S3 |
| **L4** glyph atlas | Per glyph, for ASCII in 4 styles, box and block characters, and symbols | Each bbox edge ±1 px; coverage sum ±4 % relative; SSIM ≥ 0.90. Fallback-font (CJK, emoji) glyphs are checked on box geometry only. | `l4BBoxTolerancePx = 1`, `l4CoverageTolerance = 0.04`, `l4GlyphMinSSIM = 0.90` | `vtdump atlas --json --scale` (scale exists: `RenderCommands.swift:9,73-75`; JSON added by WOR-312) | WOR-312 |
| **L5** components | ComponentSnapshot PNG per component × 3 presets × {1.6, 2.0} | Non-text: ≥ 99.8 % of unmasked non-text pixels within ±2 per channel. Text: each text-run box (from L0) SSIM ≥ 0.90. Whole component: SSIM ≥ 0.95. | `l5ChannelTolerance = 2`, `l5PixelTolerance = 0.002`, `l5TextMinSSIM = 0.90`, `l5ComponentMinSSIM = 0.95`, `l5EdgeBandPx = 1` | WOR-307 goldens | WOR-316–WOR-319 offscreen canvas |
| **L6** window | Full-window in-app capture of the fixture, 1320×820 pt (2112×1312 px at 1.6, 2640×1640 px at 2.0) | SSIM ≥ 0.97 with masks; the masked area must be ≤ 15 % of the window; L0-window must also be exact | `l6WindowMinSSIM = 0.97`, `l6MaxMaskedFraction = 0.15` | WOR-322 S4 (`TKZMUX_DEV_CAPTURE`) | WOR-318 S7 |

The L5 channel rule reuses the existing golden comparator's defaults (`channelTolerance 2`, `pixelTolerance 0.002`, `TerminalRendererTests.swift:122`).

**Comparison mechanics.** These are the same on both OSes.

- **SSIM** follows Wang et al. 2004:
  - an 11×11 Gaussian window with σ = 1.5, K1 = 0.01, K2 = 0.03 and L = 255;
  - computed on the luma of the gamma-encoded bytes, Y′ = 0.2126 R′ + 0.7152 G′ + 0.0722 B′, without linearizing;
  - the mean is taken over windows whose centre is unmasked.

  The tool also reports per-tile SSIM on 64×64 px tiles and writes a heatmap. Per-tile values are diagnostic only.
- **Masks** come in four types: `fallbackGlyph`, `cjkEmoji`, `vibrancy` and `windowControls`.
  - They are pixel rects or cell rects, derived from the L0 dump or the terminal grid, never drawn by hand for one run.
  - Masked pixels count in neither the SSIM mean nor the channel fraction.
- **Edge band (L5 at 1.6 only).** The Mac reference does not snap at 1.6: CoreAnimation draws fractional edges antialiased, including the status-bar hairline, which an offscreen layer without a window computes as 0.5 pt (`StatusBarView.swift:676`). For every L0 edge whose Mac position `e × 1.6` is not a whole pixel, pixels within `l5EdgeBandPx` (1 device px) of it are left out of the non-text channel rule. They still count in both SSIM scores. At 2.0 the band applies only to the listed off-grid exceptions.
- **Determinism.** Producers run from `TKZMUX_FIXTURE` state (`AppDelegate.swift:46`) with `Fixture.now` (`Sources/TkzCore/FixtureState.swift:33`), animations frozen and caret blink off. On Linux they run under the private FcConfig and the environment isolation in ADR-0002 (WOR-322 S3 tests this).

**Approved exceptions** (rows that WOR-324 S5 may accept as not `enforced`): none.

### 4. In-app readback only

- **Parity gates read pixels from the app's own render targets, never from the screen.**
  - The trigger is `TKZMUX_DEV_CAPTURE=<png>` plus `TKZMUX_DEV_CAPTURE_SCALE`, defined next to `TKZMUX_FIXTURE` (`AppDelegate.swift:43-46`).
  - **Mac (WOR-322 S4):** chrome is captured with `cacheDisplay`, and each terminal surface is re-rendered into an offscreen texture, because the drawable is `framebufferOnly` (`TerminalMetalView.swift:167`). The scale is set through WOR-307 S1's `contentsScale` seam. Production keeps its `contentsScale = 2` sites (`MainWindowController.swift:290`, `StatusDotView.swift:233,259`, `PaneStartupOverlayView.swift:62`).
  - **Linux (WOR-318 S7):** pixels are read back from the Vulkan render target before presentation, through a GTK-free headless producer.
- **On-screen `grim` captures are local checks only.** They are allowed in WOR-301 S2, WOR-314 S4 and WOR-323's `parity-local.sh`, and only to check that the presented frame maps 1:1 to texels. Each such check must:
  - have the tkzmux Hyprland window rule applied (`-default-opacity`, `opacity 1 1`, effective alpha verified as 1.0; ADR-0005);
  - assert the capture's pixel size.

  A grim capture is never a parity gate and never a reference.

### 5. References and the reference machine

- **The reference machine is the GitHub-hosted `macos-26` runner with Xcode 26.1**, the same runner class and toolchain as `ci.yml` (`.github/workflows/ci.yml:22,30-31`). No developer Mac is used, and output from any other Mac is "foreign hardware" in the sense of `TerminalRendererTests.swift:110-115`.
- **Generation runs only on that runner.**
  - `make parity-references` runs in a manually dispatched workflow in its own file. `ci.yml` stays byte-identical.
  - The workflow renders the set twice, fails unless the two runs are byte-identical (ignoring `provenance`), and uploads the set and its heatmaps as an artifact.
  - A person commits the set in a reviewed PR.
  - The exporter refuses to run outside a hosted runner (`CI` and `ImageOS` unset). When a manifest exists, it also refuses on an image that does not match it, unless `--regenerate` is passed.
- **The manifest** (`Tests/Parity/References/manifest.json`) records:
  - `ImageOS` and `ImageVersion` (the runner image);
  - the macOS build (`sw_vers -buildVersion`), the Xcode version and `sysctl hw.model`;
  - `AppleFontSmoothing` (or "unset") and the display profile (or "none, headless");
  - a separate `provenance` block with the commit and run id.

  It holds no user names or host names (`scripts/scan-personal-data.sh`).
- **Budget: one combined committed budget of ≤ 9 MiB (9,437,184 bytes), with each image stored once.**
  - `Tests/TkzAppTests/ComponentSnapshots/` (WOR-307) has a share of ≤ 4.25 MiB (4,456,448 bytes). Renegotiated on 2026-10-03 from 4 MiB: the first reference-runner set came to 4,194,643 bytes, 339 over, with full coverage (no case dropped).
  - `Tests/Parity/References/` (WOR-322, including WOR-312's `fonts/` and WOR-313's conformance outputs) has a share of ≤ 4.75 MiB (4,980,736 bytes), down from 5 MiB to keep the 9 MiB total.
  - The manifest lists WOR-307's goldens by path and sha256 and never copies them.
  - WOR-322's size test enforces the total and both shares.
  - Constants: `referenceBudgetBytes`, `componentSnapshotShareBytes`, `parityReferenceShareBytes`.

### 6. Unreachable items and their substitutes (the Mac is unchanged)

| Mac element | Where | Linux substitute | Parity treatment | Owner |
|---|---|---|---|---|
| SF Pro UI font (licence forbids non-Apple use) | `Theme.swift` UI family nil | Inter, bundled on Linux only, with per-size tracking calibrated from NSFont advance dumps | L0 truncation and wrap decisions exact; L5 text SSIM | WOR-312 |
| 3 SF Symbols: `bell.fill`, `bell.slash`, `folder.badge.plus` | `SidebarHeaderView.swift:100,109,119` | Vector paths | Icon boxes are compared under the L5 text rule (SSIM ≥ 0.90) | WOR-317 |
| Symbols missing from JetBrains Mono that macOS supplies by fallback (⏺ ⎿ ✢ ✳ ✶ ✻ ✽ ⎇ and others) | glyph-sheet recording (WOR-322 S2) | Bundled OFL symbol subset through the private FcConfig | `fallbackGlyph` mask in L5/L6; L4 box geometry only | WOR-312 |
| `.hudWindow` glass (sheets, palette, prompt card, activity feed, cheat sheet) | e.g. `GlassSheet.swift:72-73` | In-window dual-Kawase blur of tkzmux's own frame, with tint and alpha tokens fitted to the Mac | `vibrancy` mask on the blurred backdrop only; border, text and controls compared normally | WOR-316 |
| `.behindWindow` header backdrop (`.sidebar` material) | `ChromeViewController.swift:23-31` | The `titlebar` token (`Theme.swift:37`; alpha 0.95/0.96/0.95) flattened over `windowBackground`; the window is opaque | `vibrancy` mask on the header in L6 | WOR-318 |
| Traffic lights | AppKit title bar | Linux window controls per ADR-0005 | `windowControls` mask in L6; zone excluded from L0 | WOR-314 |
| 15 dialog sites: 14 `NSAlert` (13 in TkzApp, plus `MouseController.swift:851`) and the `NSOpenPanel` path's fallback dialog (`MainWindowController.swift:880`) | as listed | DialogSpec token redraws | L5 against the Mac captures | WOR-319 |
| Portal folder picker | xdg-desktop-portal FileChooser | System UI | **Excluded** from parity | WOR-320 |
| Segmented capsules | `MainToolbarController.swift:366,388`; `ChangesViewerView.swift:482` | Token redraw | L5; glass fill under `vibrancy` mask | WOR-317 |
| `.regular` (accent) table selection | `CommandPaletteController.swift:610`; `ActivityFeedController.swift:226` | A token measured from the reference capture | L5 | WOR-317, WOR-319 |
| `.thin` main split divider (system separator colour) | `MainWindowController.swift:706` | A token measured from the reference capture | L5/L6 | WOR-318 |
| `NSColor.linkColor` link underline | `MouseController.swift:771` | A token measured from the reference capture | L5 | WOR-318 |
| Apple Color Emoji, PingFang | system fallback | Noto Color Emoji, Noto Sans CJK | `cjkEmoji` mask; L4 box geometry only | WOR-312 |

None of these items changes the Mac. The Mac keeps the following, and Linux reproduces the *effective* result:

- the nil terminal colorspace;
- the hard-coded `contentsScale = 2` sites;
- the `Theme.Fonts.mono` weight being ignored (`ThemeAppKit.swift:37-40`), so Linux uses Regular wherever the Mac effectively does;
- its system colours.

## Consequences

**Positive**

- Every Linux visual issue closes on named, numeric verdicts with a named tool. Arguments about whether something "looks right" stop.
- The exact layers (L0–L2) catch the regressions most likely to slip through: a changed metric, a flipped wrap decision, or a row that drifts by a pixel. They are immune to rasterizer noise.
- Because references come from the CI runner, every Mac-side artifact is reproducible by anyone, from CI, with no special hardware.
- One snapping implementation, plus the `.mark` kind, keeps rows from drifting at 1.6 and keeps dots round.

**Negative, and accepted**

- **References drift with the runner image.** Mac-to-Mac drift is about 0.5 % of pixels (0.00526 and 0.00529, `TerminalRendererTests.swift:160`). GitHub moves the `macos-26` image forward on its own schedule and does not let us pin an image version, so a reference set is valid for exactly one `ImageVersion`.
  - Committed references do not move by themselves. The Linux gate compares against committed bytes, so it stays deterministic.
  - Drift appears only when references are regenerated. A regeneration PR must show that the old and new Mac sets pass L4–L6 against each other. L0–L2 must be byte-identical or explained.
  - Thresholds are never loosened to absorb a runner change.
- **No one can inspect Mac output interactively.** Every Mac-side observation is a CI artifact: PNGs, heatmaps and JSON reports.
- **The existing developer-Mac goldens become unverifiable per pixel.** These are `golden-{block,bar}-cursor.png` in `Tests/TkzTerminalRenderTests/Fixtures/`. They stay untouched, because the Mac is unchanged. Their per-pixel check stays skipped on CI, and only their dimensions are asserted. Regenerating them on the runner would change Mac goldens, so it is out of scope.
- **The runner is a VM with a paravirtualized GPU and, as far as `ci.yml:42-43` assumes, no GUI session.**
  - Offscreen Metal works there: the 0.5 % figure was measured on the runner. `layer.render(in:)` also works: `SidebarRowViewTests` runs in CI.
  - The full-window capture (WOR-322 S4) still has to be proven on the runner. If it cannot open a window, it must compose the window offscreen from the same layer tree without ordering a window on screen.
  - L3's Metal side is whatever that device produces. That is acceptable because the double-run reproducibility check rejects nondeterminism.
- **On private repositories, macOS runner minutes cost more.** The reference workflow is therefore manual, not run on every push.
- **The edge band** leaves the non-text channel rule blind to 1 px antialiased seams at 1.6. L0 (exact geometry) and SSIM cover them instead.
- **Linux lines can sit a quarter point thicker than the Mac's at 1.6.** A 1 pt border is 2 px (1.25 pt); a 1.5 pt ring is 2 px (1.25 pt). The rule chooses crisp whole pixels over antialiased 1.6 px lines, as every Wayland toolkit does at fractional scales.

## Alternatives considered

- **Compare Linux@1.6 against the Mac at 2.0, resampled.** Rejected. The cell grids differ (14×30 vs 17×37 px), and resampling destroys exactly the glyph detail L4 measures.
- **Byte-exact pixels everywhere.** Rejected. The Mac cannot meet this against itself (0.5 % drift), and CoreText and FreeType rasterizers never agree byte for byte.
- **Compositor screenshots** (grim on Hyprland, headless sway in CI) **as the gate.** Rejected. Omarchy's opacity rule, fractional-scale resampling and Mac display colour matching all distort screenshots. Headless sway remains a possible local tool only.
- **A pinned developer Mac as the reference.** This was the original plan. It was replaced by the user decision: no developer Mac is available. It would have avoided image drift, but nothing could have produced or regenerated references.
- **Origin plus rounded size for all geometry.** Rejected. Rows accumulate 0.4 px each at 1.6, so ten 44 pt rows end 4 px short (example 4).
- **Per-edge snapping for all geometry, including marks.** Rejected. A 7 pt dot becomes 11×12 px on some rows (example 3).
- **Unsnapped, antialiased geometry like the Mac's own 1.6 offscreen render.** Rejected. Hairlines and borders would blur on the real 1.6 display, which the Mac never shows at 2.0.
- **Making the Mac converge** (snapping, an sRGB colorspace, shared vector symbols, Inter on both platforms). Rejected by user decision 2.
- **ΔE2000 as a gate.** Rejected. The contract is equal gamma-encoded bytes, and ΔE stays a diagnostic.
- **Separate per-issue budgets, or copying goldens into `Tests/Parity/References/`.** Rejected. Duplicates would double the size and could disagree. One combined budget stores each image once.

## Open items

Each item has an owner issue; [decisions.md](decisions.md) carries the same list.

| Item | Resolution in this ADR | Owner |
|---|---|---|
| **Budget figure.** The WOR-299 issue text says one combined budget of ≤ 5 MB, while WOR-307 and WOR-322 cite "ADR-0003's combined ≤ 9 MB" with WOR-307's share at 4 MB, and WOR-312 cites ≤ 5 MB for its references. | Settled in WOR-299 S6 as 9 MiB total = 4 MiB component goldens + 5 MiB `Tests/Parity/References/` (section 5), which matches the WOR-307, WOR-312 and WOR-322 texts. | WOR-322 S2 (size test), WOR-307 S2 (share) |
| **`.mark` snapping kind.** New in this ADR; WOR-307 S3 (token tagging) and WOR-316 S1 (`Snapper`) name only `.hairline` and `.points`. | Both issues add `.mark` (section 2). | WOR-307 S3, WOR-316 S1 |
| **"Dev Mac" wording in other issues** now means the reference runner. | WOR-322 S2's exporter requires a hosted runner (`CI` and `ImageOS` set) instead of refusing "when `CI` is set". | WOR-322 S2 |
| | WOR-312 S1–S2 read "the reference runner" for "the ADR WOR-299 reference Mac". | WOR-312 |
| | WOR-316 S2 runs its Mac side on the reference runner, not "on the dev Mac". | WOR-316 |
| | WOR-311's criteria "goldens pass on the dev Mac with `TKZMUX_SKIP_GOLDEN_PIXELS` unset" and "bench-frame ≤ 3 % on the dev Mac" become dimension-only goldens and a runner-measured benchmark with a noise allowance. | WOR-311 |
| **Full-window capture on the runner** (WOR-322 S4) is unproven. | If the runner cannot open a window, compose the window offscreen from the same layer tree (Consequences). | WOR-322 S4 |

## References

- Repository:
  - `Tests/TkzTerminalRenderTests/TerminalRendererTests.swift:110-171`: foreign-hardware skip, tolerances and the 0.5 % drift record.
  - `Sources/TkzRenderCore/CellMetrics.swift:53-75`: metric rounding (moved from TkzTerminalRender by WOR-311 S2).
  - `Sources/TkzTerminalRender/Resources/Shaders/Terminal.metal:327-330`: nearest, 1:1 atlas sampling.
  - `Sources/TkzTerminalView/TerminalMetalView.swift:162-174`: no colorspace; `framebufferOnly`.
  - `Sources/TkzApp/StatusBar/StatusBarView.swift:168,676-677`: 36 pt bar and the device-pixel hairline.
  - `Sources/TkzApp/Sidebar/SidebarRowModels.swift:260-290`, `SessionRowView.swift:57,545-551`, `StatusDotView.swift:37`, `PaneHeaderModels.swift:21`: geometry used in the worked examples.
  - `.github/workflows/ci.yml:22,30-31,42-43`: the reference runner and toolchain.
  - `/usr/share/omarchy/default/hypr/windows.lua:6,25`: Omarchy's opacity rule.
- Research, as fact-checked:
  - Pathfinder's stem-darkening constants (x 0.0121, y 0.015125, max 0.3 px; documented for macOS 10.13), the starting point for WOR-312: https://raw.githubusercontent.com/servo/pathfinder/main/content/src/effects.rs
  - With `FT_LOAD_NO_HINTING`, FreeType scales outlines fractionally, so integer ppem from `head.flags` bit 3 does not apply: https://raw.githubusercontent.com/freetype/freetype/master/src/truetype/ttdriver.c, https://raw.githubusercontent.com/freetype/freetype/master/src/truetype/ttobjs.c
  - `CAMetalLayer.colorspace` nil means no colour matching: https://developer.apple.com/documentation/quartzcore/cametallayer/colorspace
  - The SF font licence: https://developer.apple.com/fonts/
  - Inter: https://rsms.me/inter/
  - Fractional scale in 120ths: https://wayland.app/protocols/fractional-scale-v1
  - Hyprland's `ext-background-effect-v1`, considered and not used for parity because the blur strength comes from user config: https://raw.githubusercontent.com/hyprwm/Hyprland/v0.56.2/src/protocols/BackgroundEffect.cpp
- Methods:
  - Z. Wang, A. C. Bovik, H. R. Sheikh, E. P. Simoncelli, "Image quality assessment: from error visibility to structural similarity", IEEE TIP 13(4), 2004 (SSIM).
  - M. Bjørge, "Bandwidth-efficient rendering", SIGGRAPH 2015 (dual-Kawase blur).
  - Swift `FloatingPointRoundingRule.toNearestOrAwayFromZero`: https://developer.apple.com/documentation/swift/floatingpointroundingrule/tonearestorawayfromzero
  - The GLSL 4.50 specification, §8.3 (`round` at .5 is implementation-defined): https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.4.50.pdf
  - GitHub-hosted runner images (`ImageOS`, `ImageVersion`, image update policy): https://github.com/actions/runner-images
- Issues: WOR-299 (this ADR), WOR-307, WOR-311, WOR-312, WOR-313, WOR-316–WOR-320, WOR-322–WOR-324.
