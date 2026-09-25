// ChangesViewerView.swift — the view-only diff that replaces the terminal (design 2c.2).
//
//   ┌ Changes  12 files · +142 −38  [vs HEAD ▾]          [Inline|Split]  view only  esc back ┐
//   ├──────────────┬──────────────────────────────────────────────────────────────────────────┤
//   │ file  +41 −12│ src/…/  PositionAuditService.cs                                          │
//   │ file  +18 −2 │ @@ -87,9 +87,24 @@ …                                                      │
//   │ …            │  88  88   var entries = …                                                │
//   └──────────────┴──────────────────────────────────────────────────────────────────────────┘
//
// Three drawn surfaces and one strip of controls. The file list and the diff pane are each a
// flipped `NSView` inside an `NSScrollView` that draws only the rows intersecting `dirtyRect`,
// so a 10 000-line diff costs a frame, not 10 000 text fields — the same "one view, custom draw"
// call `StatusBarView` made, for the same reasons. The header uses real AppKit controls (a popup,
// a segmented control) because they *are* controls; there is nothing to gain from redrawing them.
//
// Colours are derived from the theme's existing tokens rather than adding a dozen new ones: the
// added/removed washes are `diffAdd` / `diffRemove` at the artboard's alpha, the hunk header is
// the foreground at 5 %, the selected file row is the sidebar's `selection`. Both presets work
// without either having heard of this view.

import AppKit
import GitStatus
import TkzCore

enum ChangesMetrics {
    static let headerHeight: CGFloat = 38
    static let fileListWidth: CGFloat = 264
    static let fileRowHeight: CGFloat = 28
    static let fileListInset: CGFloat = 6
    static let pathHeaderHeight: CGFloat = 32
    static let diffRowHeight: CGFloat = 20
    /// One line-number column (2c.2: 44 px, right-aligned, 8 px of air after it).
    static let numberWidth: CGFloat = 44
    static let numberGap: CGFloat = 8
    static let textInset: CGFloat = 14
    static let fontSize: Double = 11.5
    static let fileFontSize: Double = 10.5
    /// Tabs are drawn as this many spaces; a tab stop would need a paragraph style per row.
    static let tabWidth = 4
}

// MARK: - Palette

/// The theme, resolved once into the colours this view paints with.
struct ChangesPalette: Equatable {
    var background: NSColor
    var headerBackground: NSColor
    var border: NSColor
    var text: NSColor
    var textMuted: NSColor
    var textDim: NSColor
    var add: NSColor
    var remove: NSColor
    var addWash: NSColor
    var removeWash: NSColor
    var hunkWash: NSColor
    var selection: NSColor

    init(theme: Theme) {
        background = theme.terminalBackground.nsColor
        headerBackground = theme.statusBarBackground.nsColor
        border = theme.border.nsColor
        text = theme.terminalForeground.nsColor
        textMuted = theme.foregroundMuted.nsColor
        textDim = theme.foregroundDim.nsColor
        add = theme.diffAdd.nsColor
        remove = theme.diffRemove.nsColor
        addWash = Self.wash(theme.diffAdd, alpha: 0.11)
        removeWash = Self.wash(theme.diffRemove, alpha: 0.13)
        hunkWash = Self.wash(theme.foreground, alpha: 0.05)
        selection = theme.selection.nsColor
    }

    private static func wash(_ rgb: RGB, alpha: Double) -> NSColor {
        RGB(r: rgb.r, g: rgb.g, b: rgb.b, a: alpha).nsColor
    }
}

// MARK: - Text helpers

private enum DiffText {
    static func expandTabs(_ text: String) -> String {
        guard text.contains("\t") else { return text }
        return text.replacingOccurrences(
            of: "\t", with: String(repeating: " ", count: ChangesMetrics.tabWidth))
    }

