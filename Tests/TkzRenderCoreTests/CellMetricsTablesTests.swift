// CellMetricsTablesTests — the shared CellMetrics formula fed from raw font tables (WOR-311 S2).
//
// The pinned numbers are the Mac's: CoreText measures the bundled JetBrains Mono at the same values
// (Tests/TkzTerminalRenderTests/CellMetricsTests.swift, which also checks on macOS that this path
// and the CoreText path agree face for face). Here they hold on any OS, with no font stack at all.

import Foundation
import Testing
import TkzRenderCore
#if canImport(CoreGraphics)
import CoreGraphics  // CGRect/CGFloat geometry API lives in the CoreGraphics overlay on Apple platforms
#endif

@Suite("CellMetrics from font tables")
struct CellMetricsTablesTests {

    /// JetBrains Mono, all four bundled faces: head, hhea, post and OS/2 as stored in the files.
    private static let jetBrainsMono = FontTables(
        unitsPerEm: 1000,
        ascender: 1020, descender: -300, lineGap: 0,
        underlinePosition: -155, underlineThickness: 50,
        strikeout: OS2Strikeout(size: 50, position: 320),
        xHeight: 550,
        maxASCIIAdvance: 600)

    private func metrics(_ pixelSize: CGFloat, _ tables: FontTables = jetBrainsMono) throws -> CellMetrics {
        try #require(CellMetrics(tables: tables, pixelSize: pixelSize, scale: 2))
    }

    @Test("25 px (12.5 pt at 2x): 15x33, baseline 26, underline 4, strike -8")
    func at25px() throws {
        let m = try metrics(25)
        #expect(m.width == 15)
        #expect(m.height == 33)
        #expect(m.ascent == 26)
        #expect(m.descent == 8)
        #expect(m.leading == 0)
        #expect(m.baseline == 26)
        #expect(m.underlineOffset == 4)
        #expect(m.underlineThickness == 1)
        #expect(m.strikethroughOffset == -8)
        #expect(m.strikethroughThickness == 1)
        #expect(m.wideWidth == 30)
        #expect(m.scale == 2)
    }

    @Test("28 px (14 pt at 2x): 17x37, baseline 29, underline 4, strike -9")
    func at28px() throws {
        let m = try metrics(28)
        #expect(m.width == 17)
        #expect(m.height == 37)
        #expect(m.baseline == 29)
        #expect(m.underlineOffset == 4)
        #expect(m.strikethroughOffset == -9)
    }

    @Test("22.4 px (14 pt at 1.6x): 14x30, baseline 23, underline 3, strike -7")
    func at22point4px() throws {
        // `14 * 1.6` is 22.400000000000002, which is what `FontSet` actually builds at 1.6x.
        for pixelSize in [22.4, 14 * 1.6] as [CGFloat] {
            let m = try metrics(pixelSize)
            #expect(m.width == 14)
            #expect(m.height == 30)
            #expect(m.baseline == 23)
            #expect(m.underlineOffset == 3)
            #expect(m.strikethroughOffset == -7)
        }
    }

    @Test("15 px: a descent of exactly 4.5 rounds away from zero, to 5")
    func tieRoundsAwayFromZero() throws {
        // 300 * 15 / 1000 is 4.5 exactly. Banker's rounding (lrint, `.toNearestOrEven`) would give 4;
        // the 2x pins cannot tell the two apart, because their ties (25.5, 7.5) land on even numbers.
        #expect(CGFloat(300) * (15 / 1000) == 4.5)
        #expect((4.5 as CGFloat).rounded(.toNearestOrEven) == 4)
        let m = try metrics(15)
        #expect(m.descent == 5)
        #expect(m.ascent == 15)
        #expect(m.height == 20)
        #expect(m.width == 9)
    }

    @Test("width rounds up, everything else to nearest")
    func widthRoundsUp() throws {
        // 600 units at 21 px are 12.6 px → 13 wide; a 401-unit advance at 10 px, 4.01 px → 5.
        #expect(try metrics(21).width == 13)
        var tables = Self.jetBrainsMono
        tables.maxASCIIAdvance = 401
        #expect(try metrics(10, tables).width == 5)
    }

    @Test("decoration thicknesses and the cell never round down to zero")
    func floors() throws {
        for pixelSize in [3, 6, 8, 9.5, 12.5] as [CGFloat] {
            let m = try metrics(pixelSize)
            #expect(m.underlineThickness >= 1)
            #expect(m.strikethroughThickness >= 1)
            #expect(m.width >= 1)
            #expect(m.height >= 1)
        }
    }

    @Test("without a usable OS/2 strikeout, half the x-height and the underline thickness")
    func strikeoutFallback() throws {
        var tables = Self.jetBrainsMono
        tables.strikeout = nil
        // 550 / 2 at 25 px = 6.875 up → offset -7; thickness max(1, 1.25) → 1.
        var m = try metrics(25, tables)
        #expect(m.strikethroughOffset == -7)
        #expect(m.strikethroughThickness == 1)

        // A zero-size strikeout is unusable too.
        tables.strikeout = OS2Strikeout(size: 0, position: 320)
        m = try metrics(25, tables)
        #expect(m.strikethroughOffset == -7)

        // At 100 px the underline thickness (5 px) shows through as the fallback thickness.
        m = try metrics(100, tables)
        #expect(m.strikethroughThickness == 5)
        #expect(m.strikethroughOffset == -28)  // 55 / 2
    }

