// TkzShaderTypes.glsl — the GLSL 4.50 mirror of Sources/TkzShaderTypes/include/TkzShaderTypes.h
// for the Vulkan port of Terminal.metal (WOR-313). The C header stays the contract: field
// meanings, units, flag bits and the byte layout are documented there and only there. This file
// repeats the numbers in a form glslc can read, and says how each Metal binding maps to Vulkan.
//
// EDITING THIS FILE? It must keep matching the C header. `TkzShadersSPIRVTests` checks it three
// ways, so a divergence is a test failure, never a corrupt frame:
//   - every `#define` below that also exists in the C header has the C value;
//   - the push-constant and SSBO member offsets in the committed SPIR-V (`OpMemberDecorate
//     Offset`) equal `MemoryLayout.offset(of:)` on the C structs;
//   - every `TKZ_GLYPH_OFFSET_*` equals the matching `MemoryLayout<TkzGlyphInstance>` offset.
// Then run scripts/build-shaders-linux.sh to regenerate the committed SPIR-V.
//
// Binding contract (Metal → Vulkan)
// - `TKZ_BUFFER_INDEX_UNIFORMS` → push constants. The whole 80-byte `TkzUniforms`, one range at
//   offset 0 that covers the vertex and fragment stages.
// - `TKZ_BUFFER_INDEX_INSTANCES` → a read-only std430 storage buffer at
//   (set `TKZ_DESCRIPTOR_SET_INSTANCES`, binding `TKZ_BUFFER_INDEX_INSTANCES`). Every pipeline is
//   vertex-input-free: no `VkVertexInputBindingDescription`, quads come from `gl_VertexIndex` and
//   `gl_InstanceIndex`, exactly like the Metal pipelines' nil vertex descriptor.
// - `TKZ_TEXTURE_INDEX_*` → sampled images (no sampler) at (set `TKZ_DESCRIPTOR_SET_ATLASES`,
//   binding `TKZ_TEXTURE_INDEX_*`), read with `texelFetch` via
//   GL_EXT_samplerless_texture_functions. Both atlases are always bound for the glyph pipeline,
//   as on Metal.
// - Entry points are all `main`; one SPIR-V module per Metal function, named after it
//   (`tkz_bg_vertex.vert.glsl` ↔ `TKZ_FN_BG_VERTEX`).
//
// Coordinate conventions: as in the C header (pixel space origin top-left, +y down). Vulkan's
// clip space already has +y down and `gl_FragCoord` is top-left with pixel centres at .5, so the
// Metal y-flip in `tkz_pixel_to_clip` is gone and nothing else changes.

#ifndef TKZ_SHADER_TYPES_GLSL
#define TKZ_SHADER_TYPES_GLSL

#define TKZ_SHADER_TYPES_VERSION 1

// MARK: - Binding contract

#define TKZ_BUFFER_INDEX_UNIFORMS 0
#define TKZ_BUFFER_INDEX_INSTANCES 1

#define TKZ_TEXTURE_INDEX_GRAYSCALE 0
#define TKZ_TEXTURE_INDEX_COLOR 1

// Vulkan only: the C header has no descriptor sets. Buffer and texture indices both start at 0
// on Metal, so they live in different sets here rather than being renumbered.
#define TKZ_DESCRIPTOR_SET_INSTANCES 0
#define TKZ_DESCRIPTOR_SET_ATLASES 1

// MARK: - Glyph flags (TKZ_GLYPH_FLAG_*)

#define TKZ_GLYPH_FLAG_COLOR 1u
#define TKZ_GLYPH_FLAG_UNDER_CURSOR 2u
#define TKZ_GLYPH_FLAG_MIN_CONTRAST 4u
#define TKZ_GLYPH_FLAG_WIDE 8u

// MARK: - Rect styles (TKZ_RECT_STYLE_*)

