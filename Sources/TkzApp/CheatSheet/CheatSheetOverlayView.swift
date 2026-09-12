// CheatSheetOverlayView.swift — the card the ⌘-hold shows.
//
// **Passive by construction.** It never becomes first responder and never hit-tests, because the
// keystrokes that dismiss it — the ⌘ release, or ⌘+something — have to keep reaching the terminal
// and the menu exactly as they did before. An overlay that took focus would break the very gesture
// that closes it.
//
// The blur is on the card only, not the whole window: a full-window `NSVisualEffectView` sitting
// over a continuously redrawing `CAMetalLayer` is a real cost for something that is on screen for a
// couple of seconds at a time.
import AppKit
import TkzCore

final class CheatSheetOverlayView: NSView {

    private let card = NSVisualEffectView()
    private let columns = NSStackView()
    private var theme: Theme

    /// Layout metrics. The sidebar keeps its own in `SidebarMetrics`; these are local because
    /// nothing else lays out a cheat sheet.
    private enum Metrics {
        static let cardPadding: CGFloat = 24
        static let columnSpacing: CGFloat = 36
        static let sectionSpacing: CGFloat = 18
        static let rowSpacing: CGFloat = 5
        static let keyTitleSpacing: CGFloat = 14
        static let cornerRadius: CGFloat = 12
        /// Sections are dealt into this many columns, balanced by row count.
        static let columnCount = 2
    }

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        // A wash rather than a heavy scrim: `Theme` has no dim token and adding one would mean
        // touching both presets, so this reuses `border` the way `StatusBarView` documents
        // doing ("`border` is the design's low-alpha overlay").
        layer?.backgroundColor = theme.border.cgColor
        isHidden = true
        alphaValue = 0

        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = Metrics.cornerRadius
        card.layer?.borderWidth = 1
        card.layer?.borderColor = theme.border.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = Metrics.columnSpacing
        columns.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(columns)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),

            columns.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.cardPadding),
            columns.leadingAnchor.constraint(
                equalTo: card.leadingAnchor, constant: Metrics.cardPadding),
            columns.trailingAnchor.constraint(
                equalTo: card.trailingAnchor, constant: -Metrics.cardPadding),
            columns.bottomAnchor.constraint(
                equalTo: card.bottomAnchor, constant: -Metrics.cardPadding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    // MARK: Passivity

    override var acceptsFirstResponder: Bool { false }

    /// Clicks fall straight through to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Content

    func setTheme(_ theme: Theme) {
        guard theme != self.theme else { return }
        self.theme = theme
        layer?.backgroundColor = theme.border.cgColor
        card.layer?.borderColor = theme.border.cgColor
    }

    /// Rebuilds the card. Called on every show, so an edited `AppState.shortcuts` is picked up
    /// without a relaunch.
    func setSections(_ sections: [CheatSheetSection]) {
        for view in columns.arrangedSubviews {
            columns.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for group in deal(sections) {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Metrics.sectionSpacing
            for section in group { column.addArrangedSubview(view(for: section)) }
            columns.addArrangedSubview(column)
        }
    }

    /// Deals sections into columns, keeping the running row counts as even as possible so the card
    /// stays roughly square rather than one tall column beside a stub.
    private func deal(_ sections: [CheatSheetSection]) -> [[CheatSheetSection]] {
        var groups = [[CheatSheetSection]](repeating: [], count: Metrics.columnCount)
        var weights = [Int](repeating: 0, count: Metrics.columnCount)
        for section in sections {
            let target = weights.enumerated().min { $0.element < $1.element }?.offset ?? 0
            groups[target].append(section)
            // The header costs about a row's worth of height.
            weights[target] += section.rows.count + 1
        }
        return groups.filter { !$0.isEmpty }
    }

    private func view(for section: CheatSheetSection) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.rowSpacing

        let header = NSTextField(labelWithString: section.title.uppercased())
        header.font = Theme.Fonts.ui(theme.fontUI.caption, weight: .semibold)
        header.textColor = theme.foregroundMuted.nsColor
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(Metrics.rowSpacing + 3, after: header)

        let grid = NSGridView(views: section.rows.map { row in
            let keys = NSTextField(labelWithString: row.keys)
            // The system face, not the mono one the palette uses for its trailing hint: ⌘⇧⌥⌃ are
            // SF glyphs, and JetBrains Mono at `fontMono.detail` renders them small and muddy
            // beside a 12.5 pt title. Right-aligned, so the modifiers stack into a column.
            keys.font = Theme.Fonts.ui(theme.fontUI.title, weight: .medium)
            keys.textColor = theme.accent.nsColor
            keys.alignment = .right

            let title = NSTextField(labelWithString: row.title)
            title.font = Theme.Fonts.ui(theme.fontUI.title)
            title.textColor = theme.foreground.nsColor
            return [keys, title]
        })
        grid.rowSpacing = Metrics.rowSpacing
        grid.columnSpacing = Metrics.keyTitleSpacing
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        stack.addArrangedSubview(grid)

        return stack
    }

    // MARK: Show / hide

    func show() {
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // The completion handler is `@Sendable`, but AppKit runs it on the main thread — the
            // same assumption every `DispatchSourceTimer` in this app makes.
            MainActor.assumeIsolated {
                // A `show()` that landed mid-fade must win, so only hide if we are still at zero.
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            }
        }
    }
}
