// TkzCore — layout metrics (WOR-307 S3).
//
// One nested enum per former `*Metrics` enum, plus the window geometry and the status-bar hairline.
// The doc comment on each token names the constant that forwards to it; the design reasons stay
// with those constants in TkzApp, next to the code they explain.

import Foundation

extension DesignTokens.Metrics {
    /// `SidebarMetrics` (artboard 2c).
    public enum Sidebar {
        /// `SidebarMetrics.groupRowHeight`.
        public static let groupRowHeight = DesignToken("Metrics.Sidebar.groupRowHeight", 28, .points)
        /// `SidebarMetrics.sessionRowHeight`: the single-detail-line row.
        public static let sessionRowHeight = DesignToken("Metrics.Sidebar.sessionRowHeight", 44, .points)
        /// `SidebarMetrics.sessionRowWrappedHeight`: the row whose detail line wrapped to two.
        public static let sessionRowWrappedHeight = DesignToken(
            "Metrics.Sidebar.sessionRowWrappedHeight", 59, .points)
        /// `SidebarMetrics.sidebarHeaderHeight`.
        public static let headerHeight = DesignToken("Metrics.Sidebar.headerHeight", 28, .points)
        /// `SidebarMetrics.updateNoticeHeight`.
        public static let updateNoticeHeight = DesignToken("Metrics.Sidebar.updateNoticeHeight", 48, .points)
        /// `SidebarMetrics.sessionIndent`.
        public static let sessionIndent = DesignToken("Metrics.Sidebar.sessionIndent", 16, .points)
        /// `SidebarMetrics.groupEdgeWidth`: the group colour edge, a 2.5 pt rule.
        public static let groupEdgeWidth = DesignToken("Metrics.Sidebar.groupEdgeWidth", 2.5, .stroke)
    }

    /// `TabStripMetrics`.
    public enum TabStrip {
        /// `TabStripMetrics.stripHeight`.
        public static let stripHeight = DesignToken("Metrics.TabStrip.stripHeight", 28, .points)
        /// `TabStripMetrics.tabMinWidth`.
        public static let tabMinWidth = DesignToken("Metrics.TabStrip.tabMinWidth", 90, .points)
        /// `TabStripMetrics.tabMaxWidth`.
        public static let tabMaxWidth = DesignToken("Metrics.TabStrip.tabMaxWidth", 180, .points)
        /// `TabStripMetrics.tabGap`.
        public static let tabGap = DesignToken("Metrics.TabStrip.tabGap", 1, .points)
        /// `TabStripMetrics.horizontalInset`.
        public static let horizontalInset = DesignToken("Metrics.TabStrip.horizontalInset", 8, .points)
        /// `TabStripMetrics.badgeGap`.
        public static let badgeGap = DesignToken("Metrics.TabStrip.badgeGap", 6, .points)
        /// `TabStripMetrics.closeSize`: the close box, a fixed-size mark.
        public static let closeSize = DesignToken("Metrics.TabStrip.closeSize", 14, .mark)
    }

    /// `SplitMetrics`.
    public enum Split {
        /// `SplitMetrics.dividerThickness`: the 7 pt grip bar.
        public static let dividerThickness = DesignToken("Metrics.Split.dividerThickness", 7, .points)
        /// `SplitMetrics.gripLength`: the grip pill along the divider.
        public static let gripLength = DesignToken("Metrics.Split.gripLength", 44, .mark)
        /// `SplitMetrics.gripThickness`: the grip pill across the divider.
        public static let gripThickness = DesignToken("Metrics.Split.gripThickness", 3, .mark)
        /// `SplitMetrics.minPaneSide`.
        public static let minPaneSide = DesignToken("Metrics.Split.minPaneSide", 120, .points)
        /// `SplitMetrics.ratioEpsilon`: a ratio, not a length.
        public static let ratioEpsilon = DesignToken("Metrics.Split.ratioEpsilon", 0.005, .scalar)
    }

