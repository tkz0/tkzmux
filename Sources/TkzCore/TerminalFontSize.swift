// TerminalFontSize — the user's terminal font size: its default, its bounds, its step.
//
// The size is a preference, not part of a theme preset: switching ☾/☀ must not change it, and
// every preset ships the same `Theme.Fonts.mono.terminal` anyway. `AppState.terminalFontSize` holds
// the chosen value; View › Increase / Decrease / Reset Font Size and Settings › Appearance write it.

import Foundation

public enum TerminalFontSize {
    /// The size a fresh install, and ⌘0, gives — the theme's own terminal size.
    public static var standard: Double { Theme.Fonts.mono.terminal }

    /// Smallest and largest size the controls reach. Below 8 pt JetBrains Mono's cells are a
    /// handful of device pixels wide even at @2x; above 32 pt a 13" window holds barely 40 columns.
    public static let range: ClosedRange<Double> = 8...32

    /// One ⌘+ / ⌘- press.
    public static let step: Double = 1

    /// Every size the Settings popup offers: whole points across `range`.
    public static var choices: [Double] {
        stride(from: range.lowerBound, through: range.upperBound, by: step).map { $0 }
    }

    /// `size` pulled into `range` and rounded to whole points — what any writer stores. A
    /// non-finite value falls back to `standard` rather than poisoning the font set.
    public static func clamped(_ size: Double) -> Double {
        guard size.isFinite else { return standard }
        return min(max(size.rounded(), range.lowerBound), range.upperBound)
    }
}
