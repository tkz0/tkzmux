// GlyphPlacement — exact glyph bounds → integer bitmap extent and fit scale (WOR-312 S5).
//
// The placement rules of the Mac's `GlyphRasterizer.rasterize`, as pure arithmetic over pixel
// bounds, so a backend that measures its own outlines (FreeType's `FT_Outline_Get_BBox` on Linux)
// places a glyph on the same integer pixels CoreText's bounds give on the Mac:
//   1. union the bounds of every glyph in the cluster, each offset by its pen position, skipping
//      empty ones; nothing left means nothing to draw;
//   2. grow the union by the synthetic-bold stroke width on every side;
//   3. when the union overflows the cluster's box (cellSpan cells wide, one cell tall), scale it
//      uniformly until it fits;
//   4. round the scaled union outwards to whole pixels and add the transparent padding;
//   5. when that rounding pushed the bitmap past the box, shrink the scale once more.
//
// The Mac still runs its own copy of these steps inline (TkzTerminalRender, unchanged: Mac goldens
// stay byte-identical); WOR-311 S3's CoreTextGlyphSource is where it can move onto this one.
//
// Coordinates are device pixels from the pen origin (baseline, left edge of the cluster), y up.

import Foundation

/// An axis-aligned glyph box in device pixels, y up.
public struct GlyphBounds: Sendable, Equatable {
    public var minX: CGFloat
    public var minY: CGFloat
    public var maxX: CGFloat
    public var maxY: CGFloat

    public init(minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: CGFloat { maxX - minX }
    public var height: CGFloat { maxY - minY }
    /// No area: CoreText reports such a box for a glyph with no ink (a space).
    public var isEmpty: Bool { !(width > 0) || !(height > 0) }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> GlyphBounds {
        GlyphBounds(minX: minX + dx, minY: minY + dy, maxX: maxX + dx, maxY: maxY + dy)
    }

    public func union(_ other: GlyphBounds) -> GlyphBounds {
        GlyphBounds(minX: min(minX, other.minX), minY: min(minY, other.minY),
                    maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }

    /// Grown by `amount` on every side.
    public func outset(by amount: CGFloat) -> GlyphBounds {
        GlyphBounds(minX: minX - amount, minY: minY - amount, maxX: maxX + amount, maxY: maxY + amount)
    }
}

/// Where a rasterized cluster's bitmap sits relative to the pen origin, and the scale its glyphs
/// are drawn at.
public struct GlyphPlacement: Sendable, Equatable {
    /// The ink union the placement was computed from, after the stroke outset, before scaling.
    public let union: GlyphBounds
    /// Uniform scale that fits the union into the cluster's box (1 when it fitted as drawn).
    public let appliedScale: CGFloat
    /// The bitmap's left and bottom edges, in whole pixels from the pen origin, padding included.
    public let originX: Int
    public let originY: Int
    /// The bitmap's size, padding included.
    public let width: Int
    public let height: Int

    /// `RasterizedGlyph.bearingX`.
    public var bearingX: Int { originX }
    /// `RasterizedGlyph.bearingTop`: the bitmap's top edge above the baseline.
    public var bearingTop: Int { originY + height }

    /// Places a cluster.
    ///
    /// - Parameters:
    ///   - glyphs: each glyph's exact ink bounds at the face's size and its pen offset.
    ///   - strokeOutset: the synthetic-bold stroke width (0 without synthetic bold); the union
    ///     grows by the whole width on every side, as on the Mac.
    ///   - boxWidth/boxHeight: the cluster's box, `metrics.width * cellSpan` by `metrics.height`.
    ///   - padding: transparent border on every side of the bitmap.
    /// - Returns: `nil` when no glyph has ink.
    public static func place(glyphs: [(bounds: GlyphBounds, xOffset: CGFloat, yOffset: CGFloat)],
                             strokeOutset: CGFloat = 0,
                             boxWidth: CGFloat,
                             boxHeight: CGFloat,
                             padding: Int) -> GlyphPlacement? {
        var union: GlyphBounds?
        for glyph in glyphs where !glyph.bounds.isEmpty {
            let placed = glyph.bounds.offsetBy(dx: glyph.xOffset, dy: glyph.yOffset)
            union = union.map { $0.union(placed) } ?? placed
        }
        guard var union, union.width > 0, union.height > 0 else { return nil }
        if strokeOutset > 0 { union = union.outset(by: strokeOutset) }

        var appliedScale: CGFloat = 1
        if union.width > boxWidth || union.height > boxHeight {
            appliedScale = min(boxWidth / union.width, boxHeight / union.height)
        }
        func extent(_ scale: CGFloat) -> (originX: Int, originY: Int, width: Int, height: Int) {
            let minX = Int((union.minX * scale).rounded(.down))
            let minY = Int((union.minY * scale).rounded(.down))
            return (minX - padding, minY - padding,
                    Int((union.maxX * scale).rounded(.up)) - minX + padding * 2,
                    Int((union.maxY * scale).rounded(.up)) - minY + padding * 2)
        }

        var placed = extent(appliedScale)
        // Rounding outwards can put the bitmap 1 px past the box; tighten once, so a glyph never
        // exceeds its box plus padding.
        let overWidth = CGFloat(placed.width - padding * 2) - boxWidth
        let overHeight = CGFloat(placed.height - padding * 2) - boxHeight
        if overWidth > 0 || overHeight > 0 {
            let shrinkX = overWidth > 0 ? boxWidth / CGFloat(placed.width - padding * 2) : 1
            let shrinkY = overHeight > 0 ? boxHeight / CGFloat(placed.height - padding * 2) : 1
            appliedScale *= min(shrinkX, shrinkY)
            placed = extent(appliedScale)
        }
        guard placed.width > 0, placed.height > 0 else { return nil }
        return GlyphPlacement(union: union, appliedScale: appliedScale,
                              originX: placed.originX, originY: placed.originY,
                              width: placed.width, height: placed.height)
    }
}
