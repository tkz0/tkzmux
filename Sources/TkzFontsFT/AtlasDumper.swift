// AtlasDumper — the Linux backend of `tkzmux-vtdump atlas --json` (WOR-312 S5).
//
// Rasterizes a sample the way the Mac's `RenderCommands.atlas` fills its GlyphCache — every
// character of the sample in each of the four styles, keyed by (scalars, style, cellSpan), packed
// into a 512² grayscale and a 256² colour page that double up to 2048² — and returns both pages
// and an `AtlasDump` (TkzRenderCore), the JSON schema the Mac reference shares. The per-glyph
// entries are what parity compares; the page layout follows the Mac's shelf packer so the PNGs can
// also be eyeballed side by side.
//
// Box-drawing and block-element sprites (U+2500-259F) are packed the way the Mac's cache packs
// them: once, under `regular`, when the first style asks, drawn by `BoxSpriteRasterizer` from the
// geometry the Mac's `BoxSprites` paints, with `sprite: true`, no face and no ink box.
//
// Not here yet: the PNG files and the command line. vtdump builds on Linux since WOR-311 S7, but
// its `atlas` is a stub (Sources/tkzmux-vtdump/UnavailableCommands.swift) until it is wired to this
// dumper, writing `pages` with TkzPNG (`AtlasPage.pngLayout`) and the JSON beside them. TkzPNG is
// not a dependency of this module, which ships in the app.
//
// The packer below follows TkzRenderCore's `GlyphAtlas` (WOR-311 S3): same best-fit shelves, same
// doubling, but no rebuild (a dump that overflows a 2048² page throws instead of silently dropping
// glyphs) and a value type, so a dump is `Sendable`.

import Foundation
import TkzRenderCore

/// One atlas page's pixels: A8 coverage (`grayscale`) or premultiplied BGRA (`color`), rows
/// top-down.
public struct AtlasPage: Sendable, Equatable {
    public let kind: String
    public private(set) var size: Int
    public let bytesPerPixel: Int
    public private(set) var pixels: [UInt8]

    fileprivate var shelves: [(y: Int, height: Int, nextX: Int)] = []

    public static func == (a: AtlasPage, b: AtlasPage) -> Bool {
        a.kind == b.kind && a.size == b.size && a.pixels == b.pixels
    }

    init(kind: String, size: Int, bytesPerPixel: Int) {
        self.kind = kind
        self.size = size
        self.bytesPerPixel = bytesPerPixel
        self.pixels = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
    }

    static let maxSize = 2048

    /// The pixels for a PNG encoder: unchanged A8 for a grayscale page; straight (unpremultiplied)
    /// RGBA for a colour page, as ImageIO writes the Mac's premultiplied BGRA page.
    public var pngLayout: [UInt8] {
        guard bytesPerPixel == 4 else { return pixels }
        var out = [UInt8](repeating: 0, count: pixels.count)
        var i = 0
        while i < pixels.count {
            let a = Int(pixels[i + 3])
            if a > 0 {
                out[i] = UInt8(min(255, (Int(pixels[i + 2]) * 255 + a / 2) / a))
                out[i + 1] = UInt8(min(255, (Int(pixels[i + 1]) * 255 + a / 2) / a))
                out[i + 2] = UInt8(min(255, (Int(pixels[i]) * 255 + a / 2) / a))
                out[i + 3] = UInt8(a)
            }
            i += 4
        }
        return out
    }

    /// Packs a bitmap; its slot's top-left corner, or `nil` when even a 2048² page is full.
    mutating func insert(_ glyph: RasterizedGlyph) -> (x: Int, y: Int)? {
        while true {
            if let slot = pack(width: glyph.width, height: glyph.height) {
                blit(glyph, x: slot.x, y: slot.y)
                return slot
            }
            guard size < Self.maxSize else { return nil }
            grow()
        }
    }

    /// The Mac's best fit: the shortest shelf still tall enough, else a new shelf on top.
    private mutating func pack(width: Int, height: Int) -> (x: Int, y: Int)? {
        guard width <= size, height <= size else { return nil }
        var best: Int?
        for (i, shelf) in shelves.enumerated() where shelf.height >= height && shelf.nextX + width <= size {
            if best == nil || shelf.height < shelves[best!].height { best = i }
        }
        if let i = best {
            let slot = (x: shelves[i].nextX, y: shelves[i].y)
            shelves[i].nextX += width
            return slot
        }
        let top = shelves.reduce(0) { max($0, $1.y + $1.height) }
        guard top + height <= size else { return nil }
        shelves.append((y: top, height: height, nextX: width))
        return (0, top)
    }

    private mutating func blit(_ glyph: RasterizedGlyph, x: Int, y: Int) {
        let rowBytes = glyph.width * bytesPerPixel
        for row in 0..<glyph.height {
            let source = row * glyph.bytesPerRow
            let destination = ((y + row) * size + x) * bytesPerPixel
            pixels.replaceSubrange(destination..<(destination + rowBytes),
                                   with: glyph.pixels[source..<(source + rowBytes)])
        }
    }

    private mutating func grow() {
        let newSize = min(size * 2, Self.maxSize)
        var grown = [UInt8](repeating: 0, count: newSize * newSize * bytesPerPixel)
        let oldStride = size * bytesPerPixel, newStride = newSize * bytesPerPixel
        for row in 0..<size {
            grown.replaceSubrange((row * newStride)..<(row * newStride + oldStride),
                                  with: pixels[(row * oldStride)..<((row + 1) * oldStride)])
        }
        pixels = grown
        size = newSize
    }
}

