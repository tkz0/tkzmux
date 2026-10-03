// GlyphCache — grapheme cluster → atlas placement, over any `GlyphSource` (M1.4; core since
// WOR-311 S3).
//
// The single app-wide owner of the grayscale + colour atlases: there is one per renderer, shared by
// all sessions, and nothing else should construct a `GlyphAtlas`. The font stack sits behind the
// `GlyphSource` seam (CoreText on the Mac, FreeType and HarfBuzz on Linux), and only a cache miss
// goes through that existential: a hit is a dictionary lookup on a key built from the cluster.

/// A glyph placed in an atlas: everything `FrameBuilder` needs for one instance.
public struct CachedGlyph: Sendable, Equatable {
    public let slot: AtlasSlot
    public let bearingX: Int
    public let bearingTop: Int
    public let cellSpan: Int
    public var isColor: Bool { slot.kind == .color }

    public init(slot: AtlasSlot, bearingX: Int, bearingTop: Int, cellSpan: Int) {
        self.slot = slot
        self.bearingX = bearingX
        self.bearingTop = bearingTop
        self.cellSpan = cellSpan
    }
}

/// Shapes, rasterizes and packs grapheme clusters through a `GlyphSource`, and remembers where
/// each one went. Construct one per renderer; never build a `GlyphAtlas` yourself.
///
/// Not `Sendable`; lives on the render thread.
public final class GlyphCache {
    /// The font stack. Called only on a miss.
    public let source: any GlyphSource
    /// The source's cell geometry, read once: every frame asks for it.
    public let metrics: CellMetrics
    public let grayscale: GlyphAtlas
    public let color: GlyphAtlas

    /// The cache key for one grapheme cluster.
    ///
    /// Split into `scalar` + `rest` rather than one `[UInt32]` so the common case carries no array:
    /// a single-scalar cluster — all ASCII, and most everything else — hashes as three integers,
    /// where a `[UInt32]`-backed key had to allocate the array and then walk it to hash it. On a
    /// 125×40 grid that allocation happened once per cell per rebuilt row.
    private struct Key: Hashable {
        let scalar: UInt32
        /// The scalars after the first, or `nil` for a single-scalar cluster.
        let rest: [UInt32]?
        let style: FontStyle
        let span: Int

        init(scalar: Unicode.Scalar, style: FontStyle, span: Int) {
            self.scalar = scalar.value
            self.rest = nil
            self.style = style
            self.span = span
        }

        init(scalars: [Unicode.Scalar], style: FontStyle, span: Int) {
            self.scalar = scalars.first?.value ?? 0
            self.rest = scalars.count > 1 ? scalars.dropFirst().map(\.value) : nil
            self.style = style
            self.span = span
        }
    }

    /// What the cache knows about a cluster.
    ///
    /// `.empty` is the load-bearing case. A space — and any control character, and anything else
    /// whose glyph bounds come back empty from the source's `rasterize` — has nothing to draw, and
    /// the obvious spelling `entries[key] = nil` does not record that: in Swift it *removes* the
    /// key. So every blank-but-written cell used to re-shape and re-rasterize on every rebuilt row,
    /// re-entering CoreText (`CTFontGetBoundingRectsForGlyphs`) each time. Measured with
    /// `tkzmux-vtdump bench-frame --fill spaces` on a 125×40 grid, that was **4.40 ms per frame**
    /// for a screen that draws nothing at all — over half the 8.3 ms budget at 120 Hz.
    private enum CacheEntry {
        case glyph(CachedGlyph)
        /// Shaped and rasterized, and there is nothing to draw. Holds no atlas pixels, so unlike
        /// `.glyph` it survives an atlas rebuild untouched.
        case empty
    }
    private var entries: [Key: CacheEntry] = [:]

    /// - Parameters:
    ///   - grayscaleInitialSize/colorInitialSize: starting edge lengths; the kinds' design values
    ///     by default. Dumps and tests start small.
    public init(source: any GlyphSource,
                grayscaleInitialSize: Int? = nil,
                colorInitialSize: Int? = nil) {
        self.source = source
        self.metrics = source.metrics
        self.grayscale = GlyphAtlas(kind: .grayscale, initialSize: grayscaleInitialSize)
        self.color = GlyphAtlas(kind: .color, initialSize: colorInitialSize)
    }

    public func atlas(for kind: AtlasKind) -> GlyphAtlas {
        kind == .grayscale ? grayscale : color
    }

    /// Shapes, rasterizes and packs a single-scalar grapheme, or returns the cached placement.
    ///
    /// The hot entry point: `FrameBuilder` calls this for every cell whose cluster is one scalar,
    /// which avoids building a `[Unicode.Scalar]` per cell on top of avoiding the key array.
    /// Returns `nil` for anything with nothing to draw (space, control characters).
    ///
    /// Spelled `forScalar:` rather than `for:` on purpose: a string literal like `"A"` satisfies
    /// both `Unicode.Scalar` and `Character`, so a `for:` overload would make every existing
    /// `glyph(for: "A")` call ambiguous.
    public func glyph(forScalar scalar: Unicode.Scalar,
                      style: FontStyle = .regular,
                      cellSpan: Int? = nil) -> CachedGlyph? {
        if BoxSpriteGeometry.covers(scalar) {
            let key = Key(scalar: scalar, style: .regular, span: 1)
            switch validated(key) {
            case .glyph(let entry): return entry
            case .empty: return nil
            case nil: break
            }
            if let raster = source.sprite(for: scalar) {
                return pack(raster, cellSpan: 1, key: key)
            }
            // No sprite for this scalar after all: fall through to the font.
        }
        if let cellSpan {
            switch validated(Key(scalar: scalar, style: style, span: cellSpan)) {
            case .glyph(let entry): return entry
            case .empty: return nil
            case nil: break
            }
        }
        // Miss: build the array the source needs and take the general path.
        return glyph(for: [scalar], style: style, cellSpan: cellSpan)
    }

