// NewGroupFooterView — the dashed "＋ New group" button at the foot of the sidebar (artboard 2c).
//
//     ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
//     │           ＋ New group               │   26 pt, 7 pt radius, 1 pt dashed border
//     └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
//       10 pt side margins, 2 pt above, 10 pt below → 38 pt strip
//
// Built like `GroupRowView`'s `＋`: the label is a `CATextLayer` and the border a `CAShapeLayer`, so
// both appear in a headless bitmap, with a transparent `NSButton` on top purely for hit-testing,
// tooltip and accessibility. The work is done by `onNewGroup`.

import AppKit
import TkzCore

public final class NewGroupFooterView: NSView {
    /// Fixed strip height (button plus the design's margins).
    public static let height: Double = SidebarMetrics.newGroupFooterHeight

    static let sideMargin: CGFloat = 10
    static let topMargin: CGFloat = 2
    static let bottomMargin: CGFloat = 10
    static let buttonHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 7

    private let font = Theme.Fonts.ui(Theme.Fonts.ui.body, weight: .medium)
    private lazy var labelLayer = SidebarLayers.text(font, color: NSColor.clear.cgColor, alignment: .center)
    private let borderLayer = CAShapeLayer()

    /// The transparent hit target over the whole button.
    public let button = NSButton(frame: .zero)

    /// Invoked when the button is clicked.
    public var onNewGroup: (@MainActor () -> Void)?

    private var theme: Theme = .default

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        borderLayer.lineDashPattern = [3, 3]
        borderLayer.actions = ["path": NSNull(), "strokeColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(borderLayer)
        layer?.addSublayer(labelLayer)

        button.isBordered = false
        button.isTransparent = true
        button.title = ""
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = #selector(clicked)
        button.toolTip = "New group"
        button.setAccessibilityLabel(Self.title)
        addSubview(button)

        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    public override var isFlipped: Bool { false }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    /// The button's caption, for tests and the accessibility label.
    public static let title = "\u{FF0B} New group"   // ＋ New group

    public func configure(theme: Theme) {
        self.theme = theme
        apply()
    }

    /// Keeps the layers crisp when the view moves between a retina and a 1x display.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setContentsScale(window?.backingScaleFactor ?? 2)
    }

    public func setContentsScale(_ scale: CGFloat) {
        if let layer { SidebarLayers.applyContentsScale(scale, to: layer) }
    }

    @objc private func clicked() { onNewGroup?() }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        labelLayer.string = Self.title
        labelLayer.foregroundColor = theme.foregroundMuted.cgColor
        // The design's `rgba(139,145,156,0.4)` dashed border, in tokens.
        let dim = theme.foregroundDim
        borderLayer.strokeColor = RGB(r: dim.r, g: dim.g, b: dim.b, a: 0.4).cgColor
    }

    // MARK: Test hooks (internal)

    var labelTextLayer: CATextLayer { labelLayer }
    var dashedBorderLayer: CAShapeLayer { borderLayer }
    /// The button rectangle in the view's coordinates.
    var buttonFrame: NSRect { button.frame }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Non-flipped: y = 0 is the bottom of the strip, so the bottom margin sits under the button.
        let frame = NSRect(
            x: Self.sideMargin,
            y: Self.bottomMargin,
            width: max(0, bounds.width - Self.sideMargin * 2),
            height: Self.buttonHeight)
        button.frame = frame
        // Stroke on the half-pixel so a 1 pt dash is one crisp pixel at 1x rather than two soft ones.
        let path = CGPath(
            roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        borderLayer.frame = bounds
        borderLayer.path = path
        labelLayer.frame = SidebarLayers.centredLine(
            x: frame.minX, width: frame.width, in: frame.height, font: font)
            .offsetBy(dx: 0, dy: frame.minY)
    }
}
