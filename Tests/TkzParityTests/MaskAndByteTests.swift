// The mask file (typed kinds, pixel and cell rects) and the byte compare of the exact layers.

import Foundation
import Testing
@testable import TkzParity

@Suite struct MaskTests {
    @Test func aMaskFileDecodesAndRasterises() throws {
        let json = """
            {"schema": 1,
             "grid": {"cellWidth": 14, "cellHeight": 30, "originX": 2},
             "masks": [
               {"kind": "fallbackGlyph", "cells": {"column": 1, "row": 0, "columns": 2, "rows": 1}, "source": "✳"},
               {"kind": "vibrancy", "rect": {"x": 0.4, "y": 1.6, "width": 1.2, "height": 1}}
             ]}
            """
        let set = try ParityMaskSet.decode(Data(json.utf8))
        #expect(set.grid == CellGrid(cellWidth: 14, cellHeight: 30, originX: 2, originY: 0))
        let bitmap = set.bitmap(width: 50, height: 40)
        // Cells 1–2 of row 0: x [16, 44), y [0, 30).
        #expect(bitmap.countByKind[.fallbackGlyph] == 28 * 30)
        #expect(bitmap.isMasked(16) && !bitmap.isMasked(15) && bitmap.isMasked(43) && !bitmap.isMasked(44))
        // The fractional rect covers every pixel it touches: x [0, 2), y [1, 3).
        #expect(bitmap.countByKind[.vibrancy] == 4)
        #expect(bitmap.isMasked(1 * 50 + 0) && bitmap.isMasked(2 * 50 + 1) && !bitmap.isMasked(3 * 50))
        #expect(bitmap.maskedCount == 28 * 30 + 4)
    }

    @Test func masksAreClippedToTheImage() {
        let set = ParityMaskSet(masks: [
            ParityMask(kind: .windowControls, rect: PixelRect(x: -10, y: -10, width: 15, height: 12)),
            ParityMask(kind: .cjkEmoji, rect: PixelRect(x: 1e300, y: 0, width: 1e300, height: 5)),
        ])
        let bitmap = set.bitmap(width: 8, height: 8)
        #expect(bitmap.countByKind == [.windowControls: 5 * 2])
    }

    @Test(arguments: [
        #"{"schema": 2, "masks": []}"#,
        #"{"schema": 1, "masks": [{"kind": "searchField", "rect": {"x": 0, "y": 0, "width": 1, "height": 1}}]}"#,
        #"{"schema": 1, "masks": [{"kind": "vibrancy"}]}"#,
        #"{"schema": 1, "masks": [{"kind": "vibrancy", "cells": {"column": 0, "row": 0, "columns": 1, "rows": 1}}]}"#,
        #"{"schema": 1, "grid": {"cellWidth": 0, "cellHeight": 30}, "masks": []}"#,
        #"{"schema": 1, "masks": [{"kind": "vibrancy", "rect": {"x": 0, "y": 0, "width": -1, "height": 1}}]}"#,
        """
        {"schema": 1, "grid": {"cellWidth": 14, "cellHeight": 30}, "masks": [{"kind": "vibrancy",
         "rect": {"x": 0, "y": 0, "width": 1, "height": 1}, "cells": {"column": 0, "row": 0, "columns": 1, "rows": 1}}]}
        """,
    ])
    func invalidMaskFilesAreRejected(json: String) {
        #expect(throws: MaskError.self) { try ParityMaskSet.decode(Data(json.utf8)) }
    }

    @Test func theKindsAreADR0003sFour() {
        #expect(MaskKind.allCases.map(\.rawValue) == ["fallbackGlyph", "cjkEmoji", "vibrancy", "windowControls"])
    }
}

@Suite struct ByteComparisonTests {
    @Test func identicalBytesPass() {
        let report = ByteComparison.compare([1, 2, 3], [1, 2, 3], json: false)
        #expect(report.identical && report.pass && report.firstDifference == nil)
    }

    @Test func theFirstDifferenceIsLocated() {
        let a = Array("line one\nline two\n".utf8)
        var b = a
        b[14] = UInt8(ascii: "X")
        let report = ByteComparison.compare(a, b, json: false)
        #expect(!report.pass)
        #expect(report.firstDifference == 14)
        #expect(report.firstDifferenceLine == 2 && report.firstDifferenceColumn == 6)
        // A prefix differs at the shorter length.
        #expect(ByteComparison.compare([1, 2], [1, 2, 3], json: false).firstDifference == 2)
        #expect(!ByteComparison.compare([1, 2], [1, 2, 3], json: false).pass)
    }

    @Test func jsonKeyOrderAloneIsEqual() {
        let a = Array(#"{"b":1,"a":{"y":[1,2],"x":"s"}}"#.utf8)
        let b = Array(#"{"a":{"x":"s","y":[1,2]},"b":1}"#.utf8)
        let report = ByteComparison.compare(a, b, json: true)
        #expect(!report.identical)
        #expect(report.canonicalJSONEqual == true)
        #expect(report.pass)
        // Without JSON mode the same bytes differ.
        #expect(!ByteComparison.compare(a, b, json: false).pass)
    }

    @Test func jsonDifferencesNameTheirPaths() {
        let a = Array(#"{"root":{"frame":{"x":1,"y":2},"children":[{"w":3},{"w":4}]},"schema":1}"#.utf8)
        let b = Array(#"{"schema":1,"root":{"children":[{"w":3},{"w":5},{"w":6}],"frame":{"x":1,"y":2.5}}}"#.utf8)
        let report = ByteComparison.compare(a, b, json: true)
        #expect(!report.pass)
        #expect(report.canonicalJSONEqual == false)
        #expect(report.differingPaths == ["$.root.children[1].w", "$.root.children[2]", "$.root.frame.y"])
        #expect(report.failures == ["JSON differs after canonical key order, first at $.root.children[1].w"])
    }

    @Test func invalidJSONFails() {
        let report = ByteComparison.compare(Array("{".utf8), Array("{}".utf8), json: true)
        #expect(!report.pass)
        #expect(report.failures == ["a is not valid JSON"])
    }
}

/// TkzParity is portable: Foundation and TkzPNG only, never AppKit, Metal, CoreGraphics or GTK.
@Suite struct TkzParitySourceHygieneTests {
    @Test func importsOnlyFoundationAndTkzPNG() throws {
        let directory = TestImages.repoRoot.appending(path: "Sources/TkzParity")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 6)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                guard let match = line.wholeMatch(of: #/\s*(?:@testable\s+|@_exported\s+)?import\s+(\w+).*/#) else { continue }
                #expect(["Foundation", "TkzPNG"].contains(String(match.1)),
                        "\(file.lastPathComponent): \(line)")
            }
        }
    }
}
