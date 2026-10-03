// SymbolIcons — the three SF Symbols the Mac chrome uses, redrawn from original path data, and
// their rasterizer (WOR-312 S7). Linux only.
//
// SidebarHeaderView asks AppKit for `bell.fill`, `bell.slash` (the ready-sound toggle) and
// `folder.badge.plus` (new group) at 12 pt regular. SF Symbols may not ship outside Apple
// platforms, so Linux draws stand-ins authored here, from scratch, as plain geometry: a bell with a
// knob and a clapper, the same bell outlined and struck through, and an outlined folder with a plus
// badge. None of it is traced from or derived from Apple's artwork. The Mac keeps its SF Symbols.
//
// Geometry is in font-like units: 1000 per em, y up from the baseline, so an icon drawn at the
// symbol's point size sits on a text line the way the Mac's symbol image does. Each icon is a stack
// of layers: `fill` composites its path source-over, `clear` erases under its path (the gap around
// the bell's slash and around the folder's badge). Paths fill by the non-zero rule, so a ring is an
// outer contour plus an inner one wound the other way.
//
// `IconRasterizer` draws them with FreeType's anti-aliasing rasterizer, the one the glyphs go
// through, at `pointSize × scale` device pixels per em, unsnapped (ADR-0003: vector paths are drawn
// antialiased at w × s, not rounded). Placing an icon in its button is WOR-317's job, and so is
// fitting its box and stroke weight to the Mac's rendering.

import CFreeType
import Foundation
import Synchronization

/// A point in icon units.
public struct IconPoint: Sendable, Equatable {
    public let x: CGFloat
    public let y: CGFloat

    public init(_ x: CGFloat, _ y: CGFloat) {
        self.x = x
        self.y = y
    }

    static func + (a: IconPoint, b: IconPoint) -> IconPoint { IconPoint(a.x + b.x, a.y + b.y) }
    static func - (a: IconPoint, b: IconPoint) -> IconPoint { IconPoint(a.x - b.x, a.y - b.y) }
    static func * (a: IconPoint, k: CGFloat) -> IconPoint { IconPoint(a.x * k, a.y * k) }
}

/// A path of closed contours: lines and cubic Béziers.
public struct VectorPath: Sendable, Equatable {
    public enum Element: Sendable, Equatable {
        case move(IconPoint)
        case line(IconPoint)
        case cubic(IconPoint, IconPoint, IconPoint)
        case close
    }

    public private(set) var elements: [Element] = []

    public init() {}

    mutating func move(_ x: CGFloat, _ y: CGFloat) { elements.append(.move(IconPoint(x, y))) }
    mutating func line(_ x: CGFloat, _ y: CGFloat) { elements.append(.line(IconPoint(x, y))) }
    mutating func cubic(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        elements.append(.cubic(IconPoint(x1, y1), IconPoint(x2, y2), IconPoint(x, y)))
    }
    mutating func close() { elements.append(.close) }

    mutating func append(_ other: VectorPath) { elements += other.elements }

    /// A circle's four cubic quarter arcs.
    static func circle(_ cx: CGFloat, _ cy: CGFloat, radius r: CGFloat) -> VectorPath {
        let k = r * kappa
        var path = VectorPath()
        path.move(cx + r, cy)
        path.cubic(cx + r, cy + k, cx + k, cy + r, cx, cy + r)
        path.cubic(cx - k, cy + r, cx - r, cy + k, cx - r, cy)
        path.cubic(cx - r, cy - k, cx - k, cy - r, cx, cy - r)
        path.cubic(cx + k, cy - r, cx + r, cy - k, cx + r, cy)
        path.close()
        return path
    }

    /// A stroke from `a` to `b`, `width` wide, with round caps. Every capsule winds the same way.
    static func capsule(from a: IconPoint, to b: IconPoint, width: CGFloat) -> VectorPath {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        let h = width / 2
        let u = IconPoint(dx / length * h, dy / length * h)  // along, half-width long
        let n = IconPoint(-u.y, u.x)                         // across, half-width long
        let k = kappa
        var path = VectorPath()
        path.elements.append(.move(a + n))
        path.elements.append(.line(b + n))
        path.elements.append(.cubic(b + n + u * k, b + u + n * k, b + u))
        path.elements.append(.cubic(b + u - n * k, b - n + u * k, b - n))
        path.elements.append(.line(a - n))
        path.elements.append(.cubic(a - n - u * k, a - u - n * k, a - u))
        path.elements.append(.cubic(a - u + n * k, a + n - u * k, a + n))
        path.close()
        return path
    }

