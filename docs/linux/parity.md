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

`SnapReference` (`Tests/TkzAppTests/ComponentGoldens.swift`) implements these rules for checking only. `ComponentSnapshotADRTests` renders the components that ADR-0003's worked examples 1–6 are about, applies the rules to the dumped frames, and requires the ADR's numbers at 1.6 and at 2.0. It runs on every macOS CI run, with or without goldens. A mismatch is fixed by amending ADR-0003 (WOR-299), never by changing the Mac.

The same suite also lists every dumped edge that is off the 0.5 pt grid at 2.0. The list is printed, written to `$TKZMUX_TEST_ARTIFACTS/component-snapshots/offgrid-edges-2.0.txt`, and recorded per component in `manifest.json` (`offGridEdges`, read from the `midnightIndigo` dump, because frames do not depend on the preset). Each entry is an exception to "the Mac is snap-exact at 2.0". After the first generation, carry the list into ADR-0003's exception table in a WOR-299 amendment.

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

   The first `swift test` writes the PNGs, the JSONs and `manifest.json` into the source tree through `#filePath`. The second checks them byte for byte from a fresh process. The workflow uploads the folder as the `component-snapshots` artifact, and the per-render artifacts and any diffs as `component-snapshot-renders`.
2. Download `component-snapshots`, replace the contents of `Tests/TkzAppTests/ComponentSnapshots/` with it, and commit it on its own in a reviewed PR. Review checklist:
   - `manifest.json`'s `reference` names the runner image.
   - `totalBytes` is within `budgetBytes`.
   - The off-grid lists have gone into ADR-0003's exception table.
3. If the set is over budget, the update fails once and still writes and uploads everything; `manifest.json` lists every file's size. Renegotiate the split in ADR-0003 (WOR-307 has 4 MiB, WOR-322 has 5 MiB). Do not drop coverage to fit.

A regeneration that follows a runner image change must show that the old and new sets agree. L0 must be byte-identical or each difference explained, and L5 must pass between the two sets (ADR-0003, Consequences).

Once a set is committed, the M3 refactors (WOR-308–WOR-310 and WOR-307 S3–S6) must leave every golden byte-identical. A changed golden in a refactor commit means the refactor changed what the Mac draws.
