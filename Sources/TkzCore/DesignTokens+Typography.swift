// TkzCore — typography roles (WOR-307 S4).
//
// A role is one text style as the Mac draws it: size, effective face and weight, and tracking. It
// replaces the literal-size font calls in TkzApp (`Theme.Fonts.ui(11.5, weight: .semibold)` became
// `Theme.Fonts.font(DesignTokens.Typography.sheetButtonPrimary)`), the `.kern` literals and the
// MarkdownRenderer sizes. The preset-wide sizes (`Theme.Fonts.ui.title`, `.body`, `.caption`, the
// mono `detail` and `statusBar`) stay in `Theme.Fonts`; a role refers to one where the Mac does.
//
// Every value is the Mac's literal, moved verbatim (`TypographyTokensTests` pins each one). Two
// things are recorded as the Mac has them, not as the design intends:
//
//   * **The effective mono face.** `Theme.Fonts.mono(_:weight:)` ignores its weight whenever
//     JetBrains Mono or Menlo resolves, so a mono role is always Regular. The Mac still asks for
//     another weight at five sites (MainToolbarController's cluster glyphs, `StatusBarView.pillFont`,
//     SearchRowViews' status, MarkdownRenderer's bold code); they draw Regular, and so does Linux.
//   * **Line height and baseline as they measure.** `ComponentSnapshotTypographyTests` measures
//     every role on the reference runner and writes `DesignTokens+LineMetrics.swift`; `lineHeight`
//     and `baseline` read that table and are nil until it is generated.
//
// A role's size snaps `.unrounded` (ADR-0003 §2): text snaps at its baseline, not at its size.

import Foundation

extension DesignTokens.Typography {
    /// One text style.
    public struct Role: Hashable, Sendable {
        /// The font family a role resolves to.
        public enum Face: String, CaseIterable, Hashable, Sendable {
            /// The system UI font (SF on the Mac): `Theme.Fonts.ui.family` is nil for every preset.
            case ui
            /// `Theme.Fonts.mono`: JetBrains Mono Regular, bundled.
            case mono
        }

        /// The weights the chrome uses, each the Mac's `NSFont.Weight` constant of the same name.
        public enum Weight: String, CaseIterable, Hashable, Sendable {
            case regular, medium, semibold, bold
        }

        /// The role's path under `DesignTokens`, e.g. `Typography.sheetTitle`.
        public let name: String
        /// Point size.
        public let size: Double
        public let face: Face
        /// The weight drawn. Always `.regular` for a mono role (the header).
        public let weight: Weight
        /// Letter-spacing in points (the Mac's `.kern`), or 0.
        public let tracking: Double
        /// Letter-spacing as a fraction of the size (CSS `em`), or 0. The Mac multiplies it by the
        /// point size where it applies it.
        public let trackingEm: Double

        /// A role in the system UI font.
        public static func ui(
            _ name: String, _ size: Double, _ weight: Weight = .regular,
            tracking: Double = 0, trackingEm: Double = 0
        ) -> Role {
            Role(name: name, size: size, face: .ui, weight: weight, tracking: tracking, trackingEm: trackingEm)
        }

        /// A role in the mono face. No weight: the Mac draws every mono role Regular.
        public static func mono(_ name: String, _ size: Double, tracking: Double = 0, trackingEm: Double = 0) -> Role {
            Role(name: name, size: size, face: .mono, weight: .regular, tracking: tracking, trackingEm: trackingEm)
        }

        /// The size as a token, for the design table.
        public var sizeToken: DesignToken { DesignToken(name + ".size", size, .unrounded) }

        /// The letter-spacing in points at this role's size: `trackingEm × size`, or `tracking`.
        /// The product is the one the Mac computes, in the same order where it is a static
        /// (`StatusBarView.pillTracking`).
        public var kern: Double { trackingEm != 0 ? trackingEm * size : tracking }

        /// The PostScript name the face resolves to when it is fixed by the bundle (mono); nil for the
        /// system font, whose name the measured `lineMetrics` records.
        public var postScriptName: String? {
            face == .mono ? Theme.Fonts.mono.postScriptName : nil
        }

        /// As measured on the reference runner; nil until `DesignTokens+LineMetrics.swift` is
        /// generated.
        public var lineMetrics: LineMetrics? { DesignTokens.Typography.measured[name] }
        /// The default line height of one line in this role (`NSLayoutManager.defaultLineHeight`).
        public var lineHeight: Double? { lineMetrics?.lineHeight }
        /// From the top of that line to the baseline (`NSLayoutManager.defaultBaselineOffset`).
        public var baseline: Double? { lineMetrics?.baseline }
    }

