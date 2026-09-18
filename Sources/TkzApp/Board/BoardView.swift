// BoardView — the Kanban board laid over the terminal container (⇧⌘K, the toolbar's calendar button).
//
//     Board   3 to do · 1 in progress                                                  ✕
//     ┌ To Do        3 ＋┐ ┌ In Progress  1 ＋┐ ┌ In Review    0 ＋┐ ┌ Done         4 ＋┐
//     │ ┌──────────────┐ │ │ ┌──────────────┐ │ │                  │ │                  │
//     │ │ #TKZMUX     ⋮│ │ │ │ …            │ │ │                  │ │                  │
//     │ │ Card title   │ │ │ └──────────────┘ │ │                  │ │                  │
//     │ │ notes, 3 ln  │ │ │                  │ │                  │ │                  │
//     │ │ ● agent  ⟶   │ │ │                  │ │                  │ │                  │
//     │ └──────────────┘ │ │                  │ │                  │ │                  │
//     │   ＋ Add task    │ │   ＋ Add task    │ │                  │ │                  │
//     └──────────────────┘ └──────────────────┘ └──────────────────┘ └──────────────────┘
//
// A view *inside* the window like the changes viewer, and for its reason: it replaces the terminal
// on screen and takes the keyboard on purpose; Esc gives it back. Ordinary AppKit views under Auto
// Layout — this is not a hot path, a board redraws when a card changes.
//
// The views own no state and write nothing. Every gesture is a closure `BoardController` assigns;
// `configure(_:)` replaces what is drawn.

import AppKit
import TkzCore

// MARK: - Palette

/// The board's colours, derived from the theme's tokens so both presets work with no new tokens.
struct BoardPalette {
    let background: NSColor
    let column: NSColor
    let card: NSColor
    let cardBorder: NSColor
    let title: NSColor
    let body: NSColor
    let dim: NSColor
    let accent: NSColor
    let working: NSColor
    let attention: NSColor

    init(theme: Theme) {
        let lift = theme.foreground
        background = theme.terminalBackground.nsColor
        column = theme.terminalBackground.mixed(with: lift, amount: theme.isDark ? 0.045 : 0.035).nsColor
        card = theme.terminalBackground.mixed(with: lift, amount: theme.isDark ? 0.10 : 0.0).nsColor
        cardBorder = theme.border.nsColor
        title = theme.foreground.nsColor
        body = theme.foregroundMuted.nsColor
        dim = theme.foregroundDim.nsColor
        accent = theme.accent.nsColor
        working = theme.working.nsColor
        attention = theme.waiting.nsColor
    }

    func color(for tone: BoardModel.Status.Tone) -> NSColor {
        switch tone {
        case .muted: dim
        case .working: working
        case .attention: attention
        case .done: body
        }
    }

    func color(for dot: BoardModel.Agent.Dot) -> NSColor {
        switch dot {
        case .working: working
        case .needsYou: attention
        case .idle: body
        case .offline: dim.withAlphaComponent(0.5)
        }
    }
}

enum BoardMetrics {
    static let padding: CGFloat = 16
    static let columnGap: CGFloat = 12
    static let columnRadius: CGFloat = 12
    static let cardRadius: CGFloat = 9
    static let cardGap: CGFloat = 8
    static let cardInset: CGFloat = 11
    static let headerHeight: CGFloat = 44
    static let minColumnWidth: CGFloat = 200
}

extension NSPasteboard.PasteboardType {
    /// A dragged card: its `BoardTaskID` as a string. Private to the app — nothing outside it can
    /// make sense of a card.
    static let tkzBoardTask = NSPasteboard.PasteboardType("se.tkz.tkzmux.board-task")
}

private final class BoardFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private func boardLabel(_ font: NSFont, lines: Int = 1) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: "")
    field.font = font
    field.maximumNumberOfLines = lines
    field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    field.cell?.truncatesLastVisibleLine = true
    field.isSelectable = false
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return field
}

/// A borderless text button: `＋`, `⋮`, `✕`, "＋ Add task".
@MainActor
private func boardButton(_ title: String, font: NSFont, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.isBordered = false
    button.font = font
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setButtonType(.momentaryChange)
    return button
}

// MARK: - Board

