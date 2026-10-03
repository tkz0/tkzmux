// TkzCore — the inline Auto Layout constants (WOR-307 S5).
//
// Every `constant:` and `equalToConstant:` literal TkzApp passed to an anchor, one token per role in
// its component. The Mac sites read them as `CGFloat(LayoutTokens.<Component>.<name>.value)`, where
// `LayoutTokens` is a file-private alias for `DesignTokens.Metrics`; a trailing or bottom constant
// keeps its sign at the site (`-CGFloat(…)`), so every value here is the literal's magnitude. Two
// zero placeholders stay literal under `// token-exempt:` (the tab strip's starting height and the
// merged-worktrees list's, both set before they are shown).
//
// Values are the Mac's literals, moved verbatim; `LayoutTokensTests` pins each one and checks every
// site against the line it replaced. Lines drawn as 1 pt views (borders, dividers, separators) are
// `.stroke`, dots and icon boxes `.mark`, everything else `.points` (ADR-0003 §2).

import Foundation

extension DesignTokens.Metrics {
    /// The header strip behind the toolbar items (`HeaderBackdropView`).
    public enum HeaderBackdrop {
        /// The design's 1 pt bottom border.
        public static let bottomBorder = DesignToken("Metrics.HeaderBackdrop.bottomBorder", 1, .stroke)
    }

    /// The ⌘I activity feed panel (`ActivityFeedController`).
    public enum ActivityFeed {
        /// The search field's top, leading and trailing inset in the panel.
        public static let fieldInset = DesignToken("Metrics.ActivityFeed.fieldInset", 14, .points)
        /// From the field's bottom to the list's top.
        public static let fieldToList = DesignToken("Metrics.ActivityFeed.fieldToList", 10, .points)
        /// The list's leading and trailing inset in the panel.
        public static let listInset = DesignToken("Metrics.ActivityFeed.listInset", 6, .points)
    }

    /// The activity feed's rows, kind pill and footer (`ActivityRowViews.swift`).
    public enum ActivityRow {
        /// The kind pill's label inset, leading and trailing.
        public static let pillPaddingX = DesignToken("Metrics.ActivityRow.pillPaddingX", 4.5, .points)
        /// The kind pill's label inset, top and bottom.
        public static let pillPaddingY = DesignToken("Metrics.ActivityRow.pillPaddingY", 1, .points)
        /// Every row's leading and trailing content inset (a folded row's leading is `foldedIndent`),
        /// and the footer hint's leading inset.
        public static let insetX = DesignToken("Metrics.ActivityRow.insetX", 12, .points)
        /// The gap between neighbouring items in a row (dot, title, group, meta, pill, preview).
        public static let gap = DesignToken("Metrics.ActivityRow.gap", 9, .points)
        /// The working row's status dot box.
        public static let dotSize = DesignToken("Metrics.ActivityRow.dotSize", 10, .mark)
        /// A thread row's title, from the row's top.
        public static let threadTop = DesignToken("Metrics.ActivityRow.threadTop", 6, .points)
        /// From a thread row's title to its preview.
        public static let previewGap = DesignToken("Metrics.ActivityRow.previewGap", 3, .points)
        /// The least room under a thread row's preview.
        public static let previewBottomInset = DesignToken("Metrics.ActivityRow.previewBottomInset", 4, .points)
        /// The `+N older` button's trailing inset.
        public static let olderTrailingInset = DesignToken("Metrics.ActivityRow.olderTrailingInset", 10, .points)
        /// The `+N older` button's bottom inset.
        public static let olderBottomInset = DesignToken("Metrics.ActivityRow.olderBottomInset", 5, .points)
        /// A folded row's pill, from the row's leading edge.
        public static let foldedIndent = DesignToken("Metrics.ActivityRow.foldedIndent", 28, .points)
    }

    /// The palette panel, both ⇧⌘P and ⌘F (`CommandPaletteController`).
    public enum Palette {
        /// The field's top, leading and trailing inset in the panel.
        public static let fieldInset = DesignToken("Metrics.Palette.fieldInset", 14, .points)
        /// From the field's bottom to the list's top, with no chip bar.
        public static let fieldToList = DesignToken("Metrics.Palette.fieldToList", 10, .points)
        /// From the field's bottom to the chip bar's top (⌘F).
        public static let fieldToChips = DesignToken("Metrics.Palette.fieldToChips", 8, .points)
        /// From the chip bar's bottom to the list's top (⌘F).
        public static let chipsToList = DesignToken("Metrics.Palette.chipsToList", 2, .points)
        /// The list's leading and trailing inset in the panel.
        public static let listInset = DesignToken("Metrics.Palette.listInset", 6, .points)
        /// The list's bottom inset when there is no footer (⇧⌘P).
        public static let listBottomInset = DesignToken("Metrics.Palette.listBottomInset", 8, .points)
        /// The least trailing room beside a section header or `Show N more…` label.
        public static let labelTrailingInset = DesignToken("Metrics.Palette.labelTrailingInset", 8, .points)
    }

