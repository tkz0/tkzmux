// RenderingRulesTests — the two FreeType settings parity depends on (WOR-312 S3): stem darkening is
// off whatever `FREETYPE_PROPERTIES` says, and no glyph is ever loaded hinted.
//
// The environment test sets `FREETYPE_PROPERTIES` in this process for the length of one
// `FT_Init_FreeType` call and restores it. The suite is serialized, and the repo's test runs are
// serial (`swift test --no-parallel`, docs/linux/build.md), so nothing reads the environment
// meanwhile.

import CFreeType
import Foundation
import Testing
import TkzRenderCore
@testable import TkzFontsFT

@Suite("FreeType rendering rules", .serialized)
struct RenderingRulesTests {

    // MARK: Stem darkening

    @Test("no-stem-darkening is TRUE on cff, type1, t1cid and autofitter")
    func stemDarkeningOff() throws {
        let faces = try TerminalFaces(pointSize: 14, scale: 2)
        for module in FreeTypeLibrary.darkeningModules {
            #expect(faces.isStemDarkeningDisabled(module: module) == true, "\(module)")
        }
    }

    @Test("FREETYPE_PROPERTIES cannot turn stem darkening back on")
    func environmentCannotOverride() throws {
        let properties = FreeTypeLibrary.darkeningModules
            .map { "\($0):\(FreeTypeLibrary.noStemDarkening)=0" }
            .joined(separator: " ")

        try withEnvironment("FREETYPE_PROPERTIES", properties) {
            // Control: a bare FT_Init_FreeType does apply the variable, so the check below is not
            // vacuous (FreeType's own default is already TRUE for all four).
            var bare: FT_Library?
            try #require(FT_Init_FreeType(&bare) == 0)
            let bareLibrary = try #require(bare)
            defer { FT_Done_FreeType(bareLibrary) }
            for module in FreeTypeLibrary.darkeningModules {
                #expect(FreeTypeLibrary.isStemDarkeningDisabled(bareLibrary, module: module) == false,
                        "the environment did not reach \(module)")
            }

            let library = try FreeTypeLibrary()
            for module in FreeTypeLibrary.darkeningModules {
                #expect(library.isStemDarkeningDisabled(module: module) == true, "\(module)")
            }
        }
    }

    // MARK: Hinting

    /// The cap height of JetBrains Mono's 'H' in font units, read unscaled.
    private func unitsHeightOfH(_ face: FreeTypeFace) throws -> CGFloat {
        let glyph = FT_Get_Char_Index(face.handle, FT_ULong(("H" as Unicode.Scalar).value))
        try #require(FT_Load_Glyph(face.handle, glyph, FT_Int32(FT_LOAD_NO_SCALE)) == 0)
        var box = FT_BBox()
        try #require(FT_Outline_Get_BBox(&face.handle.pointee.glyph.pointee.outline, &box) == 0)
        return CGFloat(box.yMax - box.yMin)
    }

    @Test("an 'H' at 22.4 px is 22.4 px tall in proportion, not 22 (no integer ppem, no hinting)")
    func unhintedHeight() throws {
        let pixelSize: CGFloat = 14 * 1.6
        let library = try FreeTypeLibrary()
        let directory = try #require(BundledFonts.directory)
        let face = try FreeTypeFace(library: library,
                                    url: directory.appendingPathComponent(BundledFonts.jetBrainsMonoFile(.regular)))
        try face.requestPixelSize(pixelSize)
        let units = try unitsHeightOfH(face)
        #expect(units == 730)  // OS/2 sCapHeight; the arithmetic below assumes it

        let outline = try #require(face.outlineMetrics(of: "H"))
        let exact = units * pixelSize / 1000         // 16.352
        let integerPpem = units * 22 / 1000          // 16.06: what head.flags bit 3 would give
        // Each outline point is rounded to 1/64 px, so the box is within 1/64 of the exact height.
        #expect(abs(outline.height - exact) <= 1.0 / 64, "height \(outline.height), exact \(exact)")
        #expect(abs(outline.height - integerPpem) > 0.25)
        // The advance is unrounded too: 600 units at 22.4 px.
        #expect(abs(outline.advance - 13.44) < 0.001, "advance \(outline.advance)")

        // The same glyph loaded with FreeType's defaults (hinted) does not pass the check above,
        // so a hinted load in `outlineMetrics` would fail this test.
        let glyph = FT_Get_Char_Index(face.handle, FT_ULong(("H" as Unicode.Scalar).value))
        try #require(FT_Load_Glyph(face.handle, glyph, FT_Int32(FT_LOAD_DEFAULT)) == 0)
        var hinted = FT_BBox()
        try #require(FT_Outline_Get_BBox(&face.handle.pointee.glyph.pointee.outline, &hinted) == 0)
        let hintedHeight = CGFloat(hinted.yMax - hinted.yMin) / 64
        #expect(abs(hintedHeight - exact) > 1.0 / 64, "hinted height \(hintedHeight)")
    }

    @Test("the outline load flags never hint", arguments: FontStyle.allCases)
    func loadFlags(style: FontStyle) throws {
        #expect(FreeTypeFace.loadFlags & FT_Int32(FT_LOAD_NO_HINTING) != 0)
        #expect(FreeTypeFace.loadFlags & FT_Int32(FT_LOAD_FORCE_AUTOHINT) == 0)

        // Every style scales 'H' proportionally at 22.4 px.
        let faces = try TerminalFaces(pointSize: 14, scale: 1.6)
        let outline = try #require(faces.outlineMetrics(of: "H", style: style))
        #expect(abs(outline.height - 730 * faces.pixelSize / 1000) <= 1.0 / 64,
                "\(style): \(outline.height)")
    }
}

/// Runs `body` with `name` set to `value`, then restores the previous value (or unsets it).
private func withEnvironment(_ name: String, _ value: String, _ body: () throws -> Void) throws {
    let previous = getenv(name).map { String(cString: $0) }
    setenv(name, value, 1)
    defer {
        if let previous { setenv(name, previous, 1) } else { unsetenv(name) }
    }
    try body()
}
