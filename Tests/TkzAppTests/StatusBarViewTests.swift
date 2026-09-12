import AppKit
import Testing
import TkzCore
@testable import TkzApp

/// Headless tests for the 36 pt status strip (TKZ-18, M2.2; resized with 2c.1 on 2026-09-12).
///
/// Content is asserted through `StatusBarView.segments(for:theme:)` — the pure function that turns
/// the model into what gets drawn — and geometry/theming through an offscreen `NSBitmapImageRep`,
/// so nothing here needs a window or a running app.
@MainActor
struct StatusBarViewTests {

    // MARK: Helpers

    /// A model with every field populated — the design's example strip.
    static let full = StatusBarModel(
        branch: "feature/tkz-18-main-window",
        isWorktree: true,
        modelName: "Sonnet 4.5",
        diffAdded: 142,
        diffRemoved: 38,
        diffFiles: 12,
        ahead: 0,
        behind: 2,
        ports: [5173, 3000],
        contextPercent: 62,
        sessionUsage: .init(percent: 5, resetsIn: .seconds(2 * 3_600)),
        weeklyUsage: .init(percent: 41, resetsIn: .seconds(4 * 86_400 + 12 * 3_600))
    )

    /// The same strip with every meter past a threshold — the one part of the footer that comes
    /// from Thomas rather than from an artboard.
    static let hot = StatusBarModel(
        branch: "feature/tkz-18-main-window",
        modelName: "Sonnet 4.5",
        contextPercent: 88,
        sessionUsage: .init(percent: 74),
        weeklyUsage: .init(percent: 96)
    )

