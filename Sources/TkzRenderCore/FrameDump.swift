// FrameDump — the L2 parity artifact (WOR-322 S3; ADR-0003 §3, L2): FrameBuilder's instance
// buffers for one recorded screen, and the atlas glyph table they reference.
//
// L2 asks whether the Mac and Linux FrameBuilders write the same bytes from the same cell metrics
// and the same atlas glyph table. Both platforms run this file. `FrameDumper.dump` replays a
// `.tkzrec` into a headless session, builds one frame through a `GlyphCache` over any
// `GlyphSource`, and returns two things:
//
//   * the glyph table: every cluster and sprite the cache asked its source for, in the order it
//     asked, with the face that drew it and where the shared packer put it, or that it drew nothing;
//   * the instance buffers the renderers bind, written field by field in little-endian order: the
//     background grid, the glyphs, the rects below the glyphs and the rects above them.
//
// Over the platform's font stack (CoreText on the Mac, FreeType on Linux) that is a reference.
// Over `GlyphTableSource` it is the replay: the reference's clusters come back with the reference's
// bitmap sizes and bearings, the packer puts them where it put them before, and the FrameBuilder
// must write the reference's buffers byte for byte. The replay opens no font, so neither the fonts
// nor the environment can reach an L2 result.
//
// Files: `<fixture>@<scale>.json` (this struct; sorted keys, so two runs of one build write the
// same bytes) and `<fixture>@<scale>.bin` (the buffers, laid out as `buffers` says). `<scale>` is
// the `Double` as Swift prints it: `1.6`, `2.0`.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics  // CGRect/CGFloat geometry API lives in the CoreGraphics overlay on Apple platforms
#endif
import TkzShaderTypes
import TkzTerminalCore

