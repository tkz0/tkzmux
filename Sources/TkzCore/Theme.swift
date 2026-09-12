// TkzCore — theme tokens.
//
// Source of truth: the Claude Design file `Terminal Main Window.dc.html` (project 452d6955-…), five artboards:
// 2c.1 Midnight indigo (default), 2a Graphite, 2b Warm charcoal, 1a Dark, 1b Light. 1b has since been
// redrawn as the *indigo* light aligned with the 2c family, and the 4a–4f series gives it six feature
// screens (4a main, 4b changes, 4c/4d splits, 4e first prompt, 4f search); `light` follows those. Every preset is the same
// token set; nothing in the app may branch on the preset name. Extraction rule per token is listed next to
// the token; `ThemeTests.printsDesignTable` prints the resulting values as one table.

/// One complete set of colour and font tokens. All tokens are non-optional by construction.
public struct Theme: Hashable, Sendable {
    public enum Preset: String, CaseIterable, Hashable, Sendable {
        case midnightIndigo   // 2c
        case graphite         // 2a
        case warmCharcoal     // 2b
        case dark             // 1a
        case light            // 1b
    }

    public let preset: Preset
    public let isDark: Bool

    // MARK: Surfaces
    public let windowBackground: RGB      // outer window background
    public let titlebar: RGB              // 48 pt title bar (translucent in the design; vibrancy is the app's call)
    public let sidebarBackground: RGB     // <aside>
    public let terminalBackground: RGB    // <main>; also libghostty COLOR_BACKGROUND
    public let statusBarBackground: RGB   // 36 pt footer

    // MARK: Text
    public let foreground: RGB            // sidebar session title (12.5 pt, weight 500) — primary UI text
    public let terminalForeground: RGB    // terminal text; libghostty COLOR_FOREGROUND (dimmer than `foreground` in every artboard)
    public let foregroundMuted: RGB       // "— <group>" subtitle in the title bar; terminal secondary lines
    public let foregroundDim: RGB         // search hint, chevrons, ＋ (identical to muted in 1a: that is what the artboard does)
    public let groupHeaderText: RGB       // uppercase group name in the sidebar
    public let summaryText: RGB           // "N WORKING" / "N NEED YOU" words in the summary strip (the dots carry the status colour)
    public let statusBarText: RGB         // status bar base text (files, ↑↓, ports, "Context"/"Usage" labels)

    // MARK: Meters (status bar `Context ▬▬ 62%` / stacked `Usage ▬ / ▬ 5% · 41%`, 50 × 4.5 pt)
    public let meterTrack: RGB            // the unfilled part of the bar (translucent)
    public let contextMeter: RGB          // context fill — the preset's working green
    public let usageMeter: RGB            // usage fill — the preset's blue
    /// A meter past 70 %. **Not from an artboard** — 2c.1 draws every bar in one colour; Thomas
    /// asked for a warning step so a quota running out is visible without reading the number.
    /// Every preset reuses its own `waiting` amber rather than introducing a sixth hue.
    public let meterWarn: RGB
    /// A meter past 90 %, same story: the preset's own `diffRemove` red.
    public let meterDanger: RGB

    // MARK: Accent & selection
    public let accent: RGB                // "＋ New session…" button background
    public let accentText: RGB            // text on the accent button
    public let selection: RGB             // selected sidebar row background (`selBg` in the design's data script)

    // MARK: Session status
    public let working: RGB               // status dot + "N working"
    public let waiting: RGB               // status dot + "N need you"
    public let idle: RGB                  // translucent; kept, but nothing draws it — the idle dot is hidden
    public let needsYouText: RGB          // NEEDS YOU badge
    public let needsYouBackground: RGB
    /// 2c.6: the `<mark>` behind the matched characters in a search hit. The same amber as
    /// ``needsYouBackground`` but carried at .35 — a highlight has to read as a highlight over a
    /// selected row, which the badge's .16 does not.
    public let searchMatchBackground: RGB
    /// Text colour inside that highlight (2c.6 lifts it well clear of ``needsYouText``).
    public let searchMatchText: RGB

