// FaceMetricsTests — CellMetrics from FreeType's raw tables equal the Mac's (WOR-312 S3).
//
// The pins are the Mac's CoreText numbers for the bundled JetBrains Mono (the same ones
// Tests/TkzRenderCoreTests/CellMetricsTablesTests.swift checks against hand-entered tables). Here
// the tables come out of the real font files through `FT_Get_Sfnt_Table`, so a wrong table, field
// or unit conversion in the FreeType path shows up as a changed number.
//
// The Mac's own export (`vtdump fontmetrics --json`, WOR-312 S1) is compared too when it is
// committed; until then that test is skipped.

import Foundation
import Testing
import TkzRenderCore
@testable import TkzFontsFT

@Suite("CellMetrics from FreeType faces")
struct FaceMetricsTests {

    /// JetBrains Mono's tables as WOR-311 pinned them from the font files' bytes.
    private static let jetBrainsMono = FontTables(
        unitsPerEm: 1000,
        ascender: 1020, descender: -300, lineGap: 0,
        underlinePosition: -155, underlineThickness: 50,
        strikeout: OS2Strikeout(size: 50, position: 320),
        xHeight: 550,
        maxASCIIAdvance: 600)

    private func metrics(pointSize: CGFloat, scale: CGFloat) throws -> CellMetrics {
        try TerminalFaces(pointSize: pointSize, scale: scale).metrics
    }

    @Test("12.5 pt at 2x (25 px): 15x33, baseline 26, underline 4, strike -8")
    func at25px() throws {
        let m = try metrics(pointSize: 12.5, scale: 2)
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
        #expect(m.scale == 2)
    }

    @Test("14 pt at 2x (28 px): 17x37, baseline 29, underline 4, strike -9")
    func at28px() throws {
        let m = try metrics(pointSize: 14, scale: 2)
        #expect(m.width == 17)
        #expect(m.height == 37)
        #expect(m.baseline == 29)
        #expect(m.underlineOffset == 4)
        #expect(m.strikethroughOffset == -9)
    }

    @Test("14 pt at 1.6x (22.4 px): 14x30, baseline 23, underline 3, strike -7")
    func at22point4px() throws {
        let faces = try TerminalFaces(pointSize: 14, scale: 1.6)
        #expect(faces.pixelSize == 14 * 1.6)  // 22.400000000000002, as the Mac's FontSet builds it
        let m = faces.metrics
        #expect(m.width == 14)
        #expect(m.height == 30)
        #expect(m.baseline == 23)
        #expect(m.underlineOffset == 3)
        #expect(m.strikethroughOffset == -7)
    }

    @Test("ties round half away from zero; the width rounds up")
    func rounding() throws {
        // 7.5 pt at 2x is 15 px: the descent is 300 * 15 / 1000 = 4.5 exactly. Half away from zero
        // gives 5, banker's rounding 4. The 2x pins cannot tell them apart (25.5 and 7.5 tie to even).
        #expect((4.5 as CGFloat).rounded(.toNearestOrEven) == 4)
        var m = try metrics(pointSize: 7.5, scale: 2)
        #expect(m.descent == 5)
        #expect(m.ascent == 15)
        #expect(m.height == 20)
        #expect(m.width == 9)  // 9.0 exactly stays 9

        // 5.25 pt at 2x is 10.5 px: the advance is 6.3 px, so the cell is 7 wide where rounding to
        // nearest would give 6, while the ascent (10.71) and descent (3.15) round to nearest.
        m = try metrics(pointSize: 5.25, scale: 2)
        #expect(m.width == 7)
        #expect(m.ascent == 11)
        #expect(m.descent == 3)
    }

    @Test("all four faces' raw tables are the pinned JetBrains Mono tables",
          arguments: FontStyle.allCases)
    func tablesThroughFreeType(style: FontStyle) throws {
        let faces = try TerminalFaces(pointSize: 14, scale: 2)
        #expect(faces.tables(style) == Self.jetBrainsMono)
    }

