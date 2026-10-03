// BoxSpriteRasterizer — box-drawing and block-element sprites without CoreGraphics (WOR-311 S5).
//
// Paints `BoxSpriteGeometry` into the same alpha-only bitmap the Mac's CoreGraphics `BoxSprites`
// produces: `width × height` of the cell plus a transparent `padding` ring, `appliedScale = 1`,
// placed with `bearingX = -padding` and `bearingTop = baseline + padding`, so it tiles with its
// neighbours by construction and never goes through a rasterizer's fit pass.
//
// - Fills are integer rects with antialiasing off. A covered pixel takes the fill's alpha rounded
//   to the nearest of 255 steps, halves up (`quantize`): 255 for a line or block, 64 / 128 / 191
//   for the shades ░▒▓, which is how CoreGraphics quantizes a fill colour into an A8 context.
//   These sprites are byte-identical to the Mac's; BoxSpritesTests checks both on the Mac.
// - The arcs U+256D…U+2570 and the diagonals U+2571…U+2573 are stroked with exact-area
//   (analytic) antialiasing: the stroke outline — butt caps, the quadratic flattened finely
//   enough that its error is far below a pixel — is filled by a signed-area accumulator, and each
//   pixel takes the area of the outline inside it. The two subpaths of `╳` are one stroke, so the
//   ink is their union, as CoreGraphics fills a stroke nonzero: the overlap is subtracted once.
//   These differ from the Mac only at antialiased edge pixels, which the WOR-299 glyph threshold
//   (SSIM ≥ 0.90, bbox ±1 px) covers.
//
// Used by the Linux `FreeTypeGlyphSource`; the Mac keeps drawing with CoreGraphics.

/// Draws box-drawing and block-element sprites as cell-exact A8 bitmaps.
public struct BoxSpriteRasterizer: Sendable {
    public let metrics: CellMetrics
    /// Transparent border, matching the glyph rasterizer's padding.
    public let padding: Int
    public let geometry: BoxSpriteGeometry

    public init(metrics: CellMetrics, padding: Int = 1) {
        self.metrics = metrics
        self.padding = max(0, padding)
        self.geometry = BoxSpriteGeometry(metrics: metrics)
    }

    /// Rasterizes one sprite, or `nil` when the scalar is outside the covered ranges (the caller
    /// then falls back to the font).
    public func rasterize(_ scalar: Unicode.Scalar) -> RasterizedGlyph? {
        guard let primitives = geometry.primitives(for: scalar) else { return nil }
        let width = metrics.width + padding * 2
        let height = metrics.height + padding * 2
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)

        for primitive in primitives {
            switch primitive {
            case let .fill(x, y, w, h, alpha):
                // Cell → bitmap coordinates, clipped to the bitmap as CoreGraphics clips.
                let x0 = max(0, x + padding), x1 = min(width, x + padding + w)
                let y0 = max(0, y + padding), y1 = min(height, y + padding + h)
                guard x0 < x1, y0 < y1 else { continue }
                let a = Self.quantize(alpha)
                for row in y0..<y1 {
                    for column in x0..<x1 {
                        Self.composite(a, over: &pixels[row * width + column])
                    }
                }
            case let .stroke(path, lineWidth):
                var coverage = CoverageAccumulator(width: width, height: height)
                let offset = Double(padding)
                let outlines = Self.strokeOutlines(path, lineWidth: lineWidth).map { outline in
                    outline.map { (x: $0.x + offset, y: $0.y + offset) }
                }
                for outline in outlines { coverage.addPolygon(outline) }
                // Two crossing subpaths (`╳`): take their overlap away once, so the ink is exactly
                // the union. The clamp alone would count a pixel both half-cover as fully inked.
                if outlines.count == 2, let overlap = Self.convexIntersection(outlines[0], outlines[1]) {
                    coverage.addPolygon(overlap.reversed())
                }
                coverage.resolve { index, value in
                    Self.composite(Self.quantize(value), over: &pixels[index])
                }
            }
        }

