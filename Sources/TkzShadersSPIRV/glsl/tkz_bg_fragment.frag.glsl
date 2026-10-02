// tkz_bg_fragment — port of Terminal.metal's background fragment function. Every pixel maps back
// to a grid cell and takes that cell's colour composited over the theme background; the letterbox
// outside the grid takes the theme background alone. No blending.
#version 450

#include "TkzShaderTypes.glsl"
#include "TkzCommon.glsl"

/// `TkzBgCell[gridSize.x * gridSize.y]`, row-major. A `TkzBgCell` is one packed colour.
layout(std430, set = TKZ_DESCRIPTOR_SET_INSTANCES, binding = TKZ_BUFFER_INDEX_INSTANCES)
readonly buffer TkzBgCells {
    uint cells[];
} bg;

layout(location = 0) out vec4 outColor;

void main() {
    vec4 base = tkz_unpack_rgba(u.defaultBackground);

    // `gl_FragCoord.xy` is Metal's `[[position]].xy`: framebuffer pixels, top-left, centres at .5.
    // Signed on purpose: it is left of / above `gridOriginPx` in the letterbox, and casting a
    // negative float to uint would read far past the buffer.
    vec2 cell = floor((gl_FragCoord.xy - u.gridOriginPx) / u.cellSizePx);
    if (cell.x < 0.0 || cell.y < 0.0 ||
        cell.x >= float(u.gridSize.x) || cell.y >= float(u.gridSize.y)) {
        outColor = tkz_premultiply(base);
        return;
    }

    uint index = uint(cell.y) * u.gridSize.x + uint(cell.x);
    outColor = tkz_premultiply(tkz_over_opaque(tkz_unpack_rgba(bg.cells[index]), base));
}