    static func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    /// Draws `string` vertically centred in a row `height` tall whose top is `y` (flipped).
    static func draw(_ string: NSAttributedString, x: CGFloat, rowTop y: CGFloat, height: CGFloat, font: NSFont) {
        let lineHeight = (font.ascender - font.descender).rounded(.up)
        string.draw(at: NSPoint(x: x, y: y + ((height - lineHeight) / 2).rounded()))
    }
}

// MARK: - The file list

final class ChangedFileListView: NSView {
    var onSelect: ((String) -> Void)?
    /// The list was clicked: whoever owns the keyboard should be the viewer, not the terminal.
    var onFocusRequest: (() -> Void)?

    private(set) var files: [ChangedFile] = []
    private(set) var selectedPath: String?
    private var palette: ChangesPalette
    private let font = Theme.Fonts.mono(ChangesMetrics.fileFontSize)

    init(theme: Theme) {
        palette = ChangesPalette(theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    override var isFlipped: Bool { true }

    func configure(files: [ChangedFile], selectedPath: String?) {
        guard files != self.files || selectedPath != self.selectedPath else { return }
        self.files = files
        self.selectedPath = selectedPath
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func apply(theme: Theme) {
        palette = ChangesPalette(theme: theme)
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: CGFloat(files.count) * ChangesMetrics.fileRowHeight + 2 * ChangesMetrics.fileListInset)
    }

    /// Where row `index` is drawn.
    func rowRect(_ index: Int) -> NSRect {
        NSRect(
            x: ChangesMetrics.fileListInset,
            y: ChangesMetrics.fileListInset + CGFloat(index) * ChangesMetrics.fileRowHeight,
            width: bounds.width - 2 * ChangesMetrics.fileListInset,
            height: ChangesMetrics.fileRowHeight)
    }

    func index(at point: NSPoint) -> Int? {
        let y = point.y - ChangesMetrics.fileListInset
        guard y >= 0 else { return nil }
        let index = Int(y / ChangesMetrics.fileRowHeight)
        return index < files.count ? index : nil
    }

    /// Scrolls the selected row into view.
    func revealSelection() {
        guard let index = files.firstIndex(where: { $0.path == selectedPath }) else { return }
        scrollToVisible(rowRect(index).insetBy(dx: 0, dy: -ChangesMetrics.fileListInset))
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point) else { return }
        onSelect?(files[index].path)
    }

    override func draw(_ dirtyRect: NSRect) {
        palette.background.setFill()
        dirtyRect.fill()
        let h = ChangesMetrics.fileRowHeight
        let first = max(0, Int((dirtyRect.minY - ChangesMetrics.fileListInset) / h))
        let last = min(files.count - 1, Int((dirtyRect.maxY - ChangesMetrics.fileListInset) / h))
        guard first <= last else { return }
        for index in first...last {
            draw(files[index], in: rowRect(index), selected: files[index].path == selectedPath)
        }
    }

    private func draw(_ file: ChangedFile, in rect: NSRect, selected: Bool) {
        if selected {
            palette.selection.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        let padX: CGFloat = 8
        let gap: CGFloat = 8
        var right = rect.maxX - padX
        // Counts first, right-aligned, so the name knows how much room is left.
        let counts = Self.counts(for: file)
        for (text, color) in counts.reversed() {
            let string = DiffText.attributed(
                text, font: font, color: color == .add ? palette.add : (color == .remove ? palette.remove : palette.textDim))
            let width = string.size().width.rounded(.up)
            right -= width
            DiffText.draw(string, x: right, rowTop: rect.minY, height: rect.height, font: font)
            right -= gap
        }
        let nameColor = selected ? palette.text : palette.textMuted
        let name = DiffText.attributed(
            Self.truncated(file.name, font: font, width: right - rect.minX - padX), font: font,
            color: nameColor)
        DiffText.draw(name, x: rect.minX + padX, rowTop: rect.minY, height: rect.height, font: font)
    }

    private enum CountColor { case add, remove, dim }

    /// `+41` `−12`, or `binary` for a file with no line counts.
    private static func counts(for file: ChangedFile) -> [(String, CountColor)] {
        guard !file.isBinary else { return [("binary", .dim)] }
        return [
            ("+\(file.insertions ?? 0)", .add),
            ("\u{2212}\(file.deletions ?? 0)", .remove),
        ]
    }

    /// Head-truncates (`…AuditService.cs`): the end of a file name is the part that tells files
    /// in one directory apart.
    static func truncated(_ text: String, font: NSFont, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (text as NSString).size(withAttributes: attributes).width > width else { return text }
        var tail = Substring(text)
        while !tail.isEmpty {
            tail = tail.dropFirst()
            let candidate = "\u{2026}" + tail
            if (candidate as NSString).size(withAttributes: attributes).width <= width {
                return candidate
            }
        }
        return "\u{2026}"
    }
}

// MARK: - The diff pane

final class DiffPaneView: NSView {
    var onFocusRequest: (() -> Void)?

    private(set) var rows: [DiffRow] = []
    private(set) var mode: DiffDisplayMode = .inline
    /// The pane's text when there are no rows: `Loading…`, `No changes`, `Binary file`.
    private(set) var message: String?
    private var palette: ChangesPalette
    private let font = Theme.Fonts.mono(ChangesMetrics.fontSize)
    private let messageFont = Theme.Fonts.ui(Theme.Fonts.ui.body)
    /// Width of one glyph of the mono font: every character advances the same, so the content
    /// width is a multiplication rather than a measurement per row.
    private let charWidth: CGFloat
    /// Longest text on any row, in characters, for the horizontal extent in inline mode.
    private var maxChars = 0
    /// What the enclosing clip view can show; the frame is never narrower than this.
    var visibleWidth: CGFloat = 0 {
        didSet { if visibleWidth != oldValue { updateFrameSize() } }
    }

    init(theme: Theme) {
        palette = ChangesPalette(theme: theme)
        charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    override var isFlipped: Bool { true }

    func configure(rows: [DiffRow], mode: DiffDisplayMode, message: String?) {
        guard rows != self.rows || mode != self.mode || message != self.message else { return }
        self.rows = rows
        self.mode = mode
        self.message = message
        maxChars = rows.reduce(0) { longest, row in
            switch row {
            case .hunk(let header): max(longest, header.count)
            case .line(let line): max(longest, DiffText.expandTabs(line.text).count)
            case .pair(let left, let right):
                max(longest, DiffText.expandTabs(left?.text ?? "").count, DiffText.expandTabs(right?.text ?? "").count)
            }
        }
        updateFrameSize()
        needsDisplay = true
    }

    func apply(theme: Theme) {
        palette = ChangesPalette(theme: theme)
        needsDisplay = true
    }

    /// Inline rows extend as far as the longest line so the scroll view can pan; split rows fit
    /// the visible width and clip, because two halves that scroll together are not worth the
    /// geometry.
    var contentWidth: CGFloat {
        switch mode {
        case .inline:
            2 * ChangesMetrics.numberWidth + 2 * ChangesMetrics.numberGap + ChangesMetrics.textInset
                + CGFloat(maxChars) * charWidth + ChangesMetrics.textInset
        case .split:
            0
        }
    }

    var contentHeight: CGFloat {
        max(CGFloat(rows.count) * ChangesMetrics.diffRowHeight, message == nil ? 0 : 60)
    }

    private func updateFrameSize() {
        let size = NSSize(width: max(visibleWidth, contentWidth), height: contentHeight)
        if size != frame.size { setFrameSize(size) }
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        palette.background.setFill()
        dirtyRect.fill()

        if rows.isEmpty {
            if let message {
                let string = DiffText.attributed(message, font: messageFont, color: palette.textDim)
                string.draw(at: NSPoint(x: ChangesMetrics.textInset, y: 20))
            }
            return
        }
        let h = ChangesMetrics.diffRowHeight
        let first = max(0, Int(dirtyRect.minY / h))
        let last = min(rows.count - 1, Int(dirtyRect.maxY / h))
        guard first <= last else { return }
        for index in first...last {
            let rect = NSRect(x: 0, y: CGFloat(index) * h, width: bounds.width, height: h)
            switch rows[index] {
            case .hunk(let header): drawHunk(header, in: rect)
            case .line(let line): drawInline(line, in: rect)
            case .pair(let left, let right): drawPair(left, right, in: rect)
            }
        }
    }

    private func drawHunk(_ header: String, in rect: NSRect) {
        palette.hunkWash.setFill()
        rect.fill()
        let x = mode == .inline
            ? 2 * ChangesMetrics.numberWidth + 2 * ChangesMetrics.numberGap + ChangesMetrics.textInset
            : ChangesMetrics.textInset
        DiffText.draw(
            DiffText.attributed(header, font: font, color: palette.textDim),
            x: x, rowTop: rect.minY, height: rect.height, font: font)
    }

    private func wash(for kind: DiffLineKind) -> NSColor? {
        switch kind {
        case .added: palette.addWash
        case .removed: palette.removeWash
        case .context, .noNewline: nil
        }
    }

    private func textColor(for kind: DiffLineKind) -> NSColor {
        switch kind {
        case .added: palette.text.blended(withFraction: 0.35, of: palette.add) ?? palette.text
        case .removed: palette.text.blended(withFraction: 0.35, of: palette.remove) ?? palette.text
        case .context: palette.text
        case .noNewline: palette.textDim
        }
    }

    private func numberColor(for kind: DiffLineKind) -> NSColor {
        switch kind {
        case .added: palette.textDim.blended(withFraction: 0.5, of: palette.add) ?? palette.textDim
        case .removed: palette.textDim.blended(withFraction: 0.5, of: palette.remove) ?? palette.textDim
        case .context, .noNewline: palette.textDim
        }
    }

    private func drawNumber(_ number: Int?, kind: DiffLineKind, rightEdge: CGFloat, rowTop: CGFloat) {
        guard let number else { return }
        let string = DiffText.attributed("\(number)", font: font, color: numberColor(for: kind))
        DiffText.draw(
            string, x: rightEdge - string.size().width, rowTop: rowTop,
            height: ChangesMetrics.diffRowHeight, font: font)
    }

    private func drawInline(_ line: DiffLine, in rect: NSRect) {
        if let wash = wash(for: line.kind) {
            wash.setFill()
            rect.fill()
        }
        drawNumber(line.oldNumber, kind: line.kind, rightEdge: ChangesMetrics.numberWidth, rowTop: rect.minY)
        drawNumber(
            line.newNumber, kind: line.kind,
            rightEdge: 2 * ChangesMetrics.numberWidth + ChangesMetrics.numberGap, rowTop: rect.minY)
        let x = 2 * ChangesMetrics.numberWidth + 2 * ChangesMetrics.numberGap + ChangesMetrics.textInset
        DiffText.draw(
            DiffText.attributed(Self.marked(line), font: font, color: textColor(for: line.kind)),
            x: x, rowTop: rect.minY, height: rect.height, font: font)
    }

    /// `+ text` / `− text` / `  text`: the marker is part of the row, as on the artboard.
    static func marked(_ line: DiffLine) -> String {
        let text = DiffText.expandTabs(line.text)
        switch line.kind {
        case .added: return "+ " + text
        case .removed: return "\u{2212} " + text
        case .context: return "  " + text
        case .noNewline: return "\\ " + text
        }
    }

    private func drawPair(_ left: DiffLine?, _ right: DiffLine?, in rect: NSRect) {
        let half = (rect.width / 2).rounded(.down)
        drawHalf(left, in: NSRect(x: 0, y: rect.minY, width: half, height: rect.height), side: .left)
        // The 1 pt seam between the halves, in the border colour.
        palette.border.setFill()
        NSRect(x: half, y: rect.minY, width: 1, height: rect.height).fill()
        drawHalf(right, in: NSRect(x: half + 1, y: rect.minY, width: rect.width - half - 1, height: rect.height), side: .right)
    }

    private enum Side { case left, right }

    private func drawHalf(_ line: DiffLine?, in rect: NSRect, side: Side) {
        guard let line else { return }
        if let wash = wash(for: line.kind) {
            wash.setFill()
            rect.fill()
        }
        let number = side == .left ? line.oldNumber : line.newNumber
        drawNumber(number, kind: line.kind, rightEdge: rect.minX + ChangesMetrics.numberWidth, rowTop: rect.minY)
        let x = rect.minX + ChangesMetrics.numberWidth + ChangesMetrics.numberGap + 6
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        DiffText.draw(
            DiffText.attributed(Self.marked(line), font: font, color: textColor(for: line.kind)),
            x: x, rowTop: rect.minY, height: rect.height, font: font)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - The header bar

final class ChangesHeaderBar: NSView {
    var onBaseChanged: ((DiffBase) -> Void)?
    var onModeChanged: ((DiffDisplayMode) -> Void)?
    /// The `✕` was clicked. The viewer is opened by a click as often as by the chord, so it has
    /// a click to close it too, not only Esc.
    var onClose: (() -> Void)?

    private let title = NSTextField(labelWithString: "Changes")
    private let counts = NSTextField(labelWithString: "")
    private let basePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modeControl = NSSegmentedControl(
        labels: DiffDisplayMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let viewOnly = NSTextField(labelWithString: "view only")
    private let escHint = NSTextField(labelWithString: "esc  back to terminal")
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let bottomBorder = NSView()
    private var bases: [DiffBase] = [.head]
    private var palette: ChangesPalette

    init(theme: Theme) {
        palette = ChangesPalette(theme: theme)
        super.init(frame: .zero)
        wantsLayer = true

        title.font = Theme.Fonts.ui(12, weight: .semibold)
        counts.font = Theme.Fonts.ui(Theme.Fonts.ui.body)
        viewOnly.font = Theme.Fonts.ui(Theme.Fonts.ui.caption)
        escHint.font = Theme.Fonts.ui(Theme.Fonts.ui.caption)
        viewOnly.wantsLayer = true
        viewOnly.layer?.cornerRadius = 4
        viewOnly.alignment = .center

        basePopup.controlSize = .small
        basePopup.font = Theme.Fonts.ui(Theme.Fonts.ui.body)
        basePopup.target = self
        basePopup.action = #selector(baseChanged(_:))
        modeControl.controlSize = .small
        modeControl.font = Theme.Fonts.ui(Theme.Fonts.ui.body)
        modeControl.segmentStyle = .rounded
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))

        bottomBorder.wantsLayer = true

        // The same shape as the first-prompt card's `esc ✕`: borderless, momentary, a glyph.
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.setButtonType(.momentaryChange)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Back to terminal (esc)"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let leading = NSStackView(views: [title, counts, basePopup])
        leading.orientation = .horizontal
        leading.spacing = 12
        leading.alignment = .centerY
        let trailing = NSStackView(views: [modeControl, viewOnly, escHint, closeButton])
        trailing.orientation = .horizontal
        trailing.spacing = 12
        trailing.alignment = .centerY

        for view in [leading, trailing, bottomBorder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12),
            viewOnly.widthAnchor.constraint(equalToConstant: 62),
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),
        ])
        // The hints yield first when the window is narrow; the counts and the base menu are data.
        escHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        viewOnly.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    func configure(countsText: String, bases: [DiffBase], base: DiffBase, mode: DiffDisplayMode) {
        counts.attributedStringValue = Self.attributedCounts(countsText, palette: palette, font: counts.font!)
        if bases != self.bases || basePopup.numberOfItems != bases.count {
            self.bases = bases
            basePopup.removeAllItems()
            basePopup.addItems(withTitles: bases.map(\.label))
        }
        if let index = bases.firstIndex(of: base), basePopup.indexOfSelectedItem != index {
            basePopup.selectItem(at: index)
        }
        basePopup.isEnabled = bases.count > 1
        let modeIndex = DiffDisplayMode.allCases.firstIndex(of: mode) ?? 0
        if modeControl.selectedSegment != modeIndex { modeControl.selectedSegment = modeIndex }
    }

    /// `12 files · ` in the muted text, `+142` in the add green, `−38` in the remove red.
    static func attributedCounts(_ text: String, palette: ChangesPalette, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text.isEmpty ? "Loading\u{2026}" : text, attributes: [
            .font: font, .foregroundColor: palette.textDim,
        ])
        let string = out.string as NSString
        let plus = string.range(of: "+")
        let minus = string.range(of: "\u{2212}")
        if plus.location != NSNotFound, minus.location != NSNotFound, minus.location > plus.location {
            out.addAttribute(.foregroundColor, value: palette.add, range: NSRange(location: plus.location, length: minus.location - plus.location - 1))
            out.addAttribute(.foregroundColor, value: palette.remove, range: NSRange(location: minus.location, length: string.length - minus.location))
        }
        return out
    }

    func apply(theme: Theme) {
        palette = ChangesPalette(theme: theme)
        layer?.backgroundColor = palette.headerBackground.cgColor
        bottomBorder.layer?.backgroundColor = palette.border.cgColor
        title.textColor = theme.foreground.nsColor
        viewOnly.textColor = palette.textDim
        viewOnly.layer?.backgroundColor = palette.hunkWash.cgColor
        escHint.textColor = palette.textDim
        closeButton.attributedTitle = NSAttributedString(string: "\u{2715}", attributes: [
            .font: Theme.Fonts.ui(13, weight: .medium), .foregroundColor: palette.textMuted,
        ])
        counts.attributedStringValue = Self.attributedCounts(counts.stringValue, palette: palette, font: counts.font!)
    }

    @objc private func closeTapped() { onClose?() }

    @objc private func baseChanged(_ sender: Any?) {
        let index = basePopup.indexOfSelectedItem
        guard bases.indices.contains(index) else { return }
        onBaseChanged?(bases[index])
    }

    @objc private func modeChanged(_ sender: Any?) {
        let index = modeControl.selectedSegment
        guard DiffDisplayMode.allCases.indices.contains(index) else { return }
        onModeChanged?(DiffDisplayMode.allCases[index])
    }

    // MARK: Test hooks

    var countsForTesting: String { counts.stringValue }
    var basePopupForTesting: NSPopUpButton { basePopup }
    var modeControlForTesting: NSSegmentedControl { modeControl }
    var closeButtonForTesting: NSButton { closeButton }
}

// MARK: - The viewer

/// The whole 2c.2 surface. Owns the keyboard while shown: Esc goes back to the terminal, ↑/↓
/// walk the file list, Page Up/Down and Home/End scroll the diff.
final class ChangesViewerView: NSView {
    var onEscape: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onSelectPath: ((String) -> Void)?
    var onBaseChanged: ((DiffBase) -> Void)?
    var onModeChanged: ((DiffDisplayMode) -> Void)?

