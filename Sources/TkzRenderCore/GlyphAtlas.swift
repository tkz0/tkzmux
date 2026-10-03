// GlyphAtlas — the device-free half of the app-wide glyph atlases (M1.4; core since WOR-311 S3).
//
// `.grayscale` is one byte of coverage per pixel at 2048², `.color` is premultiplied BGRA at 1024²
// growing to 2048². Packing is a shelf packer over a CPU staging buffer; the staging copy is what
// makes regrow cheap (re-upload, no re-rasterization), gives "one upload per frame" (a single dirty
// bounding box), and provides the `--png` dump for free.
//
// No GPU here: a renderer's uploader (Metal in TkzTerminalRender, Vulkan with WOR-313) takes the
// dirty region once per frame with `takePendingRegion()`, copies those rows of `staging` into its
// texture, and makes a new texture whenever `size` no longer matches the one it has.
//
// Every slot carries the atlas `generation`. It increments whenever coordinates or texture identity
// change — on regrow (UVs change because the atlas got bigger) and on rebuild after overflow (the
// contents are gone). Holders of slots must check `isValid(_:)` and re-insert when it fails.

/// Which of the two atlases a glyph lives in.
public enum AtlasKind: Sendable, Hashable {
    case grayscale
    case color

    public var bytesPerPixel: Int { self == .grayscale ? 1 : 4 }
    public var defaultInitialSize: Int { self == .grayscale ? 2048 : 1024 }
    public var maxSize: Int { 2048 }
}

/// Where a glyph lives in an atlas, stamped with the generation it was packed in.
public struct AtlasSlot: Sendable, Equatable, Hashable {
    public let kind: AtlasKind
    public let generation: UInt64
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// Atlas edge length when the slot was packed, so UVs can be recomputed without asking the atlas.
    public let atlasSize: Int

    public init(kind: AtlasKind, generation: UInt64, x: Int, y: Int, width: Int, height: Int,
                atlasSize: Int) {
        self.kind = kind
        self.generation = generation
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.atlasSize = atlasSize
    }

    /// Normalized texture coordinates of the slot's top-left / bottom-right corners.
    public var uvOrigin: (Float, Float) {
        (Float(x) / Float(atlasSize), Float(y) / Float(atlasSize))
    }
    public var uvSize: (Float, Float) {
        (Float(width) / Float(atlasSize), Float(height) / Float(atlasSize))
    }
}

