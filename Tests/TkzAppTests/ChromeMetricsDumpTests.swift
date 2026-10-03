// ChromeMetricsDumpTests — WOR-312 S2: the Mac chrome's text metrics, as NSFont and the views
// measure them, for the Linux chrome to be calibrated against (Inter and its tracking table,
// WOR-312 S8; the canvas UI text of WOR-316 and WOR-317; the symbol subset's advances, S7).
//
// Gated: the dump runs only with `TKZMUX_CHROME_METRICS_OUT=<file>` and is skipped otherwise, so the
// default `swift test` pays for one trait check. scripts/parity-chrome-references.sh sets it on the
// reference runner (.github/workflows/font-references.yml) and writes
// Tests/Parity/References/fonts/chrome-metrics.json, which Tests/TkzFontsFTTests reads on Linux.
// The dump measures everything twice in one process and refuses a measurement that is not
// reproducible; the script's `--check` then demands byte identity from a second process.
//
// What it holds (compact, key-sorted JSON, one record per line; points throughout, rounded to
// 1/10000 pt except where the Mac's own arithmetic is exact):
//
//   * `entries`: every typography role of WOR-307 (`DesignTokens.Typography.roles`) and the
//     preset sizes and inline fonts the chrome calls directly (`extraEntries`: the session title,
//     the mono detail line at 10 pt, the status bar, …), each resolved through
//     `Theme.Fonts.font(_:)`, that is `Theme.Fonts.ui/mono` exactly as ThemeAppKit does. An entry
//     names its font by key (`"ui 9 semibold"`, `"mono 10 regular"`); with tracking it also holds
//     the corpus widths with that `.kern` applied.
//   * `fonts`: one line per distinct font: the PostScript name it resolved to, ascender,
//     descender, leading, cap and x height, and `NSLayoutManager`'s default line height and
//     baseline.
//   * `advances`: per font, the width of every printable ASCII character, of every corpus string,
//     and of every symbol (the modifier glyphs, S7's agent, chrome and UI lists, and every
//     non-ASCII scalar in a TkzApp or TkzCore string literal), as `NSAttributedString.size()`
//     reports it with only the font set. Where CoreText falls back to another font, `fallback`
//     names the run fonts.
//   * `sessionRow`: `SessionRowView.neededDetailWidth` per fixture model with its components, and
//     the row height (44 or 59, `detailWraps`) at every width from 240 to 520 pt.
//   * `statusBar`: each strip's items with their widths, and at every width from 100 to 1300 pt
//     which items `StatusBarView.placement()` keeps, whether the trailing group sits flush right,
//     and which item is truncated into how much room (`minTruncatedWidth` = 30).
//   * `reference`: the machine, as the component goldens record it.

import AppKit
import CoreText
import Testing
import TkzCore
import TkzTerminalRender

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct ChromeMetricsDumpTests {
    nonisolated static let outputVariable = "TKZMUX_CHROME_METRICS_OUT"

    /// Where the dump goes; nil (and the test skipped) without the variable. Read by the
    /// `.enabled` trait, off the main actor.
    nonisolated static var outputPath: String? {
        guard let path = ProcessInfo.processInfo.environment[outputVariable], !path.isEmpty else { return nil }
        return path
    }

    @Test(
        .enabled(
            if: Self.outputPath != nil,
            "Writes the chrome metrics reference only when asked: TKZMUX_CHROME_METRICS_OUT=<file> (scripts/parity-chrome-references.sh)"))
    func dump() throws {
        _ = NSApplication.shared
        _ = FontSet.registration
        let path = try #require(Self.outputPath)
        let first = try ChromeMetricsDump.render()
        let again = try ChromeMetricsDump.render()
        try #require(first == again, "the chrome metrics differ between two measurements in one process")
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try first.write(to: url, options: .atomic)
        print("wrote \(url.path) (\(first.count) bytes)")
    }
}

// MARK: - The dump

@MainActor
enum ChromeMetricsDump {
    typealias Role = DesignTokens.Typography.Role

    static let schema = 1

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Entries