    let header: ChangesHeaderBar
    let fileList: ChangedFileListView
    let diffPane: DiffPaneView
    private let fileScroll = NSScrollView()
    private let diffScroll = NSScrollView()
    private let pathHeader = NSTextField(labelWithString: "")
    private let pathBorder = NSView()
    private let columnBorder = NSView()
    private var palette: ChangesPalette
    private var theme: Theme
    /// The file the path header names, kept so a theme change can redraw it in the new colours.
    private var shownFile: ChangedFile?

    init(theme: Theme) {
        self.theme = theme
        palette = ChangesPalette(theme: theme)
        header = ChangesHeaderBar(theme: theme)
        fileList = ChangedFileListView(theme: theme)
        diffPane = DiffPaneView(theme: theme)
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        wantsLayer = true

        for scroll in [fileScroll, diffScroll] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.borderType = .noBorder
        }
        fileScroll.documentView = fileList
        diffScroll.hasHorizontalScroller = true
        diffScroll.documentView = diffPane
        diffScroll.contentView.postsBoundsChangedNotifications = true

        pathHeader.font = Theme.Fonts.mono(Theme.Fonts.mono.detail)
        pathHeader.lineBreakMode = .byTruncatingHead
        pathHeader.maximumNumberOfLines = 1
        pathBorder.wantsLayer = true
        columnBorder.wantsLayer = true