    // MARK: Badges, groups, diff, separators
    public let wtText: RGB                // WT badge (sidebar row and status bar)
    public let wtBackground: RGB
    public let groupEdgeDefault: RGB      // 2 pt group colour edge (the "Toolbox" example group)
    public let diffAdd: RGB               // +142
    public let diffRemove: RGB            // −38
    public let border: RGB                // sidebar border-right / title-bar border-bottom
    /// Status-bar PR badge (icon + `#418`) while the PR is open. 2c.1 draws it in GitHub's own
    /// open green (`#3fb950`), not a preset colour, so every dark preset shares it; the light
    /// preset takes GitHub's light-mode green, since the dark one is 2.2:1 on 1b's strip.
    public let prOpen: RGB
    /// The same badge once the PR is merged. No artboard shows one; GitHub's merged purple
    /// (`#a371f7`) lifted one step so it clears 4.5:1 on every dark strip, and GitHub's
    /// light-mode purple on 1b.
    public let prMerged: RGB

    // MARK: Panes (artboards 2c.3 / 2c.4: the 28 pt pane header, the focus ring, the 7 pt grip divider)
    public let paneHeaderBackground: RGB          // header of the focused pane
    public let paneHeaderBackgroundInactive: RGB  // header of every other pane
    public let paneHeaderPath: RGB                // the `~/dev/repo` line on the focused header
    public let paneHeaderPathInactive: RGB        // the same line on an unfocused header (2c.3: foregroundDim)
    public let focusRing: RGB                     // 1.5 pt inset ring around the focused pane — accent at .65
    public let dividerGrip: RGB                   // the 3 × 44 pt pill in the middle of a divider — accent at .55
    public let dividerShade: RGB                  // the divider gradient's two dark ends
    public let dividerHighlight: RGB              // the divider gradient's light middle

    /// ANSI 0…7 then bright 8…15, all opaque. Built by `Theme.palette16`; see the rule there.
    public let terminalPalette16: [RGB]

    public let fontUI: Fonts.UI
    public let fontMono: Fonts.Mono

    public static let `default`: Theme = .midnightIndigo
    public static let allPresets: [Theme] = [.midnightIndigo, .graphite, .warmCharcoal, .dark, .light]

    public static func preset(_ preset: Preset) -> Theme {
        allPresets.first { $0.preset == preset }!
    }

    /// The preset a light/dark toggle lands on from `preset`.
    ///
    /// The pairing is *data in this file* so that no call site ever names a preset — the rule in the
    /// header. Only 2c and 1b are paired today, because only those two are reachable; when a picker
    /// gives graphite or warm charcoal a light twin, this table is the one line that changes.
    public static func toggled(_ preset: Preset) -> Preset {
        switch preset {
        case .midnightIndigo, .graphite, .warmCharcoal, .dark: .light
        case .light: .midnightIndigo
        }
    }
}

// MARK: - Fonts

extension Theme {
    /// Font families and point sizes from the design. Identical for every preset.
    public enum Fonts {
        public struct UI: Hashable, Sendable {
            /// `nil` = the system UI font (SF). The design uses `-apple-system`.
            public let family: String?
            public let title: Double      // session title, window title: 12.5 pt
            public let body: Double       // summary strip, menu rows, "— <group>" subtitle: 11 pt
            public let caption: Double    // group header (uppercase, 600), ⌘K hint: 10.5 pt
        }

        public struct Mono: Hashable, Sendable {
            public let family: String
            public let postScriptName: String   // what CTFontCreateWithName gets
            public let fallback: String         // used when the family is not installed
            public let terminal: Double         // terminal cells: 14 pt (cmux runs 14 via its
                                                // Ghostty config; 12.5 read visibly lighter)
            public let detail: Double           // sidebar "⎇ branch" line: 10 pt
            public let statusBar: Double        // status bar: 12 pt (2c.1, raised from 10.5)
            /// Rasterize terminal glyphs with CoreText font smoothing — the stem-darkening pass
            /// Ghostty calls `font-thicken`. Without it JetBrains Mono reads as a lighter face
            /// than cmux draws (compared side by side 2026-09-08).
            public let thicken: Bool
        }

        public static let ui = UI(family: nil, title: 12.5, body: 11, caption: 10.5)
        public static let mono = Mono(
            family: "JetBrains Mono",
            postScriptName: "JetBrainsMono-Regular",
            fallback: "Menlo",
            terminal: 14,
            detail: 10,
            statusBar: 12,
            thicken: true
        )
    }
}

// MARK: - Terminal palette derivation