    /// A role's font metrics as AppKit reports them, in points. Generated, never typed in.
    public struct LineMetrics: Hashable, Sendable {
        /// The PostScript name of the font actually used, fallbacks included.
        public let fontName: String
        /// `NSFont.ascender`, `.descender` (negative), `.leading`: what CoreText lines (CATextLayer,
        /// `draw(with:)`) are built from.
        public let ascender: Double
        public let descender: Double
        public let leading: Double
        /// `NSLayoutManager.defaultLineHeight(for:)`: what an `NSTextField` line takes.
        public let lineHeight: Double
        /// `NSLayoutManager.defaultBaselineOffset(for:)`.
        public let baseline: Double

        public init(
            fontName: String, ascender: Double, descender: Double, leading: Double,
            lineHeight: Double, baseline: Double
        ) {
            self.fontName = fontName
            self.ascender = ascender
            self.descender = descender
            self.leading = leading
            self.lineHeight = lineHeight
            self.baseline = baseline
        }
    }

    // MARK: Sidebar, tabs, panes

    /// The uppercase badges (`WT`, `NEEDS YOU`, the spend and account chips) on session rows, tabs
    /// and pane headers, and `SidebarBadgeLayer`'s default.
    public static let badge = Role.ui("Typography.badge", 9, .semibold)
    /// The session row's and the changes viewer's `✕`.
    public static let closeGlyph = Role.ui("Typography.closeGlyph", 13, .medium)
    /// The group row's `+`.
    public static let groupAdd = Role.ui("Typography.groupAdd", 12)
    /// The sidebar header's `SESSIONS` caption: the caption size, letterspaced 0.6 pt.
    public static let sidebarHeaderCaption = Role.ui(
        "Typography.sidebarHeaderCaption", Theme.Fonts.ui.caption, .semibold, tracking: 0.6)
    /// The last-message popover's fallback font, used only if its text view has none.
    public static let lastMessage = Role.ui("Typography.lastMessage", 11)
    /// The update card's title line, its glyph, and its `✕`. 12 / 11 rather than the artboard's
    /// 11 / 10 (`UpdateNoticeView`).
    public static let updateTitle = Role.ui("Typography.updateTitle", 12, .semibold)
    public static let updateGlyph = Role.ui("Typography.updateGlyph", 12, .semibold)
    public static let updateClose = Role.ui("Typography.updateClose", 11)

    // MARK: Status bar

    /// The model pill: the mono detail size, letterspaced 0.03 em (2c.1). The Mac asks for semibold
    /// (`StatusBarView.pillFont`) and draws Regular.
    public static let statusPill = Role.mono("Typography.statusPill", Theme.Fonts.mono.detail, trackingEm: 0.03)

    // MARK: Changes and file viewers

    /// The changes viewer's header title.
    public static let changesTitle = Role.ui("Typography.changesTitle", 12, .semibold)
    /// A plain-text file in the file viewer.
    public static let fileViewerText = Role.mono("Typography.fileViewerText", 13)
    /// Markdown body text (`MarkdownRenderer.bodySize`) and list markers.
    public static let markdownBody = Role.ui("Typography.markdownBody", 13.5)
    /// A Markdown code block (`MarkdownRenderer.codeSize`). Inline code is the surrounding size
    /// less 1 pt.
    public static let markdownCode = Role.mono("Typography.markdownCode", 12.5)
    /// Markdown headings by level (`MarkdownRenderer.headerSize`); levels 1–2 are bold, 3 and
    /// deeper semibold.
    public static let markdownHeading1 = Role.ui("Typography.markdownHeading1", 22, .bold)
    public static let markdownHeading2 = Role.ui("Typography.markdownHeading2", 18, .bold)
    public static let markdownHeading3 = Role.ui("Typography.markdownHeading3", 15.5, .semibold)
    /// Level 4 and deeper.
    public static let markdownHeading4 = Role.ui("Typography.markdownHeading4", 14, .semibold)

    /// The file viewer's plain-text line spacing (`NSParagraphStyle.lineHeightMultiple`).
    public static let fileViewerLineHeightMultiple = DesignToken(
        "Typography.fileViewerLineHeightMultiple", 1.1, .scalar)
    /// Markdown's line spacing outside code blocks, and inside them.
    public static let markdownLineHeightMultiple = DesignToken(
        "Typography.markdownLineHeightMultiple", 1.15, .scalar)
    public static let markdownCodeLineHeightMultiple = DesignToken(
        "Typography.markdownCodeLineHeightMultiple", 1.05, .scalar)
    /// How far each Markdown list or quote level indents (`MarkdownRenderer.indentStep`).
    public static let markdownIndentStep = DesignToken("Typography.markdownIndentStep", 22, .points)