    @Test("a face with no units per em has no metrics")
    func zeroUnitsPerEm() {
        var tables = Self.jetBrainsMono
        tables.unitsPerEm = 0
        #expect(CellMetrics(tables: tables, pixelSize: 25, scale: 2) == nil)
    }

    @Test("the pixel formula is what the raw-table path feeds")
    func pixelFormula() throws {
        let direct = CellMetrics(ascent: 25.5, descent: 7.5, leading: 0, maxAdvance: 15,
                                 underlinePosition: -3.875, underlineThickness: 1.25,
                                 strikeoutPosition: 8, strikeoutThickness: 1.25, scale: 2)
        #expect(try metrics(25) == direct)
    }

    // MARK: - OS/2 strikeout parser

    @Test("the strikeout is two big-endian int16s at bytes 26 and 28")
    func os2Parser() throws {
        var table = [UInt8](repeating: 0xAA, count: 30)
        table[26] = 0x00; table[27] = 0x32   // 50
        table[28] = 0x01; table[29] = 0x40   // 320
        #expect(OS2Strikeout(os2Table: table) == OS2Strikeout(size: 50, position: 320))

        table[28] = 0xFF; table[29] = 0x38   // -200
        #expect(try #require(OS2Strikeout(os2Table: table)).position == -200)

        // Any collection of bytes, including a slice that does not start at index 0.
        let padded = [0xEE, 0xEE] + table
        #expect(OS2Strikeout(os2Table: padded[2...]) == OS2Strikeout(size: 50, position: -200))
    }

    @Test("a table too short for the strikeout fields is not parsed")
    func os2Truncated() {
        for length in [0, 1, 26, 28, 29] {
            #expect(OS2Strikeout(os2Table: [UInt8](repeating: 1, count: length)) == nil)
        }
    }

    @Test("strikeout pixels use one pixels-per-unit factor")
    func strikeoutPixels() throws {
        let strike = try #require(OS2Strikeout(size: 50, position: 320)
            .pixels(pixelSize: 25, unitsPerEm: 1000))
        #expect(strike.position == CGFloat(320) * (25 / 1000))
        #expect(strike.thickness == CGFloat(50) * (25 / 1000))
        #expect(OS2Strikeout(size: 50, position: 320).pixels(pixelSize: 25, unitsPerEm: 0) == nil)
        #expect(OS2Strikeout(size: -1, position: 320).pixels(pixelSize: 25, unitsPerEm: 1000) == nil)
    }

    // MARK: - The bundled font files

    /// The fonts stay in TkzTerminalRender's resources (ModuleResources and make-app.sh expect them
    /// there); the test reads them straight from the source tree.
    private static let fontDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/TkzTerminalRender/Resources/Fonts")

    @Test("the bundled faces carry the tables the pins assume",
          arguments: ["Regular", "Bold", "Italic", "BoldItalic"])
    func bundledFaceTables(face: String) throws {
        let url = Self.fontDirectory.appendingPathComponent("JetBrainsMono-\(face).ttf")
        let font = try SFNT(bytes: [UInt8](Data(contentsOf: url)))
        let head = try font.table("head"), hhea = try font.table("hhea")
        let post = try font.table("post"), os2 = try font.table("OS/2")

        // hhea.advanceWidthMax stands in for the ASCII advance: every glyph of a monospaced face is
        // 600 units, so the maximum over all glyphs is the maximum over ASCII.
        let tables = FontTables(
            unitsPerEm: Int(SFNT.uint16(head, 18)),
            ascender: Int(SFNT.int16(hhea, 4)),
            descender: Int(SFNT.int16(hhea, 6)),
            lineGap: Int(SFNT.int16(hhea, 8)),
            underlinePosition: Int(SFNT.int16(post, 8)),
            underlineThickness: Int(SFNT.int16(post, 10)),
            strikeout: OS2Strikeout(os2Table: os2),
            xHeight: Int(SFNT.int16(os2, 86)),
            maxASCIIAdvance: Int(SFNT.uint16(hhea, 10)))
        #expect(tables == Self.jetBrainsMono)
    }
}

/// Just enough of the sfnt table directory to find a table by tag.
private struct SFNT {
    struct Missing: Error { let tag: String }

    let bytes: [UInt8]
    private let directory: [String: Range<Int>]

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        guard bytes.count >= 12 else { throw Missing(tag: "directory") }
        var directory: [String: Range<Int>] = [:]
        for index in 0..<Int(SFNT.uint16(bytes[...], 4)) {
            let record = 12 + 16 * index
            guard record + 16 <= bytes.count else { throw Missing(tag: "directory") }
            let tag = String(decoding: bytes[record..<(record + 4)], as: UTF8.self)
            let offset = Int(SFNT.uint32(bytes, record + 8)), length = Int(SFNT.uint32(bytes, record + 12))
            guard offset + length <= bytes.count else { throw Missing(tag: tag) }
            directory[tag] = offset..<(offset + length)
        }
        self.directory = directory
    }

    /// The table's bytes; indices are the file's, so read them relative to `startIndex`.
    func table(_ tag: String) throws -> ArraySlice<UInt8> {
        guard let range = directory[tag] else { throw Missing(tag: tag) }
        return bytes[range]
    }

    static func uint16(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt16 {
        let base = bytes.startIndex + offset
        return UInt16(bytes[base]) << 8 | UInt16(bytes[base + 1])
    }

    static func int16(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> Int16 {
        Int16(bitPattern: uint16(bytes, offset))
    }

    static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
