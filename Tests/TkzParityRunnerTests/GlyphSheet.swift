// The glyph sheet: one synthetic screen with the glyphs the terminal references compare (WOR-322
// S2). Printable ASCII in the four styles, box and block characters, the symbols Claude Code draws,
// CJK, emoji and ZWJ sequences, one family per row and nothing wider than the grid, so every glyph
// sits in a cell of its own row and a diff points at a glyph rather than at a wrap.
//
// Committed as Tests/Parity/Fixtures/glyph-sheet.tkzrec, because scripts/parity-export-mac.sh renders
// it with `tkzmux-vtdump render` on the reference runner. Like the L2 feature sheet, the recording is
// written from this source alone, with an empty environment and a zero timestamp.
// `theCommittedRecordingIsItsSource` pins the file to `output`; regenerate with
// `TKZMUX_UPDATE_PARITY_FIXTURES=1 swift test --filter GlyphSheetTests`, then the terminal references
// (docs/linux/parity.md, "The terminal references").

import Foundation
import Testing
import TkzTerminalCore

enum GlyphSheet {
    static let columns: UInt16 = 48
    static let rows: UInt16 = 15

    static var url: URL { ParityPaths.repoRoot.appending(path: "Tests/Parity/Fixtures/glyph-sheet.tkzrec") }

    /// Printable ASCII without the space, as two rows of 47.
    static var asciiRows: [String] {
        let ascii = (0x21...0x7E).compactMap { Unicode.Scalar($0) }.map(String.init).joined()
        return [String(ascii.prefix(47)), String(ascii.dropFirst(47))]
    }

    /// The rows as drawn, before the escapes: what `theRowsFitTheGrid` measures.
    static var plainRows: [String] {
        let styled = Array(repeating: asciiRows, count: 4).flatMap { $0 }
        return styled + [
            // Box drawing: light, heavy, double and rounded corners, tees and crosses.
            "┌─┬─┐ ┏━┳━┓ ╔═╦═╗ ╭─╮ ├─┼─┤ ┣━╋━┫ ╠═╬═╣ │┃║",
            "└─┴─┘ ┗━┻━┛ ╚═╩═╝ ╰─╯ ╴╵╶╷ ╌╎ ┄┆ ╱╲╳",
            // Block elements: full, halves, eighths, shades and quadrants.
            "█▀▄▌▐ ▁▂▃▄▅▆▇ ▏▎▍▋▊▉ ░▒▓ ▖▗▘▝▙▚▛▜▞▟",
            // The symbols Claude Code draws, regular then bold.
            "⏺ ⎿ ✢ ✳ ✶ ✻ ✽  ⏺ ⎿ ✢ ✳ ✶ ✻ ✽",
            // Wide CJK: Chinese, Japanese and Korean.
            "你好世界 日本語 かな カナ 한국어 漢字",
            // Colour emoji, a skin-tone modifier, ZWJ sequences and a flag.
            "😀 🎉 ✅ 👍🏽 👩‍💻 👨‍👩‍👧 🏳️‍🌈 🇸🇪",
        ]
    }

    /// The pty bytes, one row per family.
    static var output: String {
        let esc = "\u{1b}"
        let rows = plainRows
        let styles = ["", "\(esc)[1m", "\(esc)[3m", "\(esc)[1;3m"]
        var text = ""
        for (index, style) in styles.enumerated() {
            for row in rows[(2 * index)..<(2 * index + 2)] { text += "\(style)\(row)\(esc)[0m\r\n" }
        }
        text += rows[8] + "\r\n" + rows[9] + "\r\n" + rows[10] + "\r\n"
        // The symbols: the first seven regular, the second seven bold.
        let symbols = rows[11]
        let half = symbols.index(symbols.startIndex, offsetBy: 14)
        text += String(symbols[..<half]) + "\(esc)[1m" + String(symbols[half...]) + "\(esc)[0m\r\n"
        text += rows[12] + "\r\n" + rows[13] + "\r\n"
        text += "\(esc)[15;1H"  // park the cursor on the last row, column 1
        return text
    }

    /// The recording, exactly as committed.
    static func recordingData() throws -> Data {
        let header = RecordingHeader(cols: columns, rows: rows, argv: ["synthetic"], env: [:], startedAt: 0,
                                     note: "WOR-322 S2 glyph sheet, written by TkzParityRunnerTests from GlyphSheet.output")
        let writer = RecordingWriter(header: header)
        var data = try writer.headerLine()
        data.append(writer.encode(.output(elapsedNanos: 0, bytes: Data(output.utf8))))
        return data
    }
}

@Suite struct GlyphSheetTests {
    @Test func theCommittedRecordingIsItsSource() throws {
        let expected = try GlyphSheet.recordingData()
        if ProcessInfo.processInfo.environment["TKZMUX_UPDATE_PARITY_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: GlyphSheet.url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try expected.write(to: GlyphSheet.url, options: .atomic)
        }
        let committed = try Data(contentsOf: GlyphSheet.url)
        #expect(committed == expected, """
            Tests/Parity/Fixtures/glyph-sheet.tkzrec is not GlyphSheet.output: regenerate it with \
            TKZMUX_UPDATE_PARITY_FIXTURES=1, then the terminal references (docs/linux/parity.md)
            """)
        let reader = try RecordingReader(data: committed)
        #expect(reader.header.cols == GlyphSheet.columns && reader.header.rows == GlyphSheet.rows)
        #expect(reader.header.env.isEmpty && reader.header.startedAt == 0)
    }

    /// Every row is on screen and none wraps: the replayed screen shows each row on a line of its
    /// own, in order, and the line after the last one is empty.
    @Test func theRowsFitTheGrid() throws {
        let session = try TerminalSession(options: TerminalSessionOptions(cols: GlyphSheet.columns, rows: GlyphSheet.rows))
        try RecordingReader(data: try GlyphSheet.recordingData()).replay(into: session)
        let screen = try session.formatted()
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let rows = GlyphSheet.plainRows
        #expect(lines.count >= rows.count)
        for (index, row) in rows.enumerated() where index < lines.count {
            #expect(lines[index] == row.trimmingCharacters(in: .whitespaces), "row \(index) wrapped or moved")
        }
        if lines.count > rows.count { #expect(lines[rows.count].isEmpty) }
    }
}
