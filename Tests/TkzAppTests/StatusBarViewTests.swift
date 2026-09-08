import AppKit
import Testing
import TkzCore
@testable import TkzApp

/// Headless tests for the 30 pt status strip (TKZ-18, M2.2).
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
        usagePercent: 5,
        usageResetsIn: .seconds(4 * 86_400 + 12 * 3_600)
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

    @Test func isExactlyThirtyPointsTall() {
        let view = StatusBarView()
        #expect(StatusBarView.height == 30)
        #expect(view.intrinsicContentSize.height == 30)
        // The height constraint installed in init pins it regardless of content.
        #expect(view.fittingSize.height == 30)
        #expect(view.frame.height == 30)
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
        let model = StatusBarModel(usagePercent: 5)
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

    @Test func modelBadgeAppearsOnlyWhenSet() {
        #expect(Self.texts(.empty).isEmpty)
        #expect(Self.texts(StatusBarModel(modelName: "Opus 4.6")).contains("Opus 4.6"))
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
        #expect(Self.texts(StatusBarModel(usagePercent: 5)) == ["Usage 5%"])
        #expect(Self.texts(StatusBarModel(usageResetsIn: .seconds(4 * 86_400 + 12 * 3_600)))
                == ["resets 4d 12h"])
    }

    @Test func fullModelHasEverySegmentInDesignOrder() {
        #expect(Self.texts(Self.full) == [
            "\u{2387} feature/tkz-18-main-window",
            "WT",
            "Sonnet 4.5",
            "+142 \u{2212}38",
            "12 files",
            "\u{2191}0 \u{2193}2",
            ":3000",
            ":5173",
            "Context 62%",
            "Usage 5%",
            "resets 4d 12h",
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
            #expect(segments == [.pill(text: "WT", foreground: theme.wtText, background: theme.wtBackground)])
        }
    }

    @Test func fontSizeComesFromTheTokenNotALiteral() {
        // The family is not asserted: FontSet does not register JetBrains Mono in this process, so
        // resolution legitimately falls back to Menlo. The *size* must still be the design token.
        #expect(Theme.default.fontMono.statusBar == 10.5)
        #expect(Theme.Fonts.mono(Theme.default.fontMono.statusBar).pointSize == 10.5)
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
        // The 12 pt trailing inset must stay pure background at every row below the hairline:
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