    /// One ⇧⌘P hit (`PaletteRowView`).
    public enum PaletteRow {
        /// The title's leading inset and the trailing hint's trailing inset.
        public static let insetX = DesignToken("Metrics.PaletteRow.insetX", 12, .points)
        /// The title, from the row's top.
        public static let titleTop = DesignToken("Metrics.PaletteRow.titleTop", 4, .points)
        /// From the title's bottom to the subtitle's top.
        public static let subtitleGap = DesignToken("Metrics.PaletteRow.subtitleGap", 2, .points)
        /// The least gap between the title or subtitle and the trailing hint.
        public static let trailingGap = DesignToken("Metrics.PaletteRow.trailingGap", 8, .points)
    }

    /// The ⌘F search rows, chip bar and footer (`SearchRowViews.swift`).
    public enum SearchRow {
        /// Every row's trailing inset, the chip bar's leading and trailing inset, the footer's leading
        /// inset.
        public static let insetX = DesignToken("Metrics.SearchRow.insetX", 12, .points)
        /// The gap between neighbouring items in a row.
        public static let gap = DesignToken("Metrics.SearchRow.gap", 9, .points)
        /// The fixed session column of the transcript and file rows (2c.6), so excerpts line up.
        public static let sessionColumnWidth = DesignToken("Metrics.SearchRow.sessionColumnWidth", 150, .points)
        /// The least gap between the chips and the `in:` filter label.
        public static let chipBarMinGap = DesignToken("Metrics.SearchRow.chipBarMinGap", 8, .points)
    }

    /// A file tab's read-only viewer header (`FileViewerView`).
    public enum FileViewer {
        /// The path's leading inset and the read-only label's trailing inset.
        public static let headerInsetX = DesignToken("Metrics.FileViewer.headerInsetX", 12, .points)
        /// The least gap between the path and the read-only label.
        public static let headerGap = DesignToken("Metrics.FileViewer.headerGap", 12, .points)
        /// The header's 1 pt bottom border.
        public static let headerBorder = DesignToken("Metrics.FileViewer.headerBorder", 1, .stroke)
    }

    /// `RebaseSheetView`'s own spacing. The rest is the glass sheet family's.
    public enum RebaseSheet {
        /// The least gap between the title and the shortcut hint.
        public static let titleShortcutGap = DesignToken("Metrics.RebaseSheet.titleShortcutGap", 10, .points)
        /// From the title's bottom to the body's top.
        public static let titleToBody = DesignToken("Metrics.RebaseSheet.titleToBody", 6, .points)
        /// From the body's bottom to the buttons' top.
        public static let bodyToButtons = DesignToken("Metrics.RebaseSheet.bodyToButtons", 14, .points)
    }

    /// `DeleteWorktreeSheetView`'s own spacing.
    public enum DeleteWorktreeSheet {
        /// From the title's bottom to the body's top.
        public static let titleToBody = DesignToken("Metrics.DeleteWorktreeSheet.titleToBody", 7, .points)
        /// From the body's bottom to the buttons' top.
        public static let bodyToButtons = DesignToken("Metrics.DeleteWorktreeSheet.bodyToButtons", 14, .points)
    }
}

extension DesignTokens.Metrics.GlassSheet {
    /// The gap between neighbouring buttons in a glass sheet's button row (all three sheets).
    public static let buttonSpacing = DesignToken("Metrics.GlassSheet.buttonSpacing", 8, .points)
}

extension DesignTokens.Metrics.DeleteMergedSheet {
    /// From the title's bottom to the body's top.
    public static let titleToBody = DesignToken("Metrics.DeleteMergedSheet.titleToBody", 6, .points)
    /// From the body's bottom to the list's top.
    public static let bodyToList = DesignToken("Metrics.DeleteMergedSheet.bodyToList", 10, .points)
    /// From the list's bottom to the buttons' top.
    public static let listToButtons = DesignToken("Metrics.DeleteMergedSheet.listToButtons", 12, .points)
}

extension DesignTokens.Metrics.PromptCard {
    /// From a pill (PROMPT, RECAP) to its meta line.
    public static let pillMetaGap = DesignToken("Metrics.PromptCard.pillMetaGap", 8, .points)
    /// The least gap between the prompt's meta line and the close hint.
    public static let metaHintGap = DesignToken("Metrics.PromptCard.metaHintGap", 8, .points)
    /// From the prompt text's bottom to the divider.
    public static let dividerGap = DesignToken("Metrics.PromptCard.dividerGap", 14, .points)
    /// The divider between the prompt and the recap, a 1 pt rule.
    public static let dividerThickness = DesignToken("Metrics.PromptCard.dividerThickness", 1, .stroke)
    /// From the RECAP pill's bottom to the recap text.
    public static let recapTextGap = DesignToken("Metrics.PromptCard.recapTextGap", 6, .points)
    /// From the recap text's bottom to the copy buttons.
    public static let recapToButtons = DesignToken("Metrics.PromptCard.recapToButtons", 14, .points)
    /// The gap between the two copy buttons.
    public static let buttonSpacing = DesignToken("Metrics.PromptCard.buttonSpacing", 8, .points)
}

