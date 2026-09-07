import CoreText
import Foundation
import Testing
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
}