    /// `PaneHeaderMetrics` (design 2c.3 / 2c.4).
    public enum PaneHeader {
        /// `PaneHeaderMetrics.height`.
        public static let height = DesignToken("Metrics.PaneHeader.height", 28, .points)
        /// `PaneHeaderMetrics.insetX`.
        public static let insetX = DesignToken("Metrics.PaneHeader.insetX", 12, .points)
        /// `PaneHeaderMetrics.gap`.
        public static let gap = DesignToken("Metrics.PaneHeader.gap", 8, .points)
        /// `PaneHeaderMetrics.dotDiameter`.
        public static let dotDiameter = DesignToken("Metrics.PaneHeader.dotDiameter", 6, .mark)
        /// `PaneHeaderMetrics.closeSize`.
        public static let closeSize = DesignToken("Metrics.PaneHeader.closeSize", 16, .mark)
        /// `PaneHeaderMetrics.focusRingWidth` (ADR-0003 worked example 2).
        public static let focusRingWidth = DesignToken("Metrics.PaneHeader.focusRingWidth", 1.5, .stroke)
        /// `PaneHeaderMetrics.inactiveContentAlpha`: an alpha, not a length.
        public static let inactiveContentAlpha = DesignToken(
            "Metrics.PaneHeader.inactiveContentAlpha", 0.85, .scalar)
    }

    /// `ChangesMetrics`. Its font sizes are `Typography.changesDiffSize` / `changesFileSize`.
    public enum Changes {
        /// `ChangesMetrics.headerHeight`.
        public static let headerHeight = DesignToken("Metrics.Changes.headerHeight", 38, .points)
        /// `ChangesMetrics.fileListWidth`.
        public static let fileListWidth = DesignToken("Metrics.Changes.fileListWidth", 264, .points)
        /// `ChangesMetrics.fileRowHeight`.
        public static let fileRowHeight = DesignToken("Metrics.Changes.fileRowHeight", 28, .points)
        /// `ChangesMetrics.fileListInset`.
        public static let fileListInset = DesignToken("Metrics.Changes.fileListInset", 6, .points)
        /// `ChangesMetrics.pathHeaderHeight`.
        public static let pathHeaderHeight = DesignToken("Metrics.Changes.pathHeaderHeight", 32, .points)
        /// `ChangesMetrics.diffRowHeight`.
        public static let diffRowHeight = DesignToken("Metrics.Changes.diffRowHeight", 20, .points)
        /// `ChangesMetrics.numberWidth`.
        public static let numberWidth = DesignToken("Metrics.Changes.numberWidth", 44, .points)
        /// `ChangesMetrics.numberGap`.
        public static let numberGap = DesignToken("Metrics.Changes.numberGap", 8, .points)
        /// `ChangesMetrics.textInset`.
        public static let textInset = DesignToken("Metrics.Changes.textInset", 14, .points)
        /// `ChangesMetrics.tabWidth`: a tab is drawn as this many spaces. A count.
        public static let tabWidth = DesignToken("Metrics.Changes.tabWidth", 4, .scalar)
    }

    /// `GlassSheetMetrics`, which the rebase and delete-worktree sheets alias. Its radius is
    /// `Radii.glassSheet`.
    public enum GlassSheet {
        /// `GlassSheetMetrics.width`.
        public static let width = DesignToken("Metrics.GlassSheet.width", 318, .points)
        /// `GlassSheetMetrics.padding`.
        public static let padding = DesignToken("Metrics.GlassSheet.padding", 14, .points)
        /// `GlassSheetMetrics.topPadding`.
        public static let topPadding = DesignToken("Metrics.GlassSheet.topPadding", 13, .points)
        /// `GlassSheetMetrics.bottomPadding`.
        public static let bottomPadding = DesignToken("Metrics.GlassSheet.bottomPadding", 12, .points)
        /// `GlassSheetMetrics.buttonHeight`.
        public static let buttonHeight = DesignToken("Metrics.GlassSheet.buttonHeight", 27, .points)
        /// `GlassSheetMetrics.inset`.
        public static let inset = DesignToken("Metrics.GlassSheet.inset", 14, .points)
    }

    /// `DeleteMergedWorktreesSheetView.Metrics`: the two values it does not alias from the family.
    public enum DeleteMergedSheet {
        /// `DeleteMergedWorktreesSheetView.Metrics.width`.
        public static let width = DesignToken("Metrics.DeleteMergedSheet.width", 380, .points)
        /// `DeleteMergedWorktreesSheetView.Metrics.maxListHeight`.
        public static let maxListHeight = DesignToken("Metrics.DeleteMergedSheet.maxListHeight", 180, .points)
    }

