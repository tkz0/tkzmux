// FontconfigConfiguration — the private FcConfig every fallback lookup runs against (WOR-312 S4).
//
// Fontconfig's default configuration is the desktop's: /etc/fonts/fonts.conf pulls in conf.d,
// where Omarchy's 50-omarchy.conf remaps sans-serif and monospace with `binding="strong"`, Ubuntu
// adds its own aliases, and `FONTCONFIG_FILE`/`FONTCONFIG_PATH` can point anywhere. None of that
// may reach tkzmux's output (ADR-0002 D8), so the config is built from scratch: `FcConfigCreate`
// plus one document from `xml`, loaded with `FcConfigParseAndLoadFromMemory`. It names font
// directories, a cache directory and the rejected formats, and includes nothing: no fonts.conf, no
// conf.d, no match rules. With no rules, `FcConfigSubstitute` would be a no-op, and
// `FcDefaultSubstitute` (locale language, the default config's DPI) is never called, so a pattern
// is exactly what `FontFallback` puts in it.
//
// Directories, in order (the order breaks exact ties in a sort):
//   system  the bundled fonts, /usr/share/fonts, ~/.local/share/fonts
//   parity  the bundled fonts and the pinned test-font directory (scripts/fetch-parity-fonts.sh,
//           Tests/Parity/Fonts/fonts.lock.json), nothing else, so CI and every desktop resolve the
//           same faces
// The cache lives in `$XDG_CACHE_HOME/tkzmux/fontconfig`: without a `<cachedir>` fontconfig has
// nowhere to write one and rescans every font on every launch.

import Foundation
import TkzPlatform

public struct FontconfigConfiguration: Sendable, Equatable {
    /// Font directories, scanned recursively, in this order.
    public let fontDirectories: [URL]
    /// Where fontconfig reads and writes its per-directory caches.
    public let cacheDirectory: URL

    public init(fontDirectories: [URL], cacheDirectory: URL) {
        self.fontDirectories = fontDirectories
        self.cacheDirectory = cacheDirectory
    }

    /// `$XDG_CACHE_HOME/tkzmux/fontconfig`.
    public static var defaultCacheDirectory: URL {
        AppPaths.cache.appendingPathComponent("fontconfig", isDirectory: true)
    }

    /// Where scripts/fetch-parity-fonts.sh puts the pinned parity fonts: `$TKZMUX_PARITY_FONTS`
    /// when it is absolute, else `$XDG_CACHE_HOME/tkzmux/parity-fonts`.
    public static var defaultParityFontDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["TKZMUX_PARITY_FONTS"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return AppPaths.cache.appendingPathComponent("parity-fonts", isDirectory: true)
    }

    /// The bundled fonts, then /usr/share/fonts, then ~/.local/share/fonts.
    public static func system(bundled: [URL],
                              home: URL = AppPaths.home,
                              cacheDirectory: URL = defaultCacheDirectory) -> FontconfigConfiguration {
        FontconfigConfiguration(
            fontDirectories: bundled + [
                URL(fileURLWithPath: "/usr/share/fonts", isDirectory: true),
                home.appendingPathComponent(".local/share/fonts", isDirectory: true),
            ],
            cacheDirectory: cacheDirectory)
    }

    /// The bundled fonts and the pinned parity test fonts, and nothing else.
    public static func parity(bundled: [URL],
                              testFonts: URL,
                              cacheDirectory: URL = defaultCacheDirectory) -> FontconfigConfiguration {
        FontconfigConfiguration(fontDirectories: bundled + [testFonts], cacheDirectory: cacheDirectory)
    }

    /// Font formats that never enter the fallback lists: bitmap formats (no outline to place at a
    /// fractional size) and the PostScript formats HarfBuzz cannot read tables from.
    static let rejectedFormats = ["BDF", "PCF", "Windows FNT", "PFR", "Type 1", "CID Type 1", "Type 42"]

    /// The whole configuration document. Pure, so its content is tested directly.
    public var xml: String {
        var lines = [
            #"<?xml version="1.0"?>"#,
            #"<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">"#,
            "<fontconfig>",
        ]
        for directory in fontDirectories {
            lines.append("  <dir>\(Self.escaped(directory.standardizedFileURL.path))</dir>")
        }
        lines.append("  <cachedir>\(Self.escaped(cacheDirectory.standardizedFileURL.path))</cachedir>")
        lines.append("  <selectfont><rejectfont>")
        for format in Self.rejectedFormats {
            lines.append(#"    <pattern><patelt name="fontformat"><string>\#(format)</string></patelt></pattern>"#)
        }
        lines.append("  </rejectfont></selectfont>")
        // Never rescan behind the lists' back: a font installed mid-session shows up next launch.
        lines.append("  <config><rescan><int>0</int></rescan></config>")
        lines.append("</fontconfig>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }
}
