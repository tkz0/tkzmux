// TkzCore — the fixed set of colours the sidebar's "Group color" picker offers (TKZ-48).
//
// `Group.color` is a free-form `RGB?`, but the picker deliberately offers a small curated set
// rather than an `NSColorPanel`: the edge is 2.5 pt of solid colour on a sidebar background that
// ranges from near-black (2c, 2a, 2b, 1a) to near-white (1b), and an arbitrary colour cannot be
// trusted to read on both. The precedent is `SidebarSessionRowModel.accountChipColor` — "tiny,
// mid-saturation, must read on all five presets" — and four of the eight hues are shared with it
// so the two palettes stay in one visual family.
//
// The values are **fixed sRGB, not derived from the theme**. `Group.color` stores a literal `RGB`,
// so a theme-dependent swatch could not be matched back to its entry when the menu is next opened.
//
// `Theme.groupEdgeDefault` is *not* one of these by definition — it is the colour the picker offers
// as its default (the first swatch matches its 2c value), never a fallback for `color == nil`.
// A group with no colour has a fully transparent edge; see `SidebarGroupRowModel.color`.

/// One entry in the group-colour picker.
public struct GroupSwatch: Hashable, Sendable {
    /// Menu title, e.g. `"Teal"`.
    public let name: String
    /// Stable identifier for the menu item (`tkzmux.context.groupColor.teal`). Never localised and
    /// never derived from `name` at runtime, so a renamed swatch cannot silently change a test's id.
    public let slug: String
    /// The colour written into `Group.color`.
    public let rgb: RGB

    public init(name: String, slug: String, rgb: RGB) {
        self.name = name
        self.slug = slug
        self.rgb = rgb
    }
}

public enum GroupPalette {
    /// Menu order. The first entry is what the picker offers as its default and reproduces
    /// `Theme.groupEdgeDefault` in the 2c artboard.
    public static let swatches: [GroupSwatch] = [
        GroupSwatch(name: "Teal", slug: "teal", rgb: RGB(hex: 0x41c6a8)),
        GroupSwatch(name: "Indigo", slug: "indigo", rgb: RGB(hex: 0x8b93f8)),
        GroupSwatch(name: "Blue", slug: "blue", rgb: RGB(hex: 0x5b8def)),
        // #a78bfa would be the obvious violet, but it sits too close to the indigo above to tell
        // apart at 2.5 pt — `swatchesAreDistinct` measures it.
        GroupSwatch(name: "Violet", slug: "violet", rgb: RGB(hex: 0xc084fc)),
        GroupSwatch(name: "Magenta", slug: "magenta", rgb: RGB(hex: 0xe06aa8)),
        GroupSwatch(name: "Amber", slug: "amber", rgb: RGB(hex: 0xe0b060)),
        GroupSwatch(name: "Coral", slug: "coral", rgb: RGB(hex: 0xf28b8b)),
        GroupSwatch(name: "Green", slug: "green", rgb: RGB(hex: 0x7bc96f)),
    ]

    /// The swatch `color` came from, or `nil` for "no colour" and for any colour set outside the
    /// palette.
    ///
    /// Matching is on `RGB.bytes`, **not** on `Double` equality: the stored colour has been through
    /// `state.json`, and the menu's checkmark has to survive a relaunch. The palette is authored in
    /// 8-bit hex, so comparing the 8-bit channels loses nothing.
    public static func swatch(matching color: RGB?) -> GroupSwatch? {
        guard let color else { return nil }
        let wanted = color.bytes
        return swatches.first { $0.rgb.bytes == wanted }
    }
}