        for view in [header, fileScroll, columnBorder, pathHeader, pathBorder, diffScroll] {
            addSubview(view)
        }

        header.onBaseChanged = { [weak self] base in self?.onBaseChanged?(base) }
        header.onModeChanged = { [weak self] mode in self?.onModeChanged?(mode) }
        header.onClose = { [weak self] in self?.onEscape?() }
        fileList.onSelect = { [weak self] path in self?.onSelectPath?(path) }
        fileList.onFocusRequest = { [weak self] in self?.takeKeyboard() }
        diffPane.onFocusRequest = { [weak self] in self?.takeKeyboard() }
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func takeKeyboard() {
        window?.makeFirstResponder(self)
    }

    func configure(_ model: ChangesViewerModel) {
        header.configure(countsText: model.countsText, bases: model.bases, base: model.base, mode: model.mode)
        fileList.configure(files: model.files, selectedPath: model.selectedPath)
        fileList.revealSelection()
        shownFile = model.selectedFile
        pathHeader.attributedStringValue = Self.pathTitle(for: shownFile, palette: palette, font: pathHeader.font!)
        diffPane.configure(
            rows: model.diff.map { DiffRowBuilder.rows(for: $0, mode: model.mode) } ?? [],
            mode: model.mode,
            message: Self.message(for: model))
        needsLayout = true
    }

