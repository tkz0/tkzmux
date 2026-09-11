// UpdateNoticeView — the "Update available" card at the foot of the sidebar (design 2c.1, TKZ-50).
//
//     ┌──────────────────────────────────────────────┐
//     │ ┌──┐  Update available — v0.8.0            ✕ │   40 pt card, 9 pt radius, 1 pt border
//     │ │ ↓│  Update via Homebrew · What's new        │   22 pt tile, 6 pt radius; 12 pt title, 11 pt links
//     │ └──┘                                          │
//     └──────────────────────────────────────────────┘
//       10 pt side margins, 2 pt above, 6 pt below → 48 pt strip
//
// Built like `NewGroupFooterView`: every visible thing is a layer, so the card rasterises in the
// headless bitmap tests, with transparent `NSButton`s on top purely for hit-testing, tooltips,
// the pointing-hand cursor and accessibility — one per clickable run on the second line, plus the
// `✕`. The links read as links: accent-coloured, a pointing hand over them, and the one under the
// pointer underlined (a tracking area on the card; tests set the hovered run directly). The view
// is a pure function of `UpdateNoticeModel`, the theme and the hovered run; what a click *does*
// is the owner's (`onAction` / `onDismiss`).
//
// Tokens rather than the artboard's literals: the tile is the WT badge pair (`wtBackground` /
// `wtText` — the design's `rgba(139,147,248,.18)` / `#c3c8fd` *are* those tokens), the fill and
// the border are `accent` at low alpha, links are `accent`, and the rest is the sidebar's text
// tokens, so the card reads on all five presets including 1b Light.

import AppKit
import TkzCore

public final class UpdateNoticeView: NSView {
    public static let height: Double = SidebarMetrics.updateNoticeHeight

    static let sideMargin: CGFloat = 10
    static let topMargin: CGFloat = 2
    static let bottomMargin: CGFloat = 6
    static let cardHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 9
    static let padding: CGFloat = 9
    static let tileSide: CGFloat = 22
    static let tileRadius: CGFloat = 6
    static let tileGap: CGFloat = 8
    static let closeSide: CGFloat = 20
    static let separator = " \u{00B7} "   // " · "

    // 12 / 11 rather than the artboard's 11 / 10: read next to the session rows they were too
    // small (2026-09-11). The two lines still stack inside the 40 pt card with room to spare.
    private let titleFont = Theme.Fonts.ui(12, weight: .semibold)
    private let lineFont = Theme.Fonts.ui(Theme.Fonts.ui.body)
    private let glyphFont = Theme.Fonts.ui(12, weight: .semibold)
    private let closeFont = Theme.Fonts.ui(11)

    private let cardLayer = SidebarLayers.fill(cornerRadius: UpdateNoticeView.cornerRadius)
    private let tileLayer = SidebarLayers.fill(cornerRadius: UpdateNoticeView.tileRadius)
    private lazy var glyphLayer = SidebarLayers.text(glyphFont, color: NSColor.clear.cgColor, alignment: .center)
    private lazy var titleLayer = SidebarLayers.text(titleFont, color: NSColor.clear.cgColor)
    private lazy var closeLayer = SidebarLayers.text(closeFont, color: NSColor.clear.cgColor, alignment: .center)
    private var runLayers: [CATextLayer] = []
    private var runButtons: [NSButton] = []
    private var trackingArea: NSTrackingArea?

    /// The transparent hit target over the `✕`.
    public let closeButton: NSButton = LinkHitButton(frame: .zero)

    public var onAction: (@MainActor (UpdateAction) -> Void)?
    public var onDismiss: (@MainActor () -> Void)?

    private var model = UpdateNoticeModel(title: "", runs: [], showsClose: true)
    private var theme: Theme = .default

