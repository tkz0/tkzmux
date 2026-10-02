// tkz_glyph_fragment — port of Terminal.metal's glyph fragment function. One pipeline for both
// atlases, branching on TKZ_GLYPH_FLAG_COLOR (uniform within a quad). Output is premultiplied
// (blend ONE / ONE_MINUS_SRC_ALPHA for colour and alpha).
#version 450
#extension GL_EXT_samplerless_texture_functions : require

#include "TkzShaderTypes.glsl"
#include "TkzCommon.glsl"

/// `R8_UNORM` coverage atlas. Red channel = alpha mask.
layout(set = TKZ_DESCRIPTOR_SET_ATLASES, binding = TKZ_TEXTURE_INDEX_GRAYSCALE)
uniform texture2D grayscaleAtlas;
/// `B8G8R8A8_UNORM` colour atlas (emoji, colour fonts), already premultiplied. Reads come back as
/// RGBA, like Metal's `bgra8Unorm`.
layout(set = TKZ_DESCRIPTOR_SET_ATLASES, binding = TKZ_TEXTURE_INDEX_COLOR)
uniform texture2D colorAtlas;

layout(location = 0) in vec2 atlasPx;
layout(location = 1) flat in vec4 color;
layout(location = 2) flat in uint flags;

layout(location = 0) out vec4 outColor;

/// Metal's `sampler(coord::pixel, filter::nearest, address::clamp_to_edge)`: nearest in texel
/// coordinates is the texel containing the point, and the clamp keeps a rounding error on the last
/// texel from reading outside the atlas (an out-of-range `texelFetch` is undefined).
ivec2 tkz_atlas_texel(vec2 px, ivec2 atlasSize) {
    return clamp(ivec2(floor(px)), ivec2(0), atlasSize - 1);
}

void main() {
    if ((flags & TKZ_GLYPH_FLAG_COLOR) != 0u) {
        // `color.a` is the only part of the instance colour that applies — scaling a premultiplied
        // colour by a scalar keeps it premultiplied.
        ivec2 texel = tkz_atlas_texel(atlasPx, textureSize(colorAtlas, 0));
        outColor = texelFetch(colorAtlas, texel, 0) * color.a;
        return;
    }

    // R8 coverage: the red channel is the glyph's alpha mask. Straight colour × mask, then
    // premultiplied in one step — `vec4(rgb * a, a)` with `a = color.a * mask`.
    ivec2 texel = tkz_atlas_texel(atlasPx, textureSize(grayscaleAtlas, 0));
    float alpha = color.a * texelFetch(grayscaleAtlas, texel, 0).r;
    outColor = vec4(color.rgb * alpha, alpha);
}
