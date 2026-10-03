// FontDumpCommands — the Mac font references of WOR-312 S1: `fontmetrics`, `shaping` and
// `symbols`, plus the per-glyph table of `atlas --json` (`AtlasRecorder`, used by RenderCommands).
//
//   tkzmux-vtdump fontmetrics --json [--out <file.json>]
//       CellMetrics of the theme's terminal font (JetBrains Mono) at every configuration in
//       `metricsConfigurations`: 11, 12.5, 13, 14 and 16 pt at 1.6x and 2x, and 40 pt at 2x (80 px,
//       above the 72 ppem where dilation stops). 12.5 pt at 2x is the rounding tie case (ascent
//       25.5, descent 7.5). Each entry also carries the unrounded CoreText inputs.
//
//   tkzmux-vtdump shaping --json [--out <file.json>] [--point-size n] [--scale s]
//       Every cluster of `shapingCorpus` in the four styles through `GraphemeShaper`: cellSpan,
//       glyph count, the font that carries it and the CoreText run fonts behind it.
//
//   tkzmux-vtdump symbols --json [--out <file.json>] [--point-size n] [--scale s]
//       The symbol inventory: for every scalar the agents and the chrome print (and every scalar of
//       the shaping corpus), whether JetBrains Mono covers it, the font CoreText falls back to, and
//       that glyph's advance and ink box, in the four styles.
//
// Without `--out` the JSON goes to stdout. Size and scale default to the theme's terminal font at
// 2x. The JSON is key-sorted and pretty-printed, and holds nothing that changes between two runs of
// one build on one machine. Each file carries the same `environment` (macOS build, CoreText
// version, `AppleFontSmoothing`, display profile). scripts/parity-font-references.sh runs all of
// them and writes Tests/Parity/References/fonts/; the Linux tests decode them
// (Tests/TkzFontsFTTests). macOS only: on Linux these commands exit 1.

#if canImport(Metal)
import CoreGraphics
import CoreText
import Darwin
import Foundation
import TkzCore
import TkzRenderCore
import TkzTerminalRender

enum FontDumpCommands {
    static let schema = 1

    // MARK: - Command lines

    /// The flags every font dump takes; anything else is a usage error.
    private static func parse(_ argv: [String], command: String, sized: Bool) -> Arguments {
        let valueFlags: Set<String> = sized ? ["out", "point-size", "scale"] : ["out"]
        let arguments = Arguments(argv, valueFlags: valueFlags)
        if let unknown = arguments.flags.keys.sorted().first(where: { !valueFlags.contains($0) && $0 != "json" }) {
            fail("tkzmux-vtdump \(command): unknown option --\(unknown)", code: 2)
        }
        if !arguments.positionals.isEmpty {
            fail("tkzmux-vtdump \(command): unexpected argument \(arguments.positionals[0])", code: 2)
        }
        if !arguments.has("json") {
            fail("tkzmux-vtdump \(command): --json is required (the only output format)", code: 2)
        }
        return arguments
    }

    private static func size(_ arguments: Arguments, command: String) -> (pointSize: Double, scale: Double) {
        func positive(_ name: String, default value: Double) -> Double {
            guard let text = arguments.value(name) else { return value }
            guard let parsed = Double(text), parsed.isFinite, parsed > 0 else {
                fail("tkzmux-vtdump \(command): --\(name) must be a positive number", code: 2)
            }
            return parsed
        }
        return (positive("point-size", default: Theme.default.fontMono.terminal), positive("scale", default: 2))
    }