        return RasterizedGlyph(
            width: width, height: height, bytesPerRow: width, bytesPerPixel: 1,
            bearingX: -padding, bearingTop: metrics.baseline + padding, isColor: false,
            appliedScale: 1, pixels: pixels)
    }

    // MARK: - Pixels

    /// A fill alpha or a coverage in [0, 1] as an A8 value: the nearest of 255 steps, halves up.
    static func quantize(_ alpha: Double) -> UInt8 {
        UInt8(min(255, max(0, (alpha * 255).rounded(.toNearestOrAwayFromZero))))
    }

    /// Source-over in an alpha-only bitmap.
    static func composite(_ source: UInt8, over destination: inout UInt8) {
        guard source > 0 else { return }
        let s = Int(source), d = Int(destination)
        destination = UInt8(s + (d * (255 - s) + 127) / 255)
    }

    // MARK: - Stroke outlines

    /// Segments per quadratic. The arcs' radius is a third of the cell, so even at 72 px a chord
    /// of a 64-way split strays from the curve by well under a hundredth of a pixel.
    static let quadSegments = 64

    /// The closed outlines of `path` stroked `lineWidth` wide with butt caps: one per subpath,
    /// the left side walked forward and the right side back. Every outline has the same
    /// orientation, so where they overlap their areas add; `convexIntersection` takes the overlap
    /// back out.
    static func strokeOutlines(_ path: [BoxSpriteGeometry.PathElement],
                               lineWidth: Double) -> [[BoxSpriteGeometry.Point]] {
        typealias Point = BoxSpriteGeometry.Point
        // Centre-line samples with their unit normals (pointing left of the direction of travel).
        var subpaths: [[(point: Point, normal: Point)]] = []
        var current: [(point: Point, normal: Point)] = []
        var pen = Point(x: 0, y: 0)

        func normal(_ dx: Double, _ dy: Double) -> Point? {
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return nil }
            return Point(x: -dy / length, y: dx / length)
        }
        func flush() {
            if current.count >= 2 { subpaths.append(current) }
            current = []
        }

        for element in path {
            switch element {
            case .move(let to):
                flush()
                pen = to
            case .line(let to):
                if let n = normal(to.x - pen.x, to.y - pen.y) {
                    current.append((pen, n))
                    current.append((to, n))
                }
                pen = to
            case let .quadCurve(to, control):
                let p0 = pen
                for i in 0...quadSegments {
                    let t = Double(i) / Double(quadSegments), u = 1 - t
                    let point = Point(x: u * u * p0.x + 2 * u * t * control.x + t * t * to.x,
                                      y: u * u * p0.y + 2 * u * t * control.y + t * t * to.y)
                    // B'(t) / 2; at a degenerate end (control on an end point) use the chord.
                    let dx = u * (control.x - p0.x) + t * (to.x - control.x)
                    let dy = u * (control.y - p0.y) + t * (to.y - control.y)
                    if let n = normal(dx, dy) ?? normal(to.x - p0.x, to.y - p0.y) {
                        current.append((point, n))
                    }
                }
                pen = to
            }
        }
        flush()

        let half = lineWidth / 2
        return subpaths.map { samples in
            let left = samples.map { Point(x: $0.point.x + $0.normal.x * half, y: $0.point.y + $0.normal.y * half) }
            let right = samples.reversed().map { Point(x: $0.point.x - $0.normal.x * half,
                                                       y: $0.point.y - $0.normal.y * half) }
            return left + right
        }
    }
}

// MARK: - Convex overlap

extension BoxSpriteRasterizer {
    typealias Vertex = (x: Double, y: Double)

    /// +1 or -1 for a convex polygon wound that way, `nil` for a concave or degenerate one.
    static func convexOrientation(_ polygon: [Vertex]) -> Double? {
        guard polygon.count >= 3 else { return nil }
        var sign = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count], c = polygon[(i + 2) % polygon.count]
            let turn = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard turn != 0 else { continue }
            if sign == 0 {
                sign = turn > 0 ? 1 : -1
            } else if (turn > 0 ? 1 : -1) != sign {
                return nil
            }
        }
        return sign == 0 ? nil : sign
    }

    /// The overlap of two convex polygons wound the same way (Sutherland–Hodgman), wound like
    /// them; `nil` when either is not convex or they do not overlap.
    static func convexIntersection(_ subject: [Vertex], _ clip: [Vertex]) -> [Vertex]? {
        guard let orientation = convexOrientation(clip), convexOrientation(subject) == orientation else {
            return nil
        }
        var output = subject
        for i in clip.indices where !output.isEmpty {
            let a = clip[i], b = clip[(i + 1) % clip.count]
            func side(_ p: Vertex) -> Double {
                ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) * orientation
            }
            let input = output
            output = []
            for j in input.indices {
                let p = input[j], q = input[(j + 1) % input.count]
                let sp = side(p), sq = side(q)
                if sp >= 0 { output.append(p) }
                if (sp >= 0) != (sq >= 0) {
                    let t = sp / (sp - sq)
                    output.append((x: p.x + t * (q.x - p.x), y: p.y + t * (q.y - p.y)))
                }
            }
        }
        return output.count >= 3 ? output : nil
    }
}