extension Theme {
    /// The six chromatic ANSI base colours of a preset, each taken from a named artboard swatch.
    /// Mapping is by *swatch*, not by token: 2b's accent is coral, so "blue = accent" would be wrong.
    ///
    ///   1 red     = diffRemove (the −38 in the status bar)
    ///   2 green   = working
    ///   3 yellow  = waiting
    ///   4 blue    = the "● Update(…)" tool dot in the terminal mock
    ///   5 magenta = the "● Bash(…)" tool dot
    ///   6 cyan    = the teal used for the plan-mode line / group edge
    struct AnsiBase: Sendable {
        let red, green, yellow, blue, magenta, cyan: RGB
    }

    /// Builds the 16-entry palette.
    ///
    /// Dark presets:  0 = statusBarBackground, 7 = terminalForeground, 8 = foregroundDim, 15 = foreground;
    ///                bright 9…14 = base mixed 25 % toward white.
    /// Light preset:  0 = foreground, 7 = foregroundMuted, 8 = foregroundDim, 15 = terminalForeground;
    ///                bright 9…14 = base mixed 15 % toward black (never lighten toward the white background).
    /// The Claude orange (#e0956a and friends) has no ANSI slot and is skipped; Claude Code emits it as 24-bit.
    /// Slots 16…255 are not themed (renderer uses `ghostty_color_palette_default`).
    static func palette16(
        isDark: Bool,
        black: RGB, white: RGB, brightBlack: RGB, brightWhite: RGB,
        base: AnsiBase
    ) -> [RGB] {
        let brighten: (RGB) -> RGB = isDark
            ? { $0.mixed(with: .white, amount: 0.25) }
            : { $0.mixed(with: .black, amount: 0.15) }
        let chroma = [base.red, base.green, base.yellow, base.blue, base.magenta, base.cyan]
        return [black] + chroma + [white] + [brightBlack] + chroma.map(brighten) + [brightWhite]
    }
}

// MARK: - Presets

extension Theme {
    /// 2c.1 · Midnight indigo — the default.
    public static let midnightIndigo: Theme = {
        let fg = RGB(hex: 0xdde2f5), termFg = RGB(hex: 0xd6dbf0), dim = RGB(hex: 0x8890b4)
        let statusBar = RGB(hex: 0x262a42)
        let working = RGB(hex: 0x4ade80), waiting = RGB(hex: 0xfbbf54), diffRemove = RGB(hex: 0xf28b8b)
        return Theme(
            preset: .midnightIndigo, isDark: true,
            windowBackground: RGB(hex: 0x1a1d30),
            titlebar: RGB(rgb: 38, 42, 64, alpha: 0.95),
            sidebarBackground: RGB(hex: 0x20243a),
            terminalBackground: RGB(hex: 0x171a2b),
            statusBarBackground: statusBar,
            foreground: fg,
            terminalForeground: termFg,
            foregroundMuted: RGB(hex: 0x98a0c2),
            foregroundDim: dim,
            groupHeaderText: RGB(hex: 0xccd1e8),
            summaryText: RGB(hex: 0xb6bcd8),
            statusBarText: RGB(hex: 0xa8b0d0),
            meterTrack: RGB(rgb: 255, 255, 255, alpha: 0.16),
            contextMeter: working,
            usageMeter: RGB(hex: 0x8b93f8),
            meterWarn: waiting,
            meterDanger: diffRemove,
            accent: RGB(hex: 0x8b93f8),
            accentText: RGB(hex: 0x14162a),
            selection: RGB(rgb: 139, 147, 248, alpha: 0.22),
            working: working,
            waiting: waiting,
            idle: RGB(rgb: 255, 255, 255, alpha: 0.30),
            needsYouText: RGB(hex: 0xfbbf54),
            needsYouBackground: RGB(rgb: 251, 191, 84, alpha: 0.16),
            searchMatchBackground: RGB(rgb: 251, 191, 84, alpha: 0.35),
            searchMatchText: RGB(hex: 0xffe9c2),
            wtText: RGB(hex: 0xc3c8fd),
            wtBackground: RGB(rgb: 139, 147, 248, alpha: 0.20),
            groupEdgeDefault: RGB(hex: 0x41c6a8),
            diffAdd: RGB(hex: 0x4ade80),
            diffRemove: diffRemove,
            border: RGB(rgb: 255, 255, 255, alpha: 0.08),
            prOpen: RGB(hex: 0x3fb950),
            prMerged: RGB(hex: 0xb48cff),
            paneHeaderBackground: RGB(hex: 0x222639),
            paneHeaderBackgroundInactive: RGB(hex: 0x1d2033),
            paneHeaderPath: RGB(hex: 0x99a1c4),
            paneHeaderPathInactive: dim,
            focusRing: RGB(rgb: 139, 147, 248, alpha: 0.65),
            dividerGrip: RGB(rgb: 139, 147, 248, alpha: 0.55),
            dividerShade: RGB(rgb: 0, 0, 0, alpha: 0.35),
            dividerHighlight: RGB(rgb: 255, 255, 255, alpha: 0.06),
            terminalPalette16: palette16(
                isDark: true, black: statusBar, white: termFg, brightBlack: dim, brightWhite: fg,
                base: AnsiBase(
                    red: diffRemove, green: working, yellow: waiting,
                    blue: RGB(hex: 0x8b93f8), magenta: RGB(hex: 0xc084fc), cyan: RGB(hex: 0x41c6a8)
                )
            ),
            fontUI: Fonts.ui, fontMono: Fonts.mono
        )
    }()

