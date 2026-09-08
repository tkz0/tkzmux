// SidebarRowViewTests — M2.3 (TKZ-19), the presentation half.
//
// What these prove, and why they are shaped this way:
//
//   1. **The rows render with no window.** Every view in `Sidebar/` draws with `CALayer`s, never
//      `draw(_:)` and never an `NSTextField`, precisely so a row can be rasterised headlessly:
//      `layoutSubtreeIfNeeded()` then `layer.render(in:)` into a `CGContext` backed by an
//      `NSBitmapImageRep`. (`NSView.cacheDisplay(in:to:)` would *not* capture custom sublayer
//      properties — the dot, the badges and the colour edge would silently vanish from the bitmap.)
//      Both 1x and 2x are exercised.
//   2. **The structural facts the ticket lists**: exact 28/44 pt heights; the pulse is attached only
//      to `working` rows and is removed on reuse and on leaving the window; `NEEDS YOU` only when
//      `needsAttention`; `WT` only when `isWorktree`; a long title truncates instead of overflowing;
//      the group edge is transparent when the group has no colour.
//   3. **The views are theme-driven, not hardcoded.** The dot colour is compared component-wise
//      against the `Theme` token for each status, and a `.light` render is shown to differ from a
//      `.midnightIndigo` one — a hardcoded `#4ade80` would pass the first check for `.midnightIndigo`
//      and fail the second.
//   4. **Rendering is deterministic.** The same model rendered twice produces byte-identical
//      pixels — nothing here may depend on `Hasher` (seeded per process), the clock, or a global.
//
// AppKit views are `@MainActor`, so the whole suite is. Serialised because these tests share the
// process-wide font registry and the `CATransaction` stack.

