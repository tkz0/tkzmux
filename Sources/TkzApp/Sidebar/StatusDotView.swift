// StatusDotView / StatusDotLayer — the session status dot and its pulse (M2.3 / TKZ-19).
//
// The pulse is the one animation in the sidebar, and design.md is explicit about how it must be
// done: *"one `CABasicAnimation` on a layer (GPU-side, zero app CPU), only on visible `working`
// rows, paused when occluded"*. So:
//
//   * the animation lives on a `CALayer` and is added **once**, under a fixed key, so re-applying
//     the same model cannot stack duplicates;
//   * there is no timer and no `setNeedsDisplay` anywhere in this file — once added, the render
//     server owns it and the app process does no per-frame work;
//   * it is removed on reuse, on any status change away from `.working`, and when the owning view
//     leaves its window — a recycled or detached row must not keep an animation alive;
//   * `setOccluded(true)` sets `speed = 0` on the **dot layer only**. Parking the row's layer would
//     freeze everything on it, and parking the whole window's layer is not this view's business.
//
// **Why the dot is a `CALayer` and not an `NSView`.** Everything in `Sidebar/` is rasterised
// headlessly in the tests via `CALayer.render(in:)`, and a subview's backing layer is only grafted
// into its superview's layer tree once the hierarchy reaches a window — so an `NSView`-based dot
// renders as *nothing* in a headless bitmap (observed: the first version of these rows produced a
// dotless PNG). `StatusDotLayer` carries the behaviour; `StatusDotView` is a thin host for anywhere
// a standalone view is wanted. `SessionRowView` uses the layer directly.

import AppKit
import TkzCore

/// A 7 pt status dot. `exited` draws as a hollow ring so it reads as "not alive" without needing a
/// colour token of its own.
public final class StatusDotLayer: CALayer {
    /// Key the pulse is registered under. Exposed so the row view and the tests can assert presence
    /// without duplicating the string.
    public static let pulseAnimationKey = "tkz.sidebar.pulse"

    /// Dot diameter in points.
    public static let diameter: Double = 7

    private var status: SidebarStatus = .idle
    private var theme: Theme = .default
    private var occluded = false

    public override init() {
        super.init()
        cornerRadius = Self.diameter / 2
        bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        actions = [
            "backgroundColor": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull(),
            "position": NSNull(), "bounds": NSNull(), "opacity": NSNull(),
        ]
        apply()
    }

    // `CALayer` needs this for its internal presentation-layer copies.
    public override init(layer: Any) {
        if let other = layer as? StatusDotLayer {
            status = other.status
            theme = other.theme
            occluded = other.occluded
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds layers in code") }

    // MARK: Configuration

    /// Sets the status and theme. Idempotent: calling it twice with the same values leaves exactly
    /// one pulse animation attached (or none).
    public func configure(status: SidebarStatus, theme: Theme) {
        self.status = status
        self.theme = theme
        apply()
    }

    /// Removes the pulse and returns the dot to its resting state. Called from the row's
    /// `prepareForReuse()`.
    public func reset() {
        status = .idle
        occluded = false
        speed = 1
        opacity = 1
        removeAnimation(forKey: Self.pulseAnimationKey)
        apply()
    }

    /// Removes the pulse without changing the status — the detach path
    /// (`viewDidMoveToWindow` with a `nil` window).
    public func suspend() {
        removeAnimation(forKey: Self.pulseAnimationKey)
    }

    /// Re-adds the pulse if the current status calls for one — the re-attach path.
    public func resume() {
        apply()
    }

    /// Parks (`true`) or resumes (`false`) the animation without removing it.
    ///
    /// `speed = 0` stops the render server advancing the animation, which is what makes an occluded
    /// window cost nothing. Resuming does not restore the phase the animation was parked at — for a
    /// symmetric autoreversing opacity pulse that is invisible, so no `timeOffset` bookkeeping.
    public func setOccluded(_ occluded: Bool) {
        guard occluded != self.occluded else { return }
        self.occluded = occluded
        speed = occluded ? 0 : 1
    }

    /// `true` when the pulse animation is attached. Structural, so tests need no window.
    public var isPulsing: Bool { animation(forKey: Self.pulseAnimationKey) != nil }

    /// The dot's fill colour as configured — transparent for `.exited`, which draws as a ring.
    public var fillColor: CGColor? { backgroundColor }

    /// The dot's ring colour — non-nil only for `.exited`.
    public var strokeColor: CGColor? { borderWidth > 0 ? borderColor : nil }

    /// The layer clock speed; `0` while occluded.
    public var pulseSpeed: Float { speed }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch status {
        case .working:
            backgroundColor = theme.working.cgColor
            borderWidth = 0
        case .waiting:
            backgroundColor = theme.waiting.cgColor
            borderWidth = 0
        case .idle:
            backgroundColor = theme.idle.cgColor
            borderWidth = 0
        case .exited:
            // No token exists for `exited`; a hollow `idle`-coloured ring reads as "gone" without
            // inventing a colour, and stays correct in all five presets.
            backgroundColor = NSColor.clear.cgColor
            borderWidth = 1
            borderColor = theme.idle.cgColor
        }

        if status == .working {
            // Only add if absent: re-applying an unchanged model must not stack animations.
            if animation(forKey: Self.pulseAnimationKey) == nil {
                add(Self.makePulse(), forKey: Self.pulseAnimationKey)
            }
        } else {
            removeAnimation(forKey: Self.pulseAnimationKey)
            opacity = 1
        }
        speed = occluded ? 0 : 1
    }

    /// The pulse: opacity 0.4 → 1, autoreversing, infinite, ease-in-ease-out.
    static func makePulse() -> CABasicAnimation {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.4
        pulse.toValue = 1.0
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Survives the layer being detached and re-attached by the outline view's recycling.
        pulse.isRemovedOnCompletion = false
        return pulse
    }
}

/// A standalone view host for a `StatusDotLayer`. `SessionRowView` does **not** use this — it hosts
/// the layer directly, so the row rasterises headlessly. Kept for anywhere a dot is wanted on its
/// own (a status-bar indicator, a menu item).
public final class StatusDotView: NSView {
    public let dot = StatusDotLayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    public override var isFlipped: Bool { false }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: StatusDotLayer.diameter, height: StatusDotLayer.diameter)
    }

    public override func layout() {
        super.layout()
        let d = StatusDotLayer.diameter
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(
            x: ((bounds.width - d) / 2).rounded(),
            y: ((bounds.height - d) / 2).rounded(),
            width: d, height: d
        )
        CATransaction.commit()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dot.suspend() } else { dot.resume() }
    }
}