    /// Renders the view offscreen at 2× so text is legible in the written PNG.
    static func render(_ view: StatusBarView, width: CGFloat) -> NSBitmapImageRep {
        _ = NSApplication.shared
        view.frame = NSRect(x: 0, y: 0, width: width, height: StatusBarView.height)
        let scale = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width) * scale,
            pixelsHigh: Int(StatusBarView.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: width, height: StatusBarView.height)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    static func srgb(_ rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    static func isClose(_ color: NSColor?, _ token: RGB, tolerance: CGFloat = 0.02) -> Bool {
        guard let color else { return false }
        let expected = token.nsColor.usingColorSpace(.sRGB)!
        return abs(color.redComponent - expected.redComponent) < tolerance
            && abs(color.greenComponent - expected.greenComponent) < tolerance
            && abs(color.blueComponent - expected.blueComponent) < tolerance
    }

    static func texts(_ model: StatusBarModel, _ theme: Theme = .default) -> [String] {
        StatusBarView.segments(for: model, theme: theme).map(\.plainText)
    }

    // MARK: Geometry

    @Test func isExactlyThirtySixPointsTall() {
        let view = StatusBarView()
        #expect(StatusBarView.height == 36)
        #expect(view.intrinsicContentSize.height == 36)
        // The height constraint installed in init pins it regardless of content.
        #expect(view.fittingSize.height == 36)
        #expect(view.frame.height == 36)
    }

    // MARK: Empty model

    @Test func emptyModelRendersWithoutSeparatorsOrCrash() {
        let view = StatusBarView(theme: .default, model: .empty)
        #expect(StatusBarView.segments(for: .empty, theme: .default).isEmpty)
        #expect(view.accessibilityValue() as? String == "")

        let rep = Self.render(view, width: 600)
        // Nothing but the background band (plus the top hairline, which we avoid by sampling low).
        for x in stride(from: 4, to: 1_190, by: 97) {
            #expect(Self.isClose(Self.srgb(rep, x: x, y: 40), Theme.default.statusBarBackground))
        }
    }

    @Test func partialModelDoesNotEmitDanglingSeparators() {
        // Only usage%, i.e. a hole on both sides of the strip.
        let model = StatusBarModel(weeklyUsage: .init(percent: 5))
        let view = StatusBarView(theme: .default, model: model)
        #expect(view.accessibilityValue() as? String == "Usage 5%")
        #expect(!((view.accessibilityValue() as? String ?? "").contains("\u{00B7}")))
    }

    // MARK: Per-field segments

    @Test func branchSegmentAppearsOnlyWhenSet() {
        #expect(!Self.texts(.empty).contains { $0.contains("\u{2387}") })
        #expect(Self.texts(StatusBarModel(branch: "main")).contains("\u{2387} main"))
    }

    @Test func worktreePillAppearsOnlyWhenTrue() {
        #expect(!Self.texts(StatusBarModel(isWorktree: false)).contains("WT"))
        #expect(!Self.texts(.empty).contains("WT"))
        #expect(Self.texts(StatusBarModel(isWorktree: true)).contains("WT"))
    }

    @Test func modelBadgeAppearsOnlyWhenSetAndIsUppercased() {
        // 2c.1 sets the badge in caps; the tooltip keeps the name as the sidecar reported it.
        #expect(Self.texts(.empty).isEmpty)
        #expect(Self.texts(StatusBarModel(modelName: "Opus 4.6")) == ["OPUS 4.6"])
        let item = StatusBarView.items(
            for: StatusBarModel(modelName: "Opus 4.6"), theme: .default).first
        #expect(item?.tooltip == "Model Opus 4.6")
    }

    @Test func diffCountsAndFileCountCollapseIndependently() {
        #expect(Self.texts(StatusBarModel(diffAdded: 142)) == ["+142"])
        #expect(Self.texts(StatusBarModel(diffRemoved: 38)) == ["\u{2212}38"])
        #expect(Self.texts(StatusBarModel(diffAdded: 142, diffRemoved: 38)) == ["+142 \u{2212}38"])
        #expect(Self.texts(StatusBarModel(diffFiles: 12)) == ["12 files"])
        #expect(Self.texts(StatusBarModel(diffFiles: 1)) == ["1 file"])
    }

    @Test func aheadBehindCollapseIndependently() {
        #expect(Self.texts(StatusBarModel(ahead: 3)) == ["\u{2191}3"])
        #expect(Self.texts(StatusBarModel(behind: 2)) == ["\u{2193}2"])
        #expect(Self.texts(StatusBarModel(ahead: 0, behind: 2)) == ["\u{2191}0 \u{2193}2"])
    }

    @Test func portsAreSortedAndEmptyListCollapses() {
        #expect(Self.texts(StatusBarModel(ports: [])).isEmpty)
        // Since M4.2 each port is its own item so it can carry its own tooltip and URL; they are
        // still drawn as one group (`:3000 :5173`, no ` · ` between them) — see
        // `StatusBarInteractionTests.eachPortIsItsOwnClickableItemButOneVisualGroup`.
        #expect(Self.texts(StatusBarModel(ports: [5173, 3000])) == [":3000", ":5173"])
    }

    @Test func contextAndUsageSegments() {
        #expect(Self.texts(StatusBarModel(contextPercent: 62)) == ["Context 62%"])
        // 2c.1: one `Usage` segment carrying both windows, session first.
        #expect(Self.texts(StatusBarModel(
            sessionUsage: .init(percent: 5), weeklyUsage: .init(percent: 41)))
                == ["Usage 5% \u{00B7} 41%"])
        // Either window alone collapses the meter back to a single bar and a single number.
        #expect(Self.texts(StatusBarModel(sessionUsage: .init(percent: 5))) == ["Usage 5%"])
        #expect(Self.texts(StatusBarModel(weeklyUsage: .init(percent: 41))) == ["Usage 41%"])
    }

    @Test func theUsageMeterStacksSessionOverWeekly() throws {
        let segment = try #require(StatusBarView.segments(
            for: StatusBarModel(
                sessionUsage: .init(percent: 5), weeklyUsage: .init(percent: 41)),
            theme: .default).first)
        guard case .meter(let label, let bars, let value) = segment else {
            Issue.record("usage should be a meter"); return
        }
        #expect(label.text == "Usage")
        #expect(bars.count == 2)
        #expect(bars[0].fraction == 0.05)
        #expect(bars[1].fraction == 0.41)
        // The weekly bar is the same hue at half alpha while it is in the normal band.
        #expect(bars[0].fill == Theme.default.usageMeter)
        #expect(bars[1].fill.a == Theme.default.usageMeter.a * 0.5)
        #expect(value.map(\.text) == ["5%", " \u{00B7} ", "41%"])
    }

    @Test func aMeterTurnsAmberPastSeventyAndRedPastNinety() {
        // Not from an artboard — Thomas' thresholds. Both bounds are exclusive.
        for theme in Theme.allPresets {
            func fill(_ percent: Int) -> RGB {
                StatusBarView.meterFill(percent: percent, base: theme.contextMeter, theme: theme)
            }
            #expect(fill(0) == theme.contextMeter)
            #expect(fill(70) == theme.contextMeter)
            #expect(fill(71) == theme.meterWarn)
            #expect(fill(90) == theme.meterWarn)
            #expect(fill(91) == theme.meterDanger)
            #expect(fill(100) == theme.meterDanger)
        }
    }

    @Test func aWeeklyBarPastAThresholdStopsBeingDimmed() throws {
        // A warning that has been faded out is not a warning: the half-alpha treatment only
        // applies while the weekly bar is still in its normal band.
        let segment = try #require(StatusBarView.segments(
            for: StatusBarModel(sessionUsage: .init(percent: 5), weeklyUsage: .init(percent: 95)),
            theme: .default).first)
        guard case .meter(_, let bars, _) = segment else {
            Issue.record("usage should be a meter"); return
        }
        #expect(bars[1].fill == Theme.default.meterDanger)
        #expect(bars[1].fill.a == 1)
    }

    @Test func fullModelHasEverySegmentInDesignOrder() {
        #expect(Self.texts(Self.full) == [
            "\u{2387} feature/tkz-18-main-window",
            "WT",
            "SONNET 4.5",
            "+142 \u{2212}38",
            "12 files",
            "\u{2191}0 \u{2193}2",
            ":3000",
            ":5173",
            "Context 62%",
            "Usage 5% \u{00B7} 41%",
        ])
    }

    @Test func resetDurationFormatting() {
        #expect(StatusBarModel.formatResetsIn(.seconds(4 * 86_400 + 12 * 3_600)) == "4d 12h")
        #expect(StatusBarModel.formatResetsIn(.seconds(2 * 86_400)) == "2d")
        #expect(StatusBarModel.formatResetsIn(.seconds(12 * 3_600 + 30 * 60)) == "12h 30m")
        #expect(StatusBarModel.formatResetsIn(.seconds(45 * 60)) == "45m")
        #expect(StatusBarModel.formatResetsIn(.seconds(30)) == "30s")
        #expect(StatusBarModel.formatResetsIn(.seconds(-5)) == "0s")
    }

    // MARK: Tokens

    @Test func diffCountsUseTheDiffTokens() {
        for theme in Theme.allPresets {
            let segments = StatusBarView.segments(
                for: StatusBarModel(diffAdded: 142, diffRemoved: 38), theme: theme
            )
            guard case .runs(let runs) = segments[0] else {
                Issue.record("diff segment should be inline runs")
                return
            }
            #expect(runs.first { $0.text == "+142" }?.color == theme.diffAdd)
            #expect(runs.first { $0.text == "\u{2212}38" }?.color == theme.diffRemove)
        }
    }

    @Test func worktreePillUsesWtTokens() {
        for theme in Theme.allPresets {
            let segments = StatusBarView.segments(for: StatusBarModel(isWorktree: true), theme: theme)
            #expect(segments == [.pill(
                text: "WT", foreground: theme.wtText, background: theme.wtBackground,
                border: nil, tracking: 0)])
        }
    }

    @Test func secondaryTextUsesTheStatusBarTokens() {
        // 2c.1: the branch segment is the WT lavender, the base text is `statusBarText`, and the
        // percentages are the terminal foreground — the way every artboard draws the footer.
        for theme in Theme.allPresets {
            let segments = StatusBarView.segments(for: Self.full, theme: theme)
            func colors(of text: String) -> [RGB]? {
                segments.first { $0.plainText == text }?.colors
            }
            #expect(colors(of: "\u{2387} feature/tkz-18-main-window") == [theme.wtText, theme.wtText])
            #expect(colors(of: "12 files") == [theme.statusBarText])
            #expect(colors(of: "\u{2191}0 \u{2193}2") == [theme.statusBarText, theme.statusBarText, theme.statusBarText])
            #expect(colors(of: ":3000") == [theme.statusBarText])
            #expect(colors(of: "Context 62%")
                    == [theme.statusBarText, theme.contextMeter, theme.meterTrack, theme.terminalForeground])
            var dimmedUsage = theme.usageMeter
            dimmedUsage.a *= 0.5
            #expect(colors(of: "Usage 5% \u{00B7} 41%") == [
                theme.statusBarText,
                theme.usageMeter, theme.meterTrack,
                dimmedUsage, theme.meterTrack,
                theme.terminalForeground, theme.statusBarText, theme.terminalForeground,
            ])
            // 2c.1's model badge is outlined in its own text colour, not filled.
            #expect(colors(of: "SONNET 4.5")
                    == [theme.statusBarText, .clear, theme.statusBarText])
        }
    }

    @Test func metersClampAndKeepTheNumber() throws {
        // The bar is capped at full; the number still says what the reader reported.
        let over = try #require(
            StatusBarView.segments(for: StatusBarModel(contextPercent: 104), theme: .default).first)
        guard case .meter(_, let bars, let value) = over else {
            Issue.record("context should be a meter"); return
        }
        #expect(bars.map(\.fraction) == [1])
        #expect(value.map(\.text) == ["104%"])
        let low = try #require(StatusBarView.segments(
            for: StatusBarModel(weeklyUsage: .init(percent: 5)), theme: .default).first)
        guard case .meter(_, let usageBars, _) = low else {
            Issue.record("usage should be a meter"); return
        }
        #expect(usageBars.map(\.fraction) == [0.05])
    }

    @Test func meterPaintsItsFillAndTrackWhereItSaysItDoes() throws {
        // Draws the strip and samples inside the fill, inside the unfilled track, and just below
        // the track (background), using the same rects `draw` used — so the geometry and the
        // colours are both asserted against what was actually painted.
        for theme in Theme.allPresets {
            let model = StatusBarModel(contextPercent: 62)
            let view = StatusBarView(theme: theme, model: model)
            let rep = Self.render(view, width: 600)
            let placed = try #require(view.placement().first)
            let rects = try #require(view.meterRects(placed.item.segment, at: placed.frame.minX).first)
            #expect(rects.track.width == StatusBarView.meterWidth)
            #expect(rects.track.height == StatusBarView.meterHeight)
            #expect(rects.fill.width == (StatusBarView.meterWidth * 0.62).rounded())

            // The bitmap is 2× and y-flipped relative to the view.
            func sample(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
                Self.srgb(rep, x: Int(x * 2), y: Int((StatusBarView.height - y) * 2))
            }
            let fillColor = sample(rects.fill.minX + 4, rects.fill.midY)
            let trackColor = sample(rects.track.maxX - 4, rects.track.midY)
            let below = sample(rects.track.midX, rects.track.minY - 4)
            #expect(Self.isClose(fillColor, theme.contextMeter), "\(theme.preset) fill")
            #expect(Self.isClose(trackColor, theme.meterTrack.over(theme.statusBarBackground)),
                    "\(theme.preset) track")
            #expect(Self.isClose(below, theme.statusBarBackground), "\(theme.preset) below")
            // The right edge of the strip is the number, then the inset: the meter ends inside it.
            #expect(rects.track.maxX + StatusBarView.meterGap < placed.frame.maxX)
        }
    }

    @Test func fontSizeComesFromTheTokenNotALiteral() {
        // The family is not asserted: FontSet does not register JetBrains Mono in this process, so
        // resolution legitimately falls back to Menlo. The *size* must still be the design token.
        #expect(Theme.default.fontMono.statusBar == 12)
        #expect(Theme.Fonts.mono(Theme.default.fontMono.statusBar).pointSize == 12)
    }

    @Test func nonDefaultPresetProducesDifferentColours() {
        // Content is identical; only the theme changes. Both the background and the text tokens
        // must follow the preset, proving nothing is hardcoded to 2c.
        let dark = StatusBarView(theme: .midnightIndigo, model: Self.full)
        let light = StatusBarView(theme: .light, model: Self.full)

        let darkRep = Self.render(dark, width: 1_240)
        let lightRep = Self.render(light, width: 1_240)

        #expect(Self.isClose(Self.srgb(darkRep, x: 20, y: 40), Theme.midnightIndigo.statusBarBackground))
        #expect(Self.isClose(Self.srgb(lightRep, x: 20, y: 40), Theme.light.statusBarBackground))
        #expect(!Self.isClose(Self.srgb(lightRep, x: 20, y: 40), Theme.midnightIndigo.statusBarBackground))

        let darkSegments = StatusBarView.segments(for: Self.full, theme: .midnightIndigo)
        let lightSegments = StatusBarView.segments(for: Self.full, theme: .light)
        #expect(darkSegments.map(\.plainText) == lightSegments.map(\.plainText))
        #expect(darkSegments.map(\.colors) != lightSegments.map(\.colors))
    }

    // MARK: Truncation

    @Test func narrowWidthTruncatesInsteadOfOverflowing() {
        let view = StatusBarView(theme: .default, model: Self.full)
        let width: CGFloat = 320
        let rep = Self.render(view, width: width)
        // The 15 pt trailing inset must stay pure background at every row below the hairline:
        // if a segment had overflowed it would paint here.
        for x in (Int(width) * 2 - 20)..<(Int(width) * 2) {
            for y in stride(from: 6, to: 58, by: 8) {
                #expect(Self.isClose(Self.srgb(rep, x: x, y: y), Theme.default.statusBarBackground),
                        "pixel (\(x),\(y)) is not background — content overflowed")
            }
        }
    }

    // MARK: Visual sanity (writes PNGs to the temp dir; inspected by hand during TKZ-18)

    @Test func writesInspectionPngs() throws {
        // Temp dir only, and removed again unless TKZMUX_KEEP_SNAPSHOTS is set — the escape hatch
        // for looking at the strip by hand. Never touches a real user directory.
        let keep = ProcessInfo.processInfo.environment["TKZMUX_KEEP_SNAPSHOTS"] != nil
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkzmux-statusbar-snapshots", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if !keep { try? FileManager.default.removeItem(at: dir) } }

        let cases: [(String, StatusBarView, CGFloat)] = [
            ("wide-2c", StatusBarView(theme: .midnightIndigo, model: Self.full), 1_240),
            ("narrow-2c", StatusBarView(theme: .midnightIndigo, model: Self.full), 480),
            // Too narrow even for the branch: exercises the `…` truncation branch.
            ("ellipsis-2c", StatusBarView(theme: .midnightIndigo, model: Self.full), 150),
            ("wide-light", StatusBarView(theme: .light, model: Self.full), 1_240),
            // The amber/red steps, which no artboard draws: context in the warning band, the
            // weekly quota over the danger one.
            ("hot-2c", StatusBarView(theme: .midnightIndigo, model: Self.hot), 1_240),
        ]
        for (name, view, width) in cases {
            let rep = Self.render(view, width: width)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let url = dir.appendingPathComponent("\(name).png")
            try png.write(to: url)
            print("status-bar snapshot: \(url.path)")
            #expect(png.count > 0)
        }
    }
}
