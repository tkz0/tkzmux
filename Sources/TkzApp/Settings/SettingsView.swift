// SettingsView.swift — the Settings window's contents (design 7a–d).
//
// A 176 pt nav column on the left, and on the right a scrolling column of sections: an uppercase
// caption over a bordered card, each card a stack of rows, each row a title, a sentence and one
// control on the trailing edge. Pure layout: `render(_:page:)` is the whole input. The row views
// are built once per page and then **updated in place** — `ChangeSet.chrome` fires on every
// update-check tick and on every sidebar drag, and rebuilding a switch under the pointer would
// drop its focus ring mid-click.

import AppKit
import TkzCore

@MainActor
final class SettingsView: NSView {

    enum Metrics {
        static let width: CGFloat = 720
        static let height: CGFloat = 600
        static let navWidth: CGFloat = 176
        static let navRowHeight: CGFloat = 28
        static let navInset: CGFloat = 10
        static let cardRadius: CGFloat = 9
        static let contentTop: CGFloat = 20
        static let contentSide: CGFloat = 22
        static let sectionSpacing: CGFloat = 20
        static let rowPaddingV: CGFloat = 12
        static let rowPaddingH: CGFloat = 14
        static let controlGap: CGFloat = 16
    }

    var onSelectPage: ((SettingsPage) -> Void)?
    var onToggle: ((SettingsRow.ID, Bool) -> Void)?
    var onButton: ((SettingsRow.ID) -> Void)?
    var onPopup: ((SettingsRow.ID, Int) -> Void)?

    private(set) var page: SettingsPage = .general
    private(set) var model: SettingsModel?
    private var theme: Theme

    private let navColumn = NSView()
    private let navBorder = NSView()
    private let navStack = NSStackView()
    private var navRows: [SettingsPage: NavRowView] = [:]
    private let shortcutLabel = NSTextField(labelWithString: "\u{2318},")
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private let contentStack = NSStackView()
    private var sectionViews: [SectionView] = []
    private var rowViews: [SettingsRow.ID: RowView] = [:]
    private var renderedPage: SettingsPage?
    private var renderedIDs: [SettingsRow.ID] = []

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    // MARK: Input

    func render(_ model: SettingsModel, page: SettingsPage) {
        self.model = model
        self.page = page
        // A page the model does not carry is hidden rather than shown empty — `SettingsPage`
        // `allCases` is the draw *order*, the model decides membership (see its own doc comment).
        // The rows are built once and hidden, not rebuilt, so the nav column never reflows.
        for (navPage, row) in navRows {
            row.isHidden = model.pages[navPage] == nil
            row.isSelected = navPage == page
        }
        let sections = model.sections(for: page)
        let ids = sections.flatMap { $0.rows.map(\.id) }
        if renderedPage != page || ids != renderedIDs {
            rebuildContent(sections)
            renderedPage = page
            renderedIDs = ids
        } else {
            for section in sections {
                for row in section.rows { rowViews[row.id]?.update(row) }
            }
        }
    }

    func setTheme(_ theme: Theme) {
        guard theme != self.theme else { return }
        self.theme = theme
        applyTheme()
    }

    // MARK: Layout

    private func build() {
        navColumn.translatesAutoresizingMaskIntoConstraints = false
        navColumn.wantsLayer = true
        addSubview(navColumn)

        navBorder.translatesAutoresizingMaskIntoConstraints = false
        navBorder.wantsLayer = true
        addSubview(navBorder)

        navStack.translatesAutoresizingMaskIntoConstraints = false
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 2
        navColumn.addSubview(navStack)
        for page in SettingsPage.allCases {
            let row = NavRowView(page: page, theme: theme)
            row.onSelect = { [weak self] in self?.onSelectPage?(page) }
            navRows[page] = row
            navStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: navStack.widthAnchor).isActive = true
        }

        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
        addSubview(scrollView)

        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Metrics.sectionSpacing
        document.addSubview(contentStack)

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            navColumn.leadingAnchor.constraint(equalTo: leadingAnchor),
            navColumn.topAnchor.constraint(equalTo: topAnchor),
            navColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
            navColumn.widthAnchor.constraint(equalToConstant: Metrics.navWidth),

            navBorder.leadingAnchor.constraint(equalTo: navColumn.trailingAnchor),
            navBorder.topAnchor.constraint(equalTo: topAnchor),
            navBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            navBorder.widthAnchor.constraint(equalToConstant: 1),

            // Under the title bar: the window is `fullSizeContentView`, and the traffic lights
            // sit in the nav column's top-left.
            navStack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            navStack.leadingAnchor.constraint(equalTo: navColumn.leadingAnchor, constant: Metrics.navInset),
            navStack.trailingAnchor.constraint(equalTo: navColumn.trailingAnchor, constant: -Metrics.navInset),

            shortcutLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            scrollView.leadingAnchor.constraint(equalTo: navBorder.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),

            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: Metrics.contentTop),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Metrics.contentSide),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Metrics.contentSide),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Metrics.contentTop),
        ])
    }

    private func rebuildContent(_ sections: [SettingsSection]) {
        for view in sectionViews { view.removeFromSuperview() }
        sectionViews = []
        rowViews = [:]
        for section in sections {
            let view = SectionView(section: section, theme: theme)
            view.onToggle = { [weak self] id, isOn in self?.onToggle?(id, isOn) }
            view.onButton = { [weak self] id in self?.onButton?(id) }
            view.onPopup = { [weak self] id, index in self?.onPopup?(id, index) }
            sectionViews.append(view)
            contentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            for (id, row) in view.rowViews { rowViews[id] = row }
        }
    }

    private func applyTheme() {
        layer?.backgroundColor = theme.windowBackground.cgColor
        navColumn.layer?.backgroundColor = theme.sidebarBackground.cgColor
        navBorder.layer?.backgroundColor = theme.border.cgColor
        shortcutLabel.font = Theme.Fonts.mono(10)
        shortcutLabel.textColor = theme.foregroundDim.nsColor
        for row in navRows.values { row.setTheme(theme) }
        for section in sectionViews { section.setTheme(theme) }
    }

    // MARK: Test access

    var navRowsForTesting: [SettingsPage: NavRowView] { navRows }
    var captionsForTesting: [String] { sectionViews.map(\.captionForTesting) }
    func rowViewForTesting(_ id: SettingsRow.ID) -> RowView? { rowViews[id] }
    func controlForTesting(_ id: SettingsRow.ID) -> NSView? { rowViews[id]?.control }
}

// MARK: - Nav row

@MainActor
final class NavRowView: NSView {
    let page: SettingsPage
    var onSelect: (() -> Void)?
    var isSelected = false {
        didSet { if isSelected != oldValue { applyTheme() } }
    }

    private var theme: Theme
    private let glyph = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")

    init(page: SettingsPage, theme: Theme) {
        self.page = page
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        glyph.stringValue = page.glyph
        title.stringValue = page.title
        for label in [glyph, title] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = label === glyph ? .center : .left
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsView.Metrics.navRowHeight),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(page.title)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    func setTheme(_ theme: Theme) {
        self.theme = theme
        applyTheme()
    }

    private func applyTheme() {
        title.font = Theme.Fonts.ui(12.5, weight: isSelected ? .medium : .regular)
        glyph.font = Theme.Fonts.ui(12)
        title.textColor = (isSelected ? theme.foreground : theme.foregroundMuted).nsColor
        glyph.textColor = (isSelected ? theme.accent : theme.foregroundDim).nsColor
        layer?.backgroundColor = isSelected ? theme.selection.cgColor : nil
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    var titleForTesting: String { title.stringValue }
}

// MARK: - Section

@MainActor
final class SectionView: NSView {
    var onToggle: ((SettingsRow.ID, Bool) -> Void)?
    var onButton: ((SettingsRow.ID) -> Void)?
    var onPopup: ((SettingsRow.ID, Int) -> Void)?

    private(set) var rowViews: [SettingsRow.ID: RowView] = [:]
    private var theme: Theme
    private let caption = NSTextField(labelWithString: "")
    private let card = NSView()
    private let stack = NSStackView()
    private var separators: [NSView] = []
    private let captionText: String