extension DesignTokens.Metrics.Changes {
    /// The header bar's leading and trailing inset (`ChangesHeaderBar`).
    public static let headerInsetX = DesignToken("Metrics.Changes.headerInsetX", 14, .points)
    /// The least gap between the header's leading and trailing groups.
    public static let headerMinGap = DesignToken("Metrics.Changes.headerMinGap", 12, .points)
    /// The fixed width of the header's `view only` label.
    public static let viewOnlyWidth = DesignToken("Metrics.Changes.viewOnlyWidth", 62, .points)
    /// The header's 1 pt bottom border.
    public static let headerBorder = DesignToken("Metrics.Changes.headerBorder", 1, .stroke)
}

extension DesignTokens.Metrics.Settings {
    /// The 1 pt rule between the nav column and the content.
    public static let navBorder = DesignToken("Metrics.Settings.navBorder", 1, .stroke)
    /// The nav stack, below the safe-area top (the title bar).
    public static let navTop = DesignToken("Metrics.Settings.navTop", 12, .points)
    /// The shortcut hint, from the window content's top.
    public static let shortcutTop = DesignToken("Metrics.Settings.shortcutTop", 8, .points)
    /// The shortcut hint's trailing inset.
    public static let shortcutTrailing = DesignToken("Metrics.Settings.shortcutTrailing", 14, .points)
    /// A nav row's glyph leading inset and title trailing inset (`NavRowView`).
    public static let navRowInsetX = DesignToken("Metrics.Settings.navRowInsetX", 10, .points)
    /// A nav row's glyph box width.
    public static let navGlyphWidth = DesignToken("Metrics.Settings.navGlyphWidth", 16, .mark)
    /// From a nav row's glyph to its title.
    public static let navGlyphGap = DesignToken("Metrics.Settings.navGlyphGap", 9, .points)
    /// The 1 pt separator between the rows of a card (`SectionView`).
    public static let rowSeparator = DesignToken("Metrics.Settings.rowSeparator", 1, .stroke)
    /// A section caption's leading indent over its card.
    public static let captionIndent = DesignToken("Metrics.Settings.captionIndent", 2, .points)
    /// From a section caption's bottom to its card.
    public static let captionGap = DesignToken("Metrics.Settings.captionGap", 7, .points)
    /// From a row's title to its detail line (`RowView`).
    public static let rowDetailGap = DesignToken("Metrics.Settings.rowDetailGap", 2, .points)
    /// The status chip's dot (`StatusChipView`).
    public static let statusDot = DesignToken("Metrics.Settings.statusDot", 7, .mark)
    /// From the status chip's dot to its label.
    public static let statusDotGap = DesignToken("Metrics.Settings.statusDotGap", 6, .points)
}

extension DesignTokens.Metrics {
    /// Every S5 token, in declaration order. Part of `Metrics.all`.
    static let layout: [DesignToken] = [
        HeaderBackdrop.bottomBorder,
        ActivityFeed.fieldInset, ActivityFeed.fieldToList, ActivityFeed.listInset,
        ActivityRow.pillPaddingX, ActivityRow.pillPaddingY, ActivityRow.insetX, ActivityRow.gap,
        ActivityRow.dotSize, ActivityRow.threadTop, ActivityRow.previewGap, ActivityRow.previewBottomInset,
        ActivityRow.olderTrailingInset, ActivityRow.olderBottomInset, ActivityRow.foldedIndent,
        Palette.fieldInset, Palette.fieldToList, Palette.fieldToChips, Palette.chipsToList, Palette.listInset,
        Palette.listBottomInset, Palette.labelTrailingInset,
        PaletteRow.insetX, PaletteRow.titleTop, PaletteRow.subtitleGap, PaletteRow.trailingGap,
        SearchRow.insetX, SearchRow.gap, SearchRow.sessionColumnWidth, SearchRow.chipBarMinGap,
        FileViewer.headerInsetX, FileViewer.headerGap, FileViewer.headerBorder,
        RebaseSheet.titleShortcutGap, RebaseSheet.titleToBody, RebaseSheet.bodyToButtons,
        DeleteWorktreeSheet.titleToBody, DeleteWorktreeSheet.bodyToButtons,
        GlassSheet.buttonSpacing,
        DeleteMergedSheet.titleToBody, DeleteMergedSheet.bodyToList, DeleteMergedSheet.listToButtons,
        PromptCard.pillMetaGap, PromptCard.metaHintGap, PromptCard.dividerGap, PromptCard.dividerThickness,
        PromptCard.recapTextGap, PromptCard.recapToButtons, PromptCard.buttonSpacing,
        Changes.headerInsetX, Changes.headerMinGap, Changes.viewOnlyWidth, Changes.headerBorder,
        Settings.navBorder, Settings.navTop, Settings.shortcutTop, Settings.shortcutTrailing,
        Settings.navRowInsetX, Settings.navGlyphWidth, Settings.navGlyphGap, Settings.rowSeparator,
        Settings.captionIndent, Settings.captionGap, Settings.rowDetailGap, Settings.statusDot,
        Settings.statusDotGap,
    ]
}