    /// Shapes, rasterizes and packs a grapheme, or returns the cached placement.
    /// Returns `nil` for clusters with nothing to draw (space, control characters).
    public func glyph(for scalars: [Unicode.Scalar],
                      style: FontStyle = .regular,
                      cellSpan: Int? = nil) -> CachedGlyph? {
        // Box drawing and block elements are drawn, not shaped: same sprite for every style, and one
        // cell wide by definition. Keyed as `.regular` so bold text does not cache a second copy.
        if BoxSpriteGeometry.covers(scalars) {
            let key = Key(scalars: scalars, style: .regular, span: 1)
            switch validated(key) {
            case .glyph(let entry): return entry
            case .empty: return nil
            case nil: break
            }
            if let raster = source.sprite(for: scalars[0]) {
                return pack(raster, cellSpan: 1, key: key)
            }
            // No sprite for this scalar after all: fall through to the font.
        }

        // The span decides the key, and when the caller already knows it — `FrameBuilder` always
        // does, from libghostty's authoritative WIDE flag — the key is fully determined here. So
        // the cache is consulted *before* the source, which on a hit skips the shaper's own
        // dictionary lookup and the key array it would have built for it.
        if let cellSpan {
            switch validated(Key(scalars: scalars, style: style, span: cellSpan)) {
            case .glyph(let entry): return entry
            case .empty: return nil
            case nil: break
            }
        }

        let shaped = source.shape(scalars, style: style, cellSpan: cellSpan)
        let key = Key(scalars: scalars, style: style, span: shaped.cellSpan)
        if cellSpan == nil {
            switch validated(key) {
            case .glyph(let entry): return entry
            case .empty: return nil
            case nil: break
            }
        }
        guard let raster = source.rasterize(shaped, style: style) else {
            entries[key] = .empty
            return nil
        }
        return pack(raster, cellSpan: shaped.cellSpan, key: key)
    }

    public func glyph(for character: Character,
                      style: FontStyle = .regular,
                      cellSpan: Int? = nil) -> CachedGlyph? {
        glyph(for: Array(character.unicodeScalars), style: style, cellSpan: cellSpan)
    }

    /// What the cache holds for `key`, re-stamped after a regrow. `nil` means "not cached, draw it";
    /// `.empty` means "cached, and there is nothing to draw".
    private func validated(_ key: Key) -> CacheEntry? {
        guard let cached = entries[key] else { return nil }
        guard case .glyph(let glyph) = cached else { return .empty }
        let target = atlas(for: glyph.slot.kind)
        if target.isValid(glyph.slot) { return cached }
        // A regrow moved the goalposts but kept the pixels: just re-stamp the slot.
        guard let refreshed = target.revalidate(glyph.slot) else { return nil }
        let entry = CachedGlyph(slot: refreshed, bearingX: glyph.bearingX,
                                bearingTop: glyph.bearingTop, cellSpan: glyph.cellSpan)
        entries[key] = .glyph(entry)
        return .glyph(entry)
    }

    /// Packs a freshly drawn bitmap into its atlas and records the placement.
    private func pack(_ raster: RasterizedGlyph, cellSpan: Int, key: Key) -> CachedGlyph? {
        let target = atlas(for: raster.isColor ? .color : .grayscale)
        let generationBefore = target.generation
        guard let slot = target.insert(pixels: raster.pixels, width: raster.width,
                                       height: raster.height, bytesPerRow: raster.bytesPerRow)
        else { return nil }
        if target.rebuildGeneration > generationBefore {
            // The atlas was cleared while packing: every other entry in it lost its pixels.
            dropEntries(in: target.kind, keeping: key)
        }
        let entry = CachedGlyph(slot: slot, bearingX: raster.bearingX,
                                bearingTop: raster.bearingTop, cellSpan: cellSpan)
        entries[key] = .glyph(entry)
        return entry
    }

    /// Drops every entry whose pixels lived in the atlas that was just cleared. `.empty` entries
    /// hold no pixels, so they are deliberately kept — re-deriving them is the expensive thing this
    /// cache exists to avoid.
    private func dropEntries(in kind: AtlasKind, keeping key: Key) {
        for (k, v) in entries {
            guard case .glyph(let glyph) = v, glyph.slot.kind == kind, k != key else { continue }
            entries.removeValue(forKey: k)
        }
    }

    /// Number of cached clusters (diagnostics and tests).
    ///
    /// Counts `.empty` entries too — a cluster with nothing to draw is a cached answer like any
    /// other, and the whole point of keeping it is that it is never re-derived.
    public var cachedCount: Int { entries.count }
}