final class BoardView: NSView {
    /// Esc, or the header's ✕.
    var onEscape: (() -> Void)?
    /// `＋` on a column, or its "Add task" footer. The view is what a popover anchors to.
    var onAdd: ((BoardColumn, NSView) -> Void)?
    /// Double-click on a card.
    var onEdit: ((BoardTaskID, NSView) -> Void)?
    /// `⋮` or right-click: the controller builds the menu, since it knows the groups and rows.
    var menuForCard: ((BoardTaskID) -> NSMenu?)?
    /// A card was dropped at `index` among `column`'s *other* cards.
    var onDrop: ((BoardTaskID, BoardColumn, Int) -> Void)?
    /// The agent chip on a card.
    var onOpenAgent: ((SessionID) -> Void)?

    private(set) var palette: BoardPalette
    private let titleLabel = boardLabel(Theme.Fonts.ui(15, weight: .semibold))
    private let summaryLabel = boardLabel(Theme.Fonts.ui(11.5))
    private var closeButton: NSButton!
    private(set) var columnViews: [BoardColumnView] = []

    init(theme: Theme) {
        palette = BoardPalette(theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = "Board"
        closeButton = boardButton("\u{2715}", font: Theme.Fonts.ui(13), target: self, action: #selector(close))
        closeButton.toolTip = "Back to the terminal (Esc)"
        closeButton.setAccessibilityLabel("Close the board")

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.distribution = .fillEqually
        columns.alignment = .top
        columns.spacing = BoardMetrics.columnGap
        columns.translatesAutoresizingMaskIntoConstraints = false
        for column in BoardColumn.allCases {
            let view = BoardColumnView(column: column, board: self)
            columnViews.append(view)
            columns.addArrangedSubview(view)
            view.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: BoardMetrics.minColumnWidth).isActive = true
        }

        // Four 200 pt columns do not fit a narrow window; they scroll sideways rather than crush.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = BoardFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(columns)
        scroll.documentView = document

        for view in [titleLabel, summaryLabel, closeButton!, scroll] as [NSView] { addSubview(view) }

        let p = BoardMetrics.padding
        // A tie-breaker and nothing more. `document ≥ clip` (required, below) already makes the
        // board fill a wide window; this only says "and no wider than it has to be". At any real
        // priority the columns' minimum width reaches out through the clip view and resizes what
        // is around it — at 750 it widened the window, at 490 it squeezed the sidebar — and it
        // does so even while the board is hidden, because a hidden view still takes part in layout.
        let fill = document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        fill.priority = NSLayoutConstraint.Priority(1)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p + 2),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: BoardMetrics.headerHeight / 2 + 2),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            summaryLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -10),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: topAnchor, constant: BoardMetrics.headerHeight),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            fill,
            document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),

            columns.topAnchor.constraint(equalTo: document.topAnchor),
            columns.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    func configure(_ columns: [BoardModel.Column]) {
        summaryLabel.stringValue = BoardModel.summary(columns)
        for model in columns {
            columnViews.first { $0.column == model.column }?.configure(model.cards)
        }
    }

    func apply(theme: Theme) {
        palette = BoardPalette(theme: theme)
        layer?.backgroundColor = palette.background.cgColor
        titleLabel.textColor = palette.title
        summaryLabel.textColor = palette.dim
        closeButton.contentTintColor = palette.dim
        closeButton.attributedTitle = NSAttributedString(
            string: "\u{2715}", attributes: [.foregroundColor: palette.dim, .font: Theme.Fonts.ui(13)])
        for view in columnViews { view.applyPalette() }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    func takeKeyboard() { window?.makeFirstResponder(self) }

    override func mouseDown(with event: NSEvent) { takeKeyboard() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    /// Esc arriving as `cancelOperation:` through the responder chain.
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    @objc private func close() { onEscape?() }
}

// MARK: - Column

final class BoardColumnView: NSView {
    let column: BoardColumn
    private unowned let board: BoardView

    private let titleLabel = boardLabel(Theme.Fonts.ui(12.5, weight: .semibold))
    private let countLabel = boardLabel(Theme.Fonts.ui(11))
    private var addButton: NSButton!
    private var footerButton: NSButton!
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let insertionLine = NSView()
    private(set) var cardViews: [BoardCardView] = []

    init(column: BoardColumn, board: BoardView) {
        self.column = column
        self.board = board
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = BoardMetrics.columnRadius
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = column.title
        addButton = boardButton("\u{FF0B}", font: Theme.Fonts.ui(13), target: self, action: #selector(add(_:)))
        addButton.toolTip = "Add a task to \(column.title)"
        addButton.setAccessibilityLabel("Add a task to \(column.title)")
        footerButton = boardButton(
            "\u{FF0B} Add task", font: Theme.Fonts.ui(11.5, weight: .medium), target: self,
            action: #selector(add(_:)))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = BoardMetrics.cardGap
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = BoardFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.addSubview(footerButton)
        insertionLine.wantsLayer = true
        insertionLine.layer?.cornerRadius = 1
        insertionLine.isHidden = true
        document.addSubview(insertionLine)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        for view in [titleLabel, countLabel, addButton!, scroll] as [NSView] { addSubview(view) }

        let inset: CGFloat = 10
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 4),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 7),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset - 2),
            addButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -6),

            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            footerButton.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 10),
            footerButton.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            footerButton.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -6),
        ])
        registerForDraggedTypes([.tkzBoardTask])
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    func configure(_ cards: [BoardModel.Card]) {
        countLabel.stringValue = "\(cards.count)"
        // Views are reused by position: a status flip on one card re-labels it in place rather
        // than tearing down the column under a drag.
        while cardViews.count > cards.count {
            let view = cardViews.removeLast()
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        while cardViews.count < cards.count {
            let view = BoardCardView(board: board)
            cardViews.append(view)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for (view, card) in zip(cardViews, cards) { view.configure(card, palette: board.palette) }
    }

    func applyPalette() {
        let palette = board.palette
        layer?.backgroundColor = palette.column.cgColor
        titleLabel.textColor = palette.title
        countLabel.textColor = palette.dim
        insertionLine.layer?.backgroundColor = palette.accent.cgColor
        for (button, font) in [(addButton!, Theme.Fonts.ui(13)), (footerButton!, Theme.Fonts.ui(11.5, weight: .medium))] {
            button.attributedTitle = NSAttributedString(
                string: button.title, attributes: [.foregroundColor: palette.dim, .font: font])
        }
        for view in cardViews { view.applyPalette(palette) }
    }

    @objc private func add(_ sender: NSButton) { board.onAdd?(column, sender) }

    // MARK: Drop

    /// Where a drop at `point` (this view's coordinates) lands among the column's cards, not
    /// counting the dragged card itself — which is the index `moveBoardTask` takes.
    func insertionIndex(at point: NSPoint, dragging: BoardTaskID?) -> Int {
        let others = cardViews.filter { $0.card?.id != dragging }
        // This view is not flipped: a card sits above the drop when its middle is higher up.
        return others.count { convert($0.bounds, from: $0).midY > point.y }
    }

    private func draggedTask(_ sender: any NSDraggingInfo) -> BoardTaskID? {
        sender.draggingPasteboard.string(forType: .tkzBoardTask).flatMap(BoardTaskID.init)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let task = draggedTask(sender) else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        showInsertionLine(at: insertionIndex(at: point, dragging: task), dragging: task)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { insertionLine.isHidden = true }

    override func draggingEnded(_ sender: any NSDraggingInfo) { insertionLine.isHidden = true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        insertionLine.isHidden = true
        guard let task = draggedTask(sender) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        board.onDrop?(task, column, insertionIndex(at: point, dragging: task))
        return true
    }

    private func showInsertionLine(at index: Int, dragging: BoardTaskID) {
        guard let document = scroll.documentView else { return }
        let others = cardViews.filter { $0.card?.id != dragging }
        let y: CGFloat
        if index < others.count {
            y = document.convert(others[index].bounds, from: others[index]).minY - BoardMetrics.cardGap / 2
        } else if let last = others.last {
            y = document.convert(last.bounds, from: last).maxY + BoardMetrics.cardGap / 2
        } else {
            y = 2
        }
        insertionLine.frame = NSRect(x: 2, y: max(0, y - 1), width: document.bounds.width - 4, height: 2)
        insertionLine.isHidden = false
    }
}

// MARK: - Card

final class BoardCardView: NSView, NSDraggingSource {
    private unowned let board: BoardView
    private(set) var card: BoardModel.Card?

    private let tagLabel = boardLabel(Theme.Fonts.ui(10.5, weight: .semibold))
    private let tagBackground = NSView()
    private let titleLabel = boardLabel(Theme.Fonts.ui(12.5, weight: .medium), lines: 3)
    private let notesLabel = boardLabel(Theme.Fonts.ui(11.5), lines: 3)
    private let statusLabel = boardLabel(Theme.Fonts.ui(11))
    private let agentDot = NSView()
    private var agentButton: NSButton!
    private var menuButton: NSButton!
    private let content = NSStackView()
    private var mouseDownPoint: NSPoint?

    init(board: BoardView) {
        self.board = board
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = BoardMetrics.cardRadius
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        tagBackground.wantsLayer = true
        tagBackground.layer?.cornerRadius = 5
        tagBackground.translatesAutoresizingMaskIntoConstraints = false
        tagBackground.addSubview(tagLabel)

        menuButton = boardButton("\u{22EE}", font: Theme.Fonts.ui(14, weight: .bold), target: self, action: #selector(showMenu(_:)))
        menuButton.toolTip = "Group, agent, move, delete"
        menuButton.setAccessibilityLabel("Card actions")

        agentDot.wantsLayer = true
        agentDot.layer?.cornerRadius = 3.5
        agentDot.translatesAutoresizingMaskIntoConstraints = false
        agentButton = boardButton("", font: Theme.Fonts.ui(11, weight: .medium), target: self, action: #selector(openAgent))
        agentButton.toolTip = "Go to this agent's session"
        agentButton.lineBreakMode = .byTruncatingTail
        agentButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let agentRow = NSStackView(views: [agentDot, agentButton])
        agentRow.orientation = .horizontal
        agentRow.spacing = 5
        agentRow.alignment = .centerY

        let footer = NSStackView(views: [agentRow, statusLabel])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 3

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [tagBackground, titleLabel, notesLabel, footer] as [NSView] {
            content.addArrangedSubview(view)
        }
        content.setCustomSpacing(8, after: notesLabel)
        addSubview(content)
        addSubview(menuButton)

        let inset = BoardMetrics.cardInset
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            titleLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -14),
            notesLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),

            tagLabel.topAnchor.constraint(equalTo: tagBackground.topAnchor, constant: 2),
            tagLabel.bottomAnchor.constraint(equalTo: tagBackground.bottomAnchor, constant: -2),
            tagLabel.leadingAnchor.constraint(equalTo: tagBackground.leadingAnchor, constant: 6),
            tagLabel.trailingAnchor.constraint(equalTo: tagBackground.trailingAnchor, constant: -6),
            tagBackground.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -18),

            agentDot.widthAnchor.constraint(equalToConstant: 7),
            agentDot.heightAnchor.constraint(equalToConstant: 7),

            menuButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            menuButton.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    func configure(_ card: BoardModel.Card, palette: BoardPalette) {
        self.card = card
        titleLabel.stringValue = card.title
        notesLabel.stringValue = card.notes
        notesLabel.isHidden = card.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        tagLabel.stringValue = card.group.map { "#" + $0.name } ?? ""
        tagBackground.isHidden = card.group == nil
        agentButton.superview?.isHidden = card.agent == nil
        statusLabel.stringValue = card.status.text
        setAccessibilityLabel("\(card.title), \(card.status.text)")
        applyPalette(palette)
    }

    func applyPalette(_ palette: BoardPalette) {
        layer?.backgroundColor = palette.card.cgColor
        layer?.borderColor = palette.cardBorder.cgColor
        titleLabel.textColor = palette.title
        notesLabel.textColor = palette.body
        menuButton.attributedTitle = NSAttributedString(
            string: "\u{22EE}",
            attributes: [.foregroundColor: palette.dim, .font: Theme.Fonts.ui(14, weight: .bold)])
        guard let card else { return }
        let tint = card.group?.color?.nsColor ?? palette.body
        tagLabel.textColor = tint
        tagBackground.layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        statusLabel.textColor = palette.color(for: card.status.tone)
        if let agent = card.agent {
            agentDot.layer?.backgroundColor = palette.color(for: agent.dot).cgColor
            agentButton.attributedTitle = NSAttributedString(
                string: agent.title,
                attributes: [.foregroundColor: palette.title, .font: Theme.Fonts.ui(11, weight: .medium)])
        }
    }

    // MARK: Gestures

    @objc private func showMenu(_ sender: NSButton) {
        guard let card, let menu = board.menuForCard?(card.id) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func openAgent() {
        if let agent = card?.agent { board.onOpenAgent?(agent.id) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        card.flatMap { board.menuForCard?($0.id) }
    }

    override func mouseDown(with event: NSEvent) {
        board.takeKeyboard()
        if event.clickCount == 2, let card {
            mouseDownPoint = nil
            board.onEdit?(card.id, self)
        } else {
            mouseDownPoint = event.locationInWindow
        }
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    /// A drag starts after 4 pt of travel, so a click that wobbles is still a click.
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let card else { return }
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= 4 else { return }
        mouseDownPoint = nil

        let item = NSPasteboardItem()
        item.setString(card.id.rawValue, forType: .tkzBoardTask)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshotImage())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    private func snapshotImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        alphaValue = 0.35
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        alphaValue = 1
    }
}
