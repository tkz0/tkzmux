import CoreText
import Foundation
import Testing
@testable import TkzTerminalRender

@Suite("FontSet")
struct FontSetTests {

    @Test("the bundled JetBrains Mono files reach Bundle.module and register with the process")
    func bundledFontsRegister() {
        let registration = FontSet.registration
        #expect(registration.failures.isEmpty)
        #expect(registration.directory != nil)

        let names = Set(registration.registeredFiles.map(\.lastPathComponent))
        #expect(names == [
            "JetBrainsMono-Bold.ttf",
            "JetBrainsMono-BoldItalic.ttf",
            "JetBrainsMono-Italic.ttf",
            "JetBrainsMono-Regular.ttf",
        ])
        // Every registered file must come from the module bundle, not from ~/Library/Fonts.
        let directory = registration.directory?.standardizedFileURL.path ?? ""
        for url in registration.registeredFiles {
            #expect(url.standardizedFileURL.path.hasPrefix(directory))
        }
    }

    @Test("OFL.txt ships alongside the fonts (SIL OFL 1.1 requires the license to travel with them)")
    func licenseIsBundled() throws {
        let url = try #require(FontSet.bundledLicenseURL)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("SIL OPEN FONT LICENSE"))
    }

    @Test("JetBrains Mono resolves to its four static faces in a swift-test process")
    func resolvesAllFaces() {
        let fonts = FontSet(pointSize: 12.5, scale: 2)
        #expect(fonts.resolvedFamily == "JetBrains Mono")
        #expect(fonts.usedFallbackFamily == false)
        #expect(fonts.postScriptName(for: .regular) == "JetBrainsMono-Regular")
        #expect(fonts.postScriptName(for: .bold) == "JetBrainsMono-Bold")
        #expect(fonts.postScriptName(for: .italic) == "JetBrainsMono-Italic")
        #expect(fonts.postScriptName(for: .boldItalic) == "JetBrainsMono-BoldItalic")
        #expect(fonts.needsSyntheticBold == false)
        #expect(fonts.needsSyntheticItalic == false)
        // Fonts are built in device pixels.
        #expect(fonts.pixelSize == 25)
        #expect(CTFontGetSize(fonts.font(for: .regular)) == 25)
    }

    @Test("an unknown family falls back instead of silently substituting Helvetica")
    func fallsBackToMenlo() {
        let fonts = FontSet(family: "Definitely Not A Font \(UUID().uuidString)",
                            fallback: "Menlo", pointSize: 13, scale: 2)
        #expect(fonts.usedFallbackFamily)
        #expect(fonts.resolvedFamily == "Menlo")
        #expect(fonts.postScriptName(for: .regular) == "Menlo-Regular")
    }

    @Test("per-scalar fallback picks the right font and flags colour fonts")
    func perScalarFallback() {
        let fonts = FontSet(pointSize: 12.5, scale: 2)

        let latin = fonts.font(for: "A" as Unicode.Scalar)
        #expect(CTFontCopyPostScriptName(latin) as String == "JetBrainsMono-Regular")
        #expect(fonts.isColorFont(latin) == false)

        // The CJK fallback is locale-dependent (PingFang / Hiragino); only assert what is stable.
        let han = fonts.font(for: Unicode.Scalar(0x4F60)!)  // 你
        #expect(CTFontCopyPostScriptName(han) as String != "JetBrainsMono-Regular")
        #expect(fonts.isColorFont(han) == false)

        let emoji = fonts.font(for: Unicode.Scalar(0x1F600)!)  // 😀
        #expect(CTFontCopyPostScriptName(emoji) as String == "AppleColorEmoji")
        #expect(fonts.isColorFont(emoji))
    }

    @Test("the fallback cache returns the same font for a repeated scalar")
    func fallbackCacheIsStable() {
        let fonts = FontSet(pointSize: 12.5, scale: 2)
        let first = CTFontCopyPostScriptName(fonts.font(for: Unicode.Scalar(0x1F600)!)) as String
        let second = CTFontCopyPostScriptName(fonts.font(for: Unicode.Scalar(0x1F600)!)) as String
        #expect(first == second)
    }
}