import AppKit
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct SidebarRowViewTests {
    // MARK: Headless rendering helper

    /// Rasterises a view's layer tree at `scale`, with no window anywhere in sight.
    static func render(_ view: NSView, scale: CGFloat) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        if let row = view as? SessionRowView { row.setContentsScale(scale) }
        if let row = view as? GroupRowView { row.setContentsScale(scale) }
        if let strip = view as? SummaryStripView { strip.setContentsScale(scale) }

        let pixelsWide = Int((view.bounds.width * scale).rounded())
        let pixelsHigh = Int((view.bounds.height * scale).rounded())
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let ctx = graphics.cgContext
        ctx.scaleBy(x: scale, y: scale)
        try #require(view.layer).render(in: ctx)
        return rep
    }

    /// Raw pixel bytes, for the determinism comparison.
    static func pixels(_ rep: NSBitmapImageRep) throws -> [UInt8] {
        let data = try #require(rep.bitmapData)
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    /// `true` when anything at all was drawn (guards against "rendered a blank bitmap and passed").
    static func isNonBlank(_ rep: NSBitmapImageRep) throws -> Bool {
        try pixels(rep).contains { $0 != 0 }
    }

    static func components(_ color: CGColor?) -> [CGFloat] {
        guard let color, let converted = color.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
        ) else { return [] }
        return converted.components ?? []
    }

    static func approxEqual(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.002 }
    }

    static func sessionRow(
        _ model: SidebarSessionRowModel,
        theme: Theme = .default,
        width: Double = SidebarMetrics.sidebarWidth
    ) -> SessionRowView {
        let row = SessionRowView(frame: NSRect(x: 0, y: 0, width: width, height: SessionRowView.rowHeight))
        row.configure(model, theme: theme)
        return row
    }

    static func groupRow(
        _ model: SidebarGroupRowModel,
        theme: Theme = .default,
        width: Double = SidebarMetrics.sidebarWidth
    ) -> GroupRowView {
        let row = GroupRowView(frame: NSRect(x: 0, y: 0, width: width, height: GroupRowView.rowHeight))
        row.configure(model, theme: theme)
        return row
    }

    static let sample = SidebarSessionRowModel(
        title: "tkzmux sidebar",
        branch: "tkz-19-sidebar",
        isWorktree: true,
        status: .working,
        accountLabel: "PR",
        accountColor: SidebarSessionRowModel.accountChipColor(forKey: "private"),
        needsAttention: false,
        isSelected: true
    )

    // MARK: Geometry

    @Test("Row heights are exactly the design's 28 pt / 44 pt")
    func rowHeights() {
        #expect(GroupRowView.rowHeight == 28)
        #expect(SessionRowView.rowHeight == 44)
        #expect(SidebarMetrics.groupRowHeight == 28)
        #expect(SidebarMetrics.sessionRowHeight == 44)
        // The outline view returns these; a row view must also actually be that tall.
        let session = Self.sessionRow(Self.sample)
        #expect(session.bounds.height == 44)
        let group = Self.groupRow(SidebarGroupRowModel(name: "tkzmux"))
        #expect(group.bounds.height == 28)
    }

    // MARK: Headless rendering

    @Test("Every row view rasterises without a window, at 1x and 2x")
    func rendersHeadlesslyAtBothScales() throws {
        let views: [NSView] = [
            Self.sessionRow(Self.sample),
            Self.groupRow(SidebarGroupRowModel(name: "tkzmux", color: RGB(hex: 0x41c6a8), sessionCount: 3)),
            {
                let strip = SummaryStripView(frame: NSRect(
                    x: 0, y: 0, width: SidebarMetrics.sidebarWidth, height: SummaryStripView.height))
                strip.configure(SidebarSummaryModel(working: 5, needAttention: 2), theme: .default)
                return strip
            }(),
        ]
        for view in views {
            #expect(view.window == nil)
            for scale in [CGFloat(1), CGFloat(2)] {
                let rep = try Self.render(view, scale: scale)
                #expect(rep.pixelsWide == Int(view.bounds.width * scale))
                #expect(rep.pixelsHigh == Int(view.bounds.height * scale))
                #expect(try Self.isNonBlank(rep), "\(type(of: view)) rendered a blank bitmap at \(scale)x")
            }
        }
    }

    @Test("The same model renders byte-identically twice — no per-call randomness")
    func renderIsDeterministic() throws {
        let a = try Self.pixels(Self.render(Self.sessionRow(Self.sample), scale: 2))
        let b = try Self.pixels(Self.render(Self.sessionRow(Self.sample), scale: 2))
        #expect(a == b)
        #expect(a.contains { $0 != 0 })

        // Re-configuring one live view with the same model must also be a no-op visually.
        let row = Self.sessionRow(Self.sample)
        let first = try Self.pixels(Self.render(row, scale: 2))
        row.configure(Self.sample, theme: .default)
        let second = try Self.pixels(Self.render(row, scale: 2))
        #expect(first == second)
    }

    @Test("The account chip colour is stable across processes (FNV-1a, not Hasher)")
    func accountChipColourIsStable() {
        // Literal expectation: a seeded `hashValue` would change these between runs.
        #expect(SidebarSessionRowModel.accountChipColor(forKey: "private") ==
                SidebarSessionRowModel.accountChipColor(forKey: "private"))
        #expect(SidebarSessionRowModel.accountChipColor(forKey: "private").hexString == "#5b8def")
        #expect(SidebarSessionRowModel.accountChipColor(forKey: "work").hexString == "#e0956a")
    }

    // MARK: Pulse

    @Test("Only a working row pulses, and the animation lives on the layer")
    func onlyWorkingRowsPulse() {
        for status in SidebarStatus.allCases {
            let row = Self.sessionRow(SidebarSessionRowModel(title: "s", status: status))
            #expect(row.isPulsing == (status == .working), "status \(status)")
        }
        // The claim the design makes: it is a CABasicAnimation on opacity, not a timer.
        let working = Self.sessionRow(SidebarSessionRowModel(title: "s", status: .working))
        let pulse = working.statusDot.animation(forKey: StatusDotLayer.pulseAnimationKey) as? CABasicAnimation
        #expect(pulse != nil, "the pulse must be a CABasicAnimation on the dot layer, not a timer")
        #expect(pulse?.keyPath == "opacity")
        #expect(pulse?.autoreverses == true)
        #expect(pulse?.repeatCount == .infinity)
        #expect(pulse?.fromValue as? Double == 0.4)
        #expect(pulse?.toValue as? Double == 1.0)
    }

    @Test("Re-applying a working model does not stack a second animation")
    func pulseIsNotStacked() {
        let row = Self.sessionRow(SidebarSessionRowModel(title: "s", status: .working))
        for _ in 0..<5 { row.configure(SidebarSessionRowModel(title: "s", status: .working), theme: .default) }
        #expect(row.statusDot.animationKeys()?.count == 1)
    }

    @Test("Reuse and leaving the window both remove the pulse")
    func pulseIsRemovedOnReuseAndDetach() {
        let row = Self.sessionRow(SidebarSessionRowModel(title: "s", status: .working))
        #expect(row.isPulsing)
        row.prepareForReuse()
        #expect(!row.isPulsing)

        let again = Self.sessionRow(SidebarSessionRowModel(title: "s", status: .working))
        #expect(again.isPulsing)
        // `viewDidMoveToWindow` with a nil window is the detach path the outline view takes.
        again.viewDidMoveToWindow()
        #expect(!again.isPulsing)
        // …and coming back re-arms it, because the row is still `working`.
        again.statusDot.resume()
        #expect(again.isPulsing)

        // A row recycled from `working` to `idle` must not keep pulsing.
        let recycled = Self.sessionRow(SidebarSessionRowModel(title: "s", status: .working))
        recycled.configure(SidebarSessionRowModel(title: "t", status: .idle), theme: .default)
        #expect(!recycled.isPulsing)
    }

    @Test("Occlusion parks the animation by stopping the layer clock, not by removing it")
    func occlusionParksTheLayer() {
        let row = Self.sessionRow(SidebarSessionRowModel(title: "s", status: .working))
        #expect(row.statusDot.pulseSpeed == 1)
        row.setOccluded(true)
        #expect(row.statusDot.pulseSpeed == 0)
        #expect(row.isPulsing, "parking must not discard the animation")
        row.setOccluded(false)
        #expect(row.statusDot.pulseSpeed == 1)
        // Reuse resets occlusion too, or a recycled row would come back frozen.
        row.setOccluded(true)
        row.prepareForReuse()
        #expect(row.statusDot.pulseSpeed == 1)
    }

    // MARK: Badges

    @Test("NEEDS YOU appears only when needsAttention; WT only when isWorktree")
    func badgesAreConditional() throws {
        for needs in [false, true] {
            for worktree in [false, true] {
                let row = Self.sessionRow(SidebarSessionRowModel(
                    title: "s", branch: "main", isWorktree: worktree, status: .waiting, needsAttention: needs))
                #expect(row.needsYouBadgeLayer.isHidden == !needs)
                #expect(row.worktreeBadgeLayer.isHidden == !worktree)
                if needs {
                    #expect(Self.approxEqual(
                        Self.components(row.needsYouBadgeLayer.backgroundColor),
                        Self.components(Theme.default.needsYouBackground.cgColor)))
                    #expect(row.needsYouBadgeLayer.frame.width > 0)
                }
                if worktree {
                    #expect(Self.approxEqual(
                        Self.components(row.worktreeBadgeLayer.backgroundColor),
                        Self.components(Theme.default.wtBackground.cgColor)))
                }
                // Whatever is shown stays inside the row.
                for layer in [row.needsYouBadgeLayer, row.worktreeBadgeLayer] where !layer.isHidden {
                    #expect(layer.frame.minX >= 0)
                    #expect(layer.frame.maxX <= row.bounds.width)
                    #expect(layer.frame.maxY <= row.bounds.height)
                }
            }
        }
    }

    @Test("The account chip is present only with a label, and takes the colour it is given")
    func accountChipIsOptional() {
        let none = Self.sessionRow(SidebarSessionRowModel(title: "s"))
        #expect(none.accountChipLayer.isHidden)

        let tint = SidebarSessionRowModel.accountChipColor(forKey: "work")
        let chip = Self.sessionRow(SidebarSessionRowModel(title: "s", accountLabel: "AL", accountColor: tint))
        #expect(!chip.accountChipLayer.isHidden)
        let expected = RGB(r: tint.r, g: tint.g, b: tint.b, a: 0.18)
        #expect(Self.approxEqual(Self.components(chip.accountChipLayer.backgroundColor),
                                 Self.components(expected.cgColor)))
    }

    @Test("Selection paints the theme's selection token; an unselected row paints nothing")
    func selectionUsesTheToken() {
        let selected = Self.sessionRow(SidebarSessionRowModel(title: "s", isSelected: true))
        #expect(Self.approxEqual(Self.components(selected.selectionBackgroundLayer.backgroundColor),
                                 Self.components(Theme.default.selection.cgColor)))
        let plain = Self.sessionRow(SidebarSessionRowModel(title: "s", isSelected: false))
        #expect(Self.components(plain.selectionBackgroundLayer.backgroundColor).last == 0)
    }

    // MARK: Hierarchy

    /// Regression: reported from real use — "the sidebar does not have enough indentation for the
    /// group items". A session title sat at x=30 against a group name at x=25, five points apart,
    /// which reads as no hierarchy at all. `NSOutlineView.indentationPerLevel` is 0 because the rows
    /// lay themselves out, so the indent has to come from `SidebarMetrics.sessionIndent`.
    @Test("a session row's content is indented under its group header")
    func sessionRowsIndentUnderTheirGroup() {
        let group = GroupRowView()
        group.configure(SidebarGroupRowModel(name: "Northwind Trading", color: nil,
                                             isCollapsed: false, sessionCount: 12),
                        theme: .midnightIndigo)
        group.frame = CGRect(x: 0, y: 0, width: SidebarMetrics.sidebarWidth,
                             height: SidebarMetrics.groupRowHeight)
        group.layoutSubtreeIfNeeded()

        let session = SessionRowView()
        session.configure(SidebarSessionRowModel(title: "northwind", branch: "main",
                                                 isWorktree: false, status: .working,
                                                 accountLabel: nil, accountColor: nil,
                                                 needsAttention: false, isSelected: false),
                          theme: .midnightIndigo)
        session.frame = CGRect(x: 0, y: 0, width: SidebarMetrics.sidebarWidth,
                               height: SidebarMetrics.sessionRowHeight)
        session.layoutSubtreeIfNeeded()

        let groupNameX = group.nameTextLayer.frame.minX
        let sessionTitleX = session.titleTextLayer.frame.minX

        // The indent is real, not a rounding difference.
        // `Comment` is only expressible by a literal, so the message is one interpolation.
        #expect(sessionTitleX > groupNameX + 8,
                "session title \(sessionTitleX) is not indented under group name \(groupNameX)")
        // And it tracks the metric rather than a second magic number.
        #expect(sessionTitleX - groupNameX == CGFloat(SidebarMetrics.sessionIndent) + 5)
    }

    // MARK: Truncation

    @Test("A long title truncates with an ellipsis instead of overflowing the row")
    func longTitleTruncates() {
        let long = String(repeating: "a-very-long-session-title ", count: 8)
        for width in [SidebarMetrics.sidebarMinWidth, SidebarMetrics.sidebarWidth] {
            let row = Self.sessionRow(
                SidebarSessionRowModel(title: long, needsAttention: true), width: width)
            let title = row.titleTextLayer
            #expect(title.isWrapped == false)
            #expect(title.truncationMode == .end)
            #expect(title.frame.maxX <= row.bounds.width)
            let natural = SidebarLayers.width(of: long, font: row.titleFontForMeasurement)
            #expect(natural > title.frame.width, "the fixture must actually be too long at \(width) pt")
            // And the NEEDS YOU badge still gets its space rather than being pushed off the row.
            #expect(title.frame.maxX <= row.needsYouBadgeLayer.frame.minX)
        }
    }

    @Test("A long branch name never pushes the WT badge outside the row")
    func longBranchKeepsBadgeInside() {
        let row = Self.sessionRow(SidebarSessionRowModel(
            title: "s",
            branch: String(repeating: "feature/very-long-branch-", count: 4),
            isWorktree: true,
            accountLabel: "PR"
        ), width: SidebarMetrics.sidebarMinWidth)
        #expect(row.branchTextLayer.truncationMode == .end)
        #expect(row.worktreeBadgeLayer.frame.maxX <= row.bounds.width)
        #expect(row.branchTextLayer.frame.maxX <= row.bounds.width)
    }

    // MARK: Theme-driven colours

    @Test("The dot colour is the theme token for every status, in every preset")
    func dotColoursComeFromTheTheme() {
        for theme in Theme.allPresets {
            for status in SidebarStatus.allCases {
                let row = Self.sessionRow(SidebarSessionRowModel(title: "s", status: status), theme: theme)
                let dot = row.statusDot
                switch status {
                case .working:
                    #expect(Self.approxEqual(Self.components(dot.fillColor),
                                             Self.components(theme.working.cgColor)),
                            "\(theme.preset) working")
                case .waiting:
                    #expect(Self.approxEqual(Self.components(dot.fillColor),
                                             Self.components(theme.waiting.cgColor)),
                            "\(theme.preset) waiting")
                case .idle:
                    #expect(Self.approxEqual(Self.components(dot.fillColor),
                                             Self.components(theme.idle.cgColor)),
                            "\(theme.preset) idle")
                case .done:
                    #expect(Self.approxEqual(Self.components(dot.fillColor),
                                             Self.components(theme.accent.cgColor)),
                            "\(theme.preset) done")
                }
            }
        }
    }

    @Test("A non-default preset renders different colours — the views are not hardcoded to 2c")
    func lightPresetDiffers() throws {
        let model = SidebarSessionRowModel(
            title: "session", branch: "main", isWorktree: true, status: .working,
            accountLabel: "PR", needsAttention: true, isSelected: true)
        let dark = Self.sessionRow(model, theme: .midnightIndigo)
        let light = Self.sessionRow(model, theme: .light)

        #expect(!Self.approxEqual(Self.components(dark.statusDot.fillColor),
                                  Self.components(light.statusDot.fillColor)))
        #expect(!Self.approxEqual(Self.components(dark.selectionBackgroundLayer.backgroundColor),
                                  Self.components(light.selectionBackgroundLayer.backgroundColor)))
        #expect(!Self.approxEqual(Self.components(dark.needsYouBadgeLayer.backgroundColor),
                                  Self.components(light.needsYouBadgeLayer.backgroundColor)))
        #expect(try Self.pixels(Self.render(dark, scale: 2)) != Self.pixels(Self.render(light, scale: 2)))

        // The group name colour is derived from tokens too — it must invert for the light preset.
        let darkTitle = GroupRowView.groupTitleColor(.midnightIndigo)
        let lightTitle = GroupRowView.groupTitleColor(.light)
        #expect(darkTitle != lightTitle)
        // …and it reproduces the design's #ccd1e8 for 2c to within one 8-bit unit per channel.
        let target = RGB(hex: 0xccd1e8)
        #expect(abs(darkTitle.r - target.r) * 255 <= 1.5)
        #expect(abs(darkTitle.g - target.g) * 255 <= 1.5)
        #expect(abs(darkTitle.b - target.b) * 255 <= 1.5)
    }

    // MARK: Group row

    @Test("The colour edge is transparent when the group has no colour, and tinted when it has one")
    func groupEdgeReflectsTheGroupColour() {
        let plain = Self.groupRow(SidebarGroupRowModel(name: "tkzmux", color: nil))
        #expect(Self.components(plain.edgeColor).last == 0, "an uncoloured group must not borrow groupEdgeDefault")
        #expect(plain.colourEdgeLayer.frame.width == CGFloat(SidebarMetrics.groupEdgeWidth))
        #expect(plain.colourEdgeLayer.frame.height == plain.bounds.height)
        #expect(plain.colourEdgeLayer.frame.minX == 0)

        let teal = RGB(hex: 0x41c6a8)
        let coloured = Self.groupRow(SidebarGroupRowModel(name: "tkzmux", color: teal))
        #expect(Self.approxEqual(Self.components(coloured.edgeColor), Self.components(teal.cgColor)))
        // Same geometry either way — colouring a group must not reflow the row.
        #expect(coloured.colourEdgeLayer.frame == plain.colourEdgeLayer.frame)

        // …and reuse clears it, so a recycled header cannot show the previous group's colour.
        coloured.prepareForReuse()
        #expect(Self.components(coloured.edgeColor).last == 0)
    }

    @Test("The group name is uppercased and the chevron follows isCollapsed")
    func groupNameAndChevron() {
        let expanded = Self.groupRow(SidebarGroupRowModel(name: "tkzmux", isCollapsed: false, sessionCount: 3))
        #expect(expanded.nameTextLayer.string as? String == "TKZMUX")
        #expect(expanded.chevronTextLayer.string as? String == "▾")

        let collapsed = Self.groupRow(SidebarGroupRowModel(name: "tkzmux", isCollapsed: true, sessionCount: 3))
        #expect(collapsed.chevronTextLayer.string as? String == "▸")

        // A long group name truncates rather than running under the ＋ button.
        let long = Self.groupRow(
            SidebarGroupRowModel(name: String(repeating: "long-group-name ", count: 6), sessionCount: 12),
            width: SidebarMetrics.sidebarMinWidth)
        #expect(long.nameTextLayer.truncationMode == .end)
        #expect(long.nameTextLayer.frame.maxX <= long.addButton.frame.minX)
    }

    @Test("The ＋ button invokes the injected closure and reuse detaches it")
    func addButtonCallsItsClosure() {
        let row = Self.groupRow(SidebarGroupRowModel(name: "tkzmux"))
        var calls = 0
        row.onAdd = { calls += 1 }
        row.addButton.performClick(nil)
        #expect(calls == 1)
        row.prepareForReuse()
        row.addButton.performClick(nil)
        #expect(calls == 1, "a recycled header must not still call the previous group's action")
        #expect(row.addButton.frame.maxX <= row.bounds.width)
    }

    // MARK: Summary strip

    @Test("The summary strip reads 'N working · N need you' at 11 pt")
    func summaryStripText() throws {
        let strip = SummaryStripView(frame: NSRect(
            x: 0, y: 0, width: SidebarMetrics.sidebarWidth, height: SummaryStripView.height))
        strip.configure(SidebarSummaryModel(working: 5, needAttention: 2), theme: .default)
        #expect(strip.summaryText == "5 working · 2 need you")
        #expect(strip.accessibilityLabel() == "5 working · 2 need you")
        #expect(Theme.Fonts.ui.body == 11)

        strip.configure(SidebarSummaryModel(working: 0, needAttention: 0), theme: .default)
        #expect(strip.summaryText == "0 working · 0 need you")
        #expect(try Self.isNonBlank(Self.render(strip, scale: 2)))
    }

    // MARK: Visual sanity artefact

    /// Renders a representative sidebar column to a PNG so a human (or the agent that wrote this)
    /// can look at it. This is a *sanity* artefact, not a comparison against the artboard: there is
    /// no reference image in the repo, so the test only asserts that a plausible bitmap came out.
    /// It writes a file only when `TKZMUX_TEST_ARTIFACTS` names a directory to write it to.
    @Test("Renders a representative row set to a PNG for eyeballing")
    func rendersSampleSheet() throws {
        let theme = Theme.default
        let width = SidebarMetrics.sidebarWidth

        struct Entry { let view: NSView; let height: Double }
        var entries: [Entry] = []

        func group(_ model: SidebarGroupRowModel) {
            entries.append(Entry(view: Self.groupRow(model, theme: theme), height: GroupRowView.rowHeight))
        }
        func session(_ model: SidebarSessionRowModel) {
            entries.append(Entry(view: Self.sessionRow(model, theme: theme), height: SessionRowView.rowHeight))
        }

        group(SidebarGroupRowModel(name: "tkzmux", color: theme.groupEdgeDefault, sessionCount: 3))
        session(SidebarSessionRowModel(
            title: "sidebar outline view", branch: "tkz-19-sidebar", isWorktree: true, status: .working,
            accountLabel: "PR", accountColor: SidebarSessionRowModel.accountChipColor(forKey: "private"),
            isSelected: true))
        session(SidebarSessionRowModel(
            title: "app store & change sets", branch: "main", status: .waiting,
            accountLabel: "AL", accountColor: SidebarSessionRowModel.accountChipColor(forKey: "work"),
            needsAttention: true))
        session(SidebarSessionRowModel(
            title: "a session whose title is far too long to fit in the sidebar",
            branch: "feature/really-long-branch-name", isWorktree: true, status: .idle))
        group(SidebarGroupRowModel(name: "acme-ledger", color: nil, isCollapsed: true, sessionCount: 2))
        session(SidebarSessionRowModel(title: "restored session", branch: "develop", status: .idle))

        let summary = SummaryStripView(frame: NSRect(
            x: 0, y: 0, width: width, height: SummaryStripView.height))
        summary.configure(SidebarSummaryModel(working: 1, needAttention: 1), theme: theme)
        entries.append(Entry(view: summary, height: SummaryStripView.height))

        let total = entries.reduce(0) { $0 + $1.height }
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale), pixelsHigh: Int(total * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let ctx = graphics.cgContext
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(theme.sidebarBackground.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: total))

        // Bottom-up: the views are not flipped, so the first entry goes at the top.
        var y = total
        for entry in entries {
            y -= entry.height
            entry.view.layoutSubtreeIfNeeded()
            ctx.saveGState()
            ctx.translateBy(x: 0, y: y)
            try #require(entry.view.layer).render(in: ctx)
            ctx.restoreGState()
        }

        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        #expect(try Self.isNonBlank(rep))

        // The bitmap is always asserted in memory; it is only *written out* when a human asked for
        // it by setting `TKZMUX_TEST_ARTIFACTS` (shared agent brief, rule 8: no stray files).
        if let dir = ProcessInfo.processInfo.environment["TKZMUX_TEST_ARTIFACTS"] {
            let url = URL(fileURLWithPath: dir)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent("sidebar-rows.png"))
        }
    }
}


