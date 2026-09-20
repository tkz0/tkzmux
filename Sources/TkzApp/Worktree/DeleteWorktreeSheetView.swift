// DeleteWorktreeSheetView — the "Delete worktree…" card's contents (TKZ-70).
//
// The rebase sheet's 318 pt card with three body lines, a conditional dirty warning and its
// checkbox, and three buttons. Pure layout: `setModel` is the whole input, and every string comes
// from `DeleteWorktreeSheetModel`.
//
// The body is an `NSStackView` rather than the rebase sheet's hand-rolled constraints for one
// concrete reason: a stack view collapses a hidden arranged subview, so hiding the dirty line and
// the checkbox actually *shrinks* the card, and `fittingSize` — which is what
// `DeleteWorktreeSheetController.place` measures — comes out right without a height-constraint
// dance.
//
// Two firsts in this codebase, both deliberate:
//
//   * **A red button.** `theme.diffRemove` is the token that already means "this removes
//     something" here (the `−38` chip), and both presets have tuned it — `NSColor.systemRed`
//     would break preset parity. `contentTintColor` is not optional alongside a hand-set
//     `bezelColor`: without it the title keeps the system label colour and vanishes on the dark
//     preset's salmon bezel, which is exactly why `rebaseButton` sets it too. It never takes
//     `keyEquivalent`: Return must not be the branch-destroying path.
//   * **A checkbox.** Its title is an `attributedTitle`, not a `title`, because a plain checkbox
//     title renders in the system label colour, which is wrong on the HUD material.

import AppKit
import TkzCore

@MainActor
final class DeleteWorktreeSheetView: NSView {

    enum Metrics {
        static let width = GlassSheetMetrics.width
        static let padding = GlassSheetMetrics.padding
        static let topPadding = GlassSheetMetrics.topPadding
        static let bottomPadding = GlassSheetMetrics.bottomPadding
        static let buttonHeight = GlassSheetMetrics.buttonHeight
    }

    private(set) var model: DeleteWorktreeSheetModel?
    private var theme: Theme

