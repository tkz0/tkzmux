// GroupPalette — the fixed swatch set the sidebar's "Group color" picker offers (TKZ-48).
//
// The two properties that matter are (1) every swatch is visible against every preset's sidebar,
// including the near-white one, and (2) a colour survives `state.json` and still matches its
// swatch, or the menu's checkmark would go missing after a relaunch.

import Foundation
import Testing

@testable import TkzCore

@Suite struct GroupPaletteTests {
    @Test func eightSwatchesInMenuOrder() {
        #expect(GroupPalette.swatches.count == 8)
        #expect(GroupPalette.swatches.map(\.slug) == [
            "teal", "indigo", "blue", "violet", "magenta", "amber", "coral", "green",
        ])
        // Every swatch is opaque: the edge is a solid 2.5 pt stripe, not a tint.
        for swatch in GroupPalette.swatches {
            #expect(swatch.rgb.a == 1, "\(swatch.slug) is not opaque")
        }
    }

    @Test func swatchesAreDistinct() {
        #expect(Set(GroupPalette.swatches.map(\.slug)).count == GroupPalette.swatches.count)
        #expect(Set(GroupPalette.swatches.map(\.rgb)).count == GroupPalette.swatches.count)
        // Distinct is not enough — two hues one 8-bit unit apart would be useless as group markers.
        for (i, a) in GroupPalette.swatches.enumerated() {
            for b in GroupPalette.swatches[(i + 1)...] {
                let distance = ((a.rgb.r - b.rgb.r) * (a.rgb.r - b.rgb.r)
                    + (a.rgb.g - b.rgb.g) * (a.rgb.g - b.rgb.g)
                    + (a.rgb.b - b.rgb.b) * (a.rgb.b - b.rgb.b)).squareRoot()
                #expect(distance > 0.15, "\(a.slug) and \(b.slug) are too close to tell apart")
            }
        }
    }

    /// The first swatch is what the picker offers as its default, and reproduces the 2c artboard's
    /// `groupEdgeDefault`. Not a fallback: an uncoloured group still has no edge at all.
    @Test func firstSwatchIsTheDefaultOffering() {
        #expect(GroupPalette.swatches[0].rgb == Theme.preset(.midnightIndigo).groupEdgeDefault)
    }

    /// A 2.5 pt decorative stripe, not text, so the bar is "clearly visible", not WCAG AA. The
    /// binding case is the `.light` preset, whose sidebar is near-white.
    @Test(arguments: Theme.allPresets)
    func everySwatchReadsAgainstTheSidebar(theme: Theme) {
        let background = theme.sidebarBackground
        for swatch in GroupPalette.swatches {
            let ratio = swatch.rgb.contrastRatio(against: background)
            #expect(ratio >= 1.5, "\(theme.preset)/\(swatch.slug) is only \(ratio):1 on the sidebar")
        }
    }

    // MARK: Matching

    @Test func matchingFindsTheSwatchAndToleratesEverythingElse() {
        for swatch in GroupPalette.swatches {
            #expect(GroupPalette.swatch(matching: swatch.rgb) == swatch)
        }
        #expect(GroupPalette.swatch(matching: nil) == nil)
        #expect(GroupPalette.swatch(matching: RGB(hex: 0x123456)) == nil)
    }

    /// The checkmark has to survive a relaunch: `Group.color` is written to `state.json` as four
    /// `Double`s and read back, so matching compares 8-bit channels rather than `Double` equality.
    @Test func matchingSurvivesAJSONRoundTrip() throws {
        for swatch in GroupPalette.swatches {
            let data = try JSONEncoder().encode(swatch.rgb)
            let decoded = try JSONDecoder().decode(RGB.self, from: data)
            #expect(GroupPalette.swatch(matching: decoded) == swatch, "\(swatch.slug) lost its match")
        }
    }

    /// A colour a hair off the palette still matches — the same tolerance the round trip relies on.
    @Test func matchingIsOnEightBitChannels() {
        let teal = GroupPalette.swatches[0]
        var nudged = teal.rgb
        nudged.r += 0.0005
        #expect(GroupPalette.swatch(matching: nudged) == teal)
    }
}
