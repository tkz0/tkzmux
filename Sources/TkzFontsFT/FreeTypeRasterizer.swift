// FreeTypeRasterizer — shaped cluster → A8 coverage or premultiplied BGRA bitmap, the Linux side of
// the Mac's GlyphRasterizer (WOR-312 S5).
//
// Placement. Each glyph is loaded unhinted (`FreeTypeFace.loadFlags`) and measured with
// `FT_Outline_Get_BBox`, the exact ink box, which is what CoreText's bounding rects are; the boxes go
// through TkzRenderCore's `GlyphPlacement`, the Mac's union / fit-scale / integer-origin rules, so
// both platforms put a glyph on the same pixels.
//
// Outlines (the grayscale page). In order, on the loaded outline in 26.6 pixels:
//   1. synthetic bold, only when the family has no real bold (`RasterizerOptions.syntheticBold`;
//      never for the bundled JetBrains Mono, as on the Mac): EmboldenXY(w, w), then translate by
//      -w/2, with w = max(1, 0.03 · px), the Mac's fill-and-stroke width; no synthetic italic,
//      which the Mac never applies either;
//   2. the glyph's pen offset, the fit scale and the bitmap origin, as the Mac's CGContext
//      transform does them;
//   3. with `thicken`, the CoreGraphics-smoothing dilation (`Dilation`), in device pixels;
//   4. `FT_Outline_Render` with anti-aliasing, through a span callback that composites each glyph
//      source-over into the bitmap, the way CGContext draws one glyph over another.
// FreeType's smooth rasterizer computes exact area coverage, so with the same outline at the same
// fractional position the masks differ only by 26.6 quantization (about 1-2/255).
//
// Colour (the BGRA page). Bitmap-strike faces (CBDT Noto Color Emoji) are drawn from the strike
// `FreeTypeFace.selectStrike` picks, loaded with `FT_LOAD_COLOR`, and scaled with
// `ColorBitmapResampler`'s premultiplied area average: strike pixels × (px / strike ppem) × the fit
// scale. Scalable colour faces (COLRv0) are rendered by FreeType at px. A colour face's
// non-colour glyph comes out as grayscale coverage and is drawn white, as the Mac's colour context
// fills it. COLRv1-only glyphs never get here: the shaper skips their faces.
//
// Not Sendable: used inside `TerminalFaces`' owner, behind its `Mutex`, with the faces it draws.

import CFreeType
import Foundation
import TkzRenderCore

/// How glyphs are rasterized: the terminal's `thicken` setting and what goes with it.
public struct RasterizerOptions: Sendable, Equatable {
    /// CoreGraphics font smoothing, emulated by dilation (grayscale glyphs only).
    public var thicken: Bool
    /// Transparent border before `thicken`'s extra pixel; the Mac's GlyphRasterizer default is 1.
    public var basePadding: Int
    /// The dilation for `thicken`; `nil` takes `Dilation.pathfinder(pixelSize:)`.
    public var dilation: Dilation?
    /// Embolden bold styles, for a family with no bold face (`TerminalFaces.needsSyntheticBold`).
    public var syntheticBold: Bool

    public init(thicken: Bool = true, basePadding: Int = 1, dilation: Dilation? = nil, syntheticBold: Bool = false) {
        self.thicken = thicken
        self.basePadding = basePadding
        self.dilation = dilation
        self.syntheticBold = syntheticBold
    }

    /// The transparent border around every bitmap: one pixel more when thickening, to hold the
    /// dilation (`GlyphRasterizer.padding` on the Mac).
    public var padding: Int { max(0, basePadding) + (thicken ? 1 : 0) }

    /// The dilation applied at `pixelSize`: none without `thicken` or above 72 ppem.
    public func effectiveDilation(pixelSize: CGFloat) -> Dilation {
        guard thicken, pixelSize <= Dilation.maxPixelSize else { return .none }
        return dilation ?? .pathfinder(pixelSize: pixelSize)
    }

    /// The synthetic-bold stroke width at `pixelSize`, as the Mac computes it.
    public static func syntheticBoldWidth(pixelSize: CGFloat) -> CGFloat {
        max(1, pixelSize * 0.03)
    }
}

/// A rasterized cluster and the ink box it was placed from (for dumps and tests).
struct RasterResult {
    let glyph: RasterizedGlyph
    let ink: GlyphBounds
}