// MARK: - Hover and the close button (2026-09-08)

@MainActor
@Suite(.serialized)
struct SessionRowHoverTests {
    @Test("Hovering a row shows a × on the right and a faint highlight; leaving hides both")
    func hoverShowsTheCloseButton() {
        let row = SessionRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        row.configure(SidebarSessionRowModel(title: "s", status: .idle, needsAttention: true), theme: .default)
        row.layoutSubtreeIfNeeded()
        #expect(row.closeButtonFrame == nil)
        #expect(row.selectionBackgroundLayer.backgroundColor?.alpha == 0)
        let badgeBefore = row.needsYouBadgeLayer.frame

        row.setHovered(true)
        row.layoutSubtreeIfNeeded()
        let close = try! #require(row.closeButtonFrame)
        #expect(close.maxX <= 300 && close.maxX > 270, "the × sits at the right edge")
        #expect(abs(close.midY - 22) < 2, "vertically centred")
        #expect((row.selectionBackgroundLayer.backgroundColor?.alpha ?? 0) > 0, "hover highlight")
        #expect(row.needsYouBadgeLayer.frame.maxX < badgeBefore.maxX, "badges shift left, out from under the ×")

        row.setHovered(false)
        row.layoutSubtreeIfNeeded()
        #expect(row.closeButtonFrame == nil)
        #expect(row.needsYouBadgeLayer.frame == badgeBefore)
    }

    @Test("A selected row keeps its selection tint while hovered")
    func hoveredSelectedRowStaysSelected() {
        let row = SessionRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        row.configure(SidebarSessionRowModel(title: "s", status: .idle, isSelected: true), theme: .default)
        let selected = row.selectionBackgroundLayer.backgroundColor
        row.setHovered(true)
        #expect(row.selectionBackgroundLayer.backgroundColor == selected)
    }

    @Test("prepareForReuse clears the hover state and the close handler")
    func reuseClearsHover() {
        let row = SessionRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        row.configure(SidebarSessionRowModel(title: "s", status: .idle), theme: .default)
        row.onClose = {}
        row.setHovered(true)
        row.prepareForReuse()
        #expect(row.isHovered == false)
        #expect(row.onClose == nil)
        #expect(row.closeButtonFrame == nil)
    }
}
