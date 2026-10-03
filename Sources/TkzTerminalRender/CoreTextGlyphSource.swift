// CoreTextGlyphSource — the Mac font stack behind TkzRenderCore's `GlyphSource` seam (WOR-311 S3).
//
// Wraps what the Mac's GlyphCache used to own directly: the `FontSet`, the `GraphemeShaper`, the
// `GlyphRasterizer` and the `BoxSprites`, built exactly as before so every bitmap stays
// byte-identical. The core never sees a `CTFont` or `CGGlyph`: each face a shaped cluster comes
// back in (a primary style face or a CoreText fallback) is entered once in a face table and handed
// out as an opaque `FontFace`, and glyph ids widen to `GlyphID`. `rasterize` turns both back into
// the `ShapedGrapheme` the rasterizer takes. `GlyphCache` rasterizes straight after it shapes, so
// that is normally the shaper's own `ShapedGrapheme`, `CTFont` object and all; the face table is the
// fallback for a cluster shaped earlier.
//
// Called only on a glyph-cache miss.

import CoreText
import Foundation
import TkzRenderCore

/// The CoreText `GlyphSource`. One per `FontSet` (size, scale) and `thicken`, like the cache it
/// feeds.
///
/// Not `Sendable` (holds `CTFont`s); lives on the render thread with its `GlyphCache`.
public final class CoreTextGlyphSource: GlyphSource {
    public let fontSet: FontSet
    public let metrics: CellMetrics
    public let shaper: GraphemeShaper
    public let rasterizer: GlyphRasterizer
    /// Box-drawing and block-element sprites, drawn instead of the font's own glyphs so they tile.
    public let sprites: BoxSprites

    /// Every face handed out so far; a `FontFace` is an index into it.
    private var fonts: [CTFont] = []
    private var faces: [FaceKey: FontFace] = [:]
    /// The cluster `shape` returned last and the `ShapedGrapheme` it was made from. Rasterizing
    /// that grapheme, rather than one rebuilt from the face table, draws with the exact `CTFont`
    /// the shaper resolved, not merely one CoreFoundation considers equal: the bitmaps are the
    /// ones the cache drew before the seam existed.
    private var lastShaped: (cluster: ShapedCluster, grapheme: ShapedGrapheme)?

    /// A `CTFont` keyed by CoreFoundation equality, so the same face reached twice (CoreText often
    /// returns a fresh object for a fallback) maps to one `FontFace`.
    private struct FaceKey: Hashable {
        let font: CTFont

        static func == (a: FaceKey, b: FaceKey) -> Bool { CFEqual(a.font, b.font) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(font)) }
    }

    /// - Parameter thicken: font smoothing on grayscale glyphs (`GlyphRasterizer.thicken`).
    public init(fontSet: FontSet, thicken: Bool = true) {
        let metrics = CellMetrics(fontSet: fontSet)
        let rasterizer = GlyphRasterizer(fontSet: fontSet, metrics: metrics, thicken: thicken)
        self.fontSet = fontSet
        self.metrics = metrics
        self.shaper = GraphemeShaper(fontSet: fontSet)
        self.rasterizer = rasterizer
        self.sprites = BoxSprites(metrics: metrics, padding: rasterizer.padding)
    }

    public var padding: Int { rasterizer.padding }

    public func shape(_ scalars: [Unicode.Scalar], style: FontStyle, cellSpan: Int?) -> ShapedCluster {
        let shaped = shaper.shape(scalars, style: style, cellSpan: cellSpan)
        let cluster = ShapedCluster(
            face: face(for: shaped.font),
            glyphs: shaped.glyphs.map {
                ClusterGlyph(glyph: GlyphID(rawValue: UInt32($0.glyph)), xOffset: $0.xOffset, yOffset: $0.yOffset)
            },
            isColor: shaped.isColor,
            cellSpan: shaped.cellSpan)
        lastShaped = (cluster, shaped)
        return cluster
    }

    public func rasterize(_ cluster: ShapedCluster, style: FontStyle) -> RasterizedGlyph? {
        if let last = lastShaped, last.cluster == cluster {
            return rasterizer.rasterize(last.grapheme, style: style)
        }
        guard let resolved = font(of: cluster.face) else { return nil }
        let shaped = ShapedGrapheme(
            font: resolved,
            glyphs: cluster.glyphs.map {
                ShapedGlyph(glyph: CGGlyph(truncatingIfNeeded: $0.glyph.rawValue),
                            xOffset: $0.xOffset, yOffset: $0.yOffset)
            },
            isColor: cluster.isColor,
            cellSpan: cluster.cellSpan)
        return rasterizer.rasterize(shaped, style: style)
    }

    public func sprite(for scalar: Unicode.Scalar) -> RasterizedGlyph? {
        sprites.rasterize(scalar)
    }

    public func name(of face: FontFace) -> String {
        guard let resolved = font(of: face) else { return "?" }
        return CTFontCopyPostScriptName(resolved) as String
    }

    // MARK: - Face table

    /// The `CTFont` behind a handle this source minted, or `nil` for anyone else's.
    public func font(of face: FontFace) -> CTFont? {
        let index = Int(face.rawValue)
        return fonts.indices.contains(index) ? fonts[index] : nil
    }

    /// The handle for `font`, entering it in the table the first time it is seen.
    private func face(for font: CTFont) -> FontFace {
        let key = FaceKey(font: font)
        if let face = faces[key] { return face }
        let face = FontFace(rawValue: UInt32(fonts.count))
        fonts.append(font)
        faces[key] = face
        return face
    }
}

extension GlyphCache {
    /// A glyph cache over CoreText: the Mac's production font stack.
    ///
    /// - Parameter thicken: font smoothing on grayscale glyphs (`GlyphRasterizer.thicken`).
    public convenience init(fontSet: FontSet,
                            grayscaleInitialSize: Int? = nil,
                            colorInitialSize: Int? = nil,
                            thicken: Bool = true) {
        self.init(source: CoreTextGlyphSource(fontSet: fontSet, thicken: thicken),
                  grayscaleInitialSize: grayscaleInitialSize,
                  colorInitialSize: colorInitialSize)
    }
}