final class FreeTypeRasterizer {
    /// Load flags for colour glyphs: bitmaps allowed (the strike is the glyph), colour on.
    static let colorLoadFlags = FT_Int32(FT_LOAD_COLOR | FT_LOAD_NO_HINTING)

    private let library: FreeTypeLibrary

    init(library: FreeTypeLibrary) {
        self.library = library
    }

    /// Rasterizes `cluster`, whose glyphs belong to `face`. `nil` when nothing has ink.
    func rasterize(_ cluster: ShapedCluster,
                   style: FontStyle,
                   face: FreeTypeFace,
                   metrics: CellMetrics,
                   pixelSize: CGFloat,
                   options: RasterizerOptions) -> RasterResult? {
        guard !cluster.glyphs.isEmpty else { return nil }
        let boxWidth = CGFloat(metrics.width * max(1, cluster.cellSpan))
        let boxHeight = CGFloat(metrics.height)
        if cluster.isColor {
            return rasterizeColor(cluster, face: face, pixelSize: pixelSize,
                                  boxWidth: boxWidth, boxHeight: boxHeight, padding: options.padding)
        }
        return rasterizeOutlines(cluster, style: style, face: face, pixelSize: pixelSize,
                                 boxWidth: boxWidth, boxHeight: boxHeight, options: options)
    }

    // MARK: - Outlines (A8)

    /// Loads `glyph` unhinted; the outline is in the face's glyph slot until the next load.
    private func loadOutline(_ glyph: GlyphID, face: FreeTypeFace) -> UnsafeMutablePointer<FT_Outline>? {
        guard FT_Load_Glyph(face.handle, FT_UInt(glyph.rawValue), FreeTypeFace.loadFlags) == 0 else { return nil }
        return currentOutline(face)
    }

    /// The outline in the face's glyph slot, addressed in place (FreeType owns it until the next
    /// load), or `nil` when the slot does not hold an outline.
    private func currentOutline(_ face: FreeTypeFace) -> UnsafeMutablePointer<FT_Outline>? {
        guard let slot = face.handle.pointee.glyph, slot.pointee.format == FT_GLYPH_FORMAT_OUTLINE,
              let offset = MemoryLayout<FT_GlyphSlotRec>.offset(of: \.outline) else { return nil }
        return (UnsafeMutableRawPointer(slot) + offset).assumingMemoryBound(to: FT_Outline.self)
    }

    /// The exact ink box of a loaded outline, in pixels; empty for an outline with no points.
    private static func bounds(of outline: UnsafeMutablePointer<FT_Outline>) -> GlyphBounds {
        let empty = GlyphBounds(minX: 0, minY: 0, maxX: 0, maxY: 0)
        guard outline.pointee.n_points > 0 else { return empty }
        var box = FT_BBox()
        guard FT_Outline_Get_BBox(outline, &box) == 0 else { return empty }
        return GlyphBounds(minX: CGFloat(box.xMin) / 64, minY: CGFloat(box.yMin) / 64,
                           maxX: CGFloat(box.xMax) / 64, maxY: CGFloat(box.yMax) / 64)
    }

