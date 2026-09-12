// SessionRowView — the 44 pt sidebar session row (M2.3 / TKZ-19).
//
// Layout is manual (`layout()` computing frames from `bounds.width`), not Auto Layout: the outline
// view recycles these and re-lays them on every scroll tick, and a 44 pt row with eight sublayers
// does not need a constraint solver. `bounds.width` is never assumed — the sidebar is resizable
// between 240 and 300 pt, and the title truncates rather than overflowing at either end.
//
// Everything visible is a `CALayer`, for the reason spelled out in `StatusDotView.swift`: a layer
// tree renders headlessly via `CALayer.render(in:)`, so every one of these rows is testable with no
// window. There are **no subviews at all** — a subview's backing layer is not grafted into its
// superview's tree until the hierarchy reaches a window, so anything drawn by a subview would be
// missing from a headless bitmap.
//
// Geometry (row height 44, origin bottom-left — the view is not flipped; every y below is
// measured **down from the top**, so a taller row keeps its title where it was):
//
//     ┌────────────────────────────────────────────────────────────┐
//     │  ●   Session title…                          NEEDS YOU     │  title line,  top 22…6
//     │      …/folder · ⎇ branch   WT                     [ALT]    │  detail line, top 38…25
//     └────────────────────────────────────────────────────────────┘
//        ↑14                                                    12↑
//
// `…/folder` is there only when the title is not the folder (design 2c.1, see
// `SidebarSessionRowModel.directory`). When `…/folder · ⎇ branch WT` does not fit, the detail line
// wraps — by *segment*, never mid-word — and the row is 59 pt:
//
//     ┌────────────────────────────────────────────────────────────┐
//     │  ●   Claude's summary title                  NEEDS YOU     │  title line,  top 22…6
//     │      …/folder                                              │  detail 1,    top 38…25
//     │      ⎇ feature/a-long-branch-name   WT            [ALT]    │  detail 2,    top 53…40
//     └────────────────────────────────────────────────────────────┘
//
// The wrap decision (`detailWraps(for:width:)`) is a pure function of the model and the row width,
// so the outline view can ask `height(for:width:)` without a row view, and it ignores the hover
// `×` reserve on purpose: a row must not change height because the pointer passed over it.
//
// The account chip is the one element with a tooltip; since there are no subviews to hang one on,
// the row registers a tooltip rect and owns it — see `refreshAccountTooltip()`.

import AppKit
import TkzCore

public final class SessionRowView: NSTableCellView {
    // MARK: Metrics (all from the design; see docs/design.md → App architecture → Sidebar)

    /// The single-line row height. The outline view returns `height(for:width:)` from
    /// `heightOfRowByItem`, which is this unless the detail line wraps.
    public static let rowHeight: Double = SidebarMetrics.sessionRowHeight

    /// Both are measured from the group header's own leading edge and then indented, so the
    /// hierarchy is one constant (`SidebarMetrics.sessionIndent`) rather than two magic numbers
    /// that have to be kept in step with `GroupRowView`.
    private static let dotCenterX: CGFloat = 17.5 + CGFloat(SidebarMetrics.sessionIndent)
    private static let textLeft: CGFloat = 30 + CGFloat(SidebarMetrics.sessionIndent)
    private static let rightInset: CGFloat = 12
    private static let selectionInset: CGFloat = 5
    private static let titleLineHeight: CGFloat = 16
    /// Top of the row → bottom of the title line (`y = h - titleTop`).
    private static let titleTop: CGFloat = 22
    /// Top of the row → bottom of the first detail line (`y = h - detailTop`).
    private static let detailTop: CGFloat = 38
    /// One more detail line, when the `…/folder · ⎇ branch` line wraps. Equals
    /// `sessionRowWrappedHeight - sessionRowHeight`, so the second line lands at y 6 of a 59 pt row.
    private static let detailLinePitch: CGFloat = CGFloat(SidebarMetrics.sessionRowWrappedHeight - SidebarMetrics.sessionRowHeight)
    private static let badgeGap: CGFloat = 6
    /// Smallest sensible title width; below this we still clip rather than let text escape the row.
    private static let minTitleWidth: CGFloat = 24

