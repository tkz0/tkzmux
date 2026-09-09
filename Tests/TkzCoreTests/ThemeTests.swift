import Testing
@testable import TkzCore

@Suite struct ThemeTests {
    // MARK: Presets

    @Test func fivePresetsAndDefault() {
        #expect(Theme.Preset.allCases.count == 5)
        #expect(Theme.allPresets.map(\.preset) == Theme.Preset.allCases)
        #expect(Theme.default.preset == .midnightIndigo)
        #expect(Theme.preset(.light).preset == .light)
        #expect(Theme.allPresets.filter { !$0.isDark }.map(\.preset) == [.light])
    }

    @Test(arguments: Theme.allPresets)
    func everyTokenIsDefined(theme: Theme) {
        // The type system already forbids optionals; this is the literal acceptance check.
        for child in Mirror(reflecting: theme).children {
            let isOptional = Mirror(reflecting: child.value).displayStyle == .optional
            #expect(!isOptional, "\(theme.preset) token \(child.label ?? "?") is optional")
        }
    }

    @Test(arguments: Theme.allPresets)
    func colourComponentsAreInRange(theme: Theme) {
        for (name, colour) in theme.colourTokens {
            for component in [colour.r, colour.g, colour.b, colour.a] {
                #expect((0...1).contains(component), "\(theme.preset).\(name) has a component out of range")
            }
            #expect(colour.a > 0, "\(theme.preset).\(name) is fully transparent")
        }
    }

    // MARK: Contrast (WCAG 2.x)

    @Test(arguments: Theme.allPresets)
    func foregroundContrastIsAAA(theme: Theme) {
        let bg = theme.terminalBackground
        #expect(theme.foreground.contrastRatio(against: bg) >= 7, "\(theme.preset) foreground")
        #expect(theme.terminalForeground.contrastRatio(against: bg) >= 7, "\(theme.preset) terminalForeground")
        #expect(theme.foregroundMuted.contrastRatio(against: bg) >= 4.5, "\(theme.preset) foregroundMuted")
    }

