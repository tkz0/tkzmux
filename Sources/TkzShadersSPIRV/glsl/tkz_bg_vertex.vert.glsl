// tkz_bg_vertex — port of Terminal.metal's background vertex function. One full-screen triangle,
// three vertices, no buffers. Draw with `vkCmdDraw(cmd, 3, 1, 0, 0)`, cull mode NONE.
#version 450

#include "TkzShaderTypes.glsl"
#include "TkzCommon.glsl"

void main() {
    // (-1,-1), (3,-1), (-1,3): one oversized triangle that covers the whole clip square. The
    // winding is the mirror image of Metal's (Vulkan clip y points down), which is harmless with
    // culling off.
    uint vid = uint(gl_VertexIndex);
    vec2 p = vec2(vid == 1u ? 3.0 : -1.0,
                  vid == 2u ? 3.0 : -1.0);
    gl_Position = vec4(p, 0.0, 1.0);
}
