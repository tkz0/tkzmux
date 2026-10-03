// FreeTypeGlyphSource — the Linux font stack behind TkzRenderCore's `GlyphSource` seam (WOR-312 S5).
//
// Shaping and rasterizing go to `TerminalFaces`; this adds the rasterizer options a glyph cache is
// built with (`thicken`, and synthetic bold when the family needs it), the way the Mac's
// CoreTextGlyphSource builds its GlyphRasterizer. One source per (size, scale, thicken), like the
// Mac's.
//
// Box-drawing and block-element sprites come from TkzRenderCore's `BoxSpriteRasterizer`, which
// paints the same `BoxSpriteGeometry` the Mac's CoreGraphics `BoxSprites` does, at the same padding
// as the glyphs.

import Foundation
import TkzRenderCore

public final class FreeTypeGlyphSource: GlyphSource {
    public let faces: TerminalFaces
    public let options: RasterizerOptions
    /// Box-drawing and block-element sprites, drawn instead of the font's own glyphs so they tile.
    public let sprites: BoxSpriteRasterizer

    public init(faces: TerminalFaces, thicken: Bool = true, dilation: Dilation? = nil) {
        self.faces = faces
        self.options = RasterizerOptions(thicken: thicken, dilation: dilation,
                                         syntheticBold: faces.needsSyntheticBold)
        self.sprites = BoxSpriteRasterizer(metrics: faces.metrics, padding: options.padding)
    }

    public var metrics: CellMetrics { faces.metrics }

    public var padding: Int { options.padding }

    public func shape(_ scalars: [Unicode.Scalar], style: FontStyle, cellSpan: Int?) -> ShapedCluster {
        faces.shape(scalars, style: style, cellSpan: cellSpan)
    }

    public func rasterize(_ cluster: ShapedCluster, style: FontStyle) -> RasterizedGlyph? {
        faces.rasterize(cluster, style: style, options: options)
    }

    public func sprite(for scalar: Unicode.Scalar) -> RasterizedGlyph? {
        sprites.rasterize(scalar)
    }

    public func name(of face: FontFace) -> String {
        faces.name(of: face)
    }
}
