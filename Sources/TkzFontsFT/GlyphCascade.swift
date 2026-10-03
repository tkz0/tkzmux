// GlyphCascade — which face draws a cluster of chrome text, and its advance in points (WOR-312 S7).
//
// The chrome's version of the terminal's face resolution, in the same order: the primary faces
// (chrome mono: the bundled JetBrains Mono Regular, opened directly; chrome UI: Inter, WOR-312 S8),
// then the bundled symbol subset (`BundledSymbols`), then the private fontconfig configuration.
// A cluster's face must cover every non-ignorable scalar in it, and a cluster asking for emoji
// presentation goes to the colour list first (the subset only when nothing there covers it). The
// subset never is colour, so a bare ✳ stays monochrome.
//
// Advances are linear: hmtx in font units × point size / unitsPerEm, never hinted, the way an
// NSFont's advances come out at a fractional size. They feed truncation and wrap decisions
// (`detailWraps`, the status bar), which is why the subset's hmtx is fitted to the Mac's.
//
// Laying the text out (tracking, kerning, ellipsis, wrapping) is WOR-316/317; this only answers
// "which face, which glyph, how wide". The library and faces live in a non-Sendable owner behind a
// `Mutex`; results are cached per cluster, so a repeated lookup makes no fontconfig call.

import CFreeType
import Foundation
import Synchronization
import TkzRenderCore

public final class GlyphCascade: Sendable {
    /// Where a cluster's face came from.
    public enum Source: Sendable, Hashable {
        /// `primaryFiles[index]`.
        case primary(Int)
        /// The bundled symbol subset.
        case symbols
        /// A fontconfig font.
        case fallback(FallbackFace)
        /// Nothing covers it: the first primary face's `.notdef`.
        case missing
    }

    /// One resolved cluster.
    public struct Resolution: Sendable, Equatable {
        public let source: Source
        public let postScriptName: String
        public let isColor: Bool
        /// The nominal glyph of each non-ignorable scalar, before shaping.
        public let glyphs: [UInt32]
        /// Sum of the glyphs' hmtx advances, in em (font units / unitsPerEm).
        public let advanceEm: CGFloat

        /// True when a bundled face (a primary or the subset) draws the cluster.
        public var isBundled: Bool {
            switch source {
            case .primary, .symbols: true
            case .fallback, .missing: false
            }
        }

        /// The advance at `pointSize`, in points.
        public func advance(pointSize: CGFloat) -> CGFloat { advanceEm * pointSize }
    }

    public enum CascadeError: Error, Sendable, Equatable {
        case noPrimaryFace
        case bundledFontsNotFound
    }

    private let owner: Mutex<Owner>
    public let fallback: FontFallback

    /// Opens `primaryFiles` (best first) and `symbols`; nothing touches fontconfig until a cluster
    /// none of them covers.
    public init(primaryFiles: [URL], symbols: FallbackFace? = BundledSymbols.face, fallback: FontFallback = .system) throws {
        guard !primaryFiles.isEmpty else { throw CascadeError.noPrimaryFace }
        let library = try FreeTypeLibrary()
        var primaries: [FreeTypeFace] = []
        for url in primaryFiles { primaries.append(try FreeTypeFace(library: library, url: url)) }
        let symbolFace = try symbols.map { try FreeTypeFace(library: library, url: URL(fileURLWithPath: $0.path), index: $0.index) }
        self.fallback = fallback
        self.owner = Mutex(Owner(library: library, primaries: primaries, symbols: symbolFace, fallback: fallback))
    }

    /// The chrome's mono text: JetBrains Mono Regular, then the subset, then fontconfig. Chrome
    /// mono stays Regular at every weight, as on the Mac.
    public static func chromeMono(fallback: FontFallback = .system) throws -> GlyphCascade {
        guard let directory = BundledFonts.directory else { throw CascadeError.bundledFontsNotFound }
        return try GlyphCascade(primaryFiles: [directory.appendingPathComponent(BundledFonts.jetBrainsMonoFile(.regular))],
                                fallback: fallback)
    }

    /// Resolves one grapheme cluster.
    public func resolve(_ scalars: [Unicode.Scalar]) -> Resolution {
        owner.withLock { $0.resolve(scalars) }
    }

    /// Resolves one character (a grapheme cluster already).
    public func resolve(_ character: Character) -> Resolution {
        resolve(Array(character.unicodeScalars))
    }

    /// The advance of `text`, cluster by cluster, at `pointSize`, in points: no kerning, no tracking.
    public func advance(of text: String, pointSize: CGFloat) -> CGFloat {
        text.reduce(0) { $0 + resolve($1).advance(pointSize: pointSize) }
    }
}

// MARK: - The owner of the FreeType objects

