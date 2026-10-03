// ChromeMetricsReferenceTests — the Mac chrome metrics of WOR-312 S2 as Linux reads them.
//
// Tests/Parity/References/fonts/chrome-metrics.json is written on the reference runner by
// `ChromeMetricsDump` (Tests/TkzAppTests/ChromeMetricsDumpTests.swift, through
// scripts/parity-chrome-references.sh). `ChromeMetricsReference` decodes the parts the Linux side
// compares with: the fonts and their per-string advances (S7's symbol advances, S8's Inter
// tracking fit), the session row's detail-line breakdown and wrap grid, and the status bar's
// visibility and truncation grid (S8, WOR-316, WOR-317). Unknown keys are ignored.
//
// The tests here hold the file to the rules it records, so a Linux reimplementation can trust that
// a grid follows from the widths next to it: the row is 59 pt exactly where `neededDetailWidth`
// exceeds the width, the components add up, nothing is truncated into less than
// `minTruncatedWidth`. They skip while the file is missing.

import Foundation
import Testing

/// chrome-metrics.json, schema 1.
struct ChromeMetricsReference: Decodable {
    struct Entry: Decodable {
        let name: String
        let font: String
        let kern: Double
        let tracked: [String: Double]?
    }
    struct Font: Decodable {
        let key: String
        let face: String
        let pointSize: Double
        let weight: String
        let fontName: String
        let ascender, descender, leading, capHeight, xHeight, lineHeight, baseline: Double
    }
    struct Advances: Decodable {
        let font: String
        /// `ascii`, `corpus` or `symbols`.
        let set: String
        let advances: [String: Double]
        let fallback: [String: [String]]?
    }
    struct SessionRow: Decodable {
        struct Constants: Decodable {
            let textLeft, badgeGap, rightInset, textPad, badgePadding, rowHeight, wrappedRowHeight: Double
            let detailFont, badgeFont, titleFont: String
        }
        struct Component: Decodable {
            let part: String
            let text: String?
            let font: String?
            let measured: Double?
            let width: Double
        }
        struct Model: Decodable {
            let name: String
            let title: String
            let titleWidth: Double
            let components: [Component]?
            let neededDetailWidth: Double?
            let heights: [Int]
        }
        let constants: Constants
        let widths: [String: Int]
        let models: [Model]
    }
    struct StatusBar: Decodable {
        struct Constants: Decodable {
            let insetX, minTruncatedWidth, fitSlack, dotWidth, spaceWidth: Double
            let textFont, pillFont: String
        }
        struct Item: Decodable {
            let kind: String
            let text: String
            let trailing: Bool
            let separated: Bool
            let width: Double
        }
        struct Strip: Decodable {
            let name: String
            let items: [Item]
        }
        struct Decision: Decodable {
            let strip: String
            let width: Int
            let placed: [Int]
            let split: Bool
            let truncated: [String: Double]?
        }
        let constants: Constants
        let widths: [String: Int]
        let strips: [Strip]
        let grid: [Decision]
    }

    let schema: Int
    let platform: String
    let entries: [Entry]
    let fonts: [Font]
    let advances: [Advances]
    let sessionRow: SessionRow
    let statusBar: StatusBar

    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Parity/References/fonts/chrome-metrics.json")
    static var isCommitted: Bool { FileManager.default.fileExists(atPath: url.path) }
    static let skip: Comment = "DEFERRED: Tests/Parity/References/fonts/chrome-metrics.json comes from WOR-312 S2 on the reference Mac"

    static func load() throws -> ChromeMetricsReference {
        try JSONDecoder().decode(ChromeMetricsReference.self, from: Data(contentsOf: url))
    }

    /// The Mac's width of `string` in the font recorded under `key` (`"mono 10 regular"`), from
    /// whichever set holds it.
    func advance(of string: String, font key: String) -> Double? {
        advances.lazy.filter { $0.font == key }.compactMap { $0.advances[string] }.first
    }
}

