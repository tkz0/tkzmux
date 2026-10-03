// LayoutDump — the layout half of a component snapshot (WOR-307 S1; ADR-0003 layer L0).
//
// What `ComponentSnapshot.render` measured about a component, as JSON: the frame tree in logical
// points, the measured text runs with their truncation and wrap results, the masks over regions
// that do not render deterministically, and the pixel rounding a fractional scale needed. The
// Linux canvas views (WOR-316–WOR-319) are compared against these files, so this is plain data:
// Foundation only, no AppKit type in it.
//
// Conventions, all fixed by ADR-0003:
//
//   * **Frames are logical points with a top-left origin**, relative to the component's own
//     bounds, whatever the views' `isFlipped`. A layer in a y-up row at y 19 of a 44 pt row is
//     recorded at y 18 (44 − 19 − 7 for a 7 pt dot), which is what the Linux canvas has to produce.
//   * **No rounding.** Frames and widths are the doubles AppKit and CoreText reported; L0 compares
//     frames exactly and text widths within ±0.5 pt.
//   * **The JSON is canonical**: sorted keys, pretty-printed, a trailing newline, and absent fields
//     left out rather than written as null, so two runs on one build are byte-identical.

import Foundation

struct LayoutDump: Codable, Equatable, Sendable {
    /// Bumped whenever a field changes meaning; the parity tool refuses a schema it does not know.
    static let schemaVersion = 1

    var schema: Int = Self.schemaVersion
    /// The component id, e.g. `sidebar.sessionRow`.
    var component: String
    /// `Theme.Preset.rawValue`.
    var theme: String
    /// The appearance the render was forced to, as `NSAppearance.Name`: `NSAppearanceNameDarkAqua`
    /// for the dark presets, `NSAppearanceNameAqua` for Light.
    var appearance: String
    var scale: Double
    /// The logical size the component was laid out at.
    var size: Size
    /// The bitmap's size, and whether a fractional product had to be rounded up to get it.
    var pixels: Pixels
    /// Component-level results that are not a frame: a wrap decision, a computed height.
    var facts: [String: String]
    var masks: [Mask]
    var root: Node

    struct Size: Codable, Equatable, Sendable {
        var width: Double
        var height: Double
    }

    struct Rect: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var maxX: Double { x + width }
        var maxY: Double { y + height }
    }

    /// One axis of the bitmap. A component is drawn from the top-left corner, so when
    /// `logical × scale` is not a whole number the last row or column is the partly covered one.
    struct PixelExtent: Codable, Equatable, Sendable {
        /// The bitmap's size along this axis.
        var pixels: Int
        /// `logical × scale`, to six decimals (70.4 for a 44 pt row at 1.6).
        var exact: Double
        /// `true` when `exact` was not whole and `pixels` is its ceiling.
        var roundedUp: Bool

        init(logical: Double, scale: Double) {
            let product = logical * scale
            let nearest = product.rounded()
            // 300 × 1.6 is 480.00000000000006 in binary floating point: a product within a
            // millionth of a whole pixel is that pixel, not a reason to add one.
            if abs(product - nearest) < 1e-6 {
                pixels = Int(nearest)
                roundedUp = false
            } else {
                pixels = Int(product.rounded(.up))
                roundedUp = true
            }
            exact = (product * 1e6).rounded() / 1e6
        }
    }

    struct Pixels: Codable, Equatable, Sendable {
        var width: PixelExtent
        var height: PixelExtent
    }

    /// A string as drawn: by a `CATextLayer`, an `NSTextField`, or a view's `draw(_:)` when the
    /// component reports it.
    struct TextRun: Codable, Equatable, Sendable {
        var string: String
        /// PostScript name of the font actually used (`ThemeAppKit.mono`'s fallbacks included).
        var font: String
        var size: Double
        /// The natural single-line width of the string in that font.
        var measuredWidth: Double
        /// The width the run was given to draw in.
        var availableWidth: Double
        var wraps: Bool
        /// Wrapping runs only: the height the text needs at `availableWidth`.
        var fittingHeight: Double?
        /// The run does not fit: wider than its box on one line, or taller than it when wrapping.
        var truncated: Bool
    }

    /// A region the pixel comparison leaves out (ADR-0003 section 3), with why.
    enum MaskKind: String, Codable, Equatable, Sendable {
        /// `NSVisualEffectView` material: its blur has no offscreen content.
        case vibrancy
        /// `NSSearchField`'s system-drawn bezel and icons.
        case searchField
        /// A `.regular` table selection, drawn in the system accent colour.
        case accentSelection
        /// Overlay scrollers, whose visibility depends on timing.
        case scroller
    }

    struct Mask: Codable, Equatable, Sendable {
        var kind: MaskKind
        var frame: Rect
        /// The class that caused it.
        var source: String
    }

    enum NodeKind: String, Codable, Equatable, Sendable {
        case view
        case layer
    }

    /// One view, or one layer that is not a view's backing layer. Children are in drawing order:
    /// a view's own sublayers first, then its subviews.
    struct Node: Codable, Equatable, Sendable {
        var kind: NodeKind
        /// The class name, e.g. `SessionRowView` or `CATextLayer`.
        var type: String
        /// `NSView.identifier` or `CALayer.name`, when set.
        var name: String?
        var frame: Rect
        var hidden: Bool?
        /// `alphaValue` or `opacity`, when below 1.
        var alpha: Double?
        /// Views only, when `isFlipped`.
        var flipped: Bool?
        /// The animation keys that were attached and then frozen (removed) for the capture.
        var animations: [String]?
        var text: TextRun?
        var children: [Node]?

        /// This node and every node under it, depth first in drawing order.
        var allNodes: [Node] {
            [self] + (children ?? []).flatMap(\.allNodes)
        }
    }

    /// Every node in the tree, depth first in drawing order.
    var allNodes: [Node] { root.allNodes }

    /// The nodes whose class is `type`.
    func nodes(ofType type: String) -> [Node] {
        allNodes.filter { $0.type == type }
    }

    /// The canonical JSON form.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