    var onDelete: (() -> Void)?
    var onDeleteBranch: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleDirty: ((Bool) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let dirtyLabel = NSTextField(labelWithString: "")
    private let dirtyCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let body = NSStackView()

    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let deleteBranchButton = NSButton(
        title: DeleteWorktreeSheetModel.deleteBranchButtonTitle, target: nil, action: nil)

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 160))
        translatesAutoresizingMaskIntoConstraints = false
        build()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    // MARK: Input

    func setModel(_ model: DeleteWorktreeSheetModel) {
        self.model = model
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
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        for label in [pathLabel, branchLabel, statusLabel, dirtyLabel] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        // Keep the worktree's own name in view and drop the prefix: the tail is what identifies it.
        pathLabel.lineBreakMode = .byTruncatingHead

        dirtyCheckbox.target = self
        dirtyCheckbox.action = #selector(dirtyToggled)

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 3
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in [pathLabel, branchLabel, statusLabel, dirtyLabel, dirtyCheckbox] {
            body.addArrangedSubview(view)
        }
        // The dirty pair gets a little air above it; the three facts above it read as one block.
        body.setCustomSpacing(8, after: statusLabel)
        addSubview(body)

        for button in [cancelButton, deleteButton, deleteBranchButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
            addSubview(button)
        }
        cancelButton.action = #selector(cancelTapped)
        deleteButton.action = #selector(deleteTapped)
        deleteBranchButton.action = #selector(deleteBranchTapped)
        deleteButton.keyEquivalent = "\r"
        deleteBranchButton.hasDestructiveAction = true

        let p = Metrics.padding
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topPadding),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),

            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),

            deleteButton.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 14),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            deleteButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomPadding),
            deleteButton.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight),
            deleteBranchButton.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),
            deleteBranchButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            deleteBranchButton.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight),
            cancelButton.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight),
            cancelButton.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: p),
        ])
        // Cancel sits left of whichever destructive button is showing, so hiding the red one does
        // not leave a gap.
        cancelTrailingToRed = cancelButton.trailingAnchor.constraint(
            equalTo: deleteBranchButton.leadingAnchor, constant: -8)
        cancelTrailingToPrimary = cancelButton.trailingAnchor.constraint(
            equalTo: deleteButton.leadingAnchor, constant: -8)
        cancelTrailingToRed?.isActive = true
    }

    private var cancelTrailingToRed: NSLayoutConstraint?
    private var cancelTrailingToPrimary: NSLayoutConstraint?

    private func applyTheme() {
        titleLabel.font = Theme.Fonts.ui(13, weight: .semibold)
        titleLabel.textColor = theme.foreground.nsColor

        pathLabel.font = Theme.Fonts.mono(11)
        pathLabel.textColor = theme.foregroundDim.nsColor
        branchLabel.font = Theme.Fonts.mono(11.5)
        branchLabel.textColor = theme.foregroundMuted.nsColor
        statusLabel.font = Theme.Fonts.mono(11.5)
        dirtyLabel.font = Theme.Fonts.mono(11.5)
        dirtyLabel.textColor = theme.needsYouText.nsColor

        dirtyCheckbox.attributedTitle = NSAttributedString(
            string: DeleteWorktreeSheetModel.dirtyAcknowledgementTitle,
            attributes: [
                .font: Theme.Fonts.ui(11.5),
                .foregroundColor: theme.foreground.nsColor,
            ])
        dirtyCheckbox.contentTintColor = theme.needsYouText.nsColor

        cancelButton.font = Theme.Fonts.ui(11.5)
        deleteButton.font = Theme.Fonts.ui(11.5, weight: .semibold)
        deleteBranchButton.font = Theme.Fonts.ui(11.5, weight: .semibold)

        deleteButton.bezelColor = theme.accent.nsColor
        deleteButton.contentTintColor = theme.accentText.nsColor
        deleteBranchButton.bezelColor = theme.diffRemove.nsColor
        deleteBranchButton.contentTintColor = theme.accentText.nsColor
        cancelButton.bezelColor = nil
    }

    private func render() {
        guard let model else { return }
        titleLabel.stringValue = model.title
        pathLabel.stringValue = model.pathLine
        branchLabel.stringValue = model.branchLine

        statusLabel.stringValue = model.statusLine
        statusLabel.textColor = (model.statusTone == .caution ? theme.needsYouText : theme.foregroundDim)
            .nsColor

        dirtyLabel.stringValue = model.dirtyLine ?? ""
        dirtyLabel.isHidden = model.dirtyLine == nil
        dirtyCheckbox.isHidden = !model.requiresDirtyAcknowledgement || model.dirtyLine == nil
        dirtyCheckbox.state = model.acknowledgedDirty ? .on : .off

        deleteButton.title = model.deleteButtonTitle
        deleteButton.isEnabled = model.canDelete
        deleteButton.toolTip = model.deleteHint

        deleteBranchButton.isHidden = !model.showsDeleteBranchButton
        deleteBranchButton.isEnabled = model.canDelete
        deleteBranchButton.toolTip = model.deleteHint
        cancelTrailingToRed?.isActive = model.showsDeleteBranchButton
        cancelTrailingToPrimary?.isActive = !model.showsDeleteBranchButton

        cancelButton.isEnabled = model.phase != .deleting
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func deleteTapped() { onDelete?() }
    @objc private func deleteBranchTapped() { onDeleteBranch?() }
    @objc private func dirtyToggled() { onToggleDirty?(dirtyCheckbox.state == .on) }

    // MARK: Test access

    var titleForTesting: String { titleLabel.stringValue }
    var pathForTesting: String { pathLabel.stringValue }
    var branchForTesting: String { branchLabel.stringValue }
    var statusForTesting: String { statusLabel.stringValue }
    var dirtyForTesting: String { dirtyLabel.stringValue }
    var deleteButtonForTesting: NSButton { deleteButton }
    var deleteBranchButtonForTesting: NSButton { deleteBranchButton }
    var cancelButtonForTesting: NSButton { cancelButton }
    var dirtyCheckboxForTesting: NSButton { dirtyCheckbox }
}
