// ThemeAppKit.swift — the AppKit side of the design tokens.
//
// `TkzCore` is deliberately AppKit-free (design.md → Theme): `RGB` is a plain sRGB value type and
// conversion belongs to the consumer. This file is that consumer, shared by every view in `TkzApp`
// so nobody hand-rolls a second conversion with a different colour space.
//
// **Colour space matters here.** The design's hex values are sRGB. `NSColor(red:green:blue:alpha:)`
// uses the *deviceRGB* space, which is not sRGB on a wide-gamut display, so the same literal would
// render differently in the sidebar (AppKit) and the terminal grid (Metal, explicitly sRGB). Always
// go through `.sRGB` so the two halves of the window agree.
import AppKit
import TkzCore

public extension RGB {
    /// The sRGB `NSColor` for this token. Straight alpha, as stored.
    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// The same colour as a `CGColor`, for `CALayer` properties.
    var cgColor: CGColor { nsColor.cgColor }
}

public extension Theme.Fonts {
    /// The design's UI font at `size`. `family == nil` means the system font (SF), which is what
    /// every preset uses.
    static func ui(_ size: Double, weight: NSFont.Weight = .regular) -> NSFont {
        if let family = ui.family, let font = NSFont(name: family, size: size) { return font }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// JetBrains Mono at `size`, falling back to Menlo and then to the system monospaced face.
    ///
    /// The bundled faces are registered process-wide by `FontSet` (M1.4) and, inside the `.app`, by
    /// `ATSApplicationFontsPath`. Resolution still goes through a descriptor match rather than
    /// `NSFont(name:)` alone, because a missing family silently substitutes rather than failing.
    static func mono(_ size: Double, weight: NSFont.Weight = .regular) -> NSFont {
        if let font = NSFont(name: mono.postScriptName, size: size) { return font }
        if let font = NSFont(name: mono.fallback, size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}