    /// 2a · Graphite — higher contrast, blue accent.
    public static let graphite: Theme = {
        let fg = RGB(hex: 0xf5f7fa), termFg = RGB(hex: 0xe3e8f0), dim = RGB(hex: 0x8791a0)
        let statusBar = RGB(hex: 0x191b20)
        let working = RGB(hex: 0x3ddc74), waiting = RGB(hex: 0xffb454), diffRemove = RGB(hex: 0xf07a7a)
        return Theme(
            preset: .graphite, isDark: true,
            windowBackground: RGB(hex: 0x141519),
            titlebar: RGB(rgb: 30, 32, 37, alpha: 0.95),
            sidebarBackground: RGB(hex: 0x1b1d22),
            terminalBackground: RGB(hex: 0x0f1013),
            statusBarBackground: statusBar,
            foreground: fg,
            terminalForeground: termFg,
            foregroundMuted: RGB(hex: 0x98a2b3),
            foregroundDim: dim,
            groupHeaderText: RGB(hex: 0xc9ced8),
            summaryText: RGB(hex: 0xb7bec9),
            statusBarText: RGB(hex: 0xa3adbd),
            meterTrack: RGB(rgb: 255, 255, 255, alpha: 0.16),
            contextMeter: working,
            usageMeter: RGB(hex: 0x5b8def),
            meterWarn: waiting,
            meterDanger: diffRemove,
            accent: RGB(hex: 0x5b8def),
            accentText: RGB(hex: 0xffffff),
            selection: RGB(rgb: 91, 141, 239, alpha: 0.24),
            working: working,
            waiting: waiting,
            idle: RGB(rgb: 255, 255, 255, alpha: 0.30),
            needsYouText: RGB(hex: 0xffb454),
            needsYouBackground: RGB(rgb: 255, 180, 84, alpha: 0.16),
            searchMatchBackground: RGB(rgb: 255, 180, 84, alpha: 0.35),
            searchMatchText: RGB(hex: 0xffe4bd),
            wtText: RGB(hex: 0xb9cdf5),
            wtBackground: RGB(rgb: 91, 141, 239, alpha: 0.22),
            groupEdgeDefault: RGB(hex: 0x3fbf9f),
            diffAdd: RGB(hex: 0x3ddc74),
            diffRemove: diffRemove,
            border: RGB(rgb: 255, 255, 255, alpha: 0.08),
            prOpen: RGB(hex: 0x3fb950),
            prMerged: RGB(hex: 0xb48cff),
            // No split artboard for this preset: the focused header is the footer surface, the
            // inactive one sits halfway between the terminal and the sidebar, and the ring and grip
            // are the accent at the same alphas 2c.3 uses.
            paneHeaderBackground: statusBar,
            paneHeaderBackgroundInactive: RGB(hex: 0x0f1013).mixed(
                with: RGB(hex: 0x1b1d22).over(RGB(hex: 0x141519)), amount: 0.5),
            paneHeaderPath: RGB(hex: 0x98a2b3),
            paneHeaderPathInactive: dim,
            focusRing: RGB(rgb: 91, 141, 239, alpha: 0.65),
            dividerGrip: RGB(rgb: 91, 141, 239, alpha: 0.55),
            dividerShade: RGB(rgb: 0, 0, 0, alpha: 0.35),
            dividerHighlight: RGB(rgb: 255, 255, 255, alpha: 0.06),
            terminalPalette16: palette16(
                isDark: true, black: statusBar, white: termFg, brightBlack: dim, brightWhite: fg,
                base: AnsiBase(
                    red: diffRemove, green: working, yellow: waiting,
                    blue: RGB(hex: 0x5b8def), magenta: RGB(hex: 0xa58bf0), cyan: RGB(hex: 0x3fbf9f)
                )
            ),
            fontUI: Fonts.ui, fontMono: Fonts.mono
        )
    }()