    @Test("the faces are the bundled JetBrains Mono, by PostScript name")
    func postScriptNames() throws {
        let faces = try TerminalFaces(pointSize: 14, scale: 2)
        #expect(faces.postScriptName(.regular) == "JetBrainsMono-Regular")
        #expect(faces.postScriptName(.bold) == "JetBrainsMono-Bold")
        #expect(faces.postScriptName(.italic) == "JetBrainsMono-Italic")
        #expect(faces.postScriptName(.boldItalic) == "JetBrainsMono-BoldItalic")
    }

    @Test("the size request is an exact 16.16 scale, not a rounded 26.6 character size")
    func scaleRequest() {
        // 22.4 * 64 / 1000 * 65536 = 93952.4096: a 26.6 size would be 1434/64 = 22.40625 px instead.
        #expect(FreeTypeFace.scale(pixelSize: 22.4, unitsPerEm: 1000) == 93952)
        #expect(FreeTypeFace.scale(pixelSize: 28, unitsPerEm: 1000) == 117441)  // 117440.512
        #expect(FreeTypeFace.scale(pixelSize: 25, unitsPerEm: 1000) == 104858)  // 104857.6
    }

    @Test("faces can be queried from many tasks at once")
    func concurrentQueries() async throws {
        let faces = try TerminalFaces(pointSize: 14, scale: 2)
        let expected = FontStyle.allCases.map { faces.outlineMetrics(of: "H", style: $0) }
        #expect(expected.allSatisfy { $0 != nil })
        let results = await withTaskGroup(of: (Int, GlyphOutlineMetrics?).self) { group in
            for index in 0..<32 {
                let style = FontStyle.allCases[index % 4]
                group.addTask { (index % 4, faces.outlineMetrics(of: "H", style: style)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 32)
        for (styleIndex, outline) in results {
            #expect(outline == expected[styleIndex])
        }
    }

    // MARK: - The Mac reference (WOR-312 S1)

    /// `Tests/Parity/References/fonts/fontmetrics.json`, written on the reference Mac by
    /// `tkzmux-vtdump fontmetrics --json` (WOR-312 S1).
    static let referenceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Parity/References/fonts/fontmetrics.json")

    /// TODO(WOR-312 S1): the exporter owns this schema. This decoder is the Linux side's
    /// expectation of it — one entry per configuration, with every `CellMetrics` field — and must be
    /// aligned with whatever S1 commits. Unknown keys are ignored.
    struct Reference: Decodable {
        struct Configuration: Decodable {
            /// PostScript name of the measured face (the regular face).
            let font: String
            let pointSize: Double
            let scale: Double
            let metrics: Metrics
        }
        struct Metrics: Decodable, Equatable {
            let width, height, ascent, descent, leading, baseline: Int
            let underlineOffset, underlineThickness, strikethroughOffset, strikethroughThickness: Int
        }
        let configurations: [Configuration]
    }

    @Test("every configuration in the Mac's fontmetrics.json matches exactly",
          .enabled(if: FileManager.default.fileExists(atPath: referenceURL.path),
                   "DEFERRED: Tests/Parity/References/fonts/fontmetrics.json comes from WOR-312 S1 on the reference Mac"))
    func matchesMacReference() throws {
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: Self.referenceURL))
        #expect(!reference.configurations.isEmpty)
        for configuration in reference.configurations where configuration.font.hasPrefix("JetBrainsMono") {
            let m = try metrics(pointSize: configuration.pointSize, scale: configuration.scale)
            let linux = Reference.Metrics(
                width: m.width, height: m.height, ascent: m.ascent, descent: m.descent,
                leading: m.leading, baseline: m.baseline,
                underlineOffset: m.underlineOffset, underlineThickness: m.underlineThickness,
                strikethroughOffset: m.strikethroughOffset, strikethroughThickness: m.strikethroughThickness)
            #expect(linux == configuration.metrics, "\(configuration.pointSize) pt at \(configuration.scale)x")
        }
    }
}