    // MARK: Fonts
    //
    // Static, because `detailWraps(for:width:)` measures with them before any row view exists.

    private static let titleFont = Theme.Fonts.ui(Theme.Fonts.ui.title, weight: .medium)
    private static let branchFont = Theme.Fonts.mono(Theme.Fonts.mono.detail)
    private static let badgeFont = Theme.Fonts.ui(9, weight: .semibold)
    private var titleFont: NSFont { Self.titleFont }
    private var branchFont: NSFont { Self.branchFont }
    private var badgeFont: NSFont { Self.badgeFont }

    // MARK: Detail-line strings
    //
    // Built in one place so what `apply()` draws is exactly what `detailWraps` measured.

    /// The design renders the branch as `⎇ <name>`; the glyph is part of the string rather than a
    /// separate layer so the two truncate together.
    private static func branchText(_ branch: String) -> String { "\u{2387} \(branch)" }
    /// `…/<folder>` — the leading ellipsis stands for the rest of the path (design 2c.1).
    private static func directoryText(_ directory: String) -> String { "\u{2026}/\(directory)" }
    /// The `·` between the folder and the branch, drawn at half opacity.
    private static let separatorText = "\u{00B7}"

    // MARK: Layers & subviews

    /// The group's 2.5 pt colour edge, continued down this row so the stripe spans the whole group
    /// rather than stopping at its header (TKZ-48). Always present so layout never shifts; fully
    /// transparent when the group has no colour. Bottom of the z-order, though nothing overlaps it:
    /// `selectionInset` keeps the selection/hover rect at x = 5.
    private let edgeLayer = SidebarLayers.fill(cornerRadius: 0)
    private let selectionLayer = SidebarLayers.fill(cornerRadius: 6)
    private lazy var titleLayer = SidebarLayers.text(titleFont, color: NSColor.clear.cgColor)
    /// `…/folder`, in front of the branch (or above it, wrapped). Hidden without a directory.
    private lazy var directoryLayer = SidebarLayers.text(branchFont, color: NSColor.clear.cgColor)
    /// The `·` between folder and branch; only on the single-line form.
    private lazy var separatorLayer: CATextLayer = {
        let layer = SidebarLayers.text(branchFont, color: NSColor.clear.cgColor)
        layer.opacity = 0.5
        return layer
    }()
    private lazy var branchLayer = SidebarLayers.text(branchFont, color: NSColor.clear.cgColor)
    private lazy var wtBadge = SidebarBadgeLayer(font: badgeFont)
    /// The "this session's processes are holding N GB" badge. Reuses the amber NEEDS YOU tokens
    /// rather than introducing its own: both are warnings, and the two never appear on the same
    /// line (NEEDS YOU sits on the title line, this on the detail line).
    private lazy var memoryBadge = SidebarBadgeLayer(font: badgeFont)
    private lazy var needsYouBadge = SidebarBadgeLayer(font: badgeFont)
    private lazy var accountChip = SidebarBadgeLayer(font: badgeFont)

    /// The status dot. Public so the controller can park its pulse; `setOccluded(_:)` below is the
    /// preferred entry point.
    public let statusDot = StatusDotLayer()

    /// Invoked by `mouseDown(with:)` when the click lands on the status dot. Returns `true` when the
    /// click was handled (eligible row: idle-done or waiting) — the row must **not** also select in
    /// that case. Returns `false` for an ineligible row, so the click falls through to the normal
    /// selection behaviour instead of silently swallowing it. `prepareForReuse()` clears it, like
    /// `GroupRowView.onAdd`, so the controller rewires it on every vend rather than a stale closure
    /// firing for whatever session got recycled into this row.
    public var onStatusDotClick: (() -> Bool)?
    /// Invoked by a click on the `×` that appears while the pointer is over the row (2026-09-08).
    /// Cleared by `prepareForReuse()` like `onStatusDotClick`.
    public var onClose: (() -> Void)?