    /// `PromptCardView.Metrics`. Its radius is `Radii.promptCard`.
    public enum PromptCard {
        /// `PromptCardView.Metrics.width`.
        public static let width = DesignToken("Metrics.PromptCard.width", 640, .points)
        /// `PromptCardView.Metrics.padding`.
        public static let padding = DesignToken("Metrics.PromptCard.padding", 20, .points)
        /// `PromptCardView.Metrics.verticalPadding`.
        public static let verticalPadding = DesignToken("Metrics.PromptCard.verticalPadding", 18, .points)
        /// `PromptCardView.Metrics.rowSpacing`.
        public static let rowSpacing = DesignToken("Metrics.PromptCard.rowSpacing", 10, .points)
        /// `PromptCardView.Metrics.defaultMaxTextHeight`.
        public static let defaultMaxTextHeight = DesignToken(
            "Metrics.PromptCard.defaultMaxTextHeight", 220, .points)
        /// `PromptCardView.Metrics.minTextHeight`.
        public static let minTextHeight = DesignToken("Metrics.PromptCard.minTextHeight", 22, .points)
    }

    /// `ThemedSwitch.Metrics`.
    public enum ThemedSwitch {
        /// `ThemedSwitch.Metrics.width`.
        public static let width = DesignToken("Metrics.ThemedSwitch.width", 30, .points)
        /// `ThemedSwitch.Metrics.height`.
        public static let height = DesignToken("Metrics.ThemedSwitch.height", 18, .points)
        /// `ThemedSwitch.Metrics.knob`: the knob's diameter, a fixed-size mark.
        public static let knob = DesignToken("Metrics.ThemedSwitch.knob", 14, .mark)
        /// `ThemedSwitch.Metrics.inset`.
        public static let inset = DesignToken("Metrics.ThemedSwitch.inset", 2, .points)
    }

    /// `SettingsView.Metrics`. Its card radius is `Radii.settingsCard`.
    public enum Settings {
        /// `SettingsView.Metrics.width`.
        public static let width = DesignToken("Metrics.Settings.width", 720, .points)
        /// `SettingsView.Metrics.height`.
        public static let height = DesignToken("Metrics.Settings.height", 600, .points)
        /// `SettingsView.Metrics.navWidth`.
        public static let navWidth = DesignToken("Metrics.Settings.navWidth", 176, .points)
        /// `SettingsView.Metrics.navRowHeight`.
        public static let navRowHeight = DesignToken("Metrics.Settings.navRowHeight", 28, .points)
        /// `SettingsView.Metrics.navInset`.
        public static let navInset = DesignToken("Metrics.Settings.navInset", 10, .points)
        /// `SettingsView.Metrics.contentTop`.
        public static let contentTop = DesignToken("Metrics.Settings.contentTop", 20, .points)
        /// `SettingsView.Metrics.contentSide`.
        public static let contentSide = DesignToken("Metrics.Settings.contentSide", 22, .points)
        /// `SettingsView.Metrics.sectionSpacing`.
        public static let sectionSpacing = DesignToken("Metrics.Settings.sectionSpacing", 20, .points)
        /// `SettingsView.Metrics.rowPaddingV`.
        public static let rowPaddingV = DesignToken("Metrics.Settings.rowPaddingV", 12, .points)
        /// `SettingsView.Metrics.rowPaddingH`.
        public static let rowPaddingH = DesignToken("Metrics.Settings.rowPaddingH", 14, .points)
        /// `SettingsView.Metrics.controlGap`.
        public static let controlGap = DesignToken("Metrics.Settings.controlGap", 16, .points)
    }

    /// `CheatSheetOverlayView.Metrics`. Its radius is `Radii.cheatSheet`.
    public enum CheatSheet {
        /// `CheatSheetOverlayView.Metrics.cardPadding`.
        public static let cardPadding = DesignToken("Metrics.CheatSheet.cardPadding", 24, .points)
        /// `CheatSheetOverlayView.Metrics.columnSpacing`.
        public static let columnSpacing = DesignToken("Metrics.CheatSheet.columnSpacing", 36, .points)
        /// `CheatSheetOverlayView.Metrics.sectionSpacing`.
        public static let sectionSpacing = DesignToken("Metrics.CheatSheet.sectionSpacing", 18, .points)
        /// `CheatSheetOverlayView.Metrics.rowSpacing`.
        public static let rowSpacing = DesignToken("Metrics.CheatSheet.rowSpacing", 5, .points)
        /// `CheatSheetOverlayView.Metrics.keyTitleSpacing`.
        public static let keyTitleSpacing = DesignToken("Metrics.CheatSheet.keyTitleSpacing", 14, .points)
        /// `CheatSheetOverlayView.Metrics.columnCount`: sections are dealt into this many columns.
        public static let columnCount = DesignToken("Metrics.CheatSheet.columnCount", 2, .scalar)
    }

