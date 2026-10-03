// BundledSymbols — Tkzmux Symbols, the bundled OFL subset of the symbols JetBrains Mono and Inter
// lack, and the inventory it must cover (WOR-312 S7). Linux only.
//
// On the Mac, CoreText's fallback draws ⏺ ⎿ ✢ ✳ ⎇ ↵ ⚙ and friends. On Linux, fontconfig would
// pick whatever the distro has: Omarchy draws ✳ with Noto Color Emoji, Ubuntu with something else.
// So every symbol the inventory lists comes from one bundled font, built at dev time by
// scripts/make-symbol-subset.py from Noto Sans Symbols 2, Noto Sans Symbols and Noto Sans Math
// (each pinned by SHA-256 in scripts/symbol-subset.json, each glyph picked to resemble the Mac),
// renamed Tkzmux Symbols as the OFL asks of a modified version. Resources/Symbols/OFL.txt ships
// with it.
//
// Fallback order, terminal and chrome alike: the primary face (JetBrains Mono; Inter for chrome
// UI, WOR-312 S8), then this subset, then the private fontconfig configuration. The subset is opened
// directly, like the primary faces, and is in no FcConfig directory, so an inventory glyph never
// costs a fontconfig call and never depends on what the machine has installed. It has one face, a
// regular outline face: never colour, so a text-presentation ✳ stays monochrome.
//
// The three SF Symbols the Mac chrome uses are not glyphs; they are drawn from original path data
// (SymbolIcons.swift).

import Foundation

public enum BundledSymbols {
    public static let family = "Tkzmux Symbols"
    public static let postScriptName = "TkzmuxSymbols-Regular"
    public static let fileName = "TkzmuxSymbols-Regular.ttf"

    /// The directory holding the subset and its OFL.txt, `nil` when the bundle is missing.
    public static var directory: URL? {
        ModuleResources.bundle.resourceURL?.appendingPathComponent("Symbols", isDirectory: true)
    }

    /// The subset's file.
    public static var url: URL? {
        directory?.appendingPathComponent(fileName)
    }

    /// The subset as a face the shaper opens like a fallback, `nil` when the file is missing.
    public static var face: FallbackFace? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return FallbackFace(path: url.path, index: 0, postScriptName: postScriptName, family: family, isColor: false)
    }

    // MARK: - Inventory

    /// What agents print (Claude Code's tool and status lines) that JetBrains Mono lacks.
    public static let agentGlyphs: [Unicode.Scalar] = [
        "\u{23FA}", "\u{23BF}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}",
        "\u{21AF}", "\u{2714}", "\u{25D0}", "\u{23F5}",
    ]

    /// Chrome glyphs: ⎇ ↵ ▾ ▸ ✕ ◫ ▬ ⬓ ☾ ☀ ⤿ ⚙ ⟳ ＋ ·. The middle dot is in both primary faces and
    /// not in the subset; it is listed because its advance feeds `detailWraps`.
    public static let chromeGlyphs: [Unicode.Scalar] = [
        "\u{2387}", "\u{21B5}", "\u{25BE}", "\u{25B8}", "\u{2715}", "\u{25EB}", "\u{25AC}", "\u{2B13}",
        "\u{263E}", "\u{2600}", "\u{293F}", "\u{2699}", "\u{27F3}", "\u{FF0B}", "\u{00B7}",
    ]

    /// The modifier and key glyphs of shortcut hints: ⌘ ⇧ ⌥ ⌃ ⎋ ⏎ ↩. The subset has all of them,
    /// so whichever of them Inter lacks is covered.
    public static let modifierGlyphs: [Unicode.Scalar] = [
        "\u{2318}", "\u{21E7}", "\u{2325}", "\u{2303}", "\u{238B}", "\u{23CE}", "\u{21A9}",
    ]

    /// Other UI-font glyphs the chrome sources print (settings sidebar, palette, toolbar, shortcut
    /// hints) that JetBrains Mono has but a UI font may not: ◈ ⌨ ● ■ ▶ ␣ ⇥.
    public static let uiGlyphs: [Unicode.Scalar] = [
        "\u{25C8}", "\u{2328}", "\u{25CF}", "\u{25A0}", "\u{25B6}", "\u{2423}", "\u{21E5}",
    ]

    /// Every glyph that must resolve to a bundled face. TODO(WOR-312 S1/S2): add what the Mac's
    /// symbol inventory and chrome-metrics dump find beyond these.
    public static var inventory: [Unicode.Scalar] {
        agentGlyphs + chromeGlyphs + modifierGlyphs + uiGlyphs
    }
}
