// CellMetrics from CoreText (M1.4).
//
// The struct and its formulas live in TkzRenderCore (CellMetrics.swift there), shared with the
// Linux font backend. This file only reads the CoreText values and hands them to the shared
// formula. Everything is device pixels at the `FontSet`'s scale, because `FontSet` builds its
// `CTFont`s at `pointSize * scale`.

import CoreText
import Foundation
import TkzRenderCore

extension CellMetrics {
    /// Measures the regular face of `fontSet`.
    public init(fontSet: FontSet) {
        self.init(font: fontSet.font(for: .regular), scale: fontSet.scale)
    }

    /// Measures a `CTFont` that is already sized in device pixels.
    public init(font: CTFont, scale: CGFloat) {
        // Underline: CoreText reports position relative to the baseline, positive *up*.
        // Strikethrough: CoreText has no accessor, so read OS/2 (`strikeout(of:)`).
        let strike = CellMetrics.strikeout(of: font)
        self.init(ascent: CTFontGetAscent(font),
                  descent: CTFontGetDescent(font),
                  leading: CTFontGetLeading(font),
                  maxAdvance: CellMetrics.maxASCIIAdvance(of: font),
                  underlinePosition: CTFontGetUnderlinePosition(font),
                  underlineThickness: CTFontGetUnderlineThickness(font),
                  strikeoutPosition: strike.position,
                  strikeoutThickness: strike.thickness,
                  scale: scale)
    }

    /// Max horizontal advance over printable ASCII (U+0020…U+007E).
    static func maxASCIIAdvance(of font: CTFont) -> CGFloat {
        let chars: [UniChar] = (0x20...0x7E).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count) else {
            // A face missing some ASCII glyph: measure what we can, zeros contribute nothing.
            return CellMetrics.advanceMax(font: font, glyphs: glyphs)
        }
        return CellMetrics.advanceMax(font: font, glyphs: glyphs)
    }

    private static func advanceMax(font: CTFont, glyphs: [CGGlyph]) -> CGFloat {
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        _ = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        return advances.reduce(CGFloat(0)) { max($0, $1.width) }
    }

    /// Strikeout size and position in device pixels, positive up, from the OS/2 table through the
    /// shared parser (`OS2Strikeout`). Falls back to half the x-height and the underline thickness
    /// when the font has no usable OS/2 table.
    static func strikeout(of font: CTFont) -> (position: CGFloat, thickness: CGFloat) {
        let fallback = (position: CTFontGetXHeight(font) / 2,
                        thickness: max(1, CTFontGetUnderlineThickness(font)))
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) else {
            return fallback
        }
        let parsed = withExtendedLifetime(table) { () -> OS2Strikeout? in
            let length = CFDataGetLength(table)
            guard length >= 30, let bytes = CFDataGetBytePtr(table) else { return nil }
            return OS2Strikeout(os2Table: UnsafeBufferPointer(start: bytes, count: length))
        }
        guard let strikeout = parsed else { return fallback }
        let unitsPerEm = CGFloat(CTFontGetUnitsPerEm(font))
        return strikeout.pixels(pixelSize: CTFontGetSize(font), unitsPerEm: unitsPerEm) ?? fallback
    }
}