    /// The pane's caption when it has no rows to draw.
    static func message(for model: ChangesViewerModel) -> String? {
        if model.failed { return "git could not read this repository" }
        guard model.summary != nil else { return "Loading\u{2026}" }
        guard let file = model.selectedFile else { return "No changes" }
        guard let diff = model.diff else { return "Loading\u{2026}" }
        if diff.isBinary || file.isBinary { return "Binary file" }
        if diff.hunks.isEmpty {
            return file.isUntracked ? "Empty file" : "No changes"
        }
        return nil
    }

    /// `src/CoreInvest.Api/Services/` dimmed, then `PositionAuditService.cs` in the foreground.
    static func pathTitle(for file: ChangedFile?, palette: ChangesPalette, font: NSFont) -> NSAttributedString {
        guard let file else { return NSAttributedString(string: "") }
        let out = NSMutableAttributedString()
        if let old = file.oldPath {
            out.append(NSAttributedString(string: old + " \u{2192} ", attributes: [.font: font, .foregroundColor: palette.textDim]))
        }
        out.append(NSAttributedString(string: file.directory, attributes: [.font: font, .foregroundColor: palette.textDim]))
        out.append(NSAttributedString(string: file.name, attributes: [
            .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), .foregroundColor: palette.text,
        ]))
        return out
    }