    /// The pointer is over the row: a faint highlight and the `×` close button.
    public private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            apply()
            needsLayout = true
        }
    }
    /// The `×` glyph; a text layer, hit-tested in `mouseDown`.
    private lazy var closeLayer = SidebarLayers.text(closeFont, color: NSColor.clear.cgColor, alignment: .center)
    private let closeFont = Theme.Fonts.ui(13, weight: .medium)
    private static let closeSize: CGFloat = 18
    private var trackingArea: NSTrackingArea?
    /// Extra hit-test margin around the 7 pt dot — a 7 pt target is not reliably clickable on its
    /// own.
    private static let dotHitSlop: CGFloat = 5

    // MARK: Cached layout inputs

    private var model = SidebarSessionRowModel(title: "")
    private var theme: Theme = .default
    private var wtBadgeWidth: CGFloat = 0
    private var memoryBadgeWidth: CGFloat = 0
    private var needsYouBadgeWidth: CGFloat = 0
    private var accountChipWidth: CGFloat = 0
    /// What ``refreshAccountTooltip()`` last registered, so it can skip the churn.
    private var registeredTooltipRect: NSRect?
    private var registeredTooltipText: String?

    // MARK: Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        guard let root = layer else { return }
        root.addSublayer(edgeLayer)
        root.addSublayer(selectionLayer)
        root.addSublayer(titleLayer)
        root.addSublayer(directoryLayer)
        root.addSublayer(separatorLayer)
        root.addSublayer(branchLayer)
        root.addSublayer(wtBadge)
        root.addSublayer(memoryBadge)
        root.addSublayer(needsYouBadge)
        root.addSublayer(accountChip)
        root.addSublayer(statusDot)
        root.addSublayer(closeLayer)
        apply()
    }

    // MARK: Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Tests have no pointer; they set the hover state directly.
    public func setHovered(_ hovered: Bool) { isHovered = hovered }

    /// The `×` button's frame in the row's coordinates, or nil while it is not shown.
    public var closeButtonFrame: CGRect? { closeLayer.isHidden ? nil : closeLayer.frame }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    public override var isFlipped: Bool { false }

    // MARK: Configuration

    /// Binds a model. Idempotent and allocation-light: the layer tree is fixed, only its contents
    /// and frames change, so re-binding the same model twice renders identically (a test asserts
    /// this) and never stacks a second pulse.
    public func configure(_ model: SidebarSessionRowModel, theme: Theme) {
        self.model = model
        self.theme = theme
        apply()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// `NSOutlineView` recycling hook. Clears every piece of per-row state, most importantly the
    /// pulse: a recycled row that kept its animation would pulse under a title that is no longer
    /// `working`.
    public override func prepareForReuse() {
        super.prepareForReuse()
        statusDot.reset()
        model = SidebarSessionRowModel(title: "")
        titleLayer.string = nil
        directoryLayer.string = nil
        directoryLayer.isHidden = true
        separatorLayer.string = nil
        separatorLayer.isHidden = true
        branchLayer.string = nil
        wtBadge.isHidden = true
        memoryBadge.isHidden = true
        needsYouBadge.isHidden = true
        accountChip.isHidden = true
        removeAllToolTips()
        registeredTooltipRect = nil
        registeredTooltipText = nil
        selectionLayer.backgroundColor = NSColor.clear.cgColor
        edgeLayer.backgroundColor = NSColor.clear.cgColor
        onStatusDotClick = nil
        onClose = nil
        isHovered = false
    }

    /// A click on the status dot is handled here rather than falling through to selection — the
    /// controller decides (from the *store's* session, not this presentation-only model) whether
    /// the row is showing a last message worth popping over.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The `×` first: it is only there while hovered, and a click on it must not select the row.
        if !closeLayer.isHidden, closeLayer.frame.insetBy(dx: -4, dy: -6).contains(point), let onClose {
            onClose()
            return
        }
        guard let onStatusDotClick else {
            super.mouseDown(with: event)
            return
        }
        let hitArea = statusDot.frame.insetBy(dx: -Self.dotHitSlop, dy: -Self.dotHitSlop)
        guard hitArea.contains(point), onStatusDotClick() else {
            super.mouseDown(with: event)
            return
        }
    }

    /// Parks or resumes the pulse. The controller calls this from
    /// `NSWindow.didChangeOcclusionStateNotification`.
    public func setOccluded(_ occluded: Bool) { statusDot.setOccluded(occluded) }

    /// `true` when the row's dot is pulsing — structural, needs no window.
    public var isPulsing: Bool { statusDot.isPulsing }

    /// Propagates the backing scale to the whole layer tree (the tests render at 1x and 2x).
    /// Keeps the text layers crisp when the row moves between a retina and a 1x display. The view
    /// owns its layers, so the controller never has to think about backing scale.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setContentsScale(window?.backingScaleFactor ?? 2)
    }

    public func setContentsScale(_ scale: CGFloat) {
        if let layer { SidebarLayers.applyContentsScale(scale, to: layer) }
    }

    /// The group-edge layer's colour, mirroring `GroupRowView.edgeColor`. `nil`/zero alpha means
    /// "this row's group has no colour"; a test asserts it.
    public var edgeColor: CGColor? { edgeLayer.backgroundColor }

    /// Drops the pulse when the row leaves the window, and restores it when it comes back — the
    /// second half of the "zero CPU when nothing is on screen" claim.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { statusDot.suspend() } else { statusDot.resume() }
    }

    // MARK: Content

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // `nil` colour → transparent, never `theme.groupEdgeDefault`; same rule as the header.
        edgeLayer.backgroundColor = model.groupColor?.cgColor ?? NSColor.clear.cgColor

        // Hover is a fainter version of the selection tint, so a hovered selected row stays selected-looking.
        if model.isSelected {
            selectionLayer.backgroundColor = theme.selection.cgColor
        } else if isHovered {
            var hover = theme.selection
            hover.a *= 0.45
            selectionLayer.backgroundColor = hover.cgColor
        } else {
            selectionLayer.backgroundColor = NSColor.clear.cgColor
        }
        closeLayer.isHidden = !isHovered
        closeLayer.string = "\u{00D7}"
        closeLayer.foregroundColor = theme.foregroundMuted.cgColor

        titleLayer.string = model.title
        titleLayer.foregroundColor = theme.foreground.cgColor

        if let branch = model.branch, !branch.isEmpty {
            branchLayer.string = Self.branchText(branch)
            branchLayer.isHidden = false
        } else {
            branchLayer.string = nil
            branchLayer.isHidden = true
        }
        branchLayer.foregroundColor = theme.foregroundMuted.cgColor

        if let directory = model.directory, !directory.isEmpty {
            directoryLayer.string = Self.directoryText(directory)
            directoryLayer.isHidden = false
        } else {
            directoryLayer.string = nil
            directoryLayer.isHidden = true
        }
        directoryLayer.foregroundColor = theme.foregroundMuted.cgColor
        // Shown only between a folder and a branch on one line; `layout()` hides it when wrapped.
        separatorLayer.string = Self.separatorText
        separatorLayer.foregroundColor = theme.foregroundMuted.cgColor
        separatorLayer.isHidden = directoryLayer.isHidden || branchLayer.isHidden

        wtBadge.isHidden = !model.isWorktree
        if model.isWorktree {
            wtBadgeWidth = wtBadge.configure(text: "WT", foreground: theme.wtText, background: theme.wtBackground)
        } else {
            wtBadgeWidth = 0
        }

        if let size = model.memoryBadge, !size.isEmpty {
            memoryBadge.isHidden = false
            memoryBadgeWidth = memoryBadge.configure(
                text: size, foreground: theme.needsYouText, background: theme.needsYouBackground)
        } else {
            memoryBadge.isHidden = true
            memoryBadgeWidth = 0
        }

        needsYouBadge.isHidden = !model.needsAttention
        if model.needsAttention {
            needsYouBadgeWidth = needsYouBadge.configure(
                text: "NEEDS YOU",
                foreground: theme.needsYouText,
                background: theme.needsYouBackground
            )
        } else {
            needsYouBadgeWidth = 0
        }

        if let label = model.accountLabel, !label.isEmpty {
            let tint = model.accountColor ?? theme.foregroundMuted
            accountChip.isHidden = false
            accountChipWidth = accountChip.configure(
                text: label,
                foreground: tint,
                background: RGB(r: tint.r, g: tint.g, b: tint.b, a: 0.18)
            )
        } else {
            accountChip.isHidden = true
            accountChipWidth = 0
        }

        statusDot.configure(status: model.status, theme: theme)
    }

    // MARK: Test hooks
    //
    // Internal, not private: the sidebar tests assert *structure* (which layer exists, how wide it
    // is, what colour it carries) rather than pixels, and structure is what wave 2 depends on too.

    var titleTextLayer: CATextLayer { titleLayer }
    var directoryTextLayer: CATextLayer { directoryLayer }
    var separatorTextLayer: CATextLayer { separatorLayer }
    var branchTextLayer: CATextLayer { branchLayer }
    var worktreeBadgeLayer: CALayer { wtBadge }
    var memoryBadgeLayer: CALayer { memoryBadge }
    var needsYouBadgeLayer: CALayer { needsYouBadge }
    var accountChipLayer: CALayer { accountChip }
    var selectionBackgroundLayer: CALayer { selectionLayer }
    var colourEdgeLayer: CALayer { edgeLayer }
    var titleFontForMeasurement: NSFont { titleFont }
    var detailFontForMeasurement: NSFont { branchFont }

    // MARK: Row height

    /// `true` when `…/folder · ⎇ branch [WT] [size] [chip]` does not fit one detail line at
    /// `width`, so the branch (with its badges) moves to a second line.
    ///
    /// Pure: the same model at the same width always answers the same, which is what lets the
    /// outline view ask before a row view exists. Measured at the **unhovered** width — the `×`
    /// reserve only ever costs truncation, never a line, or a row would grow under the pointer.
    /// Without a directory, or without a branch, there is nothing to wrap.
    public static func detailWraps(for model: SidebarSessionRowModel, width: CGFloat) -> Bool {
        guard let needed = neededDetailWidth(for: model) else { return false }
        return needed > width
    }

    /// The width the detail line needs to stay on one line, or `nil` when it can never wrap.
    ///
    /// Split out of `detailWraps` because it depends only on the *model* — `width` entered that
    /// function in one comparison and nowhere else. The sidebar caches this per row, so changing
    /// the list's width (a divider drag, which re-asks for every row's height on every frame of the
    /// drag) costs one comparison per row instead of rebuilding each row's model and running up to
    /// six uncached Core Text measurements on it.
    public static func neededDetailWidth(for model: SidebarSessionRowModel) -> CGFloat? {
        guard let directory = model.directory, !directory.isEmpty,
              let branch = model.branch, !branch.isEmpty else { return nil }
        var needed = textLeft
        needed += SidebarLayers.width(of: directoryText(directory), font: branchFont) + 1
        needed += badgeGap + SidebarLayers.width(of: separatorText, font: branchFont) + 1
        needed += badgeGap + SidebarLayers.width(of: branchText(branch), font: branchFont) + 1
        if model.isWorktree {
            needed += badgeGap + SidebarBadgeLayer.width(for: "WT", font: badgeFont)
        }
        if let size = model.memoryBadge, !size.isEmpty {
            needed += badgeGap + SidebarBadgeLayer.width(for: size, font: badgeFont)
        }
        if let label = model.accountLabel, !label.isEmpty {
            needed += badgeGap + SidebarBadgeLayer.width(for: label, font: badgeFont)
        }
        return needed + rightInset
    }

    /// The row height the outline view must return for `model` at `width`: 44, or 59 when the
    /// detail line wraps.
    public static func height(for model: SidebarSessionRowModel, width: CGFloat) -> CGFloat {
        detailWraps(for: model, width: width)
            ? CGFloat(SidebarMetrics.sessionRowWrappedHeight)
            : CGFloat(SidebarMetrics.sessionRowHeight)
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let w = bounds.width
        let h = bounds.height
        let badgeH = SidebarBadgeLayer.height

        // Full height and flush left, exactly as on the header — with `intercellSpacing == .zero`
        // that makes one unbroken stripe from the header down to the group's last row.
        edgeLayer.frame = CGRect(x: 0, y: 0, width: SidebarMetrics.groupEdgeWidth, height: h)

        selectionLayer.frame = CGRect(
            x: Self.selectionInset,
            y: 2,
            width: max(0, w - Self.selectionInset * 2),
            height: max(0, h - 4)
        )

        let d = StatusDotLayer.diameter
        statusDot.frame = CGRect(
            x: Self.dotCenterX - d / 2,
            y: ((h - d) / 2).rounded(),
            width: d,
            height: d
        )

        // While hovered the `×` takes the right edge, vertically centred, and everything on the
        // right shifts left by its width so nothing is drawn under it.
        let closeReserve: CGFloat = isHovered ? Self.closeSize + Self.badgeGap : 0
        closeLayer.frame = CGRect(
            x: w - Self.rightInset - Self.closeSize + 2,
            y: ((h - Self.closeSize) / 2).rounded(),
            width: Self.closeSize, height: Self.closeSize)

        // Title line: NEEDS YOU is right-aligned and the title gets what is left. (The pane count
        // that used to sit inside NEEDS YOU went with the other row counters, 2026-09-10.)
        let titleY = h - Self.titleTop
        var titleRight = w - Self.rightInset - closeReserve
        if !needsYouBadge.isHidden {
            let x = w - Self.rightInset - closeReserve - needsYouBadgeWidth
            needsYouBadge.frame = CGRect(
                x: x,
                y: titleY + (Self.titleLineHeight - badgeH) / 2,
                width: needsYouBadgeWidth,
                height: badgeH
            )
            titleRight = x - Self.badgeGap
        }
        titleLayer.frame = CGRect(
            x: Self.textLeft,
            y: titleY,
            width: max(Self.minTitleWidth, titleRight - Self.textLeft),
            height: Self.titleLineHeight
        )

        // Detail line(s). Single line: `…/folder · ⎇ branch WT … [size] [chip]`. Wrapped: the
        // folder alone on the first line, the branch with every badge on the second. The wrap is
        // decided at the unhovered width (see `detailWraps`), so hover only truncates.
        let wraps = Self.detailWraps(for: model, width: w)
        let folderLineY = h - Self.detailTop
        let branchLineY = wraps ? folderLineY - Self.detailLinePitch : folderLineY

        // Account chip right-aligned on the branch line, the memory badge before it.
        var detailRight = w - Self.rightInset - closeReserve
        if !accountChip.isHidden {
            let x = w - Self.rightInset - closeReserve - accountChipWidth
            accountChip.frame = CGRect(x: x, y: branchLineY, width: accountChipWidth, height: badgeH)
            detailRight = x - Self.badgeGap
        }
        if !memoryBadge.isHidden {
            let x = detailRight - memoryBadgeWidth
            memoryBadge.frame = CGRect(x: x, y: branchLineY, width: memoryBadgeWidth, height: badgeH)
            detailRight = x - Self.badgeGap
        }

        var detailLeft = Self.textLeft
        if !directoryLayer.isHidden {
            // Wrapped, the folder has the whole first line to itself; otherwise it shares the
            // badges' line. Either way it is clamped so a pathological name cannot escape the row.
            let lineRight = wraps ? w - Self.rightInset - closeReserve : detailRight
            let natural = SidebarLayers.width(of: (directoryLayer.string as? String) ?? "", font: branchFont) + 1
            let width = min(natural, max(0, lineRight - detailLeft))
            directoryLayer.frame = CGRect(x: detailLeft, y: folderLineY, width: width, height: badgeH)
            if !wraps { detailLeft += width + Self.badgeGap }
        }
        separatorLayer.isHidden = directoryLayer.isHidden || branchLayer.isHidden || wraps
        if !separatorLayer.isHidden {
            let width = SidebarLayers.width(of: Self.separatorText, font: branchFont) + 1
            separatorLayer.frame = CGRect(x: detailLeft, y: folderLineY, width: width, height: badgeH)
            detailLeft += width + Self.badgeGap
        }
        if !branchLayer.isHidden {
            let natural = SidebarLayers.width(of: (branchLayer.string as? String) ?? "", font: branchFont) + 1
            let available = max(0, detailRight - detailLeft - (wtBadge.isHidden ? 0 : wtBadgeWidth + Self.badgeGap))
            let width = min(natural, available)
            branchLayer.frame = CGRect(x: detailLeft, y: branchLineY, width: width, height: badgeH)
            detailLeft += width + Self.badgeGap
        }
        if !wtBadge.isHidden {
            // Clamp so the badge never escapes the row when the branch name eats the whole line.
            let x = min(detailLeft, max(Self.textLeft, detailRight - wtBadgeWidth))
            wtBadge.frame = CGRect(x: x, y: branchLineY, width: wtBadgeWidth, height: badgeH)
        }

        refreshAccountTooltip()
    }

    /// One tooltip rect over the **whole row**, resolved per point in
    /// ``view(_:stringForToolTip:point:userData:)``.
    ///
    /// The chip is a `CALayer` in a row that deliberately has no subviews at all (see the file
    /// header), so the transparent-`NSButton` trick `GroupRowView` uses for its `＋` is not
    /// available. This is the `StatusBarView` pattern instead: register rects, own them as an
    /// `NSViewToolTipOwner`, and answer against the frames that were actually painted.
    /// `addToolTip` installs a tracking rect, not a view, so the headless render is untouched.
    ///
    /// Covering the whole row rather than the chip is what keeps the 24 pt hover shift of
    /// `closeReserve` from needing a re-registration of its own.
    ///
    /// **Only re-registered when it actually changes.** `layout()` runs on every scroll tick and
    /// again whenever `isHovered` flips, and tearing the rect down while the pointer is already
    /// inside it is how a tooltip goes missing until the pointer moves again: AppKit does not
    /// reliably re-enter a tracking rect that appeared under a stationary cursor. `StatusBarView`
    /// re-registers on `invalidatePlacement()` rather than on every layout for the same reason.
    private func refreshAccountTooltip() {
        let wanted = accountChip.isHidden ? nil : model.accountTooltip
        let rect = wanted == nil ? nil : bounds
        guard rect != registeredTooltipRect || wanted != registeredTooltipText else { return }
        registeredTooltipRect = rect
        registeredTooltipText = wanted
        removeAllToolTips()
        if let rect { addToolTip(rect, owner: self, userData: nil) }
    }
}

extension SessionRowView: NSViewToolTipOwner {
    /// The account line, but only over the chip itself — `""` everywhere else, so the rest of the
    /// row shows no tooltip. The view is unflipped (``isFlipped``), so `point` and the layer frames
    /// already share one coordinate space.
    public func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint, userData: UnsafeMutableRawPointer?
    ) -> String {
        guard !accountChip.isHidden, accountChip.frame.contains(point) else { return "" }
        return model.accountTooltip ?? ""
    }
}
