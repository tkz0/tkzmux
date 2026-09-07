// TkzShaderTypes — structs shared byte-for-byte between Swift (TkzTerminalRender) and Metal
// (Resources/Shaders/Terminal.metal). Header-only; compiled by both `swift build` and
// `xcrun metal -I Sources/TkzShaderTypes/include` in scripts/make-app.sh.
//
// Filled in by M1.5 (TKZ-11): TkzUniforms, TkzBgCell, TkzGlyphInstance, TkzRectInstance.
// See docs/design.md → Terminal engine → Metal renderer.
#pragma once

#include <simd/simd.h>

#define TKZ_SHADER_TYPES_VERSION 1