    func apply(theme: Theme) {
        self.theme = theme
        palette = ChangesPalette(theme: theme)
        layer?.backgroundColor = palette.background.cgColor
        header.apply(theme: theme)
        fileList.apply(theme: theme)
        diffPane.apply(theme: theme)
        pathBorder.layer?.backgroundColor = palette.border.cgColor
        columnBorder.layer?.backgroundColor = palette.border.cgColor
        pathHeader.attributedStringValue = Self.pathTitle(for: shownFile, palette: palette, font: pathHeader.font!)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let headerH = ChangesMetrics.headerHeight
        let listW = min(ChangesMetrics.fileListWidth, (w / 2).rounded(.down))
        header.frame = NSRect(x: 0, y: 0, width: w, height: headerH)
        fileScroll.frame = NSRect(x: 0, y: headerH, width: listW, height: max(0, h - headerH))
        columnBorder.frame = NSRect(x: listW, y: headerH, width: 1, height: max(0, h - headerH))
        let rightX = listW + 1
        let rightW = max(0, w - rightX)
        let pathH = ChangesMetrics.pathHeaderHeight
        pathHeader.frame = NSRect(x: rightX + 14, y: headerH, width: max(0, rightW - 28), height: pathH)
            .insetBy(dx: 0, dy: ((pathH - pathHeader.intrinsicContentSize.height) / 2).rounded())
        pathBorder.frame = NSRect(x: rightX, y: headerH + pathH - 1, width: rightW, height: 1)
        diffScroll.frame = NSRect(x: rightX, y: headerH + pathH, width: rightW, height: max(0, h - headerH - pathH))
        fileList.frame.size.width = fileScroll.contentSize.width
        fileList.frame.size.height = max(fileList.intrinsicContentSize.height, fileScroll.contentSize.height)
        diffPane.visibleWidth = diffScroll.contentSize.width
    }

