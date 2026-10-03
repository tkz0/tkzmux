// ShapingTests — clusters shaped through the bundled faces, the fallback and HarfBuzz (WOR-312 S4).
//
// The fixed expectations run on the bundled faces only, so they hold on any machine. Fallback
// faces are pinned in ParityFontsTests, where the font set is fixed too. The comparison with the
// Mac's shaping dump (WOR-312 S1) skips while that file is missing.

import CFreeType
import Foundation
import Testing
import TkzRenderCore
@testable import TkzFontsFT

@Suite("Cluster shaping")
struct ShapingTests {
    private func faces(_ fallback: FontFallback = TestFallbacks.system) throws -> TerminalFaces {
        try TerminalFaces(pointSize: 14, scale: 2, fallback: fallback)
    }

    @Test("an ASCII scalar takes the fast path: one glyph, no offset, the style's own face")
    func fastPath() throws {
        let faces = try faces()
        for style in FontStyle.allCases {
            let shaped = faces.shape("A", style: style)
            #expect(shaped.face == FontFace(rawValue: UInt32(style.rawValue)))
            #expect(shaped.glyphs.count == 1)
            #expect(shaped.glyphs.first?.glyph != .notdef)
            #expect(shaped.glyphs.first?.xOffset == 0 && shaped.glyphs.first?.yOffset == 0)
            #expect(!shaped.isColor)
            #expect(shaped.cellSpan == 1)
        }
        #expect(faces.name(of: faces.shape("A", style: .bold).face) == "JetBrainsMono-Bold")
        #expect(faces.name(of: faces.shape("A", style: .italic).face) == "JetBrainsMono-Italic")
        #expect(faces.name(of: faces.shape("A", style: .boldItalic).face) == "JetBrainsMono-BoldItalic")
    }

    @Test("the fast path's glyph is FreeType's cmap glyph")
    func fastPathGlyph() throws {
        let faces = try faces()
        let shaped = faces.shape("H")
        let directory = try #require(BundledFonts.directory)
        let library = try FreeTypeLibrary()
        let face = try FreeTypeFace(library: library, url: directory.appendingPathComponent(BundledFonts.jetBrainsMonoFile(.regular)))
        #expect(shaped.glyphs.map(\.glyph.rawValue) == [FT_Get_Char_Index(face.handle, 0x48)])
    }

    @Test("no ligatures: '-' '>' shaped as one cluster stays two glyphs, the same as alone")
    func noLigatures() throws {
        // JetBrains Mono draws `->` as one arrow through `calt`; `-liga,-calt` turns that off.
        let faces = try faces()
        let pair = faces.shape(["-", ">"])
        let alone = [faces.shape("-"), faces.shape(">")].flatMap { $0.glyphs.map(\.glyph) }
        #expect(pair.glyphs.map(\.glyph) == alone)
        #expect(pair.glyphs.count == 2)
        #expect(pair.glyphs[0].xOffset == 0)
        #expect(abs(pair.glyphs[1].xOffset - 16.8) < 0.001)  // the 600-unit advance at 28 px
    }

    @Test("a combining mark stays on the bundled face when it covers both scalars")
    func combiningMark() throws {
        let faces = try faces()
        let shaped = faces.shape(["e", "\u{301}"])
        #expect(faces.name(of: shaped.face) == "JetBrainsMono-Regular")
        #expect(!shaped.isEmpty)
        #expect(shaped.glyphs.allSatisfy { $0.glyph != .notdef })
        #expect(shaped.cellSpan == 1)
    }

    @Test("cellSpan: explicit values win, nil takes the shared CellSpan guess, both are cached apart")
    func cellSpan() throws {
        let faces = try faces()
        #expect(faces.shape("A").cellSpan == 1)
        #expect(faces.shape("A", cellSpan: 2).cellSpan == 2)
        #expect(faces.shape(["\u{1F600}"]).cellSpan == CellSpan.guess(for: ["\u{1F600}"]))
        #expect(faces.shape(["\u{4F60}"]).cellSpan == 2)
        #expect(faces.shape(["1", "\u{FE0F}", "\u{20E3}"]).cellSpan == 2)
        let before = faces.cachedClusterCount
        _ = faces.shape("Z")
        _ = faces.shape("Z", cellSpan: 2)
        _ = faces.shape("Z")
        #expect(faces.cachedClusterCount == before + 2)
    }

