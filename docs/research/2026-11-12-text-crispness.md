# Text crispness: why tkzmux looks softer than iTerm2

Research note, 2026-11-12. tkzmux at `92e8cc6`. Sources pinned to iTerm2
[`2a8d67e`](https://github.com/gnachman/iTerm2/tree/2a8d67e06111e8246c6af16d87546060b572fb21)
(GPL, read only for understanding; no code copied) and Ghostty
[`72ac7dc`](https://github.com/ghostty-org/ghostty/tree/72ac7dced84e96a5d5214d005d59eadd10da27bb) (MIT).

Below, "IT" means iTerm2 and "GH" means Ghostty.

## TL;DR

The GPU half of the pipeline is pixel-exact. Glyphs are drawn at device resolution, at integer
pixel positions, with nearest sampling and no resampling anywhere. The blending also matches
CoreText's own output to within 1 %. The softness comes from **what** gets rasterized, not from
how it is drawn:

1. **Stem darkening is on at full strength, and iTerm2 turns it off on Retina.** tkzmux draws every
   grayscale glyph with CoreText font smoothing (`thicken: true`) and a white fill, which is the
   strongest setting. That adds +31 % ink to JetBrains Mono at 14 pt @2x and dilates every edge by
   up to 1 px. iTerm2's default profile uses "thin strokes" on Retina, which turns smoothing off.
   The result is heavier, bloomier strokes with closed-up counters, which is the classic "macOS font
   smoothing looks blurry" effect. **Fix:** set `thicken: false` in
   `Sources/TkzCore/Theme.swift:181` to A/B it. The durable fix is iTerm2's rule: no smoothing at
   backing scale ≥ 2 and smoothing at 1x. Optionally turn the Bool into a strength (the fill gray at
   `Sources/TkzTerminalRender/GlyphRasterizer.swift:158`) the way GH's `font-thicken-strength`
   works.
2. **The font is different: JetBrains Mono 14 pt vs. Monaco 12 pt.** This machine's iTerm2 profile
   uses `Normal Font = "Monaco 12"`, which is also iTerm2's shipped default. tkzmux hard-codes
   JetBrains Mono 14 (`Sources/TkzCore/Theme.swift:175-178`) with no setting to change it.
   JetBrains Mono at 14 pt is a larger and heavier face. Combined with (1), it puts 71 % more ink on
   screen than iTerm2 does for the same text (measured below). **Fix:** make the terminal family and
   size configurable (`Theme.Fonts.Mono`, consumed at
   `Sources/TkzTerminalView/TkzTerminalView.swift:81-86`). Then compare the two apps with the same
   font and size before tuning anything else.
3. **Unfocused panes are drawn at 85 % opacity.** `content.alphaValue = 0.85`
   (`Sources/TkzApp/Panes/PaneChromeView.swift:104`, `PaneHeaderModels.swift:23`) blends every
   non-focused pane's text into the chrome behind it. This lowers contrast, which reads as softer.
   It only applies when a tab has splits. **Fix:** dim with a theme colour or a shader uniform,
   or drop the dimming.

One more cause applies to both apps: this Mac's built-in panel runs a **scaled** mode. AppKit
reports 1800×1169 pt @2x (a 3600×2338 framebuffer), and the panel is 3024×1964, so the
WindowServer downsamples every app by 0.84. That limits how crisp any app can look. It is not why
tkzmux looks worse than iTerm2, but it magnifies weight differences. The "Default" setting
(1512×982 pt) gives exact 2:1 pixels. This was measured on this machine; see *Environment*.

## Environment (measured on this machine)

| Fact | Value | How |
|---|---|---|
| tkzmux window | `windowFrame` 1800×1031 at (0, 99) | `~/Library/Application Support/tkzmux/state.json` |
| Screen hosting it | Built-in, frame 1800×1169 pt, `backingScaleFactor` 2.0 | `NSScreen.screens` probe |
| Built-in panel | 3024×1964 native ("Liquid Retina XDR") | `system_profiler SPDisplaysDataType` |
| → WindowServer scale | 3024 / 3600 = **0.84** (downsampled, all apps) | derived |
| External | Samsung C43J89x, 3840×1200 @1x, ~93 ppi; not hosting tkzmux right now | both of the above |
| `AppleFontSmoothing` | not set (system default) | `defaults read -g` |
| Appearance | Dark | `defaults read -g AppleInterfaceStyle` |
| iTerm2 profile | Monaco 12, ASCII/non-ASCII anti-aliased, `Thin Strokes` unset → default; dark colours fg ≈ #dcdcdc on bg ≈ #151920 | `defaults read com.googlecode.iterm2 "New Bookmarks"` |
| tkzmux theme | `midnightIndigo`: fg #d6dbf0 on bg #171a2b, min contrast 1 | `state.json` → `Theme.swift:228-287` |

The colours are almost identical in the two apps, so contrast does not explain the difference.

## Detailed findings, tkzmux end to end

### 1. Font family and size

- The default face is the bundled JetBrains Mono, registered per process
  (`Sources/TkzTerminalRender/FontSet.swift:106-142`, files in `Resources/Fonts/`). The fallbacks
  are Menlo and then the system monospaced face (`FontSet.swift:193-201`).
- The production size is 14 pt with thicken on (`Theme.swift:173-182`). The comment records why:
  12.5 pt "read visibly lighter" than cmux/Ghostty (`Theme.swift:163-169`). So the defaults were
  tuned to match **Ghostty with `font-thicken`**, not iTerm2.
- `FontSet.init` defaults to 12.5 pt (`FontSet.swift:151-154`), but production always passes
  the theme value (`TkzTerminalView.swift:81-86`).
- Nothing lets the user change the family or size.

### 2. Backing scale, drawable size and layer (verified correct)

- `CAMetalLayer` settings (`Sources/TkzTerminalView/TerminalMetalView.swift:162-178`):
  `.bgra8Unorm`, `framebufferOnly`, `isOpaque = true`, and `contentsScale` set from the window's
  `backingScaleFactor`. No transform, no `magnificationFilter`, no `colorspace`.
- `drawableSize = floor(bounds × backingScale)` (`TerminalMetalView.swift:289-302`). It is updated
  in `setFrameSize` (`:362-364`) and on scale change (`:489-511`). The window move also calls
  `applyBackingScale` (`:550`).
- A scale change rebuilds the font set, atlas and renderer at the new scale
  (`TkzTerminalView.swift:122-140`), so a 1x display gets glyphs rasterized at 1x and not at 2x.
- `drawableSize` matches `bounds × contentsScale` exactly only when the view is pixel-aligned. That
  is the default behaviour per Apple ([`drawableSize`][apple-drawablesize]). If it did not match,
  Core Animation would stretch the texture, because `contentsGravity` defaults to resize
  ([`contentsGravity`][apple-gravity]). **I checked whether that happens here, and it does not:**
  - The stored sidebar width is **313.5 pt** (`state.json` → `sidebar.width`). On the @2x screen
    that is 627 px, which is integral. I reproduced the layout with an `NSSplitViewController`
    configured like `MainWindowController.swift:684-709`. On the 1x external screen AppKit
    snapped the sidebar to 314 pt and the detail column to an integer. `NSSplitView.setPosition`
    with fractional values (333.3, 400.25, 617.777) also snapped to device pixels at @2x
    (333.5 / 400.5 / 618.0).
  - The pane split ratios (`state.json`: 0.6756…, 0.5680…) go through `setPosition`
    (`Sources/TkzApp/Panes/PaneContainerView.swift:322`), so they are aligned the same way.
  - The pane content inset is an integer number of points
    (`Sources/TkzApp/Panes/PaneChromeView.swift:114-126`).
  - **Remaining risk (low):** manually set frames are *not* rounded by AppKit. In the probe, a
    child frame with height 100.3 stayed 100.3. Any future non-integer inset would bring back a
    stretch over the whole surface. A one-line debug assertion that
    `bounds × scale` is integral in `updateDrawableSize` would catch it.
- Transient only: during a live resize the previous drawable is stretched until the next frame
  arrives. GH avoids that with `contentsGravity = topLeft` ([IOSurfaceLayer.zig:32-34][gh-iosl]).

### 3. Glyph rasterization (`Sources/TkzTerminalRender/GlyphRasterizer.swift`)

- Fonts are built at `pointSize × scale` and drawn 1:1 into the bitmap (`FontSet.swift:157-160`).
- Context (`GlyphRasterizer.swift:131-149`): an 8-bit **alpha-only** context for text and
  premultiplied BGRA for colour glyphs. Anti-aliasing is on, `setShouldSmoothFonts(thicken)`,
  subpixel positioning is on and subpixel quantization is off. These are the same settings GH uses
  ([coretext.zig:478-498][gh-ct-ctx]).
- The fill is **white** (`GlyphRasterizer.swift:158-162`). In an alpha-only context the fill gray
  sets the *strength* of CoreText's smoothing dilation. GH uses this as its
  `font-thicken-strength` knob ([coretext.zig:500-508][gh-ct-ctx], [Config.zig:343-355][gh-cfg-thicken]).
  Measured below: white gives the strongest dilation.
- The header comment claims "about 17 % more coverage at 12.5 pt"
  (`GlyphRasterizer.swift:10-14`). At today's 14 pt with a white fill I measured **+31 %**. +17 %
  is what the *lightest* strength (fill gray ≤ 0.25) gives. The comment is stale.
- The padding grows by 1 px when thicken is on, to hold the dilation (`GlyphRasterizer.swift:58-62`).
  The code itself acknowledges that smoothing spreads ink past the outline.

### 4. Glyph placement (verified pixel-exact)

- Cell metrics are integers: width is `ceil(max ASCII advance)` and height and baseline are rounded
  (`Sources/TkzTerminalRender/CellMetrics.swift:49-60`). For JetBrains Mono 14 @2x the advance is
  16.8 px, which becomes a 17 px cell. That adds 0.2 px of tracking per cell, which changes spacing
  but does not blur.
- Bitmap bounds are floored and ceiled to integers, and the pen origin is at integer (0, 0) in the
  bitmap (`GlyphRasterizer.swift:94-101, 151-152`).
- Instance offsets are `Int16` (`bearingX`, `baseline − bearingTop`), and sizes and atlas
  positions are `UInt16` (`FrameBuilder.swift:442-447`). The grid origin is always `.zero`
  (`TerminalRenderer.swift:296`, `TerminalSurface.swift:500-506`). The vertex shader adds integer
  pixels only (`Resources/Shaders/Terminal.metal:316-318`), so every quad lands on whole device
  pixels.
- GH, by contrast, centres glyphs in the cell and keeps the fractional part as a subpixel offset
  ([coretext.zig:363-409][gh-ct-place]). tkzmux's left-aligned integer placement is, if anything,
  crisper.

### 5. Atlas sampling (verified pixel-exact)

- `coord::pixel`, `filter::nearest`, `clamp_to_edge` (`Terminal.metal:327-330`), no mipmaps
  (`GlyphAtlas.swift:95`), and the atlas is `r8Unorm` / `bgra8Unorm` (`GlyphAtlas.swift:24`).
  With integer quads and integer atlas positions, every texel maps to exactly one pixel. This is
  the same sampler GH uses ([shaders.metal:684-688][gh-shader-text]).

### 6. Pixel format, blending, gamma (verified equivalent to CoreText-native)

- The drawable is `.bgra8Unorm`, not `_srgb` (`TerminalRenderer.swift:182`,
  `TerminalMetalView.swift:166`). Blending is premultiplied `one / oneMinusSourceAlpha` in gamma
  (sRGB-encoded) space (`TerminalRenderer.swift:184-192`, `Terminal.metal:339-342`). That is GH's
  macOS default, `alpha-blending = native` ([Config.zig:384-412][gh-cfg-blend]), and IT does the
  same in its monochrome path ([iTermText.metal:312-322][it-shader-mono]).
- **Measured:** I rendered the same line two ways. (A) is tkzmux's way: an alpha mask, then
  fg-over-bg blended in sRGB. (B) is CoreText drawing straight into an opaque sRGB context filled
  with the background, which is what a CoreText-native renderer gets. Results:
  - At @2x the two agree to within **1 %** in every pixel, with or without smoothing.
  - At 1x with smoothing on, a few edge pixels differ by up to 9 % (350 of ~2 200 ink pixels).
    tkzmux is slightly *heavier* there, not softer.
  - Blending and gamma are **not** the cause.
- `layer.colorspace` is never set, so it stays `nil`. Apple: "the rendered content isn't
  color-matched" ([`colorspace`][apple-colorspace]). On the P3 built-in panel, sRGB theme values
  are therefore shown as P3 primaries and look slightly over-saturated. That is a colour-accuracy
  issue, not a sharpness one. IT sets the layer to the screen's colour space
  ([iTermMTKView.swift:137-147][it-mtk-cs]), and GH tags its surface Display P3
  ([Target.zig:45-59][gh-target]). The comment "opaque sRGB layer" at `Terminal.metal:5` does not
  match the code.

### 7. Compositing above the layer

- Unfocused panes are drawn at 85 % opacity (`PaneChromeView.swift:104`, `PaneHeaderModels.swift:23`).
  This is the only thing between the drawable and the screen that changes pixel values.
- The scaled display mode applies to all apps (see *Environment*).

## Measurements

These are throwaway Swift scripts using the same CGContext settings as
`GlyphRasterizer.swift:131-171`, with the sample line
`The quick brown fox jumps; ls -la ~/dev | grep rs_1il0O`, integer pens and tkzmux's cell metrics.
They are not committed. To reproduce, set `thicken` and run `tkzmux-vtdump atlas --thicken 0|1`
for the atlas side.

**Smoothing strength vs. fill gray** (JetBrains Mono, 28 px = 14 pt @2x, total coverage):

| Smoothing | Fill gray | Coverage | vs. off |
|---|---|---|---|
| off | — | 3909 | — |
| on | 0.00–0.25 | 4561 | +17 % |
| on | 0.50 | 4841 | +24 % |
| on | 0.75–1.00 (tkzmux uses 1.0) | 5109 | **+31 %** |

**What each app actually puts on screen** (@2x, total ink over the sample line):

| Configuration | Ink | Relative |
|---|---|---|
| iTerm2 default on Retina: Monaco 12, smoothing off (thin strokes) | 2994 | 1.00 |
| Monaco 12, smoothing on | 4047 | 1.35 |
| JetBrains Mono 14, smoothing off | 3910 | 1.31 |
| **tkzmux today: JetBrains Mono 14, smoothing on, white fill** | **5110** | **1.71** |

At 1x (the external screen) IT also smooths, because thin strokes are "Retina only". There the two
apps differ only by font: JBM 14 at 30.9 ink/glyph vs. Monaco 12 at 23.5.

## Comparison table

| Setting | tkzmux | iTerm2 (default profile) | Ghostty (defaults) |
|---|---|---|---|
| Default font | JetBrains Mono 14 pt, bundled (`Theme.swift:175-178`) | Monaco 12 ([DefaultBookmark.plist:1077-1078][it-plist]) | 13 pt on macOS, family from system ([Config.zig:271-276][gh-cfg-size]) |
| Font smoothing / stem darkening | **On, always** (`Theme.swift:181`, `GlyphRasterizer.swift:143-145`) | Thin strokes = Retina-only by default ([iTermProfilePreferences.m:1134][it-prefs]), resolved as `_isRetina` ([iTermTextDrawingHelper.m:3104-3105][it-tdh]); thin strokes ⇒ `shouldSmooth = NO` ([iTermCharacterSource.m:683-716][it-cs-smooth]) ⇒ **off on Retina, on at 1x** | `font-thicken = false` ([Config.zig:345][gh-cfg-thicken]) ⇒ **off** |
| Smoothing strength | Max (white fill, `GlyphRasterizer.swift:158`) | Smoothing style via private `CGContextSetFontSmoothingStyle` (16 = lighter with thin strokes; 0 otherwise) ([iTermCharacterSource.m:34, 699-712][it-cs-smooth]); mask taken from a black/red/green/white render picked by text colour ([iTermCharacterSource.m:749-763][it-cs-iter], [iTermText.metal:4-23][it-shader-alpha]) | `font-thicken-strength` 0–255 = fill gray ([coretext.zig:500-508][gh-ct-ctx], [Config.zig:347-355][gh-cfg-thicken]) |
| Rasterize at | pt × backing scale (`FontSet.swift:157-160`) | pt × scale (descriptor scale, [iTermCharacterSource.m:790-794][it-cs-iter]) | pt × scale |
| Subpixel positioning / quantization | on / off (`GlyphRasterizer.swift:146-149`) | not traced (unverified) | on / off ([coretext.zig:485-494][gh-ct-ctx]) |
| Grayscale atlas | `r8Unorm`, alpha-only CG context | RGBA, 4 renders packed into channels ([iTermCharacterSource.m:946-976][it-cs-post]) | `r8Unorm`, alpha-only, `linearGray` space ([coretext.zig:415-430][gh-ct-ctx]) |
| Glyph x placement | integer, left-aligned in cell | not traced (unverified) | centred, fractional subpixel offset ([coretext.zig:363-409][gh-ct-place]) |
| Sampler | nearest, `coord::pixel` (`Terminal.metal:330`) | linear, normalized ([iTermText.metal:316-317][it-shader-mono]) | nearest, `coord::pixel` ([shaders.metal:684-688][gh-shader-text]) |
| Drawable format | `bgra8Unorm` | not traced (unverified; fp16 only with HDR cursor, [SessionView.m:1032-1040][it-sv]) | `bgra8Unorm` for `native`, `_srgb` for linear ([Metal.zig:186-196][gh-metal]) |
| Blend space | gamma (native) | gamma (monochrome path, [iTermText.metal:312-322][it-shader-mono]) | `native` on macOS ([Config.zig:384-412][gh-cfg-blend]) |
| Layer colour space | `nil` (unmatched) | screen's colour space ([iTermMTKView.swift:137-147][it-mtk-cs]) | Display P3 ([Target.zig:45-59][gh-target]) |
| `contentsScale` | window `backingScaleFactor` (`TerminalMetalView.swift:175, 499`) | (MTKView-managed, not traced) | window scale factor ([Metal.zig:122-126][gh-metal]) |
| `contentsGravity` | default (resize) | not traced | `topLeft` ([IOSurfaceLayer.zig:32-34][gh-iosl]) |

## Recommendations (ranked)

1. **Make thicken depend on the backing scale, and A/B it first.**
   - Quick test: `thicken: false` at `Sources/TkzCore/Theme.swift:181`. The only consumers are
     `TkzTerminalView.swift:77,129` and `TerminalRenderer.swift:108`.
   - Durable version, following iTerm2's default: pass the scale into the decision. Disable
     smoothing when `fontSet.scale >= 2` and keep it at 1x, where it helps legibility. This goes at
     `GlyphRasterizer.swift:143` (the `smooth` local) or wherever `GlyphCache` is built in
     `TerminalRenderContext.setScale`.
   - Optional: replace `thicken: Bool` with a strength in 0…1 and use it as the gray at
     `GlyphRasterizer.swift:158`. Measured steps: ≤0.25 → +17 %, 0.5 → +24 %, ≥0.75 → +31 %. Fix
     the stale "17 %" comment while there.
   - Cost: goldens that pin glyph coverage will need regenerating.
2. **Make the terminal font family and size settings.** Expose `Theme.Fonts.Mono.family` and
   `.terminal` (`Theme.swift:159-182`) through Preferences, with `reattachAll` on change (the hook
   already exists at `TkzTerminalView.swift:142-148`). Then compare against iTerm2 with the same
   font: Monaco 12, SF Mono 13, Menlo 13. Without this, every comparison mixes the font with the
   renderer. The current 14 pt + thicken was chosen to match cmux/Ghostty (`Theme.swift:163-169`),
   so pick a reference app deliberately.
3. **Stop dimming inactive panes with layer opacity** (`PaneChromeView.swift:104`). If the cue
   is wanted, darken the theme foreground through a uniform, or draw a translucent overlay that
   leaves glyph edges at full contrast.
4. **Guard pixel alignment** with a debug-only check in `updateDrawableSize`
   (`TerminalMetalView.swift:296-302`): assert or log when `bounds.width * scale` is non-integral.
   This is cheap insurance against a future fractional inset silently stretching the whole surface.
   Consider `contentsGravity = .topLeft` (as GH does) so live-resize frames are never stretched.
   With `isFlipped` views, check which corner is correct.
5. **Set `layer.colorspace`** to sRGB (the theme colours are sRGB). This is for colour accuracy on
   the P3 panel, not crispness. Also fix the "opaque sRGB layer" comment at `Terminal.metal:5`.
6. **User-side, applies to every app:** System Settings → Displays → built-in → "Default"
   (1512×982) instead of the current 1800×1169 "More Space". That removes the 0.84 WindowServer
   downsample.

Not recommended: switching to linear blending or `_srgb` formats. The measurements show the
current gamma-space blend already matches CoreText's native output. Linear blending makes light
text on dark backgrounds thicker (GH's docs, [Config.zig:384-412][gh-cfg-blend]), which is the wrong
direction here.

## Unverified / open

- iTerm2's drawable pixel format, glyph x-placement and subpixel-positioning flags were not traced.
- Whether iTerm2 is actually using its Metal renderer on this machine was not checked. It falls
  back to the legacy CoreGraphics renderer in some conditions. Either path applies the same
  thin-strokes rule ([iTermGraphicsUtilities.m:22-50][it-gu]).
- Whether a global `AppleFontSmoothing = 0` would also suppress smoothing in tkzmux's explicit
  `setShouldSmoothFonts(true)` context was not tested. The key is unset on this machine.
- The perception claim (heavier dilated strokes read as "blurry") is the conventional explanation
  and is consistent with iTerm2's own comment that thin strokes look "nicer"
  ([iTermCharacterSource.m:699-705][it-cs-smooth]). It was not checked with a side-by-side
  screenshot of the two running apps. The toggle in recommendation 1 is the cheap way to confirm.

## Sources

tkzmux: file:line references above, at `92e8cc6`.

Apple:
- [apple-drawablesize]: https://developer.apple.com/documentation/quartzcore/cametallayer/drawablesize
- [apple-colorspace]: https://developer.apple.com/documentation/quartzcore/cametallayer/colorspace
- [apple-gravity]: https://developer.apple.com/documentation/quartzcore/calayer/contentsgravity
- `CGContext.setShouldSmoothFonts(_:)`: https://developer.apple.com/documentation/coregraphics/cgcontext/setshouldsmoothfonts(_:)

Ghostty @ `72ac7dc`:
- [gh-ct-place]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/font/face/coretext.zig#L363-L409
- [gh-ct-ctx]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/font/face/coretext.zig#L415-L508
- [gh-cfg-size]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/config/Config.zig#L271-L276
- [gh-cfg-thicken]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/config/Config.zig#L343-L355
- [gh-cfg-blend]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/config/Config.zig#L384-L412
- [gh-metal]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/renderer/Metal.zig#L122-L196
- [gh-iosl]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/renderer/metal/IOSurfaceLayer.zig#L32-L34
- [gh-target]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/renderer/metal/Target.zig#L45-L59
- [gh-shader-text]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/renderer/shaders/shaders.metal#L678-L740
- Thicken-strength discussion (TextEdit used as the reference): https://github.com/ghostty-org/ghostty/discussions/3492
- Downscaling as a blur source (Linux context): https://mitchellh.com/writing/ghostty-devlog-002

iTerm2 @ `2a8d67e` (GPL; read for understanding only):
- [it-cs-smooth]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/MetalRenderer/Glue/iTermCharacterSource.m#L683-L716 (private `CGContextSetFontSmoothingStyle` declared at L34)
- [it-cs-iter]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/MetalRenderer/Glue/iTermCharacterSource.m#L727-L794
- [it-cs-post]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/MetalRenderer/Glue/iTermCharacterSource.m#L946-L976
- `iTermTextIsMonochrome()` is always YES: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/Hacks/FutureMethods.h#L48-L55
- [it-shader-alpha]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/MetalRenderer/Shaders/iTermText.metal#L4-L23
- [it-shader-mono]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/MetalRenderer/Shaders/iTermText.metal#L307-L322
- [it-prefs]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/Settings/iTermProfilePreferences.m#L1134
- Thin-strokes enum: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/Settings/Profiles/ITAddressBookMgr.h#L493-L499
- [it-tdh]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/Drawing/iTermTextDrawingHelper.m#L3104-L3105
- [it-gu]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/Drawing/iTermGraphicsUtilities.m#L22-L50
- [it-plist]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/plists/DefaultBookmark.plist#L1077-L1078
- [it-mtk-cs]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/TerminalView/iTermMTKView.swift#L137-L147
- [it-sv]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/TerminalView/SessionView.m#L1032-L1040

[apple-drawablesize]: https://developer.apple.com/documentation/quartzcore/cametallayer/drawablesize
[apple-colorspace]: https://developer.apple.com/documentation/quartzcore/cametallayer/colorspace
[apple-gravity]: https://developer.apple.com/documentation/quartzcore/calayer/contentsgravity
[gh-ct-place]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/font/face/coretext.zig#L363-L409
[gh-ct-ctx]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/font/face/coretext.zig#L415-L508
[gh-cfg-size]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/config/Config.zig#L271-L276
[gh-cfg-thicken]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/config/Config.zig#L343-L355
[gh-cfg-blend]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/config/Config.zig#L384-L412
[gh-metal]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/renderer/Metal.zig#L122-L196
[gh-iosl]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/renderer/metal/IOSurfaceLayer.zig#L32-L34
[gh-target]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/renderer/metal/Target.zig#L45-L59
[gh-shader-text]: https://github.com/ghostty-org/ghostty/blob/72ac7dced84e96a5d5214d005d59eadd10da27bb/src/renderer/shaders/shaders.metal#L678-L740
[it-cs-smooth]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/MetalRenderer/Glue/iTermCharacterSource.m#L683-L716
[it-cs-iter]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/MetalRenderer/Glue/iTermCharacterSource.m#L727-L794
[it-cs-post]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/MetalRenderer/Glue/iTermCharacterSource.m#L946-L976
[it-shader-alpha]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/MetalRenderer/Shaders/iTermText.metal#L4-L23
[it-shader-mono]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/MetalRenderer/Shaders/iTermText.metal#L307-L322
[it-prefs]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/Settings/iTermProfilePreferences.m#L1134
[it-tdh]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/Drawing/iTermTextDrawingHelper.m#L3104-L3105
[it-gu]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/Drawing/iTermGraphicsUtilities.m#L22-L50
[it-plist]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/plists/DefaultBookmark.plist#L1077-L1078
[it-mtk-cs]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/TerminalView/iTermMTKView.swift#L137-L147
[it-sv]: https://github.com/gnachman/iTerm2/blob/2a8d67e06111e8246c6af16d87546060b572fb21/sources/TerminalView/SessionView.m#L1032-L1040