    // MARK: Keyboard

    /// What a key does while the viewer has the keyboard. By key code rather than through
    /// `interpretKeyEvents` — the bindings are fixed, and a table is what a test can drive.
    enum Key: Equatable {
        case escape, selectPrevious, selectNext, pageUp, pageDown, top, bottom

        init?(keyCode: UInt16) {
            switch keyCode {
            case 53: self = .escape
            case 126: self = .selectPrevious
            case 125: self = .selectNext
            case 116: self = .pageUp
            case 121: self = .pageDown
            case 115: self = .top
            case 119: self = .bottom
            default: return nil
            }
        }
    }

    /// Anything not in the table (a letter, a space, ↵) is swallowed: "view only" means nothing
    /// reaches the terminal underneath, and there is nothing here to type into.
    override func keyDown(with event: NSEvent) {
        guard let key = Key(keyCode: event.keyCode) else { return }
        perform(key)
    }

    func perform(_ key: Key) {
        switch key {
        case .escape: onEscape?()
        case .selectPrevious: onMoveSelection?(-1)
        case .selectNext: onMoveSelection?(1)
        case .pageDown: scrollDiff(by: diffScroll.contentSize.height * 0.9)
        case .pageUp: scrollDiff(by: -diffScroll.contentSize.height * 0.9)
        case .top: scrollDiff(to: 0)
        case .bottom: scrollDiff(to: diffPane.frame.height)
        }
    }

    /// Esc arriving as `cancelOperation:` (through the responder chain) closes the viewer too.
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    private func scrollDiff(by delta: CGFloat) {
        scrollDiff(to: diffScroll.contentView.bounds.minY + delta)
    }

    private func scrollDiff(to y: CGFloat) {
        let maxY = max(0, diffPane.frame.height - diffScroll.contentSize.height)
        let clamped = min(max(0, y), maxY)
        diffScroll.contentView.scroll(to: NSPoint(x: diffScroll.contentView.bounds.minX, y: clamped))
        diffScroll.reflectScrolledClipView(diffScroll.contentView)
    }

    /// Back to the top when the file (or the base) changes — the previous file's scroll offset
    /// means nothing for the next one.
    func resetDiffScroll() {
        scrollDiff(to: 0)
    }

    // MARK: Test hooks

    var pathHeaderForTesting: NSTextField { pathHeader }
}
