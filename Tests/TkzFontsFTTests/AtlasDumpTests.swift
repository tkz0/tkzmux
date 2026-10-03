// AtlasDumpTests — the Linux side of `vtdump atlas --json` (WOR-312 S5), and the comparisons with
// the reference Mac's atlases that S1 commits under Tests/Parity/References/fonts/.
//
// The Mac comparisons skip until those files exist. Each reference is one `AtlasDump` JSON (the
// schema in TkzRenderCore, shared with the Mac exporter) plus the PNG pages it names.
// TODO(WOR-312 S1): write the references under `MacAtlasReference.fileName` for 14 pt at 1.6x and
// 2x, thicken 0 and 1. TODO(WOR-322 S1): score masks with the TkzParity comparator once it exists;
// `MacAtlasReference.meanAbsoluteDifference` is a stand-in with the same alignment rule (pen
// origin to pen origin).

import Foundation
import Testing
import TkzPNG
import TkzRenderCore
@testable import TkzFontsFT

enum MacAtlasReference {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Parity/References/fonts", isDirectory: true)

    /// `atlas-14pt-1.6x-thicken0.json`: the name S1's exporter writes the JSON under.
    static func fileName(pointSize: Double, scale: Double, thicken: Bool) -> String {
        "atlas-\(format(pointSize))pt-\(format(scale))x-thicken\(thicken ? 1 : 0).json"
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    static func url(pointSize: Double, scale: Double, thicken: Bool) -> URL {
        directory.appendingPathComponent(fileName(pointSize: pointSize, scale: scale, thicken: thicken))
    }

    static func exists(pointSize: Double, scale: Double, thicken: Bool) -> Bool {
        FileManager.default.fileExists(atPath: url(pointSize: pointSize, scale: scale, thicken: thicken).path)
    }

    /// The configurations S5's acceptance names: 22.4 px and 28 px.
    static let configurations: [(pointSize: Double, scale: Double)] = [(14, 1.6), (14, 2)]

    static var anyPresent: Bool {
        configurations.contains { c in [false, true].contains { exists(pointSize: c.pointSize, scale: c.scale, thicken: $0) } }
    }

    struct Loaded {
        let dump: AtlasDump
        /// Decoded pages by kind, straight RGBA.
        let pages: [String: PNGImage]

        /// The glyph's bitmap from its page: one coverage byte per pixel for grayscale.
        func coverage(_ glyph: AtlasDump.Glyph) -> [UInt8] {
            guard let page = pages[glyph.page] else { return [] }
            var out: [UInt8] = []
            out.reserveCapacity(glyph.width * glyph.height)
            for y in glyph.y..<(glyph.y + glyph.height) {
                for x in glyph.x..<(glyph.x + glyph.width) { out.append(page.pixels[(y * page.width + x) * 4]) }
            }
            return out
        }
    }

    static func load(pointSize: Double, scale: Double, thicken: Bool) throws -> Loaded {
        try load(url(pointSize: pointSize, scale: scale, thicken: thicken))
    }

    static func load(_ url: URL) throws -> Loaded {
        let dump = try JSONDecoder().decode(AtlasDump.self, from: Data(contentsOf: url))
        var pages: [String: PNGImage] = [:]
        for page in dump.pages {
            let file = url.deletingLastPathComponent().appendingPathComponent(page.file)
            pages[page.kind] = try PNG.decode([UInt8](Data(contentsOf: file)))
        }
        return Loaded(dump: dump, pages: pages)
    }

    /// Mean |Δ| over the union of two A8 bitmaps placed by their pen origins (bearings), in
    /// 0...255 units; pixels outside a bitmap count as 0.
    static func meanAbsoluteDifference(_ a: [UInt8], _ ag: AtlasDump.Glyph, _ b: [UInt8], _ bg: AtlasDump.Glyph) -> (sum: Double, count: Int) {
        let left = min(ag.bearingX, bg.bearingX), right = max(ag.bearingX + ag.width, bg.bearingX + bg.width)
        let top = max(ag.bearingTop, bg.bearingTop), bottom = min(ag.bearingTop - ag.height, bg.bearingTop - bg.height)
        func value(_ pixels: [UInt8], _ g: AtlasDump.Glyph, _ x: Int, _ yUp: Int) -> Int {
            let column = x - g.bearingX, row = g.bearingTop - 1 - yUp
            guard column >= 0, column < g.width, row >= 0, row < g.height else { return 0 }
            return Int(pixels[row * g.width + column])
        }
        var sum = 0.0, count = 0
        for yUp in bottom..<top {
            for x in left..<right {
                sum += Double(abs(value(a, ag, x, yUp) - value(b, bg, x, yUp)))
                count += 1
            }
        }
        return (sum, count)
    }
}

@Suite("Atlas dump", .serialized)
struct AtlasDumpTests {
    static func dump(pointSize: CGFloat = 14, scale: CGFloat = 1.6, thicken: Bool) throws -> AtlasDumper.Output {
        let faces = try TerminalFaces(pointSize: pointSize, scale: scale, fallback: ColorFixtures.fallback)
        return try AtlasDumper.dump(faces: faces, thicken: thicken, filePrefix: "atlas",
                                    environment: ["fallback": TestFallbacks.parityFontsPresent ? "parity" : "system"])
    }

