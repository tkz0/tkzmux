// ClusterShaper — grapheme cluster → face + positioned glyphs, the Linux side of the Mac's
// GraphemeShaper (WOR-312 S4).
//
// Shaping is per cluster, never across cells, so there are no cross-cell ligatures.
//
// Face. A text cluster stays on the style's bundled face when that face covers every
// non-ignorable scalar; otherwise the bundled symbol subset (`BundledSymbols`, WOR-312 S7) draws it
// when it covers them all, and only then does `FontFallback`'s text list for the style resolve it.
// A cluster that asks for emoji presentation (`FontFallback.wantsColor`) goes to the colour list
// first, and to the subset if no colour or text font covers it. Nothing covering it at all leaves
// it on the bundled face, as `.notdef`. The subset has one regular face for every style, as a
// fallback font with no bold has on the Mac. One face draws the whole cluster, so a glyph is never
// drawn with a face other than the one that produced its id (the Mac's multi-run clusters, drawn
// with the first run's font, are a known divergence that stays).
//
// Glyphs. Fast path: one scalar the face maps, `FT_Get_Char_Index`. Otherwise `hb_shape` on the
// cluster with that face: `-liga,-calt` on outline faces, like the Mac's
// `kCTLigatureAttributeName = 0`, and default features on colour faces, whose ZWJ sequences,
// flags and keycaps are GSUB ligatures. The buffer's language is pinned to `und`, never the
// locale, so a `zh`/`ja` LANG cannot switch Noto Sans CJK's `locl` forms. HarfBuzz scales with its
// own OpenType functions (hmtx), independent of the FreeType size and of colour bitmap strikes.
//
// Faces. `FontFace` 0…3 are the bundled styles (`FontStyle.rawValue`); fallback faces are opened
// on first use and numbered from 4. Outline fallbacks are sized like the bundled faces; bitmap
// colour faces get their strike from the rasterizer (WOR-312 S5).
//
// COLRv1 (S5). A fallback whose glyphs for the cluster are COLRv1 only
// (`FreeTypeFace.isCOLRv1Only`) would rasterize blank, so it is skipped and the list continues:
// the next colour font, then the monochrome faces the colour list runs on into. A fallback FreeType
// cannot open is skipped the same way.
//
// Not Sendable: owned by `TerminalFaces`' owner, behind its `Mutex`, with the FreeType library.

import CFreeType
import CHarfBuzz
import Foundation
import TkzRenderCore

final class ClusterShaper {
    /// HarfBuzz scale units per device pixel: positions come back in 16.16 pixels.
    static let harfBuzzUnitsPerPixel: CGFloat = 65536

    private struct Key: Hashable {
        let scalars: [UInt32]
        let style: FontStyle
        let span: Int
    }

    private struct PrimaryGlyphKey: Hashable {
        let scalar: UInt32
        let style: FontStyle
    }

    private struct OpenedFace {
        let descriptor: FallbackFace
        let face: FreeTypeFace
    }

    private let library: FreeTypeLibrary
    private let primaries: [FontStyle: FreeTypeFace]
    private let fallback: FontFallback
    /// The bundled symbol subset, tried before `fallback` (`nil`: straight to fontconfig).
    private let symbols: FallbackFace?
    private let pixelSize: CGFloat

    private var cache: [Key: ShapedCluster] = [:]
    private var primaryGlyphs: [PrimaryGlyphKey: UInt32] = [:]
    /// The subset's glyph per scalar, 0 where it has none.
    private var symbolGlyphs: [UInt32: UInt32] = [:]
    private var opened: [OpenedFace] = []
    private var openedIndex: [FallbackFace: Int] = [:]
    /// Fallbacks FreeType could not open or size; never retried.
    private var unusable: Set<FallbackFace> = []
    /// `hb_font_t` per `FontFace.rawValue`.
    private var harfBuzzFonts: [UInt32: OpaquePointer] = [:]

    static let firstFallbackFace: UInt32 = 4

    init(library: FreeTypeLibrary, primaries: [FontStyle: FreeTypeFace], fallback: FontFallback,
         symbols: FallbackFace? = BundledSymbols.face, pixelSize: CGFloat) {
        self.library = library
        self.primaries = primaries
        self.fallback = fallback
        self.symbols = symbols
        self.pixelSize = pixelSize
    }

    deinit {
        for font in harfBuzzFonts.values { hb_font_destroy(font) }
    }

    /// Number of cached clusters (test/diagnostic hook).
    var cachedCount: Int { cache.count }

    // MARK: - Shaping

    func shape(_ scalars: [Unicode.Scalar], style: FontStyle, cellSpan: Int?) -> ShapedCluster {
        let span = cellSpan ?? CellSpan.guess(for: scalars)
        let key = Key(scalars: scalars.map(\.value), style: style, span: span)
        if let cached = cache[key] { return cached }
        let shaped = shapeUncached(scalars, style: style, span: span)
        cache[key] = shaped
        return shaped
    }