public struct FrameDump: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    /// One request the glyph cache made of its source.
    public struct Glyph: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// Shaped and rasterized from a face, then packed.
            case glyph
            /// A box-drawing or block-element sprite, packed.
            case sprite
            /// Shaped, and there was nothing to draw (`rasterize` returned nil).
            case empty
            /// A box scalar the source has no sprite for; the cache went on to the font.
            case noSprite
        }

        public var kind: Kind
        /// The cluster's Unicode scalar values.
        public var scalars: [UInt32]
        /// `AtlasDump.styleName`; sprites are cached under `regular`.
        public var style: String
        /// The span the cache keyed the cluster under.
        public var cellSpan: Int
        /// PostScript name of the face the source shaped with; absent for sprites.
        public var face: String?
        /// `grayscale` or `color`, for the packed kinds.
        public var page: String?
        /// The slot: where the packer put the bitmap, and its size (padding included).
        public var x: Int?
        public var y: Int?
        public var width: Int?
        public var height: Int?
        /// `RasterizedGlyph.bearingX` / `bearingTop`.
        public var bearingX: Int?
        public var bearingTop: Int?
        public var appliedScale: Double?

        public init(kind: Kind, scalars: [UInt32], style: String, cellSpan: Int, face: String? = nil,
                    page: String? = nil, x: Int? = nil, y: Int? = nil, width: Int? = nil,
                    height: Int? = nil, bearingX: Int? = nil, bearingTop: Int? = nil,
                    appliedScale: Double? = nil) {
            self.kind = kind
            self.scalars = scalars
            self.style = style
            self.cellSpan = cellSpan
            self.face = face
            self.page = page
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.bearingX = bearingX
            self.bearingTop = bearingTop
            self.appliedScale = appliedScale
        }

        /// `U+0041 bold span 1`, for messages.
        public var label: String {
            let text = scalars.map { String(format: "U+%04X", $0) }.joined(separator: " ")
            return "\(text) \(style) span \(cellSpan)"
        }
    }

    /// One instance array in the `.bin`, in file order.
    public struct Buffer: Codable, Sendable, Equatable {
        public var name: String
        public var stride: Int
        public var count: Int

        public init(name: String, stride: Int, count: Int) {
            self.name = name
            self.stride = stride
            self.count = count
        }
    }

    /// What drew the glyphs. A replay copies its reference's, so a replay that matches writes the
    /// reference's JSON again.
    public struct Source: Codable, Sendable, Equatable {
        /// `macos` or `linux`.
        public var platform: String
        /// `CoreText` or `FreeType`.
        public var glyphSource: String
        /// Whatever the glyphs depend on that the command line does not say.
        public var environment: [String: String]

        public init(platform: String, glyphSource: String, environment: [String: String] = [:]) {
            self.platform = platform
            self.glyphSource = glyphSource
            self.environment = environment
        }
    }

    public var schema: Int
    /// The recording's file name without `.tkzrec`.
    public var fixture: String
    public var columns: Int
    public var rows: Int
    public var pointSize: Double
    public var scale: Double
    /// Transparent border around every bitmap (`GlyphSource.padding`).
    public var padding: Int
    /// The `CellMetrics` the frame was laid out on.
    public var metrics: AtlasDump.Metrics
    /// Each atlas's edge length after the frame, by page.
    public var atlas: [String: Int]
    public var glyphs: [Glyph]
    public var buffers: [Buffer]
    /// The `.bin` file, relative to the JSON.
    public var instances: String
    public var source: Source

    /// `claude-boot@1.6`.
    public static func stem(fixture: String, scale: Double) -> String {
        "\(fixture)@\(scale)"
    }

    /// Sorted-key, pretty JSON with a trailing newline.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    public static func decode(_ data: Data) throws -> FrameDump {
        let dump = try JSONDecoder().decode(FrameDump.self, from: data)
        guard dump.schema == currentSchema else {
            throw FrameDumpError(description: "frame dump schema \(dump.schema); this build reads \(currentSchema)")
        }
        return dump
    }

    // MARK: - The instance layout

    /// One field of an instance: its name and its byte range inside the instance.
    public struct Field: Sendable, Equatable {
        public let name: String
        public let offset: Int
        public let size: Int
    }

    /// The buffers, in file order: what the background, glyph and the two rect passes bind.
    public static let bufferNames = ["background", "glyphs", "rectsBelow", "rectsAbove"]

    /// Each buffer's fields, as TkzShaderTypes.h lays them out (and ShaderLayoutTests pins).
    public static func fields(of buffer: String) -> [Field] {
        switch buffer {
        case "background":
            return [Field(name: "color", offset: 0, size: 4)]
        case "glyphs":
            return [
                Field(name: "gridPos.x", offset: 0, size: 2), Field(name: "gridPos.y", offset: 2, size: 2),
                Field(name: "offsetPx.x", offset: 4, size: 2), Field(name: "offsetPx.y", offset: 6, size: 2),
                Field(name: "sizePx.x", offset: 8, size: 2), Field(name: "sizePx.y", offset: 10, size: 2),
                Field(name: "atlasPos.x", offset: 12, size: 2), Field(name: "atlasPos.y", offset: 14, size: 2),
                Field(name: "color", offset: 16, size: 4), Field(name: "bgColor", offset: 20, size: 4),
                Field(name: "flags", offset: 24, size: 4), Field(name: "reserved0", offset: 28, size: 4),
            ]
        default:
            return [
                Field(name: "originPx.x", offset: 0, size: 4), Field(name: "originPx.y", offset: 4, size: 4),
                Field(name: "sizePx.x", offset: 8, size: 4), Field(name: "sizePx.y", offset: 12, size: 4),
                Field(name: "color", offset: 16, size: 4), Field(name: "style", offset: 20, size: 4),
                Field(name: "thicknessPx", offset: 24, size: 4), Field(name: "reserved0", offset: 28, size: 4),
            ]
        }
    }

    /// Where byte `offset` of this dump's `.bin` lives: the buffer, the instance, the field and its
    /// byte range, e.g. `glyphs[12].atlasPos.x (bytes 396..<398)`. Nil past the end.
    public func locate(offset: Int) -> (description: String, range: Range<Int>)? {
        var start = 0
        for buffer in buffers {
            let end = start + buffer.stride * buffer.count
            if offset < end, buffer.stride > 0 {
                let index = (offset - start) / buffer.stride
                let within = (offset - start) % buffer.stride
                let instance = start + index * buffer.stride
                guard let field = Self.fields(of: buffer.name).first(where: { within >= $0.offset && within < $0.offset + $0.size })
                else { return ("\(buffer.name)[\(index)] byte \(within)", offset..<(offset + 1)) }
                let range = (instance + field.offset)..<(instance + field.offset + field.size)
                return ("\(buffer.name)[\(index)].\(field.name) (bytes \(range.lowerBound)..<\(range.upperBound))", range)
            }
            start = end
        }
        return nil
    }

    // MARK: - Encoding the buffers

    /// The four buffers, field by field, little-endian.
    static func encode(background: [TkzBgCell], glyphs: [TkzGlyphInstance],
                       below: [TkzRectInstance], above: [TkzRectInstance]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(background.count * 4 + (glyphs.count + below.count + above.count) * 32)
        func u16(_ value: UInt16) { out.append(UInt8(value & 0xFF)); out.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
        func f32(_ value: Float) { u32(value.bitPattern) }

        for cell in background { u32(cell.color) }
        for glyph in glyphs {
            u16(glyph.gridPos.x); u16(glyph.gridPos.y)
            u16(UInt16(bitPattern: glyph.offsetPx.x)); u16(UInt16(bitPattern: glyph.offsetPx.y))
            u16(glyph.sizePx.x); u16(glyph.sizePx.y)
            u16(glyph.atlasPos.x); u16(glyph.atlasPos.y)
            u32(glyph.color); u32(glyph.bgColor); u32(glyph.flags); u32(glyph.reserved0)
        }
        for rect in below + above {
            f32(rect.originPx.x); f32(rect.originPx.y); f32(rect.sizePx.x); f32(rect.sizePx.y)
            u32(rect.color); u32(rect.style); f32(rect.thicknessPx); u32(rect.reserved0)
        }
        return out
    }
}