    @Test("the default sample: ASCII and the CJK/emoji tail in four styles, sprites once each")
    func contents() throws {
        let output = try Self.dump(thicken: true)
        let dump = output.dump
        #expect(dump.schema == AtlasDump.currentSchema && dump.platform == "linux")
        #expect(dump.padding == 2 && dump.thicken && dump.pixelSize == 14 * 1.6)
        #expect(dump.metrics.width == 14 && dump.metrics.height == 30)
        #expect(dump.environment["freetype"] != nil && dump.environment["fallback"] != nil)
        #expect(dump.pages.map(\.file) == ["atlas-grayscale.png", "atlas-color.png"])

        // The box-drawing tail is drawn, once per scalar under `regular`, the way the Mac caches it.
        let sprites = dump.glyphs.filter(\.sprite)
        #expect(sprites.map(\.scalars) == "─│┌┐└┘├┤┬┴┼█▀▄░▒▓".unicodeScalars.map { [$0.value] })
        #expect(sprites.allSatisfy { $0.style == "regular" && $0.face.isEmpty && $0.bbox == nil && $0.cellSpan == 1 })
        #expect(sprites.allSatisfy { $0.page == "grayscale" && $0.width == 14 + 4 && $0.height == 30 + 4 })
        #expect(!dump.glyphs.contains { !$0.sprite && (0x2500...0x259F).contains($0.scalars[0]) })
        for code in 0x21...0x7E {
            let entries = dump.glyphs.filter { $0.scalars == [UInt32(code)] }
            #expect(entries.map(\.style) == ["regular", "bold", "italic", "boldItalic"], "U+\(String(code, radix: 16))")
            #expect(entries.allSatisfy { $0.face.hasPrefix("JetBrainsMono-") && $0.page == "grayscale" && $0.cellSpan == 1 })
        }
        #expect(!dump.glyphs.contains { $0.scalars == [0x20] })
        // Every slot lies inside its page and matches the pixels packed there.
        for glyph in dump.glyphs {
            let page = glyph.page == "grayscale" ? output.grayscale : output.color
            #expect(glyph.x + glyph.width <= page.size && glyph.y + glyph.height <= page.size)
        }
        if ColorFixtures.notoColorEmoji != nil {
            let smile = try #require(dump.glyphs.first { $0.scalars == [0x1F600] })
            #expect(smile.page == "color" && smile.face == "NotoColorEmoji" && smile.cellSpan == 2)
        }
    }

