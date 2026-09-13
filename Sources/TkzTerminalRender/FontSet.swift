// FontSet — CoreText font resolution for the terminal grid (M1.4 / TKZ-10).
// See docs/design.md → Terminal engine → Metal renderer.
//
// The bundled JetBrains Mono faces live in `Bundle.module/Fonts`. Outside an app bundle
// (`swift test`, `swift run`) nothing registers them, so `FontSet` registers the directory
// with `CTFontManagerRegisterFontsForURL(.process)` exactly once before resolving. Inside the
// built `.app` the same files are also registered at launch through `ATSApplicationFontsPath`,
// so registration must tolerate "already registered" and be idempotent.

import CoreText
import Foundation

/// The four faces a terminal draws with.
public enum FontStyle: UInt8, CaseIterable, Sendable, Hashable {
    case regular, bold, italic, boldItalic

    public var isBold: Bool { self == .bold || self == .boldItalic }
    public var isItalic: Bool { self == .italic || self == .boldItalic }

    public init(bold: Bool, italic: Bool) {
        switch (bold, italic) {
        case (false, false): self = .regular
        case (true, false): self = .bold
        case (false, true): self = .italic
        case (true, true): self = .boldItalic
        }
    }

    var symbolicTraits: CTFontSymbolicTraits {
        var traits: CTFontSymbolicTraits = []
        if isBold { traits.insert(.boldTrait) }
        if isItalic { traits.insert(.italicTrait) }
        return traits
    }
}

/// Outcome of the one-shot process registration of the bundled fonts.
public struct FontRegistration: Sendable, Equatable {
    /// The `Fonts` directory inside `Bundle.module`, if it exists.
    public let directory: URL?
    /// Font files handed to CoreText.
    public let registeredFiles: [URL]
    /// Human-readable failures (a file that neither registered nor was already registered).
    public let failures: [String]
}

/// A resolved family of faces at one point size and backing scale.
///
/// Not `Sendable`: `CTFont` is a CoreFoundation type without concurrency guarantees. The renderer
/// owns one `FontSet` on the render thread; tests create their own.
public final class FontSet {
    /// Family that was actually resolved (`family`, or `fallback` if the primary was unavailable).
    public let resolvedFamily: String
    /// True when the requested family could not be resolved and `fallback` was used.
    public let usedFallbackFamily: Bool
    /// Point size in *points* (not device pixels).
    public let pointSize: CGFloat
    /// Backing scale (2.0 on Retina).
    public let scale: CGFloat
    /// Point size the `CTFont`s are actually built at: `pointSize * scale`, so rasterization is
    /// pixel-exact and every metric is already in device pixels.
    public let pixelSize: CGFloat

    /// True when the family has no real bold face and bold must be synthesized (fill + stroke).
    public let needsSyntheticBold: Bool
    /// True when the family has no real italic face and italics must be synthesized (skew).
    public let needsSyntheticItalic: Bool

    private let faces: [FontStyle: CTFont]

    /// Per-scalar fallback cache: scalar+style → the font CoreText picked for it.
    private var fallbackCache: [FallbackKey: CTFont] = [:]
    private var colorFontCache: [String: Bool] = [:]

    private struct FallbackKey: Hashable {
        let scalar: UInt32
        let style: FontStyle
    }

    // MARK: - Bundled font registration

    /// The `Fonts` directory copied into `Bundle.module`, if present.
    public static var bundledFontDirectoryURL: URL? {
        ModuleResources.bundle.url(forResource: "Fonts", withExtension: nil)
    }