    init(section: SettingsSection, theme: Theme) {
        self.theme = theme
        self.captionText = section.caption
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = SettingsView.Metrics.cardRadius
        card.layer?.borderWidth = 1
        card.layer?.masksToBounds = true
        addSubview(card)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        card.addSubview(stack)

        for (index, row) in section.rows.enumerated() {
            if index > 0 {
                let line = NSView()
                line.translatesAutoresizingMaskIntoConstraints = false
                line.wantsLayer = true
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                separators.append(line)
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let view = RowView(row: row, theme: theme)
            view.onToggle = { [weak self] isOn in self?.onToggle?(row.id, isOn) }
            view.onButton = { [weak self] in self?.onButton?(row.id) }
            view.onPopup = { [weak self] index in self?.onPopup?(row.id, index) }
            rowViews[row.id] = view
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: topAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            card.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 7),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    func setTheme(_ theme: Theme) {
        self.theme = theme
        applyTheme()
        for row in rowViews.values { row.setTheme(theme) }
    }

    private func applyTheme() {
        caption.attributedStringValue = NSAttributedString(
            string: captionText.uppercased(),
            attributes: [
                .font: Theme.Fonts.ui(11, weight: .semibold),
                .foregroundColor: theme.foregroundDim.nsColor,
                .kern: 0.5,
            ])
        card.layer?.borderColor = theme.border.cgColor
        card.layer?.backgroundColor = theme.windowBackground.cgColor
        for line in separators { line.layer?.backgroundColor = theme.border.cgColor }
    }

    var captionForTesting: String { captionText }
}

// MARK: - Row

@MainActor
final class RowView: NSView {
    var onToggle: ((Bool) -> Void)?
    var onButton: (() -> Void)?
    var onPopup: ((Int) -> Void)?

    private(set) var row: SettingsRow
    private var theme: Theme
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let textColumn = NSView()
    /// The one control on the trailing edge; its class follows `row.control`'s case.
    private(set) var control: NSView

    init(row: SettingsRow, theme: Theme) {
        self.row = row
        self.theme = theme
        self.control = Self.makeControl(row.control, theme: theme)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        textColumn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textColumn)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        textColumn.addSubview(title)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.isSelectable = false
        detail.maximumNumberOfLines = 0
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textColumn.addSubview(detail)

        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        wireControl()

        let v = SettingsView.Metrics.rowPaddingV
        let h = SettingsView.Metrics.rowPaddingH
        NSLayoutConstraint.activate([
            textColumn.topAnchor.constraint(equalTo: topAnchor, constant: v),
            textColumn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: h),
            textColumn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -v),
            control.leadingAnchor.constraint(
                equalTo: textColumn.trailingAnchor, constant: SettingsView.Metrics.controlGap),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -h),
            control.topAnchor.constraint(equalTo: topAnchor, constant: v + 2),

            title.topAnchor.constraint(equalTo: textColumn.topAnchor),
            title.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: textColumn.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: textColumn.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: textColumn.bottomAnchor),
        ])
        setAccessibilityElement(false)
        control.setAccessibilityLabel(row.title)
        update(row)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    override func layout() {
        detail.preferredMaxLayoutWidth = textColumn.bounds.width
        super.layout()
    }

    /// Same id, possibly new words or a new control state. The control keeps its identity.
    func update(_ row: SettingsRow) {
        self.row = row
        title.stringValue = row.title
        detail.stringValue = row.detail
        switch row.control {
        case .toggle(let isOn):
            (control as? ThemedSwitch)?.isOn = isOn
        case .button(let text, _):
            (control as? NSButton)?.title = text
        case .popup(let titles, let selected):
            if let popup = control as? NSPopUpButton {
                if popup.itemTitles != titles {
                    popup.removeAllItems()
                    popup.addItems(withTitles: titles)
                }
                popup.selectItem(at: selected)
            }
        case .status(let text, let active):
            (control as? StatusChipView)?.set(text: text, active: active)
        }
        applyTheme()
    }

    func setTheme(_ theme: Theme) {
        self.theme = theme
        applyTheme()
    }

    private static func makeControl(_ control: SettingsRow.Control, theme: Theme) -> NSView {
        switch control {
        case .toggle(let isOn):
            let toggle = ThemedSwitch(theme: theme)
            toggle.isOn = isOn
            return toggle
        case .button(let text, _):
            let button = NSButton(title: text, target: nil, action: nil)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
            return button
        case .popup(let titles, let selected):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.addItems(withTitles: titles)
            popup.selectItem(at: selected)
            popup.setContentHuggingPriority(.required, for: .horizontal)
            return popup
        case .status(let text, let active):
            let chip = StatusChipView(theme: theme)
            chip.set(text: text, active: active)
            return chip
        }
    }

    private func wireControl() {
        switch control {
        case let toggle as ThemedSwitch:
            toggle.onToggle = { [weak self] isOn in self?.onToggle?(isOn) }
        case let button as NSButton where !(button is NSPopUpButton):
            button.target = self
            button.action = #selector(buttonTapped)
        case let popup as NSPopUpButton:
            popup.target = self
            popup.action = #selector(popupChanged)
        default:
            break
        }
    }

    @objc private func buttonTapped() { onButton?() }
    @objc private func popupChanged() { onPopup?((control as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }

    private func applyTheme() {
        title.font = Theme.Fonts.ui(13)
        title.textColor = theme.foreground.nsColor
        detail.font = Theme.Fonts.ui(11.5)
        detail.textColor = theme.foregroundMuted.nsColor
        switch control {
        case let toggle as ThemedSwitch:
            toggle.setTheme(theme)
        case let popup as NSPopUpButton:
            popup.font = Theme.Fonts.ui(12)
        case let button as NSButton:
            button.font = Theme.Fonts.ui(12)
            if case .button(_, let destructive) = row.control, destructive {
                button.contentTintColor = theme.meterDanger.nsColor
            } else {
                button.contentTintColor = nil
            }
        case let chip as StatusChipView:
            chip.setTheme(theme)
        default:
            break
        }
    }

    var titleForTesting: String { title.stringValue }
    var detailForTesting: String { detail.stringValue }
}

// MARK: - Status chip

/// `● Active` — a 7 pt dot and a mono word, the preset's working green when active.
@MainActor
final class StatusChipView: NSView {
    private var theme: Theme
    private var active = false
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        addSubview(dot)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    func set(text: String, active: Bool) {
        label.stringValue = text
        self.active = active
        applyTheme()
    }

    func setTheme(_ theme: Theme) {
        self.theme = theme
        applyTheme()
    }

    private func applyTheme() {
        let color = active ? theme.working : theme.foregroundDim
        label.font = Theme.Fonts.mono(11)
        label.textColor = color.nsColor
        dot.layer?.backgroundColor = color.cgColor
    }

    var textForTesting: String { label.stringValue }
    var isActiveForTesting: Bool { active }
}

/// A top-anchored document view for the scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