    struct Entry {
        let role: Role
        /// Where the chrome uses it, for a reader of the JSON.
        let use: String
    }

    /// The fonts the chrome calls by preset size or inline rather than through a role, each as the
    /// role it would be: `Theme.Fonts.font(_:)` makes the same `Theme.Fonts.ui/mono` call the
    /// source makes. A mono entry is Regular whatever the call site asks for: `Theme.Fonts.mono`
    /// ignores the weight once JetBrains Mono resolves (`DesignTokens+Typography.swift`).
    static let extraEntries: [Entry] = {
        let ui = Theme.Fonts.ui
        let mono = Theme.Fonts.mono
        return [
            Entry(role: .ui("Theme.Fonts.ui.title", ui.title), use: "window title, palette and tab titles"),
            Entry(role: .ui("Theme.Fonts.ui.title.medium", ui.title, .medium), use: "the session row's title (SessionRowView.titleFont)"),
            Entry(role: .ui("Theme.Fonts.ui.title.bold", ui.title, .bold), use: "an unread activity row's title"),
            Entry(role: .ui("Theme.Fonts.ui.body", ui.body), use: "summary strip, menu rows, subtitles"),
            Entry(role: .ui("Theme.Fonts.ui.body.medium", ui.body, .medium), use: "emphasised body text"),
            Entry(role: .ui("Theme.Fonts.ui.caption", ui.caption), use: "captions and hints"),
            Entry(role: .ui("Theme.Fonts.ui.caption.semibold", ui.caption, .semibold), use: "the group header (uppercase)"),
            Entry(role: .mono("Theme.Fonts.mono.detail", mono.detail), use: "the sidebar's …/folder · ⎇ branch line (SessionRowView.branchFont)"),
            Entry(role: .mono("Theme.Fonts.mono.statusBar", mono.statusBar), use: "the status bar's text (StatusBarView.textFont)"),
            Entry(role: .mono("Theme.Fonts.mono@ui.title", ui.title), use: "Theme.Fonts.mono(theme.fontUI.title)"),
            Entry(role: .mono("Theme.Fonts.mono@ui.body", ui.body), use: "Theme.Fonts.mono(theme.fontUI.body)"),
            Entry(role: .mono("Typography.changesDiffSize", DesignTokens.Typography.changesDiffSize.value),
                  use: "the changes viewer's diff text"),
            Entry(role: .mono("Typography.changesFileSize", DesignTokens.Typography.changesFileSize.value),
                  use: "the changes viewer's file list"),
            Entry(role: .mono("MainToolbarController.clusterGlyphSize", MainToolbarController.clusterGlyphSize),
                  use: "the toolbar's cluster glyphs (asks for medium, draws Regular)"),
        ]
    }()

    static var entries: [Entry] {
        DesignTokens.Typography.roles.map { Entry(role: $0, use: "DesignTokens.Typography") } + extraEntries
    }

    /// The key a font is recorded under: face, size and weight drawn.
    static func key(_ role: Role) -> String {
        "\(role.face.rawValue) \(String(format: "%g", role.size)) \(role.weight.rawValue)"
    }

    // MARK: Corpus

    /// Strings the chrome draws or could draw, plus pangrams and pairs that exercise kerning and
    /// figures. Measured in every font.
    static let corpus: [String] = [
        "The quick brown fox jumps over the lazy dog",
        "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG",
        "Hamburgefonstiv", "AV Wa To Ty LT ff fi", "0123456789", "1,234.56%",
        // Sidebar
        "SESSIONS", "NORTHWIND TRADING", "Fix the rounding bug", "Move reporting onto the new scheduler",
        "NEEDS YOU", "MUTED", "WT", "merged", "$0.42", "6.2 GB",
        "\u{2026}/reporting", "\u{2387} main", "\u{2387} feature/reporting-scheduler-rewrite",
        // Status bar
        "\u{2387} feature/tkz-18-main-window", "SONNET 4.5", "+142 \u{2212}38", "12 files",
        "\u{2191}0 \u{2193}2", ":5173", "#418", "Context", "62%", "Usage", "5% \u{00B7} 41%",
        "\u{293F} 7 behind main",
        // Sheets, palette, settings, cards
        "Delete worktree", "Cancel", "Rebase onto origin/main", "New Session", "Settings", "Appearance",
        "\u{2318}K", "\u{21E7}\u{2318}P", "Restored sidebar from backup", "PROMPT", "RECAP",
    ]

