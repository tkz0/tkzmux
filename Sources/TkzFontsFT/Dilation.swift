// Dilation — the outline growth that stands in for CoreGraphics font smoothing (WOR-312 S5).
//
// On the Mac, `thicken` turns on font smoothing in an alpha-only context, which CoreGraphics
// implements as a dilation of the glyph outline (GlyphRasterizer.swift's header): about 17 % more
// coverage at 25 px. FreeType has no such pass, so the rasterizer grows the outline itself with
// `FT_Outline_EmboldenXY(2rx, 2ry)` and moves it back by `(-rx, -ry)`: EmboldenXY keeps the
// outline's left and bottom edges where they were and pushes the right and top ones out by the full
// strength, so the translate re-centres it and each edge moves out by r.
//
// Starting values are Pathfinder's reverse-engineered `STEM_DARKENING_FACTORS` (x 0.0121, y
// 0.0121 × 1.25 = 0.015125 per pixel of size, each capped at 0.3 px), with no dilation above
// 72 ppem. Those constants target macOS 10.13, so they are only a start: WOR-312 S6 fits rx and ry
// per size against the reference Mac's thicken=1 atlases and supplies them through `init(rx:ry:)`
// (DilationCalibration.swift).

import CFreeType
import Foundation

public struct Dilation: Sendable, Equatable {
    /// Horizontal growth per edge, in device pixels.
    public let rx: CGFloat
    /// Vertical growth per edge, in device pixels.
    public let ry: CGFloat

    public init(rx: CGFloat, ry: CGFloat) {
        self.rx = max(0, rx)
        self.ry = max(0, ry)
    }

    /// No growth.
    public static let none = Dilation(rx: 0, ry: 0)

    /// Pathfinder's per-pixel factors and cap.
    public static let factorX: CGFloat = 0.0121
    public static let factorY: CGFloat = 0.015125
    public static let maxRadius: CGFloat = 0.3
    /// Above this size CoreGraphics stops darkening.
    public static let maxPixelSize: CGFloat = 72

    /// The starting values for a face at `pixelSize` device pixels per em.
    public static func pathfinder(pixelSize: CGFloat) -> Dilation {
        guard pixelSize <= maxPixelSize else { return .none }
        return Dilation(rx: min(maxRadius, factorX * pixelSize), ry: min(maxRadius, factorY * pixelSize))
    }

    public var isNone: Bool { rx == 0 && ry == 0 }

    /// The per-edge growth in 26.6 units. The strength handed to EmboldenXY is twice this, so the
    /// outline grows by exactly this much on each side (FreeType halves an odd strength with
    /// integer division, which would drop a 64th from one side).
    var halfStrength26Dot6: (x: FT_Pos, y: FT_Pos) {
        (FT_Pos((rx * 64).rounded()), FT_Pos((ry * 64).rounded()))
    }
}