    /// 2b · Warm charcoal — coral accent.
    public static let warmCharcoal: Theme = {
        let fg = RGB(hex: 0xf4eee7), termFg = RGB(hex: 0xe9e2da), dim = RGB(hex: 0x93887c)
        let statusBar = RGB(hex: 0x241e19)
        let working = RGB(hex: 0x4cc97e), waiting = RGB(hex: 0xffb454), diffRemove = RGB(hex: 0xe87f7f)
        return Theme(
            preset: .warmCharcoal, isDark: true,
            windowBackground: RGB(hex: 0x191512),
            titlebar: RGB(rgb: 40, 33, 28, alpha: 0.95),
            sidebarBackground: RGB(hex: 0x201b17),
            terminalBackground: RGB(hex: 0x141110),
            statusBarBackground: statusBar,
            foreground: fg,
            terminalForeground: termFg,
            foregroundMuted: RGB(hex: 0xa1968a),
            foregroundDim: dim,
            groupHeaderText: RGB(hex: 0xd3c9be),
            summaryText: RGB(hex: 0xc4bab0),
            statusBarText: RGB(hex: 0xb3a99d),
            meterTrack: RGB(rgb: 255, 255, 255, alpha: 0.16),
            contextMeter: working,
            usageMeter: RGB(hex: 0x7aa2e8),
            meterWarn: waiting,
            meterDanger: diffRemove,
            accent: RGB(hex: 0xe28666),
            accentText: RGB(hex: 0x2a1c14),
            selection: RGB(rgb: 226, 134, 102, alpha: 0.22),
            working: working,
            waiting: waiting,
            idle: RGB(rgb: 255, 255, 255, alpha: 0.30),
            needsYouText: RGB(hex: 0xffb454),
            needsYouBackground: RGB(rgb: 255, 180, 84, alpha: 0.16),
            searchMatchBackground: RGB(rgb: 255, 180, 84, alpha: 0.35),
            searchMatchText: RGB(hex: 0xffe4bd),
            wtText: RGB(hex: 0xf0b39c),
            wtBackground: RGB(rgb: 226, 134, 102, alpha: 0.20),
            groupEdgeDefault: RGB(hex: 0x3fbf9f),
            diffAdd: RGB(hex: 0x4cc97e),
            diffRemove: diffRemove,
            border: RGB(rgb: 255, 255, 255, alpha: 0.08),
            prOpen: RGB(hex: 0x3fb950),
            prMerged: RGB(hex: 0xb48cff),
            // No split artboard for this preset: the focused header is the footer surface, the
            // inactive one sits halfway between the terminal and the sidebar, and the ring and grip
            // are the accent at the same alphas 2c.3 uses.
            paneHeaderBackground: statusBar,
            paneHeaderBackgroundInactive: RGB(hex: 0x141110).mixed(
                with: RGB(hex: 0x201b17).over(RGB(hex: 0x191512)), amount: 0.5),
            paneHeaderPath: RGB(hex: 0xa1968a),
            paneHeaderPathInactive: dim,
            focusRing: RGB(rgb: 226, 134, 102, alpha: 0.65),
            dividerGrip: RGB(rgb: 226, 134, 102, alpha: 0.55),
            dividerShade: RGB(rgb: 0, 0, 0, alpha: 0.35),
            dividerHighlight: RGB(rgb: 255, 255, 255, alpha: 0.06),
            terminalPalette16: palette16(
                isDark: true, black: statusBar, white: termFg, brightBlack: dim, brightWhite: fg,
                base: AnsiBase(
                    red: diffRemove, green: working, yellow: waiting,
                    blue: RGB(hex: 0x7aa2e8), magenta: RGB(hex: 0xb58fd9), cyan: RGB(hex: 0x3fbf9f)
                )
            ),
            fontUI: Fonts.ui, fontMono: Fonts.mono
        )
    }()