    /// `OFL.txt` shipped alongside the bundled fonts (SIL Open Font License 1.1).
    public static var bundledLicenseURL: URL? {
        guard let dir = bundledFontDirectoryURL else { return nil }
        let url = dir.appendingPathComponent("OFL.txt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Serializes font *registration* against font *resolution* inside this process.
    ///
    /// `CTFontManagerRegisterFontsForURL` mutates the process font list that
    /// `CTFontDescriptorCreateMatchingFontDescriptor` reads through the same XPC connection; doing
    /// both from several threads at once has been observed to wedge that connection (Swift Testing
    /// runs test functions in parallel, so this is reachable from `swift test`). One `Mutex` around
    /// both sides costs nothing — resolution happens once per `FontSet`, not per glyph.
    /// `NSLock` rather than `Mutex` because the guarded values are `CTFont`s, which are not
    /// `Sendable` and so cannot be returned out of a `Mutex.withLock` closure.
    private static let coreTextLock = NSLock()

    /// Registers the bundled fonts with the current process exactly once (a `static let` is
    /// dispatch-once'd by the runtime) and reports what happened.
    public static let registration: FontRegistration = {
        coreTextLock.lock()
        defer { coreTextLock.unlock() }
        return registerBundledFonts()
    }()

    private static func registerBundledFonts() -> FontRegistration {
        guard let dir = bundledFontDirectoryURL else {
            return FontRegistration(directory: nil, registeredFiles: [], failures: ["Bundle.module has no Fonts directory"])
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var registered: [URL] = []
        var failures: [String] = []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                registered.append(url)
            } else if let cfError = error?.takeRetainedValue() {
                // 105 alreadyRegistered: the exact same URL is already registered.
                // 305 duplicatedName: the .app registered the same PostScript names from a
                // *different* URL (ATSApplicationFontsPath → Contents/Resources/Fonts).
                // Both mean the faces are available; neither is a failure.
                let code = CFErrorGetCode(cfError)
                if code == CFIndex(CTFontManagerError.alreadyRegistered.rawValue)
                    || code == CFIndex(CTFontManagerError.duplicatedName.rawValue) {
                    registered.append(url)
                } else {
                    failures.append("\(url.lastPathComponent): \(CFErrorCopyDescription(cfError) as String? ?? "unknown error")")
                }
            } else {
                failures.append("\(url.lastPathComponent): registration failed with no error")
            }
        }
        return FontRegistration(directory: dir, registeredFiles: registered, failures: failures)
    }

    // MARK: - Init

    /// - Parameters:
    ///   - family: preferred family name, e.g. `"JetBrains Mono"`.
    ///   - fallback: family used when `family` cannot be resolved, e.g. `"Menlo"`.
    ///   - pointSize: size in points.
    ///   - scale: backing scale factor; fonts are built at `pointSize * scale`.
    public init(family: String = "JetBrains Mono",
                fallback: String = "Menlo",
                pointSize: CGFloat = 12.5,
                scale: CGFloat = 2.0) {
        _ = FontSet.registration  // force the one-shot registration before any resolution

        self.pointSize = pointSize
        self.scale = scale
        let pixelSize = pointSize * scale
        self.pixelSize = pixelSize

        // Every CTFont *construction* below goes through the XType XPC connection; keep them all on
        // one side of the lock (see `coreTextLock`).
        FontSet.coreTextLock.lock()
        let (base, resolvedFamily, usedFallback) = FontSet.resolveBase(
            family: family, fallback: fallback, size: pixelSize)
        var faces: [FontStyle: CTFont] = [.regular: base]
        var syntheticBold = false
        var syntheticItalic = false
        for style in FontStyle.allCases where style != .regular {
            if let face = CTFontCreateCopyWithSymbolicTraits(
                base, pixelSize, nil, style.symbolicTraits, style.symbolicTraits) {
                faces[style] = face
            } else {
                faces[style] = base
                if style.isBold { syntheticBold = true }
                if style.isItalic { syntheticItalic = true }
            }
        }
        FontSet.coreTextLock.unlock()

        self.resolvedFamily = resolvedFamily
        self.usedFallbackFamily = usedFallback
        self.faces = faces
        self.needsSyntheticBold = syntheticBold
        self.needsSyntheticItalic = syntheticItalic
    }

    /// Resolves `family`, falling back to `fallback` and finally to the system monospaced font.
    ///
    /// `CTFontCreateWithName` never fails — it silently substitutes — so resolution goes through a
    /// descriptor match on `kCTFontFamilyNameAttribute`, which *does* return nil for a missing family.
    private static func resolveBase(family: String, fallback: String, size: CGFloat)
        -> (CTFont, String, Bool) {
        if let font = matchFamily(family, size: size) { return (font, family, false) }
        if let font = matchFamily(fallback, size: size) { return (font, fallback, true) }
        let system = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
        let name = CTFontCopyFamilyName(system) as String
        return (system, name, true)
    }

    private static func matchFamily(_ family: String, size: CGFloat) -> CTFont? {
        let attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(
            descriptor, nil) else { return nil }
        let font = CTFontCreateWithFontDescriptor(matched, size, nil)
        // Defensive: CoreText should not substitute here, but verify anyway.
        guard (CTFontCopyFamilyName(font) as String) == family else { return nil }
        return font
    }

    // MARK: - Lookup

    /// The face for `style` (may be the regular face when the family lacks that face — see
    /// `needsSyntheticBold` / `needsSyntheticItalic`).
    public func font(for style: FontStyle) -> CTFont {
        faces[style] ?? faces[.regular]!
    }

    /// PostScript name of a face, e.g. `"JetBrainsMono-Regular"`.
    public func postScriptName(for style: FontStyle) -> String {
        CTFontCopyPostScriptName(font(for: style)) as String
    }

    /// The font that can draw `codepoints`, following CoreText's cascade list when the primary
    /// face has no glyph. Results are cached per (first scalar, style).
    public func font(for codepoints: [Unicode.Scalar], style: FontStyle = .regular) -> CTFont {
        let primary = font(for: style)
        guard let first = codepoints.first else { return primary }

        let key = FallbackKey(scalar: first.value, style: style)
        if codepoints.count == 1, let cached = fallbackCache[key] { return cached }

        var utf16: [UniChar] = []
        for scalar in codepoints { utf16.append(contentsOf: Array(String(scalar).utf16)) }
        let string = String(decoding: utf16, as: UTF16.self) as CFString
        FontSet.coreTextLock.lock()
        let resolved = CTFontCreateForString(primary, string, CFRange(location: 0, length: utf16.count))
        FontSet.coreTextLock.unlock()

        if codepoints.count == 1 { fallbackCache[key] = resolved }
        return resolved
    }

    /// Convenience for a single scalar.
    public func font(for scalar: Unicode.Scalar, style: FontStyle = .regular) -> CTFont {
        font(for: [scalar], style: style)
    }

    /// True when `font` carries colour glyph tables (Apple Color Emoji and friends), which must be
    /// rasterized into the BGRA atlas rather than the alpha one.
    public func isColorFont(_ font: CTFont) -> Bool {
        let key = CTFontCopyPostScriptName(font) as String
        if let cached = colorFontCache[key] { return cached }
        let value = CTFontGetSymbolicTraits(font).contains(.colorGlyphsTrait)
        colorFontCache[key] = value
        return value
    }
}
