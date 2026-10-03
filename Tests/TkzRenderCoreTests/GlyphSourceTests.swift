// GlyphSourceTests — the font seam is implementable with no platform font stack (WOR-311 S2).
//
// `BlockGlyphSource` is the deterministic stand-in the core's tests shape and rasterize with: every
// printable scalar is one glyph whose id is its code point, drawn as a solid cell-sized block. It
// counts its calls, so the glyph-cache tests can tell a hit from a miss.

import Foundation
import Testing
import TkzRenderCore

/// A synthetic `GlyphSource`: one face, glyph id = code point, a solid block per glyph. Scalars
/// in `colorScalars` shape as colour glyphs and rasterize as opaque white BGRA. With `drawsSprites`
/// it draws every box-sprite scalar as a cell-exact block of `0x80`.
final class BlockGlyphSource: GlyphSource {
    let metrics: CellMetrics
    let padding = 1
    let drawsSprites: Bool
    let colorScalars: Set<Unicode.Scalar>
    private(set) var shapeCalls = 0
    private(set) var rasterizeCalls = 0
    private(set) var spriteCalls = 0

    init(metrics: CellMetrics, drawsSprites: Bool = false, colorScalars: Set<Unicode.Scalar> = []) {
        self.metrics = metrics
        self.drawsSprites = drawsSprites
        self.colorScalars = colorScalars
    }

    func shape(_ scalars: [Unicode.Scalar], style: FontStyle, cellSpan: Int?) -> ShapedCluster {
        shapeCalls += 1
        let glyphs = scalars.map { scalar in
            ClusterGlyph(glyph: scalar.properties.generalCategory == .control || scalar == " "
                ? .notdef : GlyphID(rawValue: scalar.value))
        }
        let isColor = scalars.contains { colorScalars.contains($0) }
        return ShapedCluster(face: FontFace(rawValue: UInt32(style.rawValue)), glyphs: glyphs,
                             isColor: isColor, cellSpan: cellSpan ?? (isColor ? 2 : 1))
    }

    func rasterize(_ cluster: ShapedCluster, style: FontStyle) -> RasterizedGlyph? {
        rasterizeCalls += 1
        guard !cluster.isEmpty else { return nil }
        let bytesPerPixel = cluster.isColor ? 4 : 1
        let width = metrics.width * cluster.cellSpan + 2 * padding
        let height = metrics.height + 2 * padding
        return RasterizedGlyph(width: width, height: height, bytesPerRow: width * bytesPerPixel,
                               bytesPerPixel: bytesPerPixel,
                               bearingX: -padding, bearingTop: metrics.baseline + padding,
                               isColor: cluster.isColor, appliedScale: 1,
                               pixels: [UInt8](repeating: 0xFF, count: width * height * bytesPerPixel))
    }

    func sprite(for scalar: Unicode.Scalar) -> RasterizedGlyph? {
        spriteCalls += 1
        guard drawsSprites, BoxSpriteGeometry.covers(scalar) else { return nil }
        let width = metrics.width + 2 * padding
        let height = metrics.height + 2 * padding
        return RasterizedGlyph(width: width, height: height, bytesPerRow: width, bytesPerPixel: 1,
                               bearingX: -padding, bearingTop: metrics.baseline + padding,
                               isColor: false, appliedScale: 1,
                               pixels: [UInt8](repeating: 0x80, count: width * height))
    }

    func name(of face: FontFace) -> String { "Block-\(face.rawValue)" }
}

@Suite("GlyphSource seam")
struct GlyphSourceTests {
    private let metrics = CellMetrics(ascent: 25.5, descent: 7.5, leading: 0, maxAdvance: 15,
                                      underlinePosition: -3.875, underlineThickness: 1.25,
                                      strikeoutPosition: 8, strikeoutThickness: 1.25, scale: 2)

    @Test("a source shapes, rasterizes and names faces through the existential")
    func existential() throws {
        let source: any GlyphSource = BlockGlyphSource(metrics: metrics)
        #expect(source.metrics.width == 15)

        let shaped = source.shape(["A"], style: .bold, cellSpan: 2)
        #expect(shaped.glyphs == [ClusterGlyph(glyph: GlyphID(rawValue: 0x41))])
        #expect(shaped.cellSpan == 2)
        #expect(source.name(of: shaped.face) == "Block-1")

        let raster = try #require(source.rasterize(shaped, style: .bold))
        #expect(raster.width == 15 * 2 + 2)
        #expect(raster.height == 33 + 2)
        #expect(raster.bearingTop == 27)
        #expect(!raster.isEmpty)
        #expect(source.sprite(for: "─") == nil)
    }

    @Test("a cluster of only .notdef glyphs is empty and draws nothing")
    func emptyCluster() {
        let source = BlockGlyphSource(metrics: metrics)
        let space = source.shape([" "], style: .regular, cellSpan: nil)
        #expect(space.isEmpty)
        #expect(source.rasterize(space, style: .regular) == nil)
        #expect(ShapedCluster(face: FontFace(rawValue: 0), glyphs: [], isColor: false, cellSpan: 1).isEmpty)
    }

    @Test("FontStyle maps bold and italic both ways")
    func fontStyle() {
        for style in FontStyle.allCases {
            #expect(FontStyle(bold: style.isBold, italic: style.isItalic) == style)
        }
        #expect(FontStyle(bold: true, italic: true) == .boldItalic)
        #expect(FontStyle.allCases.map(\.rawValue) == [0, 1, 2, 3])
    }
}