    /// 1a · Dark — the neutral macOS-grey variant.
    public static let dark: Theme = {
        let fg = RGB(hex: 0xf4f6f9), termFg = RGB(hex: 0xdde1e8), dim = RGB(hex: 0x8b93a0)
        let statusBar = RGB(hex: 0x1f2125)
        let working = RGB(hex: 0x34b060), waiting = RGB(hex: 0xf0a03a), diffRemove = RGB(hex: 0xd16a6a)
        return Theme(
            preset: .dark, isDark: true,
            windowBackground: RGB(hex: 0x1b1d21),
            titlebar: RGB(rgb: 38, 40, 45, alpha: 0.92),
            sidebarBackground: RGB(rgb: 32, 34, 38, alpha: 0.96),
            terminalBackground: RGB(hex: 0x17181b),
            statusBarBackground: statusBar,
            foreground: fg,
            terminalForeground: termFg,
            foregroundMuted: RGB(hex: 0x8b93a0),
            foregroundDim: dim,
            groupHeaderText: RGB(hex: 0xc3c8d0),
            summaryText: RGB(hex: 0xb0b6c0),
            statusBarText: RGB(hex: 0x9aa1ac),
            meterTrack: RGB(rgb: 255, 255, 255, alpha: 0.16),
            contextMeter: working,
            usageMeter: RGB(hex: 0x4d7fd6),
            meterWarn: waiting,
            meterDanger: diffRemove,
            accent: RGB(hex: 0x4d7fd6),
            accentText: RGB(hex: 0xffffff),
            selection: RGB(rgb: 77, 127, 214, alpha: 0.20),
            working: working,
            waiting: waiting,
            idle: RGB(rgb: 255, 255, 255, alpha: 0.25),
            needsYouText: RGB(hex: 0xf0a03a),
            needsYouBackground: RGB(rgb: 240, 160, 58, alpha: 0.14),
            searchMatchBackground: RGB(rgb: 240, 160, 58, alpha: 0.35),
            searchMatchText: RGB(hex: 0xffe0b0),
            wtText: RGB(hex: 0x8fb0e8),
            wtBackground: RGB(rgb: 77, 127, 214, alpha: 0.16),
            groupEdgeDefault: RGB(hex: 0x3fa08c),
            diffAdd: RGB(hex: 0x34b060),
            diffRemove: diffRemove,
            border: RGB(rgb: 255, 255, 255, alpha: 0.06),
            prOpen: RGB(hex: 0x3fb950),
            prMerged: RGB(hex: 0xb48cff),
            // No split artboard for this preset: the focused header is the footer surface, the
            // inactive one sits halfway between the terminal and the sidebar, and the ring and grip
            // are the accent at the same alphas 2c.3 uses.
            paneHeaderBackground: statusBar,
            paneHeaderBackgroundInactive: RGB(hex: 0x17181b).mixed(
                with: RGB(rgb: 32, 34, 38, alpha: 0.96).over(RGB(hex: 0x1b1d21)), amount: 0.5),
            paneHeaderPath: RGB(hex: 0x8b93a0),
            paneHeaderPathInactive: dim,
            focusRing: RGB(rgb: 77, 127, 214, alpha: 0.65),
            dividerGrip: RGB(rgb: 77, 127, 214, alpha: 0.55),
            dividerShade: RGB(rgb: 0, 0, 0, alpha: 0.35),
            dividerHighlight: RGB(rgb: 255, 255, 255, alpha: 0.06),
            terminalPalette16: palette16(
                isDark: true, black: statusBar, white: termFg, brightBlack: dim, brightWhite: fg,
                base: AnsiBase(
                    red: diffRemove, green: working, yellow: waiting,
                    blue: RGB(hex: 0x4d7fd6), magenta: RGB(hex: 0x9a6fc9), cyan: RGB(hex: 0x3fa08c)
                )
            ),
            fontUI: Fonts.ui, fontMono: Fonts.mono
        )
    }()

