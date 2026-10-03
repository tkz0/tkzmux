// RasterizerTests — the A8 outline rasterizer (WOR-312 S5): placement from the exact outline box,
// exact-area coverage, the dilation that stands in for CoreGraphics smoothing, synthetic bold, and
// the 2048² page timing.
//
// JetBrains Mono's U+2588 FULL BLOCK and U+2596 QUADRANT LOWER LEFT are axis-aligned rectangles,
// so their coverage, and how the dilation and the emboldening grow them, can be checked against
// plain arithmetic.

import CFreeType
import Foundation
import Testing
import TkzRenderCore
@testable import TkzFontsFT

/// Coverage statistics of an A8 bitmap.
struct Ink {
    /// Σ coverage / 255: the covered area in pixels.
    let area: Double
    /// Coverage-weighted centre, in bitmap pixels (x right, y down).
    let centerX: Double
    let centerY: Double
    /// The rows and columns with any coverage.
    let minX: Int, maxX: Int, minY: Int, maxY: Int

    init(_ glyph: RasterizedGlyph) {
        precondition(glyph.bytesPerPixel == 1)
        var area = 0.0, sx = 0.0, sy = 0.0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<glyph.height {
            for x in 0..<glyph.width {
                let c = Double(glyph.pixels[y * glyph.bytesPerRow + x]) / 255
                guard c > 0 else { continue }
                area += c
                sx += c * (Double(x) + 0.5)
                sy += c * (Double(y) + 0.5)
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        self.area = area
        self.centerX = area > 0 ? sx / area : 0
        self.centerY = area > 0 ? sy / area : 0
        self.minX = minX; self.maxX = maxX; self.minY = minY; self.maxY = maxY
    }

    /// Ink centre relative to the pen origin, y up, so bitmaps with different paddings compare.
    func center(of glyph: RasterizedGlyph) -> (x: Double, y: Double) {
        (Double(glyph.bearingX) + centerX, Double(glyph.bearingTop) - centerY)
    }
}

@Suite("FreeType rasterizer")
struct RasterizerTests {
    static let block: Unicode.Scalar = "\u{2588}"
    /// U+2596 QUADRANT LOWER LEFT: a rectangle a quarter of the cell.
    static let quadrant: Unicode.Scalar = "\u{2596}"

    func faces(_ pointSize: CGFloat = 14, _ scale: CGFloat = 1.6) throws -> TerminalFaces {
        try TerminalFaces(pointSize: pointSize, scale: scale, fallback: ColorFixtures.fallback)
    }

    func raster(_ faces: TerminalFaces, _ scalar: Unicode.Scalar, style: FontStyle = .regular,
                _ options: RasterizerOptions) throws -> RasterizedGlyph {
        let shaped = faces.shape([scalar], style: style)
        return try #require(faces.rasterize(shaped, style: style, options: options), "\(scalar)")
    }

    // MARK: Placement

    @Test("the bitmap is the outline box rounded outwards plus the padding")
    func placementFromOutlineBox() throws {
        let faces = try faces()
        for scalar in ["H", "g", "j", "@", "_"] as [Unicode.Scalar] {
            let box = try #require(faces.outlineMetrics(of: scalar, style: .regular))
            let glyph = try raster(faces, scalar, RasterizerOptions(thicken: false))
            #expect(glyph.bytesPerPixel == 1 && !glyph.isColor && glyph.appliedScale == 1)
            #expect(glyph.bearingX == Int(box.xMin.rounded(.down)) - 1, "\(scalar)")
            #expect(glyph.bearingTop == Int(box.yMax.rounded(.up)) + 1, "\(scalar)")
            #expect(glyph.width == Int(box.xMax.rounded(.up)) - Int(box.xMin.rounded(.down)) + 2, "\(scalar)")
            #expect(glyph.height == Int(box.yMax.rounded(.up)) - Int(box.yMin.rounded(.down)) + 2, "\(scalar)")
            // The padding stays transparent.
            let ink = Ink(glyph)
            #expect(ink.minX >= 1 && ink.minY >= 1 && ink.maxX <= glyph.width - 2 && ink.maxY <= glyph.height - 2, "\(scalar)")
        }
    }

    @Test("nothing to draw: a space rasterizes to nil")
    func emptyClusters() throws {
        let faces = try faces()
        #expect(faces.rasterize(faces.shape([" "]), options: RasterizerOptions(thicken: true)) == nil)
    }

    @Test("a wide glyph that overflows its box is scaled to fit it",
          .enabled(if: ColorFixtures.fallback.faces(in: .text(.regular)).contains { $0.family == "Noto Sans CJK SC" },
                   "needs Noto Sans CJK SC (system or parity fonts)"))
    func fitScale() throws {
        let faces = try faces(14, 2)
        // U+2588 is one cell wide by its advance, so asking for one cell with a 2-cell-wide box
        // would not scale; instead squeeze a CJK ideograph (drawn ~28 px wide) into one cell.
        let shaped = faces.shape(["你"], cellSpan: 1)
        let glyph = try #require(faces.rasterize(shaped, options: RasterizerOptions(thicken: false)))
        #expect(glyph.appliedScale < 1)
        #expect(glyph.width - 2 <= faces.metrics.width)
        #expect(glyph.height - 2 <= faces.metrics.height)
    }

    // MARK: Coverage

    @Test("exact-area anti-aliasing: a rectangle's coverage sums to its area, its inside is opaque")
    func exactArea() throws {
        let faces = try faces()
        let box = try #require(faces.outlineMetrics(of: Self.block, style: .regular))
        let glyph = try raster(faces, Self.block, RasterizerOptions(thicken: false))
        let ink = Ink(glyph)
        let expected = Double(box.width * box.height)
        #expect(abs(ink.area - expected) / expected < 0.002, "area \(ink.area), outline \(expected)")
        #expect(glyph.pixels[(glyph.height / 2) * glyph.bytesPerRow + glyph.width / 2] == 255)
    }

    @Test("without thicken, a glyph is pixel-identical to FreeType's own FT_Render_Glyph of the same outline")
    func matchesFreeTypeRenderer() throws {
        let faces = try faces()
        let library = try FreeTypeLibrary()
        let face = try FreeTypeFace(library: library, url: try #require(BundledFonts.directory)
            .appendingPathComponent(BundledFonts.jetBrainsMonoFile(.regular)))
        try face.requestPixelSize(faces.pixelSize)
        for scalar in ["H", "o", "g", "&", "W"] as [Unicode.Scalar] {
            let ours = try raster(faces, scalar, RasterizerOptions(thicken: false))
            let glyph = FT_Get_Char_Index(face.handle, FT_ULong(scalar.value))
            try #require(FT_Load_Glyph(face.handle, glyph, FreeTypeFace.loadFlags) == 0)
            let slot = try #require(face.handle.pointee.glyph)
            try #require(FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) == 0)
            let bitmap = slot.pointee.bitmap
            let left = Int(slot.pointee.bitmap_left), top = Int(slot.pointee.bitmap_top)
            // Compare over the union of both bitmaps, aligned on the pen origin (y up).
            func theirs(_ x: Int, _ yUp: Int) -> UInt8 {
                let column = x - left, row = top - 1 - yUp
                guard column >= 0, column < Int(bitmap.width), row >= 0, row < Int(bitmap.rows) else { return 0 }
                return bitmap.buffer[row * Int(bitmap.pitch) + column]
            }
            func mine(_ x: Int, _ yUp: Int) -> UInt8 {
                let column = x - ours.bearingX, row = ours.bearingTop - 1 - yUp
                guard column >= 0, column < ours.width, row >= 0, row < ours.height else { return 0 }
                return ours.pixels[row * ours.bytesPerRow + column]
            }
            var differing = 0
            for yUp in min(top - Int(bitmap.rows), ours.bearingTop - ours.height)..<max(top, ours.bearingTop) {
                for x in min(left, ours.bearingX)..<max(left + Int(bitmap.width), ours.bearingX + ours.width)
                where mine(x, yUp) != theirs(x, yUp) {
                    differing += 1
                }
            }
            #expect(differing == 0, "\(scalar): \(differing) pixels differ")
        }
    }

    @Test("a two-glyph cluster composites both glyphs")
    func multiGlyphCluster() throws {
        let faces = try faces()
        // x + U+0301: HarfBuzz cannot compose it into one precomposed glyph, as it would 'é'.
        let combined = faces.shape(["x", "\u{301}"])
        #expect(combined.glyphs.count == 2)
        let options = RasterizerOptions(thicken: false)
        let both = Ink(try #require(faces.rasterize(combined, options: options)))
        let x = Ink(try raster(faces, "x", options))
        #expect(both.area > x.area * 1.05)
    }

    // MARK: Dilation

    @Test("Pathfinder's starting radii, capped at 0.3 px, and none above 72 ppem")
    func pathfinderRadii() {
        let at22 = Dilation.pathfinder(pixelSize: 22.4)
        #expect(abs(at22.rx - 0.27104) < 1e-9 && at22.ry == 0.3)
        #expect(at22.halfStrength26Dot6.x == 17 && at22.halfStrength26Dot6.y == 19)
        #expect(Dilation.pathfinder(pixelSize: 25) == Dilation(rx: 0.3, ry: 0.3))
        let at12 = Dilation.pathfinder(pixelSize: 12)
        #expect(abs(at12.rx - 0.1452) < 1e-9 && abs(at12.ry - 0.1815) < 1e-9)
        #expect(Dilation.pathfinder(pixelSize: 72) != .none)
        #expect(Dilation.pathfinder(pixelSize: 72.5) == .none)
        #expect(RasterizerOptions(thicken: true, dilation: Dilation(rx: 0.5, ry: 0.5)).effectiveDilation(pixelSize: 80) == .none)
        #expect(RasterizerOptions(thicken: false).effectiveDilation(pixelSize: 25) == .none)
        #expect(RasterizerOptions(thicken: true).padding == 2 && RasterizerOptions(thicken: false).padding == 1)
    }

    @Test("dilation grows every edge by r and keeps the glyph centred")
    func dilationIsCentred() throws {
        let faces = try faces()
        let box = try #require(faces.outlineMetrics(of: Self.block, style: .regular))
        let dilation = Dilation(rx: 0.25, ry: 0.375)  // whole 64ths, so no 26.6 rounding
        let plain = try raster(faces, Self.block, RasterizerOptions(thicken: false))
        let thick = try raster(faces, Self.block, RasterizerOptions(thicken: true, dilation: dilation))
        #expect(thick.width == plain.width + 2 && thick.height == plain.height + 2)  // one more pixel of padding
        let expected = Double((box.width + 2 * dilation.rx) * (box.height + 2 * dilation.ry))
        let ink = Ink(thick)
        #expect(abs(ink.area - expected) / expected < 0.002, "area \(ink.area), expected \(expected)")
        let before = Ink(plain).center(of: plain), after = ink.center(of: thick)
        #expect(abs(before.x - after.x) < 0.05 && abs(before.y - after.y) < 0.05, "\(before) → \(after)")
    }

    @Test("no dilation above 72 ppem: thicken changes only the padding")
    func noDilationAbove72() throws {
        let faces = try faces(40, 2)
        let plain = Ink(try raster(faces, "H", RasterizerOptions(thicken: false)))
        let thick = Ink(try raster(faces, "H", RasterizerOptions(thicken: true)))
        #expect(plain.area == thick.area)
    }

    @Test("thicken adds coverage at every terminal size (logs the on/off ratio S6 calibrates)")
    func thickenRatio() throws {
        for (point, scale) in [(12.5, 2.0), (14, 2), (14, 1.6)] as [(CGFloat, CGFloat)] {
            let faces = try faces(point, scale)
            var off = 0.0, on = 0.0
            for code in 0x21...0x7E {
                let scalar = Unicode.Scalar(code)!
                off += Ink(try raster(faces, scalar, RasterizerOptions(thicken: false))).area
                on += Ink(try raster(faces, scalar, RasterizerOptions(thicken: true))).area
            }
            let ratio = on / off
            print("thicken coverage ratio at \(point * scale) px: \(String(format: "%.4f", ratio))")
            #expect(ratio > 1.05 && ratio < 1.4)
        }
    }

    // MARK: Synthetic bold

    @Test("synthetic bold grows every edge by w/2, with w = max(1, 0.03 px)")
    func syntheticBold() throws {
        let faces = try faces(14, 2)
        #expect(faces.needsSyntheticBold == false)  // the bundled family has a real bold
        let width = RasterizerOptions.syntheticBoldWidth(pixelSize: 28)
        #expect(width == 1)  // 0.03 · 28 = 0.84 → the 1 px floor
        #expect(abs(RasterizerOptions.syntheticBoldWidth(pixelSize: 50) - 1.5) < 1e-12)

        // A quadrant, so the emboldened box still fits the cell and no fit scale gets in the way.
        let box = try #require(faces.outlineMetrics(of: Self.quadrant, style: .bold))
        let real = try raster(faces, Self.quadrant, style: .bold, RasterizerOptions(thicken: false))
        let synthetic = try raster(faces, Self.quadrant, style: .bold, RasterizerOptions(thicken: false, syntheticBold: true))
        #expect(real.appliedScale == 1 && synthetic.appliedScale == 1)
        // The placement outsets the union by the whole stroke width on each side, as on the Mac.
        #expect(synthetic.width == real.width + 2 && synthetic.height == real.height + 2)
        let expected = Double((box.width + width) * (box.height + width))
        let ink = Ink(synthetic)
        #expect(abs(ink.area - expected) / expected < 0.002, "area \(ink.area), expected \(expected)")
        let before = Ink(real).center(of: real), after = ink.center(of: synthetic)
        // Not re-centred, the centre would move by w/2 = 0.5 px. (The coverage-weighted centre is
        // itself biased by a few hundredths by partial edge pixels.)
        #expect(abs(before.x - after.x) < 0.05 && abs(before.y - after.y) < 0.05, "\(before) → \(after)")
        // Regular styles never get it.
        let regular = try raster(faces, Self.quadrant, style: .regular, RasterizerOptions(thicken: false, syntheticBold: true))
        #expect(regular == (try raster(faces, Self.quadrant, style: .regular, RasterizerOptions(thicken: false))))
    }

    // MARK: Determinism and timing

    @Test("rasterizing is deterministic across instances")
    func deterministic() throws {
        let a = try faces(), b = try faces()
        for scalar in ["a", "W", "%"] as [Unicode.Scalar] {
            for style in FontStyle.allCases {
                #expect(try raster(a, scalar, style: style, RasterizerOptions()) == raster(b, scalar, style: style, RasterizerOptions()))
            }
        }
    }

    /// Glyphs until a 2048² A8 page is full: ASCII and Latin-1/Latin Extended-A in four styles at
    /// several sizes. The figure goes to the log; it is asserted (< 40 ms) only when
    /// `TKZMUX_ASSERT_RASTER_TIMING=1` and in a release build, i.e. on the dev machine.
    @Test("a 2048² page of glyphs rasterizes in under 40 ms (release, dev machine)")
    func pageTiming() throws {
        let scalars = (0x21...0x7E).map { Unicode.Scalar($0)! } + (0xA1...0x17F).compactMap { Unicode.Scalar($0) }
        var stacks: [TerminalFaces] = []
        for point in stride(from: 10.0, through: 30.0, by: 1.0) { stacks.append(try faces(CGFloat(point), 2)) }
        // Shape first: the page times the rasterizer, not shaping or fallback.
        var work: [(TerminalFaces, ShapedCluster, FontStyle)] = []
        var pixels = 0
        outer: for faces in stacks {
            for style in FontStyle.allCases {
                for scalar in scalars {
                    let shaped = faces.shape([scalar], style: style)
                    guard faces.name(of: shaped.face).hasPrefix("JetBrainsMono") else { continue }
                    work.append((faces, shaped, style))
                    // Estimated slot area (cell plus padding) so the page is about full.
                    pixels += (faces.metrics.width + 4) * (faces.metrics.height + 4) / 2
                    if pixels >= 2048 * 2048 { break outer }
                }
            }
        }
        let options = RasterizerOptions(thicken: true)
        var page = AtlasPage(kind: "grayscale", size: 2048, bytesPerPixel: 1)
        let clock = ContinuousClock()
        var packed = 0
        let elapsed = clock.measure {
            for (faces, shaped, style) in work {
                guard let glyph = faces.rasterize(shaped, style: style, options: options) else { continue }
                if page.insert(glyph) != nil { packed += 1 }
            }
        }
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("2048² page: \(packed) glyphs of \(work.count) in \(String(format: "%.1f", ms)) ms")
        #expect(packed > 0)
        #if !DEBUG
        if ProcessInfo.processInfo.environment["TKZMUX_ASSERT_RASTER_TIMING"] == "1" {
            #expect(ms < 40)
        }
        #endif
    }
}
