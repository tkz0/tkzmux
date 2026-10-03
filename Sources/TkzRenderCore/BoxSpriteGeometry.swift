// BoxSpriteGeometry — box-drawing and block-element sprites as plain geometry (WOR-311 S3, S5).
//
// U+2500…U+257F (box drawing) and U+2580…U+259F (block elements) are the two ranges a terminal has
// to draw itself. A font lays its own versions out on the em box, not on the terminal cell, so
// adjacent cells never tile: `█` next to `█` leaves a seam (the Claude Code banner logo turns into
// stripes), the eighth-blocks do not line up into a ramp, and `┌──┐` corners miss each other by a
// pixel. Ghostty, kitty and Terminal.app all synthesize these; so do we.
//
// This file decides *what* each sprite is, in cell coordinates (origin at the cell's top-left
// corner, y growing downward, (width, height) at the bottom-right): a list of integer rects filled
// with antialiasing off, and for the arcs and diagonals one antialiased stroke. Two painters replay
// it — the Mac's CoreGraphics `BoxSprites` (TkzTerminalRender) and the pure-Swift
// `BoxSpriteRasterizer` here — so both draw the same rects from the same arithmetic. The rect
// sprites come out byte-identical; the seven stroked ones differ only in antialiasing.
//
// `GlyphCache` asks `covers` before it looks anything up, so a sprite is keyed once for every
// style and never shaped.
//
// The arithmetic is the drawing code's from before the split, operation for operation (Double is
// CGFloat on 64-bit Darwin), so the Mac bitmaps do not move.

/// The geometry of every box-drawing and block-element sprite for one cell size.
public struct BoxSpriteGeometry: Sendable, Equatable {
    /// Cell size in device pixels.
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init(metrics: CellMetrics) {
        self.init(width: metrics.width, height: metrics.height)
    }

    // MARK: - Coverage

    /// True for the single-scalar clusters drawn as sprites.
    public static func covers(_ scalars: [Unicode.Scalar]) -> Bool {
        scalars.count == 1 && covers(scalars[0])
    }

    public static func covers(_ scalar: Unicode.Scalar) -> Bool {
        (0x2500...0x259F).contains(scalar.value)
    }

    /// True for the sprites drawn with an antialiased stroke: the arcs U+256D…U+2570 and the
    /// diagonals U+2571…U+2573. Every other sprite is integer rects only.
    public static func isAntialiased(_ scalar: Unicode.Scalar) -> Bool {
        (0x256D...0x2573).contains(scalar.value)
    }

    // MARK: - Primitives

    /// A point in cell coordinates, y down.
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// One step of a stroked path.
    public enum PathElement: Sendable, Equatable {
        /// Starts a new subpath.
        case move(to: Point)
        case line(to: Point)
        /// A quadratic Bézier from the current point.
        case quadCurve(to: Point, control: Point)
    }

    /// One drawing operation, in order.
    public enum Primitive: Sendable, Equatable {
        /// An integer rect filled with antialiasing off at `alpha` (1, or 0.25 / 0.5 / 0.75 for
        /// the shades). Never empty.
        case fill(x: Int, y: Int, width: Int, height: Int, alpha: Double)
        /// One path stroked at full alpha with antialiasing on, butt caps, the default miter join
        /// and `lineWidth` px. Every subpath of `path` is part of the same stroke, so where two of
        /// them cross (`╳`) the ink is their union, not a double coat.
        case stroke(path: [PathElement], lineWidth: Double)
    }

    /// The drawing operations for `scalar`, or `nil` when it is outside the covered ranges.
    public func primitives(for scalar: Unicode.Scalar) -> [Primitive]? {
        guard BoxSpriteGeometry.covers(scalar) else { return nil }
        var out: [Primitive] = []
        let value = scalar.value
        if value >= 0x2580 {
            block(value, &out)
        } else {
            box(value, &out)
        }
        return out
    }

    // MARK: - Metrics

    private var w: Int { width }
    private var h: Int { height }

    /// Line thickness of a "light" stroke, in device pixels.
    public var light: Int { max(1, Int((Double(w) / 8).rounded())) }
    /// "Heavy" is twice light, but always at least one pixel more.
    public var heavy: Int { max(light + 1, light * 2) }