/// A rectangle of atlas pixels, top-left origin: what an uploader copies into its texture.
public struct AtlasRegion: Sendable, Equatable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The smallest region covering both.
    public func union(_ other: AtlasRegion) -> AtlasRegion {
        let minX = min(x, other.x), minY = min(y, other.y)
        let maxX = max(x + width, other.x + other.width)
        let maxY = max(y + height, other.y + other.height)
        return AtlasRegion(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// A shelf-packed glyph atlas backed by a CPU staging buffer.
///
/// Not `Sendable`; owned by `GlyphCache` on the render thread.
public final class GlyphAtlas {
    public let kind: AtlasKind
    public private(set) var size: Int
    public private(set) var generation: UInt64 = 1
    /// The generation the pixels were last thrown away at. A slot from at or after this generation
    /// still points at its own pixels, even if the atlas has since grown.
    public private(set) var rebuildGeneration: UInt64 = 1
    /// Increments every time the atlas is cleared because it ran out of room at max size.
    public private(set) var rebuildCount: Int = 0
    /// Increments every time the atlas doubled.
    public private(set) var growCount: Int = 0

    /// Every pixel of the atlas, `size` rows of `bytesPerRow` bytes, top row first. Coverage for
    /// `.grayscale`, premultiplied BGRA for `.color`.
    public private(set) var staging: [UInt8]
    private var shelves: [Shelf] = []
    /// The bounding box of everything staged since the last `takePendingRegion()`.
    private var dirty: AtlasRegion?

    private struct Shelf {
        var y: Int
        var height: Int
        var nextX: Int
    }

    /// - Parameters:
    ///   - initialSize: edge length to start at; defaults to the kind's design value. Tests use a
    ///     small value to exercise regrow without allocating megabytes.
    public init(kind: AtlasKind, initialSize: Int? = nil) {
        self.kind = kind
        let start = min(max(initialSize ?? kind.defaultInitialSize, 16), kind.maxSize)
        self.size = start
        self.staging = [UInt8](repeating: 0, count: start * start * kind.bytesPerPixel)
    }

    /// Bytes per row of `staging`.
    public var bytesPerRow: Int { size * kind.bytesPerPixel }

    // MARK: - Validity

    /// True when `slot` is usable as-is: same atlas, current generation.
    public func isValid(_ slot: AtlasSlot) -> Bool {
        slot.kind == kind && slot.generation == generation
    }

    /// Re-stamps a stale slot when its pixels survived.
    ///
    /// A *regrow* copies every packed pixel into the larger texture, so the x/y/w/h stay correct and
    /// only the normalization changes — such a slot is refreshed here without re-rasterizing.
    /// A *rebuild* throws the pixels away, and slots from before it return `nil`.
    public func revalidate(_ slot: AtlasSlot) -> AtlasSlot? {
        guard slot.kind == kind else { return nil }
        if slot.generation == generation { return slot }
        guard slot.generation >= rebuildGeneration else { return nil }
        guard slot.x + slot.width <= size, slot.y + slot.height <= size else { return nil }
        return AtlasSlot(kind: kind, generation: generation, x: slot.x, y: slot.y,
                         width: slot.width, height: slot.height, atlasSize: size)
    }

    // MARK: - Insertion

    /// Packs `width * height` pixels, growing or rebuilding as needed.
    /// Returns `nil` only when the glyph cannot fit an empty max-size atlas.
    @discardableResult
    public func insert(pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> AtlasSlot? {
        guard width > 0, height > 0 else { return nil }

        while true {
            if let slot = pack(width: width, height: height) {
                blit(pixels: pixels, bytesPerRow: bytesPerRow, slot: slot)
                return slot
            }
            if size < kind.maxSize {
                grow()
            } else if !shelves.isEmpty {
                rebuild()
            } else {
                return nil  // does not fit an empty max-size atlas
            }
        }
    }

    private func pack(width: Int, height: Int) -> AtlasSlot? {
        guard width <= size, height <= size else { return nil }
        // Best fit: the shortest shelf that is still tall enough.
        var bestIndex: Int?
        for (i, shelf) in shelves.enumerated()
        where shelf.height >= height && shelf.nextX + width <= size {
            if bestIndex == nil || shelf.height < shelves[bestIndex!].height { bestIndex = i }
        }
        if let i = bestIndex {
            let slot = AtlasSlot(kind: kind, generation: generation, x: shelves[i].nextX,
                                 y: shelves[i].y, width: width, height: height, atlasSize: size)
            shelves[i].nextX += width
            return slot
        }
        // New shelf on top of the tallest used row.
        let top = shelves.reduce(0) { max($0, $1.y + $1.height) }
        guard top + height <= size else { return nil }
        shelves.append(Shelf(y: top, height: height, nextX: width))
        return AtlasSlot(kind: kind, generation: generation, x: 0, y: top,
                         width: width, height: height, atlasSize: size)
    }

    private func blit(pixels: [UInt8], bytesPerRow: Int, slot: AtlasSlot) {
        let bpp = kind.bytesPerPixel
        let stride = size * bpp
        let rowBytes = slot.width * bpp
        for row in 0..<slot.height {
            let src = row * bytesPerRow
            let dst = (slot.y + row) * stride + slot.x * bpp
            guard src + rowBytes <= pixels.count, dst + rowBytes <= staging.count else { break }
            staging.replaceSubrange(dst..<(dst + rowBytes), with: pixels[src..<(src + rowBytes)])
        }
        markDirty(AtlasRegion(x: slot.x, y: slot.y, width: slot.width, height: slot.height))
    }

    private func markDirty(_ region: AtlasRegion) {
        dirty = dirty.map { $0.union(region) } ?? region
    }

    // MARK: - Grow / rebuild

    private func grow() {
        let newSize = min(size * 2, kind.maxSize)
        guard newSize > size else { return }
        let bpp = kind.bytesPerPixel
        var newStaging = [UInt8](repeating: 0, count: newSize * newSize * bpp)
        let oldStride = size * bpp
        let newStride = newSize * bpp
        for row in 0..<size {
            let src = row * oldStride
            let dst = row * newStride
            newStaging.replaceSubrange(dst..<(dst + oldStride), with: staging[src..<(src + oldStride)])
        }
        staging = newStaging
        size = newSize
        // Pixel coordinates survive, but UVs and the texture do not: bump the generation so every
        // holder re-reads its slot, and mark everything for the uploader's new texture.
        generation &+= 1
        growCount += 1
        dirty = AtlasRegion(x: 0, y: 0, width: size, height: size)
    }

    private func rebuild() {
        staging = [UInt8](repeating: 0, count: staging.count)
        shelves.removeAll(keepingCapacity: true)
        generation &+= 1
        rebuildGeneration = generation
        rebuildCount += 1
        dirty = AtlasRegion(x: 0, y: 0, width: size, height: size)
    }

    // MARK: - Upload

    /// True when there are staged pixels the GPU has not seen.
    public var hasPendingUpload: Bool { dirty != nil }

    /// The bounding box of the pixels staged since the last `takePendingRegion()`, without
    /// consuming it.
    public var pendingRegion: AtlasRegion? { dirty }

    /// Hands the uploader the bounding box of everything staged since the last call, and forgets
    /// it: one upload per atlas per frame. After a grow or a rebuild it is the whole atlas.
    @discardableResult
    public func takePendingRegion() -> AtlasRegion? {
        defer { dirty = nil }
        return dirty
    }

    // MARK: - Diagnostics

    /// Reads one staged pixel's bytes (diagnostics and tests).
    public func stagedPixel(x: Int, y: Int) -> [UInt8] {
        let bpp = kind.bytesPerPixel
        guard x >= 0, y >= 0, x < size, y < size else { return [] }
        let offset = y * size * bpp + x * bpp
        return Array(staging[offset..<(offset + bpp)])
    }
}
