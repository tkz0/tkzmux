// DeleteMergedWorktreesSheetView — the group sheet's contents (TKZ-70).
//
// Wider than the per-row card (380 pt) because it carries a list. The list is an `NSStackView` of
// one checkbox plus a dim status label per row inside an `NSScrollView`, not an `NSTableView`: the
// counts here are a handful, and a data source in a sheet is more machinery than that earns.
//
// The primary button is the red one, and it *is* the default: the checked list is the
// confirmation, so there is nothing left to be careful about by the time it is pressed.

import AppKit
import TkzCore

@MainActor
final class DeleteMergedWorktreesSheetView: NSView {

    enum Metrics {
        static let width: CGFloat = 380
        static let padding = GlassSheetMetrics.padding
        static let topPadding = GlassSheetMetrics.topPadding
        static let bottomPadding = GlassSheetMetrics.bottomPadding
        static let buttonHeight = GlassSheetMetrics.buttonHeight
        /// Beyond this the list scrolls rather than the card growing without bound.
        static let maxListHeight: CGFloat = 180
    }

    private(set) var model: DeleteMergedWorktreesSheetModel?
    private var theme: Theme

    var onDelete: (() -> Void)?
    var onCancel: (() -> Void)?
    /// A row's checkbox was toggled: its `SessionID`, and whether it is now on.
    var onToggleRow: ((SessionID, Bool) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var listHeight: NSLayoutConstraint?

    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)

    /// One row's controls, kept so `render` can update in place rather than rebuilding the list
    /// on every model change (a rebuild would drop the checkbox the user is mid-click on).
    private struct RowViews {
        var checkbox: NSButton
        var status: NSTextField
        var container: NSStackView
    }
    private var rowViews: [SessionID: RowViews] = [:]
    private var rowOrder: [SessionID] = []

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 200))
        translatesAutoresizingMaskIntoConstraints = false
        build()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    func setModel(_ model: DeleteMergedWorktreesSheetModel) {
        let changedRows = model.rows.map(\.id) != rowOrder
        self.model = model
        if changedRows { rebuildRows(model.rows) }
        render()
    }

    func setTheme(_ theme: Theme) {
        guard theme != self.theme else { return }
        self.theme = theme
        applyTheme()
        render()
    }

    // MARK: Layout

    private func build() {
        for label in [titleLabel, bodyLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            addSubview(label)
        }
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 7
        list.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = list
        addSubview(scroll)

        for button in [cancelButton, deleteButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
            addSubview(button)
        }
        cancelButton.action = #selector(cancelTapped)
        deleteButton.action = #selector(deleteTapped)
        deleteButton.keyEquivalent = "\r"
        deleteButton.hasDestructiveAction = true

        let p = Metrics.padding
        let height = scroll.heightAnchor.constraint(equalToConstant: 0)
        listHeight = height
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topPadding),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),

            scroll.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            height,
            list.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            deleteButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            deleteButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomPadding),
            deleteButton.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight),
            cancelButton.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            cancelButton.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight),
            cancelButton.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: p),
        ])
    }

    private func rebuildRows(_ rows: [DeleteMergedWorktreesSheetModel.Row]) {
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews = [:]
        rowOrder = rows.map(\.id)

        for row in rows {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(rowToggled(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(row.id.rawValue)
            let status = NSTextField(labelWithString: "")
            status.maximumNumberOfLines = 1
            status.lineBreakMode = .byTruncatingTail

            let container = NSStackView(views: [checkbox, status])
            container.orientation = .vertical
            container.alignment = .leading
            container.spacing = 1
            list.addArrangedSubview(container)
            rowViews[row.id] = RowViews(checkbox: checkbox, status: status, container: container)
        }
        list.layoutSubtreeIfNeeded()
    }

    private func applyTheme() {
        titleLabel.font = Theme.Fonts.ui(13, weight: .semibold)
        titleLabel.textColor = theme.foreground.nsColor
        bodyLabel.font = Theme.Fonts.mono(11.5)
        bodyLabel.textColor = theme.foregroundDim.nsColor
        cancelButton.font = Theme.Fonts.ui(11.5)
        deleteButton.font = Theme.Fonts.ui(11.5, weight: .semibold)
        deleteButton.bezelColor = theme.diffRemove.nsColor
        deleteButton.contentTintColor = theme.accentText.nsColor
        cancelButton.bezelColor = nil
    }

    private func render() {
        guard let model else { return }
        titleLabel.stringValue = model.title
        bodyLabel.stringValue = model.body

        for row in model.rows {
            guard let views = rowViews[row.id] else { continue }
            let label = row.branch.map { "\(row.worktreeName)  \u{2387} \($0)" } ?? row.worktreeName
            views.checkbox.attributedTitle = NSAttributedString(
                string: label,
                attributes: [
                    .font: Theme.Fonts.ui(11.5),
                    .foregroundColor: (row.isEnabled ? theme.foreground : theme.foregroundDim).nsColor,
                ])
            views.checkbox.state = row.isChecked ? .on : .off
            views.checkbox.isEnabled = row.isEnabled && model.phase != .deleting
            views.checkbox.toolTip = row.disabledReason
            views.status.stringValue = row.statusLine
            views.status.font = Theme.Fonts.mono(10.5)
            views.status.textColor = theme.foregroundDim.nsColor
        }

        list.layoutSubtreeIfNeeded()
        listHeight?.constant = min(Metrics.maxListHeight, list.fittingSize.height)

        deleteButton.title = model.deleteButtonTitle
        deleteButton.isEnabled = model.canDelete
        deleteButton.toolTip = model.deleteHint
        cancelButton.isEnabled = model.phase != .deleting
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func deleteTapped() { onDelete?() }

    @objc private func rowToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = SessionID(raw) else { return }
        onToggleRow?(id, sender.state == .on)
    }

    // MARK: Test access

    var titleForTesting: String { titleLabel.stringValue }
    var bodyForTesting: String { bodyLabel.stringValue }
    var deleteButtonForTesting: NSButton { deleteButton }
    var cancelButtonForTesting: NSButton { cancelButton }
    func checkboxForTesting(_ id: SessionID) -> NSButton? { rowViews[id]?.checkbox }
}