    @Test("two runs give byte-identical JSON and pages")
    func deterministic() throws {
        let a = try Self.dump(thicken: true), b = try Self.dump(thicken: true)
        #expect(try a.dump.encoded() == b.dump.encoded())
        #expect(a.grayscale == b.grayscale && a.color == b.color)
    }

    @Test("the JSON round-trips, and the pages encode and decode as PNG")
    func roundTrip() throws {
        let output = try Self.dump(scale: 2, thicken: false)
        let decoded = try JSONDecoder().decode(AtlasDump.self, from: output.dump.encoded())
        #expect(decoded == output.dump)

        let gray = try PNG.decode(PNG.encode(output.grayscale.pngLayout, width: output.grayscale.size,
                                             height: output.grayscale.size, colorType: .gray))
        #expect(stride(from: 0, to: gray.pixels.count, by: 4).map { gray.pixels[$0] } == output.grayscale.pixels)
        let color = try PNG.decode(PNG.encode(output.color.pngLayout, width: output.color.size,
                                              height: output.color.size, colorType: .rgba))
        #expect(color.premultipliedBGRA().count == output.color.pixels.count)
        // Opaque pixels survive the premultiply round trip exactly.
        let restored = color.premultipliedBGRA()
        for i in stride(from: 0, to: restored.count, by: 4) where output.color.pixels[i + 3] == 255 {
            #expect(Array(restored[i..<(i + 4)]) == Array(output.color.pixels[i..<(i + 4)]))
        }
    }

    @Test("the reference plumbing: a dump written as JSON and PNGs loads back and compares equal to itself")
    func referencePlumbing() throws {
        let output = try Self.dump(thicken: false)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkzmux-atlas-dump-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = directory.appendingPathComponent("atlas.json")
        try output.dump.encoded().write(to: json)
        try Data(PNG.encode(output.grayscale.pngLayout, width: output.grayscale.size, height: output.grayscale.size,
                            colorType: .gray)).write(to: directory.appendingPathComponent("atlas-grayscale.png"))
        try Data(PNG.encode(output.color.pngLayout, width: output.color.size, height: output.color.size,
                            colorType: .rgba)).write(to: directory.appendingPathComponent("atlas-color.png"))

        let loaded = try MacAtlasReference.load(json)
        #expect(loaded.dump == output.dump)
        let h = try #require(loaded.dump.glyphs.first { $0.scalars == [0x48] && $0.style == "regular" })
        let coverage = loaded.coverage(h)
        #expect(coverage.count == h.width * h.height && coverage.contains(255))
        let same = MacAtlasReference.meanAbsoluteDifference(coverage, h, coverage, h)
        #expect(same.sum == 0 && same.count == h.width * h.height)
        // One pixel of horizontal misalignment shows up.
        var shifted = h
        shifted.bearingX += 1
        #expect(MacAtlasReference.meanAbsoluteDifference(coverage, h, coverage, shifted).sum > 0)
    }

    // MARK: - The reference Mac (WOR-312 S1)

    static let referenceSkip: Comment = "DEFERRED: Tests/Parity/References/fonts/atlas-*.json comes from WOR-312 S1 on the reference Mac"

    @Test("extents and bearings of ASCII × 4 styles are within ±1 px of the Mac at 22.4 and 28 px",
          .enabled(if: MacAtlasReference.anyPresent, referenceSkip))
    func extentsMatchMac() throws {
        for configuration in MacAtlasReference.configurations {
            for thicken in [false, true] where MacAtlasReference.exists(pointSize: configuration.pointSize,
                                                                       scale: configuration.scale, thicken: thicken) {
                let mac = try MacAtlasReference.load(pointSize: configuration.pointSize, scale: configuration.scale, thicken: thicken)
                let linux = try Self.dump(pointSize: configuration.pointSize, scale: configuration.scale, thicken: thicken).dump
                #expect(mac.dump.padding == linux.padding)
                for code in 0x21...0x7E {
                    for style in ["regular", "bold", "italic", "boldItalic"] {
                        let label = "U+\(String(code, radix: 16)) \(style) at \(configuration.pointSize)@\(configuration.scale) thicken \(thicken)"
                        let m = try #require(mac.dump.glyphs.first { $0.scalars == [UInt32(code)] && $0.style == style }, "\(label): missing on the Mac")
                        let l = try #require(linux.glyphs.first { $0.scalars == [UInt32(code)] && $0.style == style }, "\(label): missing on Linux")
                        #expect(abs(m.width - l.width) <= 1 && abs(m.height - l.height) <= 1, "\(label): size")
                        #expect(abs(m.bearingX - l.bearingX) <= 1 && abs(m.bearingTop - l.bearingTop) <= 1, "\(label): bearings")
                        #expect(m.face == l.face, "\(label): face")
                    }
                }
            }
        }
    }

