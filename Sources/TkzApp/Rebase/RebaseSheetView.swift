// RebaseSheetView.swift — the sheet's contents (design 5a/5b, simplified 2026-09-13).
//
// A 318 pt card: the title and the chord on one line, the body line under it, Cancel and Rebase
// right-aligned under that. Pure layout: `setModel` is the whole input.

import AppKit
import TkzCore

@MainActor
final class RebaseSheetView: NSView {

    /// Aliases onto the family's geometry (`Sheets/GlassSheet.swift`), kept under this name so
    /// the controller and the tests read the same as before.
    enum Metrics {
        static let width = GlassSheetMetrics.width
        static let padding = GlassSheetMetrics.padding
        static let topPadding = GlassSheetMetrics.topPadding
        static let bottomPadding = GlassSheetMetrics.bottomPadding
        static let cornerRadius = GlassSheetMetrics.cornerRadius
        static let buttonHeight = GlassSheetMetrics.buttonHeight
    }

    private(set) var model: RebaseSheetModel?
    private var theme: Theme

    var onRebase: (() -> Void)?
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let rebaseButton = NSButton(title: "Rebase", target: nil, action: nil)

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 120))
        translatesAutoresizingMaskIntoConstraints = false
        build()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    // MARK: Input

    func setModel(_ model: RebaseSheetModel) {
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
        for label in [titleLabel, shortcutLabel, bodyLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        bodyLabel.maximumNumberOfLines = 2
        bodyLabel.lineBreakMode = .byWordWrapping
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for button in [cancelButton, rebaseButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
            addSubview(button)
        }
        cancelButton.action = #selector(cancelTapped)
        rebaseButton.action = #selector(rebaseTapped)
        rebaseButton.keyEquivalent = "\r"

        let p = Metrics.padding
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topPadding),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            shortcutLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),

            rebaseButton.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 14),
            rebaseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            rebaseButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomPadding),
            rebaseButton.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight),
            cancelButton.centerYAnchor.constraint(equalTo: rebaseButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: rebaseButton.leadingAnchor, constant: -8),
            cancelButton.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight),
        ])
    }

    private func applyTheme() {
        titleLabel.font = Theme.Fonts.ui(13, weight: .semibold)
        titleLabel.textColor = theme.foreground.nsColor
        shortcutLabel.font = Theme.Fonts.mono(10)
        shortcutLabel.textColor = theme.foregroundDim.nsColor
        bodyLabel.font = Theme.Fonts.mono(11.5)
        for button in [cancelButton, rebaseButton] {
            button.font = Theme.Fonts.ui(11.5, weight: button === rebaseButton ? .semibold : .regular)
        }
        rebaseButton.bezelColor = theme.accent.nsColor
        rebaseButton.contentTintColor = theme.accentText.nsColor
        cancelButton.bezelColor = nil
    }

    private func render() {
        guard let model else { return }
        titleLabel.stringValue = model.title
        shortcutLabel.stringValue = model.shortcut ?? ""
        shortcutLabel.isHidden = model.shortcut == nil

        let body = model.body
        let text = NSMutableAttributedString(
            string: body.lead,
            attributes: [.font: Theme.Fonts.mono(11.5), .foregroundColor: theme.foregroundDim.nsColor])
        if let emphasis = body.emphasis {
            text.append(NSAttributedString(
                string: emphasis,
                attributes: [.font: Theme.Fonts.mono(11.5), .foregroundColor: theme.terminalForeground.nsColor]))
        }
        bodyLabel.attributedStringValue = text

        rebaseButton.isEnabled = model.canRebase
        rebaseButton.toolTip = model.rebaseHint
        cancelButton.isEnabled = model.phase != .rebasing
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func rebaseTapped() { onRebase?() }

    // MARK: Test access

    var titleForTesting: String { titleLabel.stringValue }
    var bodyForTesting: String { bodyLabel.attributedStringValue.string }
    var rebaseButtonForTesting: NSButton { rebaseButton }
    var cancelButtonForTesting: NSButton { cancelButton }
}
