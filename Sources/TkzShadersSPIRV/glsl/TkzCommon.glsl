// TkzCommon.glsl — the shared helpers of Terminal.metal ("MARK: - Shared helpers"), ported to
// GLSL 4.50. Included by every stage after TkzShaderTypes.glsl. Keep each function a line-for-line
// port of its Metal twin: L3 conformance (WOR-313 S3) compares the two pipelines byte for byte
// within ±1, so "equivalent" rewrites are not free.

#ifndef TKZ_COMMON_GLSL
#define TKZ_COMMON_GLSL

/// Unpack a `TkzShaderTypes` colour: R in the low byte, then G, B, A. Straight (non-premultiplied)
/// sRGB-encoded, 0…1 on return.
vec4 tkz_unpack_rgba(uint v) {
    return vec4(float( v         & 0xFFu),
                float((v >>  8u) & 0xFFu),
                float((v >> 16u) & 0xFFu),
                float((v >> 24u) & 0xFFu)) * (1.0 / 255.0);
}

/// Straight alpha → premultiplied, for `ONE` / `ONE_MINUS_SRC_ALPHA` blending.
vec4 tkz_premultiply(vec4 c) {
    return vec4(c.rgb * c.a, c.a);
}

/// `src` over an *opaque* `dst`, both straight-alpha. Result is opaque.
vec4 tkz_over_opaque(vec4 src, vec4 dst) {
    return vec4(mix(dst.rgb, src.rgb, src.a), 1.0);
}

/// Pixel space (origin top-left, +y down) → clip space. Vulkan's clip space is already +y down,
/// so unlike the Metal version there is no `1 - n.y` flip.
vec4 tkz_pixel_to_clip(vec2 px, vec2 viewportPx) {
    vec2 n = px / viewportPx;
    return vec4(n * 2.0 - 1.0, 0.0, 1.0);
}

/// Unit-quad corner for a 4-vertex triangle strip: (0,0) (1,0) (0,1) (1,1).
vec2 tkz_quad_corner(uint vid) {
    return vec2(float(vid & 1u), float((vid >> 1u) & 1u));
}

#endif // TKZ_COMMON_GLSL
