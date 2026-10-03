// TkzFontsFT — the Linux font stack behind the TkzRenderCore font seam: FreeType for faces, metrics
// and rasterization, HarfBuzz for cluster shaping, fontconfig for fallback (WOR-312).
//
// Linux only (Package.swift's Linux branch). Every pixel tkzmux draws on Linux comes through here,
// and parity with the Mac's CoreText masks and metrics (ADR-0003) depends on three rules:
//   - nothing from the desktop reaches the output: FreeType's stem darkening is switched off after
//     `FT_Init_FreeType`, overriding `FREETYPE_PROPERTIES`, and fallback uses a private `FcConfig`
//     that never reads /etc/fonts/conf.d (ADR-0002);
//   - glyphs are never hinted (`FreeTypeFace.loadFlags`), so outlines scale fractionally at
//     22.4 px instead of snapping to an integer ppem;
//   - cell metrics come from the raw hhea/post/OS/2 tables through TkzRenderCore's shared formula,
//     never from `FT_Size_Metrics` or `face->underline_position`.
//
// WOR-312 fills it in:
//   S3  the FreeType library, bundled faces and their metrics (FreeTypeLibrary.swift,
//       FreeTypeFace.swift, TerminalFaces.swift, BundledFonts.swift)
//   S4  the private FcConfig, fallback and HarfBuzz cluster shaping (FontconfigConfiguration.swift,
//       FontFallback.swift, ClusterShaper.swift; the pinned parity fonts are fetched by
//       scripts/fetch-parity-fonts.sh from Tests/Parity/Fonts/fonts.lock.json)
//   S5  the A8 rasterizer with dilation and synthetic bold, CBDT colour bitmaps and COLRv1
//       skipping (FreeTypeRasterizer.swift, Dilation.swift, ColorBitmapResampler.swift), the
//       `GlyphSource` conformance (FreeTypeGlyphSource.swift) and the Linux side of
//       `vtdump atlas --json` (AtlasDumper.swift)
//   S7  the bundled symbol subset, tried after the primary faces and before fontconfig
//       (BundledSymbols.swift, Resources/Symbols, written by scripts/make-symbol-subset.py), the
//       chrome's face cascade (GlyphCascade.swift) and the path-drawn SF Symbol stand-ins
//       (SymbolIcons.swift)
//   S6  the thicken calibration; S8 Inter for chrome text

import CFontconfig
import CFreeType
import CHarfBuzz

/// The versions of the three system libraries this process actually loaded, for logs and dumps.
public enum FontLibraryVersions {
    /// FreeType's runtime version, `major.minor.patch`, or `nil` when no library can be created.
    public static var freeType: String? {
        guard let library = try? FreeTypeLibrary() else { return nil }
        var major: FT_Int = 0, minor: FT_Int = 0, patch: FT_Int = 0
        FT_Library_Version(library.handle, &major, &minor, &patch)
        return "\(major).\(minor).\(patch)"
    }

    /// HarfBuzz's runtime version.
    public static var harfBuzz: String { String(cString: hb_version_string()) }

    /// fontconfig's runtime version (`FcGetVersion` encodes it as `major * 10000 + minor * 100 + revision`).
    public static var fontconfig: String {
        let version = FcGetVersion()
        return "\(version / 10000).\(version / 100 % 100).\(version % 100)"
    }
}
