// CellSpan — the cell-width guess for a grapheme cluster when the VT gives none (M1.4; shared in
// WOR-312 S4).
//
// libghostty's `WIDE` flag is authoritative in the renderer. This heuristic only answers for
// tests, headless dumps and the parity references, where no VT runs. It lives here, not in a font
// backend, so the Mac's `GraphemeShaper` and Linux's `TerminalFaces` give every cluster the same
// span by construction (WOR-312: "cellSpan matches the Mac for every S1 cluster").

public enum CellSpan {
    /// Best-effort East-Asian-Width / emoji width: 1 or 2.
    public static func guess(for scalars: [Unicode.Scalar]) -> Int {
        guard let first = scalars.first else { return 1 }

        // An explicit VS16 forces emoji presentation, which is double width.
        if scalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        // A ZWJ sequence renders as one double-width emoji.
        if scalars.contains(where: { $0.value == 0x200D }) { return 2 }

        if first.properties.isEmojiPresentation { return 2 }
        return isWide(first) ? 2 : 1
    }

    /// East Asian Wide (W) and Fullwidth (F) ranges, condensed. Not a full UAX #11 table — the VT
    /// owns that; this only has to be right for tests and offline tooling.
    public static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        switch v {
        case 0x1100...0x115F,      // Hangul Jamo init. consonants
             0x2E80...0x303E,      // CJK radicals, Kangxi, CJK symbols
             0x3041...0x33FF,      // Hiragana … CJK compatibility
             0x3400...0x4DBF,      // CJK ext A
             0x4E00...0x9FFF,      // CJK unified ideographs
             0xA000...0xA4CF,      // Yi
             0xAC00...0xD7A3,      // Hangul syllables
             0xF900...0xFAFF,      // CJK compatibility ideographs
             0xFE10...0xFE19,      // vertical forms
             0xFE30...0xFE6F,      // CJK compatibility forms
             0xFF00...0xFF60,      // fullwidth forms
             0xFFE0...0xFFE6,
             0x1F300...0x1F64F,    // emoji blocks
             0x1F900...0x1F9FF,
             0x20000...0x2FFFD,    // CJK ext B…
             0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
