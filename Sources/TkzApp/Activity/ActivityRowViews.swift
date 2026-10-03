// ActivityRowViews — how the ⌘I feed draws its rows.
//
// Views over values, like the search overlay's rows: a pinned working row (dot, title, group,
// elapsed), a thread row (title · group · age, the kind pill, the two-line preview, `+N older`),
// a folded row under an expanded thread, and the one-line empty state. The string builders are
// static so the highlighting and the labels can be asserted without a window.

import AppKit
import TkzCore

/// The Auto Layout constants in this file (WOR-307 S5).
private typealias LayoutTokens = DesignTokens.Metrics

// MARK: - Shared

@MainActor
private func singleLine(_ label: NSTextField) -> NSTextField {
    label.usesSingleLineMode = true
    label.maximumNumberOfLines = 1
    label.cell?.wraps = false
    label.cell?.isScrollable = false
    label.lineBreakMode = .byTruncatingTail
    return label
}

@MainActor
private func dimMono(_ text: String, theme: Theme) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Theme.Fonts.mono(theme.fontMono.detail)
    label.textColor = theme.foregroundDim.nsColor
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    label.setContentHuggingPriority(.required, for: .horizontal)
    return singleLine(label)
}

/// The `NEEDS YOU · permission` / `STOP` / `ENDED` pill.
@MainActor
final class ActivityKindPill: NSView {
    private let label = NSTextField(labelWithString: "")

    init(kind: ActivityEvent.Kind, theme: Theme) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.Fonts.font(DesignTokens.Typography.activityKindPill)
        label.stringValue = ActivityFeedModel.kindLabel(kind)
        singleLine(label).setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(LayoutTokens.ActivityRow.pillPaddingX.value)),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.pillPaddingX.value)),
            label.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(LayoutTokens.ActivityRow.pillPaddingY.value)),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.pillPaddingY.value)),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        switch kind {
        case .needsYou:
            label.textColor = theme.needsYouText.nsColor
            layer?.backgroundColor = theme.needsYouBackground.cgColor
        case .stop:
            label.textColor = theme.working.nsColor
            layer?.backgroundColor = theme.working.nsColor.withAlphaComponent(0.16).cgColor
        case .sessionEnded:
            label.textColor = theme.foregroundDim.nsColor
            layer?.backgroundColor = theme.foregroundDim.nsColor.withAlphaComponent(0.14).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var textForTesting: String { label.stringValue }
}

// MARK: - Working

/// `● review   Northwind                                   working · 12m`
final class ActivityWorkingRowView: NSTableCellView {
    init(row: ActivityFeedModel.WorkingRow, theme: Theme) {
        super.init(frame: .zero)
        let dot = StatusDotView()
        dot.dot.configure(status: .working, theme: theme)
        dot.setContentHuggingPriority(.required, for: .horizontal)

        let title = singleLine(NSTextField(labelWithAttributedString: Self.titleString(row, theme: theme)))
        let group = dimMono(row.groupName, theme: theme)
        group.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trailing = dimMono(Self.trailingText(row), theme: theme)

        for view in [dot, title, group, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(LayoutTokens.ActivityRow.insetX.value)),
            dot.widthAnchor.constraint(equalToConstant: CGFloat(LayoutTokens.ActivityRow.dotSize.value)),
            dot.heightAnchor.constraint(equalToConstant: CGFloat(LayoutTokens.ActivityRow.dotSize.value)),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: CGFloat(LayoutTokens.ActivityRow.gap.value)),
            group.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: CGFloat(LayoutTokens.ActivityRow.gap.value)),
            group.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.gap.value)),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.insetX.value)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func titleString(_ row: ActivityFeedModel.WorkingRow, theme: Theme) -> NSAttributedString {
        SearchHighlight.string(
            row.title, ranges: row.titleRanges,
            font: Theme.Fonts.ui(theme.fontUI.title, weight: .medium),
            color: theme.foreground.nsColor, theme: theme)
    }

    static func trailingText(_ row: ActivityFeedModel.WorkingRow) -> String {
        row.elapsed.isEmpty ? "working" : "working \u{00B7} \(row.elapsed)"
    }
}

// MARK: - Thread

/// ```
/// review   Northwind · 12m · ended                          [NEEDS YOU · permission]
/// The agent needs your permission to use Bash
/// (second line of the preview)                                          +2 older
/// ```
final class ActivityThreadRowView: NSTableCellView {
    var onToggleOlder: (() -> Void)?
    private let olderButton = NSButton(title: "", target: nil, action: nil)

