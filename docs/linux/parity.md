# Parity: component snapshots, layout dumps and goldens

How the Mac's components are pinned and measured: the snapshot harness, the layout-dump schema, the snapping kinds, and how the committed goldens are generated and checked. Written in WOR-307 S2. WOR-322 extends this page with the parity runner, `tkzmux-vtdump compare` and the regeneration of `Tests/Parity/References/`.

The rules themselves (what parity means, the snapping policy, the layers L0–L6, the thresholds, the reference machine and the size budget) are normative in [ADR-0003](adr-0003-parity.md). This page describes the files and the commands that implement them, and never restates a threshold.

## What is captured

`ComponentSnapshot.render(id:model:size:theme:scale:)` (`Tests/TkzAppTests/ComponentSnapshot.swift`, WOR-307 S1) draws one AppKit component headlessly into an sRGB bitmap, and returns:

- the PNG;
- a `LayoutDump`: the frame tree, the text runs with their measured widths and their wrap and truncation results, the masks and the frozen animations.

`ComponentCatalog` (`Tests/TkzAppTests/ComponentCatalog.swift`) lists every component that has a committed golden. Each entry is rendered for the 3 presets (`midnightIndigo`, `light`, `black`) at 2.0 and at 1.6:

| Area | Catalog entries |
|---|---|
| Sidebar | `sidebar.sessionRow.{plain, wrapped, selected, hover, badges, worktree, merged}`, `sidebar.groupRow.{expanded, collapsed}`, `sidebar.header`, `sidebar.updateCard`, `detail.emptyState` |
| Status bar | `statusBar.{wide, narrow, ellipsis, hot}` (the `writesInspectionPngs` cases; its `wide-light` is `statusBar.wide` in the light preset), `statusBar.segments.{live, git, rebasing, draft}`, `statusBar.notice` |
| Panes | `panes.tabStrip`, `panes.chrome.{focused, unfocused}` (header and focus ring), `panes.split.{vertical, horizontal}` (divider and grip), `panes.startupOverlay` |
| Palette and search | `palette.row.{session, command}` (⇧⌘P), `search.row.{session, transcript, file, action}`, `search.chipBar`, `search.footer` (⌘F) |
| Sheets and cards | `sheets.{rebase, deleteWorktree, deleteMerged}`, `prompt.card` |
| Activity and cheat sheet | `activity.row.{working, thread, folded}`, `cheatSheet` |
| Settings | `settings.card`, `settings.nav`, `settings.switch.{on, off}` |

How the entries are built:

- **Models.** Models come from `AppState.fixture` wherever the app derives them from the store: sidebar rows, group rows and palette hits. They are literals wherever the app gets them from elsewhere: git, transcripts, the update checker. Nothing reads the clock, and every `now` is `Fixture.now`.
- **Backdrop.** Each render paints a theme token under the component: the surface it sits on in the app. The dump names the token in `facts.backdrop`. For overlays that sit on `.hudWindow` glass, `windowBackground` stands in for the material, which is masked anyway.
- **Glass chrome.** The glass sheets and the prompt card are rendered inside an `NSVisualEffectView` styled as `GlassSheetPanel.make` and `PromptCardController` style theirs, with no `NSPanel` around it. A view in a window takes the window's backing scale, and on a CI runner that scale is whatever the virtual display reports.
- **Not captured here.** Whole panels (the palette, the activity feed, Settings) and the full window are not captured. Panels are covered by their rows, bars and cards. The full window is WOR-322 S4.

## Files

`Tests/TkzAppTests/ComponentSnapshots/` is excluded from `TkzAppTests` in the macOS branch of `Package.swift` and read through `#filePath`. Nothing in it is bundled.

| File | Content |
|---|---|
| `<component>@<preset>@<scale>.png` | The render, written by TkzPNG, so the bytes depend only on the pixels. It is RGB when every pixel is opaque, otherwise RGBA with straight alpha. At a fractional scale the bitmap is `ceil(logical × scale)` on each axis, and the component is drawn from the top-left corner. |
| `<component>@<preset>@<scale>.json` | The `LayoutDump`, as canonical JSON (below). |
| `manifest.json` | The reference machine, every file's size and sha256, the total against the budget, and the off-grid edges. |
| `README.md` | A pointer to this page. |

`<scale>` is written as Swift prints the `Double`: `2.0` and `1.6`.

## Layout dump schema (version 1)

Conventions, fixed by ADR-0003 §2:

- Frames are logical points with a **top-left origin**, relative to the component's own bounds, whatever the views' `isFlipped`.
- **Nothing is rounded.** The doubles are exactly what AppKit and CoreText reported.
- **The JSON is canonical:** keys are sorted, the output is compact with no whitespace, there is one trailing newline, and absent optional fields are left out rather than written as `null`. Two runs on one build are byte-identical. Use `jq -S .` to read one.

Top level:

| Field | Type | Meaning |
|---|---|---|
| `schema` | int | `1`. The parity tool refuses a schema it does not know. |
| `component` | string | Catalog name, e.g. `sidebar.sessionRow.plain`. |
| `theme` | string | `Theme.Preset` raw value. |
| `appearance` | string | The forced `NSAppearance.Name`: `NSAppearanceNameDarkAqua` for the dark presets, `NSAppearanceNameAqua` for Light. |
| `scale` | number | `2` or `1.6`. |
| `size` | `{width, height}` | The logical size the component was laid out at. |
| `pixels` | `{width, height}` of `{pixels, exact, roundedUp}` | The bitmap size per axis, `logical × scale` to six decimals, and whether a fractional product was rounded up (a 44 pt row at 1.6 is `{71, 70.4, true}`). |
| `facts` | `{string: string}` | Component results that are not frames: `backdrop`; `detailWraps` (session rows); `placed.NN` (status bar: each item's text, `x`, `w` and any truncated width, because the strip draws its text in `draw(_:)`); `focusRingWidth` (pane chrome); `borderWidth` and `cornerRadius` (glass chrome). |
| `masks` | array of `{kind, frame, source}` | Regions the pixel comparison leaves out, from the view tree: `vibrancy` (`NSVisualEffectView`), `searchField`, `accentSelection` (a `.regular` table selection), `scroller`. |
| `root` | node | The component's view. |

Node:

| Field | Type | Meaning |
|---|---|---|
| `kind` | `view` \| `layer` | A view, or a layer that is not a view's backing layer. |
| `type` | string | Class name (`SessionRowView`, `CATextLayer`, `StatusDotLayer`). |
| `name` | string? | `NSView.identifier` or `CALayer.name`. |
| `frame` | `{x, y, width, height}` | In the component's top-left space. |
| `hidden` | bool? | Present only when hidden. A hidden view's subtree is not walked. |
| `alpha` | number? | `alphaValue` or `opacity`, present only when below 1. |
| `flipped` | bool? | For views, present only when `isFlipped`. |
| `animations` | [string]? | The keys of the animations that were attached and then removed for the capture (the dot pulse, the spinner, the switch knob). |
| `text` | run? | See below. |
| `children` | [node]? | In drawing order: a view's own sublayers first, then its subviews. |

Text run (`CATextLayer` or `NSTextField`):

| Field | Meaning |
|---|---|
| `string`, `font`, `size` | The text, the PostScript name of the font actually used (fallbacks included), and its point size. |
| `measuredWidth` | The natural single-line width. |
| `availableWidth` | The width the run was given. |
| `wraps`, `fittingHeight` | Whether it wraps, and for a wrapping run the height it needs at `availableWidth`. |
| `truncated` | Whether it does not fit. |

## Snapping kinds

The Mac does not snap anything itself; its geometry lands on whole device pixels at 2.0 by construction. The Linux toolkit snaps each design value by the kind its token carries (ADR-0003 §2; `Snapper` in WOR-316 S1, the token tags in WOR-307 S3):

| Kind | Device pixels | Used for |
|---|---|---|
| `.hairline` | Exactly 1, at every scale. | The status bar's top line (`1 / backingScaleFactor` on the Mac). |
| `.points` | Each edge rounded on its own: `(edge × s).rounded()`. | Layout frames: rows, bars, panes, dividers, cards, hit areas. |
| `.mark(d)` | The origin is rounded as an edge, and the extent is `max(1, (d × s).rounded())`. | Fixed-size marks: status dots, close boxes, badge heights, icon boxes. |
| stroke | `max(1, (w × s).rounded())`, inside the snapped rect. | Borders, focus rings, rules. |

Rounding is Swift `.rounded()`, which rounds half away from zero.

Two more tags mark the token values that the rules above never round:

| Tag | Device pixels | Used for |
|---|---|---|
| `.unrounded` | `w × s`, never rounded. | Corner radii (vector paths, drawn antialiased) and font point sizes (text snaps at the baseline). |
| `.scalar` | Not scaled at all. | Ratios, alphas and counts. |

`SnapReference` (`Tests/TkzAppTests/ComponentGoldens.swift`) implements these rules for checking only. `ComponentSnapshotADRTests` renders the components that ADR-0003's worked examples 1–6 are about, applies the rules to the dumped frames, and requires the ADR's numbers at 1.6 and at 2.0. It runs on every macOS CI run, with or without goldens. A mismatch is fixed by amending ADR-0003 (WOR-299), never by changing the Mac.

The same suite also lists every dumped edge that is off the 0.5 pt grid at 2.0. The list is printed, written to `$TKZMUX_TEST_ARTIFACTS/component-snapshots/offgrid-edges-2.0.txt`, and recorded per component in `manifest.json` (`offGridEdges`, read from the `midnightIndigo` dump, because frames do not depend on the preset). Each entry is an exception to "the Mac is snap-exact at 2.0". After the first generation, carry the list into ADR-0003's exception table in a WOR-299 amendment.

## Design tokens

`DesignTokens` (`Sources/TkzCore/DesignTokens*.swift`, WOR-307 S3) holds the design's numbers with no toolkit: `Double` and Foundation only, so both UIs read the same table. Each value is a `DesignToken`: its path name (`Metrics.Sidebar.sessionRowHeight`), its value in points (device pixels for `.hairline`, unitless for `.scalar`), and its `DesignToken.Snap` tag from the two tables above.

| Namespace | Holds | Filled by |
|---|---|---|
| `DesignTokens.Metrics` | Lengths: the values of the 13 `*Metrics` enums, the window geometry (1240×820, minimum 720×420, sidebar 300/240/520, detail minimum 400), the status-bar hairline, and the inline Auto Layout constants | WOR-307 S3; S5 (Auto Layout constants, `DesignTokens+Layout.swift`); S6 the private statics |
| `DesignTokens.Typography` | The text roles (below), the changes viewer's sizes, line spacing (`lineHeightMultiple`) and the Markdown indent | S3 (sizes); S4 (roles, line spacing) |
| `DesignTokens.Radii` | Corner radii | S3 (the radii the Metrics enums held); S6 the inline ones |
| `DesignTokens.Motion`, `DesignTokens.Surfaces` | Durations; per-surface radius and border, such as the palette's two modes | S6 |

How the Mac reads them: the old names stay and forward, with the type they always had. `SidebarMetrics.sessionRowHeight` is `DesignTokens.Metrics.Sidebar.sessionRowHeight.value`, a `CGFloat` constant is `CGFloat(token.value)`, and a count is `Int(token.value)`. Each conversion is exact, so the Mac draws what it drew before, and the goldens stay byte-identical. Tags are chosen from ADR-0003 §2: a layout length is `.points`; a fixed-size mark is `.mark` (dots, close boxes, the split grip, the switch knob); a line width is `.stroke` (the focus ring, the group colour edge); the status bar's top line is the only `.hairline`.

Three suites hold this in place:

- `DesignTokensTests` (TkzCoreTests, runs on Linux) pins every old constant to its token and to the literal it held before the move, bit for bit, together with its tag. It scans the 13 enum bodies in `Sources/TkzApp` for numeric literals and checks that every member forwards to its pinned token. It also checks that the window-geometry and hairline sites read their tokens.
- `SourceHygieneTests.designTokensImportOnlyFoundation` keeps the token files on Foundation and `Double`. CoreGraphics in particular is a Mac-only import that the UI-framework check does not see.
- `DesignTokenForwardingTests` (TkzAppTests, macOS) reads every reachable old constant through its old name at run time.

`swift test --filter ThemeTests/printsDesignTable` prints every token with its value and tag after the colour table.

To add a token, declare it in its namespace with its path as its name, add it to `all`, pin the literal it replaces in `DesignTokensTests.pins` (an Auto Layout constant: `LayoutTokensTests`), and forward the old name to it. Never change a value in a migration commit: a different number is a Mac-visible change.

### Typography roles

A `DesignTokens.Typography.Role` (`Sources/TkzCore/DesignTokens+Typography.swift`, WOR-307 S4) is one text style as the Mac draws it. It holds:

- `size`, in points. It snaps `.unrounded`: text snaps at its baseline, not at its size.
- `face`: `.ui` (the system font; `Theme.Fonts.ui.family` is nil) or `.mono` (`Theme.Fonts.mono`, JetBrains Mono).
- `weight`: the weight drawn. A mono role is always `.regular`, because `Theme.Fonts.mono(_:weight:)` ignores its weight whenever JetBrains Mono or Menlo resolves. Five Mac sites still ask for another weight (MainToolbarController's cluster glyphs, `StatusBarView.pillFont`, SearchRowViews' status, MarkdownRenderer's bold code). They draw Regular, and the tokens record that rather than fix it.
- `tracking` (points, the Mac's `.kern`) or `trackingEm` (a fraction of the size, which the Mac multiplies by the point size). `kern` gives the points at the role's size, computed the way the Mac computes it. WOR-312 calibrates Inter against these values, so they stay exactly as the Mac applies them.
- `lineHeight` and `baseline`, plus the font name, ascender, descender and leading in `lineMetrics`. They are measured, never typed in (below).

The Mac reads a role through `Theme.Fonts.font(_:)` (`ThemeAppKit.swift`). It calls `ui(size, weight:)` for a UI role and `mono(size)` for a mono role, which is what the literal calls it replaced passed. Where the Mac computes with a value (`.kern`, `MarkdownRenderer.bodySize`, `headerSize`, the `lineHeightMultiple`s), the site converts it with `CGFloat(…)` and keeps the arithmetic it had. The roles cover the 46 literal-size font calls, the 3 `.kern` literals, `StatusBarView.pillTracking` and the MarkdownRenderer sizes. The preset-wide sizes (`Theme.Fonts.ui.title`, `.body`, `.caption`, and the mono `.detail` and `.statusBar`) stay in `Theme.Fonts`.

**Line metrics.** `Sources/TkzCore/DesignTokens+LineMetrics.swift` is generated. With `TKZMUX_UPDATE_SNAPSHOTS=1`, `ComponentSnapshotTypographyTests` (TkzAppTests, in the `ComponentSnapshot` filter) resolves every role to its `NSFont` and records:

- `fontName`, `ascender`, `descender` and `leading`, which are what CoreText lines are built from;
- `NSLayoutManager.defaultLineHeight(for:)` as `lineHeight`;
- `defaultBaselineOffset(for:)` as `baseline`.

It measures twice, refuses a measurement that is not reproducible, and writes the file with the macOS build in `measuredOn`. Until the file is generated it is an empty stub, the roles' `lineHeight` and `baseline` are nil, and the check is skipped with a message. Once it is generated, the check works like the goldens. On the `measuredOn` build the file must be exactly what the run measures. On any other build the values must agree within ±0.5 pt and the font names must match.

Two more suites hold the roles in place:

- `TypographyTokensTests` (TkzCoreTests, runs on Linux) pins every role to the literal call, `.kern` value or static it replaced, bit for bit. It lists every migrated TkzApp site, checks that the old expression is gone and the new one reads the pinned role, and parses each old plain font call back to its role. It also runs the S4 grep, `\.(ui|mono)\([0-9]|ofSize: [0-9]|\.kern: [^,\]]*[0-9]` over `Sources/TkzApp`, which must find nothing outside `// token-exempt: <reason>` lines.
- `ComponentSnapshotTypographyTests.rolesResolveToTheFontsTheLiteralCallsMade` (macOS) compares each role's font with the literal call it replaced, as AppKit resolves both. It also confirms that every mono role, the semibold status pill included, draws JetBrains Mono Regular.

### Auto Layout constants

WOR-307 S5 moved every literal `constant:` and `equalToConstant:` that TkzApp passed to an anchor into `DesignTokens.Metrics` (`Sources/TkzCore/DesignTokens+Layout.swift`). There is one token per role in its component, for example `Metrics.ActivityRow.gap` or `Metrics.PaletteRow.titleTop`. The component's namespace is new where it had none and extends the S3 enum where it had one (`Metrics.PromptCard`, `Metrics.Settings`). The 1 pt border, divider and separator views are `.stroke`. The dots and icon boxes are `.mark`. Everything else is `.points`.

A site reads its token as `CGFloat(LayoutTokens.<Component>.<name>.value)`. `LayoutTokens` is a file-private alias for `DesignTokens.Metrics`; the one-site `ChromeViewController.swift` spells the path out instead. A trailing or bottom constant keeps its sign at the site (`constant: -CGFloat(…)`), so a token always holds the magnitude. Each site differs from the line it replaced in the literal alone, and `-CGFloat(v)` is exactly the literal `-v`, so AppKit gets the constant it had. Two zero placeholders stay literal under `// token-exempt:`: the tab strip's starting height and the merged-worktrees list's. The code sets both before they are shown.

`LayoutTokensTests` (TkzCoreTests, runs on Linux) holds this in place. It pins every S5 token to the literal its sites held, bit for bit, with its tag. It lists every migrated line as it read before the move, rebuilds the line the migration writes from it, and requires that line in the file and the old one gone. It also runs the S5 grep, `constant: -?[0-9]|equalToConstant: [0-9]` over `Sources/TkzApp`, which must find nothing outside the two exempt lines.

## How a render is checked

`ComponentSnapshotGoldenTests` renders every catalog entry × preset × scale and compares the result with its golden. Which comparison applies depends on the machine:

| Machine | Comparison |
|---|---|
| The manifest's macOS build (`sysctl kern.osversion` equals `reference.macOSBuild`) | PNG and JSON byte for byte. A difference fails. |
| Any other build | The layout: frames, flags, strings, fonts, wrap and truncation results, masks and facts must match exactly; `measuredWidth` and `fittingHeight` may differ by up to ±0.5 pt. A PNG that differs is not a failure. It is written with the golden and a diff image to `$TKZMUX_TEST_ARTIFACTS/component-snapshots/diff/`. |

Without a committed manifest the suite is skipped, with a message saying how to generate the set. Two more tests check the set itself:

- The manifest lists exactly the files on disk, its sizes, sha256s, total and off-grid lists match those files, and the total is within WOR-307's 4 MiB share (ADR-0003 §5, `componentSnapshotShareBytes`).
- Every catalog entry × preset × scale has its PNG and JSON, and no other golden files exist.

WOR-322's size test enforces the combined budget across this folder and `Tests/Parity/References/`. WOR-322 lists these goldens by path and sha256 and never copies them.

## Determinism

The harness forces these conditions:

- **Appearance.** The view and the current drawing appearance are both forced from the preset.
- **Scale.** The layers' `contentsScale` is set through `LayerContentsScale.withScale` (below).
- **Animations.** The whole build-layout-draw runs inside `CATransaction.setDisableActions(true)`, and every attached animation is recorded and then removed.
- **Fonts.** The bundled fonts are registered first.
- **PNG encoding.** The PNG encoder is TkzPNG, which depends only on the pixels.
- **Clock.** No model reads the clock.

The update renders every case twice in one process and refuses to write a render that differs. The workflow then checks the written set from a second process.

## The `contentsScale` seam

`LayerContentsScale` (`Sources/TkzApp/LayerContentsScale.swift`, WOR-307 S1) is the only way to render the app's hand-made layers at a scale other than 2. Four sites read it:

- `StatusDotView.swift`, twice (every `SidebarLayers` text layer and the chevron);
- `PaneStartupOverlayView.swift` (the spinner);
- `MainWindowController.swift` (the empty-state label).

Production never sets it, and the value stays 2. The snapshots use `withScale(_:_:)`. WOR-322 S4's full-window capture sets `current` once from `TKZMUX_DEV_CAPTURE_SCALE`, before the window is built, and does not touch the four sites. The Mac never derives the scale from `backingScaleFactor`, because that would change what a 1x display draws today.

## Updating the goldens

Goldens are generated only on the reference runner: the GitHub-hosted `macos-26` image with Xcode 26.1, the same runner as `ci.yml` (ADR-0003 §5). They are never generated on a developer Mac, and never in a commit that also changes the app.

1. Dispatch the **Component snapshots** workflow (`.github/workflows/component-snapshots.yml`). It runs these steps:

   ```sh
   find Tests/TkzAppTests/ComponentSnapshots -type f ! -name README.md -delete
   TKZMUX_UPDATE_SNAPSHOTS=1 swift test --no-parallel --filter ComponentSnapshot
   swift test --no-parallel --filter ComponentSnapshot
   ```

   The first `swift test` writes the PNGs, the JSONs and `manifest.json` into the source tree through `#filePath`, and `Sources/TkzCore/DesignTokens+LineMetrics.swift` (the typography line metrics, above). The second checks them byte for byte from a fresh process. The workflow uploads the folder as the `component-snapshots` artifact, the line metrics as `typography-line-metrics`, and the per-render artifacts and any diffs as `component-snapshot-renders`.
2. Download `component-snapshots`, replace the contents of `Tests/TkzAppTests/ComponentSnapshots/` with it, put `typography-line-metrics` at `Sources/TkzCore/DesignTokens+LineMetrics.swift`, and commit them on their own in a reviewed PR. Review checklist:
   - `manifest.json`'s `reference` names the runner image.
   - `totalBytes` is within `budgetBytes`.
   - The off-grid lists have gone into ADR-0003's exception table.
3. If the set is over budget, the update fails once and still writes and uploads everything; `manifest.json` lists every file's size. Renegotiate the split in ADR-0003 (WOR-307 has 4 MiB, WOR-322 has 5 MiB). Do not drop coverage to fit.

A regeneration that follows a runner image change must show that the old and new sets agree. L0 must be byte-identical or each difference explained, and L5 must pass between the two sets (ADR-0003, Consequences).

Once a set is committed, the M3 refactors (WOR-308–WOR-310 and WOR-307 S3–S6) must leave every golden byte-identical. A changed golden in a refactor commit means the refactor changed what the Mac draws.

## Comparing: `tkzmux-vtdump compare`

Every parity comparison goes through one command, on both OSes (WOR-322 S1). The code is the portable `TkzParity` module (`Sources/TkzParity`: Foundation and TkzPNG only, no AppKit, Metal or GTK), so the Linux runner (WOR-322 S3) and the per-layer producers call the same functions the command does.

```sh
tkzmux-vtdump compare <a> <b> [--mask m.json] [--json out.json] [--heatmap out.png] \
                              [--layer golden|exact|L3|L4|L5|L6]
```

| Inputs | What is measured | Passes when |
|---|---|---|
| Two PNGs | The sizes; the channel rule; SSIM, global and per 64 px tile; the masked pixels per kind; ΔE2000 mean and p99 | The gate `--layer` picks passes (below). A size mismatch always fails. |
| Anything else, either side `*.json` | Bytes; on a difference, both sides again after canonical key order, with the first differing JSON paths | The JSON is equal after canonical key order (L0). |
| Anything else | Bytes, with the first differing offset (and line and column) | The bytes are identical (L1, L2). |

Exit status: 0 pass, 1 fail, 2 usage or unreadable input (an unknown option included, so a mistyped flag never falls back to the default gate). The summary goes to stdout; `--json` writes the full report as compact JSON with sorted keys, so two runs diff cleanly.

**How the image metrics read pixels.** Both PNGs are decoded by TkzPNG and compared as stored, with no colour management (ADR-0003 §1). Alpha is premultiplied first, as a `bgra8Unorm` readback holds it: colour under alpha 0 is not a difference, and a translucent pixel counts as composited over black.

- **Channel rule.** A pixel differs when any of its four premultiplied channels differs by more than the tolerance. The fraction is over the unmasked pixels. This is `assertMatchesGolden`'s rule (`TerminalRendererTests.swift`), so `--layer golden`, the default, gives the same verdict as the golden comparator on an unmasked pair.
- **SSIM** follows ADR-0003 §3 to the letter. Two choices the ADR leaves open are fixed here:
  - Every pixel is a window centre. A window that hangs over the image border uses the pixels it covers, with its weights renormalised; nothing is padded.
  - Masked pixels have weight zero inside every window, not only as centres. A difference under a mask therefore cannot reach the score through a neighbouring window, and two images that differ only under their masks score exactly 1.0.

  The Gaussian taps are literals, so the score does not depend on the platform's `exp`. Identical images score exactly 1.0.
- **ΔE2000** (sRGB, D65, Sharma 2005) is in the report and the summary and never in a verdict.

**Gates.** `--layer` picks one of `ParityGate`'s fixed rules, each built from `ParityThresholds` (`Sources/TkzParity/ParityThresholds.swift`, which mirrors ADR-0003 constant by constant). There is no flag that sets a number.

| `--layer` | Rules applied |
|---|---|
| `golden` (default) | Channel rule at `l5ChannelTolerance` / `l5PixelTolerance`, the golden comparator's defaults |
| `exact` | Every pixel identical |
| `L3` | Channel rule at `l3ChannelTolerance` / `l3PixelTolerance` |
| `L4` | Global SSIM ≥ `l4GlyphMinSSIM`, for one glyph image. The bbox and coverage rules need the atlas glyph table and are WOR-312's producer's. |
| `L5` | The channel rule as `golden` over every unmasked pixel, and global SSIM ≥ `l5ComponentMinSSIM`. Restricting the channel rule to non-text pixels, the text-run SSIM and the 1.6 edge band need the L0 boxes and edges; the L5 producers (WOR-316–WOR-319) apply them on top, with their own `MaskBitmap`s. |
| `L6` | Global SSIM ≥ `l6WindowMinSSIM`, and the masks cover at most `l6MaxMaskedFraction` of the window |

`ParityThresholdTests` reads ADR-0003 and fails when a constant is missing from the ADR, when the ADR names a constant `ParityThresholds` lacks, or when a value the ADR writes as `name = value` differs.

**The heatmap** (`--heatmap`) is an opaque PNG of the same size: dimmed grey where the pixels are identical, amber where they differ within the channel tolerance, red beyond it (brighter for a larger delta), and blue where a mask applies.

### Mask files

A mask file lists the regions a comparison leaves out (ADR-0003 §3, Masks). Producers write it from the L0 dump or the terminal grid; it is never drawn by hand for one run.

```json
{
  "schema": 1,
  "grid": {"cellWidth": 14, "cellHeight": 30, "originX": 0, "originY": 0},
  "masks": [
    {"kind": "vibrancy", "rect": {"x": 0, "y": 0, "width": 2112, "height": 84}, "source": "header"},
    {"kind": "cjkEmoji", "cells": {"column": 3, "row": 1, "columns": 2, "rows": 1}}
  ]
}
```

- `kind` is one of ADR-0003's four: `fallbackGlyph`, `cjkEmoji`, `vibrancy`, `windowControls`. Any other kind is rejected. (The layout dump's own `searchField`, `accentSelection` and `scroller` masks are not parity masks; a producer that needs one maps it explicitly.)
- Each mask has exactly one of `rect`, in device pixels with a top-left origin, and `cells`, on `grid` (needed only by cell rects; the origins default to 0).
- A fractional `rect` (a frame in points times a fractional scale) covers every pixel it touches. Rects are clipped to the image.
- `source` is free text for the report.

## The layer manifest

`Tests/Parity/layers.json` holds one row per layer and scale: `L0-component`, `L0-window`, `L1`–`L6`, each at 1.6 and 2.0. Each row has:

- `state`: `pending` (no producer gates it yet; the runner reports it with its owner and does not fail) or `enforced`;
- `owner`: the Linear issue that owns the layer, as `WOR-312`, `WOR-318 S7` or the range `WOR-316–WOR-319`;
- `what`: a reader's description.

The issue that lands a layer's producer switches its own rows to `enforced` in the same PR. WOR-324 S5 finally checks that every row is `enforced` or an approved ADR-0003 exception. `LayerManifestTests` requires every layer at both scales exactly once and an owner on every row, so a `pending` row without an owner fails. It also pins each layer's owner to the one ADR-0003 and WOR-322 name.

## The reference budget

ADR-0003 §5 sets one committed budget for every reference image and dump, `referenceBudgetBytes`, split into `componentSnapshotShareBytes` (`Tests/TkzAppTests/ComponentSnapshots/`, WOR-307) and `parityReferenceShareBytes` (`Tests/Parity/References/`, WOR-322, including WOR-312's font dumps and WOR-313's conformance outputs). `ParityThresholdTests.theReferenceTreesFitTheBudget` counts every regular file in both trees, manifests included, on both OSes. A tree that does not exist yet counts as empty. `Tests/Parity/References/` holds only the L2 set so far ([below](#the-l2-references)); the rest arrives with WOR-322 S2's exporter (`make parity-references`), which runs only on the reference runner, and with WOR-312's and WOR-313's dumps.

## The Linux parity runner

`Tests/TkzParityRunnerTests` (WOR-322 S3) is the gate. It is a Linux-only test target in the `#if os(Linux)` branch of `Package.swift`, and it links no GTK, Vulkan or font stack: producers run as child processes, mostly `tkzmux-vtdump`. So it is also on the `ubuntu` job's non-GTK `--target` list.

```sh
swift test --build-system native --filter TkzParityRunnerTests
```

It runs one test case per row of `Tests/Parity/layers.json`:

| Row | What happens |
|---|---|
| `pending` | Reported with its owner issue (`parity L5@1.6: PENDING, owner WOR-316–WOR-319`). Never fails. |
| `enforced`, references committed | The layer's producer writes the Linux artifacts, and its check compares them with the references under the layer's ADR-0003 rule. A breach fails the row. |
| `enforced`, references missing | Skipped with the producer's message, which names what produces the references. With `TKZMUX_REQUIRE_PARITY_REFERENCES=1` it fails instead. L2 never skips: its references are committed (below). |
| `enforced`, no producer registered | Fails. |

**The producer registry.** `ParityProducers.registry` (`Tests/TkzParityRunnerTests/ParityProducers.swift`) maps a layer to three closures. One says whether the references are committed at a scale. One writes the artifacts into an empty directory, from a child process that gets exactly the environment it is handed. One compares the artifacts with the references and writes its reports. The issue that lands a layer's producer registers it there and switches the layer's rows to `enforced` in the same PR. `registeredProducersAreEnforced` fails if a registered layer is not enforced at both scales. The owners are WOR-312 (L1, L4), WOR-313 S3 (L3), WOR-316–WOR-319 (L0-component, L5) and WOR-318 S7 (L0-window, L6).

**No display.** Every producer starts from the runner's environment without `WAYLAND_DISPLAY` and `DISPLAY`, and without the variables the isolation reruns set. The CI step also runs `swift test` under `env -u WAYLAND_DISPLAY -u DISPLAY`.

**Output.** Everything goes to `.build/parity/`, or to `$TKZMUX_PARITY_OUT` if it is set:

| Path | Content |
|---|---|
| `<layer>@<scale>/result.json` | The row: state, owner, outcome (`pending`, `skipped`, `passed`, `failed`), failures and notes |
| `<layer>@<scale>/produced/` | What the producer wrote |
| `<layer>@<scale>/reports/` | The check's JSON reports. Image layers add `<name>.heatmap.png` through `ParityReports.compareImages`, which is `tkzmux-vtdump compare` as a function. On a failure, `reference/` holds a copy of each failing reference. |
| `<layer>@<scale>/producer.log` | The child's stdout and stderr |
| `isolation/<layer>@<scale>/<variant>/` | The isolation reruns, with a byte report for each artifact that differs |

The `parity` job in `ci-linux.yml` uploads the directory as the `parity-reports` artifact when it fails. It runs in the required Arch image with lavapipe, the validation layer, the parity fonts and the pinned shaderc ([build.md](build.md#linux-ci)).

**Environment isolation.** `EnvironmentIsolationTests` reruns every enforced producer under each of the following, each in a fresh child process, and requires every artifact to be byte-identical to the clean run's:

- `GDK_SCALE=2`;
- `FREETYPE_PROPERTIES`, with hinting and stem darkening switched;
- Omarchy's `50-omarchy.conf` through `FONTCONFIG_FILE`. This is the installed file when there is one, and otherwise a stand-in with the same kinds of rules: monospace and sans-serif reassigned, and Noto Color Emoji accepted for them;
- a GNOME `text-scaling-factor` of 0.7273, set through a GSettings keyfile backend in a private `XDG_CONFIG_HOME`;
- all four at once.

`theVariantsReachTheChild` checks with `env` that the variables really arrive in the child. Where `gsettings` and its schema are installed, `theTextScaleVariantIsWhatGSettingsReads` checks that the child reads 0.7273. L1, L3 and L4 are covered as soon as they are registered.

## L2: FrameBuilder buffers

L2 asks whether the Mac and Linux FrameBuilders write the same instance buffers from the same cell metrics and the same atlas glyph table (ADR-0003 §3, `l2Exact`). Both sides run the same code, `FrameDump.swift` in TkzRenderCore, behind one command:

```sh
tkzmux-vtdump framedump --out <dir> [--scale s] [--fonts system|parity] <file.tkzrec> …
tkzmux-vtdump framedump --out <dir> --replay <refdir> [--scale s] <file.tkzrec> …
```

Without `--replay`, the command replays each recording headlessly and builds one frame through `FrameBuilder` over the platform's font stack: CoreText on the Mac and FreeType on Linux, at the theme's terminal size (14 pt) and the given scale. It writes two files per recording:

| File | Content |
|---|---|
| `<fixture>@<scale>.json` | The `CellMetrics`, the padding, the atlas sizes, and the glyph table: every request the glyph cache made of its source, in order (`glyph`, `sprite`, `empty`, `noSprite`), with the face, page, slot, bitmap size, bearings and `appliedScale`. Also the buffer layout and `source` (platform, glyph source, fonts). Sorted keys. |
| `<fixture>@<scale>.bin` | The four buffers the renderers bind, written field by field in little-endian order: `background` (`TkzBgCell`, 4 B), `glyphs` (`TkzGlyphInstance`, 32 B), `rectsBelow` and `rectsAbove` (`TkzRectInstance`, 32 B), with the cursor included as the renderers place it |

With `--replay`, the metrics and glyph table come from `<refdir>/<fixture>@<scale>.json`, and no font is opened. `GlyphTableSource` answers each request with the reference's bitmap size, bearings and page, in the reference's order. The shared packer then puts every glyph where the reference's packer put it, and a FrameBuilder that matches writes the reference's `.bin` again. When the table cannot answer a request, the command lists the request and exits 1.

The L2 producer replays every fixture at each scale. The check requires:

- the `.bin` byte for byte. On a difference, `reports/<stem>.bin.json` names the first 20 differing fields as buffer, instance and field, with both values: `glyphs[37].atlasPos.x (bytes 1396..<1398): reference 4100, replay 0100`;
- the replayed glyph table equal after canonical key order;
- once WOR-312 commits `fonts/fontmetrics.json`, the reference's metrics equal to that file's JetBrains Mono entry at 14 pt and that scale.

`aFlippedReferenceByteFailsL2WithItsDiff` flips one bit in a copy of a reference and checks that L2 fails, names the field, and leaves the report and the reference in `reports/`.

**Fixtures.** L2 replays the four `Tests/TkzTerminalCoreTests/Fixtures/*.tkzrec` recordings and `Tests/Parity/Fixtures/l2-features.tkzrec`. The real sessions draw plain and bold ASCII, a few underlines and box sprites. The feature sheet adds the rest of what FrameBuilder does:

- all four styles and every underline style, plus strikethrough and an underline colour;
- palette, bright, 256-colour and direct colours;
- inverse, faint and invisible text;
- wide CJK, colour emoji, a ZWJ sequence, a flag and a combining mark;
- box and block sprites and Claude Code's symbols;
- a hyperlink, a background run, a wrapped line and a parked cursor.

The feature sheet is written from `L2FeatureSheet.output` with an empty environment and a zero timestamp. `theCommittedRecordingIsItsSource` pins it. To regenerate it, run `TKZMUX_UPDATE_PARITY_FIXTURES=1 swift test --build-system native --filter L2FeatureSheetTests`, then regenerate the references.

### The L2 references

`Tests/Parity/References/framebuilder/` holds the five fixtures at 1.6 and 2.0: 20 files, about 340 KB of the 5 MiB WOR-322 share. `scripts/parity-framebuilder-references.sh` writes them on either OS, building the release `tkzmux-vtdump` first. `--check` writes them to a temporary directory instead and fails unless they equal the committed set.

- **The reference set is the Mac's.** The command that produces it is:

  ```sh
  scripts/parity-framebuilder-references.sh
  ```

  It runs on macOS, on the reference runner (ADR-0003 §5). It is equivalent to the following, run for `--scale 1.6` and again for `--scale 2.0`:

  ```sh
  swift build -c release --product tkzmux-vtdump
  .build/release/tkzmux-vtdump framedump --scale 1.6 --out Tests/Parity/References/framebuilder \
      Tests/TkzTerminalCoreTests/Fixtures/{claude-boot,claude-tool-run,synthetic-basic,zsh-ls-color}.tkzrec \
      Tests/Parity/Fixtures/l2-features.tkzrec
  ```

  WOR-322 S2's `make parity-references` (`scripts/parity-export-mac.sh`) calls the script, and its output is committed through S2's reviewed workflow. The dumps then record `"platform": "macos"` and `"glyphSource": "CoreText"`.
- **Until then, the committed set is a Linux bootstrap.** WOR-322 S3 made it with the same script on Linux, with FreeType and the pinned parity fonts (`--fonts parity`), and the dumps say so in `source`. L2 is shared code, so the gate is the same either way: the Linux FrameBuilder must rebuild the committed buffers from the committed table. Until the Mac set replaces the bootstrap, that pins FrameBuilder, the packer and the buffer layout against regressions, but it does not yet prove anything across the two OSes. The runner adds a note to every L2 row while `source.platform` is not `macos`.
- **Regenerating** is needed when FrameBuilder's output changes on purpose, or when the fixtures change. Rerun the script on the Mac, and on Linux until the Mac set exists. Commit the set on its own, and explain in the PR every buffer that changed.

## Regenerating the references

Every committed reference has exactly one producer:

| Tree | Producer | Where it runs |
|---|---|---|
| `Tests/TkzAppTests/ComponentSnapshots/` | the Component snapshots workflow (WOR-307; [Updating the goldens](#updating-the-goldens)) | reference runner |
| `Tests/Parity/References/framebuilder/` | `scripts/parity-framebuilder-references.sh` (L2, above) | reference runner. A Linux bootstrap until WOR-322 S2 |
| `Tests/Parity/References/fonts/` | WOR-312's `atlas --json`, `fontmetrics` and NSFont chrome dumps | reference runner (WOR-312 S1, S2) |
| `Tests/Parity/References/terminal/`, `manifest.json`, the full-window captures | `make parity-references` (`scripts/parity-export-mac.sh`) | reference runner (WOR-322 S2, S4) |
| WOR-313's conformance outputs | `TKZMUX_WRITE_CONFORMANCE_REFS`, a step that WOR-313 S3 adds to the exporter | reference runner |

`ParityThresholdTests.theReferenceTreesFitTheBudget` counts all of them. Never copy one tree's files into another.