    private func shapeUncached(_ scalars: [Unicode.Scalar], style: FontStyle, span: Int) -> ShapedCluster {
        // A fallback that cannot draw the cluster's glyphs (COLRv1 only) is skipped and the next
        // one in the list tried; the colour list runs on into monochrome faces after the colour ones.
        var skipped: Set<FallbackFace> = []
        while true {
            let (handle, face, isColor, descriptor) = resolve(scalars, style: style, skipping: skipped)
            let glyphs = glyphs(for: scalars, handle: handle, face: face, isColor: isColor)
            if let descriptor, glyphs.contains(where: { face.isCOLRv1Only(glyph: $0.glyph.rawValue) }) {
                skipped.insert(descriptor)
                continue
            }
            return ShapedCluster(face: handle, glyphs: glyphs, isColor: isColor, cellSpan: span)
        }
    }

    private func glyphs(for scalars: [Unicode.Scalar], handle: FontFace, face: FreeTypeFace, isColor: Bool) -> [ClusterGlyph] {
        // Fast path: one scalar the face maps directly.
        if scalars.count == 1 {
            let glyph = FT_Get_Char_Index(face.handle, FT_ULong(scalars[0].value))
            if glyph != 0 { return [ClusterGlyph(glyph: GlyphID(rawValue: glyph))] }
        }
        return harfBuzzShape(scalars, face: handle, isColor: isColor)
    }

    // MARK: - Face resolution

    /// The face for a cluster, skipping the fallbacks in `skipped`; the descriptor is `nil` for a
    /// bundled face.
    private func resolve(_ scalars: [Unicode.Scalar], style: FontStyle,
                         skipping skipped: Set<FallbackFace>) -> (FontFace, FreeTypeFace, Bool, FallbackFace?) {
        let primaryHandle = FontFace(rawValue: UInt32(style.rawValue))
        let primary = primaries[style]!
        let needed = FontFallback.nonIgnorable(scalars)
        let wantsColor = FontFallback.wantsColor(scalars)

        if !wantsColor, needed.allSatisfy({ primaryGlyph($0, style: style) != 0 }) {
            return (primaryHandle, primary, false, nil)
        }
        if !wantsColor, let resolved = resolveSymbols(needed, skipping: skipped) { return resolved }
        if !needed.isEmpty {
            let list: FontFallback.List = wantsColor ? .color : .text(style)
            var excluded = skipped.union(unusable)
            while let descriptor = fallback.face(covering: needed, in: list, excluding: excluded) {
                guard let index = open(descriptor) else {
                    excluded.insert(descriptor)
                    continue
                }
                let handle = FontFace(rawValue: Self.firstFallbackFace + UInt32(index))
                return (handle, opened[index].face, descriptor.isColor, descriptor)
            }
        }
        if wantsColor, let resolved = resolveSymbols(needed, skipping: skipped) { return resolved }
        return (primaryHandle, primary, false, nil)
    }

    /// The bundled subset, when it covers every scalar in `needed` (none empty) and has not been
    /// skipped (a `symbols:` font with COLRv1-only glyphs would otherwise be retried forever). No
    /// fontconfig.
    private func resolveSymbols(_ needed: [Unicode.Scalar],
                                skipping skipped: Set<FallbackFace>) -> (FontFace, FreeTypeFace, Bool, FallbackFace?)? {
        guard let symbols, !needed.isEmpty, !skipped.contains(symbols), let index = open(symbols) else { return nil }
        let face = opened[index].face
        for scalar in needed {
            let glyph = symbolGlyphs[scalar.value] ?? FT_Get_Char_Index(face.handle, FT_ULong(scalar.value))
            symbolGlyphs[scalar.value] = glyph
            if glyph == 0 { return nil }
        }
        return (FontFace(rawValue: Self.firstFallbackFace + UInt32(index)), face, false, symbols)
    }

    private func primaryGlyph(_ scalar: Unicode.Scalar, style: FontStyle) -> UInt32 {
        let key = PrimaryGlyphKey(scalar: scalar.value, style: style)
        if let cached = primaryGlyphs[key] { return cached }
        let glyph = FT_Get_Char_Index(primaries[style]!.handle, FT_ULong(scalar.value))
        primaryGlyphs[key] = glyph
        return glyph
    }

