// ColorGlyphTests — colour emoji from a CBDT strike, and the COLRv1-only skip (WOR-312 S5).
//
// Fixtures/colrv1-only.ttf is an original font written by scripts/make-colrv1-fixture.py: it
// covers U+1F600 only through a COLR version 1 paint (no outline, no COLRv0 layers, no strike), so
// FreeType would draw it blank. The skip test ranks it first in the colour list by putting its
// family ahead of Noto Color Emoji's (`FontFallback.init(configuration:colorFamilies:...)`) and
// expects the next colour font to draw the emoji.

import CFreeType
import Foundation
import Testing
import TkzPlatform
import TkzRenderCore
@testable import TkzFontsFT

enum ColorFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
    static let colrV1Only = directory.appendingPathComponent("colrv1-only.ttf")
    static let colrV1Family = "Tkzmux COLRv1 Fixture"
    static let colrV1PostScriptName = "TkzmuxCOLRv1Fixture-Regular"

    /// The parity fallback when scripts/fetch-parity-fonts.sh has run (always in CI), else the
    /// system one.
    static var fallback: FontFallback {
        TestFallbacks.parityFontsPresent ? TestFallbacks.parity : TestFallbacks.system
    }

    /// The CBDT Noto Color Emoji `fallback` resolves, or `nil`.
    static let notoColorEmoji: FallbackFace? = {
        fallback.faces(in: .color).first { $0.family == FontFallback.colorFamily && $0.isColor }
    }()
}

@Suite("Colour glyphs")
struct ColorGlyphTests {
    static let smile: Unicode.Scalar = "\u{1F600}"

    // MARK: CBDT