    init(row: ActivityFeedModel.ThreadRow, age: String, theme: Theme) {
        super.init(frame: .zero)
        let title = singleLine(NSTextField(labelWithAttributedString: Self.titleString(row, theme: theme)))
        let meta = dimMono(Self.metaText(row, age: age), theme: theme)
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pill = ActivityKindPill(kind: row.head.kind, theme: theme)

        let preview = NSTextField(labelWithAttributedString: Self.previewString(row, theme: theme))
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        preview.cell?.wraps = true
        preview.cell?.truncatesLastVisibleLine = true
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        olderButton.isBordered = false
        olderButton.setButtonType(.momentaryChange)
        olderButton.attributedTitle = NSAttributedString(
            string: Self.olderText(row),
            attributes: [.font: Theme.Fonts.mono(theme.fontMono.detail), .foregroundColor: theme.accent.nsColor])
        olderButton.isHidden = row.olderCount == 0
        olderButton.target = self
        olderButton.action = #selector(olderClicked)
        olderButton.setContentHuggingPriority(.required, for: .horizontal)
        olderButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [title, meta, pill, preview, olderButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(LayoutTokens.ActivityRow.insetX.value)),
            title.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(LayoutTokens.ActivityRow.threadTop.value)),
            meta.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: CGFloat(LayoutTokens.ActivityRow.gap.value)),
            meta.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.gap.value)),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.insetX.value)),
            pill.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(LayoutTokens.ActivityRow.insetX.value)),
            preview.topAnchor.constraint(equalTo: title.bottomAnchor, constant: CGFloat(LayoutTokens.ActivityRow.previewGap.value)),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: olderButton.leadingAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.gap.value)),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.previewBottomInset.value)),
            olderButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.olderTrailingInset.value)),
            olderButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.olderBottomInset.value)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func olderClicked() { onToggleOlder?() }

    /// Bold while unread — the one thing the feed says about a row at a glance.
    static func titleString(_ row: ActivityFeedModel.ThreadRow, theme: Theme) -> NSAttributedString {
        SearchHighlight.string(
            row.head.sessionTitle, ranges: row.titleRanges,
            font: Theme.Fonts.ui(theme.fontUI.title, weight: row.unread ? .bold : .medium),
            color: theme.foreground.nsColor, theme: theme)
    }

    /// `Northwind · 12m · ended`
    static func metaText(_ row: ActivityFeedModel.ThreadRow, age: String) -> String {
        var parts: [String] = []
        if !row.head.groupName.isEmpty { parts.append(row.head.groupName) }
        parts.append(age)
        if row.ended { parts.append("ended") }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func previewString(_ row: ActivityFeedModel.ThreadRow, theme: Theme) -> NSAttributedString {
        let text = row.head.preview.isEmpty ? Self.fallbackPreview(row.head.kind) : row.head.preview
        return SearchHighlight.string(
            text, ranges: row.head.preview.isEmpty ? [] : row.previewRanges,
            font: Theme.Fonts.ui(theme.fontUI.body),
            color: row.unread ? theme.foreground.nsColor : theme.foregroundMuted.nsColor, theme: theme)
    }

    /// A NEEDS YOU without the agent's own line, or an exit: one plain sentence.
    ///
    /// `ActivityEvent` (`TkzCore`) carries no agent name of its own — nothing here can say which
    /// adapter produced the row without reaching back into the store, which the view layer does
    /// not hold — so this says "the agent" rather than guessing at a product name.
    static func fallbackPreview(_ kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .needsYou(.permission, _): "The agent is waiting for permission"
        case .needsYou(.elicitation, _), .needsYou(.agentInput, _): "The agent is asking you a question"
        case .needsYou(.doneUnattended, _): "The agent finished and nobody looked"
        case .stop: "The agent finished"
        case .sessionEnded: "The agent exited"
        }
    }

    static func olderText(_ row: ActivityFeedModel.ThreadRow) -> String {
        guard row.olderCount > 0 else { return "" }
        return row.expanded ? "\u{2212} older" : "+\(row.olderCount) older"
    }

    var olderButtonForTesting: NSButton { olderButton }
}

// MARK: - Folded

/// `    [STOP]  Done. Tests are green.                                   2h`
final class ActivityFoldedRowView: NSTableCellView {
    init(row: ActivityFeedModel.FoldedRow, age: String, theme: Theme) {
        super.init(frame: .zero)
        let pill = ActivityKindPill(kind: row.event.kind, theme: theme)
        let preview = NSTextField(labelWithAttributedString: Self.previewString(row, theme: theme))
        preview.maximumNumberOfLines = 1
        preview.lineBreakMode = .byTruncatingTail
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trailing = dimMono(age, theme: theme)

        for view in [pill, preview, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(LayoutTokens.ActivityRow.foldedIndent.value)),
            preview.leadingAnchor.constraint(equalTo: pill.trailingAnchor, constant: CGFloat(LayoutTokens.ActivityRow.gap.value)),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.gap.value)),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(LayoutTokens.ActivityRow.insetX.value)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func previewString(_ row: ActivityFeedModel.FoldedRow, theme: Theme) -> NSAttributedString {
        let firstLine = ActivityEvent.firstLines(of: row.event.preview, count: 1).first
        let text = firstLine ?? ActivityThreadRowView.fallbackPreview(row.event.kind)
        let ranges = firstLine.map { line in row.previewRanges.filter { $0.upperBound <= line.endIndex } } ?? []
        return SearchHighlight.string(
            text, ranges: ranges,
            font: Theme.Fonts.ui(theme.fontUI.body),
            color: row.event.unread ? theme.foreground.nsColor : theme.foregroundMuted.nsColor, theme: theme)
    }
}

// MARK: - Empty

final class ActivityEmptyRowView: NSTableCellView {
    init(text: String, theme: Theme) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: text)
        label.font = Theme.Fonts.ui(theme.fontUI.body)
        label.textColor = theme.foregroundDim.nsColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(LayoutTokens.ActivityRow.insetX.value)),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - Footer

/// `↑↓ navigate · ↵ open · → older · esc close`
final class ActivityFooterView: NSView {
    static let height: CGFloat = 28
    static let hints = ["\u{2191}\u{2193} navigate", "\u{21B5} open", "\u{2192} \u{2190} older", "esc close"]

    private let label = NSTextField(labelWithString: "")

    init(theme: Theme) {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(LayoutTokens.ActivityRow.insetX.value)),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(theme: Theme) {
        label.font = Theme.Fonts.ui(theme.fontUI.caption)
        label.textColor = theme.foregroundDim.nsColor
        label.stringValue = Self.hints.joined(separator: "   \u{00B7}   ")
    }
}
