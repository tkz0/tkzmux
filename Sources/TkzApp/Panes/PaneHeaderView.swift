// The 28 pt strip above a split pane, drawn entirely with layers (design 2c.3 / 2c.4).
//
//   ● title  ~/dev/repo  NEEDS YOU  ×
//
// No subviews, for the reason `TabStripView` and `SessionRowView` state: a subview's backing layer
// is not grafted into the tree until the hierarchy reaches a window, so a header built from
// subviews is missing from a headless bitmap. Colours come from `Theme` and nothing else; the dot,
// badge and text primitives are the sidebar's.

import AppKit
import TkzCore

final class PaneHeaderView: NSView {
    /// The header was clicked: put the keyboard in this pane.
    var onActivate: (() -> Void)?
    /// The `×` was clicked: close this pane. A header only exists while the tab has another pane,
    /// so this is always a pane closing, never the row.
    var onClose: (() -> Void)?

    private(set) var model = PaneHeaderModel(title: "", path: "")
    private var theme: Theme

    private let titleFont = Theme.Fonts.ui(Theme.Fonts.ui.body, weight: .medium)
    private let pathFont = Theme.Fonts.mono(Theme.Fonts.mono.detail)
    private let badgeFont = Theme.Fonts.ui(9, weight: .semibold)

    private let bottomBorder = SidebarLayers.fill(cornerRadius: 0)
    private let dot = StatusDotLayer()
    private let title: CATextLayer
    private let path: CATextLayer
    private let badge: SidebarBadgeLayer
    private let close: CATextLayer
    private var badgeWidth: CGFloat = 0
    private var closeHovered = false
    private var trackingArea: NSTrackingArea?

