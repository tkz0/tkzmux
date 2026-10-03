import CoreText
import Foundation
import Testing
import TkzRenderCore
@testable import TkzTerminalRender

@Suite("CellMetrics")
struct CellMetricsTests {

    /// Exact values measured on macOS 26 / arm64. They are hard-coded on purpose: a change here means
    /// the font pipeline changed, and the renderer's grid geometry with it.
    @Test("Menlo 13 pt at 2x is deterministic and integral")
    func menlo13At2x() {
        let fonts = FontSet(family: "Menlo", fallback: "Menlo", pointSize: 13, scale: 2)
        #expect(fonts.resolvedFamily == "Menlo")
        let metrics = CellMetrics(fontSet: fonts)

        #expect(metrics.width == 16)
        #expect(metrics.height == 30)
        #expect(metrics.ascent == 24)
        #expect(metrics.descent == 6)
        #expect(metrics.leading == 0)
        #expect(metrics.baseline == 24)
        #expect(metrics.underlineOffset == 2)
        #expect(metrics.underlineThickness == 1)
        #expect(metrics.strikethroughOffset == -7)
        #expect(metrics.strikethroughThickness == 1)
        #expect(metrics.scale == 2)
        #expect(metrics.wideWidth == 32)
    }

    @Test("JetBrains Mono 12.5 pt at 2x is deterministic and integral")
    func jetBrainsMono125At2x() {
        let fonts = FontSet(pointSize: 12.5, scale: 2)
        let metrics = CellMetrics(fontSet: fonts)

        #expect(metrics.width == 15)     // 0.6 em advance at 25 px
        #expect(metrics.height == 33)
        #expect(metrics.ascent == 26)
        #expect(metrics.descent == 8)
        #expect(metrics.leading == 0)
        #expect(metrics.baseline == 26)
        #expect(metrics.underlineOffset == 4)
        #expect(metrics.underlineThickness == 1)
        #expect(metrics.strikethroughOffset == -8)
        #expect(metrics.strikethroughThickness == 1)
    }

    @Test("measuring the same font twice gives the same struct")
    func repeatable() {
        let a = CellMetrics(fontSet: FontSet(pointSize: 12.5, scale: 2))
        let b = CellMetrics(fontSet: FontSet(pointSize: 12.5, scale: 2))
        #expect(a == b)
    }

    @Test("scale multiplies the geometry")
    func scalesWithBackingScale() {
        let at1x = CellMetrics(fontSet: FontSet(pointSize: 12.5, scale: 1))
        let at2x = CellMetrics(fontSet: FontSet(pointSize: 12.5, scale: 2))
        #expect(at2x.width >= at1x.width * 2 - 1)
        #expect(at2x.height >= at1x.height * 2 - 2)
        #expect(at1x.scale == 1)
    }

    @Test("decoration thicknesses never round down to zero")
    func thicknessFloor() {
        // Small sizes are where rounding would otherwise produce a 0 px rule.
        let fonts = FontSet(pointSize: 12.5, scale: 1)
        for size in [6.0, 8.0, 9.5, 12.5, 20.0] as [CGFloat] {
            let metrics = CellMetrics(font: CTFontCreateCopyWithAttributes(
                fonts.font(for: .regular), size, nil, nil), scale: 1)
            #expect(metrics.underlineThickness >= 1)
            #expect(metrics.strikethroughThickness >= 1)
            #expect(metrics.width >= 1)
            #expect(metrics.height >= 1)
        }
    }

    @Test("the widest ASCII advance is what a monospaced face reports for every printable ASCII")
    func asciiAdvanceIsUniformForMonospace() {
        let fonts = FontSet(pointSize: 12.5, scale: 2)
        let font = fonts.font(for: .regular)
        let chars: [UniChar] = (0x20...0x7E).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        #expect(CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count))
        var advances = [CGSize](repeating: .zero, count: chars.count)
        _ = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, chars.count)
        let widths = Set(advances.map { ($0.width * 100).rounded() })
        #expect(widths.count == 1)
        #expect(CellMetrics.maxASCIIAdvance(of: font) == advances[0].width)
    }

    // MARK: - Raw tables vs CoreText (WOR-311 S2)

    /// The four bundled faces, measured both ways: CoreText's accessors (`init(font:scale:)`) and
    /// the raw head/hhea/post/OS/2/hmtx values through the shared formula (`init(tables:…)`), which
    /// is what Linux uses. 15 and 35 px are tie sizes (descent 4.5 and 10.5, and at 35 px the
    /// advance is 21.000000000000004 or 21 depending on the operation order), so if this fails only
    /// there, `FontTables.pixelsPerUnit` has the wrong order for CoreText.
    @Test("the raw-table formula equals the CoreText path for every bundled face",
          arguments: [15, 22.4, 25, 28, 35] as [CGFloat])
    func rawTablesMatchCoreText(pixelSize: CGFloat) throws {
        let fonts = FontSet(pointSize: pixelSize, scale: 1)
        try #require(fonts.resolvedFamily == "JetBrains Mono")
        #expect(!fonts.needsSyntheticBold)
        #expect(!fonts.needsSyntheticItalic)
        for style in FontStyle.allCases {
            let font = fonts.font(for: style)
            let name = fonts.postScriptName(for: style)
            #expect(name.hasPrefix("JetBrainsMono"))
            #expect(CTFontGetSize(font) == pixelSize)
            let tables = try rawTables(of: font)
            let raw = try #require(CellMetrics(tables: tables, pixelSize: CTFontGetSize(font),
                                               scale: 1))
            #expect(raw == CellMetrics(font: font, scale: 1), "\(name) at \(pixelSize) px")
        }
    }

    /// The raw table values of `font`, read from its table bytes rather than CoreText's accessors.
    private func rawTables(of font: CTFont) throws -> FontTables {
        func table(_ tag: CTFontTableTag) throws -> [UInt8] {
            let data = try #require(CTFontCopyTable(font, tag, []))
            return [UInt8](data as Data)
        }
        func uint16(_ bytes: [UInt8], _ offset: Int) -> Int {
            Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        func int16(_ bytes: [UInt8], _ offset: Int) -> Int {
            Int(Int16(bitPattern: UInt16(uint16(bytes, offset))))
        }
        let head = try table(CTFontTableTag(kCTFontTableHead))
        let hhea = try table(CTFontTableTag(kCTFontTableHhea))
        let post = try table(CTFontTableTag(kCTFontTablePost))
        let os2 = try table(CTFontTableTag(kCTFontTableOS2))
        let hmtx = try table(CTFontTableTag(kCTFontTableHmtx))

        // hmtx: numberOfHMetrics (hhea byte 34) long metrics of {advance, lsb}; glyphs past the
        // last one repeat its advance.
        let numberOfHMetrics = uint16(hhea, 34)
        let chars: [UniChar] = (0x20...0x7E).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        #expect(CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count))
        let maxAdvance = glyphs
            .map { uint16(hmtx, 4 * min(Int($0), numberOfHMetrics - 1)) }
            .max() ?? 0

        return FontTables(unitsPerEm: uint16(head, 18),
                          ascender: int16(hhea, 4),
                          descender: int16(hhea, 6),
                          lineGap: int16(hhea, 8),
                          underlinePosition: int16(post, 8),
                          underlineThickness: int16(post, 10),
                          strikeout: OS2Strikeout(os2Table: os2),
                          xHeight: int16(os2, 86),
                          maxASCIIAdvance: maxAdvance)
    }
}
