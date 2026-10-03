// DesignTokenForwardingTests — WOR-307 S3, the Mac half of `DesignTokensTests` (TkzCoreTests).
//
// The Linux half proves from source that every old constant forwards to a token holding its old
// literal. This one reads the constants as the app does, through their old names and types, and
// compares each with that literal at run time. `CheatSheetOverlayView.Metrics` is private, so only
// the source scan covers it.

import AppKit
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite struct DesignTokenForwardingTests {
    @Test func sidebarAndWindow() {
        #expect(SidebarMetrics.groupRowHeight == 28)
        #expect(SidebarMetrics.sessionRowHeight == 44)
        #expect(SidebarMetrics.sessionRowWrappedHeight == 59)
        #expect(SidebarMetrics.sidebarHeaderHeight == 28)
        #expect(SidebarMetrics.updateNoticeHeight == 48)
        #expect(SidebarMetrics.sessionIndent == 16)
        #expect(SidebarMetrics.groupEdgeWidth == 2.5)
        #expect(SidebarMetrics.sidebarWidth == 300)
        #expect(SidebarMetrics.sidebarMinWidth == 240)
        #expect(MainWindowController.defaultWindowSize == NSSize(width: 1240, height: 820))
        #expect(MainWindowController.minimumContentSize == NSSize(width: 720, height: 420))
        #expect(MainWindowController.sidebarWidth == 300)
        #expect(MainWindowController.sidebarMinWidth == 240)
        #expect(MainWindowController.sidebarMaxWidth == 520)
        #expect(MainWindowController.detailMinWidth == 400)
    }

    @Test func tabsPanesAndChanges() {
        #expect(TabStripMetrics.stripHeight == 28)
        #expect(TabStripMetrics.tabMinWidth == 90)
        #expect(TabStripMetrics.tabMaxWidth == 180)
        #expect(TabStripMetrics.tabGap == 1)
        #expect(TabStripMetrics.horizontalInset == 8)
        #expect(TabStripMetrics.cornerRadius == 6)
        #expect(TabStripMetrics.badgeGap == 6)
        #expect(TabStripMetrics.closeSize == 14)
        #expect(SplitMetrics.dividerThickness == 7)
        #expect(SplitMetrics.gripLength == 44)
        #expect(SplitMetrics.gripThickness == 3)
        #expect(SplitMetrics.minPaneSide == 120)
        #expect(SplitMetrics.ratioEpsilon == 0.005)
        #expect(PaneHeaderMetrics.height == 28)
        #expect(PaneHeaderMetrics.insetX == 12)
        #expect(PaneHeaderMetrics.gap == 8)
        #expect(PaneHeaderMetrics.dotDiameter == 6)
        #expect(PaneHeaderMetrics.closeSize == 16)
        #expect(PaneHeaderMetrics.focusRingWidth == 1.5)
        #expect(PaneHeaderMetrics.inactiveContentAlpha == 0.85)
        #expect(ChangesMetrics.headerHeight == 38)
        #expect(ChangesMetrics.fileListWidth == 264)
        #expect(ChangesMetrics.fileRowHeight == 28)
        #expect(ChangesMetrics.fileListInset == 6)
        #expect(ChangesMetrics.pathHeaderHeight == 32)
        #expect(ChangesMetrics.diffRowHeight == 20)
        #expect(ChangesMetrics.numberWidth == 44)
        #expect(ChangesMetrics.numberGap == 8)
        #expect(ChangesMetrics.textInset == 14)
        #expect(ChangesMetrics.fontSize == 11.5)
        #expect(ChangesMetrics.fileFontSize == 10.5)
        #expect(ChangesMetrics.tabWidth == 4)
    }

    @Test func sheetsCardsAndSettings() {
        #expect(GlassSheetMetrics.width == 318)
        #expect(GlassSheetMetrics.padding == 14)
        #expect(GlassSheetMetrics.topPadding == 13)
        #expect(GlassSheetMetrics.bottomPadding == 12)
        #expect(GlassSheetMetrics.cornerRadius == 11)
        #expect(GlassSheetMetrics.buttonHeight == 27)
        #expect(GlassSheetMetrics.inset == 14)
        #expect(RebaseSheetView.Metrics.width == 318)
        #expect(RebaseSheetView.Metrics.cornerRadius == 11)
        #expect(DeleteWorktreeSheetView.Metrics.width == 318)
        #expect(DeleteMergedWorktreesSheetView.Metrics.width == 380)
        #expect(DeleteMergedWorktreesSheetView.Metrics.maxListHeight == 180)
        #expect(PromptCardView.Metrics.width == 640)
        #expect(PromptCardView.Metrics.padding == 20)
        #expect(PromptCardView.Metrics.verticalPadding == 18)
        #expect(PromptCardView.Metrics.rowSpacing == 10)
        #expect(PromptCardView.Metrics.cornerRadius == 12)
        #expect(PromptCardView.Metrics.defaultMaxTextHeight == 220)
        #expect(PromptCardView.Metrics.minTextHeight == 22)
        #expect(ThemedSwitch.Metrics.width == 30)
        #expect(ThemedSwitch.Metrics.height == 18)
        #expect(ThemedSwitch.Metrics.knob == 14)
        #expect(ThemedSwitch.Metrics.inset == 2)
        #expect(SettingsView.Metrics.width == 720)
        #expect(SettingsView.Metrics.height == 600)
        #expect(SettingsView.Metrics.navWidth == 176)
        #expect(SettingsView.Metrics.navRowHeight == 28)
        #expect(SettingsView.Metrics.navInset == 10)
        #expect(SettingsView.Metrics.cardRadius == 9)
        #expect(SettingsView.Metrics.contentTop == 20)
        #expect(SettingsView.Metrics.contentSide == 22)
        #expect(SettingsView.Metrics.sectionSpacing == 20)
        #expect(SettingsView.Metrics.rowPaddingV == 12)
        #expect(SettingsView.Metrics.rowPaddingH == 14)
        #expect(SettingsView.Metrics.controlGap == 16)
    }
}