/// A frame dump that cannot be read or replayed.
public struct FrameDumpError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

extension AtlasDump.Metrics {
    /// The metrics as `CellMetrics`, at the scale they were measured at.
    public func cellMetrics(scale: Double) -> CellMetrics {
        CellMetrics(width: width, height: height, ascent: ascent, descent: descent, leading: leading,
                    baseline: baseline, underlineOffset: underlineOffset,
                    underlineThickness: underlineThickness, strikethroughOffset: strikethroughOffset,
                    strikethroughThickness: strikethroughThickness, scale: CGFloat(scale))
    }
}

// MARK: - FrameDumper

public enum FrameDumper {
    /// A dump and its `.bin`.
    public struct Output: Sendable {
        public let dump: FrameDump
        public let instances: [UInt8]

        /// Writes `<stem>.json` and `<stem>.bin` into `directory`, creating it.
        public func write(to directory: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stem = FrameDump.stem(fixture: dump.fixture, scale: dump.scale)
            try dump.encoded().write(to: directory.appendingPathComponent("\(stem).json"), options: .atomic)
            try Data(instances).write(to: directory.appendingPathComponent(dump.instances), options: .atomic)
        }
    }

    /// Replays `recording` at its own size, builds one frame through a fresh `GlyphCache` over
    /// `source`, and dumps the glyph table and the instance buffers.
    ///
    /// - Parameters:
    ///   - pointSize: the size `source` was built at, for the record (`source` already applies it).
    ///   - origin: what drew the glyphs; a replay passes its reference's.
    public static func dump(recording: RecordingReader, fixture: String, source: any GlyphSource,
                            pointSize: Double, scale: Double, origin: FrameDump.Source) throws -> Output {
        let columns = recording.header.cols
        let rows = recording.header.rows
        let session = try TerminalSession(options: TerminalSessionOptions(cols: columns, rows: rows))
        try recording.replay(into: session)

        let recorder = RecordingGlyphSource(source)
        let cache = GlyphCache(source: recorder)
        let surface = TerminalSurface()
        try surface.attach(session)
        defer { surface.detach() }
        try FrameBuilder(glyphCache: cache).update(surface)

        let metrics = cache.metrics
        let geometry = GridGeometry(metrics: metrics, viewportWidth: Int(columns) * metrics.width,
                                    viewportHeight: Int(rows) * metrics.height)
        let background = surface.backgroundCells
        let glyphs = surface.glyphInstances()
        let below = surface.rectInstancesBelow(geometry: geometry)
        let above = surface.rectInstancesAbove(geometry: geometry)

        // The lookups below are cache hits; anything that reached the source now is not the frame's.
        recorder.isRecording = false
        guard recorder.unmatchedRasterizations == 0 else {
            throw FrameDumpError(description: "\(recorder.unmatchedRasterizations) rasterizations without their shape; the glyph table would be incomplete")
        }
        let table = recorder.entries.map { entry -> FrameDump.Glyph in
            let scalars = entry.scalars.map(\.value)
            let style = AtlasDump.styleName(entry.style)
            switch entry.kind {
            case .empty, .noSprite:
                return FrameDump.Glyph(kind: entry.kind, scalars: scalars, style: style, cellSpan: entry.cellSpan,
                                       face: entry.face)
            case .glyph, .sprite:
                let raster = entry.raster
                let placed = entry.kind == .sprite
                    ? cache.glyph(for: entry.scalars)
                    : cache.glyph(for: entry.scalars, style: entry.style, cellSpan: entry.cellSpan)
                return FrameDump.Glyph(
                    kind: entry.kind, scalars: scalars, style: style, cellSpan: entry.cellSpan, face: entry.face,
                    page: raster.map { $0.isColor ? "color" : "grayscale" },
                    x: placed?.slot.x, y: placed?.slot.y, width: raster?.width, height: raster?.height,
                    bearingX: raster?.bearingX, bearingTop: raster?.bearingTop,
                    appliedScale: raster.map { Double($0.appliedScale) })
            }
        }

        let stem = FrameDump.stem(fixture: fixture, scale: scale)
        let dump = FrameDump(
            schema: FrameDump.currentSchema, fixture: fixture, columns: Int(columns), rows: Int(rows),
            pointSize: pointSize, scale: scale, padding: source.padding, metrics: AtlasDump.Metrics(metrics),
            atlas: ["grayscale": cache.grayscale.size, "color": cache.color.size],
            glyphs: table,
            buffers: [
                FrameDump.Buffer(name: "background", stride: 4, count: background.count),
                FrameDump.Buffer(name: "glyphs", stride: 32, count: glyphs.count),
                FrameDump.Buffer(name: "rectsBelow", stride: 32, count: below.count),
                FrameDump.Buffer(name: "rectsAbove", stride: 32, count: above.count),
            ],
            instances: "\(stem).bin",
            source: origin)
        let bytes = FrameDump.encode(background: background, glyphs: glyphs, below: below, above: above)
        return Output(dump: dump, instances: bytes)
    }
}

