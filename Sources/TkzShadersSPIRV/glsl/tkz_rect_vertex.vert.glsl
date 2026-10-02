// tkz_rect_vertex — port of Terminal.metal's rect vertex function. One instanced 4-vertex triangle
// strip per decoration (selection, cursor, underlines, strikethrough).
#version 450

#include "TkzShaderTypes.glsl"
#include "TkzCommon.glsl"

layout(std430, set = TKZ_DESCRIPTOR_SET_INSTANCES, binding = TKZ_BUFFER_INDEX_INSTANCES)
readonly buffer TkzRectInstances {
    TkzRectInstance rects[];
};

// `TkzRectVaryings`; the locations must match tkz_rect_fragment.frag.glsl.
/// Position inside the rect, in pixels, 0…sizePx. The only interpolated varying.
layout(location = 0) out vec2 localPx;
layout(location = 1) flat out vec2 sizePx;
layout(location = 2) flat out vec4 color;
layout(location = 3) flat out uint style;
layout(location = 4) flat out float thicknessPx;
/// Curly-underline wavelength in pixels. Half a cell, so two humps per cell and the phase is
/// continuous across rects that start on a cell boundary.
layout(location = 5) flat out float waveLengthPx;

void main() {
    TkzRectInstance r = rects[gl_InstanceIndex];
    vec2 corner = tkz_quad_corner(uint(gl_VertexIndex));

    gl_Position = tkz_pixel_to_clip(r.originPx + corner * r.sizePx, u.viewportSizePx);
    localPx = corner * r.sizePx;
    sizePx = r.sizePx;
    color = tkz_unpack_rgba(r.color);
    style = r.style;
    // A sub-pixel underline thickness would vanish once antialiased; clamp so hairlines survive.
    thicknessPx = max(r.thicknessPx, 1.0);
    waveLengthPx = max(u.cellSizePx.x * 0.5, 2.0);
}