    // MARK: Sheets and cards

    /// The prompt card's prompt and recap text line spacing (`NSParagraphStyle.lineHeightMultiple`).
    public static let promptCardLineHeightMultiple = DesignToken(
        "Typography.promptCardLineHeightMultiple", 1.25, .scalar)

    /// The glass sheets' bold title.
    public static let sheetTitle = Role.ui("Typography.sheetTitle", 13, .semibold)
    /// The glass sheets' mono body, branch, status and dirty lines.
    public static let sheetBody = Role.mono("Typography.sheetBody", 11.5)
    /// The delete-worktree sheet's path line.
    public static let sheetPath = Role.mono("Typography.sheetPath", 11)
    /// The delete-merged sheet's per-worktree status line.
    public static let sheetListStatus = Role.mono("Typography.sheetListStatus", 10.5)
    /// A sheet's secondary button, and its primary (default or destructive) one.
    public static let sheetButton = Role.ui("Typography.sheetButton", 11.5)
    public static let sheetButtonPrimary = Role.ui("Typography.sheetButtonPrimary", 11.5, .semibold)
    /// A sheet's checkbox titles.
    public static let sheetCheckbox = Role.ui("Typography.sheetCheckbox", 11.5)
    /// The `⌘…` shortcut hint in the rebase sheet and the Settings window.
    public static let shortcutHint = Role.mono("Typography.shortcutHint", 10)
    /// The prompt card's `PROMPT` / `RECAP` pills, letterspaced 0.06 em like the artboard.
    public static let promptPill = Role.ui("Typography.promptPill", 9, .bold, trackingEm: 0.06)
    /// The activity feed's kind pill.
    public static let activityKindPill = Role.ui("Typography.activityKindPill", 9, .semibold)

    // MARK: Settings

    /// A Settings nav row's title, unselected and selected.
    public static let settingsNavTitle = Role.ui("Typography.settingsNavTitle", 12.5)
    public static let settingsNavTitleSelected = Role.ui("Typography.settingsNavTitleSelected", 12.5, .medium)
    /// A Settings nav row's glyph.
    public static let settingsNavGlyph = Role.ui("Typography.settingsNavGlyph", 12)
    /// A Settings section's uppercase caption, letterspaced 0.5 pt.
    public static let settingsSectionCaption = Role.ui(
        "Typography.settingsSectionCaption", 11, .semibold, tracking: 0.5)
    /// A Settings row's title and its detail line.
    public static let settingsRowTitle = Role.ui("Typography.settingsRowTitle", 13)
    public static let settingsRowDetail = Role.ui("Typography.settingsRowDetail", 11.5)
    /// A Settings row's pop-up or push button.
    public static let settingsControl = Role.ui("Typography.settingsControl", 12)
    /// The status chip next to a dot (`StatusChipView`).
    public static let settingsStatusChip = Role.mono("Typography.settingsStatusChip", 11)

    /// Every role, in declaration order.
    public static let roles: [Role] = [
        badge, closeGlyph, groupAdd, sidebarHeaderCaption, lastMessage, updateTitle, updateGlyph, updateClose,
        statusPill,
        changesTitle, fileViewerText, markdownBody, markdownCode,
        markdownHeading1, markdownHeading2, markdownHeading3, markdownHeading4,
        sheetTitle, sheetBody, sheetPath, sheetListStatus, sheetButton, sheetButtonPrimary, sheetCheckbox,
        shortcutHint, promptPill, activityKindPill,
        settingsNavTitle, settingsNavTitleSelected, settingsNavGlyph, settingsSectionCaption,
        settingsRowTitle, settingsRowDetail, settingsControl, settingsStatusChip,
    ]

    /// The role at `name`, as `Role.name` spells it.
    public static func role(named name: String) -> Role? {
        roles.first { $0.name == name }
    }

    /// Every typography token that is a single value, in declaration order.
    static let all: [DesignToken] = [
        changesDiffSize, changesFileSize,
        fileViewerLineHeightMultiple, markdownLineHeightMultiple, markdownCodeLineHeightMultiple,
        markdownIndentStep, promptCardLineHeightMultiple,
    ]
}