    /// 1b / 4a–4f · Light — the indigo light theme and the ☀ half of the dark/light toggle.
    ///
    /// 1b was redrawn as "Light · Indigo, aligned with the 2c family", and the 4a–4f series gives
    /// that same theme six feature screens. Where the two drift — 1b draws the title `#2a2d33`, dim
    /// `#9ba1aa`, a `.09` border and a translucent sidebar — the 4a–4f values win: they cover more
    /// of the app, and 4c/4d are the only *light* split artboards, so this is the one preset besides
    /// 2c whose pane chrome is measured rather than derived from the footer surface.
    public static let light: Theme = {
        let fg = RGB(hex: 0x26292e), termFg = RGB(hex: 0x3a3e45)
        let muted = RGB(hex: 0x6a7280), dim = RGB(hex: 0x8a9099)
        let working = RGB(hex: 0x2c9e53), waiting = RGB(hex: 0xdd8a1e), diffRemove = RGB(hex: 0xc04a4a)
        let indigo = RGB(hex: 0x5661d8)
        return Theme(
            preset: .light, isDark: false,
            windowBackground: RGB(hex: 0xf3f4fa),
            titlebar: RGB(rgb: 243, 244, 251, alpha: 0.96),
            sidebarBackground: RGB(hex: 0xe9ebf6),
            terminalBackground: RGB(hex: 0xffffff),
            statusBarBackground: RGB(hex: 0xeceef8),
            foreground: fg,
            terminalForeground: termFg,
            foregroundMuted: muted,
            foregroundDim: dim,
            groupHeaderText: RGB(hex: 0x5f646d),
            summaryText: RGB(hex: 0x5f646d),
            statusBarText: RGB(hex: 0x6e7481),
            meterTrack: RGB(rgb: 0, 0, 0, alpha: 0.12),
            contextMeter: working,
            usageMeter: indigo,
            meterWarn: waiting,
            meterDanger: diffRemove,
            accent: indigo,
            accentText: RGB(hex: 0xffffff),
            selection: RGB(rgb: 86, 97, 216, alpha: 0.14),
            working: working,
            waiting: waiting,
            idle: RGB(rgb: 0, 0, 0, alpha: 0.25),
            needsYouText: RGB(hex: 0xb06e10),
            needsYouBackground: RGB(rgb: 221, 138, 30, alpha: 0.16),
            searchMatchBackground: RGB(rgb: 221, 138, 30, alpha: 0.35),
            searchMatchText: RGB(hex: 0x8a5a12),
            wtText: RGB(hex: 0x4a54c9),
            wtBackground: RGB(rgb: 86, 97, 216, alpha: 0.20),
            groupEdgeDefault: RGB(hex: 0x2c8a74),
            diffAdd: working,
            diffRemove: diffRemove,
            border: RGB(rgb: 0, 0, 0, alpha: 0.07),
            // 4a draws the badge in GitHub's *dark*-mode green (`#3fb950`), which is 2.2:1 on this
            // strip. GitHub's light-mode green is the readable equivalent at 4.4:1.
            prOpen: RGB(hex: 0x1a7f37),
            prMerged: RGB(hex: 0x8250df),
            // Measured from 4c, not derived: the focused header is the sidebar surface and the
            // inactive one the footer surface — the reverse of how the dark presets are built.
            paneHeaderBackground: RGB(hex: 0xe9ebf6),
            paneHeaderBackgroundInactive: RGB(hex: 0xeceef8),
            // 4c draws the focused path `#7c828c`, which is 3.3:1 on that header. The muted grey is
            // the readable choice, and it is what the inactive header already uses.
            paneHeaderPath: muted,
            paneHeaderPathInactive: muted,
            focusRing: RGB(rgb: 86, 97, 216, alpha: 0.65),
            dividerGrip: RGB(rgb: 86, 97, 216, alpha: 0.55),
            // Inverted from every dark preset: 4c's divider gradient is a blue-grey at both ends and
            // a *weaker* black in the middle, so over a light pane the middle still reads lighter —
            // but only once alpha is composited, which is why the invariant test composites.
            dividerShade: RGB(rgb: 30, 40, 60, alpha: 0.18),
            dividerHighlight: RGB(rgb: 0, 0, 0, alpha: 0.06),
            terminalPalette16: palette16(
                isDark: false, black: fg, white: muted, brightBlack: dim, brightWhite: termFg,
                base: AnsiBase(
                    red: diffRemove, green: working, yellow: waiting,
                    blue: indigo, magenta: RGB(hex: 0x8352b8), cyan: RGB(hex: 0x2c8a74)
                )
            ),
            fontUI: Fonts.ui, fontMono: Fonts.mono
        )
    }()
}