/// Not Sendable: only ever used inside `GlyphCascade.owner.withLock`.
private final class Owner {
    let library: FreeTypeLibrary
    let primaries: [FreeTypeFace]
    let symbols: FreeTypeFace?
    let fallback: FontFallback
    private var opened: [FallbackFace: FreeTypeFace] = [:]
    private var unusable: Set<FallbackFace> = []
    private var cache: [[UInt32]: GlyphCascade.Resolution] = [:]

    init(library: FreeTypeLibrary, primaries: [FreeTypeFace], symbols: FreeTypeFace?, fallback: FontFallback) {
        self.library = library
        self.primaries = primaries
        self.symbols = symbols
        self.fallback = fallback
    }

    func resolve(_ scalars: [Unicode.Scalar]) -> GlyphCascade.Resolution {
        let key = scalars.map(\.value)
        if let cached = cache[key] { return cached }
        let resolution = resolveUncached(scalars)
        cache[key] = resolution
        return resolution
    }

    private func resolveUncached(_ scalars: [Unicode.Scalar]) -> GlyphCascade.Resolution {
        let needed = FontFallback.nonIgnorable(scalars)
        let wantsColor = FontFallback.wantsColor(scalars)
        if !needed.isEmpty, !wantsColor {
            for (index, face) in primaries.enumerated() {
                if let resolution = resolution(needed, face: face, source: .primary(index), isColor: false) { return resolution }
            }
            if let symbols, let resolution = resolution(needed, face: symbols, source: .symbols, isColor: false) {
                return resolution
            }
        }
        if !needed.isEmpty {
            var excluded = unusable
            let list: FontFallback.List = wantsColor ? .color : .text(.regular)
            while let descriptor = fallback.face(covering: needed, in: list, excluding: excluded) {
                guard let face = open(descriptor) else {
                    excluded.insert(descriptor)
                    continue
                }
                // The fallback's pick may cover only the first scalar; it still draws the cluster.
                let glyphs = needed.map { FT_Get_Char_Index(face.handle, FT_ULong($0.value)) }
                return GlyphCascade.Resolution(source: .fallback(descriptor),
                                               postScriptName: descriptor.postScriptName,
                                               isColor: descriptor.isColor, glyphs: glyphs,
                                               advanceEm: advanceEm(glyphs, face: face))
            }
        }
        // As in the terminal: an emoji request nothing else covers still gets the subset's glyph.
        if wantsColor, !needed.isEmpty, let symbols,
           let resolution = resolution(needed, face: symbols, source: .symbols, isColor: false) {
            return resolution
        }
        let primary = primaries[0]
        let glyphs = needed.map { FT_Get_Char_Index(primary.handle, FT_ULong($0.value)) }
        return GlyphCascade.Resolution(source: .missing, postScriptName: primary.postScriptName ?? "",
                                       isColor: false, glyphs: glyphs, advanceEm: advanceEm(glyphs, face: primary))
    }

    /// `face` drawing `needed`, when it covers every scalar.
    private func resolution(_ needed: [Unicode.Scalar], face: FreeTypeFace, source: GlyphCascade.Source,
                            isColor: Bool) -> GlyphCascade.Resolution? {
        var glyphs: [UInt32] = []
        for scalar in needed {
            let glyph = FT_Get_Char_Index(face.handle, FT_ULong(scalar.value))
            guard glyph != 0 else { return nil }
            glyphs.append(glyph)
        }
        return GlyphCascade.Resolution(source: source, postScriptName: face.postScriptName ?? "",
                                       isColor: isColor, glyphs: glyphs, advanceEm: advanceEm(glyphs, face: face))
    }

    /// Sum of hmtx advances in em. A combining mark's zero advance adds nothing, as shaped.
    private func advanceEm(_ glyphs: [UInt32], face: FreeTypeFace) -> CGFloat {
        let unitsPerEm = CGFloat(max(1, face.unitsPerEm))
        var total: CGFloat = 0
        for glyph in glyphs {
            var advance: FT_Fixed = 0
            // NO_SCALE: font units straight from hmtx, no size and no hinting involved.
            if FT_Get_Advance(face.handle, FT_UInt(glyph), FT_Int32(FT_LOAD_NO_SCALE), &advance) == 0 {
                total += CGFloat(advance) / unitsPerEm
            }
        }
        return total
    }

    private func open(_ descriptor: FallbackFace) -> FreeTypeFace? {
        if let face = opened[descriptor] { return face }
        guard !unusable.contains(descriptor) else { return nil }
        guard let face = try? FreeTypeFace(library: library, url: URL(fileURLWithPath: descriptor.path),
                                           index: descriptor.index) else {
            unusable.insert(descriptor)
            return nil
        }
        opened[descriptor] = face
        return face
    }
}
