// The tab strip, drawn entirely with layers (TKZ-36).
//
// No subviews, for the reason `SessionRowView` states: a subview's backing layer is not grafted
// into the tree until the hierarchy reaches a window, so a strip built from subviews is missing
// from a headless bitmap and cannot be asserted on without one. Colours come from `Theme` and
// nothing else; the pill and text primitives are the sidebar's.

import AppKit
import TkzCore

final class TabStripView: NSView {
    /// A tab was clicked.
    var onSelectTab: ((Int) -> Void)?
    /// A tab's `×` was clicked.
    var onCloseTab: ((Int) -> Void)?

    private var model = TabStripModel()
    private var theme: Theme
    private var hoveredIndex: Int?

    private let titleFont = Theme.Fonts.ui(Theme.Fonts.ui.title, weight: .medium)
    private let badgeFont = Theme.Fonts.ui(9, weight: .semibold)

    private let bottomBorder = SidebarLayers.fill(cornerRadius: 0)
    private var tabLayers: [TabLayers] = []
    private var trackingArea: NSTrackingArea?

    /// One tab's layers, kept together so `layout` places them without re-deriving anything.
    private struct TabLayers {
        let background: CALayer
        let title: CATextLayer
        let badge: SidebarBadgeLayer
        let close: CATextLayer
    }

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: TabStripMetrics.stripHeight))
        wantsLayer = true
        layer?.addSublayer(bottomBorder)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: TabStripMetrics.stripHeight)
    }

    // MARK: Configuration

    func configure(_ model: TabStripModel, theme: Theme) {
        // A theme swap changes no model, so it has to be its own reason to re-tint: without this
        // the strip keeps the old colours until the next tab is opened or closed.
        let themeChanged = theme != self.theme
        self.theme = theme
        let modelChanged = model != self.model || tabLayers.count != model.items.count
        guard themeChanged || modelChanged else { return }
        if modelChanged {
            self.model = model
            rebuildLayers()
        }
        applyTheme()
        needsLayout = true
    }

    private func rebuildLayers() {
        for tab in tabLayers {
            tab.background.removeFromSuperlayer()
            tab.title.removeFromSuperlayer()
            tab.badge.removeFromSuperlayer()
            tab.close.removeFromSuperlayer()
        }
        tabLayers = model.items.map { _ in
            let background = SidebarLayers.fill(cornerRadius: TabStripMetrics.cornerRadius)
            let title = SidebarLayers.text(titleFont, color: NSColor.clear.cgColor)
            let badge = SidebarBadgeLayer(font: badgeFont)
            let close = SidebarLayers.text(titleFont, color: NSColor.clear.cgColor, alignment: .center)
            close.string = "\u{00D7}"
            for layer in [background, title, badge, close] as [CALayer] {
                self.layer?.addSublayer(layer)
            }
            return TabLayers(background: background, title: title, badge: badge, close: close)
        }
    }

    private func applyTheme() {
        layer?.backgroundColor = theme.sidebarBackground.cgColor
        bottomBorder.backgroundColor = theme.border.cgColor

        for (index, item) in model.items.enumerated() {
            guard index < tabLayers.count else { break }
            let tab = tabLayers[index]
            // Selected reads as the sidebar's selection; hover is the same colour at 45 %, which
            // is the idiom `SessionRowView` established.
            if item.isSelected {
                tab.background.backgroundColor = theme.selection.cgColor
            } else if hoveredIndex == index {
                var hover = theme.selection
                hover.a *= 0.45
                tab.background.backgroundColor = hover.cgColor
            } else {
                tab.background.backgroundColor = NSColor.clear.cgColor
            }
            tab.title.string = item.title
            tab.title.foregroundColor =
                (item.isSelected ? theme.foreground : theme.foregroundMuted).cgColor

            tab.badge.isHidden = item.terminalCount <= 1
            if !tab.badge.isHidden {
                let tint = theme.foregroundMuted
                _ = tab.badge.configure(
                    text: "\(item.terminalCount)", foreground: tint,
                    background: RGB(r: tint.r, g: tint.g, b: tint.b, a: 0.18))
            }
            // The `×` appears on hover only, like the sidebar row's.
            tab.close.isHidden = hoveredIndex != index
            tab.close.foregroundColor = theme.foregroundDim.cgColor
        }
    }

    func setContentsScale(_ scale: CGFloat) {
        if let layer { SidebarLayers.applyContentsScale(scale, to: layer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setContentsScale(window?.backingScaleFactor ?? 2)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        bottomBorder.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)

        let rects = model.tabRects(in: bounds.width, height: bounds.height)
        for (index, rect) in rects.enumerated() where index < tabLayers.count {
            let tab = tabLayers[index]
            tab.background.frame = rect.insetBy(dx: 0, dy: 2)

            var right = rect.maxX - TabStripMetrics.horizontalInset
            if !tab.close.isHidden {
                tab.close.frame = SidebarLayers.centredLine(
                    x: right - TabStripMetrics.closeSize, width: TabStripMetrics.closeSize,
                    in: rect.height, font: titleFont)
                right -= TabStripMetrics.closeSize + TabStripMetrics.badgeGap
            }
            if !tab.badge.isHidden {
                let width = tab.badge.bounds.width
                tab.badge.frame = CGRect(
                    x: right - width,
                    y: ((rect.height - SidebarBadgeLayer.height) / 2).rounded(),
                    width: width, height: SidebarBadgeLayer.height)
                right -= width + TabStripMetrics.badgeGap
            }
            let left = rect.minX + TabStripMetrics.horizontalInset
            tab.title.frame = SidebarLayers.centredLine(
                x: left, width: max(0, right - left), in: rect.height, font: titleFont)
        }
    }

    // MARK: Mouse

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
        let point = convert(event.locationInWindow, from: nil)
        let index = model.tabIndex(at: point, width: bounds.width, height: bounds.height)
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        applyTheme()
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredIndex != nil else { return }
        hoveredIndex = nil
        applyTheme()
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = model.tabIndex(at: point, width: bounds.width, height: bounds.height)
        else { return }
        if model.isOnClose(point, width: bounds.width, height: bounds.height) {
            onCloseTab?(index)
        } else {
            onSelectTab?(index)
        }
    }

    // MARK: Test hooks

    var tabBackgroundLayers: [CALayer] { tabLayers.map(\.background) }
    var tabTitleLayers: [CATextLayer] { tabLayers.map(\.title) }
    var tabBadgeLayers: [CALayer] { tabLayers.map(\.badge) }
}
