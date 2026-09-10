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

    /// The RGBA bytes at one pixel. Used by the group-edge tests, which have to compare what two
    /// *different* row views actually painted rather than what their layers were told to paint.
    static func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> [UInt8] {
        let data = try #require(rep.bitmapData)
        let offset = y * rep.bytesPerRow + x * (rep.bitsPerPixel / 8)
        return (0..<4).map { data[offset + $0] }
    }

    static func sessionRow(
        _ model: SidebarSessionRowModel,
        theme: Theme = .default,
        width: Double = SidebarMetrics.sidebarWidth
    ) -> SessionRowView {
        // Sized the way the outline view would size it: 44, or 59 when the detail line wraps.
        let height = SessionRowView.height(for: model, width: width)
        let row = SessionRowView(frame: NSRect(x: 0, y: 0, width: width, height: height))
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

    @Test("Row heights are exactly the design's 28 pt / 44 pt, and 59 pt for a wrapped detail line")
    func rowHeights() {
        #expect(GroupRowView.rowHeight == 28)
        #expect(SessionRowView.rowHeight == 44)
        #expect(SidebarMetrics.groupRowHeight == 28)
        #expect(SidebarMetrics.sessionRowHeight == 44)
        #expect(SidebarMetrics.sessionRowWrappedHeight == 59)
        // The outline view returns these; a row view must also actually be that tall.
        let session = Self.sessionRow(Self.sample)
        #expect(session.bounds.height == 44)
        #expect(SessionRowView.height(for: Self.sample, width: SidebarMetrics.sidebarWidth) == 44)
        let group = Self.groupRow(SidebarGroupRowModel(name: "tkzmux"))
        #expect(group.bounds.height == 28)
        // A row whose `…/folder · ⎇ branch` does not fit is exactly one detail line taller.
        let wrapped = Self.sessionRow(Self.wrappingSample, width: SidebarMetrics.sidebarMinWidth)
        #expect(wrapped.bounds.height == 59)
        #expect(SessionRowView.height(for: Self.wrappingSample, width: SidebarMetrics.sidebarMinWidth) == 59)
    }

    /// A Claude-named row with a long branch: `…/reporting · ⎇ feature/reporting-scheduler-rewrite WT`
    /// cannot fit 240 pt on one line.
    static let wrappingSample = SidebarSessionRowModel(
        title: "Move reporting onto the new scheduler",
        branch: "feature/reporting-scheduler-rewrite",
        directory: "reporting",
        isWorktree: true,
        status: .working
    )

    // MARK: The `…/folder` subtitle (design 2c.1)

    @Test("The folder subtitle exists only when the model carries a directory")
    func directoryIsConditional() {
        let without = Self.sessionRow(SidebarSessionRowModel(title: "reporting", branch: "main"))
        #expect(without.directoryTextLayer.isHidden)
        #expect(without.separatorTextLayer.isHidden)
        #expect(without.bounds.height == 44)

        let with = Self.sessionRow(SidebarSessionRowModel(
            title: "Fix the rounding bug", branch: "main", directory: "reporting"))
        #expect(with.directoryTextLayer.isHidden == false)
        #expect(with.directoryTextLayer.string as? String == "\u{2026}/reporting")
        #expect(with.separatorTextLayer.isHidden == false)
        #expect(with.separatorTextLayer.string as? String == "\u{00B7}")
        #expect(with.separatorTextLayer.opacity == 0.5)
        // Same line, in design order: folder, separator, branch — all on the detail line.
        let folder = with.directoryTextLayer.frame
        let separator = with.separatorTextLayer.frame
        let branch = with.branchTextLayer.frame
        #expect(folder.minY == branch.minY)
        #expect(separator.minY == branch.minY)
        #expect(folder.maxX <= separator.minX)
        #expect(separator.maxX <= branch.minX)
        #expect(with.bounds.height == 44)
        // The subtitle is drawn in the detail font, in the muted colour, like the branch.
        #expect(with.directoryTextLayer.fontSize == with.detailFontForMeasurement.pointSize)
        #expect(Self.approxEqual(
            Self.components(with.directoryTextLayer.foregroundColor),
            Self.components(with.branchTextLayer.foregroundColor)))

        // No branch: the folder stands alone, no separator, nothing to wrap.
        let alone = Self.sessionRow(SidebarSessionRowModel(
            title: "Fix the rounding bug", directory: "reporting"), width: SidebarMetrics.sidebarMinWidth)
        #expect(alone.directoryTextLayer.isHidden == false)
        #expect(alone.separatorTextLayer.isHidden)
        #expect(alone.bounds.height == 44)
    }

    @Test("When `…/folder · ⎇ branch WT` does not fit, the branch moves to a second line")
    func detailLineWrapsBySegment() {
        let model = Self.wrappingSample
        let width = SidebarMetrics.sidebarMinWidth
        #expect(SessionRowView.detailWraps(for: model, width: width))
        let row = Self.sessionRow(model, width: width)
        #expect(row.bounds.height == 59)

        let title = row.titleTextLayer.frame
        let folder = row.directoryTextLayer.frame
        let branch = row.branchTextLayer.frame
        let badge = row.worktreeBadgeLayer.frame
        // Title where it always is (22 pt down from the top), folder under it, branch under that.
        #expect(title.minY == row.bounds.height - 22)
        #expect(folder.minY == row.bounds.height - 38)
        #expect(branch.minY == folder.minY - 15)
        #expect(branch.minY == 6)
        #expect(badge.minY == branch.minY)
        #expect(folder.minX == branch.minX)
        // The separator has no place on the wrapped form.
        #expect(row.separatorTextLayer.isHidden)
        // The folder is whole — it is never the part that truncates.
        let natural = SidebarLayers.width(of: "\u{2026}/reporting", font: row.detailFontForMeasurement)
        #expect(folder.width >= natural)
        // Everything stays inside the row.
        #expect(folder.maxX <= row.bounds.width)
        #expect(branch.maxX <= row.bounds.width)
        #expect(badge.maxX <= row.bounds.width)
        #expect(badge.minX >= branch.maxX)

        // The same model in a much wider row fits on one line again.
        #expect(SessionRowView.detailWraps(for: model, width: 600) == false)
        let wide = Self.sessionRow(model, width: 600)
        #expect(wide.bounds.height == 44)
        #expect(wide.separatorTextLayer.isHidden == false)
        #expect(wide.branchTextLayer.frame.minY == wide.directoryTextLayer.frame.minY)
    }

    @Test("Hovering never changes a row's height or its wrap decision")
    func hoverDoesNotChangeTheHeight() {
        // A model that *just* fits: the `×` reserve would tip it over if it counted.
        let width = SidebarMetrics.sidebarWidth
        var model = SidebarSessionRowModel(title: "Named by Claude", branch: "b", directory: "d", isWorktree: true)
        var branch = "feature/x"
        while !SessionRowView.detailWraps(for: model, width: width) {
            branch += "x"
            model.branch = branch
        }
        // One character back: fits unhovered, and would not once 24 pt are taken by the `×`.
        model.branch = String(branch.dropLast())
        #expect(SessionRowView.detailWraps(for: model, width: width) == false)
        let row = Self.sessionRow(model, width: width)
        #expect(row.bounds.height == 44)
        let before = row.branchTextLayer.frame.minY
        row.setHovered(true)
        row.layoutSubtreeIfNeeded()
        #expect(SessionRowView.height(for: model, width: width) == 44)
        #expect(row.branchTextLayer.frame.minY == before)
        #expect(row.separatorTextLayer.isHidden == false)
        // Hovered, the line only truncates harder; the badge still stays inside the `×` reserve.
        let close = row.closeButtonFrame
        #expect(close != nil)
        if let close {
            #expect(row.worktreeBadgeLayer.frame.maxX <= close.minX)
        }
    }

    @Test("A wrapped row keeps its chip and memory badge on the branch line, inside the row")
    func wrappedRowKeepsTheBadgesOnTheBranchLine() {
        var model = Self.wrappingSample
        model.accountLabel = "WORK"
        model.memoryBadge = "6.2 GB"
        let width = SidebarMetrics.sidebarMinWidth
        let row = Self.sessionRow(model, width: width)
        #expect(row.bounds.height == 59)
        let branchY = row.branchTextLayer.frame.minY
        #expect(row.accountChipLayer.frame.minY == branchY)
        #expect(row.memoryBadgeLayer.frame.minY == branchY)
        #expect(row.accountChipLayer.frame.maxX <= row.bounds.width)
        #expect(row.memoryBadgeLayer.frame.maxX <= row.accountChipLayer.frame.minX)
        #expect(row.worktreeBadgeLayer.frame.maxX <= row.memoryBadgeLayer.frame.minX)
        #expect(row.branchTextLayer.frame.maxX <= row.worktreeBadgeLayer.frame.minX)
        // The folder line above them has the whole width to itself.
        #expect(row.directoryTextLayer.frame.minY > branchY)
    }

    @Test("A wrapped row rasterises headlessly at both scales, and identically twice")
    func wrappedRowRendersHeadlessly() throws {
        let row = Self.sessionRow(Self.wrappingSample, width: SidebarMetrics.sidebarMinWidth)
        for scale in [CGFloat(1), CGFloat(2)] {
            let rep = try Self.render(row, scale: scale)
            #expect(rep.pixelsHigh == Int(59 * scale))
            #expect(try Self.isNonBlank(rep))
        }
        let first = try Self.pixels(Self.render(row, scale: 2))
        row.configure(Self.wrappingSample, theme: .default)
        let second = try Self.pixels(Self.render(row, scale: 2))
        #expect(first == second)
    }

    // MARK: Headless rendering

    @Test("Every row view rasterises without a window, at 1x and 2x")
    func rendersHeadlesslyAtBothScales() throws {
        let views: [NSView] = [
            Self.sessionRow(Self.sample),
            Self.groupRow(SidebarGroupRowModel(name: "tkzmux", color: RGB(hex: 0x41c6a8))),
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

    /// The memory badge exists so a runaway process subtree is visible without opening Activity
    /// Monitor — which, for the incident that prompted it, would have blamed the app anyway
    /// (docs/perf.md → *Session process memory*). It must be absent on a normal row.
    @Test("The memory badge shows only when a size is given, and stays inside the row")
    func memoryBadgeIsConditional() throws {
        let quiet = Self.sessionRow(SidebarSessionRowModel(title: "s", branch: "main"))
        #expect(quiet.memoryBadgeLayer.isHidden)

        let loud = Self.sessionRow(SidebarSessionRowModel(
            title: "s", branch: "main", memoryBadge: "6.1 GB"))
        #expect(!loud.memoryBadgeLayer.isHidden)
        #expect(loud.memoryBadgeLayer.frame.width > 0)
        // Amber, like NEEDS YOU: both are warnings.
        #expect(Self.approxEqual(
            Self.components(loud.memoryBadgeLayer.backgroundColor),
            Self.components(Theme.default.needsYouBackground.cgColor)))
        #expect(loud.memoryBadgeLayer.frame.minX >= 0)
        #expect(loud.memoryBadgeLayer.frame.maxX <= loud.bounds.width)
        #expect(loud.memoryBadgeLayer.frame.maxY <= loud.bounds.height)
    }

    /// The badge shares the detail line with the branch and the account chip, so the crowded case
    /// is the one that can overflow.
    @Test("The memory badge does not collide with the account chip or escape a crowded row")
    func memoryBadgeSurvivesACrowdedRow() throws {
        let row = Self.sessionRow(SidebarSessionRowModel(
            title: "a session with a fairly long title",
            branch: "feature/some-quite-long-branch-name",
            isWorktree: true,
            accountLabel: "ALT",
            accountColor: RGB(hex: 0x8b93f8),
            memoryBadge: "12.4 GB"))
        let badge = row.memoryBadgeLayer
        let chip = row.accountChipLayer
        #expect(!badge.isHidden)
        #expect(badge.frame.minX >= 0)
        #expect(badge.frame.maxX <= row.bounds.width)
        if !chip.isHidden {
            // The badge sits to the left of the chip, not on top of it.
            #expect(badge.frame.maxX <= chip.frame.minX + 0.5)
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

    /// The chip is a `CALayer` in a row with no subviews, so its tooltip is a registered rect the
    /// row answers for itself. What matters is that it answers *only over the chip*: one rect covers
    /// the whole row, so a naive owner would put an account tooltip on the title too.
    @Test("The account chip's tooltip answers over the chip and nowhere else")
    func accountChipCarriesItsTooltip() {
        let row = Self.sessionRow(
            SidebarSessionRowModel(
                title: "session", accountLabel: "ALT",
                accountTooltip: "claude-alt \u{2014} ~/.claude-alt"))
        #expect(!row.accountChipLayer.isHidden)

        let chip = row.accountChipLayer.frame
        let inside = NSPoint(x: chip.midX, y: chip.midY)
        #expect(row.view(row, stringForToolTip: 0, point: inside, userData: nil)
            == "claude-alt \u{2014} ~/.claude-alt")

        // The title line, and the empty left half of the detail line, say nothing.
        for outside in [NSPoint(x: chip.midX, y: row.bounds.height - 4), NSPoint(x: 20, y: chip.midY)] {
            #expect(row.view(row, stringForToolTip: 0, point: outside, userData: nil) == "")
        }

        // No chip, no tooltip — and a chip with no tooltip text answers empty rather than crashing.
        let bare = Self.sessionRow(SidebarSessionRowModel(title: "session"))
        #expect(bare.view(bare, stringForToolTip: 0, point: inside, userData: nil) == "")
        let unexplained = Self.sessionRow(SidebarSessionRowModel(title: "session", accountLabel: "ALT"))
        #expect(unexplained.view(unexplained, stringForToolTip: 0, point: inside, userData: nil) == "")

        // Re-laying the row out — which happens on every scroll tick and on every hover — must not
        // disturb a tooltip that has not changed, and must follow one that has.
        row.setHovered(true)
        row.layoutSubtreeIfNeeded()
        // Hovering slides the chip left to make room for the `×`, so ask where it actually is.
        let hovered = row.accountChipLayer.frame
        #expect(hovered.minX < chip.minX, "the chip moved, and the tooltip followed it")
        #expect(row.view(row, stringForToolTip: 0, point: NSPoint(x: hovered.midX, y: hovered.midY),
                         userData: nil) == "claude-alt \u{2014} ~/.claude-alt")
        row.configure(
            SidebarSessionRowModel(title: "session", accountLabel: "WORK", accountTooltip: "day job"),
            theme: .default)
        let moved = row.accountChipLayer.frame
        #expect(row.view(row, stringForToolTip: 0, point: NSPoint(x: moved.midX, y: moved.midY),
                         userData: nil) == "day job")

        // A recycled row keeps nothing: the next session in this view is a different account.
        row.prepareForReuse()
        #expect(row.view(row, stringForToolTip: 0, point: inside, userData: nil) == "")
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
                                             isCollapsed: false),
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

    @Test("The dot colour is the theme token for every status that draws one, in every preset")
    func dotColoursComeFromTheTheme() {
        for theme in Theme.allPresets {
            for status in SidebarStatus.allCases {
                let row = Self.sessionRow(SidebarSessionRowModel(title: "s", status: status), theme: theme)
                let dot = row.statusDot
                switch status {
                case .working:
                    #expect(!dot.isHidden, "\(theme.preset) working")
                    #expect(Self.approxEqual(Self.components(dot.fillColor),
                                             Self.components(theme.working.cgColor)),
                            "\(theme.preset) working")
                case .waiting:
                    #expect(!dot.isHidden, "\(theme.preset) waiting")
                    #expect(Self.approxEqual(Self.components(dot.fillColor),
                                             Self.components(theme.waiting.cgColor)),
                            "\(theme.preset) waiting")
                case .idle:
                    // 2026-09-09: idle draws nothing at all — and clears its colour, so no stale
                    // token is left behind on the layer.
                    #expect(dot.isHidden, "\(theme.preset) idle")
                    #expect(dot.fillColor == nil, "\(theme.preset) idle")
                case .done:
                    #expect(!dot.isHidden, "\(theme.preset) done")
                    #expect(Self.approxEqual(Self.components(dot.fillColor),
                                             Self.components(theme.accent.cgColor)),
                            "\(theme.preset) done")
                }
            }
        }
    }

    @Test("A row recycled from working to idle loses its dot, not just its pulse")
    func recycledRowHidesTheDot() {
        let row = Self.sessionRow(SidebarSessionRowModel(title: "s", status: .working))
        #expect(!row.statusDot.isHidden)
        row.prepareForReuse()
        #expect(row.statusDot.isHidden)
        #expect(row.statusDot.fillColor == nil)

        // The same through `configure`, which is the path the outline view actually takes.
        let reconfigured = Self.sessionRow(SidebarSessionRowModel(title: "s", status: .waiting))
        #expect(!reconfigured.statusDot.isHidden)
        reconfigured.configure(SidebarSessionRowModel(title: "t", status: .idle), theme: .default)
        #expect(reconfigured.statusDot.isHidden)
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

        // The group name reads its own token, so it inverts for the light preset too.
        let darkGroup = Self.groupRow(SidebarGroupRowModel(name: "tkzmux"), theme: .midnightIndigo)
        let lightGroup = Self.groupRow(SidebarGroupRowModel(name: "tkzmux"), theme: .light)
        #expect(Self.approxEqual(Self.components(darkGroup.nameTextLayer.foregroundColor),
                                 Self.components(Theme.midnightIndigo.groupHeaderText.cgColor)))
        #expect(Self.approxEqual(Self.components(lightGroup.nameTextLayer.foregroundColor),
                                 Self.components(Theme.light.groupHeaderText.cgColor)))
        #expect(!Self.approxEqual(Self.components(darkGroup.nameTextLayer.foregroundColor),
                                  Self.components(lightGroup.nameTextLayer.foregroundColor)))
    }

    @Test("The summary strip draws neutral words with a status-coloured dot before each count")
    func summaryStripUsesTheDotsForColour() throws {
        for theme in Theme.allPresets {
            let strip = SummaryStripView(frame: NSRect(
                x: 0, y: 0, width: SidebarMetrics.sidebarWidth, height: SummaryStripView.height))
            strip.configure(SidebarSummaryModel(working: 5, needAttention: 2), theme: theme)
            strip.layoutSubtreeIfNeeded()

            #expect(Self.approxEqual(Self.components(strip.workingDotLayer.backgroundColor),
                                     Self.components(theme.working.cgColor)), "\(theme.preset)")
            #expect(Self.approxEqual(Self.components(strip.waitingDotLayer.backgroundColor),
                                     Self.components(theme.waiting.cgColor)), "\(theme.preset)")
            for label in [strip.workingTextLayer, strip.waitingTextLayer] {
                let attributed = try #require(label.string as? NSAttributedString)
                let color = try #require(
                    attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                #expect(Self.approxEqual(Self.components(color.cgColor),
                                         Self.components(theme.summaryText.cgColor)), "\(theme.preset)")
            }
            #expect(strip.workingTextLayer.string as? NSAttributedString != nil)
            #expect((strip.workingTextLayer.string as? NSAttributedString)?.string == "5 WORKING")
            #expect((strip.waitingTextLayer.string as? NSAttributedString)?.string == "2 NEED YOU")

            // 7 pt dots, each immediately before its words, both inside the strip.
            let d = StatusDotLayer.diameter
            #expect(strip.workingDotLayer.frame.size == CGSize(width: d, height: d))
            #expect(strip.waitingDotLayer.frame.size == CGSize(width: d, height: d))
            #expect(strip.workingDotLayer.frame.maxX < strip.workingTextLayer.frame.minX)
            #expect(strip.workingTextLayer.frame.maxX < strip.waitingDotLayer.frame.minX)
            #expect(strip.waitingDotLayer.frame.maxX < strip.waitingTextLayer.frame.minX)
            #expect(strip.waitingTextLayer.frame.maxX <= strip.bounds.width)
            #expect(strip.workingDotLayer.frame.minX >= 0)
            // The spoken form is unchanged.
            #expect(strip.summaryText == "5 working · 2 need you")
        }
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

    @Test("A session row carries its group's colour edge, with the header's geometry (TKZ-48)")
    func sessionEdgeReflectsTheGroupColour() {
        let plain = Self.sessionRow(SidebarSessionRowModel(title: "aira", groupColor: nil))
        #expect(Self.components(plain.edgeColor).last == 0, "an uncoloured group must not borrow groupEdgeDefault")
        #expect(plain.colourEdgeLayer.frame.width == CGFloat(SidebarMetrics.groupEdgeWidth))
        #expect(plain.colourEdgeLayer.frame.height == plain.bounds.height)
        #expect(plain.colourEdgeLayer.frame.minX == 0)

        let teal = GroupPalette.swatches[0].rgb
        let coloured = Self.sessionRow(SidebarSessionRowModel(title: "aira", groupColor: teal))
        #expect(Self.approxEqual(Self.components(coloured.edgeColor), Self.components(teal.cgColor)))
        #expect(coloured.colourEdgeLayer.frame == plain.colourEdgeLayer.frame)

        // The selection rect is inset by 5 pt, so a selected row cannot paint over the edge.
        let selected = Self.sessionRow(
            SidebarSessionRowModel(title: "aira", isSelected: true, groupColor: teal))
        #expect(selected.selectionBackgroundLayer.frame.minX > CGFloat(SidebarMetrics.groupEdgeWidth))

        coloured.prepareForReuse()
        #expect(Self.components(coloured.edgeColor).last == 0)
    }

    @Test("The edge is one stripe: a header and its session rows paint the same leftmost pixels")
    func groupEdgeIsContinuousAcrossTheGroup() throws {
        let amber = try #require(GroupPalette.swatches.first { $0.slug == "amber" }).rgb
        let header = Self.groupRow(SidebarGroupRowModel(name: "aira", color: amber))
        let row = Self.sessionRow(SidebarSessionRowModel(title: "session summary", groupColor: amber))

        let headerPixels = try Self.render(header, scale: 2)
        let rowPixels = try Self.render(row, scale: 2)
        // x = 2 is inside the 2.5 pt edge at 2x (5 device pixels); mid-height avoids nothing in
        // particular, but keeps the sample away from any rounding at the extremes.
        let fromHeader = try Self.pixel(headerPixels, x: 2, y: headerPixels.pixelsHigh / 2)
        let fromRow = try Self.pixel(rowPixels, x: 2, y: rowPixels.pixelsHigh / 2)
        #expect(fromHeader == fromRow, "the stripe changes colour between the header and its rows")

        let (r, g, b) = amber.bytes
        #expect(fromHeader[0] == r)
        #expect(fromHeader[1] == g)
        #expect(fromHeader[2] == b)
        #expect(fromHeader[3] == 255)

        // Beyond the edge the two rows are of course different — this is not a blank-bitmap pass.
        let outsideHeader = try Self.pixel(headerPixels, x: 60, y: headerPixels.pixelsHigh / 2)
        #expect(outsideHeader[3] == 0 || outsideHeader != fromHeader)
    }

    @Test("The group name is uppercased and the chevron follows isCollapsed")
    func groupNameAndChevron() throws {
        let expanded = Self.groupRow(SidebarGroupRowModel(name: "tkzmux", isCollapsed: false))
        #expect(expanded.nameTextLayer.string as? String == "TKZMUX")
        #expect(expanded.chevronPointsRight == false)

        let collapsed = Self.groupRow(SidebarGroupRowModel(name: "tkzmux", isCollapsed: true))
        #expect(collapsed.chevronPointsRight)

        // The reason it is a stroked path and not a `▾` glyph: it has to be *visible*. The old
        // 9 pt U+25BE drew about 5 pt of ink; anything much under this reads as a dot again.
        let path = try #require(expanded.chevronShapeLayer.path).boundingBox
        #expect(path.width >= 6)
        #expect(expanded.chevronShapeLayer.lineWidth >= 1.5)
        #expect(expanded.chevronShapeLayer.fillColor == nil, "a stroked chevron, not a filled wedge")

        // A long group name truncates rather than running under the ＋ button.
        let long = Self.groupRow(
            SidebarGroupRowModel(name: String(repeating: "long-group-name ", count: 6)),
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
            entries.append(Entry(
                view: Self.sessionRow(model, theme: theme),
                height: SessionRowView.height(for: model, width: width)))
        }

        group(SidebarGroupRowModel(name: "tkzmux", color: theme.groupEdgeDefault))
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
        session(SidebarSessionRowModel(
            title: "Track updated fields", branch: "develop", directory: "CoreInvest", isWorktree: true,
            status: .working))
        session(Self.wrappingSample)
        group(SidebarGroupRowModel(name: "acme-ledger", color: nil, isCollapsed: true))
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
    // MARK: - No counters on rows (2026-09-10)

    /// The group header's session count and the row's pane count both went as noise. What is left
    /// on the title line is NEEDS YOU, and the title runs up to it — or to the `＋` on a header.
    @Test func rowsCarryNoCounters() {
        let row = Self.sessionRow(
            SidebarSessionRowModel(title: "a very long session title indeed", needsAttention: true))
        row.layout()
        let needsYou = row.needsYouBadgeLayer.frame
        #expect(!needsYou.isEmpty)
        #expect(row.titleTextLayer.frame.maxX <= needsYou.minX)

        let header = Self.groupRow(SidebarGroupRowModel(name: "tkzmux"))
        header.layout()
        #expect(header.nameTextLayer.frame.maxX <= header.addButton.frame.minX)
        #expect(header.layer?.sublayers?.count == 4, "edge, chevron, name, ＋ — nothing else")
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
