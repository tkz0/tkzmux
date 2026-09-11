// PromptCardView.swift — the card's contents (design 2c.5 · FIRST PROMPT).
//
// Two labelled blocks — the first prompt in the mono face, Claude's recap in the UI face — with a
// pill over each, a meta line beside the pill, a divider between them and two Copy buttons under
// them. Both text views are selectable so a fragment can be copied by hand, and each is capped at
// `maxTextHeight` so a pasted-spec prompt scrolls rather than pushing the card off the screen.
//
// Pure layout: it holds no session and reads no store. `setSummary` is the whole input, and the
// strings it derives (`metaLine`, `recapMetaLine`, `age`) are static so they can be asserted
// without a window.

import AppKit
import ClaudeBridge
import TkzCore

@MainActor
final class PromptCardView: NSView {

    enum Metrics {
        static let width: CGFloat = 640
        static let padding: CGFloat = 20
        static let verticalPadding: CGFloat = 18
        static let rowSpacing: CGFloat = 10
        static let cornerRadius: CGFloat = 12
        /// The most either text block grows before it scrolls. The controller lowers it on a short
        /// window so both blocks and the buttons always fit.
        static let defaultMaxTextHeight: CGFloat = 220
        static let minTextHeight: CGFloat = 22
    }

    /// One transcript hit, when the card was opened from the search overlay (design 2c.6's
    /// "↵ jumps into the transcript at the hit"). It takes over the card's *top* block — the one
    /// that normally holds the first prompt — and leaves the recap below it, so the card answers
    /// both "what did I search for" and "what is this conversation".
    struct HitContent: Equatable {
        let turn: Int
        /// The kind glyph the overlay's row used, so the two read as the same line.
        let glyph: String
        let text: String
        let at: Date?
        let sessionTitle: String
    }

    /// What the card is showing, kept so a theme change can re-render it.
    private(set) var summary: TranscriptSummary?
    private(set) var hit: HitContent?
    private(set) var isLoading = true
    /// Peeking: shown by a scroll, not by the chord, with the keyboard and the mouse still the
    /// terminal's. The buttons are inert and the hint says how to pin the card instead of "esc".
    private(set) var isPeeking = false

    /// The text the Copy buttons put on the pasteboard; `nil` when there is nothing to copy.
    var promptText: String? { hit?.text ?? summary?.firstPrompt }
    var recapText: String? { summary?.recap }

    var onCopyPrompt: (() -> Void)?
    var onCopyRecap: (() -> Void)?
    var onClose: (() -> Void)?

    var maxTextHeight: CGFloat = Metrics.defaultMaxTextHeight {
        didSet { if maxTextHeight != oldValue { relayoutText() } }
    }