    /// Index into `model.runs` of the link under the pointer, underlined. `nil` when the pointer
    /// is elsewhere — and always at first, so the headless renders are the resting state.
    public private(set) var hoveredRun: Int? {
        didSet {
            guard hoveredRun != oldValue else { return }
            applyRunStrings()
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        cardLayer.borderWidth = 1
        cardLayer.actions?["borderColor"] = NSNull()
        layer?.addSublayer(cardLayer)
        layer?.addSublayer(tileLayer)
        layer?.addSublayer(glyphLayer)
        layer?.addSublayer(titleLayer)
        layer?.addSublayer(closeLayer)

        Self.configureHitTarget(closeButton, tooltip: "Not for this version", label: "Dismiss update notice")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    public override var isFlipped: Bool { false }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    public static let glyph = "\u{2193}"   // ↓
    public static let closeGlyph = "\u{2715}"   // ✕

    public func configure(_ model: UpdateNoticeModel, theme: Theme) {
        self.model = model
        self.theme = theme
        // The runs are re-worded (a phase change); the index under the pointer means nothing now.
        hoveredRun = nil
        apply()
        needsLayout = true
    }

    public func configure(theme: Theme) {
        self.theme = theme
        apply()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setContentsScale(window?.backingScaleFactor ?? 2)
    }

    public func setContentsScale(_ scale: CGFloat) {
        if let layer { SidebarLayers.applyContentsScale(scale, to: layer) }
    }

    // MARK: Clicks

    @objc private func closeClicked() { onDismiss?() }

    @objc private func runClicked(_ sender: NSButton) {
        guard model.runs.indices.contains(sender.tag), let action = model.runs[sender.tag].action else { return }
        onAction?(action)
    }

    private static func configureHitTarget(_ button: NSButton, tooltip: String, label: String) {
        button.isBordered = false
        button.isTransparent = true
        button.title = ""
        button.setButtonType(.momentaryChange)
        button.toolTip = tooltip
        button.setAccessibilityLabel(label)
    }

    /// A transparent hit target that also owns the pointing-hand cursor for its bounds. Cursor
    /// rects live on the view that is hit, so they go on the button rather than on the card
    /// beneath it (the pattern `StatusBarView.resetCursorRects` uses for its badges).
    final class LinkHitButton: NSButton {
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    // MARK: Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        hoveredRun = run(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseEntered(with event: NSEvent) {
        hoveredRun = run(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) { hoveredRun = nil }

    /// Tests have no pointer; they set the hovered run directly.
    public func setHoveredRun(_ index: Int?) { hoveredRun = index }

    /// The run whose hit button contains `point`, in the view's coordinates.
    private func run(at point: NSPoint) -> Int? {
        runButtons.first { !$0.isHidden && $0.frame.contains(point) }?.tag
    }

    // MARK: Model → layers

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let accent = theme.accent
        cardLayer.backgroundColor = RGB(r: accent.r, g: accent.g, b: accent.b, a: 0.12).cgColor
        cardLayer.borderColor = RGB(r: accent.r, g: accent.g, b: accent.b, a: 0.35).cgColor
        tileLayer.backgroundColor = theme.wtBackground.cgColor
        glyphLayer.string = Self.glyph
        glyphLayer.foregroundColor = theme.wtText.cgColor
        titleLayer.string = model.title
        titleLayer.foregroundColor = theme.foreground.cgColor
        closeLayer.string = Self.closeGlyph
        closeLayer.foregroundColor = theme.foregroundDim.cgColor
        closeLayer.isHidden = !model.showsClose
        closeButton.isHidden = !model.showsClose

        // One text layer per run plus one per separator, one button per *clickable* run.
        for layer in runLayers { layer.removeFromSuperlayer() }
        for button in runButtons { button.removeFromSuperview() }
        runLayers = []
        runButtons = []
        for (index, run) in model.runs.enumerated() {
            if index > 0 {
                let sep = SidebarLayers.text(lineFont, color: theme.foregroundDim.cgColor)
                sep.string = Self.separator
                layer?.addSublayer(sep)
                runLayers.append(sep)
            }
            let color = run.action == nil ? theme.foregroundMuted : accent
            let text = SidebarLayers.text(lineFont, color: color.cgColor)
            layer?.addSublayer(text)
            runLayers.append(text)
            if run.action != nil {
                let button = LinkHitButton(frame: .zero)
                Self.configureHitTarget(button, tooltip: run.text, label: run.text)
                button.tag = index
                button.target = self
                button.action = #selector(runClicked(_:))
                addSubview(button)
                runButtons.append(button)
            }
        }
        applyRunStrings()
    }

    /// The run texts: plain strings, except the hovered link, which carries an underline. A
    /// `CATextLayer` ignores its own `font` / `foregroundColor` for an attributed string, so the
    /// hovered one restates both in its attributes.
    private func applyRunStrings() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var layerIndex = 0
        for (index, run) in model.runs.enumerated() {
            if index > 0 { layerIndex += 1 }   // the separator before this run
            guard runLayers.indices.contains(layerIndex) else { break }
            let layer = runLayers[layerIndex]
            if index == hoveredRun, run.action != nil {
                layer.string = NSAttributedString(string: run.text, attributes: [
                    .font: lineFont,
                    .foregroundColor: theme.accent.nsColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ])
            } else {
                layer.string = run.text
            }
            layerIndex += 1
        }
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let card = NSRect(
            x: Self.sideMargin, y: Self.bottomMargin,
            width: max(0, bounds.width - Self.sideMargin * 2), height: Self.cardHeight)
        cardLayer.frame = card

        let tile = NSRect(
            x: card.minX + Self.padding, y: card.midY - Self.tileSide / 2,
            width: Self.tileSide, height: Self.tileSide)
        tileLayer.frame = tile
        glyphLayer.frame = SidebarLayers.centredLine(x: tile.minX, width: tile.width, in: tile.height, font: glyphFont)
            .offsetBy(dx: 0, dy: tile.minY)

        let close = NSRect(
            x: card.maxX - Self.padding - Self.closeSide + 4, y: card.midY - Self.closeSide / 2,
            width: Self.closeSide, height: Self.closeSide)
        closeLayer.frame = SidebarLayers.centredLine(x: close.minX, width: close.width, in: close.height, font: closeFont)
            .offsetBy(dx: 0, dy: close.minY)
        closeButton.frame = close

        let textX = tile.maxX + Self.tileGap
        let textMaxX = model.showsClose ? close.minX - 4 : card.maxX - Self.padding
        let textWidth = max(0, textMaxX - textX)

        // Two lines, stacked from the card's vertical centre. Non-flipped: the title is the upper one.
        let titleHeight = (titleFont.ascender - titleFont.descender).rounded(.up)
        let lineHeight = (lineFont.ascender - lineFont.descender).rounded(.up)
        let stack = titleHeight + lineHeight
        let lineY = (card.midY - stack / 2).rounded()
        let titleY = lineY + lineHeight
        titleLayer.frame = NSRect(x: textX, y: titleY, width: textWidth, height: titleHeight)

        // Runs left to right; whatever does not fit is clipped (the last visible run truncates).
        var x = textX
        var runIndex = 0
        var buttonIndex = 0
        for (i, layer) in runLayers.enumerated() {
            // Separators sit at odd positions when there is more than one run. Widths come from
            // the model's text, not `layer.string`: the hovered run's is an attributed string.
            let isSeparator = model.runs.count > 1 && i % 2 == 1
            let text = isSeparator ? Self.separator : (model.runs.indices.contains(runIndex) ? model.runs[runIndex].text : "")
            let natural = SidebarLayers.width(of: text, font: lineFont)
            let available = max(0, textMaxX - x)
            let width = min(natural, available)
            layer.frame = NSRect(x: x, y: lineY, width: width, height: lineHeight)
            layer.isHidden = width <= 0
            if !isSeparator {
                if model.runs.indices.contains(runIndex), model.runs[runIndex].action != nil,
                    runButtons.indices.contains(buttonIndex)
                {
                    runButtons[buttonIndex].frame = NSRect(x: x, y: lineY - 3, width: width, height: lineHeight + 6)
                    runButtons[buttonIndex].isHidden = width <= 0
                    buttonIndex += 1
                }
                runIndex += 1
            }
            x += width
        }
        // The hit targets moved: their pointing-hand rects must follow (as `StatusBarView` does).
        for button in runButtons { window?.invalidateCursorRects(for: button) }
        window?.invalidateCursorRects(for: closeButton)
    }

    // MARK: Test hooks (internal)

    var titleTextLayer: CATextLayer { titleLayer }
    var runTextLayers: [CATextLayer] { runLayers }
    var runHitButtons: [NSButton] { runButtons }
    var closeButtonFrame: NSRect { closeButton.frame }
    var cardFrame: NSRect { cardLayer.frame }
    var currentModel: UpdateNoticeModel { model }
}
