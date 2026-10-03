// DamageRegion — a set of device pixels as disjoint rects (WOR-313 S5b).
//
// The presentation ring keeps two kinds of region per image, both made of pane rects:
//
//   drawn                what this frame's panes drew into the image. Exact: it is subtracted from
//                        what the image lacks, and a superset would leave a stale pane uncopied.
//   accumulated damage   where the image differs from the latest presented frame: everything drawn
//                        since its own contents were presented. A superset is harmless (the copy
//                        from the previous image just copies equal pixels), so it is simplified to
//                        its bounding box once it holds more than `maxRects` rects.
//
// The rects are kept disjoint, so `area` counts each pixel once and a copy's destination regions
// never overlap. Pane rects make the algebra exact; nothing here rounds. Pure: no Vulkan.

extension PixelRect {
    /// The pixels both rects cover; nil when they do not overlap.
    public func intersection(_ other: PixelRect) -> PixelRect? {
        let left = max(x, other.x), top = max(y, other.y)
        let right = min(x + width, other.x + other.width), bottom = min(y + height, other.y + other.height)
        guard right > left, bottom > top else { return nil }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// This rect without `other`: up to four disjoint rects (the bands above and below the overlap,
    /// then its left and right sides), or the rect itself when they do not overlap.
    public func subtracting(_ other: PixelRect) -> [PixelRect] {
        guard !isEmpty else { return [] }
        guard let overlap = intersection(other) else { return [self] }
        let overlapRight = overlap.x + overlap.width, overlapBottom = overlap.y + overlap.height
        let pieces = [
            PixelRect(x: x, y: y, width: width, height: overlap.y - y),
            PixelRect(x: x, y: overlapBottom, width: width, height: y + height - overlapBottom),
            PixelRect(x: x, y: overlap.y, width: overlap.x - x, height: overlap.height),
            PixelRect(x: overlapRight, y: overlap.y, width: x + width - overlapRight, height: overlap.height),
        ]
        return pieces.filter { !$0.isEmpty }
    }

    var area: Int { isEmpty ? 0 : width * height }
}

public struct DamageRegion: Sendable, Hashable, CustomStringConvertible {
    /// Beyond this many rects, `simplify()` replaces an accumulated region by its bounding box.
    public static let maxRects = 16

    /// Disjoint and non-empty, in the order they were added.
    public private(set) var rects: [PixelRect] = []

    public init() {}

    public init(_ rect: PixelRect) {
        formUnion(rect)
    }

    public init(_ rects: [PixelRect]) {
        rects.forEach { formUnion($0) }
    }

    public var isEmpty: Bool { rects.isEmpty }

    /// Pixels covered, each counted once.
    public var area: Int { rects.reduce(0) { $0 + $1.area } }

    /// The smallest rect holding every pixel of the region; nil when it is empty.
    public var bounds: PixelRect? {
        guard let first = rects.first else { return nil }
        var left = first.x, top = first.y, right = first.x + first.width, bottom = first.y + first.height
        for rect in rects.dropFirst() {
            left = min(left, rect.x)
            top = min(top, rect.y)
            right = max(right, rect.x + rect.width)
            bottom = max(bottom, rect.y + rect.height)
        }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Adds the pixels of `rect` the region does not have yet, as new disjoint rects.
    public mutating func formUnion(_ rect: PixelRect) {
        var pieces = rect.isEmpty ? [] : [rect]
        for existing in rects where !pieces.isEmpty {
            pieces = pieces.flatMap { $0.subtracting(existing) }
        }
        rects += pieces
    }

    public mutating func formUnion(_ other: DamageRegion) {
        other.rects.forEach { formUnion($0) }
    }

    /// The region without the pixels of `other`. Exact, never simplified.
    public func subtracting(_ other: DamageRegion) -> DamageRegion {
        var result = DamageRegion()
        result.rects = other.rects.reduce(rects) { pieces, removed in pieces.flatMap { $0.subtracting(removed) } }
        return result
    }

    /// Replaces the region by its bounding box once it holds more than `maxRects` rects: a superset,
    /// for regions where covering more is harmless (accumulated damage), never for `drawn`.
    public mutating func simplify() {
        guard rects.count > Self.maxRects, let bounds else { return }
        rects = [bounds]
    }

    public var description: String { "[" + rects.map(\.description).joined(separator: ", ") + "]" }
}