    @Test(arguments: Theme.allPresets)
    func secondaryTextIsReadable(theme: Theme) {
        // The sidebar is translucent in 1a/1b and `contrastRatio` ignores alpha, so composite first.
        let sidebar = theme.sidebarBackground.over(theme.windowBackground)
        #expect(theme.groupHeaderText.contrastRatio(against: sidebar) >= 4.5, "\(theme.preset) groupHeaderText")
        #expect(theme.summaryText.contrastRatio(against: sidebar) >= 4.5, "\(theme.preset) summaryText")
        // 1b's artboard draws the status bar text at 4.1:1; every light scheme has that weakness.
        let minimum = theme.isDark ? 4.5 : 4.0
        #expect(theme.statusBarText.contrastRatio(against: theme.statusBarBackground) >= minimum,
                "\(theme.preset) statusBarText")
    }

    // MARK: Terminal palette

    @Test(arguments: Theme.allPresets)
    func paletteShape(theme: Theme) {
        let p = theme.terminalPalette16
        #expect(p.count == 16)
        #expect(p.allSatisfy { $0.a == 1 }, "\(theme.preset) palette must be opaque")
        let chroma = Array(p[1...6])
        #expect(Set(chroma).count == 6, "\(theme.preset) ANSI 1–6 must be distinct")
        #expect(p[7] != p[15], "\(theme.preset) white and bright white must differ")
        #expect(p[0] != p[8], "\(theme.preset) black and bright black must differ")
    }

    @Test(arguments: Theme.allPresets)
    func paletteChromaIsReadableOnTerminalBackground(theme: Theme) {
        // Yellow on white is 2.7:1 in the light artboard; every light scheme has that weakness.
        let minimum = theme.isDark ? 3.0 : 2.5
        for slot in [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14] {
            let ratio = theme.terminalPalette16[slot].contrastRatio(against: theme.terminalBackground)
            #expect(ratio >= minimum, "\(theme.preset) slot \(slot) is \(ratio):1")
        }
    }

    @Test(arguments: Theme.allPresets)
    func brightVariantsFollowTheRule(theme: Theme) {
        let p = theme.terminalPalette16
        for slot in 1...6 {
            let expected = theme.isDark
                ? p[slot].mixed(with: .white, amount: 0.25)
                : p[slot].mixed(with: .black, amount: 0.15)
            #expect(p[slot + 8] == expected, "\(theme.preset) slot \(slot + 8)")
        }
        #expect(p[1] == theme.diffRemove)
        #expect(p[2] == theme.working)
        #expect(p[3] == theme.waiting)
        #expect(p[8] == theme.foregroundDim)
        if theme.isDark {
            #expect(p[0] == theme.statusBarBackground)
            #expect(p[7] == theme.terminalForeground)
            #expect(p[15] == theme.foreground)
        } else {
            #expect(p[0] == theme.foreground)
            #expect(p[7] == theme.foregroundMuted)
            #expect(p[15] == theme.terminalForeground)
        }
    }

    // MARK: Fonts

    @Test func fontsMatchTheDesign() {
        let t = Theme.default
        #expect(t.fontUI.family == nil)
        #expect(t.fontUI.title == 12.5 && t.fontUI.body == 11 && t.fontUI.caption == 10.5)
        #expect(t.fontMono.family == "JetBrains Mono")
        #expect(t.fontMono.postScriptName == "JetBrainsMono-Regular")
        #expect(t.fontMono.fallback == "Menlo")
        #expect(t.fontMono.terminal == 14 && t.fontMono.detail == 10 && t.fontMono.statusBar == 10.5)
        #expect(Theme.allPresets.allSatisfy { $0.fontUI == t.fontUI && $0.fontMono == t.fontMono })
    }

    // MARK: Spot checks against the artboards

    @Test func midnightIndigoMatchesArtboard2c1() {
        let t = Theme.midnightIndigo
        #expect(t.windowBackground.hexString == "#1a1d30")
        #expect(t.titlebar.hexString == "rgba(38,42,64,.95)")
        #expect(t.sidebarBackground.hexString == "#20243a")
        #expect(t.terminalBackground.hexString == "#171a2b")
        #expect(t.statusBarBackground.hexString == "#262a42")
        #expect(t.foreground.hexString == "#dde2f5")
        #expect(t.terminalForeground.hexString == "#d6dbf0")
        #expect(t.foregroundMuted.hexString == "#98a0c2")
        #expect(t.groupHeaderText.hexString == "#ccd1e8")
        #expect(t.summaryText.hexString == "#b6bcd8")
        #expect(t.statusBarText.hexString == "#a8b0d0")
        #expect(t.meterTrack.hexString == "rgba(255,255,255,.16)")
        #expect(t.contextMeter.hexString == "#4ade80")
        #expect(t.usageMeter.hexString == "#8b93f8")
        #expect(t.accent.hexString == "#8b93f8")
        #expect(t.selection.hexString == "rgba(139,147,248,.22)")
        #expect(t.diffRemove.hexString == "#f28b8b")   // design.md used to say #f07a7a (that is 2a's)
        #expect(t.idle.hexString == "rgba(255,255,255,.30)")
    }

    @Test func lightMatchesArtboard1b() {
        let t = Theme.light
        #expect(t.terminalBackground.hexString == "#ffffff")
        #expect(t.foreground.hexString == "#26292e")
        #expect(t.idle.hexString == "rgba(0,0,0,.22)")
        #expect(t.needsYouText.hexString == "#b06e10")
        #expect(t.groupHeaderText.hexString == "#5f646d")
        #expect(t.statusBarText.hexString == "#6e7481")
        #expect(t.meterTrack.hexString == "rgba(0,0,0,.12)")
        #expect(t.usageMeter.hexString == "#3a66b5")
    }

    @Test(arguments: Theme.allPresets)
    func metersFollowTheArtboards(theme: Theme) {
        // Every artboard fills the context bar with its working green and the usage bar with its
        // blue, on a translucent track that lightens a dark bar and darkens a light one.
        #expect(theme.contextMeter == theme.working)
        #expect(theme.usageMeter != theme.contextMeter)
        #expect(theme.meterTrack.a < 1)
        #expect(theme.meterTrack.a >= 0.1)
        let over = theme.meterTrack.over(theme.statusBarBackground)
        #expect(theme.isDark
                ? over.relativeLuminance > theme.statusBarBackground.relativeLuminance
                : over.relativeLuminance < theme.statusBarBackground.relativeLuminance,
                "\(theme.preset) track does not stand off the bar")
        #expect(theme.contextMeter.contrastRatio(against: over) >= 2, "\(theme.preset) context fill")
        #expect(theme.usageMeter.contrastRatio(against: over) >= 2, "\(theme.preset) usage fill")
    }

    // MARK: RGB

    @Test func rgbHelpers() {
        #expect(RGB(hex: 0x141624).hexString == "#141624")
        #expect(RGB(hex: 0xffffff, alpha: 0.3).hexString == "rgba(255,255,255,.30)")
        #expect(RGB(rgb: 31, 34, 54, alpha: 0.95) == RGB(hex: 0x1f2236, alpha: 0.95))
        #expect(abs(RGB.white.contrastRatio(against: .black) - 21) < 1e-9)
        #expect(abs(RGB.black.contrastRatio(against: .white) - 21) < 1e-9)
        #expect(RGB.black.mixed(with: .white, amount: 0) == .black)
        #expect(RGB.black.mixed(with: .white, amount: 1) == .white)
        #expect(RGB(hex: 0xffffff, alpha: 0.5).over(.black) == RGB(r: 0.5, g: 0.5, b: 0.5))
    }

    // MARK: design.md table

    /// Prints the token table from the real structs, one column per preset.
    /// Run with `swift test --filter ThemeTests/printsDesignTable` to eyeball the values.
    @Test func printsDesignTable() {
        let presets = Theme.allPresets
        var lines: [String] = []
        lines.append("| Token | " + presets.map(\.columnTitle).joined(separator: " | ") + " |")
        lines.append("|---|" + presets.map { _ in "---|" }.joined())
        let names = presets[0].colourTokens.map(\.name)
        for name in names {
            let cells = presets.map { theme in
                theme.colourTokens.first { $0.name == name }!.colour.hexString
            }
            lines.append("| \(name) | " + cells.joined(separator: " | ") + " |")
        }
        for slot in 0..<16 {
            let cells = presets.map { $0.terminalPalette16[slot].hexString }
            lines.append("| ansi \(slot) | " + cells.joined(separator: " | ") + " |")
        }
        let table = lines.joined(separator: "\n")
        print("\n" + table + "\n")
        #expect(lines.count == 2 + names.count + 16)
    }
}

// MARK: - Helpers

/// Keeps parameterised test output readable: one preset name per case instead of the whole struct.
extension Theme: CustomTestStringConvertible {
    public var testDescription: String { preset.rawValue }
}

extension Theme {
    /// Every RGB token by name, in declaration order (excludes the palette array and fonts).
    var colourTokens: [(name: String, colour: RGB)] {
        Mirror(reflecting: self).children.compactMap { child in
            guard let label = child.label, let colour = child.value as? RGB else { return nil }
            return (label, colour)
        }
    }

    var columnTitle: String {
        switch preset {
        case .midnightIndigo: "2c.1 Midnight indigo (default)"
        case .graphite: "2a Graphite"
        case .warmCharcoal: "2b Warm charcoal"
        case .dark: "1a Dark"
        case .light: "1b Light"
        }
    }
}
