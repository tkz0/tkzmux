// CellSpanTests — the shared cell-width guess (WOR-312 S4). The Mac's
// `GraphemeShaper.defaultCellSpan` and Linux's `TerminalFaces.shape` both answer with it.

import Testing
import TkzRenderCore

@Suite("CellSpan guess")
struct CellSpanTests {
    @Test("the width heuristic matches East Asian Width for the cases the tests rely on")
    func widthHeuristic() {
        #expect(CellSpan.guess(for: Array("A".unicodeScalars)) == 1)
        #expect(CellSpan.guess(for: Array("你".unicodeScalars)) == 2)
        #expect(CellSpan.guess(for: Array("😀".unicodeScalars)) == 2)
        #expect(CellSpan.guess(for: Array("👨‍👩‍👧".unicodeScalars)) == 2)
        #expect(CellSpan.guess(for: Array("ﾊ".unicodeScalars)) == 1)  // halfwidth kana
    }

    @Test("VS16 and ZWJ make a cluster wide; an empty cluster is one cell")
    func presentation() {
        #expect(CellSpan.guess(for: ["\u{2764}", "\u{FE0F}"]) == 2)
        #expect(CellSpan.guess(for: ["\u{2764}"]) == 1)
        #expect(CellSpan.guess(for: ["1", "\u{FE0F}", "\u{20E3}"]) == 2)
        #expect(CellSpan.guess(for: ["\u{1F1F8}", "\u{1F1EA}"]) == 2)
        #expect(CellSpan.guess(for: ["e", "\u{301}"]) == 1)
        #expect(CellSpan.guess(for: []) == 1)
    }

    @Test("wide ranges: CJK, Hangul, fullwidth forms; not ASCII or halfwidth forms")
    func wideRanges() {
        #expect(CellSpan.isWide("\u{4E00}"))
        #expect(CellSpan.isWide("\u{AC00}"))
        #expect(CellSpan.isWide("\u{FF01}"))
        #expect(CellSpan.isWide("\u{20000}"))
        #expect(!CellSpan.isWide("A"))
        #expect(!CellSpan.isWide("\u{FF8A}"))
    }
}
