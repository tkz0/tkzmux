// CellMetrics — integer terminal cell geometry in device pixels (M1.4, moved to the core by WOR-311).
//
// Everything here is device pixels at the font's pixel size (`pointSize * scale`). All values are
// integral and deterministic for a given (family, size, scale), so a regression in font handling
// shows up as a changed number rather than a blurry frame.
//
// The formulas live here and take pixel-unit inputs, so every font backend goes through the same
// rounding: the Mac feeds it CoreText values (`init(font:scale:)` in TkzTerminalRender), Linux
// feeds it raw sfnt table values (`init(tables:pixelSize:scale:)`, FontTables.swift). Vertical
// metrics round half away from zero (`.rounded()`, never banker's), width rounds up.
//
// Vertical convention: y grows *downward* (screen space). `baseline` is the distance from the top of
// the cell to the text baseline. Decoration offsets are relative to the baseline, positive downward —
// so `underlineOffset` is positive (below the baseline) and `strikethroughOffset` is negative.

import Foundation

public struct CellMetrics: Sendable, Equatable, Hashable {
    /// Cell width: the widest advance over printable ASCII, rounded up.
    public let width: Int
    /// Cell height: `round(ascent + descent + leading)`.
    public let height: Int
    /// Rounded font ascent.
    public let ascent: Int
    /// Rounded font descent.
    public let descent: Int
    /// Rounded font leading (line gap).
    public let leading: Int
    /// Distance from the top of the cell down to the baseline.
    public let baseline: Int
    /// Underline centre, relative to the baseline, positive downward.
    public let underlineOffset: Int
    /// Underline thickness, at least 1 px.
    public let underlineThickness: Int
    /// Strikethrough centre, relative to the baseline, positive downward (normally negative).
    public let strikethroughOffset: Int
    /// Strikethrough thickness, at least 1 px.
    public let strikethroughThickness: Int
    /// Backing scale the metrics were measured at.
    public let scale: CGFloat

    /// Width of a double-width (wide) grapheme's box.
    public var wideWidth: Int { width * 2 }

    /// The shared formula. Every input is in device pixels; vertical font metrics are positive
    /// magnitudes (`descent` is below the baseline but passed as a positive number), and the
    /// decoration positions are relative to the baseline, positive *up*, as fonts store them.
    ///
    /// - Parameters:
    ///   - maxAdvance: the widest horizontal advance over printable ASCII (U+0020…U+007E).
    ///   - underlinePosition: underline centre, positive up (normally negative).
    ///   - strikeoutPosition: strikeout centre, positive up (normally positive).
    public init(ascent: CGFloat,
                descent: CGFloat,
                leading: CGFloat,
                maxAdvance: CGFloat,
                underlinePosition: CGFloat,
                underlineThickness: CGFloat,
                strikeoutPosition: CGFloat,
                strikeoutThickness: CGFloat,
                scale: CGFloat) {
        self.ascent = Int(ascent.rounded())
        self.descent = Int(descent.rounded())
        self.leading = Int(leading.rounded())
        self.height = max(1, Int((ascent + descent + leading).rounded()))
        self.baseline = Int(ascent.rounded())
        self.width = max(1, Int(maxAdvance.rounded(.up)))
        self.scale = scale

        self.underlineThickness = max(1, Int(underlineThickness.rounded()))
        self.underlineOffset = Int((-underlinePosition).rounded())

        self.strikethroughThickness = max(1, Int(strikeoutThickness.rounded()))
        self.strikethroughOffset = Int((-strikeoutPosition).rounded())
    }
}