    private var theme: Theme
    private let promptPill = PillView()
    private let promptMeta = NSTextField(labelWithString: "")
    private let closeHint = NSButton(title: "", target: nil, action: nil)
    private let promptScroll = NSScrollView()
    private let promptView = NSTextView()
    private let divider = NSView()
    private let recapPill = PillView()
    private let recapMeta = NSTextField(labelWithString: "")
    private let recapScroll = NSScrollView()
    private let recapView = NSTextView()
    private let copyPromptButton = NSButton(title: "Copy prompt", target: nil, action: nil)
    private let copyRecapButton = NSButton(title: "Copy recap", target: nil, action: nil)
    private var promptHeight: NSLayoutConstraint!
    private var recapHeight: NSLayoutConstraint!

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 300))
        translatesAutoresizingMaskIntoConstraints = false
        build()
        applyTheme()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    // MARK: Input

    /// `nil` while the first read is still running — the card says "Loading…" rather than "No
    /// prompt", which would be a lie for the half-second the read takes.
    func setSummary(_ summary: TranscriptSummary?, now: Date = Date()) {
        self.summary = summary
        isLoading = summary == nil
        render(now: now)
    }

    func setTheme(_ theme: Theme) {
        guard theme != self.theme else { return }
        self.theme = theme
        applyTheme()
        render()
    }

    /// The search overlay's hit, or `nil` to go back to the first prompt.
    func setHit(_ hit: HitContent?, now: Date = Date()) {
        guard hit != self.hit else { return }
        self.hit = hit
        render(now: now)
    }

    func setPeeking(_ peeking: Bool) {
        guard peeking != isPeeking else { return }
        isPeeking = peeking
        applyTheme()
        render()
    }

    // MARK: Derived strings

    /// "Started Tue 14:02 · 2 h ago", or just the relative half when there is no timestamp.
    static func metaLine(startedAt: Date?, now: Date) -> String {
        guard let startedAt else { return "" }
        return "Started \(Self.clock(startedAt, now: now)) \u{00B7} \(Self.age(from: startedAt, to: now))"
    }

    /// "Fix websocket reconnect · 1 h ago" — which conversation the hit came out of, and when.
    static func hitMetaLine(_ hit: HitContent, now: Date) -> String {
        guard let at = hit.at else { return hit.sessionTitle }
        return "\(hit.sessionTitle) \u{00B7} \(Self.age(from: at, to: now))"
    }

    /// The recap's provenance, so a hook fallback is never passed off as Claude's own summary.
    static func recapMetaLine(_ summary: TranscriptSummary, now: Date) -> String {
        let source: String
        switch summary.recapSource {
        case .awaySummary: source = "Claude\u{2019}s own summary"
        case .stopMessage: source = "Claude\u{2019}s last message"
        case .assistantText: source = "Claude\u{2019}s last reply"
        case nil: return "Claude\u{2019}s own summary \u{00B7} updates as the session runs"
        }
        guard let at = summary.recapAt else { return source }
        return "\(source) \u{00B7} \(Self.age(from: at, to: now))"
    }

    /// "just now", "4 min ago", "2 h ago", "yesterday", "3 d ago".
    static func age(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        case ..<172_800: return "yesterday"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }

    /// "14:02" today, "Tue 14:02" this week, "10 Sep 14:02" otherwise.
    static func clock(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let format: Date.FormatStyle
        if calendar.isDate(date, inSameDayAs: now) {
            format = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        } else if now.timeIntervalSince(date) < 6 * 86_400 {
            format = Date.FormatStyle().weekday(.abbreviated)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        } else {
            format = Date.FormatStyle().day().month(.abbreviated)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        }
        return date.formatted(format)
    }

    // MARK: Building

    private func build() {
        for pill in [promptPill, recapPill] { pill.translatesAutoresizingMaskIntoConstraints = false }
        promptPill.text = "FIRST PROMPT"
        recapPill.text = "RECAP"

        for meta in [promptMeta, recapMeta] {
            meta.translatesAutoresizingMaskIntoConstraints = false
            meta.lineBreakMode = .byTruncatingTail
            meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        closeHint.translatesAutoresizingMaskIntoConstraints = false
        closeHint.isBordered = false
        closeHint.bezelStyle = .inline
        closeHint.setButtonType(.momentaryChange)
        closeHint.target = self
        closeHint.action = #selector(closeTapped)
        closeHint.setContentHuggingPriority(.required, for: .horizontal)
        closeHint.setContentCompressionResistancePriority(.required, for: .horizontal)

        for (scroll, textView) in [(promptScroll, promptView), (recapScroll, recapView)] {
            configure(textView: textView)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.verticalScrollElasticity = .none
        }

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true

        for button in [copyPromptButton, copyRecapButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = Theme.Fonts.ui(theme.fontUI.body)
            button.target = self
        }
        copyPromptButton.action = #selector(copyPromptTapped)
        copyRecapButton.action = #selector(copyRecapTapped)

        for view in [promptPill, promptMeta, closeHint, promptScroll, divider,
                     recapPill, recapMeta, recapScroll, copyPromptButton, copyRecapButton] {
            addSubview(view)
        }

        let p = Metrics.padding
        let v = Metrics.verticalPadding
        let s = Metrics.rowSpacing
        promptHeight = promptScroll.heightAnchor.constraint(equalToConstant: Metrics.minTextHeight)
        recapHeight = recapScroll.heightAnchor.constraint(equalToConstant: Metrics.minTextHeight)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),

            promptPill.topAnchor.constraint(equalTo: topAnchor, constant: v),
            promptPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            promptMeta.centerYAnchor.constraint(equalTo: promptPill.centerYAnchor),
            promptMeta.leadingAnchor.constraint(equalTo: promptPill.trailingAnchor, constant: 8),
            promptMeta.trailingAnchor.constraint(lessThanOrEqualTo: closeHint.leadingAnchor, constant: -8),
            closeHint.centerYAnchor.constraint(equalTo: promptPill.centerYAnchor),
            closeHint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),

            promptScroll.topAnchor.constraint(equalTo: promptPill.bottomAnchor, constant: s),
            promptScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            promptScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            promptHeight,

            divider.topAnchor.constraint(equalTo: promptScroll.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            divider.heightAnchor.constraint(equalToConstant: 1),

            recapPill.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: s),
            recapPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            recapMeta.centerYAnchor.constraint(equalTo: recapPill.centerYAnchor),
            recapMeta.leadingAnchor.constraint(equalTo: recapPill.trailingAnchor, constant: 8),
            recapMeta.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -p),

            recapScroll.topAnchor.constraint(equalTo: recapPill.bottomAnchor, constant: 6),
            recapScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            recapScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            recapHeight,

            copyPromptButton.topAnchor.constraint(equalTo: recapScroll.bottomAnchor, constant: 14),
            copyPromptButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            copyRecapButton.centerYAnchor.constraint(equalTo: copyPromptButton.centerYAnchor),
            copyRecapButton.leadingAnchor.constraint(equalTo: copyPromptButton.trailingAnchor, constant: 8),
            copyPromptButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -v),
        ])
    }

    private func configure(textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    private func applyTheme() {
        let accent = theme.accent
        promptPill.configure(
            font: Theme.Fonts.ui(9, weight: .bold),
            foreground: accent,
            background: RGB(r: accent.r, g: accent.g, b: accent.b, a: 0.22))
        let green = theme.working
        recapPill.configure(
            font: Theme.Fonts.ui(9, weight: .bold),
            foreground: green,
            background: RGB(r: green.r, g: green.g, b: green.b, a: 0.14))
        for meta in [promptMeta, recapMeta] {
            meta.font = Theme.Fonts.ui(theme.fontUI.caption)
            meta.textColor = theme.foregroundDim.nsColor
        }
        closeHint.attributedTitle = NSAttributedString(
            string: isPeeking ? "\u{2325}\u{2318}P to pin" : "esc \u{2715}",
            attributes: [
                .font: Theme.Fonts.ui(theme.fontUI.caption),
                .foregroundColor: theme.foregroundDim.nsColor,
            ])
        promptView.font = Theme.Fonts.mono(theme.fontUI.title)
        promptView.textColor = theme.foreground.nsColor
        recapView.font = Theme.Fonts.ui(theme.fontUI.title)
        recapView.textColor = theme.foregroundMuted.nsColor
        divider.layer?.backgroundColor = theme.border.cgColor
        for button in [copyPromptButton, copyRecapButton] { button.font = Theme.Fonts.ui(theme.fontUI.body) }
    }

    // MARK: Rendering

    private func render(now: Date = Date()) {
        let summary = summary ?? TranscriptSummary()
        recapMeta.stringValue = Self.recapMetaLine(summary, now: now)

        let promptPlaceholder = isLoading ? "Loading\u{2026}" : "No prompt yet"
        let recapPlaceholder = isLoading ? "Loading\u{2026}" : "No recap yet"
        if let hit {
            promptPill.text = "TURN \(hit.turn)"
            promptMeta.stringValue = Self.hitMetaLine(hit, now: now)
            set(promptView, text: hit.glyph + " " + hit.text, placeholder: promptPlaceholder,
                font: Theme.Fonts.mono(theme.fontUI.title), color: theme.foreground)
        } else {
            promptPill.text = "FIRST PROMPT"
            promptMeta.stringValue = Self.metaLine(startedAt: summary.firstPromptAt, now: now)
            set(promptView, text: summary.firstPrompt, placeholder: promptPlaceholder,
                font: Theme.Fonts.mono(theme.fontUI.title), color: theme.foreground)
        }
        copyPromptButton.title = hit == nil ? "Copy prompt" : "Copy line"
        set(recapView, text: summary.recap, placeholder: recapPlaceholder,
            font: Theme.Fonts.ui(theme.fontUI.title), color: theme.foregroundMuted)
        copyPromptButton.isEnabled = !isPeeking && promptText != nil
        copyRecapButton.isEnabled = !isPeeking && summary.recap != nil
        relayoutText()
    }

    private func set(_ textView: NSTextView, text: String?, placeholder: String, font: NSFont, color: RGB) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        let string = text ?? placeholder
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: (text == nil ? theme.foregroundDim : color).nsColor,
            .paragraphStyle: paragraph,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// Sizes each scroll view to its text, capped at `maxTextHeight`. The text views track the
    /// scroll width, so the measurement uses the same width the layout will.
    private func relayoutText() {
        let width = Metrics.width - Metrics.padding * 2
        promptHeight.constant = Self.height(of: promptView, width: width, cap: maxTextHeight)
        recapHeight.constant = Self.height(of: recapView, width: width, cap: maxTextHeight)
    }

    private static func height(of textView: NSTextView, width: CGFloat, cap: CGFloat) -> CGFloat {
        guard let storage = textView.textStorage, let container = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return Metrics.minTextHeight }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.frame.size.width = width
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        _ = storage
        return min(cap, max(Metrics.minTextHeight, used.rounded(.up) + 2))
    }

    // MARK: Actions

    @objc private func copyPromptTapped() { onCopyPrompt?() }
    @objc private func copyRecapTapped() { onCopyRecap?() }
    @objc private func closeTapped() { onClose?() }

    // MARK: Test access

    var promptTextViewForTesting: NSTextView { promptView }
    var recapTextViewForTesting: NSTextView { recapView }
    var promptMetaForTesting: String { promptMeta.stringValue }
    var recapMetaForTesting: String { recapMeta.stringValue }
    var copyPromptButtonForTesting: NSButton { copyPromptButton }
    var copyRecapButtonForTesting: NSButton { copyRecapButton }
}

/// A small uppercase tag with a tinted background — the design's `FIRST PROMPT` / `RECAP` pills.
/// A view rather than the sidebar's `SidebarBadgeLayer` because it takes part in Auto Layout.
final class PillView: NSView {
    private let label = NSTextField(labelWithString: "")
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 2

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize() }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    func configure(font: NSFont, foreground: RGB, background: RGB) {
        label.font = font
        label.textColor = foreground.nsColor
        // Letterspaced like the artboard's `letter-spacing: 0.06em`.
        label.attributedStringValue = NSAttributedString(
            string: label.stringValue,
            attributes: [.font: font, .foregroundColor: foreground.nsColor, .kern: font.pointSize * 0.06])
        layer?.backgroundColor = background.cgColor
        invalidateIntrinsicContentSize()
    }
}