    /// Opens `descriptor` once; its index in `opened`, or `nil` when FreeType cannot use it.
    private func open(_ descriptor: FallbackFace) -> Int? {
        if let index = openedIndex[descriptor] { return index }
        guard !unusable.contains(descriptor) else { return nil }
        do {
            let face = try FreeTypeFace(library: library, url: URL(fileURLWithPath: descriptor.path),
                                        index: descriptor.index)
            if face.handle.pointee.face_flags & FT_Long(FT_FACE_FLAG_SCALABLE) != 0 {
                try face.requestPixelSize(pixelSize)
            }
            opened.append(OpenedFace(descriptor: descriptor, face: face))
            openedIndex[descriptor] = opened.count - 1
            return opened.count - 1
        } catch {
            unusable.insert(descriptor)
            return nil
        }
    }

    // MARK: - Faces by handle

    func freeTypeFace(_ handle: FontFace) -> FreeTypeFace? {
        if handle.rawValue < Self.firstFallbackFace {
            return FontStyle(rawValue: UInt8(handle.rawValue)).flatMap { primaries[$0] }
        }
        let index = Int(handle.rawValue - Self.firstFallbackFace)
        return opened.indices.contains(index) ? opened[index].face : nil
    }

    /// The PostScript name of `handle`'s face.
    func name(of handle: FontFace) -> String? {
        if handle.rawValue >= Self.firstFallbackFace {
            let index = Int(handle.rawValue - Self.firstFallbackFace)
            guard opened.indices.contains(index) else { return nil }
            let descriptor = opened[index].descriptor
            return descriptor.postScriptName.isEmpty ? opened[index].face.postScriptName : descriptor.postScriptName
        }
        return freeTypeFace(handle)?.postScriptName
    }

    /// The fallback descriptor behind `handle`, `nil` for a bundled face.
    func fallbackFace(of handle: FontFace) -> FallbackFace? {
        guard handle.rawValue >= Self.firstFallbackFace else { return nil }
        let index = Int(handle.rawValue - Self.firstFallbackFace)
        return opened.indices.contains(index) ? opened[index].descriptor : nil
    }

    // MARK: - HarfBuzz

    private static let outlineFeatures: [hb_feature_t] = ["-liga", "-calt"].map { text in
        var feature = hb_feature_t()
        _ = hb_feature_from_string(text, Int32(text.utf8.count), &feature)
        return feature
    }

    private func harfBuzzFont(_ handle: FontFace) -> OpaquePointer? {
        if let font = harfBuzzFonts[handle.rawValue] { return font }
        guard let face = freeTypeFace(handle), let hbFace = hb_ft_face_create_referenced(face.handle) else { return nil }
        defer { hb_face_destroy(hbFace) }
        guard let font = hb_font_create(hbFace) else { return nil }
        let scale = Int32((pixelSize * Self.harfBuzzUnitsPerPixel).rounded())
        hb_font_set_scale(font, scale, scale)
        // A named instance of a variable font lives in FC_INDEX's high 16 bits, 1-based.
        let instance = Int(face.handle.pointee.face_index) >> 16
        if instance > 0 { hb_font_set_var_named_instance(font, UInt32(instance - 1)) }
        harfBuzzFonts[handle.rawValue] = font
        return font
    }

    private func harfBuzzShape(_ scalars: [Unicode.Scalar], face handle: FontFace, isColor: Bool) -> [ClusterGlyph] {
        guard let font = harfBuzzFont(handle), let buffer = hb_buffer_create() else { return [] }
        defer { hb_buffer_destroy(buffer) }
        let codepoints = scalars.map(\.value)
        hb_buffer_add_codepoints(buffer, codepoints, Int32(codepoints.count), 0, Int32(codepoints.count))
        // `und`: HarfBuzz's default language system, whatever the locale says (interned, cheap).
        hb_buffer_set_language(buffer, hb_language_from_string("und", -1))
        hb_buffer_guess_segment_properties(buffer)
        if isColor {
            hb_shape(font, buffer, nil, 0)
        } else {
            Self.outlineFeatures.withUnsafeBufferPointer { features in
                hb_shape(font, buffer, features.baseAddress, UInt32(features.count))
            }
        }

        var count: UInt32 = 0
        guard let infos = hb_buffer_get_glyph_infos(buffer, &count),
              let positions = hb_buffer_get_glyph_positions(buffer, &count) else { return [] }
        var glyphs: [ClusterGlyph] = []
        glyphs.reserveCapacity(Int(count))
        var penX: Int32 = 0, penY: Int32 = 0
        for i in 0..<Int(count) {
            let position = positions[i]
            glyphs.append(ClusterGlyph(
                glyph: GlyphID(rawValue: infos[i].codepoint),
                xOffset: CGFloat(penX + position.x_offset) / Self.harfBuzzUnitsPerPixel,
                yOffset: CGFloat(penY + position.y_offset) / Self.harfBuzzUnitsPerPixel))
            penX += position.x_advance
            penY += position.y_advance
        }
        return glyphs
    }
}