    /// The cubic-to-quarter-circle constant.
    static let kappa: CGFloat = 0.5522847498
}

/// One stand-in for an SF Symbol.
public struct SymbolIcon: Sendable, Equatable {
    public enum Layer: Sendable, Equatable {
        /// Composites the path source-over.
        case fill(VectorPath)
        /// Erases what is under the path.
        case clear(VectorPath)
    }

    public static let unitsPerEm: CGFloat = 1000

    /// The SF Symbol this stands in for.
    public let name: String
    public let layers: [Layer]
}

public enum SymbolIcons {
    /// The sound toggle when on.
    public static let bellFill = SymbolIcon(name: "bell.fill", layers: [
        .fill(bellBody), .fill(.circle(500, 860, radius: 52)), .fill(clapper),
    ])

    /// The sound toggle when off: the bell outlined, a slash across it, a gap either side of the
    /// slash.
    public static let bellSlash: SymbolIcon = {
        var ring = bellBody
        ring.append(bellInner)
        let start = IconPoint(110, 900), end = IconPoint(890, 10)
        return SymbolIcon(name: "bell.slash", layers: [
            .fill(ring), .fill(.circle(500, 860, radius: 48)), .fill(clapper),
            .clear(.capsule(from: start, to: end, width: slashWidth + 2 * slashGap)),
            .fill(.capsule(from: start, to: end, width: slashWidth)),
        ])
    }()

    /// The new-group button: an outlined folder, a plus badge at its lower right, a gap round the
    /// badge.
    public static let folderBadgePlus: SymbolIcon = {
        var ring = folderOuter
        ring.append(folderInner)
        let centre = IconPoint(790, 150), arm: CGFloat = 165
        var plus = VectorPath.capsule(from: IconPoint(centre.x - arm, centre.y), to: IconPoint(centre.x + arm, centre.y),
                                      width: stroke)
        plus.append(.capsule(from: IconPoint(centre.x, centre.y - arm), to: IconPoint(centre.x, centre.y + arm),
                             width: stroke))
        return SymbolIcon(name: "folder.badge.plus", layers: [
            .fill(ring), .clear(.circle(centre.x, centre.y, radius: arm + stroke / 2 + 60)), .fill(plus),
        ])
    }()

    public static let all = [bellFill, bellSlash, folderBadgePlus]

    /// The stand-in for an SF Symbol name, `nil` for one there is none for.
    public static func named(_ name: String) -> SymbolIcon? {
        all.first { $0.name == name }
    }

    // MARK: - Geometry

    /// Outline stroke weight, about a regular-weight symbol's at 12 pt.
    static let stroke: CGFloat = 84
    static let slashWidth: CGFloat = 80
    static let slashGap: CGFloat = 55

    /// The bell's silhouette, clockwise: a flared skirt on a rounded rim, straight sides, a dome.
    static let bellBody: VectorPath = {
        var path = VectorPath()
        path.move(100, 230)
        path.cubic(180, 270, 230, 350, 230, 470)
        path.line(230, 590)
        path.cubic(230, 745, 350, 840, 500, 840)
        path.cubic(650, 840, 770, 745, 770, 590)
        path.line(770, 470)
        path.cubic(770, 350, 820, 270, 900, 230)
        path.cubic(935, 212, 925, 150, 880, 150)
        path.line(120, 150)
        path.cubic(75, 150, 65, 212, 100, 230)
        path.close()
        return path
    }()

    /// The bell's hollow, counter-clockwise, `stroke` inside the silhouette (the rim stays solid).
    static let bellInner: VectorPath = {
        let s = stroke
        var path = VectorPath()
        path.move(100 + s + 31, 150 + s)
        path.line(900 - s - 31, 150 + s)
        path.cubic(770 - s + 45, 270 + 10, 770 - s, 350, 770 - s, 470)
        path.line(770 - s, 590)
        path.cubic(770 - s, 700, 650 - s / 2, 840 - s, 500, 840 - s)
        path.cubic(350 + s / 2, 840 - s, 230 + s, 700, 230 + s, 590)
        path.line(230 + s, 470)
        path.cubic(230 + s, 350, 230 + s - 45, 270 + 10, 100 + s + 31, 150 + s)
        path.close()
        return path
    }()