    @Test("a cluster no face covers stays on the bundled face as .notdef")
    func noCoverage() throws {
        // U+10FFFD is a private-use scalar no font configured here maps (the empty configuration
        // proves it for fallback; JetBrains Mono has no plane-16 glyphs).
        let empty = FontFallback(configuration: FontconfigConfiguration(fontDirectories: [], cacheDirectory: TestFallbacks.cacheDirectory))
        let faces = try faces(empty)
        let shaped = faces.shape(["\u{10FFFD}"])
        #expect(shaped.face == FontFace(rawValue: 0))
        #expect(shaped.isEmpty)
    }

    @Test("names: a handle the source never minted is '?'")
    func unknownHandle() throws {
        #expect(try faces().name(of: FontFace(rawValue: 999)) == "?")
    }

    @Test("one face draws the whole cluster: a fallback face covers every scalar it is given")
    func singleFacePerCluster() throws {
        let faces = try faces()
        for cluster: [Unicode.Scalar] in [["\u{4F60}", "\u{301}"], ["\u{2733}"], ["\u{1F600}"], ["\u{1F1F8}", "\u{1F1EA}"]] {
            let shaped = faces.shape(cluster)
            guard let fallback = faces.fallbackFace(of: shaped.face) else { continue }
            let library = try FreeTypeLibrary()
            let face = try FreeTypeFace(library: library, url: URL(fileURLWithPath: fallback.path), index: fallback.index)
            for scalar in FontFallback.nonIgnorable(cluster) {
                #expect(FT_Get_Char_Index(face.handle, FT_ULong(scalar.value)) != 0, "\(fallback) lacks U+\(String(scalar.value, radix: 16))")
            }
        }
    }

    // MARK: - The Mac reference (WOR-312 S1)

    /// `Tests/Parity/References/fonts/shaping.json`, the shaping dump from the reference Mac.
    static let referenceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Parity/References/fonts/shaping.json")

    /// The part of the exporter's schema (`ShapingDump` in
    /// Sources/tkzmux-vtdump/FontDumpCommands.swift) this test reads: per cluster its scalars,
    /// style, cellSpan and CoreText runs. Unknown keys are ignored.
    struct Reference: Decodable {
        struct Cluster: Decodable {
            /// Unicode scalar values.
            let scalars: [UInt32]
            /// `regular`, `bold`, `italic` or `boldItalic`; absent means regular.
            let style: String?
            let cellSpan: Int
            let runs: [Run]
        }
        struct Run: Decodable {
            /// PostScript name of the run's font.
            let font: String
            let glyphCount: Int
        }
        let clusters: [Cluster]
    }

    @Test("cellSpan matches the Mac for every cluster; glyph count wherever the Mac has one run",
          .enabled(if: FileManager.default.fileExists(atPath: referenceURL.path),
                   "DEFERRED: Tests/Parity/References/fonts/shaping.json comes from WOR-312 S1 on the reference Mac"))
    func matchesMacReference() throws {
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: Self.referenceURL))
        #expect(!reference.clusters.isEmpty)
        let faces = try faces(TestFallbacks.parityFontsPresent ? TestFallbacks.parity : TestFallbacks.system)
        let styles: [String: FontStyle] = ["regular": .regular, "bold": .bold, "italic": .italic, "boldItalic": .boldItalic]
        for cluster in reference.clusters {
            let scalars = cluster.scalars.compactMap(Unicode.Scalar.init)
            let style = try #require(styles[cluster.style ?? "regular"], "unknown style \(cluster.style ?? "")")
            let shaped = faces.shape(scalars, style: style)
            let label = scalars.map { "U+\(String($0.value, radix: 16, uppercase: true))" }.joined(separator: " ")
            #expect(shaped.cellSpan == cluster.cellSpan, "\(label)")
            if cluster.runs.count == 1 {
                #expect(shaped.glyphs.count == cluster.runs[0].glyphCount, "\(label): \(faces.name(of: shaped.face))")
            }
        }
    }
}
