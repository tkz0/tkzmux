// SummaryStripView — the "● N WORKING   ● N NEED YOU" strip at the top of the session list (M2.3 /
// TKZ-19; moved from the bottom to the top and set in the group headers' uppercase caption style on
// 2026-09-08, which is where and how the artboards draw it).
//
// Since 2c.1 the words are neutral (`Theme.summaryText`) and a static 7 pt dot before each count
// carries the status colour (`Theme.working`, `Theme.waiting`), the way the artboard draws it. The
// dots are plain layers, not `StatusDotLayer`: that one pulses while working and hides when idle,
// and neither belongs in a summary.
//
// Everything is a layer so the strip rasterises headlessly in the tests (see `StatusDotView.swift`
// for why an `NSView` dot would render as nothing there). The strip is a pure function of the model
// and the theme, so "renders identically twice" holds by construction.

import AppKit
import TkzCore

public final class SummaryStripView: NSView {
    /// Fixed strip height.
    public static let height: Double = SidebarMetrics.summaryStripHeight

    /// Aligned with a group header's name (`GroupRowView.nameLeft`), so the column reads as one.
    /// The working dot sits to the left of this, in the chevron column.
    private static let leftInset: CGFloat = 25
    private static let rightInset: CGFloat = 12
    /// Dot diameter, the same as a session row's status dot.
    private static let dotDiameter: CGFloat = StatusDotLayer.diameter
    /// Gap between a dot and its words, and between the two groups (artboard: 5 px and 12 px).
    private static let dotGap: CGFloat = 5
    private static let groupGap: CGFloat = 12
    /// The tracking the uppercase style wants; group headers get theirs from the system font's
    /// small-caps-ish caption metrics, this one is explicit so the two read alike.
    private static let tracking: CGFloat = 0.6

    private let font = Theme.Fonts.ui(Theme.Fonts.ui.caption, weight: .semibold)
    private let workingDot = SidebarLayers.fill(cornerRadius: StatusDotLayer.diameter / 2)
    private let waitingDot = SidebarLayers.fill(cornerRadius: StatusDotLayer.diameter / 2)
    private lazy var workingLabel = SidebarLayers.text(font, color: NSColor.clear.cgColor)
    private lazy var waitingLabel = SidebarLayers.text(font, color: NSColor.clear.cgColor)

    private var model = SidebarSummaryModel()
    private var theme: Theme = .default

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for sublayer in [workingDot, workingLabel, waitingDot, waitingLabel] {
            layer?.addSublayer(sublayer)
        }
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

    /// The same words, uppercased — the two drawn labels joined the way the old single-layer strip
    /// drew them. Kept for the controller tests; nothing draws this string any more.
    static func displayText(for model: SidebarSummaryModel) -> String {
        text(for: model).uppercased()
    }

    static func workingText(for model: SidebarSummaryModel) -> String { "\(model.working) WORKING" }
    static func waitingText(for model: SidebarSummaryModel) -> String { "\(model.needAttention) NEED YOU" }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        workingDot.backgroundColor = theme.working.cgColor
        waitingDot.backgroundColor = theme.waiting.cgColor
        workingLabel.string = attributed(Self.workingText(for: model))
        waitingLabel.string = attributed(Self.waitingText(for: model))
        setAccessibilityLabel(summaryText)
    }

    /// The words with the caption tracking. A `CATextLayer` given an attributed string ignores its
    /// own `font`/`foregroundColor`, so both travel in the string.
    private func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: theme.summaryText.nsColor, .kern: Self.tracking,
        ])
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let height = bounds.height
        let d = Self.dotDiameter
        let dotY = ((height - d) / 2).rounded()
        let maxX = bounds.width - Self.rightInset

        // Widths include the tracking, which `SidebarLayers.width` does not know about.
        let workingWidth = Self.width(of: Self.workingText(for: model), font: font)
        let waitingWidth = Self.width(of: Self.waitingText(for: model), font: font)

        var x = Self.leftInset - Self.dotGap - d
        workingDot.frame = CGRect(x: x, y: dotY, width: d, height: d)
        x = Self.leftInset
        workingLabel.frame = SidebarLayers.centredLine(
            x: x, width: min(workingWidth, max(0, maxX - x)), in: height, font: font)
        x = workingLabel.frame.maxX + Self.groupGap
        waitingDot.frame = CGRect(x: x, y: dotY, width: d, height: d)
        x += d + Self.dotGap
        waitingLabel.frame = SidebarLayers.centredLine(
            x: x, width: min(waitingWidth, max(0, maxX - x)), in: height, font: font)
        waitingDot.isHidden = waitingLabel.frame.width <= 0
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: font, .kern: tracking])
        return size.width.rounded(.up) + 1
    }

    // MARK: Test hooks (internal — see SessionRowView)

    var workingDotLayer: CALayer { workingDot }
    var waitingDotLayer: CALayer { waitingDot }
    var workingTextLayer: CATextLayer { workingLabel }
    var waitingTextLayer: CATextLayer { waitingLabel }
}
