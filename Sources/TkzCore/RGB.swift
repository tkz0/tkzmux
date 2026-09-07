// TkzCore — colour value type shared by the theme, the renderer and the sidebar.
// No AppKit/Foundation: conversion to NSColor/MTLClearColor lives in the consuming module.

import Darwin  // pow

/// An sRGB colour with straight (non-premultiplied) alpha, components in 0…1.
public struct RGB: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `RGB(hex: 0x141624)`; `RGB(hex: 0xffffff, alpha: 0.30)` for the design's `rgba(255,255,255,.30)`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            r: Double((hex >> 16) & 0xff) / 255,
            g: Double((hex >> 8) & 0xff) / 255,
            b: Double(hex & 0xff) / 255,
            a: alpha
        )
    }

    /// `RGB(rgb: 31, 34, 54, alpha: 0.95)` mirrors the design file's `rgba(31,34,54,0.95)` literally.
    public init(rgb r: UInt8, _ g: UInt8, _ b: UInt8, alpha: Double = 1) {
        self.init(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255, a: alpha)
    }

    public static let white = RGB(hex: 0xffffff)
    public static let black = RGB(hex: 0x000000)

    /// 8-bit channels, rounded.
    public var bytes: (r: UInt8, g: UInt8, b: UInt8) {
        (UInt8((r * 255).rounded()), UInt8((g * 255).rounded()), UInt8((b * 255).rounded()))
    }

    /// `#rrggbb`, or `rgba(r,g,b,a)` when the alpha is below 1 — the notation the design file uses.
    public var hexString: String {
        let (r8, g8, b8) = bytes
        if a >= 1 {
            return "#" + [r8, g8, b8].map { Self.hexByte($0) }.joined()
        }
        let alpha = String(format2: a)
        return "rgba(\(r8),\(g8),\(b8),\(alpha))"
    }

    // MARK: Derivation

    /// Linear blend of the channels (`amount` 0 = self, 1 = `other`); alpha is blended too.
    public func mixed(with other: RGB, amount: Double) -> RGB {
        let t = min(max(amount, 0), 1)
        return RGB(
            r: r + (other.r - r) * t,
            g: g + (other.g - g) * t,
            b: b + (other.b - b) * t,
            a: a + (other.a - a) * t
        )
    }

    /// Alpha-composites `self` over an opaque `background` (source-over); the result is opaque.
    public func over(_ background: RGB) -> RGB {
        RGB(
            r: r * a + background.r * (1 - a),
            g: g * a + background.g * (1 - a),
            b: b * a + background.b * (1 - a),
            a: 1
        )
    }

    // MARK: WCAG 2.x contrast

    /// Relative luminance per WCAG 2.x (sRGB linearisation), ignoring alpha.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio in 1…21, symmetric in its arguments. Alpha is ignored: composite first with `over(_:)`.
    public func contrastRatio(against other: RGB) -> Double {
        let l1 = relativeLuminance
        let l2 = other.relativeLuminance
        let (hi, lo) = l1 >= l2 ? (l1, l2) : (l2, l1)
        return (hi + 0.05) / (lo + 0.05)
    }

    private static func hexByte(_ v: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(v >> 4)], digits[Int(v & 0xf)]])
    }
}

extension String {
    /// Two-decimal fixed-point rendering with a leading zero dropped (`0.95` → `.95`), matching the design file.
    fileprivate init(format2 value: Double) {
        let hundredths = Int((value * 100).rounded())
        let whole = hundredths / 100
        let frac = hundredths % 100
        let fracText = frac < 10 ? "0\(frac)" : "\(frac)"
        self = whole == 0 ? ".\(fracText)" : "\(whole).\(fracText)"
    }
}