// MARK: - Recording the cache's requests

/// Forwards to a source and logs what the glyph cache asked of it, in order. The cache rasterizes
/// right after it shapes, so a rasterization is paired with the shape before it.
final class RecordingGlyphSource: GlyphSource {
    struct Entry {
        let kind: FrameDump.Glyph.Kind
        let scalars: [Unicode.Scalar]
        let style: FontStyle
        let cellSpan: Int
        let face: String?
        let raster: RasterizedGlyph?
    }

    let base: any GlyphSource
    var isRecording = true
    private(set) var entries: [Entry] = []
    private(set) var unmatchedRasterizations = 0
    private var lastShape: (scalars: [Unicode.Scalar], style: FontStyle, cluster: ShapedCluster)?

    init(_ base: any GlyphSource) {
        self.base = base
    }

    var metrics: CellMetrics { base.metrics }
    var padding: Int { base.padding }

    func shape(_ scalars: [Unicode.Scalar], style: FontStyle, cellSpan: Int?) -> ShapedCluster {
        let cluster = base.shape(scalars, style: style, cellSpan: cellSpan)
        if isRecording { lastShape = (scalars, style, cluster) }
        return cluster
    }

    func rasterize(_ cluster: ShapedCluster, style: FontStyle) -> RasterizedGlyph? {
        let raster = base.rasterize(cluster, style: style)
        guard isRecording else { return raster }
        guard let shaped = lastShape, shaped.cluster == cluster, shaped.style == style else {
            unmatchedRasterizations += 1
            return raster
        }
        entries.append(Entry(kind: raster == nil ? .empty : .glyph, scalars: shaped.scalars, style: style,
                             cellSpan: cluster.cellSpan, face: base.name(of: cluster.face), raster: raster))
        lastShape = nil
        return raster
    }

    func sprite(for scalar: Unicode.Scalar) -> RasterizedGlyph? {
        let raster = base.sprite(for: scalar)
        if isRecording {
            entries.append(Entry(kind: raster == nil ? .noSprite : .sprite, scalars: [scalar], style: .regular,
                                 cellSpan: 1, face: nil, raster: raster))
        }
        return raster
    }

    func name(of face: FontFace) -> String {
        base.name(of: face)
    }
}

// MARK: - Replaying a glyph table

/// A `GlyphSource` that answers from a reference's glyph table instead of a font: the same metrics,
/// padding, bitmap sizes, bearings and pages, in the order the reference's cache asked for them.
/// The bitmaps are blank, because no instance byte depends on a pixel.
///
/// A request the table cannot answer is recorded in `misses` and answered with nothing to draw, so
/// the frame still builds and the dump says what was missing.
public final class GlyphTableSource: GlyphSource {
    public let metrics: CellMetrics
    public let padding: Int
    /// Requests the table had no entry for, one line each.
    public private(set) var misses: [String] = []

    private let entries: [FrameDump.Glyph]