public enum AtlasDumpError: Error, Sendable, Equatable {
    /// The sample does not fit a 2048² page.
    case pageFull(kind: String)
}

public enum AtlasDumper {
    /// The Mac's default sample (`RenderCommands.defaultSample`): printable ASCII plus box drawing,
    /// a CJK pair and two emoji.
    public static let defaultSample: String = {
        let ascii = String(String.UnicodeScalarView((0x20...0x7E).compactMap { Unicode.Scalar($0) }))
        return ascii + "─│┌┐└┘├┤┬┴┼█▀▄░▒▓你好世界😀🎉"
    }()

    /// The scalars the Mac draws as box sprites instead of font glyphs (`BoxSpriteGeometry.covers`).
    static func isSprite(_ scalars: [Unicode.Scalar]) -> Bool {
        BoxSpriteGeometry.covers(scalars)
    }

    public struct Output: Sendable {
        public let dump: AtlasDump
        public let grayscale: AtlasPage
        public let color: AtlasPage
    }

    /// Rasterizes `sample` in every style into fresh pages.
    ///
    /// - Parameters:
    ///   - filePrefix: the PNG base name the JSON's `pages` entries point at
    ///     (`<filePrefix>-grayscale.png`, `<filePrefix>-color.png`).
    ///   - environment: extra entries for the dump's `environment` (the fallback configuration in
    ///     use, say), merged over the library versions.
    public static func dump(faces: TerminalFaces,
                            sample: String = defaultSample,
                            thicken: Bool,
                            dilation: Dilation? = nil,
                            filePrefix: String,
                            environment: [String: String] = [:]) throws -> Output {
        let options = RasterizerOptions(thicken: thicken, dilation: dilation, syntheticBold: faces.needsSyntheticBold)
        let sprites = BoxSpriteRasterizer(metrics: faces.metrics, padding: options.padding)
        var grayscale = AtlasPage(kind: "grayscale", size: 512, bytesPerPixel: 1)
        var color = AtlasPage(kind: "color", size: 256, bytesPerPixel: 4)

        struct Key: Hashable {
            let scalars: [UInt32]
            let style: FontStyle
            let span: Int
        }
        var seen = Set<Key>()
        var glyphs: [AtlasDump.Glyph] = []
        for character in sample where !character.isNewline {
            let scalars = Array(character.unicodeScalars)
            if isSprite(scalars) {
                guard seen.insert(Key(scalars: scalars.map(\.value), style: .regular, span: 1)).inserted,
                      let raster = sprites.rasterize(scalars[0]) else { continue }
                guard let slot = grayscale.insert(raster) else { throw AtlasDumpError.pageFull(kind: "grayscale") }
                glyphs.append(AtlasDump.Glyph(
                    scalars: scalars.map(\.value), style: AtlasDump.styleName(.regular),
                    face: "", sprite: true, cellSpan: 1,
                    page: "grayscale", x: slot.x, y: slot.y, width: raster.width, height: raster.height,
                    bearingX: raster.bearingX, bearingTop: raster.bearingTop,
                    appliedScale: Double(raster.appliedScale), bbox: nil))
                continue
            }
            for style in FontStyle.allCases {
                let shaped = faces.shape(scalars, style: style)
                guard seen.insert(Key(scalars: scalars.map(\.value), style: style, span: shaped.cellSpan)).inserted,
                      let result = faces.rasterizeWithInk(shaped, style: style, options: options) else { continue }
                let raster = result.glyph
                let kind = raster.isColor ? "color" : "grayscale"
                let slot = raster.isColor ? color.insert(raster) : grayscale.insert(raster)
                guard let slot else { throw AtlasDumpError.pageFull(kind: kind) }
                glyphs.append(AtlasDump.Glyph(
                    scalars: scalars.map(\.value), style: AtlasDump.styleName(style),
                    face: faces.name(of: shaped.face), sprite: false, cellSpan: shaped.cellSpan,
                    page: kind, x: slot.x, y: slot.y, width: raster.width, height: raster.height,
                    bearingX: raster.bearingX, bearingTop: raster.bearingTop,
                    appliedScale: Double(raster.appliedScale), bbox: AtlasDump.Box(result.ink)))
            }
        }

        let applied = options.effectiveDilation(pixelSize: faces.pixelSize)
        var env = [
            "freetype": FontLibraryVersions.freeType ?? "?",
            "harfbuzz": FontLibraryVersions.harfBuzz,
            "fontconfig": FontLibraryVersions.fontconfig,
            "dilation": "rx=\(applied.rx) ry=\(applied.ry)",
        ]
        env.merge(environment) { _, new in new }
        let dump = AtlasDump(
            platform: "linux", pointSize: Double(faces.pointSize), scale: Double(faces.scale),
            pixelSize: Double(faces.pixelSize), thicken: thicken, padding: options.padding,
            metrics: faces.metrics, environment: env,
            pages: [
                AtlasDump.Page(kind: "grayscale", size: grayscale.size, file: "\(filePrefix)-grayscale.png"),
                AtlasDump.Page(kind: "color", size: color.size, file: "\(filePrefix)-color.png"),
            ],
            glyphs: glyphs)
        return Output(dump: dump, grayscale: grayscale, color: color)
    }
}
