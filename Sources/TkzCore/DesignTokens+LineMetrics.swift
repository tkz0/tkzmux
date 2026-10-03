// TkzCore — the typography roles' line metrics as the Mac measures them (WOR-307 S4).
//
// GENERATED on the reference runner by `ComponentSnapshotTypographyTests` (TkzAppTests) with
// `TKZMUX_UPDATE_SNAPSHOTS=1`, in the same run that regenerates the component goldens
// (docs/linux/parity.md, "Updating the goldens"). Do not edit by hand. Empty until then.

import Foundation

extension DesignTokens.Typography {
    /// The macOS build (`sysctl kern.osversion`) `measured` was taken on; empty until generated.
    public static let measuredOn = "25G83"

    /// Role name → its metrics, for every role in `roles`.
    public static let measured: [String: LineMetrics] = [
        "Typography.badge": LineMetrics(
            fontName: ".AppleSystemUIFontDemi", ascender: 8.701171875, descender: -1.8984375,
            leading: 0.0, lineHeight: 11.0, baseline: 9.0),
        "Typography.closeGlyph": LineMetrics(
            fontName: ".AppleSystemUIFontMedium", ascender: 12.568359375, descender: -2.7421875,
            leading: 0.0, lineHeight: 16.0, baseline: 13.0),
        "Typography.groupAdd": LineMetrics(
            fontName: ".AppleSystemUIFont", ascender: 11.6015625, descender: -2.53125,
            leading: 0.0, lineHeight: 15.0, baseline: 12.0),
        "Typography.sidebarHeaderCaption": LineMetrics(
            fontName: ".AppleSystemUIFontDemi", ascender: 10.1513671875, descender: -2.21484375,
            leading: 0.0, lineHeight: 12.0, baseline: 10.0),
        "Typography.lastMessage": LineMetrics(
            fontName: ".AppleSystemUIFont", ascender: 10.634765625, descender: -2.3203125,
            leading: 0.0, lineHeight: 13.0, baseline: 11.0),
        "Typography.updateTitle": LineMetrics(
            fontName: ".AppleSystemUIFontDemi", ascender: 11.6015625, descender: -2.53125,
            leading: 0.0, lineHeight: 15.0, baseline: 12.0),
        "Typography.updateGlyph": LineMetrics(
            fontName: ".AppleSystemUIFontDemi", ascender: 11.6015625, descender: -2.53125,
            leading: 0.0, lineHeight: 15.0, baseline: 12.0),
        "Typography.updateClose": LineMetrics(
            fontName: ".AppleSystemUIFont", ascender: 10.634765625, descender: -2.3203125,
            leading: 0.0, lineHeight: 13.0, baseline: 11.0),
        "Typography.statusPill": LineMetrics(
            fontName: "JetBrainsMono-Regular", ascender: 10.200042724609375, descender: -3.000030517578125,
            leading: 0.0, lineHeight: 13.0, baseline: 10.0),
        "Typography.changesTitle": LineMetrics(
            fontName: ".AppleSystemUIFontDemi", ascender: 11.6015625, descender: -2.53125,
            leading: 0.0, lineHeight: 15.0, baseline: 12.0),
        "Typography.fileViewerText": LineMetrics(
            fontName: "JetBrainsMono-Regular", ascender: 13.260055541992188, descender: -3.9000396728515625,
            leading: 0.0, lineHeight: 17.0, baseline: 13.0),
        "Typography.markdownBody": LineMetrics(
            fontName: ".AppleSystemUIFont", ascender: 13.0517578125, descender: -2.84765625,
            leading: 0.0, lineHeight: 16.0, baseline: 13.0),
        "Typography.markdownCode": LineMetrics(
            fontName: "JetBrainsMono-Regular", ascender: 12.750053405761719, descender: -3.7500381469726562,
            leading: 0.0, lineHeight: 17.0, baseline: 13.0),
        "Typography.markdownHeading1": LineMetrics(
            fontName: ".AppleSystemUIFontBold", ascender: 21.26953125, descender: -4.640625,
            leading: 0.0, lineHeight: 26.0, baseline: 21.0),
        "Typography.markdownHeading2": LineMetrics(
            fontName: ".AppleSystemUIFontBold", ascender: 17.40234375, descender: -3.796875,
            leading: 0.0, lineHeight: 21.0, baseline: 17.0),
        "Typography.markdownHeading3": LineMetrics(
            fontName: ".AppleSystemUIFontDemi", ascender: 14.9853515625, descender: -3.26953125,
            leading: 0.0, lineHeight: 18.0, baseline: 15.0),
        "Typography.markdownHeading4": LineMetrics(
            fontName: ".AppleSystemUIFontDemi", ascender: 13.53515625, descender: -2.953125,
            leading: 0.0, lineHeight: 17.0, baseline: 14.0),
        "Typography.sheetTitle": LineMetrics(
            fontName: ".AppleSystemUIFontDemi", ascender: 12.568359375, descender: -2.7421875,
            leading: 0.0, lineHeight: 16.0, baseline: 13.0),
        "Typography.sheetBody": LineMetrics(
            fontName: "JetBrainsMono-Regular", ascender: 11.730049133300781, descender: -3.4500350952148438,
            leading: 0.0, lineHeight: 15.0, baseline: 12.0),
        "Typography.sheetPath": LineMetrics(
            fontName: "JetBrainsMono-Regular", ascender: 11.220046997070312, descender: -3.3000335693359375,
            leading: 0.0, lineHeight: 14.0, baseline: 11.0),
        "Typography.sheetListStatus": LineMetrics(
            fontName: "JetBrainsMono-Regular", ascender: 10.710044860839844, descender: -3.1500320434570312,
            leading: 0.0, lineHeight: 14.0, baseline: 11.0),
        "Typography.sheetButton": LineMetrics(
            fontName: ".AppleSystemUIFont", ascender: 11.1181640625, descender: -2.42578125,
            leading: 0.0, lineHeight: 13.0, baseline: 11.0),
        "Typography.sheetButtonPrimary": LineMetrics(
            fontName: ".AppleSystemUIFontDemi", ascender: 11.1181640625, descender: -2.42578125,
            leading: 0.0, lineHeight: 13.0, baseline: 11.0),
        "Typography.sheetCheckbox": LineMetrics(
            fontName: ".AppleSystemUIFont", ascender: 11.1181640625, descender: -2.42578125,
            leading: 0.0, lineHeight: 13.0, baseline: 11.0),
        "Typography.shortcutHint": LineMetrics(
            fontName: "JetBrainsMono-Regular", ascender: 10.200042724609375, descender: -3.000030517578125,
            leading: 0.0, lineHeight: 13.0, baseline: 10.0),
        "Typography.promptPill": LineMetrics(
            fontName: ".AppleSystemUIFontBold", ascender: 8.701171875, descender: -1.8984375,
            leading: 0.0, lineHeight: 11.0, baseline: 9.0),
        "Typography.activityKindPill": LineMetrics(
            fontName: ".AppleSystemUIFontDemi", ascender: 8.701171875, descender: -1.8984375,
            leading: 0.0, lineHeight: 11.0, baseline: 9.0),
        "Typography.settingsNavTitle": LineMetrics(
            fontName: ".AppleSystemUIFont", ascender: 12.0849609375, descender: -2.63671875,
            leading: 0.0, lineHeight: 15.0, baseline: 12.0),
        "Typography.settingsNavTitleSelected": LineMetrics(
            fontName: ".AppleSystemUIFontMedium", ascender: 12.0849609375, descender: -2.63671875,
            leading: 0.0, lineHeight: 15.0, baseline: 12.0),
        "Typography.settingsNavGlyph": LineMetrics(
            fontName: ".AppleSystemUIFont", ascender: 11.6015625, descender: -2.53125,
            leading: 0.0, lineHeight: 15.0, baseline: 12.0),
        "Typography.settingsSectionCaption": LineMetrics(
            fontName: ".AppleSystemUIFontDemi", ascender: 10.634765625, descender: -2.3203125,
            leading: 0.0, lineHeight: 13.0, baseline: 11.0),
        "Typography.settingsRowTitle": LineMetrics(
            fontName: ".AppleSystemUIFont", ascender: 12.568359375, descender: -2.7421875,
            leading: 0.0, lineHeight: 16.0, baseline: 13.0),
        "Typography.settingsRowDetail": LineMetrics(
            fontName: ".AppleSystemUIFont", ascender: 11.1181640625, descender: -2.42578125,
            leading: 0.0, lineHeight: 13.0, baseline: 11.0),
        "Typography.settingsControl": LineMetrics(
            fontName: ".AppleSystemUIFont", ascender: 11.6015625, descender: -2.53125,
            leading: 0.0, lineHeight: 15.0, baseline: 12.0),
        "Typography.settingsStatusChip": LineMetrics(
            fontName: "JetBrainsMono-Regular", ascender: 11.220046997070312, descender: -3.3000335693359375,
            leading: 0.0, lineHeight: 14.0, baseline: 11.0),
    ]
}
