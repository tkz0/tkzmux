// The L2 feature sheet: one synthetic screen with what FrameBuilder does that the four terminal
// fixtures barely reach (WOR-322 S3). They are real sessions, so they hold plain and bold ASCII, a
// few underlines and box sprites, and no wide, colour or multi-scalar cluster at all.
//
// Committed as Tests/Parity/Fixtures/l2-features.tkzrec, because `tkzmux-vtdump framedump` reads
// files on both OSes; the recording is written from this source alone, with an empty environment and
// a zero timestamp, so it carries nothing of the machine that wrote it. `theCommittedRecordingIsItsSource`
// pins the file to `output`; regenerate with `TKZMUX_UPDATE_PARITY_FIXTURES=1 swift test --filter
// L2FeatureSheetTests`, then regenerate the L2 references (docs/linux/parity.md).

import Foundation
import Testing
import TkzTerminalCore

enum L2FeatureSheet {
    static let columns: UInt16 = 48
    static let rows: UInt16 = 10

    static var url: URL { ParityPaths.repoRoot.appending(path: "Tests/Parity/Fixtures/l2-features.tkzrec") }

    /// The pty bytes, one feature family per line.
    static var output: String {
        let esc = "\u{1b}"
        var text = ""
        // The four styles, then every underline style the rect pass draws.
        text += "\(esc)[1mbold\(esc)[0m \(esc)[3mitalic\(esc)[0m \(esc)[1;3mboth\(esc)[0m \(esc)[4msingle\(esc)[0m \(esc)[4:2mdouble\(esc)[0m\r\n"
        text += "\(esc)[4:3mcurly\(esc)[0m \(esc)[4:4mdotted\(esc)[0m \(esc)[4:5mdashed\(esc)[0m \(esc)[9mstruck\(esc)[0m \(esc)[4;58;5;196mred line\(esc)[0m\r\n"
        // Palette, bright, 256-colour and direct colours, foreground and background.
        text += "\(esc)[31mred\(esc)[0m \(esc)[1;31mbold red\(esc)[0m \(esc)[91mbright\(esc)[0m \(esc)[38;5;208m208\(esc)[0m "
            + "\(esc)[38;2;255;128;0mrgb\(esc)[0m \(esc)[48;5;18mbg\(esc)[0m \(esc)[48;2;20;60;20mrgb bg\(esc)[0m\r\n"
        // Attributes FrameBuilder resolves itself: inverse (with and without colours), faint, invisible.
        text += "\(esc)[7mreverse\(esc)[0m \(esc)[7;32;44mrev col\(esc)[0m \(esc)[2mfaint\(esc)[0m \(esc)[8mhidden\(esc)[0m plain\r\n"
        // Wide clusters, the colour page, a ZWJ sequence and a combining mark (multi-scalar clusters).
        text += "wide 你好 emoji 😀 zwj 👩‍💻 flag 🇸🇪 e\u{301}\r\n"
        // Box sprites, block elements, and the symbols Claude Code draws.
        text += "┌─┬─┐ │█▀▄░▒▓│ └─┴─┘ ⏺ ⎿ ✢ ✳ ✶ ✻ ✽\r\n"
        // A hyperlink and a coloured background run that ends mid-row.
        text += "\(esc)]8;;https://example.com\(esc)\\link\(esc)]8;;\(esc)\\ \(esc)[48;5;236m  shaded  \(esc)[0m tail\r\n"
        // A line wider than the grid, so it wraps.
        text += String(repeating: "wrap ", count: 11) + "\r\n"
        text += "\(esc)[9;5H"  // park the cursor on the last row, column 5
        return text
    }

    /// The recording, exactly as committed.
    static func recordingData() throws -> Data {
        let header = RecordingHeader(cols: columns, rows: rows, argv: ["synthetic"], env: [:], startedAt: 0,
                                     note: "WOR-322 S3 L2 feature sheet, written by TkzParityRunnerTests from L2FeatureSheet.output")
        let writer = RecordingWriter(header: header)
        var data = try writer.headerLine()
        data.append(writer.encode(.output(elapsedNanos: 0, bytes: Data(output.utf8))))
        return data
    }
}

@Suite struct L2FeatureSheetTests {
    @Test func theCommittedRecordingIsItsSource() throws {
        let expected = try L2FeatureSheet.recordingData()
        if ProcessInfo.processInfo.environment["TKZMUX_UPDATE_PARITY_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: L2FeatureSheet.url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try expected.write(to: L2FeatureSheet.url, options: .atomic)
        }
        let committed = try Data(contentsOf: L2FeatureSheet.url)
        #expect(committed == expected, """
            Tests/Parity/Fixtures/l2-features.tkzrec is not L2FeatureSheet.output: regenerate it with \
            TKZMUX_UPDATE_PARITY_FIXTURES=1, then the L2 references (docs/linux/parity.md)
            """)
        let reader = try RecordingReader(data: committed)
        #expect(reader.header.cols == L2FeatureSheet.columns && reader.header.rows == L2FeatureSheet.rows)
        #expect(reader.header.env.isEmpty && reader.header.startedAt == 0)
    }
}
