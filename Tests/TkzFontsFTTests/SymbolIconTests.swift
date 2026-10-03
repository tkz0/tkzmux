// SymbolIconTests — the path-drawn stand-ins for bell.fill, bell.slash and folder.badge.plus, and
// their rasterizer (WOR-312 S7).
//
// The shape checks sample the bitmap at points chosen from the geometry, rendered large (96 px per
// em) so a sample pixel lies well inside the feature it tests. Set TKZMUX_ICON_PNG_DIR to an
// absolute directory to also write each icon at 12 pt on 2x and 1.6x surfaces as PNGs.

import Foundation
import Testing
import TkzPNG
@testable import TkzFontsFT

@Suite("Symbol icons")
struct SymbolIconTests {
    private static let rasterizer = Result { try IconRasterizer() }

    /// Coverage at the icon-unit point (`x`, `y`) of `bitmap`, drawn at `pixelsPerUnit`.
    private func coverage(_ bitmap: IconBitmap, _ x: CGFloat, _ y: CGFloat, pixelsPerUnit: CGFloat) -> UInt8 {
        let column = Int((x * pixelsPerUnit).rounded(.down)) - bitmap.bearingX
        let row = bitmap.bearingTop - 1 - Int((y * pixelsPerUnit).rounded(.down))
        guard (0..<bitmap.width).contains(column), (0..<bitmap.height).contains(row) else { return 0 }
        return bitmap.pixels[row * bitmap.width + column]
    }

    private func large(_ icon: SymbolIcon) throws -> (IconBitmap, CGFloat) {
        let bitmap = try #require(try Self.rasterizer.get().rasterize(icon, pointSize: 48, scale: 2))
        return (bitmap, 96 / SymbolIcon.unitsPerEm)
    }

    @Test("the three SF Symbol names map to stand-ins")
    func names() {
        #expect(SymbolIcons.named("bell.fill") == SymbolIcons.bellFill)
        #expect(SymbolIcons.named("bell.slash") == SymbolIcons.bellSlash)
        #expect(SymbolIcons.named("folder.badge.plus") == SymbolIcons.folderBadgePlus)
        #expect(SymbolIcons.named("gear") == nil)
    }

    @Test("each icon has ink, fits about one em at 12 pt, and rasterizes identically twice",
          arguments: [2.0, 1.6] as [CGFloat])
    func sizes(scale: CGFloat) throws {
        let rasterizer = try Self.rasterizer.get()
        let em = 12 * scale
        for icon in SymbolIcons.all {
            let bitmap = try #require(rasterizer.rasterize(icon, pointSize: 12, scale: scale))
            #expect(bitmap.pixels.contains(255), "\(icon.name)")
            #expect(CGFloat(bitmap.width) <= em + 2 && CGFloat(bitmap.height) <= em + 2, "\(icon.name) \(bitmap.width)×\(bitmap.height)")
            #expect(CGFloat(bitmap.width) >= em * 0.75 && CGFloat(bitmap.height) >= em * 0.75, "\(icon.name)")
            #expect(rasterizer.rasterize(icon, pointSize: 12, scale: scale) == bitmap)
            try writePNG(bitmap, name: "\(icon.name)@\(scale)x")
        }
    }

    @Test("bell.fill is solid; bell.slash is the same bell hollow, struck through, with a gap each side")
    func bells() throws {
        let (fill, k) = try large(SymbolIcons.bellFill)
        let (slash, _) = try large(SymbolIcons.bellSlash)
        // Inside the bell, away from the slash: solid in one, hollow in the other.
        #expect(coverage(fill, 620, 650, pixelsPerUnit: k) == 255)
        #expect(coverage(slash, 620, 650, pixelsPerUnit: k) == 0)
        // The left wall, clear of the slash: both inked.
        #expect(coverage(fill, 272, 530, pixelsPerUnit: k) == 255)
        #expect(coverage(slash, 272, 530, pixelsPerUnit: k) == 255)
        // The rim where the slash crosses it (x 732 at y 190): the slash itself, the gap beside it
        // (67 units off its centre line), then the rim again (128 units off).
        #expect(coverage(slash, 732, 190, pixelsPerUnit: k) == 255)
        #expect(coverage(slash, 822, 190, pixelsPerUnit: k) == 0)
        #expect(coverage(fill, 822, 190, pixelsPerUnit: k) == 255)
        #expect(coverage(slash, 562, 190, pixelsPerUnit: k) == 255)
        // The clapper, under the rim with a gap.
        #expect(coverage(fill, 500, 60, pixelsPerUnit: k) == 255)
        #expect(coverage(fill, 500, 130, pixelsPerUnit: k) == 0)
    }

    @Test("folder.badge.plus is an outlined folder with a plus, and the folder is cut round the badge")
    func folder() throws {
        let (folder, k) = try large(SymbolIcons.folderBadgePlus)
        #expect(coverage(folder, 300, 400, pixelsPerUnit: k) == 0)    // inside
        #expect(coverage(folder, 80, 400, pixelsPerUnit: k) == 255)   // left wall
        #expect(coverage(folder, 200, 745, pixelsPerUnit: k) == 255)  // the tab
        #expect(coverage(folder, 600, 745, pixelsPerUnit: k) == 0)    // beside the tab
        #expect(coverage(folder, 790, 150, pixelsPerUnit: k) == 255)  // the plus
        #expect(coverage(folder, 400, 130, pixelsPerUnit: k) == 255)  // bottom wall
        #expect(coverage(folder, 560, 130, pixelsPerUnit: k) == 0)    // bottom wall, inside the cut
    }

    @Test("a clear layer only erases: an icon of clear layers alone has no ink")
    func clearOnly() throws {
        let icon = SymbolIcon(name: "test", layers: [.clear(.circle(500, 500, radius: 300))])
        #expect(try Self.rasterizer.get().rasterize(icon, pointSize: 12, scale: 2) == nil)
    }

    private func writePNG(_ bitmap: IconBitmap, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TKZMUX_ICON_PNG_DIR"], directory.hasPrefix("/") else { return }
        // Black ink on white, so it reads in any viewer.
        let gray = bitmap.pixels.map { 255 - $0 }
        let png = try PNG.encode(gray, width: bitmap.width, height: bitmap.height, colorType: .gray)
        try Data(png).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
