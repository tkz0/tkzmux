// FreeTypeFace — one `FT_Face`: its size, its raw metric tables and its unhinted outlines (WOR-312 S3).
//
// Size. `FT_Request_Size` with `FT_SIZE_REQUEST_TYPE_SCALES` hands FreeType the font-unit → 26.6
// scale directly, so a 22.4 px face scales by exactly 22.4 / unitsPerEm (to 16.16 precision)
// instead of going through a 26.6 character size.
//
// Hinting. Every load uses `loadFlags`, which carries `FT_LOAD_NO_HINTING`. Unhinted, FreeType
// scales outlines fractionally, so head.flags bit 3 (integer ppem, which JetBrains Mono sets) has
// no effect: a 22.4 px 'H' is 22.4 px tall in proportion, not 22 px. A hinted load would also
// grid-fit the outline. Neither matches CoreText, so nothing here ever loads hinted, and Ghostty's
// light-hinting default is deliberately not copied.
//
// Metrics. `tables()` reads head, hhea, post and OS/2 through `FT_Get_Sfnt_Table` and the ASCII
// advances in font units, for TkzRenderCore's shared CellMetrics formula. Never `FT_Size_Metrics`
// (ascender/descender rounded outwards to whole pixels) and never `face->underline_position`
// (half the thickness already subtracted); see FontTables.swift.
//
// Not Sendable: owned with its library by `TerminalFaces`' owner, behind a `Mutex`.

import CFreeType
import Foundation
import TkzRenderCore

/// An unhinted glyph outline at the face's current size, in device pixels, y positive up.
public struct GlyphOutlineMetrics: Sendable, Equatable {
    /// The exact outline bounding box (`FT_Outline_Get_BBox`, not the control-point box).
    public let xMin: CGFloat
    public let yMin: CGFloat
    public let xMax: CGFloat
    public let yMax: CGFloat
    /// The horizontal advance, from `linearHoriAdvance` (16.16, unrounded).
    public let advance: CGFloat

    public var width: CGFloat { xMax - xMin }
    public var height: CGFloat { yMax - yMin }
}

final class FreeTypeFace {
    /// The load flags for every outline this module draws or measures. `FT_LOAD_NO_HINTING` is the
    /// one that matters (see the file header); `FT_LOAD_NO_BITMAP` keeps an embedded bitmap strike
    /// from replacing the outline at some size. Colour bitmaps (CBDT) get their own flags
    /// (`FreeTypeRasterizer.colorLoadFlags`).
    static let loadFlags = FT_Int32(FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP)

    /// Holds the library open for as long as the face is (faces must be freed first).
    private let library: FreeTypeLibrary
    let handle: FT_Face
    /// The size last requested with `requestPixelSize`, 0 before the first request.
    private(set) var pixelSize: CGFloat = 0

    init(library: FreeTypeLibrary, url: URL, index: Int = 0) throws(FreeTypeError) {
        var face: FT_Face?
        let error = FT_New_Face(library.handle, url.path, FT_Long(index), &face)
        guard error == 0, let face else { throw FreeTypeError(call: "FT_New_Face(\(url.lastPathComponent))", code: error) }
        self.library = library
        self.handle = face
    }

    deinit {
        FT_Done_Face(handle)
    }

    var unitsPerEm: Int { Int(handle.pointee.units_per_EM) }

    /// The PostScript name (`FT_Get_Postscript_Name`), the name dumps compare across platforms.
    var postScriptName: String? {
        FT_Get_Postscript_Name(handle).map { String(cString: $0) }
    }

    /// The 16.16 scale for `pixelSize`: font units → 26.6 pixels, so `pixelSize * 64 / unitsPerEm`.
    static func scale(pixelSize: CGFloat, unitsPerEm: Int) -> FT_Fixed {
        let pixelsPerUnit = FontTables.pixelsPerUnit(pixelSize: pixelSize, unitsPerEm: CGFloat(unitsPerEm))
        return FT_Fixed((pixelsPerUnit * 64 * 65536).rounded())
    }