    private func rasterizeOutlines(_ cluster: ShapedCluster,
                                   style: FontStyle,
                                   face: FreeTypeFace,
                                   pixelSize: CGFloat,
                                   boxWidth: CGFloat,
                                   boxHeight: CGFloat,
                                   options: RasterizerOptions) -> RasterResult? {
        let strokeWidth = style.isBold && options.syntheticBold
            ? RasterizerOptions.syntheticBoldWidth(pixelSize: pixelSize) : 0

        var measured: [(bounds: GlyphBounds, xOffset: CGFloat, yOffset: CGFloat)] = []
        measured.reserveCapacity(cluster.glyphs.count)
        for glyph in cluster.glyphs {
            let bounds = loadOutline(glyph.glyph, face: face).map(Self.bounds)
                ?? GlyphBounds(minX: 0, minY: 0, maxX: 0, maxY: 0)
            measured.append((bounds, glyph.xOffset, glyph.yOffset))
        }
        guard let placement = GlyphPlacement.place(glyphs: measured, strokeOutset: strokeWidth,
                                                   boxWidth: boxWidth, boxHeight: boxHeight,
                                                   padding: options.padding) else { return nil }

        let width = placement.width, height = placement.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let dilation = options.effectiveDilation(pixelSize: pixelSize).halfStrength26Dot6
        let boldHalf = FT_Pos((strokeWidth * 32).rounded())
        let scale = placement.appliedScale
        let matrix = FT_Matrix(xx: FT_Fixed((scale * 65536).rounded()), xy: 0,
                               yx: 0, yy: FT_Fixed((scale * 65536).rounded()))

        pixels.withUnsafeMutableBufferPointer { buffer in
            var target = SpanTarget(base: buffer.baseAddress!, width: Int32(width), height: Int32(height))
            for (index, glyph) in cluster.glyphs.enumerated() where !measured[index].bounds.isEmpty {
                // A single glyph is still in the slot from measuring it.
                let reuse = cluster.glyphs.count == 1
                guard let outline = reuse ? currentOutline(face) : loadOutline(glyph.glyph, face: face) else { continue }
                if boldHalf > 0 {
                    FT_Outline_EmboldenXY(outline, boldHalf * 2, boldHalf * 2)
                    FT_Outline_Translate(outline, -boldHalf, -boldHalf)
                }
                FT_Outline_Translate(outline, FT_Pos((glyph.xOffset * 64).rounded()), FT_Pos((glyph.yOffset * 64).rounded()))
                if scale != 1 {
                    var transform = matrix
                    FT_Outline_Transform(outline, &transform)
                }
                FT_Outline_Translate(outline, FT_Pos(-placement.originX * 64), FT_Pos(-placement.originY * 64))
                if dilation.x > 0 || dilation.y > 0 {
                    FT_Outline_EmboldenXY(outline, dilation.x * 2, dilation.y * 2)
                    FT_Outline_Translate(outline, -dilation.x, -dilation.y)
                }
                render(outline, into: &target)
            }
        }

        let glyph = RasterizedGlyph(width: width, height: height, bytesPerRow: width, bytesPerPixel: 1,
                                    bearingX: placement.bearingX, bearingTop: placement.bearingTop,
                                    isColor: false, appliedScale: placement.appliedScale, pixels: pixels)
        return RasterResult(glyph: glyph, ink: placement.union)
    }

    /// The bitmap a span callback writes into: rows top-down, outline y up from the bottom row.
    /// Shared with `IconRasterizer`.
    struct SpanTarget {
        let base: UnsafeMutablePointer<UInt8>
        let width: Int32
        let height: Int32
    }

    /// Composites one anti-aliased span list source-over: `a + b - a·b/255`.
    static let compositeSpans: FT_SpanFunc = { y, count, spans, user in
        guard let spans, let user else { return }
        let target = user.assumingMemoryBound(to: SpanTarget.self).pointee
        let row = target.height - 1 - y
        guard row >= 0, row < target.height else { return }
        let line = target.base + Int(row) * Int(target.width)
        for k in 0..<Int(count) {
            let span = spans[k]
            let coverage = Int(span.coverage)
            guard coverage > 0 else { continue }
            let start = max(0, Int32(span.x)), end = min(target.width, Int32(span.x) + Int32(span.len))
            guard start < end else { continue }
            for x in Int(start)..<Int(end) {
                let below = Int(line[x])
                line[x] = below == 0 ? UInt8(coverage)
                    : UInt8((coverage * 255 + below * (255 - coverage) + 127) / 255)
            }
        }
    }

    private func render(_ outline: UnsafeMutablePointer<FT_Outline>, into target: inout SpanTarget) {
        withUnsafeMutablePointer(to: &target) { pointer in
            var params = FT_Raster_Params()
            params.flags = FT_RASTER_FLAG_AA | FT_RASTER_FLAG_DIRECT | FT_RASTER_FLAG_CLIP
            params.gray_spans = Self.compositeSpans
            params.user = UnsafeMutableRawPointer(pointer)
            params.clip_box = FT_BBox(xMin: 0, yMin: 0, xMax: FT_Pos(pointer.pointee.width), yMax: FT_Pos(pointer.pointee.height))
            _ = FT_Outline_Render(library.handle, outline, &params)
        }
    }

    // MARK: - Colour (BGRA)

