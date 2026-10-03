// BoxSpriteRasterizerTests — the shared box-sprite geometry and its pure-Swift painter (WOR-311 S5).
//
// Runs on both OSes at the three pinned cell sizes (25, 28 and 22.4 px JetBrains Mono: 15x33,
// 17x37, 14x30). The tiling cases are the Mac BoxSpritesTests' own, here against the rasterizer
// Linux draws with; on the Mac, BoxSpritesTests also checks that the CoreGraphics painter and this
// one agree sprite for sprite. The antialiased strokes are checked against an independent
// supersampled reference: the distance to the centre line, sampled 16x16 per pixel.

import Foundation
import Testing
@testable import TkzRenderCore

@Suite("Box-sprite geometry and rasterizer")
struct BoxSpriteRasterizerTests {

    /// JetBrains Mono's tables (CellMetricsTablesTests).
    private static let tables = FontTables(
        unitsPerEm: 1000,
        ascender: 1020, descender: -300, lineGap: 0,
        underlinePosition: -155, underlineThickness: 50,
        strikeout: OS2Strikeout(size: 50, position: 320),
        xHeight: 550,
        maxASCIIAdvance: 600)

    static let pixelSizes: [CGFloat] = [25, 28, 14 * 1.6]

    static func metrics(_ pixelSize: CGFloat) -> CellMetrics {
        CellMetrics(tables: tables, pixelSize: pixelSize, scale: 2)!
    }

    static let allScalars: [Unicode.Scalar] = (0x2500...0x259F).map { Unicode.Scalar(UInt32($0))! }
    static let strokedScalars: [Unicode.Scalar] = (0x256D...0x2573).map { Unicode.Scalar(UInt32($0))! }

    /// A rasterizer at `pixelSize` and the alpha of a cell pixel (cell coordinates, padding
    /// stripped) of one of its sprites.
    private struct Sprites {
        let metrics: CellMetrics
        let rasterizer: BoxSpriteRasterizer
        var w: Int { metrics.width }
        var h: Int { metrics.height }

        init(_ pixelSize: CGFloat, padding: Int = 2) {
            metrics = BoxSpriteRasterizerTests.metrics(pixelSize)
            rasterizer = BoxSpriteRasterizer(metrics: metrics, padding: padding)
        }

        func sprite(_ scalar: Unicode.Scalar) -> RasterizedGlyph {
            guard let glyph = rasterizer.rasterize(scalar) else {
                Issue.record("no sprite for U+\(String(scalar.value, radix: 16))")
                return RasterizedGlyph(width: 0, height: 0, bytesPerRow: 0, bytesPerPixel: 1,
                                       bearingX: 0, bearingTop: 0, isColor: false, appliedScale: 1, pixels: [])
            }
            return glyph
        }

        func alpha(_ glyph: RasterizedGlyph, _ x: Int, _ y: Int) -> UInt8 {
            let p = rasterizer.padding
            return glyph.pixels[(y + p) * glyph.bytesPerRow + x + p]
        }
    }

    // MARK: - Geometry

    @Test("covers exactly the two synthesized ranges, single scalars only")
    func coverage() {
        #expect(BoxSpriteGeometry.covers("─" as Unicode.Scalar))
        #expect(BoxSpriteGeometry.covers("▟" as Unicode.Scalar))
        #expect(!BoxSpriteGeometry.covers("⠿" as Unicode.Scalar))
        #expect(!BoxSpriteGeometry.covers(["█", "\u{FE0F}"] as [Unicode.Scalar]))
        let geometry = BoxSpriteGeometry(width: 15, height: 33)
        #expect(geometry.primitives(for: "A") == nil)
        #expect(Self.allScalars.count == 160)
        #expect(Self.allScalars.filter(BoxSpriteGeometry.isAntialiased).count == 7)
    }

    @Test("rect sprites are rects only, stroked sprites one stroke", arguments: pixelSizes)
    func primitiveKinds(pixelSize: CGFloat) throws {
        let geometry = BoxSpriteGeometry(metrics: Self.metrics(pixelSize))
        for scalar in Self.allScalars {
            let primitives = try #require(geometry.primitives(for: scalar))
            #expect(!primitives.isEmpty, "U+\(String(scalar.value, radix: 16)) draws nothing")
            let strokes = primitives.filter { if case .stroke = $0 { true } else { false } }
            #expect(strokes.count == (BoxSpriteGeometry.isAntialiased(scalar) ? 1 : 0))
            #expect(strokes.count == 0 || primitives.count == 1)
        }
    }

