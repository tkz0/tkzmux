// FrameBuilderFreeTypeTests — TkzRenderCore's FrameBuilder over the FreeType source (WOR-311 S4):
// the Linux counterparts of the CoreText cases that stay in TkzTerminalRenderTests (CJK fallback,
// colour emoji, distinct bold/italic faces). Everything else the builder does is pinned over a
// synthetic source in TkzRenderCoreTests.

import Testing
import TkzRenderCore
import TkzShaderTypes
import TkzTerminalCore
@testable import TkzFontsFT

@Suite("FrameBuilder over FreeTypeGlyphSource", .serialized)
struct FrameBuilderFreeTypeTests {
    /// Whether the fallback this suite uses has a face for 你.
    static let hasCJK: Bool = {
        guard let faces = try? TerminalFaces(pointSize: 12.5, scale: 2, fallback: ColorFixtures.fallback)
        else { return false }
        return !faces.shape(["你"]).isEmpty
    }()

    /// Builds one frame of `text` on a 20×4 grid and returns row 0's glyph instances.
    private func row0(_ text: String) throws -> (glyphs: [TkzGlyphInstance], cache: GlyphCache) {
        let faces = try TerminalFaces(pointSize: 12.5, scale: 2, fallback: ColorFixtures.fallback)
        let cache = GlyphCache(source: FreeTypeGlyphSource(faces: faces))
        let session = try TerminalSession(options: TerminalSessionOptions(cols: 20, rows: 4))
        let surface = TerminalSurface()
        try surface.attach(session)
        defer { surface.detach() }
        session.write(ptyText: text)
        try FrameBuilder(glyphCache: cache).update(surface)
        return (surface.glyphInstances().filter { $0.gridPos.y == 0 }, cache)
    }

    @Test("a CJK fallback glyph is one WIDE instance and its tail cell draws nothing (spike 6)",
          .enabled(if: hasCJK, "needs a CJK face (system or parity fonts)"))
    func wideTailProducesNoGlyph() throws {
        let row = try row0("你a").glyphs
        #expect(row.count == 2, "one glyph for 你 (columns 0–1) and one for a (column 2)")
        let wide = try #require(row.first { $0.gridPos.x == 0 })
        #expect(wide.flags & UInt32(TKZ_GLYPH_FLAG_WIDE) != 0)
        #expect(!row.contains { $0.gridPos.x == 1 }, "the SPACER_TAIL cell must draw nothing at all")
        #expect(row.contains { $0.gridPos.x == 2 })
    }

    @Test("an emoji is rasterized into the colour atlas",
          .enabled(if: ColorFixtures.notoColorEmoji != nil, "needs Noto Color Emoji (system or parity fonts)"))
    func emojiIsAColorGlyph() throws {
        let (row, cache) = try row0("😀")
        let glyph = try #require(row.first)
        #expect(glyph.flags & UInt32(TKZ_GLYPH_FLAG_COLOR) != 0)
        #expect(glyph.flags & UInt32(TKZ_GLYPH_FLAG_WIDE) != 0)
        #expect(cache.color.hasPendingUpload)
    }

    @Test("bold and italic pick different faces, and both rasterize")
    func boldAndItalicShapeDifferently() throws {
        let (row, cache) = try row0("\u{1b}[0mR\u{1b}[1mR\u{1b}[0m\u{1b}[3mR\u{1b}[0m")
        #expect(row.count == 3)
        #expect(Set(row.map { $0.atlasPos }).count == 3)
        // The same letter, from three different faces.
        let faces = [FontStyle.regular, .bold, .italic].map { style in
            cache.source.name(of: cache.source.shape(["R"], style: style, cellSpan: 1).face)
        }
        #expect(Set(faces).count == 3, "\(faces)")
    }
}