// MARK: - Shared layer helpers

/// Small factory helpers shared by the sidebar row views, so every text run is configured the same
/// way. `CATextLayer` has two traps worth naming: `font` does **not** carry the point size (that is
/// `fontSize`, separately), and a layer with the default `contentsScale` of 1 renders blurry on a
/// retina backing.
enum SidebarLayers {
    static func text(_ font: NSFont, color: CGColor, alignment: CATextLayerAlignmentMode = .left) -> CATextLayer {
        let layer = CATextLayer()
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = color
        layer.alignmentMode = alignment
        layer.isWrapped = false
        layer.truncationMode = .end
        layer.contentsScale = 2
        layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        return layer
    }

    /// A rounded background layer (selection, badges, chips).
    static func fill(cornerRadius: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.cornerRadius = cornerRadius
        layer.actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
        return layer
    }

    /// Width of `string` in `font`, rounded up — used for the manual (non–Auto Layout) row layout.
    static func width(of string: String, font: NSFont) -> CGFloat {
        let size = (string as NSString).size(withAttributes: [.font: font])
        return size.width.rounded(.up)
    }

    /// Vertically centred frame for a single line of `font` inside a box of height `height`.
    static func centredLine(x: CGFloat, width: CGFloat, in height: CGFloat, font: NSFont) -> CGRect {
        let lineHeight = (font.ascender - font.descender).rounded(.up)
        return CGRect(x: x, y: ((height - lineHeight) / 2).rounded(), width: width, height: lineHeight)
    }

    /// Applies `scale` to a layer tree. Views call this from `setContentsScale(_:)`.
    static func applyContentsScale(_ scale: CGFloat, to layer: CALayer) {
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] {
            applyContentsScale(scale, to: sublayer)
        }
    }
}

// MARK: - Badge

/// A small uppercase pill (`WT`, `NEEDS YOU`) drawn entirely with layers.
final class SidebarBadgeLayer: CALayer {
    static let height: CGFloat = 13
    static let horizontalPadding: CGFloat = 4.5

    private let label: CATextLayer
    private let font: NSFont

    init(font: NSFont) {
        self.font = font
        self.label = SidebarLayers.text(font, color: NSColor.clear.cgColor, alignment: .center)
        super.init()
        cornerRadius = 3
        actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        addSublayer(label)
    }

    override init(layer: Any) {
        let other = layer as? SidebarBadgeLayer
        self.font = other?.font ?? NSFont.systemFont(ofSize: 9, weight: .semibold)
        self.label = other?.label ?? CATextLayer()
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds layers in code") }

    /// Sets the text and colours, and returns the width the badge needs.
    @discardableResult
    func configure(text: String, foreground: RGB, background: RGB) -> CGFloat {
        label.string = text
        label.foregroundColor = foreground.cgColor
        backgroundColor = background.cgColor
        return SidebarLayers.width(of: text, font: font) + Self.horizontalPadding * 2
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        // CATextLayer draws its first line at the top of its box, so centre it by hand.
        label.frame = SidebarLayers.centredLine(x: 0, width: bounds.width, in: bounds.height, font: font)
    }
}