#define TKZ_RECT_STYLE_SOLID 0u
#define TKZ_RECT_STYLE_HOLLOW 1u
#define TKZ_RECT_STYLE_UNDERLINE_SINGLE 2u
#define TKZ_RECT_STYLE_UNDERLINE_DOUBLE 3u
#define TKZ_RECT_STYLE_UNDERLINE_CURLY 4u
#define TKZ_RECT_STYLE_UNDERLINE_DOTTED 5u
#define TKZ_RECT_STYLE_UNDERLINE_DASHED 6u
#define TKZ_RECT_STYLE_STRIKETHROUGH 7u
#define TKZ_RECT_STYLE_COUNT 8u

// MARK: - Uniforms

/// `TkzUniforms`, all 80 bytes, as push constants. std430 gives `vec2`/`uvec2` an 8-byte
/// alignment, which is exactly the C layout; the explicit offsets only make that visible.
layout(push_constant, std430) uniform TkzUniforms {
    layout(offset = 0) vec2 viewportSizePx;
    layout(offset = 8) vec2 cellSizePx;
    layout(offset = 16) vec2 gridOriginPx;
    layout(offset = 24) vec2 grayscaleAtlasSizePx;
    layout(offset = 32) vec2 colorAtlasSizePx;
    layout(offset = 40) uvec2 gridSize;
    layout(offset = 48) uint defaultBackground;
    layout(offset = 52) uint defaultForeground;
    layout(offset = 56) uint cursorColor;
    layout(offset = 60) uint cursorTextColor;
    layout(offset = 64) float minContrast;
    layout(offset = 68) uint reserved0;
    layout(offset = 72) uint reserved1;
    layout(offset = 76) uint reserved2;
} u;

// MARK: - Instances

// `TkzBgCell` is a single packed colour, so the background SSBO is a plain `uint[]`
// (array stride 4); see tkz_bg_fragment.frag.glsl.

/// `TkzRectInstance`: plain std430, same offsets as C (0, 8, 16, 20, 24, 28; size 32, align 8).
struct TkzRectInstance {
    vec2 originPx;
    vec2 sizePx;
    uint color;
    uint style;
    float thicknessPx;
    uint reserved0;
};

/// `TkzGlyphInstance` is mostly 16-bit pairs (`ushort2`/`short2`), which core GLSL cannot declare
/// in a storage buffer without 16-bit storage. It is read as two `uvec4`s (32 bytes, the C size)
/// and unpacked with `bitfieldExtract`; the byte offsets of the C fields are below. Every field
/// is 4-byte aligned, so a field is always one whole 32-bit word: the low half is `.x`, the high
/// half `.y` (little-endian, as on every target tkzmux builds for).
struct TkzGlyphInstance {
    uvec4 words[2];
};

#define TKZ_GLYPH_OFFSET_GRID_POS 0
#define TKZ_GLYPH_OFFSET_OFFSET_PX 4
#define TKZ_GLYPH_OFFSET_SIZE_PX 8
#define TKZ_GLYPH_OFFSET_ATLAS_POS 12
#define TKZ_GLYPH_OFFSET_COLOR 16
#define TKZ_GLYPH_OFFSET_BG_COLOR 20
#define TKZ_GLYPH_OFFSET_FLAGS 24
#define TKZ_GLYPH_OFFSET_RESERVED0 28

/// The 32-bit word at `byteOffset` (a multiple of 4, < 32) of a glyph instance. Callers pass the
/// constants above, so the indexing folds away.
uint tkz_glyph_word(TkzGlyphInstance g, int byteOffset) {
    return g.words[byteOffset >> 4][(byteOffset >> 2) & 3];
}

/// A `vector_ushort2` field.
uvec2 tkz_glyph_ushort2(TkzGlyphInstance g, int byteOffset) {
    uint w = tkz_glyph_word(g, byteOffset);
    return uvec2(bitfieldExtract(w, 0, 16), bitfieldExtract(w, 16, 16));
}

/// A `vector_short2` field: the signed extract sign-extends each half.
ivec2 tkz_glyph_short2(TkzGlyphInstance g, int byteOffset) {
    int w = int(tkz_glyph_word(g, byteOffset));
    return ivec2(bitfieldExtract(w, 0, 16), bitfieldExtract(w, 16, 16));
}

#endif // TKZ_SHADER_TYPES_GLSL
