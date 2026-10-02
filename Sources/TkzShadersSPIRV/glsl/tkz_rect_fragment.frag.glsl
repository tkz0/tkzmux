// tkz_rect_fragment — port of Terminal.metal's rect fragment function. Every style is procedural
// and laid out relative to the instance box; coverage is analytic with a one-pixel filter. Output
// is premultiplied (blend ONE / ONE_MINUS_SRC_ALPHA for colour and alpha). No texture is bound.
#version 450

#include "TkzShaderTypes.glsl"
#include "TkzCommon.glsl"

#define TKZ_PI 3.14159265358979323846

layout(location = 0) in vec2 localPx;
layout(location = 1) flat in vec2 sizePx;
layout(location = 2) flat in vec4 color;
layout(location = 3) flat in uint style;
layout(location = 4) flat in float thicknessPx;
layout(location = 5) flat in float waveLengthPx;

layout(location = 0) out vec4 outColor;

/// Analytic coverage of the interval [lo, hi] at x, with a one-pixel filter.
float tkz_span_coverage(float x, float lo, float hi) {
    return clamp(min(x - lo, hi - x) + 0.5, 0.0, 1.0);
}

/// Coverage of an axis-aligned box, one-pixel filtered on all four edges.
float tkz_box_coverage(vec2 p, vec2 lo, vec2 hi) {
    return tkz_span_coverage(p.x, lo.x, hi.x) * tkz_span_coverage(p.y, lo.y, hi.y);
}

/// Coverage of a periodic mask along x: `period` px long, ink for the first `on` px.
float tkz_dash_coverage(float x, float period, float on) {
    float m = x - period * floor(x / period);
    return clamp(min(m, on - m) + 0.5, 0.0, 1.0);
}

/// Coverage of a sine wave of thickness `t`, centred vertically in `size`, peak-to-peak
/// `size.y - t`. The distance to the curve is the vertical distance corrected by the local slope,
/// which keeps the stroke an even width through the steep parts of the wave.
float tkz_curly_coverage(vec2 p, vec2 size, float t, float waveLength) {
    float amplitude = max((size.y - t) * 0.5, 0.0);
    float k = 2.0 * TKZ_PI / max(waveLength, 1.0);
    float phase = k * p.x;
    float curveY = size.y * 0.5 + amplitude * sin(phase);
    float slope = amplitude * k * cos(phase);
    float distance = abs(p.y - curveY) * inversesqrt(1.0 + slope * slope);
    return clamp(t * 0.5 - distance + 0.5, 0.0, 1.0);
}

void main() {
    vec2 p = localPx;
    vec2 size = sizePx;
    float t = thicknessPx;
    float centerY = size.y * 0.5;
    float coverage = 0.0;

    switch (style) {
    case TKZ_RECT_STYLE_SOLID:
        coverage = 1.0;
        break;

    case TKZ_RECT_STYLE_HOLLOW: {
        float outer = tkz_box_coverage(p, vec2(0.0), size);
        float inner = tkz_box_coverage(p, vec2(t), size - t);
        coverage = clamp(outer - inner, 0.0, 1.0);
        break;
    }

    case TKZ_RECT_STYLE_UNDERLINE_SINGLE:
    case TKZ_RECT_STYLE_STRIKETHROUGH:
        coverage = tkz_span_coverage(p.y, centerY - t * 0.5, centerY + t * 0.5);
        break;

    case TKZ_RECT_STYLE_UNDERLINE_DOUBLE:
        coverage = max(tkz_span_coverage(p.y, 0.0, t),
                       tkz_span_coverage(p.y, size.y - t, size.y));
        break;

    case TKZ_RECT_STYLE_UNDERLINE_CURLY:
        coverage = tkz_curly_coverage(p, size, t, waveLengthPx);
        break;

    case TKZ_RECT_STYLE_UNDERLINE_DOTTED:
        coverage = tkz_span_coverage(p.y, centerY - t * 0.5, centerY + t * 0.5)
                 * tkz_dash_coverage(p.x, t * 2.0, t);
        break;

    case TKZ_RECT_STYLE_UNDERLINE_DASHED:
        coverage = tkz_span_coverage(p.y, centerY - t * 0.5, centerY + t * 0.5)
                 * tkz_dash_coverage(p.x, t * 6.0, t * 4.0);
        break;

    default:
        // Unknown style: draw nothing rather than a mystery block.
        coverage = 0.0;
        break;
    }

    outColor = tkz_premultiply(vec4(color.rgb, color.a * coverage));
}
