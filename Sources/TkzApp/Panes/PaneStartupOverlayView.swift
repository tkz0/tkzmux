// PaneStartupOverlayView.swift — "Starting Claude…" over a pane whose boot command has not come
// back yet.
//
// Drawn entirely with layers, like everything in `Sidebar/` and `EmptyStateView`, so it
// rasterises headlessly and the tests assert structure without a window. The spinner is the
// sidebar pulse's discipline applied to a rotation: one `CABasicAnimation` on a layer, added once
// under a fixed key, removed the moment the overlay hides or leaves its window — a hidden overlay
// costs the render server nothing.
//
// A sibling of the terminal view inside `PaneChromeView`, never a subview of it: the terminal view
// is layer-hosted (`CAMetalLayer`) and does not take subviews. `hitTest` returns nil, so the
// overlay is invisible to the mouse and to the first-responder logic.

import AppKit
import TkzCore

final class PaneStartupOverlayView: NSView {
    /// Key the spin is registered under, so re-showing cannot stack a second one.
    static let spinAnimationKey = "tkz.pane.startup.spin"
    static let title = "Starting Claude\u{2026}"

    static let spinnerDiameter: CGFloat = 22
    static let spinnerLineWidth: CGFloat = 2
    static let gap: CGFloat = 10
    /// The scrim's alpha over `terminalBackground`: what the shell already printed stays faintly
    /// legible underneath.
    static let scrimAlpha: Double = 0.7

    private(set) var model: PaneStartupModel?
    private var theme: Theme
    private let spinner = CAShapeLayer()
    private let titleLayer: CATextLayer
    private let captionLayer: CATextLayer

    init(theme: Theme) {
        self.theme = theme
        titleLayer = SidebarLayers.text(
            Theme.Fonts.ui(theme.fontUI.title, weight: .medium),
            color: theme.foreground.cgColor, alignment: .center)
        captionLayer = SidebarLayers.text(
            Theme.Fonts.mono(theme.fontUI.body), color: theme.foregroundMuted.cgColor,
            alignment: .center)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.actions = [
            "backgroundColor": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull(),
        ]
        isHidden = true

        spinner.fillColor = nil
        spinner.lineWidth = Self.spinnerLineWidth
        spinner.lineCap = .round
        spinner.contentsScale = 2
        spinner.bounds = CGRect(
            x: 0, y: 0, width: Self.spinnerDiameter, height: Self.spinnerDiameter)
        // Three quarters of a ring; the gap is what makes the rotation visible.
        let inset = Self.spinnerLineWidth / 2
        spinner.path = CGPath(
            ellipseIn: spinner.bounds.insetBy(dx: inset, dy: inset), transform: nil)
        spinner.strokeStart = 0
        spinner.strokeEnd = 0.75
        spinner.actions = [
            "path": NSNull(), "strokeColor": NSNull(), "position": NSNull(), "bounds": NSNull(),
            "hidden": NSNull(),
        ]
        titleLayer.string = Self.title

        layer?.addSublayer(spinner)
        layer?.addSublayer(titleLayer)
        layer?.addSublayer(captionLayer)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Never the mouse's: clicks go through to the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isShowing: Bool { model != nil }

    /// `true` when the spin animation is attached. Structural, so tests need no window.
    var isSpinning: Bool { spinner.animation(forKey: Self.spinAnimationKey) != nil }

    var titleText: String? { titleLayer.string as? String }
    var captionText: String? { captionLayer.string as? String }

    // MARK: Configuration

    func show(_ model: PaneStartupModel, theme: Theme) {
        let themeChanged = theme != self.theme
        guard model != self.model || themeChanged else { return }
        self.model = model
        self.theme = theme
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        captionLayer.string = model.command
        if themeChanged { applyTheme() }
        isHidden = false
        startSpinning()
        needsLayout = true
    }

    func hide() {
        guard model != nil else { return }
        model = nil
        isHidden = true
        stopSpinning()
    }

    func apply(theme: Theme) {
        guard theme != self.theme else { return }
        self.theme = theme
        applyTheme()
    }

    private func applyTheme() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var scrim = theme.terminalBackground
        scrim.a = Self.scrimAlpha
        layer?.backgroundColor = scrim.cgColor
        spinner.strokeColor = theme.accent.cgColor
        titleLayer.font = Theme.Fonts.ui(theme.fontUI.title, weight: .medium)
        titleLayer.fontSize = theme.fontUI.title
        titleLayer.foregroundColor = theme.foreground.cgColor
        captionLayer.font = Theme.Fonts.mono(theme.fontUI.body)
        captionLayer.fontSize = theme.fontUI.body
        captionLayer.foregroundColor = theme.foregroundMuted.cgColor
        needsLayout = true
    }

    // MARK: Animation

    private func startSpinning() {
        // Only add if absent: re-applying an unchanged model must not stack animations.
        guard spinner.animation(forKey: Self.spinAnimationKey) == nil else { return }
        spinner.add(Self.makeSpin(), forKey: Self.spinAnimationKey)
    }

    private func stopSpinning() {
        spinner.removeAnimation(forKey: Self.spinAnimationKey)
    }

    /// One full turn a second, linear, forever.
    static func makeSpin() -> CABasicAnimation {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false
        return spin
    }

    func setContentsScale(_ scale: CGFloat) {
        if let layer { SidebarLayers.applyContentsScale(scale, to: layer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setContentsScale(window?.backingScaleFactor ?? 2)
        // Detached: nothing to animate for. Re-attached while still showing: back on.
        if window == nil { stopSpinning() } else if isShowing { startSpinning() }
    }

    // MARK: Layout

    /// Spinner over title over caption, the stack centred in the view.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let titleFont = Theme.Fonts.ui(theme.fontUI.title, weight: .medium)
        let captionFont = Theme.Fonts.mono(theme.fontUI.body)
        let titleHeight = (titleFont.ascender - titleFont.descender).rounded(.up)
        let captionHeight = (captionFont.ascender - captionFont.descender).rounded(.up)
        let hasCaption = !(model?.command.isEmpty ?? true)
        let stackHeight = Self.spinnerDiameter + Self.gap + titleHeight
            + (hasCaption ? Self.gap / 2 + captionHeight : 0)
        var y = ((bounds.height - stackHeight) / 2).rounded()
        let centreX = (bounds.width / 2).rounded()

        // `position`/`bounds` rather than `frame`: a rotating layer's frame is not its bounds.
        spinner.position = CGPoint(x: centreX, y: y + Self.spinnerDiameter / 2)
        y += Self.spinnerDiameter + Self.gap
        let textInset: CGFloat = 16
        let textWidth = max(0, bounds.width - 2 * textInset)
        titleLayer.frame = CGRect(x: textInset, y: y, width: textWidth, height: titleHeight)
        y += titleHeight + Self.gap / 2
        captionLayer.isHidden = !hasCaption
        captionLayer.frame = CGRect(x: textInset, y: y, width: textWidth, height: captionHeight)
    }
}