    /// Printable ASCII, one character each.
    static let ascii: [String] = (0x20...0x7E).map { String(UnicodeScalar(UInt8($0))) }

    /// WOR-312 S7's lists (Sources/TkzFontsFT/BundledSymbols.swift; `tkzmux-vtdump symbols` uses the
    /// same), and the modifier glyphs first.
    static let listedSymbols: [Unicode.Scalar] = [
        // modifier
        "\u{2318}", "\u{21E7}", "\u{2325}", "\u{2303}", "\u{238B}", "\u{23CE}", "\u{21A9}",
        // agent
        "\u{23FA}", "\u{23BF}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}",
        "\u{21AF}", "\u{2714}", "\u{25D0}", "\u{23F5}",
        // chrome
        "\u{2387}", "\u{21B5}", "\u{25BE}", "\u{25B8}", "\u{2715}", "\u{25EB}", "\u{25AC}", "\u{2B13}",
        "\u{263E}", "\u{2600}", "\u{293F}", "\u{2699}", "\u{27F3}", "\u{FF0B}", "\u{00B7}",
        // ui
        "\u{25C8}", "\u{2328}", "\u{25CF}", "\u{25A0}", "\u{25B6}", "\u{2423}", "\u{21E5}",
    ]

    /// The listed symbols and every non-ASCII scalar of a TkzApp or TkzCore string literal (the
    /// scan `SymbolCoverageTests.chromeLiteralScalars` makes on Linux), in scalar order.
    static func symbols() throws -> [String] {
        var found = Set(listedSymbols)
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let literal = try Regex(#""(?:[^"\\]|\\.)*""#)
        let escape = try Regex(#"\\u\{([0-9A-Fa-f]{1,6})\}"#)
        for root in ["Sources/TkzApp", "Sources/TkzCore"] {
            let directory = repo.appendingPathComponent(root, isDirectory: true)
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                throw Failure(description: "cannot list \(directory.path)")
            }
            for case let file as URL in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for line in text.split(separator: "\n") {
                    if line.drop(while: { $0 == " " }).hasPrefix("//") { continue }
                    for match in line.matches(of: literal) {
                        let body = line[match.range]
                        for scalar in body.unicodeScalars where scalar.value > 0x7F { found.insert(scalar) }
                        for escaped in body.matches(of: escape) {
                            if let hex = escaped.output[1].substring, let value = UInt32(hex, radix: 16),
                               value > 0x7F, let scalar = Unicode.Scalar(value) {
                                found.insert(scalar)
                            }
                        }
                    }
                }
            }
        }
        return found.sorted { $0.value < $1.value }.map { String($0) }
    }

    // MARK: Measuring

    /// 1/10000 pt: far below any tolerance the Linux side applies, and stable across printers.
    static func r(_ value: CGFloat) -> Double {
        (Double(value) * 10_000).rounded() / 10_000
    }

    /// The width `NSAttributedString` measures, the font (and `kern`) the only attributes: what
    /// `SidebarLayers.width` rounds up and what `StatusBarView` lays out with.
    static func width(_ string: String, font: NSFont, kern: Double = 0) -> CGFloat {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if kern != 0 { attributes[.kern] = kern }
        return NSAttributedString(string: string, attributes: attributes).size().width
    }