    /// Sizes the face to `pixelSize` device pixels per em with an exact scale request.
    func requestPixelSize(_ pixelSize: CGFloat) throws(FreeTypeError) {
        let scale = Self.scale(pixelSize: pixelSize, unitsPerEm: unitsPerEm)
        var request = FT_Size_RequestRec(type: FT_SIZE_REQUEST_TYPE_SCALES,
                                         width: scale, height: scale,
                                         horiResolution: 0, vertResolution: 0)
        let error = FT_Request_Size(handle, &request)
        guard error == 0 else { throw FreeTypeError(call: "FT_Request_Size", code: error) }
        self.pixelSize = pixelSize
    }

    /// The raw head/hhea/post/OS/2 values and the widest ASCII advance, in font units. `nil` for a
    /// face without head or hhea (not an sfnt font).
    func tables() -> FontTables? {
        guard let head = sfntTable(FT_SFNT_HEAD, as: TT_Header.self),
              let hhea = sfntTable(FT_SFNT_HHEA, as: TT_HoriHeader.self) else { return nil }
        let post = sfntTable(FT_SFNT_POST, as: TT_Postscript.self)
        // FreeType returns no OS/2 table for a font without one (it fakes version 0xFFFF inside).
        let os2 = sfntTable(FT_SFNT_OS2, as: TT_OS2.self)

        let strikeout = os2.map { OS2Strikeout(size: $0.yStrikeoutSize, position: $0.yStrikeoutPosition) }
        let xHeight: Int
        if let os2, os2.version >= 2 {
            xHeight = Int(os2.sxHeight)
        } else {
            xHeight = unscaledHeight(of: "x") ?? 0
        }
        return FontTables(unitsPerEm: Int(head.Units_Per_EM),
                          ascender: Int(hhea.Ascender),
                          descender: Int(hhea.Descender),
                          lineGap: Int(hhea.Line_Gap),
                          underlinePosition: Int(post?.underlinePosition ?? 0),
                          underlineThickness: Int(post?.underlineThickness ?? 0),
                          strikeout: strikeout,
                          xHeight: xHeight,
                          maxASCIIAdvance: maxASCIIAdvance())
    }

    /// The widest hmtx advance, in font units, over the glyphs for U+0020…U+007E. A character the
    /// face lacks maps to glyph 0 and counts with `.notdef`'s advance, as CoreText's
    /// `CTFontGetAdvancesForGlyphs` counts it on the Mac.
    func maxASCIIAdvance() -> Int {
        var widest: FT_Fixed = 0
        for code in 0x20...0x7E {
            let glyph = FT_Get_Char_Index(handle, FT_ULong(code))
            var advance: FT_Fixed = 0
            // NO_SCALE: font units straight from hmtx, no size involved.
            guard FT_Get_Advance(handle, glyph, FT_Int32(FT_LOAD_NO_SCALE), &advance) == 0 else { continue }
            widest = max(widest, advance)
        }
        return Int(widest)
    }

    /// The unhinted outline metrics of `scalar` at the current size, or `nil` when the face has no
    /// glyph for it, the load fails, or the glyph is not an outline.
    func outlineMetrics(of scalar: Unicode.Scalar) -> GlyphOutlineMetrics? {
        let glyph = FT_Get_Char_Index(handle, FT_ULong(scalar.value))
        guard glyph != 0, FT_Load_Glyph(handle, glyph, Self.loadFlags) == 0 else { return nil }
        let slot = handle.pointee.glyph!
        guard slot.pointee.format == FT_GLYPH_FORMAT_OUTLINE else { return nil }
        var box = FT_BBox()
        guard FT_Outline_Get_BBox(&slot.pointee.outline, &box) == 0 else { return nil }
        func pixels(_ value: FT_Pos) -> CGFloat { CGFloat(value) / 64 }
        return GlyphOutlineMetrics(xMin: pixels(box.xMin), yMin: pixels(box.yMin),
                                   xMax: pixels(box.xMax), yMax: pixels(box.yMax),
                                   advance: CGFloat(slot.pointee.linearHoriAdvance) / 65536)
    }