    init(theme: Theme) {
        self.theme = theme
        title = SidebarLayers.text(titleFont, color: NSColor.clear.cgColor)
        path = SidebarLayers.text(pathFont, color: NSColor.clear.cgColor)
        badge = SidebarBadgeLayer(font: badgeFont)
        close = SidebarLayers.text(
            Theme.Fonts.ui(Theme.Fonts.ui.title, weight: .medium), color: NSColor.clear.cgColor,
            alignment: .center)
        close.string = "\u{00D7}"
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: PaneHeaderMetrics.height))
        wantsLayer = true
        layer?.actions = ["backgroundColor": NSNull()]
        // The header's dot is 6 pt; the sidebar's layer draws 7. Resize rather than subclass.
        dot.cornerRadius = PaneHeaderMetrics.dotDiameter / 2
        dot.bounds = CGRect(
            x: 0, y: 0, width: PaneHeaderMetrics.dotDiameter, height: PaneHeaderMetrics.dotDiameter)
        for sublayer in [bottomBorder, dot, title, path, badge, close] as [CALayer] {
            layer?.addSublayer(sublayer)
        }
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: PaneHeaderMetrics.height)
    }

    // MARK: Configuration

    func configure(_ model: PaneHeaderModel, theme: Theme) {
        guard model != self.model || theme != self.theme else { return }
        self.model = model
        self.theme = theme
        applyTheme()
        needsLayout = true
    }

    func setTheme(_ theme: Theme) {
        configure(model, theme: theme)
    }

    private func applyTheme() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let focused = model.isFocused
        layer?.backgroundColor =
            (focused ? theme.paneHeaderBackground : theme.paneHeaderBackgroundInactive).cgColor
        bottomBorder.backgroundColor = theme.border.cgColor

        dot.configure(status: model.status, theme: theme)

        title.string = model.title
        title.foregroundColor = (focused ? theme.foreground : theme.summaryText).cgColor
        path.string = model.path
        path.foregroundColor = (focused ? theme.paneHeaderPath : theme.paneHeaderPathInactive).cgColor

        // Always drawn, dim; the pointer over it brings it up to full text colour. The sidebar
        // hides its `×` until hover, but a pane's is the one affordance the header has for the
        // mouse and Thomas asked for it to be visible (2026-09-10).
        close.foregroundColor = (closeHovered ? theme.foreground : theme.foregroundDim).cgColor

        badge.isHidden = !model.needsAttention
        badgeWidth = badge.isHidden
            ? 0
            : badge.configure(
                text: "NEEDS YOU", foreground: theme.needsYouText,
                background: theme.needsYouBackground)
    }

    func setContentsScale(_ scale: CGFloat) {
        if let layer { SidebarLayers.applyContentsScale(scale, to: layer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setContentsScale(window?.backingScaleFactor ?? 2)
        if window == nil { dot.suspend() } else { dot.resume() }
    }

    // MARK: Layout

    /// Left to right: dot · title · path · badge · ×. The title keeps its natural width while it
    /// fits; past that the path gives way first (it is the longer, less specific string), then
    /// the title truncates, and neither the badge nor the `×` is ever squeezed.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let height = bounds.height
        bottomBorder.frame = CGRect(x: 0, y: height - 1, width: bounds.width, height: 1)

        var x = PaneHeaderMetrics.insetX

        if !dot.isHidden {
            let d = PaneHeaderMetrics.dotDiameter
            dot.frame = CGRect(x: x, y: ((height - d) / 2).rounded(), width: d, height: d)
            x += d + PaneHeaderMetrics.gap
        }

        let closeRect = Self.closeRect(width: bounds.width, height: height)
        close.frame = SidebarLayers.centredLine(
            x: closeRect.minX, width: closeRect.width, in: height, font: titleFont)

        var badgeLeft = closeRect.minX - PaneHeaderMetrics.gap
        if !badge.isHidden {
            badgeLeft -= badgeWidth
            badge.frame = CGRect(
                x: badgeLeft, y: ((height - SidebarBadgeLayer.height) / 2).rounded(),
                width: badgeWidth, height: SidebarBadgeLayer.height)
            badgeLeft -= PaneHeaderMetrics.gap
        }

        let available = max(0, badgeLeft - x)
        let titleNatural = SidebarLayers.width(of: model.title, font: titleFont)
        let pathNatural = SidebarLayers.width(of: model.path, font: pathFont)
        let titleWidth = min(titleNatural, available)
        let pathWidth = model.path.isEmpty
            ? 0 : max(0, min(pathNatural, available - titleWidth - PaneHeaderMetrics.gap))

        title.frame = SidebarLayers.centredLine(x: x, width: titleWidth, in: height, font: titleFont)
        x += titleWidth + PaneHeaderMetrics.gap
        path.isHidden = pathWidth <= 0
        path.frame = SidebarLayers.centredLine(x: x, width: pathWidth, in: height, font: pathFont)
    }

    /// The `×`'s hit box: a `closeSize` square against the right inset. Pure, so the hit test is
    /// a test and not a screenshot.
    static func closeRect(width: CGFloat, height: CGFloat) -> CGRect {
        let side = PaneHeaderMetrics.closeSize
        return CGRect(
            x: width - PaneHeaderMetrics.insetX - side + 2, y: ((height - side) / 2).rounded(),
            width: side, height: side)
    }

    func isOnClose(_ point: CGPoint) -> Bool {
        Self.closeRect(width: bounds.width, height: bounds.height).contains(point)
    }

    // MARK: Mouse

    /// Same as `TerminalMetalView`: a click from another app both activates the window and
    /// focuses the pane.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setCloseHovered(isOnClose(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setCloseHovered(false)
    }

    private func setCloseHovered(_ hovered: Bool) {
        guard hovered != closeHovered else { return }
        closeHovered = hovered
        applyTheme()
    }

    override func mouseDown(with event: NSEvent) {
        if isOnClose(convert(event.locationInWindow, from: nil)) {
            onClose?()
        } else {
            onActivate?()
        }
    }

    // MARK: Test hooks

    var backgroundColor: CGColor? { layer?.backgroundColor }
    var titleLayer: CATextLayer { title }
    var pathLayer: CATextLayer { path }
    var dotLayer: StatusDotLayer { dot }
    var badgeLayer: CALayer { badge }
    var closeLayer: CATextLayer { close }
}