    /// The main window (artboard 2c is 1240×820): `MainWindowController`'s geometry, and the sidebar
    /// widths `SidebarMetrics` shares with it.
    public enum Window {
        /// `MainWindowController.defaultWindowSize`, titlebar included.
        public static let width = DesignToken("Metrics.Window.width", 1240, .points)
        public static let height = DesignToken("Metrics.Window.height", 820, .points)
        /// `MainWindowController.minimumContentSize`.
        public static let minWidth = DesignToken("Metrics.Window.minWidth", 720, .points)
        public static let minHeight = DesignToken("Metrics.Window.minHeight", 420, .points)
        /// `SidebarMetrics.sidebarWidth`: the nominal sidebar width.
        public static let sidebarWidth = DesignToken("Metrics.Window.sidebarWidth", 300, .points)
        /// `SidebarMetrics.sidebarMinWidth`: titles must truncate at this width.
        public static let sidebarMinWidth = DesignToken("Metrics.Window.sidebarMinWidth", 240, .points)
        /// The sidebar split item's `maximumThickness`, and the cap on a restored width.
        public static let sidebarMaxWidth = DesignToken("Metrics.Window.sidebarMaxWidth", 520, .points)
        /// The detail split item's `minimumThickness`.
        public static let detailMinWidth = DesignToken("Metrics.Window.detailMinWidth", 400, .points)
    }

    /// The status bar.
    public enum StatusBar {
        /// The line along the bar's top edge: one device pixel, `1 / backingScaleFactor` points on
        /// the Mac (`StatusBarView.draw(_:)`).
        public static let topLine = DesignToken("Metrics.StatusBar.topLine", 1, .hairline)
    }

    /// Every metric, in declaration order, then the inline Auto Layout constants
    /// (`DesignTokens+Layout.swift`).
    static let all: [DesignToken] = [
        Sidebar.groupRowHeight, Sidebar.sessionRowHeight, Sidebar.sessionRowWrappedHeight,
        Sidebar.headerHeight, Sidebar.updateNoticeHeight, Sidebar.sessionIndent, Sidebar.groupEdgeWidth,
        TabStrip.stripHeight, TabStrip.tabMinWidth, TabStrip.tabMaxWidth, TabStrip.tabGap,
        TabStrip.horizontalInset, TabStrip.badgeGap, TabStrip.closeSize,
        Split.dividerThickness, Split.gripLength, Split.gripThickness, Split.minPaneSide, Split.ratioEpsilon,
        PaneHeader.height, PaneHeader.insetX, PaneHeader.gap, PaneHeader.dotDiameter, PaneHeader.closeSize,
        PaneHeader.focusRingWidth, PaneHeader.inactiveContentAlpha,
        Changes.headerHeight, Changes.fileListWidth, Changes.fileRowHeight, Changes.fileListInset,
        Changes.pathHeaderHeight, Changes.diffRowHeight, Changes.numberWidth, Changes.numberGap,
        Changes.textInset, Changes.tabWidth,
        GlassSheet.width, GlassSheet.padding, GlassSheet.topPadding, GlassSheet.bottomPadding,
        GlassSheet.buttonHeight, GlassSheet.inset,
        DeleteMergedSheet.width, DeleteMergedSheet.maxListHeight,
        PromptCard.width, PromptCard.padding, PromptCard.verticalPadding, PromptCard.rowSpacing,
        PromptCard.defaultMaxTextHeight, PromptCard.minTextHeight,
        ThemedSwitch.width, ThemedSwitch.height, ThemedSwitch.knob, ThemedSwitch.inset,
        Settings.width, Settings.height, Settings.navWidth, Settings.navRowHeight, Settings.navInset,
        Settings.contentTop, Settings.contentSide, Settings.sectionSpacing, Settings.rowPaddingV,
        Settings.rowPaddingH, Settings.controlGap,
        CheatSheet.cardPadding, CheatSheet.columnSpacing, CheatSheet.sectionSpacing, CheatSheet.rowSpacing,
        CheatSheet.keyTitleSpacing, CheatSheet.columnCount,
        Window.width, Window.height, Window.minWidth, Window.minHeight, Window.sidebarWidth,
        Window.sidebarMinWidth, Window.sidebarMaxWidth, Window.detailMinWidth,
        StatusBar.topLine,
    ] + layout
}