// MARK: - Coverage accumulator

/// Exact-area coverage of closed polygons over a pixel grid (y down).
///
/// Each edge deposits, per pixel it crosses, its signed height there split between that pixel and
/// the next by where it crosses: the running sum along a row is then the winding-weighted area of
/// the polygons inside each pixel. `resolve` clamps its magnitude to 1, which fills nonzero where
/// a pixel is wholly inside overlapping polygons (at a shared antialiased edge it over-counts, so
/// a caller that needs the exact union subtracts the overlap). Edges left of the grid count as if on its
/// left edge; edges right of it and parts above or below it drop out, which is clipping.
struct CoverageAccumulator {
    let width: Int
    let height: Int
    /// `width + 2` cells per row: a deposit can land one past the last pixel.
    private var cells: [Double]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.cells = [Double](repeating: 0, count: (width + 2) * height)
    }

    mutating func addPolygon(_ points: [(x: Double, y: Double)]) {
        guard points.count >= 3 else { return }
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            addEdge(a.x, a.y, b.x, b.y)
        }
    }

    private mutating func addEdge(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        guard y0 != y1, x0.isFinite, y0.isFinite, x1.isFinite, y1.isFinite else { return }
        // Walk top to bottom; `sign` keeps the edge's direction.
        let (sign, ax, ay, bx, by) = y0 < y1 ? (1.0, x0, y0, x1, y1) : (-1.0, x1, y1, x0, y0)
        let top = max(ay, 0), bottom = min(by, Double(height))
        guard top < bottom else { return }
        let slope = (bx - ax) / (by - ay)
        func x(at y: Double) -> Double { ax + (y - ay) * slope }

        var row = Int(top.rounded(.down))
        while row < height, Double(row) < bottom {
            let rowTop = max(top, Double(row)), rowBottom = min(bottom, Double(row + 1))
            if rowTop < rowBottom {
                addRowSpan(row: row, x(at: rowTop), rowTop, x(at: rowBottom), rowBottom, sign: sign)
            }
            row += 1
        }
    }

    /// One edge's piece inside a pixel row, split where it crosses a pixel column.
    private mutating func addRowSpan(row: Int, _ xa: Double, _ ya: Double, _ xb: Double, _ yb: Double,
                                     sign: Double) {
        let base = row * (width + 2)
        // Each piece lies in one column, or wholly left or right of the grid: left of it counts as
        // on x = 0 (everything right of it is inside), right of it lands in the spare cell past the
        // last pixel, which nothing reads.
        func deposit(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
            let dy = (y1 - y0) * sign
            let mid = min(max((x0 + x1) / 2, 0), Double(width))
            let column = min(Int(mid.rounded(.down)), width)
            let fraction = mid - Double(column)
            cells[base + column] += dy * (1 - fraction)
            cells[base + column + 1] += dy * fraction
        }
        // The pixel-column boundaries 0…width strictly between the two ends, where it is cut.
        let span = Double(width) + 1
        let lo = min(max(min(xa, xb), -1), span), hi = min(max(max(xa, xb), -1), span)
        let first = max(Int(lo.rounded(.down)) + 1, 0), last = min(Int(hi.rounded(.up)) - 1, width)
        guard xa != xb, first <= last else { return deposit(xa, ya, xb, yb) }
        let slope = (yb - ya) / (xb - xa)
        var cuts = (first...last).map(Double.init)
        if xa > xb { cuts.reverse() }
        var px = xa, py = ya
        for cut in cuts {
            let cy = ya + (cut - xa) * slope
            deposit(px, py, cut, cy)
            px = cut
            py = cy
        }
        deposit(px, py, xb, yb)
    }

    /// Calls `body` with the pixel index and coverage in (0, 1] of every covered pixel.
    func resolve(_ body: (Int, Double) -> Void) {
        for row in 0..<height {
            var sum = 0.0
            let base = row * (width + 2)
            for column in 0..<width {
                sum += cells[base + column]
                let coverage = min(1, abs(sum))
                if coverage > 1e-9 { body(row * width + column, coverage) }
            }
        }
    }
}
