// SearchRowViews.swift — how the toolbar's results overlay draws (TKZ-52, design 2c.6).
//
// 2c.6's rows are one line each, unlike ⇧⌘P's two-line `PaletteRowView`: a status dot, the title
// with the matched characters marked in amber, a dim mono trailer, and a right-aligned hint. The
// chip bar sits above the list and the key hints below it.
//
// Everything here is a view over a value — no store, no controller. The attributed-string builders
// are `static` and pure so the highlighting can be asserted without a window.

import AppKit
import TkzCore

// MARK: - Shared highlighting

@MainActor
enum SearchHighlight {
    /// Marks `ranges` of `text` the way 2c.6's `<mark>` does: amber wash, lifted text colour.
    static func string(
        _ text: String,
        ranges: [Range<String.Index>],
        font: NSFont,
        color: NSColor,
        theme: Theme
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])
        for range in ranges {
            out.addAttributes(
                [
                    .backgroundColor: theme.searchMatchBackground.nsColor,
                    .foregroundColor: theme.searchMatchText.nsColor,
                ],
                range: NSRange(range, in: text))
        }
        return out
    }
}

/// The dim mono trailer at a row's right edge (`↵ open`, `turn 9 · 1h`, `⌘↵`).
/// Every label in a row is one line, always.
///
/// `NSTextField(labelWithString:)` wraps by default, and an attributed string carries no paragraph
/// style to stop it — a long transcript excerpt then lays out two lines inside a 28 pt row and
/// draws straight over its neighbour (GUI pass 2026-09-11). `usesSingleLineMode` also pins the
/// intrinsic height, so the row cannot grow behind the table's back.
@MainActor
private func singleLine(_ label: NSTextField, truncating: NSLineBreakMode = .byTruncatingTail) -> NSTextField {
    label.usesSingleLineMode = true
    label.maximumNumberOfLines = 1
    label.cell?.wraps = false
    label.cell?.isScrollable = false
    label.lineBreakMode = truncating
    return label
}

@MainActor
private func trailingLabel(_ text: String, theme: Theme) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Theme.Fonts.mono(theme.fontMono.detail)
    label.textColor = theme.foregroundDim.nsColor
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    label.setContentHuggingPriority(.required, for: .horizontal)
    return singleLine(label, truncating: .byClipping)
}

@MainActor
private func mono(_ text: String, theme: Theme) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Theme.Fonts.mono(theme.fontMono.detail)
    label.textColor = theme.foregroundMuted.nsColor
    return singleLine(label)
}

/// Lays a row out as `[leading…] title … trailing`, all vertically centred.
@MainActor
private func layOut(_ row: NSView, _ views: [NSView], trailing: NSView, leading: CGFloat = 12) {
    var previous: NSView?
    for view in views + [trailing] {
        view.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(view)
        view.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
        if let previous {
            view.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 9).isActive = true
        } else {
            view.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: leading).isActive = true
        }
        previous = view
    }
    trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12).isActive = true
}

// MARK: - Session

