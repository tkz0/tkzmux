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
// Geometry (row height 44, origin bottom-left — the view is not flipped):
//
//     ┌────────────────────────────────────────────────────────────┐
//     │  ●   Session title…                          NEEDS YOU     │  title line,  y 22…38
//     │      ⎇ branch   WT                                 [AC]    │  detail line, y  6…19
//     └────────────────────────────────────────────────────────────┘
//        ↑14                                                    12↑

import AppKit
import TkzCore

public final class SessionRowView: NSTableCellView {
    // MARK: Metrics (all from the design; see docs/design.md → App architecture → Sidebar)

    /// Fixed row height. The outline view must return this from `heightOfRowByItem`.
    public static let rowHeight: Double = SidebarMetrics.sessionRowHeight

    /// Both are measured from the group header's own leading edge and then indented, so the
    /// hierarchy is one constant (`SidebarMetrics.sessionIndent`) rather than two magic numbers
    /// that have to be kept in step with `GroupRowView`.
    private static let dotCenterX: CGFloat = 17.5 + CGFloat(SidebarMetrics.sessionIndent)
    private static let textLeft: CGFloat = 30 + CGFloat(SidebarMetrics.sessionIndent)
    private static let rightInset: CGFloat = 12
    private static let selectionInset: CGFloat = 5
    private static let titleLineHeight: CGFloat = 16
    private static let titleLineY: CGFloat = 22
    private static let detailLineY: CGFloat = 6
    private static let badgeGap: CGFloat = 6
    /// Smallest sensible title width; below this we still clip rather than let text escape the row.
    private static let minTitleWidth: CGFloat = 24

    // MARK: Fonts

    private let titleFont = Theme.Fonts.ui(Theme.Fonts.ui.title, weight: .medium)
    private let branchFont = Theme.Fonts.mono(Theme.Fonts.mono.detail)
    private let badgeFont = Theme.Fonts.ui(9, weight: .semibold)

    // MARK: Layers & subviews

    private let selectionLayer = SidebarLayers.fill(cornerRadius: 6)
    private lazy var titleLayer = SidebarLayers.text(titleFont, color: NSColor.clear.cgColor)
    private lazy var branchLayer = SidebarLayers.text(branchFont, color: NSColor.clear.cgColor)
    private lazy var wtBadge = SidebarBadgeLayer(font: badgeFont)
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
    private var needsYouBadgeWidth: CGFloat = 0
    private var accountChipWidth: CGFloat = 0

    // MARK: Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        guard let root = layer else { return }
        root.addSublayer(selectionLayer)
        root.addSublayer(titleLayer)
        root.addSublayer(branchLayer)
        root.addSublayer(wtBadge)
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
        branchLayer.string = nil
        wtBadge.isHidden = true
        needsYouBadge.isHidden = true
        accountChip.isHidden = true
        selectionLayer.backgroundColor = NSColor.clear.cgColor
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

        // The design renders the branch as `⎇ <name>`; the glyph is part of the string rather than a
        // separate layer so the two truncate together.
        if let branch = model.branch, !branch.isEmpty {
            branchLayer.string = "⎇ \(branch)"
            branchLayer.isHidden = false
        } else {
            branchLayer.string = nil
            branchLayer.isHidden = true
        }
        branchLayer.foregroundColor = theme.foregroundMuted.cgColor

        wtBadge.isHidden = !model.isWorktree
        if model.isWorktree {
            wtBadgeWidth = wtBadge.configure(text: "WT", foreground: theme.wtText, background: theme.wtBackground)
        } else {
            wtBadgeWidth = 0
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
    var branchTextLayer: CATextLayer { branchLayer }
    var worktreeBadgeLayer: CALayer { wtBadge }
    var needsYouBadgeLayer: CALayer { needsYouBadge }
    var accountChipLayer: CALayer { accountChip }
    var selectionBackgroundLayer: CALayer { selectionLayer }
    var titleFontForMeasurement: NSFont { titleFont }

    // MARK: Layout

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let w = bounds.width
        let h = bounds.height
        let badgeH = SidebarBadgeLayer.height

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

        // Title line: the NEEDS YOU badge is right-aligned and the title gets what is left.
        var titleRight = w - Self.rightInset - closeReserve
        if !needsYouBadge.isHidden {
            let x = w - Self.rightInset - closeReserve - needsYouBadgeWidth
            needsYouBadge.frame = CGRect(
                x: x,
                y: Self.titleLineY + (Self.titleLineHeight - badgeH) / 2,
                width: needsYouBadgeWidth,
                height: badgeH
            )
            titleRight = x - Self.badgeGap
        }
        titleLayer.frame = CGRect(
            x: Self.textLeft,
            y: Self.titleLineY,
            width: max(Self.minTitleWidth, titleRight - Self.textLeft),
            height: Self.titleLineHeight
        )

        // Detail line: account chip right-aligned, then branch text, then the WT badge after it.
        var detailRight = w - Self.rightInset - closeReserve
        if !accountChip.isHidden {
            let x = w - Self.rightInset - closeReserve - accountChipWidth
            accountChip.frame = CGRect(x: x, y: Self.detailLineY, width: accountChipWidth, height: badgeH)
            detailRight = x - Self.badgeGap
        }
        var detailLeft = Self.textLeft
        if !branchLayer.isHidden {
            let natural = SidebarLayers.width(of: (branchLayer.string as? String) ?? "", font: branchFont) + 1
            let available = max(0, detailRight - detailLeft - (wtBadge.isHidden ? 0 : wtBadgeWidth + Self.badgeGap))
            let width = min(natural, available)
            branchLayer.frame = CGRect(x: detailLeft, y: Self.detailLineY, width: width, height: badgeH)
            detailLeft += width + Self.badgeGap
        }
        if !wtBadge.isHidden {
            // Clamp so the badge never escapes the row when the branch name eats the whole line.
            let x = min(detailLeft, max(Self.textLeft, detailRight - wtBadgeWidth))
            wtBadge.frame = CGRect(x: x, y: Self.detailLineY, width: wtBadgeWidth, height: badgeH)
        }
    }
}