    private struct ClusterKey: Hashable {
        let scalars: [UInt32]
        let style: String
        let span: Int
    }
    /// Each key's entries not yet handed out, in table order.
    private var clusters: [ClusterKey: [Int]] = [:]
    private var sprites: [UInt32: [Int]] = [:]

    /// Face index for a request the table could not answer.
    private static let missingFace = FontFace(rawValue: .max)

    public init(_ dump: FrameDump) throws {
        metrics = dump.metrics.cellMetrics(scale: dump.scale)
        padding = dump.padding
        entries = dump.glyphs
        for (index, entry) in entries.enumerated() {
            guard AtlasDump.style(named: entry.style) != nil else {
                throw FrameDumpError(description: "glyph \(index): unknown style \(entry.style)")
            }
            switch entry.kind {
            case .glyph, .sprite:
                guard entry.width != nil, entry.height != nil, entry.bearingX != nil, entry.bearingTop != nil,
                      entry.page == "grayscale" || entry.page == "color"
                else { throw FrameDumpError(description: "glyph \(index) (\(entry.label)): a packed entry needs width, height, bearings and page") }
            case .empty, .noSprite:
                break
            }
            switch entry.kind {
            case .glyph, .empty:
                clusters[ClusterKey(scalars: entry.scalars, style: entry.style, span: entry.cellSpan), default: []].append(index)
            case .sprite, .noSprite:
                guard entry.scalars.count == 1 else {
                    throw FrameDumpError(description: "glyph \(index): a sprite entry has one scalar")
                }
                sprites[entry.scalars[0], default: []].append(index)
            }
        }
    }

    public func shape(_ scalars: [Unicode.Scalar], style: FontStyle, cellSpan: Int?) -> ShapedCluster {
        let values = scalars.map(\.value)
        let styleName = AtlasDump.styleName(style)
        let key: ClusterKey? = if let cellSpan {
            ClusterKey(scalars: values, style: styleName, span: cellSpan)
        } else {
            clusters.keys.filter { $0.scalars == values && $0.style == styleName }.min { $0.span < $1.span }
        }
        guard let key, var queue = clusters[key], !queue.isEmpty else {
            let request = FrameDump.Glyph(kind: .glyph, scalars: values, style: styleName, cellSpan: cellSpan ?? 0)
            misses.append("no table entry for \(request.label)")
            return ShapedCluster(face: Self.missingFace, glyphs: [], isColor: false, cellSpan: cellSpan ?? 1)
        }
        let index = queue.removeFirst()
        clusters[key] = queue
        let entry = entries[index]
        return ShapedCluster(face: FontFace(rawValue: UInt32(index)),
                             glyphs: entry.kind == .glyph ? [ClusterGlyph(glyph: GlyphID(rawValue: 1))] : [],
                             isColor: entry.page == "color", cellSpan: entry.cellSpan)
    }

    public func rasterize(_ cluster: ShapedCluster, style: FontStyle) -> RasterizedGlyph? {
        let index = Int(cluster.face.rawValue)
        guard cluster.face != Self.missingFace, index < entries.count, entries[index].kind == .glyph else { return nil }
        return Self.blank(entries[index])
    }

    public func sprite(for scalar: Unicode.Scalar) -> RasterizedGlyph? {
        guard var queue = sprites[scalar.value], !queue.isEmpty else {
            misses.append("no table entry for the sprite \(String(format: "U+%04X", scalar.value))")
            return nil
        }
        let index = queue.removeFirst()
        sprites[scalar.value] = queue
        return entries[index].kind == .sprite ? Self.blank(entries[index]) : nil
    }

    public func name(of face: FontFace) -> String {
        let index = Int(face.rawValue)
        guard face != Self.missingFace, index < entries.count else { return "" }
        return entries[index].face ?? ""
    }

    /// A blank bitmap of the entry's size, bearings and page.
    private static func blank(_ entry: FrameDump.Glyph) -> RasterizedGlyph {
        let width = entry.width ?? 0
        let height = entry.height ?? 0
        let isColor = entry.page == "color"
        let bytesPerPixel = isColor ? 4 : 1
        return RasterizedGlyph(width: width, height: height, bytesPerRow: width * bytesPerPixel,
                               bytesPerPixel: bytesPerPixel, bearingX: entry.bearingX ?? 0,
                               bearingTop: entry.bearingTop ?? 0, isColor: isColor,
                               appliedScale: CGFloat(entry.appliedScale ?? 1),
                               pixels: [UInt8](repeating: 0, count: width * height * bytesPerPixel))
    }
}