    /// n/8 of the cell width, rounded to the nearest pixel. `eighthX(8) == w` exactly, which is what
    /// makes `▌` + `▐` and the eighth-block ramp tile without a seam or an overlap.
    private func eighthX(_ n: Int) -> Int { n >= 8 ? w : (w * n + 4) / 8 }
    private func eighthY(_ n: Int) -> Int { n >= 8 ? h : (h * n + 4) / 8 }

    /// A band of `thickness` px centred on `center`.
    private func band(_ center: Int, _ thickness: Int) -> (start: Int, end: Int) {
        let start = center - thickness / 2
        return (start, start + thickness)
    }

    /// The continuous-coordinate centre of `band`, for strokes that have to line up with fills.
    private func bandCentre(_ center: Int, _ thickness: Int) -> Double {
        Double(band(center, thickness).start) + Double(thickness) / 2
    }

    private func fill(_ out: inout [Primitive], _ x: Int, _ y: Int, _ width: Int, _ height: Int,
                      alpha: Double = 1) {
        guard width > 0, height > 0 else { return }
        out.append(.fill(x: x, y: y, width: width, height: height, alpha: alpha))
    }

    // MARK: - Block elements (U+2580…U+259F)

    /// Which quadrants each of U+2596…U+259F fills: 1 = upper left, 2 = upper right,
    /// 4 = lower left, 8 = lower right.
    private static let quadrantMask: [UInt8] = [
        0b0100,  // 2596 ▖ lower left
        0b1000,  // 2597 ▗ lower right
        0b0001,  // 2598 ▘ upper left
        0b1101,  // 2599 ▙ upper left, lower left, lower right
        0b1001,  // 259A ▚ upper left, lower right
        0b0111,  // 259B ▛ upper left, upper right, lower left
        0b1011,  // 259C ▜ upper left, upper right, lower right
        0b0010,  // 259D ▝ upper right
        0b0110,  // 259E ▞ upper right, lower left
        0b1110,  // 259F ▟ upper right, lower left, lower right
    ]

    private func block(_ value: UInt32, _ out: inout [Primitive]) {
        switch value {
        case 0x2580:  // ▀ upper half
            fill(&out, 0, 0, w, eighthY(4))
        case 0x2581...0x2588:  // ▁…█ lower one eighth … full block
            // Measured from the *top* edge down, so `▄` is the exact complement of `▀` rather than
            // overlapping it by the rounding of two independent halves.
            let top = eighthY(8 - Int(value - 0x2580))
            fill(&out, 0, top, w, h - top)
        case 0x2589...0x258F:  // ▉…▏ left seven eighths … left one eighth
            fill(&out, 0, 0, eighthX(8 - Int(value - 0x2588)), h)
        case 0x2590:  // ▐ right half
            let x = eighthX(4)
            fill(&out, x, 0, w - x, h)
        case 0x2591, 0x2592, 0x2593:  // ░▒▓ light / medium / dark shade
            // Flat coverage rather than a dot pattern: it tiles seamlessly and reads as an even
            // tint at 12.5 pt, which is what shades are used for (gradients, dimmed fills).
            fill(&out, 0, 0, w, h, alpha: [0.25, 0.5, 0.75][Int(value - 0x2591)])
        case 0x2594:  // ▔ upper one eighth
            fill(&out, 0, 0, w, eighthY(1))
        case 0x2595:  // ▕ right one eighth
            let x = eighthX(7)
            fill(&out, x, 0, w - x, h)
        case 0x2596...0x259F:
            let mask = BoxSpriteGeometry.quadrantMask[Int(value - 0x2596)]
            let hx = eighthX(4)
            let hy = eighthY(4)
            if mask & 0b0001 != 0 { fill(&out, 0, 0, hx, hy) }
            if mask & 0b0010 != 0 { fill(&out, hx, 0, w - hx, hy) }
            if mask & 0b0100 != 0 { fill(&out, 0, hy, hx, h - hy) }
            if mask & 0b1000 != 0 { fill(&out, hx, hy, w - hx, h - hy) }
        default:
            break
        }
    }

    // MARK: - Box drawing (U+2500…U+257F)

    enum ArmStyle: UInt8 {
        case none, light, heavy, double

        init(_ char: Character) {
            switch char {
            case "l": self = .light
            case "h": self = .heavy
            case "d": self = .double
            default: self = .none
            }
        }

        var isSet: Bool { self != .none }
    }

