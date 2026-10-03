// BoxSprites — procedural box-drawing and block-element glyphs (M1.4), drawn with CoreGraphics.
//
// U+2500…U+257F (box drawing) and U+2580…U+259F (block elements) are the two ranges a terminal has
// to draw itself; TkzRenderCore's `BoxSpriteGeometry` explains why and decides what each sprite is.
// This file is the Mac's painter for that geometry. Linux paints the same geometry with
// `BoxSpriteRasterizer` (TkzRenderCore).
//
// Every sprite is drawn at exactly `metrics.width × metrics.height` with `appliedScale = 1`, so it
// tiles with its neighbours by construction and never goes through the rasterizer's fit/shrink
// pass. Fills are integer rects with antialiasing off (crisp edges, no half-covered seam pixels);
// only arcs and diagonals are antialiased. The bitmap keeps the same transparent padding as a font
// glyph so atlas neighbours cannot bleed in — padding sits *outside* the cell and is transparent,
// so it cannot reintroduce a seam.

import CoreGraphics
import Foundation
import TkzRenderCore

/// Draws the box-drawing and block-element ranges as cell-exact bitmaps.
///
/// Not `Sendable` (CoreGraphics state); owned by `CoreTextGlyphSource` on the render thread.
public struct BoxSprites {
    public let metrics: CellMetrics
    /// Transparent border, matching `GlyphRasterizer.padding`.
    public let padding: Int

    private let geometry: BoxSpriteGeometry
    private let gray = CGColorSpaceCreateDeviceGray()

    public init(metrics: CellMetrics, padding: Int = 1) {
        self.metrics = metrics
        self.padding = max(0, padding)
        self.geometry = BoxSpriteGeometry(metrics: metrics)
    }

    /// True for the single-scalar clusters this type draws (`BoxSpriteGeometry.covers`, shared with
    /// the glyph cache in TkzRenderCore).
    public static func covers(_ scalars: [Unicode.Scalar]) -> Bool {
        BoxSpriteGeometry.covers(scalars)
    }

    public static func covers(_ scalar: Unicode.Scalar) -> Bool {
        BoxSpriteGeometry.covers(scalar)
    }

    private var w: Int { metrics.width }
    private var h: Int { metrics.height }

    // MARK: - Entry point

    /// Rasterizes one sprite, or `nil` when the scalar is outside the covered ranges (the caller
    /// then falls back to the font).
    public func rasterize(_ scalar: Unicode.Scalar) -> RasterizedGlyph? {
        guard let primitives = geometry.primitives(for: scalar) else { return nil }
        return makeBitmap { ctx in
            self.draw(primitives, ctx)
        }
    }

    /// Builds the alpha-only bitmap and runs `draw` in cell coordinates: origin at the cell's
    /// top-left corner, y growing downward, (w, h) at the bottom-right.
    private func makeBitmap(_ draw: (CGContext) -> Void) -> RasterizedGlyph? {
        let width = w + padding * 2
        let height = h + padding * 2
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drew: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: gray,
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }

            ctx.setShouldAntialias(false)
            ctx.setAllowsAntialiasing(false)
            ctx.setLineCap(.butt)
            // Bitmap origin is bottom-left; flip into top-left cell coordinates.
            ctx.translateBy(x: CGFloat(padding), y: CGFloat(padding + h))
            ctx.scaleBy(x: 1, y: -1)
            setAlpha(ctx, 1)
            draw(ctx)
            return true
        }
        guard drew else { return nil }

        return RasterizedGlyph(
            width: width, height: height, bytesPerRow: bytesPerRow, bytesPerPixel: 1,
            bearingX: -padding, bearingTop: metrics.baseline + padding, isColor: false,
            appliedScale: 1, pixels: pixels)
    }

    private func setAlpha(_ ctx: CGContext, _ alpha: CGFloat) {
        if let color = CGColor(colorSpace: gray, components: [1, alpha]) {
            ctx.setFillColor(color)
            ctx.setStrokeColor(color)
        }
    }

    // MARK: - Painting

    /// Replays the geometry: integer rects with antialiasing off, strokes with it on. The fill
    /// colour is opaque except while a shade is filled, as before the geometry moved to the core.
    private func draw(_ primitives: [BoxSpriteGeometry.Primitive], _ ctx: CGContext) {
        for primitive in primitives {
            switch primitive {
            case let .fill(x, y, width, height, alpha):
                if alpha != 1 { setAlpha(ctx, CGFloat(alpha)) }
                ctx.fill(CGRect(x: x, y: y, width: width, height: height))
                if alpha != 1 { setAlpha(ctx, 1) }
            case let .stroke(path, lineWidth):
                ctx.setShouldAntialias(true)
                ctx.setAllowsAntialiasing(true)
                ctx.setLineWidth(CGFloat(lineWidth))
                ctx.addPath(cgPath(path))
                ctx.strokePath()
                ctx.setShouldAntialias(false)
                ctx.setAllowsAntialiasing(false)
            }
        }
    }

    private func cgPath(_ elements: [BoxSpriteGeometry.PathElement]) -> CGPath {
        func point(_ p: BoxSpriteGeometry.Point) -> CGPoint { CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let to): path.move(to: point(to))
            case .line(let to): path.addLine(to: point(to))
            case let .quadCurve(to, control): path.addQuadCurve(to: point(to), control: point(control))
            }
        }
        return path
    }
}