    @Test("every fill is a non-empty rect inside the cell", arguments: pixelSizes)
    func fillsInsideTheCell(pixelSize: CGFloat) throws {
        let m = Self.metrics(pixelSize)
        let geometry = BoxSpriteGeometry(metrics: m)
        for scalar in Self.allScalars {
            for case let .fill(x, y, w, h, alpha) in try #require(geometry.primitives(for: scalar)) {
                let name = "U+\(String(scalar.value, radix: 16))"
                #expect(w > 0 && h > 0, "\(name)")
                #expect(x >= 0 && y >= 0 && x + w <= m.width && y + h <= m.height, "\(name) \(x),\(y) \(w)x\(h)")
                #expect(alpha == 1 || (0x2591...0x2593).contains(scalar.value), "\(name)")
            }
        }
    }

    @Test("light and heavy strokes: 2 and 4 px at 15 px wide, 2 and 4 at 17, 2 and 4 at 14")
    func thickness() {
        for pixelSize in Self.pixelSizes {
            let geometry = BoxSpriteGeometry(metrics: Self.metrics(pixelSize))
            #expect(geometry.light == 2 && geometry.heavy == 4)
        }
        #expect(BoxSpriteGeometry(width: 4, height: 9).light == 1)
        #expect(BoxSpriteGeometry(width: 4, height: 9).heavy == 2)
        #expect(BoxSpriteGeometry(width: 28, height: 60).light == 4)
    }

    @Test("the arcs end on the line bands, the diagonals run corner to corner")
    func strokeGeometry() throws {
        let geometry = BoxSpriteGeometry(width: 15, height: 33)
        // light 2: the vertical band is x 6..<8 (centre 7), the horizontal y 15..<17 (centre 16).
        guard case let .stroke(path, lineWidth) = try #require(geometry.primitives(for: "╭")?.first) else {
            Issue.record("╭ is not a stroke")
            return
        }
        typealias P = BoxSpriteGeometry.Point
        #expect(lineWidth == 2)
        #expect(path == [.move(to: P(x: 7, y: 33)), .line(to: P(x: 7, y: 21)),
                         .quadCurve(to: P(x: 12, y: 16), control: P(x: 7, y: 16)),
                         .line(to: P(x: 15, y: 16))])
        guard case let .stroke(cross, _) = try #require(geometry.primitives(for: "╳")?.first) else {
            Issue.record("╳ is not a stroke")
            return
        }
        #expect(cross == [.move(to: P(x: 0, y: 0)), .line(to: P(x: 15, y: 33)),
                          .move(to: P(x: 0, y: 33)), .line(to: P(x: 15, y: 0))])
    }

    // MARK: - Bitmaps

    @Test("every codepoint draws something, cell-exact plus padding", arguments: pixelSizes)
    func everyCodepointHasInk(pixelSize: CGFloat) {
        let sprites = Sprites(pixelSize)
        for scalar in Self.allScalars {
            let glyph = sprites.sprite(scalar)
            #expect(glyph.pixels.contains { $0 > 0 }, "U+\(String(scalar.value, radix: 16)) rasterized empty")
            #expect(glyph.width == sprites.w + 4 && glyph.height == sprites.h + 4)
            #expect(glyph.bytesPerRow == glyph.width && glyph.bytesPerPixel == 1)
            #expect(glyph.bearingX == -2 && glyph.bearingTop == sprites.metrics.baseline + 2)
            #expect(glyph.appliedScale == 1 && !glyph.isColor)
        }
    }

    @Test("rect sprites are crisp and never touch the padding", arguments: pixelSizes)
    func rectSpritesAreCrisp(pixelSize: CGFloat) {
        let sprites = Sprites(pixelSize)
        for scalar in Self.allScalars where !BoxSpriteGeometry.isAntialiased(scalar) {
            let glyph = sprites.sprite(scalar)
            let shade = (0x2591...0x2593).contains(scalar.value)
            let allowed: Set<UInt8> = shade ? [[64, 128, 191][Int(scalar.value - 0x2591)]] : [0, 255]
            for y in 0..<glyph.height {
                for x in 0..<glyph.width {
                    let value = glyph.pixels[y * glyph.width + x]
                    let inCell = (2..<(2 + sprites.w)).contains(x) && (2..<(2 + sprites.h)).contains(y)
                    if inCell {
                        #expect(value == 0 || allowed.contains(value), "U+\(String(scalar.value, radix: 16)) (\(x), \(y)) = \(value)")
                    } else {
                        #expect(value == 0, "U+\(String(scalar.value, radix: 16)) inks the padding at (\(x), \(y))")
                    }
                }
            }
        }
    }

    @Test("shades fill the cell flat at CoreGraphics' A8 quantization of 0.25, 0.5 and 0.75")
    func shades() {
        let sprites = Sprites(25)
        for (scalar, expected) in [("░", 64), ("▒", 128), ("▓", 191)] as [(Unicode.Scalar, UInt8)] {
            let glyph = sprites.sprite(scalar)
            for y in 0..<sprites.h {
                for x in 0..<sprites.w {
                    #expect(sprites.alpha(glyph, x, y) == expected)
                }
            }
        }
        #expect(BoxSpriteRasterizer.quantize(0) == 0 && BoxSpriteRasterizer.quantize(1) == 255)
        #expect(BoxSpriteRasterizer.quantize(0.5) == 128 && BoxSpriteRasterizer.quantize(-1) == 0)
    }

    @Test("the full block covers the whole cell", arguments: pixelSizes)
    func fullBlock(pixelSize: CGFloat) {
        let sprites = Sprites(pixelSize)
        let glyph = sprites.sprite("█")
        #expect((0..<sprites.h).allSatisfy { y in (0..<sprites.w).allSatisfy { sprites.alpha(glyph, $0, y) == 255 } })
        #expect(glyph.pixels.filter { $0 == 255 }.count == sprites.w * sprites.h)
    }

    @Test("half blocks and quadrants tile into a full block", arguments: pixelSizes)
    func tiling(pixelSize: CGFloat) {
        let sprites = Sprites(pixelSize)
        let left = sprites.sprite("▌"), right = sprites.sprite("▐")
        let upper = sprites.sprite("▀"), lower = sprites.sprite("▄")
        let quads = ["▘", "▝", "▖", "▗"].map { sprites.sprite($0) }
        for y in 0..<sprites.h {
            for x in 0..<sprites.w {
                let lr = [left, right].filter { sprites.alpha($0, x, y) == 255 }.count
                let ul = [upper, lower].filter { sprites.alpha($0, x, y) == 255 }.count
                let q = quads.filter { sprites.alpha($0, x, y) == 255 }.count
                #expect(lr == 1 && ul == 1 && q == 1, "(\(x), \(y)): \(lr) \(ul) \(q)")
            }
        }
    }

    @Test("the eighth blocks are a monotonic ramp that ends at the full block", arguments: pixelSizes)
    func eighthRamp(pixelSize: CGFloat) {
        let sprites = Sprites(pixelSize)
        var previous = -1
        for value in UInt32(0x2581)...0x2588 {
            let glyph = sprites.sprite(Unicode.Scalar(value)!)
            let filled = (0..<sprites.h).filter { sprites.alpha(glyph, 0, $0) == 255 }.count
            #expect(filled > previous, "U+\(String(value, radix: 16)) did not grow")
            previous = filled
        }
        #expect(previous == sprites.h)
    }

    @Test("lines run edge to edge, corners reach only their own edges, a cross grows no nub")
    func boxDrawing() {
        let sprites = Sprites(25)
        let line = sprites.sprite("─")
        let rows = (0..<sprites.h).filter { sprites.alpha(line, 0, $0) > 0 }
        #expect(rows == [15, 16])
        #expect(rows.allSatisfy { y in (0..<sprites.w).allSatisfy { sprites.alpha(line, $0, y) == 255 } })

        let corner = sprites.sprite("┌")
        let midX = sprites.w / 2, midY = sprites.h / 2
        #expect(sprites.alpha(corner, sprites.w - 1, midY) == 255)
        #expect(sprites.alpha(corner, midX, sprites.h - 1) == 255)
        #expect(sprites.alpha(corner, 0, midY) == 0)
        #expect(sprites.alpha(corner, midX, 0) == 0)

        let cross = sprites.sprite("┼")
        let vertical = (0..<sprites.w).filter { sprites.alpha(cross, $0, 0) > 0 }.count
        #expect(vertical == 2)
        for y in 0..<sprites.h where y < midY - 2 || y > midY + 2 {
            #expect((0..<sprites.w).filter { sprites.alpha(cross, $0, y) > 0 }.count <= vertical)
        }
    }

    // MARK: - Antialiased strokes

    @Test("arcs meet a neighbouring ─ and │ exactly, with butt ends on the cell edge", arguments: pixelSizes)
    func arcsJoinTheirNeighbours(pixelSize: CGFloat) {
        let sprites = Sprites(pixelSize)
        let hLine = sprites.sprite("─"), vLine = sprites.sprite("│")
        let lineRows = (0..<sprites.h).map { sprites.alpha(hLine, 0, $0) }
        let lineColumns = (0..<sprites.w).map { sprites.alpha(vLine, $0, 0) }
        // (scalar, horizontal arm's edge column, vertical arm's edge row)
        let arcs: [(Unicode.Scalar, Int, Int)] = [
            ("╭", sprites.w - 1, sprites.h - 1), ("╮", 0, sprites.h - 1),
            ("╯", 0, 0), ("╰", sprites.w - 1, 0),
        ]
        for (scalar, edgeX, edgeY) in arcs {
            let glyph = sprites.sprite(scalar)
            #expect((0..<sprites.h).map { sprites.alpha(glyph, edgeX, $0) } == lineRows, "\(scalar) row profile")
            #expect((0..<sprites.w).map { sprites.alpha(glyph, $0, edgeY) } == lineColumns, "\(scalar) column profile")
            // Nothing in the padding ring: the caps stop on the cell edge.
            for y in 0..<glyph.height {
                for x in 0..<glyph.width where !((2..<(2 + sprites.w)).contains(x) && (2..<(2 + sprites.h)).contains(y)) {
                    #expect(glyph.pixels[y * glyph.width + x] == 0, "\(scalar) inks the padding at (\(x), \(y))")
                }
            }
            // And the curve between them is antialiased.
            #expect(glyph.pixels.contains { $0 > 0 && $0 < 255 }, "\(scalar) is not antialiased")
        }
    }

    @Test("strokes match a supersampled reference", arguments: pixelSizes)
    func strokesMatchSupersampling(pixelSize: CGFloat) throws {
        let sprites = Sprites(pixelSize)
        let geometry = sprites.rasterizer.geometry
        for scalar in Self.strokedScalars {
            guard case let .stroke(path, lineWidth) = try #require(geometry.primitives(for: scalar)?.first) else {
                Issue.record("U+\(String(scalar.value, radix: 16)) is not a stroke")
                continue
            }
            let glyph = sprites.sprite(scalar)
            let reference = Reference(path: path, lineWidth: lineWidth, cell: (sprites.w, sprites.h))
            var worst = 0, total = 0
            for y in 0..<glyph.height {
                for x in 0..<glyph.width {
                    let expected = reference.coverage(pixelX: x - 2, pixelY: y - 2)
                    let difference = abs(Int(glyph.pixels[y * glyph.width + x]) - Int((expected * 255).rounded()))
                    worst = max(worst, difference)
                    total += difference
                }
            }
            // 256 samples resolve coverage to 1/256; a pixel crossed by two edges can be off by
            // twice that, plus rounding.
            #expect(worst <= 4, "U+\(String(scalar.value, radix: 16)) at \(pixelSize) px: worst \(worst)")
            #expect(Double(total) / Double(glyph.pixels.count) < 0.5, "U+\(String(scalar.value, radix: 16)) mean")
        }
    }

    @Test("╳ is the union of ╱ and ╲, not a double coat", arguments: pixelSizes)
    func crossIsAUnion(pixelSize: CGFloat) {
        let sprites = Sprites(pixelSize)
        let a = sprites.sprite("╱"), b = sprites.sprite("╲"), cross = sprites.sprite("╳")
        for i in cross.pixels.indices {
            let (pa, pb, pc) = (Int(a.pixels[i]), Int(b.pixels[i]), Int(cross.pixels[i]))
            #expect(pc >= max(pa, pb) - 1 && pc <= min(255, pa + pb) + 1)
        }
        // Where both strokes are solid the cross is solid, once.
        let centre = cross.pixels[(cross.height / 2) * cross.width + cross.width / 2]
        #expect(centre == 255)
    }

    @Test("rasterizing is deterministic and padding only translates", arguments: pixelSizes)
    func paddingTranslates(pixelSize: CGFloat) {
        let one = Sprites(pixelSize, padding: 1), two = Sprites(pixelSize, padding: 2)
        for scalar in Self.allScalars {
            let a = one.sprite(scalar), b = two.sprite(scalar)
            #expect(a == one.sprite(scalar))
            // Stroke caps of the diagonals reach past the cell, so compare the cell only.
            for y in 0..<one.h {
                for x in 0..<one.w where one.alpha(a, x, y) != two.alpha(b, x, y) {
                    Issue.record("U+\(String(scalar.value, radix: 16)) differs at (\(x), \(y))")
                }
            }
        }
    }

    // MARK: - Coverage accumulator

    @Test("the accumulator measures exact areas, clipped to the grid")
    func accumulatorAreas() {
        func coverage(_ width: Int, _ height: Int, _ polygons: [[(x: Double, y: Double)]]) -> [Double] {
            var accumulator = CoverageAccumulator(width: width, height: height)
            for polygon in polygons { accumulator.addPolygon(polygon) }
            var out = [Double](repeating: 0, count: width * height)
            accumulator.resolve { out[$0] = $1 }
            return out
        }
        func close(_ a: [Double], _ b: [Double]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }
        }
        // A 2x1 rect offset by half a pixel: quarters at the corners, halves on the edges.
        let rect: [(x: Double, y: Double)] = [(0.5, 0.5), (2.5, 0.5), (2.5, 1.5), (0.5, 1.5)]
        #expect(close(coverage(3, 2, [rect]), [0.25, 0.5, 0.25, 0.25, 0.5, 0.25]))
        // Either orientation fills.
        #expect(close(coverage(3, 2, [rect.reversed()]), [0.25, 0.5, 0.25, 0.25, 0.5, 0.25]))
        // A right triangle over a 2x2 grid: half of each diagonal pixel, all of the one below it.
        let triangle: [(x: Double, y: Double)] = [(0, 0), (2, 2), (0, 2)]
        #expect(close(coverage(2, 2, [triangle]), [0.5, 0, 1, 0.5]))
        // Overlapping same-orientation polygons union; the overlap is not counted twice.
        let square: [(x: Double, y: Double)] = [(0, 0), (2, 0), (2, 1), (0, 1)]
        #expect(close(coverage(2, 1, [square, square]), [1, 1]))
        // Clipping: a rect hanging off every side covers exactly the grid.
        let big: [(x: Double, y: Double)] = [(-3, -2), (5.5, -2), (5.5, 4), (-3, 4)]
        #expect(close(coverage(2, 2, [big]), [1, 1, 1, 1]))
        // A sliver left of the grid and one right of it cover nothing.
        let outside: [[(x: Double, y: Double)]] = [[(-2, 0), (-1, 0), (-1, 1), (-2, 1)],
                                                    [(3, 0), (4, 0), (4, 1), (3, 1)]]
        #expect(close(coverage(2, 1, outside), [0, 0]))
        // A slanted edge crossing three pixel columns and the grid's left edge inside one row:
        // x = 3y - 0.5, so the part left of it inside the grid is ∫ (3y - 0.5) dy over [1/6, 1].
        let slant: [(x: Double, y: Double)] = [(-0.5, 0), (3, 0), (3, 1), (2.5, 1)]
        // Per column: ∫ clamp(c + 1 - max(c, x(y)), 0, 1) dy.
        #expect(close(coverage(3, 1, [slant]), [1.0 / 3, 2.0 / 3, 23.0 / 24]))
    }

    @Test("the overlap of two convex outlines, subtracted once, gives their exact union")
    func convexOverlap() throws {
        // Two unit-wide bars crossing at half-pixel offsets: the overlap is a 1x1 square at
        // (1.5, 0.5), so the union of 2 + 2 px is 3 px and the shared pixels are not over-counted.
        let horizontal: [(x: Double, y: Double)] = [(0.5, 0.5), (2.5, 0.5), (2.5, 1.5), (0.5, 1.5)]
        let vertical: [(x: Double, y: Double)] = [(1.5, -0.5), (2.5, -0.5), (2.5, 1.5), (1.5, 1.5)]
        let overlap = try #require(BoxSpriteRasterizer.convexIntersection(horizontal, vertical))
        var area = 0.0
        for i in overlap.indices {
            let a = overlap[i], b = overlap[(i + 1) % overlap.count]
            area += a.x * b.y - b.x * a.y
        }
        #expect(abs(abs(area) / 2 - 1) < 1e-12)
        var union = CoverageAccumulator(width: 3, height: 2)
        union.addPolygon(horizontal)
        union.addPolygon(vertical)
        union.addPolygon(overlap.reversed())
        var total = 0.0
        union.resolve { total += $1 }
        #expect(abs(total - 2.5) < 1e-9)  // the vertical bar's top half-pixel row is clipped
        // Disjoint, concave or opposite windings have no convex overlap.
        let apart: [(x: Double, y: Double)] = [(5, 5), (6, 5), (6, 6), (5, 6)]
        #expect(BoxSpriteRasterizer.convexIntersection(horizontal, apart) == nil)
        #expect(BoxSpriteRasterizer.convexIntersection(horizontal, vertical.reversed()) == nil)
        let notch: [(x: Double, y: Double)] = [(0, 0), (2, 0), (1, 0.5), (2, 1), (0, 1)]
        #expect(BoxSpriteRasterizer.convexOrientation(notch) == nil)
    }
}