    /// One loaded colour glyph: premultiplied BGRA rows and where they sit.
    private struct ColorBitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        /// The bitmap's ink box in device pixels at the face's size, pen offset applied, y up.
        let bounds: GlyphBounds
        /// Device pixels per bitmap pixel before the fit scale.
        let pixelScale: CGFloat
    }

    private func rasterizeColor(_ cluster: ShapedCluster,
                                face: FreeTypeFace,
                                pixelSize: CGFloat,
                                boxWidth: CGFloat,
                                boxHeight: CGFloat,
                                padding: Int) -> RasterResult? {
        // A bitmap-only face draws from a strike; a scalable one at the face's pixel size.
        var pixelScale: CGFloat = 1
        if !face.isScalable {
            guard let strike = face.selectStrike(for: pixelSize), strike > 0 else { return nil }
            pixelScale = pixelSize / strike
        }

        var bitmaps: [ColorBitmap?] = []
        for glyph in cluster.glyphs {
            bitmaps.append(loadColorBitmap(glyph, face: face, pixelScale: pixelScale))
        }
        let measured = bitmaps.map { ($0?.bounds ?? GlyphBounds(minX: 0, minY: 0, maxX: 0, maxY: 0), CGFloat(0), CGFloat(0)) }
        guard let placement = GlyphPlacement.place(glyphs: measured, boxWidth: boxWidth, boxHeight: boxHeight,
                                                   padding: padding) else { return nil }

        let width = placement.width, height = placement.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let scale = placement.appliedScale
        for case let bitmap? in bitmaps where !bitmap.bounds.isEmpty {
            // Top-left of the bitmap in the destination: x from the left edge, rows from the top.
            let left = Double(bitmap.bounds.minX * scale) - Double(placement.originX)
            let top = Double(placement.originY + height) - Double(bitmap.bounds.maxY * scale)
            bitmap.pixels.withUnsafeBufferPointer { source in
                ColorBitmapResampler.draw(source: source, sourceWidth: bitmap.width, sourceHeight: bitmap.height,
                                          sourceBytesPerRow: bitmap.width * 4,
                                          into: &pixels, destinationWidth: width, destinationHeight: height,
                                          originX: left, originY: top, scale: Double(bitmap.pixelScale * scale))
            }
        }
        let glyph = RasterizedGlyph(width: width, height: height, bytesPerRow: width * 4, bytesPerPixel: 4,
                                    bearingX: placement.bearingX, bearingTop: placement.bearingTop,
                                    isColor: true, appliedScale: placement.appliedScale, pixels: pixels)
        return RasterResult(glyph: glyph, ink: placement.union)
    }

    /// Loads and renders one colour glyph into premultiplied BGRA. A grayscale result (a glyph with
    /// no colour data) becomes white coverage.
    private func loadColorBitmap(_ glyph: ClusterGlyph, face: FreeTypeFace, pixelScale: CGFloat) -> ColorBitmap? {
        guard FT_Load_Glyph(face.handle, FT_UInt(glyph.glyph.rawValue), Self.colorLoadFlags) == 0,
              let slot = face.handle.pointee.glyph else { return nil }
        if slot.pointee.format != FT_GLYPH_FORMAT_BITMAP {
            guard FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) == 0 else { return nil }
        }
        let bitmap = slot.pointee.bitmap
        let width = Int(bitmap.width), height = Int(bitmap.rows)
        guard width > 0, height > 0, let buffer = bitmap.buffer else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let pitch = Int(bitmap.pitch)
        // A negative pitch means bottom-up rows; FreeType's buffer pointer is then the last row.
        func row(_ y: Int) -> UnsafeMutablePointer<UInt8> {
            pitch >= 0 ? buffer + y * pitch : buffer + (height - 1 - y) * -pitch
        }
        switch bitmap.pixel_mode {
        case UInt8(FT_PIXEL_MODE_BGRA.rawValue):
            for y in 0..<height {
                let source = row(y)
                for x in 0..<width * 4 { pixels[y * width * 4 + x] = source[x] }
            }
        case UInt8(FT_PIXEL_MODE_GRAY.rawValue):
            let levels = max(1, Int(bitmap.num_grays) - 1)
            for y in 0..<height {
                let source = row(y)
                for x in 0..<width {
                    let coverage = UInt8(min(255, Int(source[x]) * 255 / levels))
                    let o = (y * width + x) * 4
                    pixels[o] = coverage; pixels[o + 1] = coverage; pixels[o + 2] = coverage; pixels[o + 3] = coverage
                }
            }
        default:
            return nil
        }

        let left = CGFloat(slot.pointee.bitmap_left) * pixelScale + glyph.xOffset
        let top = CGFloat(slot.pointee.bitmap_top) * pixelScale + glyph.yOffset
        let bounds = GlyphBounds(minX: left, minY: top - CGFloat(height) * pixelScale,
                                 maxX: left + CGFloat(width) * pixelScale, maxY: top)
        return ColorBitmap(width: width, height: height, pixels: pixels, bounds: bounds, pixelScale: pixelScale)
    }
}
