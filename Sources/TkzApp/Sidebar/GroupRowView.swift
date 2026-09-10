// GroupRowView — the 28 pt sidebar group header (M2.3 / TKZ-19).
//
//     ┌────────────────────────────────────────────────────┐
//     ║ ▾  TKZMUX                                       ＋  │   28 pt
//     └────────────────────────────────────────────────────┘
//      ↑ 2.5 pt colour edge (CALayer; fully transparent when the group has no colour)
//
// The `＋` glyph is a `CATextLayer` (so it appears in a headless bitmap — a subview's backing layer
// is not in its superview's tree until the hierarchy reaches a window), with a *transparent*
// `NSButton` sitting on top of it purely for hit-testing, tooltip and cursor. The button's action is
// a closure wired by the controller in M2.4. Everything drawn is a layer; see `StatusDotView.swift`
// for the full reason.
//
// The chevron is a stroked `CAShapeLayer` (`SidebarLayers.chevron`), rotated a quarter turn when the
// group is collapsed. It used to be a `CATextLayer` holding `▾`/`▸` — U+25BE/U+25B8, the *small*
// triangles, whose ink fills roughly half the em box — and at 9 pt that read as a dot rather than a
// direction.
//
// The name is drawn in `Theme.groupHeaderText`, a token of its own since 2c.1 (it used to be
// derived by mixing `foreground` toward `foregroundMuted`, which only ever matched one artboard).

import AppKit
import TkzCore

public final class GroupRowView: NSTableCellView {
    /// Fixed row height. The outline view must return this from `heightOfRowByItem`.
    public static let rowHeight: Double = SidebarMetrics.groupRowHeight

    private static let chevronX: CGFloat = 11
    private static let chevronSide: CGFloat = 10
    private static let chevronLineWidth: CGFloat = 1.6
    private static let nameLeft: CGFloat = 25
    private static let rightInset: CGFloat = 8
    private static let addButtonSize: CGFloat = 18
    /// Between the name's right edge and the `＋`.
    private static let nameGap: CGFloat = 8
    private static let minNameWidth: CGFloat = 24

    // MARK: Fonts

    private let nameFont = Theme.Fonts.ui(Theme.Fonts.ui.caption, weight: .semibold)
    private let addFont = Theme.Fonts.ui(12)

    // MARK: Layers & subviews

    /// The 2.5 pt colour edge. Always present so layout never shifts; `backgroundColor` is fully
    /// transparent when the group has no colour.
    private let edgeLayer = SidebarLayers.fill(cornerRadius: 0)
    private lazy var chevronLayer = SidebarLayers.chevron(
        side: Self.chevronSide, lineWidth: Self.chevronLineWidth)
    private lazy var nameLayer = SidebarLayers.text(nameFont, color: NSColor.clear.cgColor)
    private lazy var addLayer = SidebarLayers.text(addFont, color: NSColor.clear.cgColor, alignment: .center)

    /// The transparent hit target over the `＋` glyph. Its target/action is this view; the work is
    /// done by `onAdd`.
    public let addButton = NSButton(frame: .zero)

    /// Invoked when `＋` is clicked. Wired in M2.4 (new-session menu); `nil` here.
    public var onAdd: (@MainActor () -> Void)?

    // MARK: Cached layout inputs

    private var model = SidebarGroupRowModel(name: "")
    private var theme: Theme = .default

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        guard let root = layer else { return }
        root.addSublayer(edgeLayer)
        root.addSublayer(chevronLayer)
        root.addSublayer(nameLayer)
        root.addSublayer(addLayer)

        addButton.isBordered = false
        addButton.isTransparent = true
        addButton.title = ""
        addButton.setButtonType(.momentaryChange)
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.toolTip = "New session in this group"
        addSubview(addButton)

        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    public override var isFlipped: Bool { false }

    // MARK: Configuration

    public func configure(_ model: SidebarGroupRowModel, theme: Theme) {
        self.model = model
        self.theme = theme
        apply()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        onAdd = nil
        model = SidebarGroupRowModel(name: "")
        nameLayer.string = nil
        edgeLayer.backgroundColor = NSColor.clear.cgColor
    }

    /// Keeps the text layers crisp when the row moves between a retina and a 1x display. The view
    /// owns its layers, so the controller never has to think about backing scale.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setContentsScale(window?.backingScaleFactor ?? 2)
    }

    public func setContentsScale(_ scale: CGFloat) {
        if let layer { SidebarLayers.applyContentsScale(scale, to: layer) }
    }

    /// The edge layer's colour. `nil`/zero alpha means "this group has no colour"; a test asserts it.
    public var edgeColor: CGColor? { edgeLayer.backgroundColor }

    @objc private func addClicked() { onAdd?() }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // `nil` colour → transparent, never `theme.groupEdgeDefault`: that token is the picker's
        // default, not a stand-in for an uncoloured group.
        edgeLayer.backgroundColor = model.color?.cgColor ?? NSColor.clear.cgColor

        // Rotating CCW in a y-up layer takes "down" to "right".
        chevronLayer.setAffineTransform(
            model.isCollapsed ? CGAffineTransform(rotationAngle: .pi / 2) : .identity)
        chevronLayer.strokeColor = theme.foregroundDim.cgColor

        nameLayer.string = model.name.uppercased()
        nameLayer.foregroundColor = theme.groupHeaderText.cgColor

        addLayer.string = "＋"
        addLayer.foregroundColor = theme.foregroundDim.cgColor
    }

    // MARK: Test hooks (internal — see SessionRowView)

    var nameTextLayer: CATextLayer { nameLayer }
    var chevronShapeLayer: CAShapeLayer { chevronLayer }
    /// `true` while the chevron is rotated a quarter turn — i.e. the group is collapsed.
    var chevronPointsRight: Bool { chevronLayer.affineTransform().b > 0.5 }
    var colourEdgeLayer: CALayer { edgeLayer }
    var addGlyphLayer: CATextLayer { addLayer }

    // MARK: Layout

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let w = bounds.width
        let h = bounds.height

        edgeLayer.frame = CGRect(x: 0, y: 0, width: SidebarMetrics.groupEdgeWidth, height: h)

        // `bounds`/`position` rather than `frame`: the collapsed state carries a rotation, and
        // `frame` is derived from the transform.
        let side = Self.chevronSide
        chevronLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        chevronLayer.position = CGPoint(x: Self.chevronX + side / 2, y: (h / 2).rounded())

        let btn = Self.addButtonSize
        let buttonFrame = NSRect(
            x: w - Self.rightInset - btn,
            y: ((h - btn) / 2).rounded(),
            width: btn,
            height: btn
        )
        addButton.frame = buttonFrame
        addLayer.frame = SidebarLayers.centredLine(
            x: buttonFrame.minX, width: btn, in: h, font: addFont)

        // The name takes everything up to the `＋`. There used to be a session count in between;
        // it went with the other row counters (2026-09-10: "they're just noise").
        let nameHeight = (nameFont.ascender - nameFont.descender).rounded(.up)
        nameLayer.frame = CGRect(
            x: Self.nameLeft,
            y: ((h - nameHeight) / 2).rounded(),
            width: max(Self.minNameWidth, buttonFrame.minX - Self.nameGap - Self.nameLeft),
            height: nameHeight
        )
    }
}
