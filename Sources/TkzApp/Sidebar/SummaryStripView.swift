// SummaryStripView — the "N WORKING · N NEED YOU" strip at the top of the session list (M2.3 /
// TKZ-19; moved from the bottom to the top and set in the group headers' uppercase caption style on
// 2026-09-08, which is where and how artboard 2c draws it).
//
// One `CATextLayer` holding an `NSAttributedString` with three runs, so the two counts carry the
// same colours as their status dots (`Theme.working`, `Theme.waiting`) and the separator is dim.
// Same face as a group header's name: semibold caption, uppercased, with a little tracking.
//
// A single layer rather than three keeps the strip trivially centred and makes the "renders
// identically twice" guarantee obvious: the string is a pure function of the model and the theme.

import AppKit
import TkzCore

public final class SummaryStripView: NSView {
    /// Fixed strip height.
    public static let height: Double = SidebarMetrics.summaryStripHeight

    /// Aligned with a group header's name (`GroupRowView.nameLeft`), so the column reads as one.
    private static let leftInset: CGFloat = 25
    private static let rightInset: CGFloat = 12
    /// The tracking the uppercase style wants; group headers get theirs from the system font's
    /// small-caps-ish caption metrics, this one is explicit so the two read alike.
    private static let tracking: CGFloat = 0.6

    private let font = Theme.Fonts.ui(Theme.Fonts.ui.caption, weight: .semibold)
    private lazy var textLayer = SidebarLayers.text(font, color: NSColor.clear.cgColor)

    private var model = SidebarSummaryModel()
    private var theme: Theme = .default

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(textLayer)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    public override var isFlipped: Bool { false }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    public func configure(_ model: SidebarSummaryModel, theme: Theme) {
        self.model = model
        self.theme = theme
        apply()
        needsLayout = true
        layoutSubtreeIfNeeded()
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

    /// The rendered string, for tests and for the accessibility label.
    public var summaryText: String { Self.text(for: model) }

    static func text(for model: SidebarSummaryModel) -> String {
        "\(model.working) working · \(model.needAttention) need you"
    }

    /// What is drawn: the same words, uppercased.
    static func displayText(for model: SidebarSummaryModel) -> String {
        text(for: model).uppercased()
    }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
            string: "\(model.working) WORKING",
            attributes: [.font: font, .foregroundColor: theme.working.nsColor, .kern: Self.tracking]
        ))
        attributed.append(NSAttributedString(
            string: " · ",
            attributes: [.font: font, .foregroundColor: theme.foregroundDim.nsColor, .kern: Self.tracking]
        ))
        attributed.append(NSAttributedString(
            string: "\(model.needAttention) NEED YOU",
            attributes: [.font: font, .foregroundColor: theme.waiting.nsColor, .kern: Self.tracking]
        ))
        textLayer.string = attributed
        setAccessibilityLabel(summaryText)
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let lineHeight = (font.ascender - font.descender).rounded(.up)
        textLayer.frame = CGRect(
            x: Self.leftInset,
            y: ((bounds.height - lineHeight) / 2).rounded(),
            width: max(0, bounds.width - Self.leftInset - Self.rightInset),
            height: lineHeight
        )
    }
}
