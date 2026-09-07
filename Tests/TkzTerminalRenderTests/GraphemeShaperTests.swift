import CoreText
import Foundation
import Testing
@testable import TkzTerminalRender

@Suite("GraphemeShaper")
struct GraphemeShaperTests {

    private func shaper() -> GraphemeShaper {
        GraphemeShaper(fontSet: FontSet(pointSize: 12.5, scale: 2))
    }

    @Test("a plain ASCII scalar takes the fast path and lands on the primary face")
    func ascii() {
        let shaped = shaper().shape("A")
        #expect(shaped.fontName == "JetBrainsMono-Regular")
        #expect(shaped.glyphs.count == 1)
        #expect(shaped.glyphs[0].glyph != 0)
        #expect(shaped.isColor == false)
        #expect(shaped.cellSpan == 1)
    }

    @Test("a CJK scalar falls back to a system face and is double width")
    func han() {
        let shaped = shaper().shape("你")
        #expect(shaped.fontName != "JetBrainsMono-Regular")
        #expect(shaped.isColor == false)
        #expect(shaped.glyphs.count == 1)
        #expect(shaped.glyphs[0].glyph != 0)
        #expect(shaped.cellSpan == 2)
    }

    @Test("a non-BMP emoji goes through CTLine and lands in Apple Color Emoji")
    func emoji() {
        let shaped = shaper().shape("😀")
        #expect(shaped.fontName == "AppleColorEmoji")
        #expect(shaped.isColor)
        #expect(shaped.glyphs.count == 1)
        #expect(shaped.glyphs[0].glyph != 0)
        #expect(shaped.cellSpan == 2)
    }

    @Test("a ZWJ family sequence shapes to a single colour glyph, one grapheme wide")
    func zwjSequence() {
        let shaped = shaper().shape("👨‍👩‍👧")
        #expect(shaped.fontName == "AppleColorEmoji")
        #expect(shaped.isColor)
        // Ligature substitution is disabled, but ZWJ sequences are handled by cmap/GSUB rules that
        // CoreText still applies: the family must collapse to one glyph, not three people.
        #expect(shaped.glyphs.count == 1)
        #expect(shaped.cellSpan == 2)
    }

    @Test("VS16 forces emoji presentation and double width")
    func variationSelector16() {
        let shaped = shaper().shape("\u{2764}\u{FE0F}")  // ❤️
        #expect(shaped.isColor)
        #expect(shaped.cellSpan == 2)
        #expect(shaped.glyphs.isEmpty == false)
    }

    @Test("a combining mark stays inside one cell and shapes with the base")
    func combiningMark() {
        let shaped = shaper().shape("e\u{0301}")  // é decomposed
        #expect(shaped.cellSpan == 1)
        #expect(shaped.isColor == false)
        #expect(shaped.isEmpty == false)
    }

    @Test("no ligatures: fi, -> and == shape as separate per-cell glyphs")
    func noLigatures() {
        let s = shaper()
        // A terminal shapes one cell at a time, so a ligature can never form across cells.
        for pair in ["fi", "->", "==", "!=", "=>"] {
            let glyphs = pair.map { s.shape($0).glyphs }
            #expect(glyphs.count == 2)
            #expect(glyphs.allSatisfy { $0.count == 1 })
        }
        // And a two-character cluster shaped in one go still gets two glyphs, not a ligature.
        let together = s.shape(Array("fi".unicodeScalars))
        #expect(together.glyphs.count == 2)
    }

    @Test("cellSpan from the VT overrides the heuristic")
    func explicitSpanWins() {
        let s = shaper()
        #expect(s.shape("A", cellSpan: 2).cellSpan == 2)
        #expect(s.shape("你", cellSpan: 1).cellSpan == 1)
    }

    @Test("shaping is cached per (codepoints, style, span)")
    func caches() {
        let s = shaper()
        #expect(s.cachedCount == 0)
        _ = s.shape("A")
        _ = s.shape("A")
        #expect(s.cachedCount == 1)
        _ = s.shape("A", style: .bold)
        #expect(s.cachedCount == 2)
        _ = s.shape("A", cellSpan: 2)
        #expect(s.cachedCount == 3)
        s.clearCache()
        #expect(s.cachedCount == 0)
    }

    @Test("bold and italic resolve to their own faces")
    func styledFaces() {
        let s = shaper()
        #expect(s.shape("A", style: .bold).fontName == "JetBrainsMono-Bold")
        #expect(s.shape("A", style: .italic).fontName == "JetBrainsMono-Italic")
        #expect(s.shape("A", style: .boldItalic).fontName == "JetBrainsMono-BoldItalic")
    }

    @Test("the width heuristic matches East Asian Width for the cases the tests rely on")
    func widthHeuristic() {
        #expect(GraphemeShaper.defaultCellSpan(for: Array("A".unicodeScalars)) == 1)
        #expect(GraphemeShaper.defaultCellSpan(for: Array("你".unicodeScalars)) == 2)
        #expect(GraphemeShaper.defaultCellSpan(for: Array("😀".unicodeScalars)) == 2)
        #expect(GraphemeShaper.defaultCellSpan(for: Array("👨‍👩‍👧".unicodeScalars)) == 2)
        #expect(GraphemeShaper.defaultCellSpan(for: Array("ﾊ".unicodeScalars)) == 1)  // halfwidth kana
    }
}