/// The stroke as a point set, independent of the outline the rasterizer fills: within half the
/// line width of the centre line. A diagonal is one butt-capped segment; an arc's centre line is
/// its path flattened 256 ways, cut at the cell edge where its butt ends lie. Pixels near the
/// stroke's edge are sampled 16x16; the rest are wholly in or out.
private struct Reference {
    let segments: [(BoxSpriteGeometry.Point, BoxSpriteGeometry.Point)]
    let half: Double
    let cell: (w: Int, h: Int)
    let isDiagonal: Bool

    init(path: [BoxSpriteGeometry.PathElement], lineWidth: Double, cell: (Int, Int)) {
        var segments: [(BoxSpriteGeometry.Point, BoxSpriteGeometry.Point)] = []
        var pen = BoxSpriteGeometry.Point(x: 0, y: 0)
        var curved = false
        for element in path {
            switch element {
            case .move(let to): pen = to
            case .line(let to): segments.append((pen, to)); pen = to
            case let .quadCurve(to, control):
                curved = true
                let n = 256
                var previous = pen
                for i in 1...n {
                    let t = Double(i) / Double(n), u = 1 - t
                    let point = BoxSpriteGeometry.Point(
                        x: u * u * pen.x + 2 * u * t * control.x + t * t * to.x,
                        y: u * u * pen.y + 2 * u * t * control.y + t * t * to.y)
                    segments.append((previous, point))
                    previous = point
                }
                pen = to
            }
        }
        self.segments = segments
        self.half = lineWidth / 2
        self.cell = cell
        self.isDiagonal = !curved
    }