    /// One "URDL" code (up, right, down, left) per codepoint from U+2500:
    /// `.` none, `l` light, `h` heavy, `d` double. Dashes (2504–250B, 254C–254F), arcs (256D–2570)
    /// and diagonals (2571–2573) are drawn by hand and their entries here are never read.
    static let boxArms: [String] = [
        ".l.l", ".h.h", "l.l.", "h.h.", "....", "....", "....", "....",  // 2500 ─━│┃┄┅┆┇
        "....", "....", "....", "....", ".ll.", ".hl.", ".lh.", ".hh.",  // 2508 ┈┉┊┋┌┍┎┏
        "..ll", "..lh", "..hl", "..hh", "ll..", "lh..", "hl..", "hh..",  // 2510 ┐┑┒┓└┕┖┗
        "l..l", "l..h", "h..l", "h..h", "lll.", "lhl.", "hll.", "llh.",  // 2518 ┘┙┚┛├┝┞┟
        "hlh.", "hhl.", "lhh.", "hhh.", "l.ll", "l.lh", "h.ll", "l.hl",  // 2520 ┠┡┢┣┤┥┦┧
        "h.hl", "h.lh", "l.hh", "h.hh", ".lll", ".llh", ".hll", ".hlh",  // 2528 ┨┩┪┫┬┭┮┯
        ".lhl", ".lhh", ".hhl", ".hhh", "ll.l", "ll.h", "lh.l", "lh.h",  // 2530 ┰┱┲┳┴┵┶┷
        "hl.l", "hl.h", "hh.l", "hh.h", "llll", "lllh", "lhll", "lhlh",  // 2538 ┸┹┺┻┼┽┾┿
        "hlll", "llhl", "hlhl", "hllh", "hhll", "llhh", "lhhl", "hhlh",  // 2540 ╀╁╂╃╄╅╆╇
        "lhhh", "hlhh", "hhhl", "hhhh", "....", "....", "....", "....",  // 2548 ╈╉╊╋╌╍╎╏
        ".d.d", "d.d.", ".dl.", ".ld.", ".dd.", "..ld", "..dl", "..dd",  // 2550 ═║╒╓╔╕╖╗
        "ld..", "dl..", "dd..", "l..d", "d..l", "d..d", "ldl.", "dld.",  // 2558 ╘╙╚╛╜╝╞╟
        "ddd.", "l.ld", "d.dl", "d.dd", ".dld", ".ldl", ".ddd", "ld.d",  // 2560 ╠╡╢╣╤╥╦╧
        "dl.l", "dd.d", "ldld", "dldl", "dddd", "....", "....", "....",  // 2568 ╨╩╪╫╬╭╮╯
        "....", "....", "....", "....", "...l", "l...", ".l..", "..l.",  // 2570 ╰╱╲╳╴╵╶╷
        "...h", "h...", ".h..", "..h.", ".h.l", "l.h.", ".l.h", "h.l.",  // 2578 ╸╹╺╻╼╽╾╿
    ]

    private func box(_ value: UInt32, _ out: inout [Primitive]) {
        switch value {
        case 0x2504...0x2507: return dashes(count: 3, value: value, base: 0x2504, &out)
        case 0x2508...0x250B: return dashes(count: 4, value: value, base: 0x2508, &out)
        case 0x254C...0x254F: return dashes(count: 2, value: value, base: 0x254C, &out)
        case 0x256D...0x2570: return out.append(arc(value))
        case 0x2571...0x2573: return out.append(diagonal(value))
        default: break
        }

        let code = Array(BoxSpriteGeometry.boxArms[Int(value - 0x2500)])
        let arms = code.map(ArmStyle.init)  // up, right, down, left
        solidArms(arms, &out)
        doubleRails(arms, &out)
    }