@Suite(.enabled(if: ChromeMetricsReference.isCommitted, ChromeMetricsReference.skip))
struct ChromeMetricsReferenceTests {
    @Test("every entry names a recorded font, and every font has its three advance sets")
    func fontsAreComplete() throws {
        let reference = try ChromeMetricsReference.load()
        #expect(reference.schema == 1)
        #expect(reference.platform == "macos")
        let keys = Set(reference.fonts.map(\.key))
        #expect(keys.count == reference.fonts.count)
        for entry in reference.entries {
            #expect(keys.contains(entry.font), "\(entry.name) → \(entry.font)")
            #expect((entry.kern != 0) == (entry.tracked != nil), "\(entry.name)")
        }
        for key in keys {
            let sets = reference.advances.filter { $0.font == key }.map(\.set).sorted()
            #expect(sets == ["ascii", "corpus", "symbols"], "\(key): \(sets)")
        }
        // The roles S2 names: the 9 pt semibold badge and the mono detail line at 10 pt.
        #expect(reference.entries.contains { $0.name == "Typography.badge" && $0.font == "ui 9 semibold" })
        #expect(reference.entries.contains { $0.name == "Theme.Fonts.mono.detail" && $0.font == "mono 10 regular" })
        for glyph in ["\u{2318}", "\u{21E7}", "\u{2325}", "\u{2303}", "\u{238B}", "\u{23CE}", "\u{21A9}", "\u{2387}", "\u{00B7}"] {
            #expect(reference.advance(of: glyph, font: "mono 10 regular") != nil, "\(glyph)")
        }
    }

    @Test("the session row's components add up, and it wraps exactly where they exceed the width")
    func sessionRowFollowsItsWidths() throws {
        let row = try ChromeMetricsReference.load().sessionRow
        let from = try #require(row.widths["from"]), to = try #require(row.widths["to"]), step = try #require(row.widths["step"])
        let widths = Array(stride(from: from, through: to, by: step))
        var wrapped = 0, single = 0
        for model in row.models {
            #expect(model.heights.count == widths.count, "\(model.name)")
            if let components = model.components, let needed = model.neededDetailWidth {
                #expect(components.reduce(0) { $0 + $1.width } == needed, "\(model.name)")
                for component in components {
                    guard let measured = component.measured else { continue }
                    // A text part rounds up and adds the pad; a badge adds both sides' padding. The
                    // rounding is the Mac's, of the unrounded width: only its bracket is checked.
                    let pad = component.font == row.constants.badgeFont ? row.constants.badgePadding : row.constants.textPad
                    let gap = component.part == "directory" ? 0 : row.constants.badgeGap
                    let ceiled = component.width - gap - pad
                    #expect(ceiled == ceiled.rounded() && ceiled >= measured - 0.001 && ceiled < measured + 1,
                            "\(model.name).\(component.part)")
                }
            } else {
                #expect(model.components == nil && model.neededDetailWidth == nil, "\(model.name)")
            }
            for (width, height) in zip(widths, model.heights) {
                let wraps = (model.neededDetailWidth ?? 0) > Double(width)
                #expect(Double(height) == (wraps ? row.constants.wrappedRowHeight : row.constants.rowHeight),
                        "\(model.name) @ \(width)")
                if wraps { wrapped += 1 } else { single += 1 }
            }
        }
        // The grid is only worth matching if it holds both answers.
        #expect(wrapped > 0 && single > 0)
    }

    @Test("the status bar grid keeps items in order and truncates into at least minTruncatedWidth")
    func statusBarFollowsItsRules() throws {
        let bar = try ChromeMetricsReference.load().statusBar
        let strips = Dictionary(uniqueKeysWithValues: bar.strips.map { ($0.name, $0) })
        var truncations = 0
        for decision in bar.grid {
            let strip = try #require(strips[decision.strip])
            #expect(decision.placed.allSatisfy { strip.items.indices.contains($0) }, "\(decision.strip) @ \(decision.width)")
            #expect(Set(decision.placed).count == decision.placed.count)
            for (index, room) in decision.truncated ?? [:] {
                let item = try #require(Int(index).map { strip.items[$0] })
                #expect(item.kind == "runs" && room >= bar.constants.minTruncatedWidth && room < item.width,
                        "\(decision.strip) @ \(decision.width): \(item.text) into \(room)")
                truncations += 1
            }
            // Everything fits once the strip is wider than the sum of its parts.
            let whole = strip.items.reduce(2 * bar.constants.insetX) { $0 + $1.width }
                + Double(strip.items.count) * bar.constants.dotWidth
            if Double(decision.width) >= whole {
                #expect(decision.placed.count == strip.items.count && decision.truncated == nil,
                        "\(decision.strip) @ \(decision.width)")
            }
        }
        #expect(truncations > 0)
    }
}
