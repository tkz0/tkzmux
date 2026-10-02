// TkzRenderCore — the device-free half of the terminal renderer, built on macOS and Linux.
//
// Everything here works in pixels and bytes, never in a GPU, font or image API: the Metal renderer
// (TkzTerminalRender) and the Vulkan renderer (WOR-313) both sit on top of it, and the shader
// contract both of them upload is TkzShaderTypes.h. No CoreText, CoreGraphics, Metal, ImageIO,
// AppKit or Darwin import belongs in this module; `docs/linux/` and the WOR-311 acceptance grep
// check that.
//
// WOR-311 fills it in:
//   S2  `FontFace`/`GlyphID`/`GlyphSource` and the CellMetrics formulas over raw font tables
//   S3  the glyph-atlas packer (staging buffer, dirty bbox, grow generation) and `GlyphCache`
//   S4  `FrameBuilder` and `TerminalSurface`
//   S5  the box-sprite geometry and the pure-Swift box-sprite rasterizer
// Until then the target only pins the shader layout through its test target.
