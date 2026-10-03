// FontTables — the raw sfnt values CellMetrics is derived from, in font units (WOR-311 S2).
//
// This is the entry point for a backend that reads font tables rather than a platform's metric
// accessors. On Linux it must be fed raw table values, not FreeType's derived ones: the
// `FT_Size_Metrics` ascender/descender are ceil/floor-rounded to whole pixels (ascent 21 / descent
// 7 at 20 px instead of 20 / 6), and `face->underline_position` already has half the thickness
// subtracted (offset 5 instead of 4 at 25 px).
//
// Units are converted to pixels through one pixels-per-unit factor, `units * (pixelSize /
// unitsPerEm)`, the order the Mac's own OS/2 strikeout read has always used. The order matters
// on ties: at 35 px, `600 * (35 / 1000)` is 21.000000000000004 and makes a 22 px cell where
// `600 * 35 / 1000` makes 21, and `300 * (35 / 1000)` is 10.500000000000002 rather than 10.5. The
// macOS test that compares this path with CoreText's at 15, 22.4, 25, 28 and 35 px pins the order;
// it lives in `pixelsPerUnit` below and nowhere else.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The OS/2 strikeout fields, in font units, positive up.
public struct OS2Strikeout: Sendable, Equatable, Hashable {
    /// `yStrikeoutSize`: the stroke thickness.
    public let size: Int16
    /// `yStrikeoutPosition`: the stroke centre above the baseline.
    public let position: Int16

    public init(size: Int16, position: Int16) {
        self.size = size
        self.position = position
    }

    /// Reads `yStrikeoutSize` (byte 26) and `yStrikeoutPosition` (byte 28), both big-endian int16,
    /// from a raw OS/2 table. `nil` when the table is too short to hold them (every OS/2 version
    /// has them, so that means a truncated or missing table).
    public init?<Bytes: RandomAccessCollection>(os2Table bytes: Bytes) where Bytes.Element == UInt8 {
        guard bytes.count >= 30 else { return nil }
        func int16(at offset: Int) -> Int16 {
            let hi = bytes[bytes.index(bytes.startIndex, offsetBy: offset)]
            let lo = bytes[bytes.index(bytes.startIndex, offsetBy: offset + 1)]
            return Int16(bitPattern: UInt16(hi) << 8 | UInt16(lo))
        }
        self.size = int16(at: 26)
        self.position = int16(at: 28)
    }

    /// Position and thickness in device pixels, positive up, or `nil` when the font has no usable
    /// strikeout (`unitsPerEm` not positive, or a size that is not positive) and the caller should
    /// fall back.
    public func pixels(pixelSize: CGFloat, unitsPerEm: CGFloat)
        -> (position: CGFloat, thickness: CGFloat)? {
        guard unitsPerEm > 0 else { return nil }
        let pixelsPerUnit = FontTables.pixelsPerUnit(pixelSize: pixelSize, unitsPerEm: unitsPerEm)
        let thickness = CGFloat(size) * pixelsPerUnit
        let position = CGFloat(position) * pixelsPerUnit
        guard thickness > 0 else { return nil }
        return (position: position, thickness: thickness)
    }
}

/// Raw font-unit values from head, hhea, post, OS/2 and hmtx.
public struct FontTables: Sendable, Equatable, Hashable {
    /// `head.unitsPerEm`.
    public var unitsPerEm: Int
    /// `hhea.ascender`, positive up.
    public var ascender: Int
    /// `hhea.descender`, positive up, so normally negative.
    public var descender: Int
    /// `hhea.lineGap`.
    public var lineGap: Int
    /// `post.underlinePosition`: the underline centre, positive up (normally negative).
    public var underlinePosition: Int
    /// `post.underlineThickness`.
    public var underlineThickness: Int
    /// The OS/2 strikeout, or `nil` without a usable OS/2 table.
    public var strikeout: OS2Strikeout?
    /// The x-height, for the strikeout fallback: OS/2 `sxHeight` (version 2 and later), or the
    /// measured height of `x` for an older table.
    public var xHeight: Int
    /// The widest hmtx advance over the glyphs for printable ASCII (U+0020…U+007E).
    public var maxASCIIAdvance: Int

    public init(unitsPerEm: Int,
                ascender: Int,
                descender: Int,
                lineGap: Int,
                underlinePosition: Int,
                underlineThickness: Int,
                strikeout: OS2Strikeout?,
                xHeight: Int,
                maxASCIIAdvance: Int) {
        self.unitsPerEm = unitsPerEm
        self.ascender = ascender
        self.descender = descender
        self.lineGap = lineGap
        self.underlinePosition = underlinePosition
        self.underlineThickness = underlineThickness
        self.strikeout = strikeout
        self.xHeight = xHeight
        self.maxASCIIAdvance = maxASCIIAdvance
    }

    /// The one font-unit → device-pixel factor (see the file header for why the order matters).
    public static func pixelsPerUnit(pixelSize: CGFloat, unitsPerEm: CGFloat) -> CGFloat {
        pixelSize / unitsPerEm
    }
}

extension CellMetrics {
    /// Measures a face from its raw tables at `pixelSize` device pixels per em.
    /// `nil` when `unitsPerEm` is not positive.
    ///
    /// The strikeout falls back to half the x-height and the underline thickness (at least 1 px)
    /// when the font has no usable OS/2 strikeout, the same fallback the CoreText path uses.
    public init?(tables: FontTables, pixelSize: CGFloat, scale: CGFloat) {
        guard tables.unitsPerEm > 0 else { return nil }
        let unitsPerEm = CGFloat(tables.unitsPerEm)
        let pixelsPerUnit = FontTables.pixelsPerUnit(pixelSize: pixelSize, unitsPerEm: unitsPerEm)
        func pixels(_ units: Int) -> CGFloat { CGFloat(units) * pixelsPerUnit }

        let underlineThickness = pixels(tables.underlineThickness)
        let strike = tables.strikeout?.pixels(pixelSize: pixelSize, unitsPerEm: unitsPerEm)
            ?? (position: pixels(tables.xHeight) / 2, thickness: max(1, underlineThickness))
        self.init(ascent: pixels(tables.ascender),
                  descent: pixels(-tables.descender),
                  leading: pixels(tables.lineGap),
                  maxAdvance: pixels(tables.maxASCIIAdvance),
                  underlinePosition: pixels(tables.underlinePosition),
                  underlineThickness: underlineThickness,
                  strikeoutPosition: strike.position,
                  strikeoutThickness: strike.thickness,
                  scale: scale)
    }
}
