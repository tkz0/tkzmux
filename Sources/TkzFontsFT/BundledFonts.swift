// BundledFonts — where the bundled JetBrains Mono faces are, and which file each style opens (WOR-312 S3).
//
// The terminal's primary faces are opened directly from these files with `FT_New_Face`, never looked
// up through fontconfig: on a desktop with the JetBrainsMono Nerd Font installed (Omarchy), a
// 'JetBrains Mono' lookup resolves to the Nerd Font, whose metrics and outlines differ.
//
// Resources/Fonts is a byte-identical copy of `Sources/TkzTerminalRender/Resources/Fonts`, which is
// in the Mac graph only; `BundledFontsTests` fails if the two ever differ. The bundle is found the
// way every module's is (`ResourceLocator`, then `Bundle.module` last; see
// `Sources/TkzTerminalRender/ModuleResources.swift` for why the order matters).

import Foundation
import TkzCore
import TkzRenderCore

enum ModuleResources {
    static let bundle: Bundle = {
        if let url = ResourceLocator.current.bundleURL(forModule: "TkzFontsFT"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
}

public enum BundledFonts {
    /// The directory holding the bundled TTFs and their OFL.txt.
    public static var directory: URL? {
        ModuleResources.bundle.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
    }

    /// The file name of `style`'s JetBrains Mono face.
    public static func jetBrainsMonoFile(_ style: FontStyle) -> String {
        switch style {
        case .regular: "JetBrainsMono-Regular.ttf"
        case .bold: "JetBrainsMono-Bold.ttf"
        case .italic: "JetBrainsMono-Italic.ttf"
        case .boldItalic: "JetBrainsMono-BoldItalic.ttf"
        }
    }
}