    @Test("with thicken=0 the ASCII masks differ from the Mac's by a mean |Δ| ≤ 2/255",
          .enabled(if: MacAtlasReference.configurations.contains { MacAtlasReference.exists(pointSize: $0.pointSize, scale: $0.scale, thicken: false) },
                   referenceSkip))
    func masksMatchMac() throws {
        for configuration in MacAtlasReference.configurations
        where MacAtlasReference.exists(pointSize: configuration.pointSize, scale: configuration.scale, thicken: false) {
            let mac = try MacAtlasReference.load(pointSize: configuration.pointSize, scale: configuration.scale, thicken: false)
            let output = try Self.dump(pointSize: configuration.pointSize, scale: configuration.scale, thicken: false)
            let linux = MacAtlasReference.Loaded(dump: output.dump, pages: [
                "grayscale": PNGImage(width: output.grayscale.size, height: output.grayscale.size,
                                      pixels: output.grayscale.pixels.flatMap { [$0, $0, $0, 255] }),
            ])
            var sum = 0.0, count = 0
            for l in linux.dump.glyphs where l.page == "grayscale" && l.scalars.count == 1 && l.scalars[0] < 0x80 {
                guard let m = mac.dump.glyphs.first(where: { $0.scalars == l.scalars && $0.style == l.style }) else { continue }
                let d = MacAtlasReference.meanAbsoluteDifference(mac.coverage(m), m, linux.coverage(l), l)
                sum += d.sum
                count += d.count
            }
            let mean = sum / Double(max(1, count))
            print("mask mean |Δ| at \(configuration.pointSize)@\(configuration.scale): \(String(format: "%.3f", mean))/255")
            #expect(count > 0 && mean <= 2, "\(configuration)")
        }
    }

    @Test("the emoji box is within ±1 px of the Mac's",
          .enabled(if: MacAtlasReference.anyPresent && ColorFixtures.notoColorEmoji != nil, referenceSkip))
    func emojiBoxMatchesMac() throws {
        for configuration in MacAtlasReference.configurations {
            for thicken in [false, true] where MacAtlasReference.exists(pointSize: configuration.pointSize,
                                                                       scale: configuration.scale, thicken: thicken) {
                let mac = try MacAtlasReference.load(pointSize: configuration.pointSize, scale: configuration.scale, thicken: thicken)
                let linux = try Self.dump(pointSize: configuration.pointSize, scale: configuration.scale, thicken: thicken).dump
                for scalar: UInt32 in [0x1F600, 0x1F389] {
                    let m = try #require(mac.dump.glyphs.first { $0.scalars == [scalar] && $0.style == "regular" })
                    let l = try #require(linux.glyphs.first { $0.scalars == [scalar] && $0.style == "regular" })
                    let label = "U+\(String(scalar, radix: 16)) at \(configuration.pointSize)@\(configuration.scale)"
                    #expect(abs(m.width - l.width) <= 1 && abs(m.height - l.height) <= 1, "\(label): size")
                    #expect(abs(m.bearingX - l.bearingX) <= 1 && abs(m.bearingTop - l.bearingTop) <= 1, "\(label): bearings")
                }
            }
        }
    }
}