    /// Light and heavy arms: one rect per direction, every rect extended into a shared central
    /// junction so a corner or a tee joins without a notch.
    private func solidArms(_ arms: [ArmStyle], _ out: inout [Primitive]) {
        func thickness(_ style: ArmStyle) -> Int? {
            switch style {
            case .light: return light
            case .heavy: return heavy
            case .none, .double: return nil
            }
        }
        let solid = arms.map(thickness)
        guard solid.contains(where: { $0 != nil }) else { return }

        let cx = w / 2
        let cy = h / 2
        // Each arm stops exactly on the far edge of the perpendicular arm's band, so a corner or a
        // tee joins flush — one pixel more and every junction grows a visible nub. With no
        // perpendicular arm (a half line like `╴`) the arm's own band is the stop instead.
        let vThickness = max(solid[0] ?? 0, solid[2] ?? 0)
        let hThickness = max(solid[1] ?? 0, solid[3] ?? 0)
        let hasVBand = vThickness > 0
        let hasHBand = hThickness > 0
        let vBand = band(cx, vThickness)
        let hBand = band(cy, hThickness)

        // A single line that runs straight through (arms on both sides) always crosses the rails —
        // that is what `╪` and `╫` look like. One that *ends* at a double line stops at the near
        // rail if the double runs through (`╧`), or reaches the far rail to close a corner (`╘`).
        let vSolidThrough = solid[0] != nil && solid[2] != nil
        let hSolidThrough = solid[1] != nil && solid[3] != nil
        let vDouble = (arms[0] == .double || arms[2] == .double) && !hSolidThrough
        let hDouble = (arms[1] == .double || arms[3] == .double) && !vSolidThrough
        let hThrough = arms[1] == .double && arms[3] == .double
        let vThrough = arms[0] == .double && arms[2] == .double
        let offset = railOffset

        if let t = solid[0] {  // up
            let x = band(cx, t)
            let stop = hasHBand ? hBand.end : band(cy, t).end
            let bottom = hDouble ? (hThrough ? cy - offset : cy + offset) : stop
            fill(&out, x.start, 0, t, max(0, bottom))
        }
        if let t = solid[2] {  // down
            let x = band(cx, t)
            let stop = hasHBand ? hBand.start : band(cy, t).start
            let top = hDouble ? (hThrough ? cy + offset : cy - offset) : stop
            fill(&out, x.start, top, t, max(0, h - top))
        }
        if let t = solid[3] {  // left
            let y = band(cy, t)
            let stop = hasVBand ? vBand.end : band(cx, t).end
            let right = vDouble ? (vThrough ? cx - offset : cx + offset) : stop
            fill(&out, 0, y.start, max(0, right), t)
        }
        if let t = solid[1] {  // right
            let y = band(cy, t)
            let stop = hasVBand ? vBand.start : band(cx, t).start
            let left = vDouble ? (vThrough ? cx + offset : cx - offset) : stop
            fill(&out, left, y.start, max(0, w - left), t)
        }
    }

    /// Centre-to-centre distance from the cell axis to each rail of a double line: the pair spans
    /// `3 * light` px, two rails of `light` with a `light` gap between them.
    private var railOffset: Int { light }

    /// Double arms: two parallel rails per axis, each rail clipped where it meets the other axis so
    /// `╔` closes at the corner and `╬` leaves the four inner gaps open.
    private func doubleRails(_ arms: [ArmStyle], _ out: inout [Primitive]) {
        // up, right, down, left → (near, far) per axis, in the transposed helper's terms.
        if arms[1] == .double || arms[3] == .double {
            rails(&out, transposed: false,
                  lowSide: arms[3] == .double, highSide: arms[1] == .double,
                  crossLow: arms[0], crossHigh: arms[2])
        }
        if arms[0] == .double || arms[2] == .double {
            rails(&out, transposed: true,
                  lowSide: arms[0] == .double, highSide: arms[2] == .double,
                  crossLow: arms[3], crossHigh: arms[1])
        }
    }

