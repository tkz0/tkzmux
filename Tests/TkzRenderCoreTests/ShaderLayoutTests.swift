// ShaderLayoutTests — Swift's view of TkzShaderTypes.h, checked on macOS and on Linux.
//
// The C compiler and both Metal compilers evaluate the `_Static_assert`s at the bottom of the
// header; this suite asserts the very same literals through `MemoryLayout`, so Swift, C and Metal
// cannot silently disagree about a struct layout. On Linux the header declares its vector types with
// `ext_vector_type` instead of including <simd/simd.h>, and `vectorFieldsImportAsSIMD2` pins that
// those still import as the `SIMD2` types the Mac renderer writes.
//
// The Metal compile tests and the bundled-header checks stay in
// Tests/TkzTerminalRenderTests/ShaderCompileTests.swift (macOS only).

import Testing
import TkzShaderTypes

@Suite("Shader struct layout")
struct ShaderLayoutTests {
    // The literals below are duplicated from the TKZ_STATIC_ASSERTs at the bottom of
    // TkzShaderTypes.h. If one side changes, this fails before anything renders.

    @Test func uniformsLayoutMatchesTheCHeader() {
        #expect(MemoryLayout<TkzUniforms>.size == 80)
        #expect(MemoryLayout<TkzUniforms>.stride == 80)
        #expect(MemoryLayout<TkzUniforms>.alignment == 8)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.viewportSizePx) == 0)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.cellSizePx) == 8)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.gridOriginPx) == 16)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.grayscaleAtlasSizePx) == 24)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.colorAtlasSizePx) == 32)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.gridSize) == 40)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.defaultBackground) == 48)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.defaultForeground) == 52)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.cursorColor) == 56)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.cursorTextColor) == 60)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.minContrast) == 64)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.reserved0) == 68)
    }

    @Test func bgCellLayoutMatchesTheCHeader() {
        #expect(MemoryLayout<TkzBgCell>.size == 4)
        #expect(MemoryLayout<TkzBgCell>.stride == 4)
        #expect(MemoryLayout<TkzBgCell>.alignment == 4)
        #expect(MemoryLayout<TkzBgCell>.offset(of: \.color) == 0)
    }

    @Test func glyphInstanceLayoutMatchesTheCHeader() {
        #expect(MemoryLayout<TkzGlyphInstance>.size == 32)
        #expect(MemoryLayout<TkzGlyphInstance>.stride == 32)
        #expect(MemoryLayout<TkzGlyphInstance>.alignment == 4)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.gridPos) == 0)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.offsetPx) == 4)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.sizePx) == 8)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.atlasPos) == 12)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.color) == 16)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.bgColor) == 20)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.flags) == 24)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.reserved0) == 28)
    }

    @Test func rectInstanceLayoutMatchesTheCHeader() {
        #expect(MemoryLayout<TkzRectInstance>.size == 32)
        #expect(MemoryLayout<TkzRectInstance>.stride == 32)
        #expect(MemoryLayout<TkzRectInstance>.alignment == 8)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.originPx) == 0)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.sizePx) == 8)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.color) == 16)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.style) == 20)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.thicknessPx) == 24)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.reserved0) == 28)
    }

    /// The renderers fill these fields with `SIMD2` values. On Darwin the types come from
    /// <simd/simd.h>; elsewhere from the header's own `ext_vector_type` typedefs. Either way Swift
    /// must see the same types, or FrameBuilder would not compile on one of the two.
    @Test func vectorFieldsImportAsSIMD2() {
        #expect(type(of: TkzUniforms().viewportSizePx) == SIMD2<Float>.self)
        #expect(type(of: TkzUniforms().cellSizePx) == SIMD2<Float>.self)
        #expect(type(of: TkzUniforms().gridOriginPx) == SIMD2<Float>.self)
        #expect(type(of: TkzUniforms().grayscaleAtlasSizePx) == SIMD2<Float>.self)
        #expect(type(of: TkzUniforms().colorAtlasSizePx) == SIMD2<Float>.self)
        #expect(type(of: TkzUniforms().gridSize) == SIMD2<UInt32>.self)
        #expect(type(of: TkzGlyphInstance().gridPos) == SIMD2<UInt16>.self)
        #expect(type(of: TkzGlyphInstance().offsetPx) == SIMD2<Int16>.self)
        #expect(type(of: TkzGlyphInstance().sizePx) == SIMD2<UInt16>.self)
        #expect(type(of: TkzGlyphInstance().atlasPos) == SIMD2<UInt16>.self)
        #expect(type(of: TkzRectInstance().originPx) == SIMD2<Float>.self)
        #expect(type(of: TkzRectInstance().sizePx) == SIMD2<Float>.self)

        // And the values land where MemoryLayout says: x then y, little-endian, no padding.
        var glyph = TkzGlyphInstance()
        glyph.gridPos = SIMD2<UInt16>(0x0102, 0x0304)
        glyph.offsetPx = SIMD2<Int16>(-2, 5)
        let bytes = withUnsafeBytes(of: &glyph) { Array($0.prefix(8)) }
        #expect(bytes == [0x02, 0x01, 0x04, 0x03, 0xFE, 0xFF, 0x05, 0x00])
    }

    /// The binding contract and the flag bits are part of the header, so pin them here too: a
    /// renumbering would otherwise only show up as a blank terminal.
    @Test func bindingContractIsStable() {
        #expect(TKZ_BUFFER_INDEX_UNIFORMS == 0)
        #expect(TKZ_BUFFER_INDEX_INSTANCES == 1)
        #expect(TKZ_TEXTURE_INDEX_GRAYSCALE == 0)
        #expect(TKZ_TEXTURE_INDEX_COLOR == 1)

        #expect(TKZ_GLYPH_FLAG_COLOR == 1)
        #expect(TKZ_GLYPH_FLAG_UNDER_CURSOR == 2)
        #expect(TKZ_GLYPH_FLAG_MIN_CONTRAST == 4)
        #expect(TKZ_GLYPH_FLAG_WIDE == 8)

        #expect(TKZ_RECT_STYLE_SOLID == 0)
        #expect(TKZ_RECT_STYLE_HOLLOW == 1)
        #expect(TKZ_RECT_STYLE_UNDERLINE_SINGLE == 2)
        #expect(TKZ_RECT_STYLE_UNDERLINE_DOUBLE == 3)
        #expect(TKZ_RECT_STYLE_UNDERLINE_CURLY == 4)
        #expect(TKZ_RECT_STYLE_UNDERLINE_DOTTED == 5)
        #expect(TKZ_RECT_STYLE_UNDERLINE_DASHED == 6)
        #expect(TKZ_RECT_STYLE_STRIKETHROUGH == 7)
        #expect(TKZ_RECT_STYLE_COUNT == 8)
    }
}