    /// Inside one segment's butt-capped rectangle (diagonals) or within `half` of the polyline
    /// (arcs, whose only caps lie on the cell edge and are cut there).
    func contains(_ x: Double, _ y: Double) -> Bool {
        for (a, b) in segments {
            let dx = b.x - a.x, dy = b.y - a.y
            let length2 = dx * dx + dy * dy
            var t = ((x - a.x) * dx + (y - a.y) * dy) / length2
            if isDiagonal {
                guard t >= 0, t <= 1 else { continue }
            } else {
                t = min(1, max(0, t))
            }
            let px = a.x + t * dx - x, py = a.y + t * dy - y
            if px * px + py * py <= half * half { return true }
        }
        return false
    }

    /// Distance from `(x, y)` to the nearest segment, ignoring the caps.
    func distance(_ x: Double, _ y: Double) -> Double {
        var best = Double.infinity
        for (a, b) in segments {
            let dx = b.x - a.x, dy = b.y - a.y
            let t = min(1, max(0, ((x - a.x) * dx + (y - a.y) * dy) / (dx * dx + dy * dy)))
            let px = a.x + t * dx - x, py = a.y + t * dy - y
            best = min(best, px * px + py * py)
        }
        return best.squareRoot()
    }

    func coverage(pixelX: Int, pixelY: Int) -> Double {
        // A pixel reaches at most √½ px from its centre: farther than that from the stroke's edge,
        // it is all out, or all in unless a cap or the cell edge cuts it.
        let d = distance(Double(pixelX) + 0.5, Double(pixelY) + 0.5)
        if d > half + 0.75 { return 0 }
        let n = 16
        var inside = 0
        for sy in 0..<n {
            for sx in 0..<n {
                let x = Double(pixelX) + (Double(sx) + 0.5) / Double(n)
                let y = Double(pixelY) + (Double(sy) + 0.5) / Double(n)
                if !isDiagonal, x < 0 || y < 0 || x > Double(cell.w) || y > Double(cell.h) { continue }
                if contains(x, y) { inside += 1 }
            }
        }
        return Double(inside) / Double(n * n)
    }
}
