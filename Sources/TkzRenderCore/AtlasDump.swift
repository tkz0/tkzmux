// AtlasDump — the JSON `tkzmux-vtdump atlas --json` writes next to its atlas PNGs (WOR-312).
//
// One schema for both platforms, so the Mac reference (WOR-312 S1, CoreText) and the Linux dump
// (WOR-312 S5, FreeType) are compared field by field instead of through two hand-aligned decoders.
// Per glyph it records where the glyph sits in its atlas page, its placement (bearings and
// `appliedScale`), the exact ink box it was placed from, and the PostScript name of the face that
// actually drew it. The encoding is deterministic: sorted keys, and the ink box rounded to 1/10000
// px, so two runs of the same build give byte-identical files.
//
// The Mac exporter (`AtlasRecorder` in Sources/tkzmux-vtdump/FontDumpCommands.swift, WOR-312 S1)
// fills it from CoreText: `bbox` is the union of `CTFontGetBoundingRectsForGlyphs` before the fit
// scale, and `environment` carries the macOS build, the CoreText version, `defaults read -g
// AppleFontSmoothing` and the display profile. Bump `currentSchema` on any change to the fields.

import Foundation

public struct AtlasDump: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    /// One atlas page, written as `<prefix>-<kind>.png`.
    public struct Page: Codable, Sendable, Equatable {
        /// `grayscale` (A8 coverage) or `color` (premultiplied BGRA).
        public var kind: String
        /// Edge length in pixels.
        public var size: Int
        /// The PNG's file name, relative to the JSON.
        public var file: String

        public init(kind: String, size: Int, file: String) {
            self.kind = kind
            self.size = size
            self.file = file
        }
    }

    /// An ink box in device pixels from the pen origin, y up.
    public struct Box: Codable, Sendable, Equatable {
        public var minX: Double
        public var minY: Double
        public var maxX: Double
        public var maxY: Double

        public init(_ bounds: GlyphBounds) {
            self.minX = AtlasDump.rounded(bounds.minX)
            self.minY = AtlasDump.rounded(bounds.minY)
            self.maxX = AtlasDump.rounded(bounds.maxX)
            self.maxY = AtlasDump.rounded(bounds.maxY)
        }
    }

    /// The `CellMetrics` the atlas was rasterized against.
    public struct Metrics: Codable, Sendable, Equatable {
        public var width, height, ascent, descent, leading, baseline: Int
        public var underlineOffset, underlineThickness, strikethroughOffset, strikethroughThickness: Int

        public init(_ metrics: CellMetrics) {
            width = metrics.width
            height = metrics.height
            ascent = metrics.ascent
            descent = metrics.descent
            leading = metrics.leading
            baseline = metrics.baseline
            underlineOffset = metrics.underlineOffset
            underlineThickness = metrics.underlineThickness
            strikethroughOffset = metrics.strikethroughOffset
            strikethroughThickness = metrics.strikethroughThickness
        }
    }

    /// One packed glyph (a cluster in one style, or a box-drawing sprite).
    public struct Glyph: Codable, Sendable, Equatable {
        /// The cluster's Unicode scalar values.
        public var scalars: [UInt32]
        /// `regular`, `bold`, `italic` or `boldItalic` (`AtlasDump.styleName`).
        public var style: String
        /// PostScript name of the face that drew it; empty for a sprite.
        public var face: String
        /// Drawn by the box-sprite rasterizer, not from a font.
        public var sprite: Bool
        public var cellSpan: Int
        /// The page it lives in: `grayscale` or `color`.
        public var page: String
        /// The slot in the page, which is the bitmap's size (padding included).
        public var x, y, width, height: Int
        /// `RasterizedGlyph.bearingX` / `bearingTop`.
        public var bearingX, bearingTop: Int
        public var appliedScale: Double
        /// The ink union the bitmap was placed from, before the fit scale; `nil` for a sprite.
        public var bbox: Box?

        public init(scalars: [UInt32], style: String, face: String, sprite: Bool, cellSpan: Int,
                    page: String, x: Int, y: Int, width: Int, height: Int,
                    bearingX: Int, bearingTop: Int, appliedScale: Double, bbox: Box?) {
            self.scalars = scalars
            self.style = style
            self.face = face
            self.sprite = sprite
            self.cellSpan = cellSpan
            self.page = page
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.bearingX = bearingX
            self.bearingTop = bearingTop
            self.appliedScale = appliedScale
            self.bbox = bbox
        }
    }

    public var schema: Int
    /// `macos` or `linux`.
    public var platform: String
    public var pointSize: Double
    public var scale: Double
    public var pixelSize: Double
    public var thicken: Bool
    /// Transparent border around every bitmap.
    public var padding: Int
    public var metrics: Metrics
    /// Library versions, OS build and font-smoothing settings: whatever the platform's output
    /// depends on that the command line does not say.
    public var environment: [String: String]
    public var pages: [Page]
    public var glyphs: [Glyph]

    public init(platform: String, pointSize: Double, scale: Double, pixelSize: Double, thicken: Bool,
                padding: Int, metrics: CellMetrics, environment: [String: String],
                pages: [Page], glyphs: [Glyph]) {
        self.schema = Self.currentSchema
        self.platform = platform
        self.pointSize = pointSize
        self.scale = scale
        self.pixelSize = pixelSize
        self.thicken = thicken
        self.padding = padding
        self.metrics = Metrics(metrics)
        self.environment = environment
        self.pages = pages
        self.glyphs = glyphs
    }

    /// The style's name in the dump.
    public static func styleName(_ style: FontStyle) -> String {
        switch style {
        case .regular: "regular"
        case .bold: "bold"
        case .italic: "italic"
        case .boldItalic: "boldItalic"
        }
    }

    public static func style(named name: String) -> FontStyle? {
        FontStyle.allCases.first { styleName($0) == name }
    }

    /// Rounds to 1/10000 px: enough for a ±1 px comparison, stable across runs and printers.
    static func rounded(_ value: CGFloat) -> Double {
        (Double(value) * 10_000).rounded() / 10_000
    }

    /// Key-sorted, compact JSON with one glyph per line and a trailing newline. Not pretty-printed:
    /// a dump holds some 400 glyphs, and the references share ADR-0003's budget (pretty, one
    /// dump is 190 KB; this way 107 KB). A changed glyph is still a one-line diff.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var header = self
        header.glyphs = []
        let marker = Data(#""glyphs":[]"#.utf8)
        let outer = try encoder.encode(header)
        guard let slot = outer.range(of: marker) else { return outer + Data("\n".utf8) }
        var out = Data(outer[..<slot.lowerBound])
        out += Data(#""glyphs":["#.utf8)
        for (index, glyph) in glyphs.enumerated() {
            out += Data((index == 0 ? "\n" : ",\n").utf8)
            out += try encoder.encode(glyph)
        }
        out += Data((glyphs.isEmpty ? "]" : "\n]").utf8)
        out += outer[slot.upperBound...]
        return out + Data("\n".utf8)
    }
}