    /// The height of `character`'s outline in font units (no size involved), for the x-height
    /// fallback of a pre-version-2 OS/2 table.
    private func unscaledHeight(of character: Unicode.Scalar) -> Int? {
        let glyph = FT_Get_Char_Index(handle, FT_ULong(character.value))
        guard glyph != 0,
              FT_Load_Glyph(handle, glyph, FT_Int32(FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING)) == 0,
              let slot = handle.pointee.glyph,
              slot.pointee.format == FT_GLYPH_FORMAT_OUTLINE else { return nil }
        var box = FT_BBox()
        guard FT_Outline_Get_BBox(&slot.pointee.outline, &box) == 0 else { return nil }
        return Int(box.yMax)
    }

    private func sfntTable<Table>(_ tag: FT_Sfnt_Tag, as: Table.Type) -> Table? {
        FT_Get_Sfnt_Table(handle, tag).map { $0.assumingMemoryBound(to: Table.self).pointee }
    }

    // MARK: - Faces and colour (WOR-312 S5)

    private func hasFlag(_ flag: Int) -> Bool {
        handle.pointee.face_flags & FT_Long(flag) != 0
    }

    /// Outlines that scale to any size (false for a bitmap-only face like CBDT Noto Color Emoji).
    var isScalable: Bool { hasFlag(FT_FACE_FLAG_SCALABLE) }
    /// The face carries embedded bitmap strikes (CBDT/CBLC, sbix, EBDT).
    var hasBitmapStrikes: Bool { hasFlag(FT_FACE_FLAG_FIXED_SIZES) && handle.pointee.num_fixed_sizes > 0 }
    /// The face's own style says bold (`FT_STYLE_FLAG_BOLD`, from OS/2 and head.macStyle).
    var isBold: Bool { handle.pointee.style_flags & FT_Long(FT_STYLE_FLAG_BOLD) != 0 }

    /// Selects the bitmap strike for drawing at `pixelSize`: the smallest at least that large, so
    /// drawing only ever scales down, else the largest. Returns the strike's y ppem in pixels.
    func selectStrike(for pixelSize: CGFloat) -> CGFloat? {
        guard hasBitmapStrikes, let sizes = handle.pointee.available_sizes else { return nil }
        let count = Int(handle.pointee.num_fixed_sizes)
        let ppems = (0..<count).map { CGFloat(sizes[$0].y_ppem) / 64 }
        let index = ppems.indices.filter { ppems[$0] >= pixelSize }.min { ppems[$0] < ppems[$1] }
            ?? ppems.indices.max { ppems[$0] < ppems[$1] }!
        guard FT_Select_Size(handle, FT_Int(index)) == 0 else { return nil }
        return ppems[index]
    }

    /// True when `glyph`'s only colour data is COLR version 1: no COLRv0 layers, a v1 paint, and no
    /// bitmap in any strike. FreeType reports such a paint graph but cannot draw it (drawing it
    /// takes `hb_raster_paint`, which waits on a WOR-299 allow-list decision), so the glyph would
    /// come out blank: the colour fallback skips the face (ClusterShaper).
    func isCOLRv1Only(glyph: UInt32) -> Bool {
        var layerGlyph: FT_UInt = 0
        var colorIndex: FT_UInt = 0
        var iterator = FT_LayerIterator(num_layers: 0, layer: 0, p: nil)
        if FT_Get_Color_Glyph_Layer(handle, FT_UInt(glyph), &layerGlyph, &colorIndex, &iterator) != 0 { return false }
        var paint = FT_OpaquePaint(p: nil, insert_root_transform: 0)
        guard FT_Get_Color_Glyph_Paint(handle, FT_UInt(glyph), FT_COLOR_INCLUDE_ROOT_TRANSFORM, &paint) != 0 else {
            return false
        }
        return !hasStrikeBitmap(glyph: glyph)
    }

    /// Whether a bitmap strike has `glyph`. Selecting a strike resizes the face, so a scalable face
    /// is sized back to `pixelSize` afterwards.
    private func hasStrikeBitmap(glyph: UInt32) -> Bool {
        guard hasBitmapStrikes, selectStrike(for: pixelSize) != nil else { return false }
        defer { if isScalable && pixelSize > 0 { try? requestPixelSize(pixelSize) } }
        let flags = FT_Int32(FT_LOAD_COLOR | FT_LOAD_SBITS_ONLY)
        return FT_Load_Glyph(handle, FT_UInt(glyph), flags) == 0
            && handle.pointee.glyph.pointee.format == FT_GLYPH_FORMAT_BITMAP
    }
}