    private static func write(_ data: Data, to path: String?) throws {
        guard let path else {
            FileHandle.standardOutput.write(data)
            return
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func runFontMetrics(_ argv: [String]) throws {
        let arguments = parse(argv, command: "fontmetrics", sized: false)
        try write(encoded(fontMetrics()), to: arguments.value("out"))
    }

    static func runShaping(_ argv: [String]) throws {
        let arguments = parse(argv, command: "shaping", sized: true)
        let (pointSize, scale) = size(arguments, command: "shaping")
        try write(encoded(shaping(pointSize: pointSize, scale: scale)), to: arguments.value("out"))
    }

    static func runSymbols(_ argv: [String]) throws {
        let arguments = parse(argv, command: "symbols", sized: true)
        let (pointSize, scale) = size(arguments, command: "symbols")
        try write(encoded(symbols(pointSize: pointSize, scale: scale)), to: arguments.value("out"))
    }

    /// Pretty, key-sorted JSON with a trailing newline, as `AtlasDump.encoded()`.
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    /// Rounds to 1/10000 px, as `AtlasDump` rounds its ink boxes.
    static func rounded(_ value: CGFloat) -> Double {
        (Double(value) * 10_000).rounded() / 10_000
    }

    /// The theme's terminal font at one size, resolved as the renderer resolves it.
    static func fontSet(pointSize: Double, scale: Double) -> FontSet {
        let mono = Theme.default.fontMono
        return FontSet(family: mono.family, fallback: mono.fallback,
                       pointSize: CGFloat(pointSize), scale: CGFloat(scale))
    }

    static func postScriptName(_ font: CTFont) -> String {
        CTFontCopyPostScriptName(font) as String
    }

    /// UTF-16 glyph lookup in one font, surrogate pairs included; `nil` when it has no glyph.
    static func glyph(of scalar: Unicode.Scalar, in font: CTFont) -> CGGlyph? {
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    // MARK: - fontmetrics

    /// The configurations `fontmetrics` measures: the gated sizes 12.5 and 14 pt, three more, at
    /// both parity scales, and one size above 72 px.
    static let metricsConfigurations: [(pointSize: Double, scale: Double)] = [
        (11, 1.6), (11, 2), (12.5, 1.6), (12.5, 2), (13, 1.6), (13, 2),
        (14, 1.6), (14, 2), (16, 1.6), (16, 2), (40, 2),
    ]

    struct FontMetricsDump: Encodable {
        struct Inputs: Encodable {
            /// What `CellMetrics(font:scale:)` reads from CoreText, unrounded, in device pixels.
            let ascent, descent, leading, maxAdvance, underlinePosition, underlineThickness: Double
            let unitsPerEm: Int
        }
        struct Configuration: Encodable {
            /// PostScript name of the regular face, which the metrics are measured from.
            let font: String
            let family: String
            let usedFallbackFamily: Bool
            let pointSize: Double
            let scale: Double
            let pixelSize: Double
            /// PostScript names of the four style faces.
            let faces: [String: String]
            let needsSyntheticBold: Bool
            let needsSyntheticItalic: Bool
            let metrics: AtlasDump.Metrics
            let inputs: Inputs
        }
        let schema: Int
        let platform: String
        let environment: [String: String]
        let configurations: [Configuration]
    }

    static func fontMetrics() -> FontMetricsDump {
        let configurations = metricsConfigurations.map { pointSize, scale in
            let set = fontSet(pointSize: pointSize, scale: scale)
            let regular = set.font(for: .regular)
            let ascii: [UniChar] = (0x20...0x7E).map { UniChar($0) }
            var glyphs = [CGGlyph](repeating: 0, count: ascii.count)
            _ = CTFontGetGlyphsForCharacters(regular, ascii, &glyphs, ascii.count)
            var advances = [CGSize](repeating: .zero, count: glyphs.count)
            _ = CTFontGetAdvancesForGlyphs(regular, .horizontal, glyphs, &advances, glyphs.count)
            let inputs = FontMetricsDump.Inputs(
                ascent: Double(CTFontGetAscent(regular)),
                descent: Double(CTFontGetDescent(regular)),
                leading: Double(CTFontGetLeading(regular)),
                maxAdvance: Double(advances.reduce(CGFloat(0)) { max($0, $1.width) }),
                underlinePosition: Double(CTFontGetUnderlinePosition(regular)),
                underlineThickness: Double(CTFontGetUnderlineThickness(regular)),
                unitsPerEm: Int(CTFontGetUnitsPerEm(regular)))
            var faces: [String: String] = [:]
            for style in FontStyle.allCases { faces[AtlasDump.styleName(style)] = set.postScriptName(for: style) }
            return FontMetricsDump.Configuration(
                font: set.postScriptName(for: .regular), family: set.resolvedFamily,
                usedFallbackFamily: set.usedFallbackFamily,
                pointSize: pointSize, scale: scale, pixelSize: Double(set.pixelSize),
                faces: faces,
                needsSyntheticBold: set.needsSyntheticBold, needsSyntheticItalic: set.needsSyntheticItalic,
                metrics: AtlasDump.Metrics(CellMetrics(fontSet: set)), inputs: inputs)
        }
        return FontMetricsDump(schema: schema, platform: "macos", environment: MacFontEnvironment.current,
                               configurations: configurations)
    }

    // MARK: - shaping

    /// The shaping corpus: one grapheme cluster per entry, grouped by what it exercises. `agent`
    /// is every non-ASCII glyph of Tests/TkzTerminalCoreTests/Fixtures/claude-tool-run.txt (· ← ⏵ ⏺
    /// ✻ ❯ and the no-break space) plus the agent glyphs WOR-312 S7 inventories. The fixture's box
    /// drawing and block elements (U+2500-259F) are left out: the renderer draws those as sprites
    /// and never shapes them.
    static let shapingCorpus: [(group: String, cluster: String)] = [
        ("zwj", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"),
        ("zwj", "\u{1F469}\u{200D}\u{1F4BB}"),
        ("zwj", "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"),
        ("flag", "\u{1F1F8}\u{1F1EA}"),
        ("flag", "\u{1F1EF}\u{1F1F5}"),
        ("flag", "\u{1F1FA}\u{1F1F8}"),
        ("keycap", "1\u{FE0F}\u{20E3}"),
        ("keycap", "#\u{FE0F}\u{20E3}"),
        ("keycap", "*\u{FE0F}\u{20E3}"),
        ("combining", "e\u{301}"),
        ("combining", "a\u{308}"),
        ("combining", "\u{4F60}\u{301}"),
        ("cjk", "\u{4F60}"), ("cjk", "\u{597D}"), ("cjk", "\u{4E16}"), ("cjk", "\u{754C}"),
        ("cjk", "\u{4E2D}"), ("cjk", "\u{3042}"), ("cjk", "\u{30A2}"), ("cjk", "\u{D55C}"),
        ("cjk", "\u{FF0B}"),
        ("emoji", "\u{1F600}"), ("emoji", "\u{1F389}"), ("emoji", "\u{1F44D}\u{1F3FD}"),
        ("emoji", "\u{2733}\u{FE0F}"), ("emoji", "\u{2764}\u{FE0F}"),
        ("text", "\u{2733}\u{FE0E}"),
        ("agent", "\u{00A0}"), ("agent", "\u{00B7}"), ("agent", "\u{2190}"), ("agent", "\u{23F5}"),
        ("agent", "\u{23FA}"), ("agent", "\u{273B}"), ("agent", "\u{276F}"),
        ("agent", "\u{23BF}"), ("agent", "\u{2722}"), ("agent", "\u{2733}"), ("agent", "\u{2736}"),
        ("agent", "\u{273D}"), ("agent", "\u{21AF}"), ("agent", "\u{2714}"), ("agent", "\u{25D0}"),
    ]

    struct ShapingDump: Encodable {
        struct Run: Encodable {
            /// PostScript name of the run's font.
            let font: String
            let glyphCount: Int
        }
        struct Cluster: Encodable {
            let group: String
            /// Unicode scalar values.
            let scalars: [UInt32]
            let style: String
            let cellSpan: Int
            /// The font `GraphemeShaper` resolved: the first run's, for a multi-run cluster.
            let font: String
            let isColor: Bool
            /// Glyphs the shaper returned, over all runs.
            let glyphCount: Int
            /// True when the single-scalar `CTFontGetGlyphsForCharacters` path shaped it, false for
            /// the CTLine path.
            let fastPath: Bool
            /// The runs behind it: one for the fast path, CoreText's glyph runs otherwise.
            let runs: [Run]
            /// The pen advance of the cluster as shaped, in device pixels.
            let advance: Double
        }
        let schema: Int
        let platform: String
        let environment: [String: String]
        let pointSize: Double
        let scale: Double
        let pixelSize: Double
        let clusters: [Cluster]
    }

    struct ShapingMismatch: Error, CustomStringConvertible {
        let description: String
    }

    static func shaping(pointSize: Double, scale: Double) throws -> ShapingDump {
        let set = fontSet(pointSize: pointSize, scale: scale)
        let shaper = GraphemeShaper(fontSet: set)
        var clusters: [ShapingDump.Cluster] = []
        for (group, text) in shapingCorpus {
            guard text.count == 1, let character = text.first else {
                throw ShapingMismatch(description: "corpus entry \(text.unicodeScalars.map(\.value)) is not one grapheme")
            }
            let scalars = Array(character.unicodeScalars)
            for style in FontStyle.allCases {
                let shaped = shaper.shape(scalars, style: style)
                let primary = set.font(for: scalars, style: style)
                let runs: [ShapingDump.Run]
                let advance: CGFloat
                let fastPath = scalars.count == 1 && scalars[0].value <= 0xFFFF && glyph(of: scalars[0], in: primary) != nil
                if fastPath {
                    // GraphemeShaper's fast path: one glyph from the primary face.
                    runs = [ShapingDump.Run(font: postScriptName(primary), glyphCount: shaped.glyphs.count)]
                    var glyphs = shaped.glyphs.map(\.glyph)
                    var advances = [CGSize](repeating: .zero, count: glyphs.count)
                    _ = CTFontGetAdvancesForGlyphs(shaped.font, .horizontal, &glyphs, &advances, glyphs.count)
                    advance = advances.reduce(0) { $0 + $1.width }
                } else {
                    // The same one-line CTLine `GraphemeShaper.shapeWithCTLine` builds.
                    let line = ctLine(scalars, font: primary)
                    let ctRuns = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
                    runs = ctRuns.map { run in
                        // A run without a font attribute is the primary's, as in the shaper.
                        ShapingDump.Run(font: postScriptName(runFont(run) ?? primary), glyphCount: CTRunGetGlyphCount(run))
                    }
                    advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                }
                // The runs must account for exactly what the shaper returned, or the dump would
                // describe a different shaping than the terminal draws.
                let label = "\(scalars.map { String($0.value, radix: 16) }) \(AtlasDump.styleName(style))"
                guard runs.reduce(0, { $0 + $1.glyphCount }) == shaped.glyphs.count else {
                    throw ShapingMismatch(description: "\(label): run glyph counts do not add up to the shaper's")
                }
                if let first = runs.first, first.font != shaped.fontName {
                    throw ShapingMismatch(description: "\(label): first run \(first.font) is not the shaper's \(shaped.fontName)")
                }
                clusters.append(ShapingDump.Cluster(
                    group: group, scalars: scalars.map(\.value), style: AtlasDump.styleName(style),
                    cellSpan: shaped.cellSpan, font: shaped.fontName, isColor: shaped.isColor,
                    glyphCount: shaped.glyphs.count, fastPath: fastPath, runs: runs,
                    advance: rounded(advance)))
            }
        }
        return ShapingDump(schema: schema, platform: "macos", environment: MacFontEnvironment.current,
                           pointSize: pointSize, scale: scale, pixelSize: Double(set.pixelSize),
                           clusters: clusters)
    }

    /// The line `GraphemeShaper` shapes a cluster with: the primary font, ligatures off.
    private static func ctLine(_ scalars: [Unicode.Scalar], font: CTFont) -> CTLine {
        var text = ""
        for scalar in scalars { text.unicodeScalars.append(scalar) }
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTLigatureAttributeName as NSAttributedString.Key: NSNumber(value: 0),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func runFont(_ run: CTRun) -> CTFont? {
        guard let attributes = CTRunGetAttributes(run) as? [String: Any],
              let value = attributes[kCTFontAttributeName as String] else { return nil }
        return (value as! CTFont)  // swiftlint:disable:this force_cast
    }

    // MARK: - symbols

    /// What the symbol inventory covers, by group. `agent`, `chrome`, `modifier` and `ui` are
    /// WOR-312 S7's lists (Sources/TkzFontsFT/BundledSymbols.swift), `agent` widened by the
    /// fixture's glyphs; `corpus` adds every scalar of the shaping corpus.
    static let symbolGroups: [(group: String, scalars: [Unicode.Scalar])] = [
        ("agent", ["\u{23FA}", "\u{23BF}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}",
                   "\u{21AF}", "\u{2714}", "\u{25D0}", "\u{23F5}",
                   "\u{00A0}", "\u{00B7}", "\u{2190}", "\u{276F}"]),
        ("chrome", ["\u{2387}", "\u{21B5}", "\u{25BE}", "\u{25B8}", "\u{2715}", "\u{25EB}", "\u{25AC}", "\u{2B13}",
                    "\u{263E}", "\u{2600}", "\u{293F}", "\u{2699}", "\u{27F3}", "\u{FF0B}", "\u{00B7}"]),
        ("modifier", ["\u{2318}", "\u{21E7}", "\u{2325}", "\u{2303}", "\u{238B}", "\u{23CE}", "\u{21A9}"]),
        ("ui", ["\u{25C8}", "\u{2328}", "\u{25CF}", "\u{25A0}", "\u{25B6}", "\u{2423}", "\u{21E5}"]),
        ("corpus", shapingCorpus.flatMap { $0.cluster.unicodeScalars }),
    ]

    struct SymbolsDump: Encodable {
        struct Box: Encodable {
            let minX, minY, maxX, maxY: Double
        }
        struct Style: Encodable {
            let style: String
            /// The style's JetBrains Mono face has a glyph for the scalar.
            let covered: Bool
            /// PostScript name of the font the shaper draws it with (CoreText's fallback when not
            /// covered).
            let font: String
            let isColor: Bool
            let glyphCount: Int
            /// The first glyph's advance in device pixels, and as a fraction of the pixel size.
            let advance: Double?
            let advanceEm: Double?
            /// The first glyph's ink box in device pixels from the pen origin, y up; `nil` without ink.
            let bbox: Box?
        }
        struct Symbol: Encodable {
            let scalar: UInt32
            let hex: String
            let groups: [String]
            let cellSpan: Int
            let styles: [Style]
        }
        let schema: Int
        let platform: String
        let environment: [String: String]
        let pointSize: Double
        let scale: Double
        let pixelSize: Double
        /// PostScript name of the regular face the coverage is checked against.
        let primary: String
        let symbols: [Symbol]
    }

    static func symbols(pointSize: Double, scale: Double) -> SymbolsDump {
        let set = fontSet(pointSize: pointSize, scale: scale)
        let shaper = GraphemeShaper(fontSet: set)

        // Scalar → groups, ASCII and default-ignorable scalars (joiners, variation selectors) left out.
        var groups: [UInt32: Set<String>] = [:]
        for (group, scalars) in symbolGroups {
            for scalar in scalars where scalar.value > 0x7E && !scalar.properties.isDefaultIgnorableCodePoint {
                groups[scalar.value, default: []].insert(group)
            }
        }

        let symbols = groups.keys.sorted().compactMap { value -> SymbolsDump.Symbol? in
            guard let scalar = Unicode.Scalar(value) else { return nil }
            let styles = FontStyle.allCases.map { style -> SymbolsDump.Style in
                let shaped = shaper.shape([scalar], style: style)
                var advance: Double?, advanceEm: Double?, bbox: SymbolsDump.Box?
                if var first = shaped.glyphs.first?.glyph, first != 0 {
                    var size = CGSize.zero
                    _ = CTFontGetAdvancesForGlyphs(shaped.font, .horizontal, &first, &size, 1)
                    advance = rounded(size.width)
                    advanceEm = (Double(size.width / set.pixelSize) * 1_000_000).rounded() / 1_000_000
                    var rect = CGRect.zero
                    _ = CTFontGetBoundingRectsForGlyphs(shaped.font, .horizontal, &first, &rect, 1)
                    if !rect.isNull, !rect.isEmpty {
                        bbox = SymbolsDump.Box(minX: rounded(rect.minX), minY: rounded(rect.minY),
                                               maxX: rounded(rect.maxX), maxY: rounded(rect.maxY))
                    }
                }
                return SymbolsDump.Style(
                    style: AtlasDump.styleName(style),
                    covered: glyph(of: scalar, in: set.font(for: style)) != nil,
                    font: shaped.fontName, isColor: shaped.isColor, glyphCount: shaped.glyphs.count,
                    advance: advance, advanceEm: advanceEm, bbox: bbox)
            }
            return SymbolsDump.Symbol(
                scalar: value, hex: "U+" + String(format: "%04X", value),
                groups: groups[value, default: []].sorted(),
                cellSpan: GraphemeShaper.defaultCellSpan(for: [scalar]), styles: styles)
        }
        return SymbolsDump(schema: schema, platform: "macos", environment: MacFontEnvironment.current,
                           pointSize: pointSize, scale: scale, pixelSize: Double(set.pixelSize),
                           primary: set.postScriptName(for: .regular), symbols: symbols)
    }
}

// MARK: - atlas --json

/// The CoreText `GlyphSource` with a tap: it remembers the last bitmap the glyph cache asked for,
/// so `atlas --json` can record what was drawn without the cache or the rasterizer changing. Every
/// call goes straight through, so the atlas pages are the ones `atlas` writes without `--json`.
final class AtlasRecorder: GlyphSource {
    enum Drawn {
        case sprite(RasterizedGlyph)
        case glyph(ShapedCluster, RasterizedGlyph)
    }

    let base: CoreTextGlyphSource
    /// What the last cache miss drew; the caller clears it before each lookup.
    var drawn: Drawn?

    init(base: CoreTextGlyphSource) {
        self.base = base
    }

    var metrics: CellMetrics { base.metrics }
    var padding: Int { base.padding }

    func shape(_ scalars: [Unicode.Scalar], style: FontStyle, cellSpan: Int?) -> ShapedCluster {
        base.shape(scalars, style: style, cellSpan: cellSpan)
    }

    func rasterize(_ cluster: ShapedCluster, style: FontStyle) -> RasterizedGlyph? {
        let raster = base.rasterize(cluster, style: style)
        if let raster { drawn = .glyph(cluster, raster) }
        return raster
    }

    func sprite(for scalar: Unicode.Scalar) -> RasterizedGlyph? {
        let raster = base.sprite(for: scalar)
        if let raster { drawn = .sprite(raster) }
        return raster
    }

    func name(of face: FontFace) -> String {
        base.name(of: face)
    }

    /// The ink union a cluster's bitmap was placed from, as `GlyphRasterizer.rasterize` computes it:
    /// `CTFontGetBoundingRectsForGlyphs` at each glyph's offset, grown by the synthetic-bold stroke,
    /// before the fit scale.
    func inkBox(of cluster: ShapedCluster, style: FontStyle) -> AtlasDump.Box? {
        guard let font = base.font(of: cluster.face) else { return nil }
        let glyphs = cluster.glyphs.map { CGGlyph(truncatingIfNeeded: $0.glyph.rawValue) }
        var bounds = [CGRect](repeating: .zero, count: glyphs.count)
        _ = CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &bounds, glyphs.count)
        var union = CGRect.null
        for (i, rect) in bounds.enumerated() where !rect.isNull && !rect.isEmpty {
            union = union.union(rect.offsetBy(dx: cluster.glyphs[i].xOffset, dy: cluster.glyphs[i].yOffset))
        }
        guard !union.isNull, union.width > 0, union.height > 0 else { return nil }
        if style.isBold && base.fontSet.needsSyntheticBold {
            let stroke = max(1, CTFontGetSize(font) * 0.03)
            union = union.insetBy(dx: -stroke, dy: -stroke)
        }
        return AtlasDump.Box(GlyphBounds(minX: union.minX, minY: union.minY, maxX: union.maxX, maxY: union.maxY))
    }

    /// The `AtlasDump` entry for what the last lookup drew and where the cache put it.
    func entry(for scalars: [Unicode.Scalar], style: FontStyle, placed: CachedGlyph) -> AtlasDump.Glyph? {
        switch drawn {
        case nil:
            return nil
        case .sprite(let raster):
            return AtlasDump.Glyph(
                scalars: scalars.map(\.value), style: AtlasDump.styleName(.regular), face: "", sprite: true,
                cellSpan: 1, page: "grayscale", x: placed.slot.x, y: placed.slot.y,
                width: raster.width, height: raster.height,
                bearingX: raster.bearingX, bearingTop: raster.bearingTop,
                appliedScale: Double(raster.appliedScale), bbox: nil)
        case .glyph(let cluster, let raster):
            return AtlasDump.Glyph(
                scalars: scalars.map(\.value), style: AtlasDump.styleName(style),
                face: base.name(of: cluster.face), sprite: false, cellSpan: cluster.cellSpan,
                page: raster.isColor ? "color" : "grayscale", x: placed.slot.x, y: placed.slot.y,
                width: raster.width, height: raster.height,
                bearingX: raster.bearingX, bearingTop: raster.bearingTop,
                appliedScale: Double(raster.appliedScale), bbox: inkBox(of: cluster, style: style))
        }
    }
}

// MARK: - Environment

/// Whatever the Mac's font output depends on that a command line does not say. Every font dump
/// carries it, and scripts/parity-font-references.sh copies it into the manifest.
enum MacFontEnvironment {
    static var current: [String: String] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "macOSBuild": sysctlString("kern.osversion") ?? "?",
            "macOSVersion": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "coreTextVersion": String(format: "0x%08X", CTGetCoreTextVersion()),
            "AppleFontSmoothing": appleFontSmoothing,
            "displayProfile": displayProfile,
        ]
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `defaults read -g AppleFontSmoothing`, or "unset".
    static var appleFontSmoothing: String {
        guard let value = CFPreferencesCopyValue("AppleFontSmoothing" as CFString, kCFPreferencesAnyApplication,
                                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return "unset"
        }
        return "\(value)"
    }

    /// The main display's colour profile by its description, or "none, headless" without a display.
    /// The dumps draw into offscreen contexts with device colour spaces, so this is a record, not
    /// an input.
    static var displayProfile: String {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return "none, headless" }
        let space = CGDisplayCopyColorSpace(CGMainDisplayID())
        if let name = space.name { return name as String }
        guard let icc = space.copyICCData() as Data? else { return "no ICC profile" }
        return iccDescription(icc) ?? "unnamed ICC profile (\(icc.count) bytes)"
    }

    /// The `desc` tag of an ICC profile: `mluc` (v4) or `desc` (v2) text.
    static func iccDescription(_ icc: Data) -> String? {
        let bytes = [UInt8](icc)
        func u32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        guard let tagCount = u32(128), tagCount < 1000 else { return nil }
        for i in 0..<tagCount {
            let entry = 132 + i * 12
            guard let signature = u32(entry), signature == 0x6465_7363,  // 'desc'
                  let offset = u32(entry + 4), let type = u32(offset) else { continue }
            if type == 0x6D6C_7563 {  // 'mluc': the first record, UTF-16BE
                guard let length = u32(offset + 20), let start = u32(offset + 24).map({ offset + $0 }),
                      start + length <= bytes.count else { return nil }
                let units = stride(from: start, to: start + length - 1, by: 2).map {
                    UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
                }
                return String(decoding: units, as: UTF16.self)
            }
            if type == 0x6465_7363 {  // 'desc': an ASCII count and string
                guard let length = u32(offset + 8), length > 0, offset + 12 + length <= bytes.count else { return nil }
                return String(decoding: bytes[(offset + 12)..<(offset + 12 + length)].prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        return nil
    }
}

#else

/// The font references come from CoreText; Linux has its own tests against them.
enum FontDumpCommands {
    static func runFontMetrics(_ argv: [String]) throws { macOSOnly("fontmetrics") }
    static func runShaping(_ argv: [String]) throws { macOSOnly("shaping") }
    static func runSymbols(_ argv: [String]) throws { macOSOnly("symbols") }

    private static func macOSOnly(_ command: String) -> Never {
        fail("tkzmux-vtdump \(command): macOS only (the CoreText reference of WOR-312 S1)", code: 1)
    }
}
#endif
