// BoxSpriteGeometry — which clusters are drawn as box sprites instead of font glyphs (WOR-311 S3).
//
// U+2500…U+257F (box drawing) and U+2580…U+259F (block elements) are drawn by the renderer so they
// tile with their neighbours (TkzTerminalRender's BoxSprites explains why). `GlyphCache` asks this
// before it looks anything up, so a sprite is keyed once for every style and never shaped.
//
// TODO(WOR-311 S5): the per-codepoint rects, arms and alpha decomposition move in here, shared by
// the Mac's CoreGraphics drawing and the pure-Swift rasterizer.

public enum BoxSpriteGeometry {
    /// True for the single-scalar clusters drawn as sprites.
    public static func covers(_ scalars: [Unicode.Scalar]) -> Bool {
        scalars.count == 1 && covers(scalars[0])
    }

    public static func covers(_ scalar: Unicode.Scalar) -> Bool {
        (0x2500...0x259F).contains(scalar.value)
    }
}