/// `● Fix websocket reconnect   Aira · ⎇ main            ↵ open`
final class SearchSessionRowView: NSTableCellView {
    init(result: PaletteResult, state: AppState, theme: Theme) {
        super.init(frame: .zero)

        let dot = StatusDotView()
        let session = result.item.sessionID.flatMap { state.sessions[$0] }
        dot.dot.configure(status: session.map(SidebarRowAdapter.status(of:)) ?? .idle, theme: theme)
        dot.setContentHuggingPriority(.required, for: .horizontal)

        let title = singleLine(
            NSTextField(labelWithAttributedString: Self.titleString(result, theme: theme)))

        let detail = mono(Self.detailString(result, in: state), theme: theme)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        layOut(self, [dot, title, detail], trailing: trailingLabel("\u{21B5} open", theme: theme))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The title with the query's characters marked, exactly as 2c.6 draws it. A hit that came
    /// from another field leaves the title plain — the trailer explains the row instead.
    static func titleString(_ result: PaletteResult, theme: Theme) -> NSAttributedString {
        SearchHighlight.string(
            result.item.title,
            ranges: result.titleRanges,
            font: Theme.Fonts.ui(theme.fontUI.title, weight: .medium),
            color: theme.foreground.nsColor,
            theme: theme)
    }

    /// `Aira · ⎇ main` — the group and the branch, which is what 2c.6 puts after the title.
    static func detailString(_ result: PaletteResult, in state: AppState) -> String {
        var parts: [String] = []
        if let groupID = result.item.groupID, let group = state.groups[groupID], !group.name.isEmpty {
            parts.append(group.name)
        }
        if let id = result.item.sessionID, let branch = state.sessions[id]?.live?.git?.branch,
            !branch.isEmpty
        {
            parts.append("\u{2387} \(branch)")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Transcript

/// `Fix websocket reconnect   ✳ the websocket client drops…        turn 9 · 1h`
final class SearchTranscriptRowView: NSTableCellView {
    init(hit: TranscriptRow, theme: Theme) {
        super.init(frame: .zero)

        let session = singleLine(NSTextField(labelWithString: hit.sessionTitle))
        session.font = Theme.Fonts.ui(theme.fontUI.caption)
        session.textColor = theme.foregroundMuted.nsColor
        // 2c.6 gives the session column a fixed 150 pt so the excerpts line up.
        session.translatesAutoresizingMaskIntoConstraints = false
        session.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let excerpt = singleLine(
            NSTextField(labelWithAttributedString: Self.excerptString(hit, theme: theme)))
        excerpt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        layOut(
            self, [session, excerpt],
            trailing: trailingLabel(Self.trailingText(hit), theme: theme))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The kind glyph, then the collapsed line with the match marked.
    static func excerptString(_ hit: TranscriptRow, theme: Theme) -> NSAttributedString {
        let prefix = hit.kind.glyph + " "
        let text = prefix + hit.excerpt
        let shifted = hit.matchRanges.map { range -> Range<String.Index> in
            let lower = text.index(
                text.startIndex,
                offsetBy: prefix.count + hit.excerpt.distance(from: hit.excerpt.startIndex, to: range.lowerBound))
            let upper = text.index(
                lower, offsetBy: hit.excerpt.distance(from: range.lowerBound, to: range.upperBound))
            return lower..<upper
        }
        return SearchHighlight.string(
            text,
            ranges: shifted,
            font: Theme.Fonts.mono(theme.fontMono.statusBar),
            color: theme.foregroundMuted.nsColor,
            theme: theme)
    }

    /// `turn 9 · 1h`. The age is the sidebar's own short form, and is dropped when unknown.
    static func trailingText(_ hit: TranscriptRow, now: Date = Date()) -> String {
        var parts = ["turn \(hit.turn)"]
        if let at = hit.at { parts.append(age(from: at, now: now)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func age(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Changed file

/// `core-invest   M src/Api/PositionAuditService.cs                        ↵ open`
final class SearchFileRowView: NSTableCellView {
    init(hit: FileRow, theme: Theme) {
        super.init(frame: .zero)

        let session = singleLine(NSTextField(labelWithString: hit.sessionTitle))
        session.font = Theme.Fonts.ui(theme.fontUI.caption)
        session.textColor = theme.foregroundMuted.nsColor
        session.translatesAutoresizingMaskIntoConstraints = false
        session.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let status = singleLine(NSTextField(labelWithString: hit.status))
        status.font = Theme.Fonts.mono(theme.fontMono.detail, weight: .semibold)
        status.textColor = theme.foregroundDim.nsColor
        status.setContentHuggingPriority(.required, for: .horizontal)

        // A long path is more useful at its tail (the file name) than at its head.
        let path = singleLine(
            NSTextField(labelWithAttributedString: Self.pathString(hit, theme: theme)),
            truncating: .byTruncatingHead)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        layOut(self, [session, status, path], trailing: trailingLabel("\u{21B5} open", theme: theme))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func pathString(_ hit: FileRow, theme: Theme) -> NSAttributedString {
        SearchHighlight.string(
            hit.path,
            ranges: hit.matchRanges,
            font: Theme.Fonts.mono(theme.fontMono.statusBar),
            color: theme.foregroundMuted.nsColor,
            theme: theme)
    }
}

// MARK: - Action

/// `＋ New session in Aira with prompt "websocket…"                            ⌘↵`
final class SearchActionRowView: NSTableCellView {
    init(action: SearchAction, theme: Theme) {
        super.init(frame: .zero)
        let title = singleLine(NSTextField(labelWithString: action.title))
        title.font = Theme.Fonts.ui(theme.fontUI.title)
        title.textColor = theme.accent.nsColor
        layOut(self, [title], trailing: trailingLabel(action.trailing, theme: theme))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - Chip bar

/// `All · Sessions · Transcripts · Files changed` and the `in: … ▾` filter (2c.6's top strip).
final class SearchChipBarView: NSView {
    static let height: CGFloat = 34

    var onSelectScope: ((SearchScope) -> Void)?

    private var theme: Theme
    private let stack = NSStackView()
    private let filterLabel = NSTextField(labelWithString: "")
    private var chips: [SearchScope: NSButton] = [:]

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for scope in SearchScope.allCases {
            let chip = NSButton(title: scope.chipTitle, target: self, action: #selector(chipClicked(_:)))
            chip.isBordered = false
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 5
            chip.font = Theme.Fonts.ui(theme.fontUI.caption, weight: .semibold)
            chip.tag = SearchScope.allCases.firstIndex(of: scope) ?? 0
            chips[scope] = chip
            stack.addArrangedSubview(chip)
        }

        filterLabel.font = Theme.Fonts.ui(theme.fontUI.caption)
        filterLabel.textColor = theme.foregroundDim.nsColor
        filterLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            filterLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            filterLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            filterLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: stack.trailingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(scope: SearchScope, filterTitle: String, theme: Theme) {
        self.theme = theme
        for (chipScope, chip) in chips {
            let selected = chipScope == scope
            chip.layer?.backgroundColor =
                (selected ? theme.accent.nsColor : theme.foregroundDim.nsColor.withAlphaComponent(0.10))
                .cgColor
            chip.attributedTitle = NSAttributedString(
                string: chipScope.chipTitle,
                attributes: [
                    .font: Theme.Fonts.ui(theme.fontUI.caption, weight: selected ? .semibold : .regular),
                    .foregroundColor: selected
                        ? theme.accentText.nsColor : theme.foregroundMuted.nsColor,
                ])
        }
        filterLabel.stringValue = "in: \(filterTitle) \u{25BE}"
        filterLabel.textColor = theme.foregroundDim.nsColor
    }

    @objc private func chipClicked(_ sender: NSButton) {
        let all = SearchScope.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        onSelectScope?(all[sender.tag])
    }
}

// MARK: - Footer

/// `↑↓ navigate · ↵ open at hit · tab filter scope · esc close` (2c.6's bottom strip).
final class SearchFooterView: NSView {
    static let height: CGFloat = 28

    private let label = NSTextField(labelWithString: "")

    init(theme: Theme) {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
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

    static let hints = [
        "\u{2191}\u{2193} navigate", "\u{21B5} open at hit", "tab filter scope", "esc close",
    ]
}
