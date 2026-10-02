// tkz_glyph_vertex — port of Terminal.metal's glyph vertex function. One instanced 4-vertex
// triangle strip per glyph. Colour selection (cursor swap, min contrast) happens here, four
// invocations per glyph instead of a few hundred fragments, and rides along as flat varyings.
#version 450

#include "TkzShaderTypes.glsl"
#include "TkzCommon.glsl"

layout(std430, set = TKZ_DESCRIPTOR_SET_INSTANCES, binding = TKZ_BUFFER_INDEX_INSTANCES)
readonly buffer TkzGlyphInstances {
    TkzGlyphInstance glyphs[];
};

// `TkzGlyphVaryings`; the locations must match tkz_glyph_fragment.frag.glsl.
/// Atlas position in *texels* (both atlases are read with `texelFetch`), so an atlas regrow cannot
/// invalidate instances that were already built against the old dimensions.
layout(location = 0) out vec2 atlasPx;
layout(location = 1) flat out vec4 color;
layout(location = 2) flat out uint flags;

float tkz_srgb_to_linear(float c) {
    return c <= 0.04045 ? c * (1.0 / 12.92) : pow((c + 0.055) * (1.0 / 1.055), 2.4);
}

/// WCAG relative luminance of an sRGB-encoded colour.
float tkz_relative_luminance(vec3 c) {
    vec3 linear = vec3(tkz_srgb_to_linear(c.r),
                       tkz_srgb_to_linear(c.g),
                       tkz_srgb_to_linear(c.b));
    return dot(linear, vec3(0.2126, 0.7152, 0.0722));
}

float tkz_contrast_ratio(float lumA, float lumB) {
    return (max(lumA, lumB) + 0.05) / (min(lumA, lumB) + 0.05);
}

float tkz_linear_to_srgb(float c) {
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

/// If `fg` on `bg` is below `minRatio`, move it toward black or white — whichever has more
/// contrast against `bg` — just far enough to reach `minRatio`, mixing in linear light so the hue
/// survives. See the Metal twin for the full rationale.
vec3 tkz_min_contrast(vec3 fg, vec3 bg, float minRatio) {
    float bgLuminance = tkz_relative_luminance(bg);
    float fgLuminance = tkz_relative_luminance(fg);
    if (tkz_contrast_ratio(fgLuminance, bgLuminance) >= minRatio) {
        return fg;
    }
    vec3 linear = vec3(tkz_srgb_to_linear(fg.r), tkz_srgb_to_linear(fg.g), tkz_srgb_to_linear(fg.b));
    bool whiteWins = tkz_contrast_ratio(1.0, bgLuminance) > tkz_contrast_ratio(0.0, bgLuminance);
    if (whiteWins) {
        // L' = L + t(1 - L)
        float target = min(minRatio * (bgLuminance + 0.05) - 0.05, 1.0);
        float t = fgLuminance < 1.0 ? clamp((target - fgLuminance) / (1.0 - fgLuminance), 0.0, 1.0) : 0.0;
        linear = mix(linear, vec3(1.0), t);
    } else {
        // L' = L * s
        float target = max((bgLuminance + 0.05) / minRatio - 0.05, 0.0);
        float s = fgLuminance > 0.0 ? clamp(target / fgLuminance, 0.0, 1.0) : 0.0;
        linear *= s;
    }
    return vec3(tkz_linear_to_srgb(linear.r), tkz_linear_to_srgb(linear.g), tkz_linear_to_srgb(linear.b));
}

void main() {
    TkzGlyphInstance g = glyphs[gl_InstanceIndex];
    uvec2 gridPos = tkz_glyph_ushort2(g, TKZ_GLYPH_OFFSET_GRID_POS);
    ivec2 offsetPx = tkz_glyph_short2(g, TKZ_GLYPH_OFFSET_OFFSET_PX);
    uvec2 glyphSizePx = tkz_glyph_ushort2(g, TKZ_GLYPH_OFFSET_SIZE_PX);
    uvec2 atlasPos = tkz_glyph_ushort2(g, TKZ_GLYPH_OFFSET_ATLAS_POS);
    uint glyphFlags = tkz_glyph_word(g, TKZ_GLYPH_OFFSET_FLAGS);

    vec2 corner = tkz_quad_corner(uint(gl_VertexIndex));
    vec2 glyphSize = vec2(glyphSizePx);
    vec2 cellOriginPx = u.gridOriginPx + vec2(gridPos) * u.cellSizePx;

    vec4 c = tkz_unpack_rgba(tkz_glyph_word(g, TKZ_GLYPH_OFFSET_COLOR));
    if ((glyphFlags & TKZ_GLYPH_FLAG_UNDER_CURSOR) != 0u) {
        // Emoji keep their own colours under the cursor; only monochrome text is swapped.
        if ((glyphFlags & TKZ_GLYPH_FLAG_COLOR) == 0u) {
            c.rgb = tkz_unpack_rgba(u.cursorTextColor).rgb;
        }
    } else if ((glyphFlags & TKZ_GLYPH_FLAG_MIN_CONTRAST) != 0u && u.minContrast > 1.0) {
        vec3 bgColor = tkz_unpack_rgba(tkz_glyph_word(g, TKZ_GLYPH_OFFSET_BG_COLOR)).rgb;
        c.rgb = tkz_min_contrast(c.rgb, bgColor, u.minContrast);
    }

    gl_Position = tkz_pixel_to_clip(cellOriginPx + vec2(offsetPx) + corner * glyphSize,
                                    u.viewportSizePx);
    atlasPx = vec2(atlasPos) + corner * glyphSize;
    color = c;
    flags = glyphFlags;
}
