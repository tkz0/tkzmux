// TypographyLineMetricsFile — the generated `Sources/TkzCore/DesignTokens+LineMetrics.swift`
// (WOR-307 S4): where it lives, and its exact text for a set of measurements.
//
// Foundation and TkzCore only, like ComponentGoldens: the text it renders for no measurements is
// the committed stub, byte for byte, and that is checkable without AppKit. The measuring is in
// `ComponentSnapshotTypographyTests.swift`.

import Foundation
import TkzCore

enum TypographyLineMetricsFile {
    typealias LineMetrics = DesignTokens.Typography.LineMetrics

    /// This file's path, captured here: a `#filePath` default argument would be the caller's.
    static let sourceFile: String = #filePath

    /// `Sources/TkzCore/DesignTokens+LineMetrics.swift`, from `Tests/TkzAppTests/` up to the repo.
    static func url(file: String = TypographyLineMetricsFile.sourceFile) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()      // Tests/TkzAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <repo>
            .appendingPathComponent("Sources/TkzCore/DesignTokens+LineMetrics.swift")
    }

    /// The file's text: `measurements` in the order given (the order of `roles`), each Double
    /// written as Swift prints it, which reads back to the same bits.
    static func render(_ measurements: [(name: String, metrics: LineMetrics)], measuredOn build: String) -> String {
        var lines = [
            "// TkzCore — the typography roles' line metrics as the Mac measures them (WOR-307 S4).",
            "//",
            "// GENERATED on the reference runner by `ComponentSnapshotTypographyTests` (TkzAppTests) with",
            "// `TKZMUX_UPDATE_SNAPSHOTS=1`, in the same run that regenerates the component goldens",
            "// (docs/linux/parity.md, \"Updating the goldens\"). Do not edit by hand. Empty until then.",
            "",
            "import Foundation",
            "",
            "extension DesignTokens.Typography {",
            "    /// The macOS build (`sysctl kern.osversion`) `measured` was taken on; empty until generated.",
            "    public static let measuredOn = \"\(build)\"",
            "",
            "    /// Role name → its metrics, for every role in `roles`.",
        ]
        if measurements.isEmpty {
            lines.append("    public static let measured: [String: LineMetrics] = [:]")
        } else {
            lines.append("    public static let measured: [String: LineMetrics] = [")
            for (name, m) in measurements {
                lines.append("        \"\(name)\": LineMetrics(")
                lines.append("            fontName: \"\(m.fontName)\", ascender: \(m.ascender), descender: \(m.descender),")
                lines.append("            leading: \(m.leading), lineHeight: \(m.lineHeight), baseline: \(m.baseline)),")
            }
            lines.append("    ]")
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The `measuredOn` build recorded in `text`, or nil if there is none.
    static func measuredOn(in text: String) -> String? {
        guard let start = text.range(of: "public static let measuredOn = \""),
              let end = text[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(text[start.upperBound..<end])
    }

    /// The differences between two measurements of one role beyond `tolerance` points (font names
    /// must match exactly). Used off the reference build, where CoreText drifts.
    static func differences(_ name: String, golden: LineMetrics, actual: LineMetrics, tolerance: Double) -> [String] {
        var out: [String] = []
        if golden.fontName != actual.fontName { out.append("\(name).fontName: \(golden.fontName) → \(actual.fontName)") }
        for (field, a, b) in [
            ("ascender", golden.ascender, actual.ascender), ("descender", golden.descender, actual.descender),
            ("leading", golden.leading, actual.leading), ("lineHeight", golden.lineHeight, actual.lineHeight),
            ("baseline", golden.baseline, actual.baseline),
        ] where abs(a - b) > tolerance {
            out.append("\(name).\(field): \(a) → \(b)")
        }
        return out
    }
}
