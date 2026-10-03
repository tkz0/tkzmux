// ComponentSnapshotTypographyTests — WOR-307 S4, the Mac half of `TypographyTokensTests`
// (TkzCoreTests). Named into the `ComponentSnapshot` filter so the golden workflow runs it.
//
//   * `rolesResolveToTheFontsTheLiteralCallsMade` builds every role's NSFont through
//     `Theme.Fonts.font(_:)` and compares its face and size with the literal call it replaced, as
//     AppKit resolves both. It also confirms the effective mono face: a mono role is JetBrains Mono
//     Regular, and so is the semibold the status-bar pill asks for.
//   * `lineMetricsMatchTheGeneratedTable` measures every role (ascender, descender, leading,
//     `NSLayoutManager`'s default line height and baseline). With `TKZMUX_UPDATE_SNAPSHOTS=1` it
//     measures twice, refuses a measurement that is not reproducible, and writes
//     `Sources/TkzCore/DesignTokens+LineMetrics.swift`. Otherwise, on the build the table was
//     measured on, the file must be exactly what this run measures; on another build the values
//     must agree within ±0.5 pt and the font names exactly. Skipped while the table is the empty
//     stub.

import AppKit
import Testing
import TkzCore
import TkzTerminalRender

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct ComponentSnapshotTypographyTests {
    typealias T = DesignTokens.Typography
    typealias LineMetrics = DesignTokens.Typography.LineMetrics

    init() {
        _ = NSApplication.shared
        _ = FontSet.registration
    }

    /// Each role next to the call it replaced, copied from the sources before WOR-307 S4.
    static func literalCalls() -> [(DesignTokens.Typography.Role, NSFont)] {
        [
            (T.badge, Theme.Fonts.ui(9, weight: .semibold)),
            (T.badge, NSFont.systemFont(ofSize: 9, weight: .semibold)),
            (T.closeGlyph, Theme.Fonts.ui(13, weight: .medium)),
            (T.groupAdd, Theme.Fonts.ui(12)),
            (T.sidebarHeaderCaption, Theme.Fonts.ui(Theme.Fonts.ui.caption, weight: .semibold)),
            (T.lastMessage, NSFont.systemFont(ofSize: 11)),
            (T.updateTitle, Theme.Fonts.ui(12, weight: .semibold)),
            (T.updateGlyph, Theme.Fonts.ui(12, weight: .semibold)),
            (T.updateClose, Theme.Fonts.ui(11)),
            (T.statusPill, Theme.Fonts.mono(Theme.Fonts.mono.detail, weight: .semibold)),
            (T.changesTitle, Theme.Fonts.ui(12, weight: .semibold)),
            (T.fileViewerText, Theme.Fonts.mono(13)),
            (T.markdownBody, Theme.Fonts.ui(13.5)),
            (T.markdownCode, Theme.Fonts.mono(12.5)),
            (T.markdownHeading1, Theme.Fonts.ui(22, weight: .bold)),
            (T.markdownHeading2, Theme.Fonts.ui(18, weight: .bold)),
            (T.markdownHeading3, Theme.Fonts.ui(15.5, weight: .semibold)),
            (T.markdownHeading4, Theme.Fonts.ui(14, weight: .semibold)),
            (T.sheetTitle, Theme.Fonts.ui(13, weight: .semibold)),
            (T.sheetBody, Theme.Fonts.mono(11.5)),
            (T.sheetPath, Theme.Fonts.mono(11)),
            (T.sheetListStatus, Theme.Fonts.mono(10.5)),
            (T.sheetButton, Theme.Fonts.ui(11.5)),
            (T.sheetButtonPrimary, Theme.Fonts.ui(11.5, weight: .semibold)),
            (T.sheetCheckbox, Theme.Fonts.ui(11.5)),
            (T.shortcutHint, Theme.Fonts.mono(10)),
            (T.promptPill, Theme.Fonts.ui(9, weight: .bold)),
            (T.activityKindPill, Theme.Fonts.ui(9, weight: .semibold)),
            (T.settingsNavTitle, Theme.Fonts.ui(12.5, weight: .regular)),
            (T.settingsNavTitleSelected, Theme.Fonts.ui(12.5, weight: .medium)),
            (T.settingsNavGlyph, Theme.Fonts.ui(12)),
            (T.settingsSectionCaption, Theme.Fonts.ui(11, weight: .semibold)),
            (T.settingsRowTitle, Theme.Fonts.ui(13)),
            (T.settingsRowDetail, Theme.Fonts.ui(11.5)),
            (T.settingsControl, Theme.Fonts.ui(12)),
            (T.settingsStatusChip, Theme.Fonts.mono(11)),
        ]
    }

    @Test func rolesResolveToTheFontsTheLiteralCallsMade() {
        let calls = Self.literalCalls()
        #expect(Set(calls.map(\.0.name)) == Set(T.roles.map(\.name)), "a role has no literal call to compare with")
        for (role, literal) in calls {
            let font = Theme.Fonts.font(role)
            #expect(font.fontName == literal.fontName, "\(role.name): \(font.fontName), was \(literal.fontName)")
            #expect(font.pointSize == literal.pointSize, "\(role.name): \(font.pointSize), was \(literal.pointSize)")
            if let face = role.postScriptName {
                #expect(font.fontName == face, "\(role.name) draws \(font.fontName), not the bundled face")
            }
        }
        // The kerning the Mac applies, as it computes it.
        #expect(StatusBarView.pillTracking == 0.03 * Theme.Fonts.mono.detail)
        #expect(Theme.Fonts.font(T.promptPill).pointSize * CGFloat(T.promptPill.trackingEm) == 9 * 0.06)
    }

    @Test(
        .enabled(
            if: ComponentGoldens.isUpdating || Self.tableIsGenerated,
            "The typography line metrics are not generated yet. Generate them with the goldens on the reference runner: TKZMUX_UPDATE_SNAPSHOTS=1 swift test --no-parallel --filter ComponentSnapshot (docs/linux/parity.md)"))
    func lineMetricsMatchTheGeneratedTable() throws {
        let measured = Self.measureAll()
        let url = TypographyLineMetricsFile.url()
        let build = ComponentHostInfo.macOSBuild
        if ComponentGoldens.isUpdating {
            let again = Self.measureAll()
            try #require(measured.map(\.metrics) == again.map(\.metrics), "line metrics differ between two measurements")
            let text = TypographyLineMetricsFile.render(measured, measuredOn: build)
            let old = try? String(contentsOf: url, encoding: .utf8)
            if old != text {
                try Data(text.utf8).write(to: url)
                print("wrote \(url.path)")
            }
            return
        }

        let committed = try String(contentsOf: url, encoding: .utf8)
        if TypographyLineMetricsFile.measuredOn(in: committed) == build {
            let text = TypographyLineMetricsFile.render(measured, measuredOn: build)
            #expect(text == committed, "the line metrics measured on \(build) differ from \(url.lastPathComponent)")
            return
        }
        // Another build: what this binary was compiled with, within the text-width tolerance.
        #expect(Set(T.measured.keys) == Set(measured.map(\.name)), "the compiled table does not cover the roles")
        for (name, metrics) in measured {
            guard let golden = T.measured[name] else { continue }
            let problems = TypographyLineMetricsFile.differences(
                name, golden: golden, actual: metrics, tolerance: LayoutComparison.textWidthTolerance)
            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        }
    }

    // MARK: Measuring

    /// The committed file is more than the empty stub. Read by the `.enabled` trait, off the main
    /// actor.
    nonisolated static var tableIsGenerated: Bool {
        guard let text = try? String(contentsOf: TypographyLineMetricsFile.url(), encoding: .utf8) else { return false }
        return text != TypographyLineMetricsFile.render([], measuredOn: "")
    }

    static func measureAll() -> [(name: String, metrics: LineMetrics)] {
        T.roles.map { ($0.name, measure($0)) }
    }

    static func measure(_ role: DesignTokens.Typography.Role) -> LineMetrics {
        let font = Theme.Fonts.font(role)
        let layout = NSLayoutManager()
        return LineMetrics(
            fontName: font.fontName,
            ascender: Double(font.ascender),
            descender: Double(font.descender),
            leading: Double(font.leading),
            lineHeight: Double(layout.defaultLineHeight(for: font)),
            baseline: Double(layout.defaultBaselineOffset(for: font)))
    }
}
