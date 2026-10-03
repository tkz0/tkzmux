// GlyphSource — the font seam between the device-free renderer and a platform font stack (WOR-311 S2).
//
// The core never sees a CTFont, CGGlyph or FT_Face. A backend (CoreText on the Mac, FreeType and
// HarfBuzz on Linux) resolves faces itself and hands out opaque `FontFace` handles and `GlyphID`s;
// only that backend can interpret them. What crosses the seam is plain data: positioned glyph ids,
// CPU bitmaps in device pixels, and `CellMetrics`.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The four faces a terminal draws with.
public enum FontStyle: UInt8, CaseIterable, Sendable, Hashable {
    case regular, bold, italic, boldItalic

    public var isBold: Bool { self == .bold || self == .boldItalic }
    public var isItalic: Bool { self == .italic || self == .boldItalic }

    public init(bold: Bool, italic: Bool) {
        switch (bold, italic) {
        case (false, false): self = .regular
        case (true, false): self = .bold
        case (false, true): self = .italic
        case (true, true): self = .boldItalic
        }
    }
}

/// An opaque handle for a resolved face — a primary style face or a fallback the backend picked
/// for a cluster. Minted by a `GlyphSource` and meaningful only to the source that minted it.
public struct FontFace: Sendable, Hashable {
    /// The backend's own key for the face (an index into its face table, say).
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// A glyph index inside a `FontFace`. Wide enough for both CoreText (`CGGlyph`, 16 bit) and
/// FreeType (32 bit). Glyph 0 is `.notdef` in every sfnt font: no coverage.
public struct GlyphID: Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// `.notdef`, the "no glyph for this character" glyph.
    public static let notdef = GlyphID(rawValue: 0)
}

/// One positioned glyph inside a shaped cluster. Offsets are device pixels from the cluster's pen
/// origin (baseline left), y positive up.
public struct ClusterGlyph: Sendable, Equatable {
    public let glyph: GlyphID
    public let xOffset: CGFloat
    public let yOffset: CGFloat

    public init(glyph: GlyphID, xOffset: CGFloat = 0, yOffset: CGFloat = 0) {
        self.glyph = glyph
        self.xOffset = xOffset
        self.yOffset = yOffset
    }
}

/// One grapheme cluster shaped by a `GlyphSource`.
public struct ShapedCluster: Sendable, Equatable {
    /// The face that carries the glyphs (may be a fallback, not the style's primary face).
    public let face: FontFace
    /// Positioned glyphs, in draw order.
    public let glyphs: [ClusterGlyph]
    /// True when `face` is a colour face and the result belongs in the BGRA atlas.
    public let isColor: Bool
    /// How many terminal cells the cluster occupies (1 or 2).
    public let cellSpan: Int

    /// True when every glyph is `.notdef` — the cluster has no coverage anywhere.
    public var isEmpty: Bool { glyphs.isEmpty || glyphs.allSatisfy { $0.glyph == .notdef } }

    public init(face: FontFace, glyphs: [ClusterGlyph], isColor: Bool, cellSpan: Int) {
        self.face = face
        self.glyphs = glyphs
        self.isColor = isColor
        self.cellSpan = cellSpan
    }
}

/// A rasterized grapheme: pixels plus everything needed to place them.
///
/// `bearingX` / `bearingTop` are device pixels from the pen origin (baseline, left edge of the
/// cluster) to the bitmap's left and top edges, y positive up. To draw at cell origin `(cx, cy)`
/// with baseline `b`: `x = cx + bearingX`, `y = cy + b - bearingTop`.
public struct RasterizedGlyph: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bytesPerPixel: Int
    public let bearingX: Int
    public let bearingTop: Int
    public let isColor: Bool
    /// Uniform scale applied to fit the cell box (1.0 when the glyph fitted as drawn).
    public let appliedScale: CGFloat
    public let pixels: [UInt8]

    public var isEmpty: Bool { width == 0 || height == 0 }

    public init(width: Int,
                height: Int,
                bytesPerRow: Int,
                bytesPerPixel: Int,
                bearingX: Int,
                bearingTop: Int,
                isColor: Bool,
                appliedScale: CGFloat,
                pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bytesPerPixel = bytesPerPixel
        self.bearingX = bearingX
        self.bearingTop = bearingTop
        self.isColor = isColor
        self.appliedScale = appliedScale
        self.pixels = pixels
    }
}

/// A platform font stack as the glyph cache sees it: shape a cluster, rasterize it, draw a box
/// sprite, and report the cell geometry everything is laid out on.
///
/// Called only on a cache miss, so the existential cost stays off the hot path. Implementations
/// keep their own caches and are not `Sendable`: one lives on the render thread with its cache.
public protocol GlyphSource: AnyObject {
    /// Cell geometry of the regular face at the source's pixel size.
    var metrics: CellMetrics { get }

    /// Transparent border, in pixels, around every bitmap `rasterize` and `sprite` return, so
    /// bilinear sampling never bleeds a neighbour.
    var padding: Int { get }

    /// Shapes one grapheme cluster.
    /// - Parameter cellSpan: how many cells the terminal assigned the cluster (libghostty's `WIDE`
    ///   flag in production); `nil` asks the source for its own Unicode-property guess.
    func shape(_ scalars: [Unicode.Scalar], style: FontStyle, cellSpan: Int?) -> ShapedCluster

    /// Rasterizes a cluster this source shaped. `nil` when there is nothing to draw (space,
    /// control characters, no coverage).
    func rasterize(_ cluster: ShapedCluster, style: FontStyle) -> RasterizedGlyph?

    /// The box-drawing or block-element sprite for `scalar`, drawn to tile with its neighbours
    /// instead of taken from the font, or `nil` when the source has no sprite for it.
    func sprite(for scalar: Unicode.Scalar) -> RasterizedGlyph?

    /// A stable human-readable name for `face` (its PostScript name), for dumps and tests.
    func name(of face: FontFace) -> String
}