    /// The two rails of one axis.
    ///
    /// Coordinates are "along" (the axis the rails run on) and "across". `transposed` swaps them, so
    /// the same code draws `═` and `║`. `lowSide` / `highSide` say whether the arm exists towards
    /// along = 0 and along = max; `crossLow` / `crossHigh` are the two arms of the other axis.
    private func rails(_ out: inout [Primitive],
                       transposed: Bool,
                       lowSide: Bool,
                       highSide: Bool,
                       crossLow: ArmStyle,
                       crossHigh: ArmStyle) {
        let alongMax = transposed ? h : w
        let acrossMax = transposed ? w : h
        let centre = acrossMax / 2
        let crossCentre = alongMax / 2
        let offset = railOffset
        let crossDouble = crossLow == .double || crossHigh == .double
        let light = self.light

        func put(_ alongStart: Int, _ alongEnd: Int, _ acrossCentre: Int) {
            guard alongEnd > alongStart else { return }
            let a = band(acrossCentre, light)
            if transposed {
                fill(&out, a.start, alongStart, light, alongEnd - alongStart)
            } else {
                fill(&out, alongStart, a.start, alongEnd - alongStart, light)
            }
        }

        for side in [-1, 1] {  // -1 = the rail nearer across = 0, +1 = the far one
            let acrossCentre = centre + side * offset

            guard crossDouble else {
                // Nothing double crosses: the rail runs from edge to edge, or stops at the axis when
                // there is no arm on that side.
                let start = lowSide ? 0 : crossCentre
                let end = highSide ? alongMax : crossCentre
                put(start, end, acrossCentre)
                continue
            }

            if crossLow == .double && crossHigh == .double {
                // A through line crosses: the rail is interrupted between the two crossing rails.
                if lowSide { put(0, crossCentre - offset, acrossCentre) }
                if highSide { put(crossCentre + offset, alongMax, acrossCentre) }
                continue
            }

            // A tee or a corner: the rail on the far side from the crossing arm is the outer one and
            // runs past the axis to close the corner; the near rail stops short of it.
            let crossSide = crossLow == .double ? -1 : 1
            let outer = side != crossSide
            let start = lowSide ? 0 : crossCentre + (outer ? -offset : offset)
            let end = highSide ? alongMax : crossCentre + (outer ? offset : -offset)
            if outer {
                put(start, end, acrossCentre)
            } else {
                // The inner rail is cut by the crossing line, so it can be two separate stubs.
                if lowSide { put(0, crossCentre - offset, acrossCentre) }
                if highSide { put(crossCentre + offset, alongMax, acrossCentre) }
            }
        }
    }

    /// U+2504…U+250B and U+254C…U+254F: `count` dashes evenly spread along the cell.
    private func dashes(count: Int, value: UInt32, base: UInt32, _ out: inout [Primitive]) {
        let index = Int(value - base)
        let vertical = index >= 2
        let t = (index % 2 == 0) ? light : heavy
        let length = vertical ? h : w
        let across = band((vertical ? w : h) / 2, t)
        let segment = Double(length) / Double(count)
        let dash = max(1, Int((segment * 0.6).rounded()))
        for i in 0..<count {
            let start = Int((Double(i) * segment).rounded()) + max(0, (Int(segment) - dash) / 2)
            let end = min(length, start + dash)
            guard end > start else { continue }
            if vertical {
                fill(&out, across.start, start, t, end - start)
            } else {
                fill(&out, start, across.start, end - start, t)
            }
        }
    }

    /// U+256D…U+2570: light arcs. Antialiased, unlike the straight sprites — a stair-stepped
    /// quarter circle looks worse than a soft one — but centred on the same bands as `─` and `│`,
    /// with butt ends on the cell edge, so they meet a neighbouring line exactly.
    private func arc(_ value: UInt32) -> Primitive {
        let cx = bandCentre(w / 2, light)
        let cy = bandCentre(h / 2, light)
        let radius = min(Double(w), Double(h)) / 3
        // The cell edge each arm runs to.
        let (vertical, horizontal): (Double, Double)
        switch value {
        case 0x256D: (vertical, horizontal) = (Double(h), Double(w))  // ╭ down and right
        case 0x256E: (vertical, horizontal) = (Double(h), 0)          // ╮ down and left
        case 0x256F: (vertical, horizontal) = (0, 0)                  // ╯ up and left
        default: (vertical, horizontal) = (0, Double(w))              // ╰ up and right
        }
        let vSign: Double = vertical > cy ? 1 : -1
        let hSign: Double = horizontal > cx ? 1 : -1

        return .stroke(path: [
            .move(to: Point(x: cx, y: vertical)),
            .line(to: Point(x: cx, y: cy + vSign * radius)),
            .quadCurve(to: Point(x: cx + hSign * radius, y: cy), control: Point(x: cx, y: cy)),
            .line(to: Point(x: horizontal, y: cy)),
        ], lineWidth: Double(light))
    }

    /// U+2571…U+2573: the two diagonals and their cross, corner to corner.
    private func diagonal(_ value: UInt32) -> Primitive {
        var path: [PathElement] = []
        if value != 0x2571 {  // ╲ and ╳
            path.append(.move(to: Point(x: 0, y: 0)))
            path.append(.line(to: Point(x: Double(w), y: Double(h))))
        }
        if value != 0x2572 {  // ╱ and ╳
            path.append(.move(to: Point(x: 0, y: Double(h))))
            path.append(.line(to: Point(x: Double(w), y: 0)))
        }
        return .stroke(path: path, lineWidth: Double(light))
    }
}
