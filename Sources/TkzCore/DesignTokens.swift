// TkzCore — design tokens: every layout number, size, radius and duration the chrome uses, with no
// toolkit in sight.
//
// The Mac reads these through its old names (`SidebarMetrics`, `TabStripMetrics`, the nested
// `Metrics` enums, …), which now forward here; the Linux canvas (WOR-316–WOR-319) reads them
// directly. The values are the Mac's literals, moved verbatim: the Mac must draw exactly what it drew
// before (WOR-307), and `DesignTokensTests` pins every token to the literal it replaced.
//
// `Double` and Foundation only. TkzCore builds on both OSes, and a `CGFloat` here would tie the
// table to CoreGraphics on the Mac; the AppKit side converts with `CGFloat(token.value)`, which is
// exact because `CGFloat` is a `Double` on every platform tkzmux ships on.
//
// Each token carries the snapping kind the Linux toolkit applies to it (ADR-0003 §2,
// `docs/linux/parity.md` "Snapping kinds"). The Mac ignores it: at 2.0 its geometry lands on whole
// device pixels by construction.
//
// Filled so far: `Metrics` (the 13 `*Metrics` enums, window geometry, the status-bar hairline),
// the radii and the font sizes those enums held (S3), and the typography roles with their tracking
// and line metrics (S4, `DesignTokens+Typography.swift`), and the inline Auto Layout constants
// (S5, `DesignTokens+Layout.swift`). S6 adds the private statics, radii, borders, surfaces and
// motion.

import Foundation

/// One design value and how the Linux toolkit snaps it to device pixels.
public struct DesignToken: Hashable, Sendable {
    /// How a value becomes device pixels at scale `s` (ADR-0003 §2). Rounding is always Swift
    /// `.rounded()`, half away from zero.
    public enum Snap: String, CaseIterable, Hashable, Sendable {
        /// A layout length: each edge it produces is rounded on its own, `(edge × s).rounded()`,
        /// never origin plus rounded size. Rows, bars, panes, insets, gaps, hit areas.
        case points
        /// Exactly one device pixel at every scale. `value` is in device pixels; the Mac draws it
        /// as `1 / backingScaleFactor` points.
        case hairline
        /// A fixed-size mark: the origin rounds as an edge, the extent is `max(1, (d × s).rounded())`
        /// wherever it lands, so a dot is equally round on every row.
        case mark
        /// A line width: `max(1, (w × s).rounded())`, drawn inside the snapped rect.
        case stroke
        /// A length used at `w × s` and never rounded: corner radii (vector paths, drawn
        /// antialiased) and font point sizes (text snaps at the baseline, not here).
        case unrounded
        /// Not a length, so never scaled: ratios, alphas, counts.
        case scalar
    }

    /// The token's path under `DesignTokens`, e.g. `Metrics.Sidebar.groupRowHeight`.
    public let name: String
    /// In points, except for `.hairline` (device pixels) and `.scalar` (unitless).
    public let value: Double
    public let snap: Snap

    public init(_ name: String, _ value: Double, _ snap: Snap) {
        self.name = name
        self.value = value
        self.snap = snap
    }
}

/// The namespace. Nothing here is a colour: colours stay per preset in `Theme`.
public enum DesignTokens {
    /// Lengths: rows, bars, panes, cards, insets, gaps, window geometry. `DesignTokens+Metrics.swift`,
    /// and `DesignTokens+Layout.swift` for the inline Auto Layout constants.
    public enum Metrics {}

    /// Text: the roles (size, effective face and weight, tracking, measured line height and
    /// baseline) and the single-value text tokens. `DesignTokens+Typography.swift`.
    public enum Typography {
        /// The changes viewer's diff text (`ChangesMetrics.fontSize`).
        public static let changesDiffSize = DesignToken("Typography.changesDiffSize", 11.5, .unrounded)
        /// The changes viewer's file list (`ChangesMetrics.fileFontSize`).
        public static let changesFileSize = DesignToken("Typography.changesFileSize", 10.5, .unrounded)
    }

    /// Corner radii. WOR-307 S6 adds the inline radius literals.
    public enum Radii {
        /// A tab's rounded rect (`TabStripMetrics.cornerRadius`).
        public static let tab = DesignToken("Radii.tab", 6, .unrounded)
        /// The glass sheet family (`GlassSheetMetrics.cornerRadius`).
        public static let glassSheet = DesignToken("Radii.glassSheet", 11, .unrounded)
        /// The prompt card (`PromptCardView.Metrics.cornerRadius`).
        public static let promptCard = DesignToken("Radii.promptCard", 12, .unrounded)
        /// The cheat sheet card (`CheatSheetOverlayView.Metrics.cornerRadius`).
        public static let cheatSheet = DesignToken("Radii.cheatSheet", 12, .unrounded)
        /// A Settings card (`SettingsView.Metrics.cardRadius`).
        public static let settingsCard = DesignToken("Radii.settingsCard", 9, .unrounded)
    }

    /// Durations. Filled by WOR-307 S6.
    public enum Motion {}

    /// Surface geometry (radius, border) per surface, such as the palette's two modes. Filled by
    /// WOR-307 S6.
    public enum Surfaces {}

    /// Every token, in declaration order, for the design table and the tests.
    public static let all: [DesignToken] = Metrics.all + Typography.all + [
        Radii.tab, Radii.glassSheet, Radii.promptCard, Radii.cheatSheet, Radii.settingsCard,
    ]

    /// The token at `name`, as `DesignToken.name` spells it.
    public static func token(named name: String) -> DesignToken? {
        all.first { $0.name == name }
    }
}