    /// The clapper: a half disc under the rim, clear of it.
    static let clapper: VectorPath = {
        var path = VectorPath()
        path.move(395, 112)
        path.line(605, 112)
        path.cubic(605, 54, 558, 12, 500, 12)
        path.cubic(442, 12, 395, 54, 395, 112)
        path.close()
        return path
    }()

    /// The folder's silhouette, clockwise: a tab at the upper left, rounded corners.
    static let folderOuter: VectorPath = {
        var path = VectorPath()
        path.move(40, 190)
        path.line(40, 700)
        path.cubic(40, 750, 80, 790, 130, 790)
        path.line(340, 790)
        path.cubic(370, 790, 390, 780, 405, 760)
        path.line(450, 700)
        path.line(810, 700)
        path.cubic(860, 700, 900, 660, 900, 610)
        path.line(900, 190)
        path.cubic(900, 140, 860, 100, 810, 100)
        path.line(130, 100)
        path.cubic(80, 100, 40, 140, 40, 190)
        path.close()
        return path
    }()

    /// The folder's hollow, counter-clockwise, `stroke` inside the body (the tab stays solid).
    static let folderInner: VectorPath = {
        let s = stroke, r: CGFloat = 32
        let left = 40 + s, right = 900 - s, bottom = 100 + s, top = 700 - s
        var path = VectorPath()
        path.move(left + r, bottom)
        path.line(right - r, bottom)
        path.cubic(right - r / 2, bottom, right, bottom + r / 2, right, bottom + r)
        path.line(right, top - r)
        path.cubic(right, top - r / 2, right - r / 2, top, right - r, top)
        path.line(left + r, top)
        path.cubic(left + r / 2, top, left, top - r / 2, left, top - r)
        path.line(left, bottom + r)
        path.cubic(left, bottom + r / 2, left + r / 2, bottom, left + r, bottom)
        path.close()
        return path
    }()
}

// MARK: - Rasterizing

/// An icon's A8 coverage, rows top-down, placed like a glyph: `bearingX` from the pen origin to the
/// bitmap's left edge, `bearingTop` from the baseline up to its top edge, in device pixels.
public struct IconBitmap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let bearingX: Int
    public let bearingTop: Int
    public let pixels: [UInt8]
}

public final class IconRasterizer: Sendable {
    private let library: Mutex<FreeTypeLibrary>

    public init() throws {
        library = Mutex(try FreeTypeLibrary())
    }