    /// The PostScript names of the CoreText runs `string` lays out in.
    static func runFonts(_ string: String, font: NSFont) -> [String] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        return runs.map { run in
            guard let attributes = CTRunGetAttributes(run) as? [String: Any],
                  let value = attributes[kCTFontAttributeName as String] else { return "?" }
            return CTFontCopyPostScriptName(value as! CTFont) as String  // swiftlint:disable:this force_cast
        }
    }

    // MARK: Records

    struct EntryRecord: Encodable {
        let name: String
        let use: String
        let font: String
        /// The role's letter-spacing in points (`Role.kern`), 0 for none.
        let kern: Double
        /// The corpus widths with that `.kern` applied; nil without tracking.
        let tracked: [String: Double]?
    }

    struct FontRecord: Encodable {
        let key: String
        let face: String
        let pointSize: Double
        let weight: String
        /// `NSFont.fontName`: the PostScript name the request resolved to.
        let fontName: String
        let familyName: String
        let ascender, descender, leading, capHeight, xHeight: Double
        /// `NSLayoutManager.defaultLineHeight(for:)` and `.defaultBaselineOffset(for:)`.
        let lineHeight, baseline: Double
    }

    struct AdvanceRecord: Encodable {
        let font: String
        /// `ascii`, `corpus` or `symbols`.
        let set: String
        let advances: [String: Double]
        /// The run fonts of every string CoreText does not lay out in the font alone.
        let fallback: [String: [String]]?
    }

    static func measureFonts() throws -> (entries: [EntryRecord], fonts: [FontRecord], advances: [AdvanceRecord]) {
        let symbols = try symbols()
        var entryRecords: [EntryRecord] = []
        var fonts: [String: (Role, NSFont)] = [:]
        for entry in entries {
            let font = Theme.Fonts.font(entry.role)
            let key = key(entry.role)
            if let known = fonts[key], known.1.fontName != font.fontName || known.1.pointSize != font.pointSize {
                throw Failure(description: "\(key) resolves to both \(known.1.fontName) and \(font.fontName)")
            }
            fonts[key] = fonts[key] ?? (entry.role, font)
            let kern = entry.role.kern
            let tracked = kern == 0 ? nil : Dictionary(uniqueKeysWithValues: corpus.map { ($0, r(width($0, font: font, kern: kern))) })
            entryRecords.append(EntryRecord(name: entry.role.name, use: entry.use, font: key, kern: kern, tracked: tracked))
        }

        var fontRecords: [FontRecord] = []
        var advanceRecords: [AdvanceRecord] = []
        let layout = NSLayoutManager()
        for key in fonts.keys.sorted() {
            let (role, font) = fonts[key]!
            fontRecords.append(FontRecord(
                key: key, face: role.face.rawValue, pointSize: role.size, weight: role.weight.rawValue,
                fontName: font.fontName, familyName: font.familyName ?? "",
                ascender: r(font.ascender), descender: r(font.descender), leading: r(font.leading),
                capHeight: r(font.capHeight), xHeight: r(font.xHeight),
                lineHeight: r(layout.defaultLineHeight(for: font)), baseline: r(layout.defaultBaselineOffset(for: font))))
            for (set, strings) in [("ascii", ascii), ("corpus", corpus), ("symbols", symbols)] {
                var advances: [String: Double] = [:]
                var fallback: [String: [String]] = [:]
                for string in strings {
                    advances[string] = r(width(string, font: font))
                    let runs = runFonts(string, font: font)
                    if runs.contains(where: { $0 != font.fontName }) { fallback[string] = runs }
                }
                advanceRecords.append(AdvanceRecord(
                    font: key, set: set, advances: advances, fallback: fallback.isEmpty ? nil : fallback))
            }
        }
        return (entryRecords, fontRecords, advanceRecords)
    }

    // MARK: The session row

    /// `SessionRowView`'s private constants, as `neededDetailWidth` adds them. `sessionRow()` holds
    /// their sum to the view's own answer for every model, so a change on either side stops the
    /// dump rather than recording a stale breakdown.
    static let textLeft: CGFloat = 30 + CGFloat(SidebarMetrics.sessionIndent)
    static let badgeGap: CGFloat = 6
    static let rightInset: CGFloat = 12
    /// What `SidebarLayers.width` leaves after a text layer's rounded width.
    static let textPad: CGFloat = 1
    static let detailRole = Role.mono("Theme.Fonts.mono.detail", Theme.Fonts.mono.detail)
    static let badgeRole = DesignTokens.Typography.badge
    static let titleRole = Role.ui("Theme.Fonts.ui.title.medium", Theme.Fonts.ui.title, .medium)

    static let rowWidths = Array(240...520)

    struct SessionRowSection: Encodable {
        struct Constants: Encodable {
            let textLeft, badgeGap, rightInset, textPad, badgePadding: Double
            let detailFont, badgeFont, titleFont: String
            let rowHeight, wrappedRowHeight: Double
            let rule: String
        }
        struct Component: Encodable {
            let part: String
            let text: String?
            let font: String?
            /// The unrounded width.
            let measured: Double?
            /// What `neededDetailWidth` adds for this part: the gap before it, the rounded-up
            /// width, and the text pad or the badge padding.
            let width: Double
        }
        struct Model: Encodable {
            let name: String
            let title: String
            let titleWidth: Double
            let directory: String?
            let branch: String?
            let isWorktree: Bool
            let isMerged: Bool
            let memoryBadge: String?
            let accountLabel: String?
            let components: [Component]?
            let neededDetailWidth: Double?
            /// The row height at each of `widths`, in order.
            let heights: [Int]
        }
        let constants: Constants
        let widths: [String: Int]
        let models: [Model]
    }

    /// The fixture rows the sidebar draws, and the catalog's and a few more that put every part of
    /// the detail line on it.
    static func rowModels() throws -> [(String, SidebarSessionRowModel)] {
        var out: [(String, SidebarSessionRowModel)] = []
        for n in 0..<CatalogFixtures.state.sessions.count {
            out.append((String(format: "fixture.%02d", n), try CatalogFixtures.row(n)))
        }
        out.append(("catalog.plainRow", CatalogFixtures.plainRow))
        out.append(("catalog.wrappingRow", CatalogFixtures.wrappingRow))
        out.append(("merged", SidebarSessionRowModel(
            title: "Ship the CSV importer", branch: "feat/csv-import", directory: "importer",
            isWorktree: true, isMerged: true)))
        out.append(("memory", SidebarSessionRowModel(
            title: "Profile the indexer", branch: "perf/indexer", directory: "indexer", memoryBadge: "6.2 GB")))
        out.append(("account", SidebarSessionRowModel(
            title: "Nightly report", branch: "main", directory: "reports", accountLabel: "ALT")))
        out.append(("longDirectory", SidebarSessionRowModel(
            title: "Tidy up", branch: "main", directory: "northwind-trading-platform-services")))
        out.append(("everything", SidebarSessionRowModel(
            title: "Rewrite the pricing engine", branch: "feat/pricing-engine-v2", directory: "pricing",
            isWorktree: true, isMerged: true, accountLabel: "ALT", memoryBadge: "12 GB")))
        return out
    }

    static func sessionRow() throws -> SessionRowSection {
        let detailFont = Theme.Fonts.font(detailRole)
        let badgeFont = Theme.Fonts.font(badgeRole)
        let titleFont = Theme.Fonts.font(titleRole)
        let padding = SidebarBadgeLayer.horizontalPadding * 2

        func text(_ part: String, _ string: String, gap: CGFloat) -> SessionRowSection.Component {
            let measured = width(string, font: detailFont)
            return .init(part: part, text: string, font: key(detailRole), measured: r(measured),
                         width: Double(gap + SidebarLayers.width(of: string, font: detailFont) + textPad))
        }
        func badge(_ part: String, _ string: String) -> SessionRowSection.Component {
            let measured = width(string, font: badgeFont)
            return .init(part: part, text: string, font: key(badgeRole), measured: r(measured),
                         width: Double(badgeGap + SidebarBadgeLayer.width(for: string, font: badgeFont)))
        }

        var models: [SessionRowSection.Model] = []
        for (name, model) in try rowModels() {
            var components: [SessionRowSection.Component]?
            let needed = SessionRowView.neededDetailWidth(for: model)
            if let directory = model.directory, !directory.isEmpty, let branch = model.branch, !branch.isEmpty {
                var parts: [SessionRowSection.Component] = [
                    .init(part: "textLeft", text: nil, font: nil, measured: nil, width: Double(textLeft)),
                    text("directory", "\u{2026}/\(directory)", gap: 0),
                    text("separator", "\u{00B7}", gap: badgeGap),
                    text("branch", "\u{2387} \(branch)", gap: badgeGap),
                ]
                if model.isWorktree { parts.append(badge("worktree", "WT")) }
                if model.isMerged { parts.append(text("merged", SessionRowView.mergedText, gap: badgeGap)) }
                if let size = model.memoryBadge, !size.isEmpty { parts.append(badge("memory", size)) }
                if let label = model.accountLabel, !label.isEmpty { parts.append(badge("account", label)) }
                parts.append(.init(part: "rightInset", text: nil, font: nil, measured: nil, width: Double(rightInset)))
                // Every part is a whole or half point, so the sum is exact in any order.
                let sum = parts.reduce(0) { $0 + $1.width }
                guard let needed, Double(needed) == sum else {
                    throw Failure(description: "\(name): the components add up to \(sum), SessionRowView says \(String(describing: needed))")
                }
                components = parts
            } else if needed != nil {
                throw Failure(description: "\(name): SessionRowView measures a detail line the dump does not expect")
            }
            let heights = rowWidths.map { Int(SessionRowView.height(for: model, width: CGFloat($0))) }
            models.append(.init(
                name: name, title: model.title, titleWidth: r(width(model.title, font: titleFont)),
                directory: model.directory, branch: model.branch, isWorktree: model.isWorktree, isMerged: model.isMerged,
                memoryBadge: model.memoryBadge, accountLabel: model.accountLabel,
                components: components, neededDetailWidth: needed.map { Double($0) }, heights: heights))
        }
        return SessionRowSection(
            constants: .init(
                textLeft: Double(textLeft), badgeGap: Double(badgeGap), rightInset: Double(rightInset),
                textPad: Double(textPad), badgePadding: Double(padding),
                detailFont: key(detailRole), badgeFont: key(badgeRole), titleFont: key(titleRole),
                rowHeight: SidebarMetrics.sessionRowHeight, wrappedRowHeight: SidebarMetrics.sessionRowWrappedHeight,
                rule: "a text part adds gap + ceil(measured) + textPad, a badge gap + ceil(measured) + badgePadding; the row is wrappedRowHeight when neededDetailWidth > width"),
            widths: ["from": rowWidths.first!, "to": rowWidths.last!, "step": 1],
            models: models)
    }

    // MARK: The status bar

    /// `StatusBarView`'s private constants that decide visibility, recorded for the reader. The
    /// grid is what the view decided; `statusBar()` checks the inset and the truncation floor
    /// against it.
    static let insetX: CGFloat = 15
    static let minTruncatedWidth: CGFloat = 30
    static let barWidths = Array(stride(from: 100, through: 1_300, by: 10))
    /// Wide enough for every strip to fit whole.
    static let wideWidth: CGFloat = 4_000

    struct StatusBarSection: Encodable {
        struct Constants: Encodable {
            let insetX, minTruncatedWidth, fitSlack: Double
            let separator: String
            let textFont, pillFont: String
            /// The ` · ` between two groups and the single space between two ports, in the text font.
            let dotWidth, spaceWidth: Double
            let rule: String
        }
        struct Item: Encodable {
            let kind: String
            let text: String
            let trailing: Bool
            let separated: Bool
            let width: Double
            /// A meter's label and numbers, a pill's tracking.
            let label: String?
            let value: String?
            let tracking: Double?
        }
        struct Strip: Encodable {
            let name: String
            let items: [Item]
        }
        struct Decision: Encodable {
            let strip: String
            let width: Int
            /// Indices into the strip's items, in placement order.
            let placed: [Int]
            /// The trailing group sits flush right, the rest flows from the left.
            let split: Bool
            /// Item index → the width it was truncated into.
            let truncated: [String: Double]?
        }
        let constants: Constants
        let widths: [String: Int]
        let strips: [Strip]
        let grid: [Decision]
    }

    static let strips: [(String, StatusBarModel)] = [
        ("full", ComponentCatalog.fullStrip),
        ("hot", ComponentCatalog.hotStrip),
        ("live", ComponentCatalog.liveStrip),
        ("git", ComponentCatalog.gitStrip),
        ("rebasing", ComponentCatalog.rebasingStrip),
        ("draft", ComponentCatalog.draftStrip),
        ("notice", ComponentCatalog.noticeStrip),
    ]

    static func placement(_ model: StatusBarModel, width: CGFloat) -> [StatusBarView.PlacedItem] {
        let view = StatusBarView(theme: .default, model: model)
        view.frame = NSRect(x: 0, y: 0, width: width, height: StatusBarView.height)
        return view.placement()
    }

    /// Indices into `items` for what was placed: the leading items and then the trailing ones when
    /// the line split, the items in order otherwise. A leading item left out is always followed by
    /// leading items left out, so a forward walk finds each one.
    static func indices(_ placed: [StatusBarView.PlacedItem], of items: [StatusItem], split: Bool) throws -> [Int] {
        let order = split
            ? items.indices.filter { !items[$0].trailing } + items.indices.filter { items[$0].trailing }
            : Array(items.indices)
        var cursor = 0
        var out: [Int] = []
        for item in placed {
            while cursor < order.count, items[order[cursor]] != item.item { cursor += 1 }
            guard cursor < order.count else { throw Failure(description: "a placed item is not in the strip") }
            out.append(order[cursor])
            cursor += 1
        }
        return out
    }

    static func statusBar() throws -> StatusBarSection {
        let theme = Theme.default
        let textRole = Role.mono("Theme.Fonts.mono.statusBar", theme.fontMono.statusBar)
        let pillRole = DesignTokens.Typography.statusPill
        let textFont = Theme.Fonts.font(textRole)
        let dotWidth = width(" \u{00B7} ", font: textFont)
        let spaceWidth = width(" ", font: textFont)

        var strips: [StatusBarSection.Strip] = []
        var grid: [StatusBarSection.Decision] = []
        for (name, model) in Self.strips {
            let items = StatusBarView.items(for: model, theme: theme)
            // Everything fits: each item's frame is its width.
            let wide = placement(model, width: wideWidth)
            guard wide.count == items.count else { throw Failure(description: "\(name): \(wideWidth) pt does not fit the strip") }
            let wideIndices = try indices(wide, of: items, split: wide.contains { $0.separatorX == nil && $0.frame.minX != insetX })
            var widths = [CGFloat](repeating: 0, count: items.count)
            for (placed, index) in zip(wide, wideIndices) {
                widths[index] = placed.frame.width
                if let separatorX = placed.separatorX {
                    let expected = placed.separatorIsDot ? dotWidth : spaceWidth
                    guard abs(placed.frame.minX - separatorX - expected) < 0.0001 else {
                        throw Failure(description: "\(name): a separator is \(placed.frame.minX - separatorX) pt, not \(expected)")
                    }
                }
            }
            strips.append(.init(name: name, items: items.enumerated().map { index, item -> StatusBarSection.Item in
                var label: String?, value: String?, tracking: Double?
                let kind: String
                switch item.segment {
                case .runs: kind = "runs"
                case .pill(_, _, _, _, let t): kind = "pill"; tracking = t
                case .meter(let l, _, let v): kind = "meter"; label = l.text; value = v.map(\.text).joined()
                case .iconRuns: kind = "iconRuns"
                }
                return StatusBarSection.Item(kind: kind, text: item.segment.plainText, trailing: item.trailing, separated: item.separated,
                             width: r(widths[index]), label: label, value: value, tracking: tracking)
            }))

            for barWidth in barWidths {
                let placed = placement(model, width: CGFloat(barWidth))
                if let first = placed.first, first.separatorX == nil, first.frame.minX < insetX {
                    throw Failure(description: "\(name) @ \(barWidth): the first item starts at \(first.frame.minX)")
                }
                // Split: a trailing group's first item has no separator and does not start the line.
                let split = placed.enumerated().contains { position, item in
                    item.separatorX == nil && (position > 0 || item.frame.minX != insetX)
                }
                let placedIndices = try indices(placed, of: items, split: split)
                var truncated: [String: Double] = [:]
                for (item, index) in zip(placed, placedIndices) {
                    guard let room = item.truncatedWidth else { continue }
                    guard room >= minTruncatedWidth else {
                        throw Failure(description: "\(name) @ \(barWidth): truncated into \(room) pt, under \(minTruncatedWidth)")
                    }
                    truncated[String(index)] = r(room)
                }
                grid.append(.init(strip: name, width: barWidth, placed: placedIndices, split: split,
                                  truncated: truncated.isEmpty ? nil : truncated))
            }
        }
        return StatusBarSection(
            constants: .init(
                insetX: Double(insetX), minTruncatedWidth: Double(minTruncatedWidth), fitSlack: 0.01,
                separator: " \u{00B7} ", textFont: key(textRole), pillFont: key(pillRole),
                dotWidth: r(dotWidth), spaceWidth: r(spaceWidth),
                rule: "items flow from insetX, a separator before every item but the first; an item fits when width <= room + fitSlack; the first that does not is truncated into the room left if it is a runs item and that room is at least minTruncatedWidth, and nothing after it is drawn. When the trailing group fits whole one separator right of the leading group's start, it sits flush right and the leading group flows into what is left"),
            widths: ["from": barWidths.first!, "to": barWidths.last!, "step": 10],
            strips: strips, grid: grid)
    }

    // MARK: Writing

    /// The whole dump: compact, key-sorted JSON with one record per line in the long arrays, so a
    /// changed font or model is a one-line diff, and a trailing newline.
    static func render() throws -> Data {
        let fonts = try measureFonts()
        let row = try sessionRow()
        let bar = try statusBar()
        let document: CompactJSON.Node = .object([
            "schema": .value(schema),
            "platform": .value("macos"),
            "about": .value("The Mac chrome's text metrics (WOR-312 S2), written by ChromeMetricsDumpTests (TkzAppTests) through scripts/parity-chrome-references.sh on the reference runner (ADR-0003 section 5), and read by Tests/TkzFontsFTTests. Points throughout."),
            "reference": .value(ComponentHostInfo.current()),
            "corpus": .value(["ascii": ascii, "corpus": corpus, "symbols": try symbols()]),
            "entries": .lines(fonts.entries),
            "fonts": .lines(fonts.fonts),
            "advances": .lines(fonts.advances),
            "sessionRow": .object([
                "constants": .value(row.constants),
                "widths": .value(row.widths),
                "models": .lines(row.models),
            ]),
            "statusBar": .object([
                "constants": .value(bar.constants),
                "widths": .value(bar.widths),
                "strips": .lines(bar.strips),
                "grid": .lines(bar.grid),
            ]),
        ])
        return try CompactJSON.render(document) + Data("\n".utf8)
    }
}

/// Key-sorted compact JSON whose long arrays put one element on each line.
enum CompactJSON {
    indirect enum Node {
        case value(any Encodable)
        case lines([any Encodable])
        case object([String: Node])
    }

    static func render(_ node: Node) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func encode(_ value: any Encodable) throws -> Data { try encoder.encode(value) }
        switch node {
        case .value(let value):
            return try encode(value)
        case .lines(let elements):
            guard !elements.isEmpty else { return Data("[]".utf8) }
            var out = Data("[".utf8)
            for (index, element) in elements.enumerated() {
                out += Data((index == 0 ? "\n" : ",\n").utf8)
                out += try encode(element)
            }
            return out + Data("\n]".utf8)
        case .object(let members):
            var out = Data("{".utf8)
            for (index, name) in members.keys.sorted().enumerated() {
                if index > 0 { out += Data(",".utf8) }
                out += try encode(name) + Data(":".utf8) + render(members[name]!)
            }
            return out + Data("}".utf8)
        }
    }
}
