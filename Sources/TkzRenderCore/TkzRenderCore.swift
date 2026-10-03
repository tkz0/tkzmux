// TkzRenderCore — the device-free half of the terminal renderer, built on macOS and Linux.
//
// Everything here works in pixels and bytes, never in a GPU, font or image API: the Metal renderer
// (TkzTerminalRender) and the Vulkan renderer (WOR-313) both sit on top of it, and the shader
// contract both of them upload is TkzShaderTypes.h. No CoreText, CoreGraphics, Metal, ImageIO,
// AppKit or Darwin import belongs in this module; `docs/linux/` and the WOR-311 acceptance grep
// check that.
//
// WOR-311 fills it in:
//   S2  `FontFace`/`GlyphID`/`GlyphSource` (GlyphSource.swift) and the CellMetrics formulas, from
//       pixel values or raw font tables (CellMetrics.swift, FontTables.swift)
//   S3  the glyph-atlas packer (staging buffer, dirty bbox, grow generation) and `GlyphCache`
//       over `any GlyphSource` (GlyphAtlas.swift, GlyphCache.swift), and which scalars are box
//       sprites (BoxSpriteGeometry.swift)
//   S4  `TerminalSurface` and `FrameBuilder`: libghostty's render state → instance buffers. They
//       read the terminal through TkzTerminalCore and hold a renderer's GPU state only as an
//       opaque `SurfaceRenderResources` (TerminalSurface.swift, FrameBuilder.swift)
//   S5  the box-sprite geometry and the pure-Swift box-sprite rasterizer