    @Test("😀 rasterizes from Noto Color Emoji's strike into premultiplied BGRA inside its 2-cell box",
          .enabled(if: ColorFixtures.notoColorEmoji != nil, "needs Noto Color Emoji (system or parity fonts)"),
          arguments: [(14.0, 2.0), (14.0, 1.6), (12.5, 2.0)] as [(CGFloat, CGFloat)])
    func cbdtEmoji(pointSize: CGFloat, scale: CGFloat) throws {
        let faces = try TerminalFaces(pointSize: pointSize, scale: scale, fallback: ColorFixtures.fallback)
        let shaped = faces.shape([Self.smile])
        #expect(shaped.isColor && shaped.cellSpan == 2)
        #expect(faces.name(of: shaped.face) == "NotoColorEmoji")
        for thicken in [false, true] {
            let options = RasterizerOptions(thicken: thicken)
            let glyph = try #require(faces.rasterize(shaped, options: options))
            #expect(glyph.isColor && glyph.bytesPerPixel == 4 && glyph.bytesPerRow == glyph.width * 4)
            let padding = options.padding
            #expect(glyph.width - 2 * padding <= faces.metrics.width * 2)
            #expect(glyph.height - 2 * padding <= faces.metrics.height)
            // Premultiplied, opaque in the middle, transparent padding.
            var opaque = 0
            for i in stride(from: 0, to: glyph.pixels.count, by: 4) {
                let a = glyph.pixels[i + 3]
                #expect(glyph.pixels[i] <= a && glyph.pixels[i + 1] <= a && glyph.pixels[i + 2] <= a)
                if a == 255 { opaque += 1 }
            }
            #expect(opaque > glyph.width * glyph.height / 3)
            for x in 0..<glyph.width { #expect(glyph.pixels[x * 4 + 3] == 0) }
            print("😀 at \(faces.pixelSize) px thicken=\(thicken): \(glyph.width)×\(glyph.height) " +
                  "bearing (\(glyph.bearingX), \(glyph.bearingTop)) scale \(glyph.appliedScale)")
        }
    }

    // MARK: COLRv1

    @Test("the fixture is COLRv1 only; Noto Color Emoji (CBDT) and JetBrains Mono are not")
    func detectsCOLRv1Only() throws {
        let library = try FreeTypeLibrary()
        let fixture = try FreeTypeFace(library: library, url: ColorFixtures.colrV1Only)
        try fixture.requestPixelSize(28)
        #expect(fixture.postScriptName == ColorFixtures.colrV1PostScriptName)
        #expect(fixture.handle.pointee.face_flags & FT_Long(FT_FACE_FLAG_COLOR) != 0)
        let smile = FT_Get_Char_Index(fixture.handle, FT_ULong(Self.smile.value))
        #expect(smile == 1)
        #expect(fixture.isCOLRv1Only(glyph: smile))
        #expect(!fixture.isCOLRv1Only(glyph: 2))  // the painted square: a plain outline

        let mono = try FreeTypeFace(library: library,
                                    url: try #require(BundledFonts.directory).appendingPathComponent(BundledFonts.jetBrainsMonoFile(.regular)))
        #expect(!mono.isCOLRv1Only(glyph: FT_Get_Char_Index(mono.handle, 0x41)))

        if let noto = ColorFixtures.notoColorEmoji {
            let face = try FreeTypeFace(library: library, url: URL(fileURLWithPath: noto.path), index: noto.index)
            #expect(!face.isCOLRv1Only(glyph: FT_Get_Char_Index(face.handle, FT_ULong(Self.smile.value))))
        }
    }

    /// A private configuration: the bundled fonts, the fixture, and (optionally) the directory
    /// holding Noto Color Emoji, with the fixture's family ranked first among the colour fonts.
    func fixtureFirst(with emojiDirectory: URL?) -> FontFallback {
        let directories = BundledFonts.fontDirectories + [ColorFixtures.directory] + (emojiDirectory.map { [$0] } ?? [])
        return FontFallback(
            configuration: FontconfigConfiguration(fontDirectories: directories, cacheDirectory: TestFallbacks.cacheDirectory),
            colorFamilies: [ColorFixtures.colrV1Family, FontFallback.colorFamily],
            isMainThread: { false })
    }

    @Test("with the COLRv1-only fixture first, 😀 comes from the next colour face, not blank",
          .enabled(if: ColorFixtures.notoColorEmoji != nil, "needs Noto Color Emoji (system or parity fonts)"))
    func skipsCOLRv1Only() throws {
        let noto = try #require(ColorFixtures.notoColorEmoji)
        let fallback = fixtureFirst(with: URL(fileURLWithPath: noto.path).deletingLastPathComponent())
        // Not vacuous: the fixture is the first colour face covering 😀.
        let first = try #require(fallback.face(covering: [Self.smile], in: .color))
        #expect(first.postScriptName == ColorFixtures.colrV1PostScriptName)

        let faces = try TerminalFaces(pointSize: 14, scale: 2, fallback: fallback)
        let shaped = faces.shape([Self.smile])
        #expect(faces.name(of: shaped.face) == "NotoColorEmoji")
        #expect(shaped.isColor && !shaped.isEmpty)
        let glyph = try #require(faces.rasterize(shaped))
        #expect(glyph.pixels.contains { $0 != 0 })
    }

    @Test("with no other colour face, the fixture is still skipped (monochrome fallback or .notdef)")
    func skipsCOLRv1OnlyWithoutAlternative() throws {
        let fallback = fixtureFirst(with: nil)
        #expect(fallback.face(covering: [Self.smile], in: .color)?.postScriptName == ColorFixtures.colrV1PostScriptName)
        let faces = try TerminalFaces(pointSize: 14, scale: 2, fallback: fallback)
        let shaped = faces.shape([Self.smile])
        #expect(faces.name(of: shaped.face) != ColorFixtures.colrV1PostScriptName)
        #expect(faces.fallbackFace(of: shaped.face) == nil)  // nothing else covers it: the bundled face
        #expect(!shaped.isColor)
    }

    @Test("the fixture on disk is what scripts/make-colrv1-fixture.py writes")
    func fixtureIsPinned() throws {
        let data = try Data(contentsOf: ColorFixtures.colrV1Only)
        #expect(data.count == 948)
        #expect(SHA256.hash(data: data).description == "ae5077cbd367c376997c90331fbf3ec1e2dc4e07613093ef5d8c2d695c6664c8")
    }
}