    /// `icon` at `pointSize` points per em on a `scale`× surface. The bitmap is the ink box of the
    /// fill layers, rounded out to whole pixels; `nil` when it has no ink.
    public func rasterize(_ icon: SymbolIcon, pointSize: CGFloat, scale: CGFloat) -> IconBitmap? {
        let pixelsPerUnit = pointSize * scale / SymbolIcon.unitsPerEm
        return library.withLock { library in
            var outlines: [(outline: FT_Outline, clear: Bool)] = []
            defer {
                for index in outlines.indices { FT_Outline_Done(library.handle, &outlines[index].outline) }
            }
            var box: (minX: FT_Pos, minY: FT_Pos, maxX: FT_Pos, maxY: FT_Pos)?
            for layer in icon.layers {
                let (path, clear) = switch layer {
                case .fill(let path): (path, false)
                case .clear(let path): (path, true)
                }
                guard var outline = Self.outline(path, pixelsPerUnit: pixelsPerUnit, library: library) else { continue }
                outlines.append((outline, clear))
                guard !clear else { continue }
                var bbox = FT_BBox()
                guard FT_Outline_Get_BBox(&outline, &bbox) == 0 else { continue }
                box = box.map { (min($0.minX, bbox.xMin), min($0.minY, bbox.yMin), max($0.maxX, bbox.xMax), max($0.maxY, bbox.yMax)) }
                    ?? (bbox.xMin, bbox.yMin, bbox.xMax, bbox.yMax)
            }
            guard let box else { return nil }
            // Whole pixels around the ink; the ink itself is not moved.
            let left = Int((Double(box.minX) / 64).rounded(.down)), bottom = Int((Double(box.minY) / 64).rounded(.down))
            let right = Int((Double(box.maxX) / 64).rounded(.up)), top = Int((Double(box.maxY) / 64).rounded(.up))
            let width = right - left, height = top - bottom
            guard width > 0, height > 0 else { return nil }

            var pixels = [UInt8](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBufferPointer { buffer in
                var target = FreeTypeRasterizer.SpanTarget(base: buffer.baseAddress!, width: Int32(width), height: Int32(height))
                for index in outlines.indices {
                    FT_Outline_Translate(&outlines[index].outline, FT_Pos(-left * 64), FT_Pos(-bottom * 64))
                    Self.render(&outlines[index].outline, clear: outlines[index].clear, into: &target, library: library)
                }
            }
            return IconBitmap(width: width, height: height, bearingX: left, bearingTop: top, pixels: pixels)
        }
    }

    /// `path` as a FreeType outline in 26.6 device pixels, or `nil` when it is empty. The caller
    /// frees it with `FT_Outline_Done`.
    private static func outline(_ path: VectorPath, pixelsPerUnit: CGFloat, library: FreeTypeLibrary) -> FT_Outline? {
        // Points and tags per contour; a contour's closing point equal to its start is dropped.
        var points: [FT_Vector] = [], tags: [UInt8] = [], ends: [Int] = []
        var contourStart = 0
        func vector(_ p: IconPoint) -> FT_Vector {
            FT_Vector(x: FT_Pos((p.x * pixelsPerUnit * 64).rounded()), y: FT_Pos((p.y * pixelsPerUnit * 64).rounded()))
        }
        func endContour() {
            guard points.count > contourStart else { return }
            if points.count - contourStart > 1, tags.last == UInt8(FT_CURVE_TAG_ON),
               points.last!.x == points[contourStart].x, points.last!.y == points[contourStart].y {
                points.removeLast()
                tags.removeLast()
            }
            ends.append(points.count - 1)
            contourStart = points.count
        }
        for element in path.elements {
            switch element {
            case .move(let p):
                endContour()
                points.append(vector(p)); tags.append(UInt8(FT_CURVE_TAG_ON))
            case .line(let p):
                points.append(vector(p)); tags.append(UInt8(FT_CURVE_TAG_ON))
            case .cubic(let c1, let c2, let p):
                points += [vector(c1), vector(c2), vector(p)]
                tags += [UInt8(FT_CURVE_TAG_CUBIC), UInt8(FT_CURVE_TAG_CUBIC), UInt8(FT_CURVE_TAG_ON)]
            case .close:
                endContour()
            }
        }
        endContour()
        guard !points.isEmpty else { return nil }

        var outline = FT_Outline()
        guard FT_Outline_New(library.handle, FT_UInt(points.count), FT_Int(ends.count), &outline) == 0 else { return nil }
        for (index, point) in points.enumerated() {
            outline.points[index] = point
            outline.tags[index] = numericCast(tags[index])
        }
        for (index, end) in ends.enumerated() {
            outline.contours[index] = numericCast(end)
        }
        return outline
    }

    /// Erases under one anti-aliased span list: `d · (255 − c) / 255`.
    private static let clearSpans: FT_SpanFunc = { y, count, spans, user in
        guard let spans, let user else { return }
        let target = user.assumingMemoryBound(to: FreeTypeRasterizer.SpanTarget.self).pointee
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
                line[x] = UInt8((Int(line[x]) * (255 - coverage) + 127) / 255)
            }
        }
    }

    private static func render(_ outline: inout FT_Outline, clear: Bool,
                               into target: inout FreeTypeRasterizer.SpanTarget, library: FreeTypeLibrary) {
        withUnsafeMutablePointer(to: &target) { pointer in
            var params = FT_Raster_Params()
            params.flags = FT_RASTER_FLAG_AA | FT_RASTER_FLAG_DIRECT | FT_RASTER_FLAG_CLIP
            params.gray_spans = clear ? clearSpans : FreeTypeRasterizer.compositeSpans
            params.user = UnsafeMutableRawPointer(pointer)
            params.clip_box = FT_BBox(xMin: 0, yMin: 0, xMax: FT_Pos(pointer.pointee.width), yMax: FT_Pos(pointer.pointee.height))
            _ = FT_Outline_Render(library.handle, &outline, &params)
        }
    }
}
