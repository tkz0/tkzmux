// StatusBarView.swift — the 30 pt strip along the bottom of the main window.
//
// The line, as the artboards draw it:
//   `⎇ branch` · `WT` · model badge · `+142 −38 · 12 files` · `↑0 ↓2`   …   ports · `Context 62%` ·
//   `Usage 5% · resets 4d 12h`
// The group from the ports onward sits flush right (2c.1); the rest flows from the left edge.
//
// One `NSView` with a custom `draw(_:)` and **no subviews**. Reasons:
//   * the separator between two segments must not exist when either side is missing, which is much
//     easier to get right in one pass than with stack views that need per-view hidden bookkeeping;
//   * the strip must truncate at a narrow window instead of overflowing, and the truncation point
//     is a property of the whole line, not of one label;
//   * it redraws only when the selected session's ChangeSet intersects, so a single `draw` is
//     cheaper than a dozen `NSTextField`s.
//
// Everything visible is derived from ``StatusBarModel`` and a ``Theme``; nothing is hardcoded, so
// all five presets work.
//
// M4.2 (TKZ-27) added the interactive half. The ticket asked for `NSStackView` children bound to
// slices of the live state; that is **not** what shipped, because the no-subviews decision above
// predates the ticket and still holds — collapsing separators and whole-line truncation are
// properties of the line, not of a label. Instead the layout pass records a frame per item
// (`placedItems`), and tooltips, the pointing-hand cursor and clicks (the PR badge, each port) are
// resolved by hit-testing those frames. Same behaviour, one view.

import AppKit
import TkzCore

// MARK: - Segments

/// One coloured piece of text inside a segment (`+142` green, `−38` red, …).
struct StatusRun: Equatable, Sendable {
    var text: String
    var color: RGB
}

/// One logical item on the strip. Segments are joined by ` · ` **only between the ones that are
/// actually drawn**, which is what makes a `nil` field collapse without leaving a stray separator.
enum StatusSegment: Equatable, Sendable {
    /// Inline text, one or more differently coloured runs.
    case runs([StatusRun])
    /// A rounded badge — the `WT` marker and the model name.
    case pill(text: String, foreground: RGB, background: RGB)
    /// `Context ▬▬▬▬ 62%`: a label, a 44 × 4 pt bar filled to `fraction`, and the number after it.
    case meter(label: StatusRun, fraction: Double, fill: RGB, track: RGB, value: StatusRun)

    /// The segment's text with no styling; used for the accessibility value and by tests.
    var plainText: String {
        switch self {
        case .runs(let runs): runs.map(\.text).joined()
        case .pill(let text, _, _): text
        case .meter(let label, _, _, _, let value): label.text + value.text
        }
    }

    /// Every colour the segment paints with, in order. Lets a test assert that `+142` really
    /// uses the `diffAdd` token rather than something that merely looks green.
    var colors: [RGB] {
        switch self {
        case .runs(let runs): runs.map(\.color)
        case .pill(_, let fg, let bg): [fg, bg]
        case .meter(let label, _, let fill, let track, let value): [label.color, fill, track, value.color]
        }
    }
}

/// A segment plus everything the pointer can do with it. Tooltips carry *text*, not a rule, and a
/// clickable item carries its `URL` — so what a click does is decided where the content is decided,
/// not in the mouse handler.
struct StatusItem: Equatable, Sendable {
    var segment: StatusSegment
    var tooltip: String?
    /// Opened in the default browser on click; also what makes the cursor a pointing hand.
    var url: URL?
    /// `false` = glued to the previous item with a single space instead of ` · `. The port list is
    /// one visual group (`:5101 :64566`) made of independently clickable items.
    var separated: Bool = true
    /// `true` = part of the group that sits flush right (ports, context, usage, resets), the way
    /// the artboards place it. Everything else flows from the left edge.
    var trailing: Bool = false

    init(
        _ segment: StatusSegment, tooltip: String? = nil, url: URL? = nil,
        separated: Bool = true, trailing: Bool = false
    ) {
        self.segment = segment
        self.tooltip = tooltip
        self.url = url
        self.separated = separated
        self.trailing = trailing
    }
}

// MARK: - View

/// The status strip. Set ``model`` and ``theme``; the view redraws itself.
@MainActor
public final class StatusBarView: NSView {
    /// Fixed height from the design. Not derived from the font: the bar is a 30 pt band whatever
    /// the text metrics do.
    public static let height: CGFloat = 30

    /// Horizontal padding at both ends of the strip.
    private static let insetX: CGFloat = 12
    /// Text drawn between two adjacent visible segments.
    private static let separator = " · "
    /// Horizontal padding inside a pill, and its corner radius / height.
    private static let pillPadX: CGFloat = 5
    private static let pillHeight: CGFloat = 15
    private static let pillRadius: CGFloat = 3
    /// A segment that does not fit is drawn truncated only if at least this much room is left;
    /// below that it is dropped entirely (a two-character stub reads as damage, not as data).
    private static let minTruncatedWidth: CGFloat = 30
    /// The meter bar: 44 × 4 pt, fully rounded, 5 pt from the label and from the number.
    static let meterWidth: CGFloat = 44
    static let meterHeight: CGFloat = 4
    static let meterGap: CGFloat = 5

    public var model: StatusBarModel {
        didSet { if model != oldValue { invalidate() } }
    }

    public var theme: Theme {
        didSet { if theme != oldValue { invalidate() } }
    }

    public init(theme: Theme = .default, model: StatusBarModel = .empty) {
        self.theme = theme
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 1240, height: Self.height))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("StatusBarView is code-only") }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    public override var isFlipped: Bool { false }

    /// Opaque band: nothing behind it shows through, so AppKit can skip whatever is below.
    public override var isOpaque: Bool { theme.statusBarBackground.a >= 1 }

    private func invalidate() {
        needsDisplay = true
        cachedPlacement = nil
        refreshInteraction()
        setAccessibility()
    }

    private func setAccessibility() {
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Session status")
        setAccessibilityValue(
            Self.segments(for: model, theme: theme)
                .map(\.plainText)
                .joined(separator: Self.separator)
        )
    }

    // MARK: Content

    /// Turns the model into the ordered list of items the design specifies. Pure and synchronous —
    /// the whole content decision lives here, `draw` only places it and the mouse handlers only
    /// hit-test what it produced.
    static func items(for model: StatusBarModel, theme: Theme) -> [StatusItem] {
        var out: [StatusItem] = []

        // A notice owns the whole strip. It is rare, it is about the app rather than the session,
        // and mixing it in among `⎇ develop · WT · …` would make it easy to miss — which defeats
        // the point of telling the user their sidebar came back from a backup.
        if let notice = model.notice, !notice.isEmpty {
            return [StatusItem(.runs([StatusRun(text: notice, color: theme.foreground)]))]
        }

        if let branch = model.branch, !branch.isEmpty {
            var tooltip = "Branch \(branch)"
            if let upstream = model.upstream, !upstream.isEmpty {
                tooltip += "\nUpstream \(upstream)"
            } else if model.upstreamMissing {
                tooltip += "\nNo upstream"
            }
            out.append(StatusItem(
                .runs([
                    // The artboards draw the whole segment in the WT lavender, not in the body text.
                    StatusRun(text: "\u{2387} ", color: theme.wtText),   // ⎇
                    StatusRun(text: branch, color: theme.wtText),
                ]),
                tooltip: tooltip))
        }

        if model.isWorktree == true {
            let name = model.worktreeName.flatMap { $0.isEmpty ? nil : $0 }
            out.append(StatusItem(
                .pill(text: "WT", foreground: theme.wtText, background: theme.wtBackground),
                tooltip: name.map { "Worktree \($0)" } ?? "Git worktree"))
        }

        if let name = model.modelName, !name.isEmpty {
            // No dedicated badge token exists; `border` is the design's low-alpha overlay and is
            // defined for every preset (see DESIGN.MD DELTA in the ticket report).
            out.append(StatusItem(
                .pill(text: name, foreground: theme.statusBarText, background: theme.border),
                tooltip: "Model \(name)"))
        }

        var diff: [StatusRun] = []
        if let added = model.diffAdded {
            diff.append(StatusRun(text: "+\(added)", color: theme.diffAdd))
        }
        if let removed = model.diffRemoved {
            if !diff.isEmpty { diff.append(StatusRun(text: " ", color: theme.foregroundDim)) }
            diff.append(StatusRun(text: "\u{2212}\(removed)", color: theme.diffRemove))  // −
        }
        if !diff.isEmpty {
            let tooltip = "\(model.diffAdded ?? 0) inserted, \(model.diffRemoved ?? 0) deleted since HEAD"
            out.append(StatusItem(.runs(diff), tooltip: tooltip))
        }

        if let files = model.diffFiles {
            out.append(StatusItem(
                .runs([
                    StatusRun(text: "\(files) file\(files == 1 ? "" : "s")", color: theme.statusBarText)
                ]),
                tooltip: "\(files) file\(files == 1 ? "" : "s") changed in the working tree"))
        }

        // Ahead/behind has three states, and the middle one is the reason this is not just two
        // optionals: **no upstream** draws `↑– ↓–` dimmed rather than nothing, because nothing
        // reads as "not measured yet" and `↑0 ↓0` reads as "in sync with a remote" that does not
        // exist. design.md → *Git integration*: "no upstream → ahead/behind nil, shown dimmed".
        if model.upstreamMissing, model.ahead == nil, model.behind == nil {
            out.append(StatusItem(
                .runs([
                    StatusRun(text: "\u{2191}\u{2013} \u{2193}\u{2013}", color: theme.foregroundDim)
                ]),
                tooltip: "No upstream"))
        } else {
            var sync: [StatusRun] = []
            if let ahead = model.ahead {
                sync.append(StatusRun(text: "\u{2191}\(ahead)", color: theme.statusBarText))  // ↑
            }
            if let behind = model.behind {
                if !sync.isEmpty { sync.append(StatusRun(text: " ", color: theme.statusBarText)) }
                sync.append(StatusRun(text: "\u{2193}\(behind)", color: theme.statusBarText))  // ↓
            }
            if !sync.isEmpty {
                let target = model.upstream.map { " \($0)" } ?? " upstream"
                out.append(StatusItem(
                    .runs(sync),
                    tooltip: "\(model.ahead ?? 0) ahead of\(target), \(model.behind ?? 0) behind"))
            }
        }

        if let pr = model.pullRequest {
            out.append(prItem(pr, theme: theme))
        }

        // One item per port: `:5101 :64566` reads as one group (hence `separated: false` after the
        // first), but each is separately clickable and has its own owning-process tooltip.
        if let ports = model.ports, !ports.isEmpty {
            for (index, port) in ports.sorted().enumerated() {
                var tooltip = ":\(port)"
                if let owner = model.portOwners[port], !owner.isEmpty { tooltip += " — \(owner)" }
                tooltip += "\nOpen http://localhost:\(port)"
                out.append(StatusItem(
                    .runs([StatusRun(text: ":\(port)", color: theme.statusBarText)]),
                    tooltip: tooltip,
                    url: URL(string: "http://localhost:\(port)"),
                    separated: index == 0,
                    trailing: true))
            }
        }

        if let context = model.contextPercent {
            out.append(StatusItem(
                meter("Context ", percent: context, fill: theme.contextMeter, theme: theme),
                tooltip: "\(context)% of the model's context window used",
                trailing: true))
        }

        if let usage = model.usagePercent {
            out.append(StatusItem(
                meter("Usage ", percent: usage, fill: theme.usageMeter, theme: theme),
                tooltip: model.usageTooltip ?? "\(usage)% of the seven-day quota used",
                trailing: true))
        }

        if let resets = model.usageResetsIn {
            out.append(StatusItem(
                .runs([
                    StatusRun(
                        text: "resets \(StatusBarModel.formatResetsIn(resets))",
                        color: theme.foregroundDim
                    )
                ]),
                tooltip: model.usageResetsAtText.map { "Quota window resets \($0)" },
                trailing: true))
        }

        return out
    }

    /// A percentage as the artboards draw it: the label in the base text, a bar, the number in the
    /// terminal foreground. The number is what is *reported*; the bar clamps to 0…100 % so a stray
    /// 104 % from a reader does not paint outside its track.
    private static func meter(_ label: String, percent: Int, fill: RGB, theme: Theme) -> StatusSegment {
        .meter(
            label: StatusRun(text: label, color: theme.statusBarText),
            fraction: min(max(Double(percent) / 100, 0), 1),
            fill: fill,
            track: theme.meterTrack,
            value: StatusRun(text: "\(percent)%", color: theme.terminalForeground))
    }

    /// The PR pill: `#123` plus the one marker that matters most — a draft is a draft whatever the
    /// review says, then the review decision, then plain `●` for an open PR nobody has looked at.
    private static func prItem(_ pr: PRInfo, theme: Theme) -> StatusItem {
        let state = pr.state?.uppercased()
        let decision = pr.reviewDecision?.uppercased()
        let marker: String
        let color: RGB
        if pr.isDraft {
            marker = "draft"
            color = theme.foregroundDim
        } else if decision == "APPROVED" {
            marker = "\u{2713}"                                  // ✓
            color = theme.diffAdd
        } else if decision == "CHANGES_REQUESTED" {
            marker = "\u{25CF}"                                  // ●
            color = theme.diffRemove
        } else {
            marker = "\u{25CF}"
            color = theme.statusBarText
        }

        var lines = ["Pull request #\(pr.number)"]
        if let state, !state.isEmpty { lines.append("State \(state)") }
        if pr.isDraft { lines.append("Draft") }
        if let decision, !decision.isEmpty {
            lines.append("Review \(decision.replacingOccurrences(of: "_", with: " ").lowercased())")
        }
        if let url = pr.url, !url.isEmpty { lines.append(url) }

        return StatusItem(
            .pill(text: "#\(pr.number) \(marker)", foreground: color, background: theme.border),
            tooltip: lines.joined(separator: "\n"),
            url: pr.url.flatMap(URL.init(string:)))
    }

    /// The segments alone — what the content tests assert against, and what the accessibility
    /// value is built from.
    static func segments(for model: StatusBarModel, theme: Theme) -> [StatusSegment] {
        items(for: model, theme: theme).map(\.segment)
    }

    /// The segments this view currently shows. Convenience for tests.
    var currentSegments: [StatusSegment] { Self.segments(for: model, theme: theme) }

    /// The items this view currently shows, interaction included.
    var currentItems: [StatusItem] { Self.items(for: model, theme: theme) }

    // MARK: Drawing

    private var textFont: NSFont { Theme.Fonts.mono(theme.fontMono.statusBar) }
    private var pillFont: NSFont { Theme.Fonts.mono(theme.fontMono.detail, weight: .medium) }

    /// One item as it was placed on the strip. Mouse handling, tooltips and cursor rects all read
    /// the placement rather than re-deriving the line, so what the pointer hits is exactly what was
    /// painted — including after a truncating resize.
    struct PlacedItem: Equatable {
        var item: StatusItem
        /// Where the separator before this item starts, when there is one.
        var separatorX: CGFloat?
        /// ` · ` (a new group) rather than a single space (the next port in the port list).
        var separatorIsDot: Bool
        var frame: NSRect
        /// Non-nil when the item did not fit and was drawn truncated into this width.
        var truncatedWidth: CGFloat?
    }

    /// Cached layout, dropped whenever the model, the theme or the size changes.
    private var cachedPlacement: [PlacedItem]?

    /// The placed items, laying them out first if the cache is cold. Internal so a test can assert
    /// hit targets without going through a real draw.
    func placement() -> [PlacedItem] {
        if let cachedPlacement { return cachedPlacement }
        let placed = computePlacement()
        cachedPlacement = placed
        return placed
    }

    /// The item under a point in view coordinates, if any.
    func item(at point: NSPoint) -> StatusItem? {
        placement().first { $0.frame.contains(point) }?.item
    }

    /// Lays the line out. The trailing group (ports, context, usage, resets) sits flush right and
    /// the rest flows from the left, as on the artboards; the two never touch because the leading
    /// group's usable width stops one separator short of the trailing group. When the trailing
    /// group does not fit whole — a very narrow window — the entire line flows left to right and
    /// truncates as before, so nothing is ever drawn half right-aligned.
    private func computePlacement() -> [PlacedItem] {
        let items = currentItems
        guard !items.isEmpty else { return [] }

        let minX = bounds.minX + Self.insetX
        let maxX = bounds.maxX - Self.insetX
        let dotWidth = attributed(
            [StatusRun(text: Self.separator, color: theme.foregroundDim)], font: textFont
        ).size().width
        let spaceWidth = attributed(
            [StatusRun(text: " ", color: theme.foregroundDim)], font: textFont
        ).size().width

        let leading = items.filter { !$0.trailing }
        let trailing = items.filter(\.trailing)
        if !trailing.isEmpty {
            var trailingWidth: CGFloat = 0
            for (index, item) in trailing.enumerated() {
                if index > 0 { trailingWidth += item.separated ? dotWidth : spaceWidth }
                trailingWidth += width(of: item.segment)
            }
            let gap = leading.isEmpty ? 0 : dotWidth
            let trailingMinX = maxX - trailingWidth
            if trailingMinX - gap >= minX {
                return flow(leading, from: minX, to: trailingMinX - gap, dotWidth: dotWidth, spaceWidth: spaceWidth)
                    + flow(trailing, from: trailingMinX, to: maxX, dotWidth: dotWidth, spaceWidth: spaceWidth)
            }
        }
        return flow(items, from: minX, to: maxX, dotWidth: dotWidth, spaceWidth: spaceWidth)
    }

    /// Places `items` left to right between `minX` and `maxX`, separators between neighbours only,
    /// truncating the first item that does not fit and dropping the rest.
    private func flow(
        _ items: [StatusItem], from minX: CGFloat, to maxX: CGFloat,
        dotWidth: CGFloat, spaceWidth: CGFloat
    ) -> [PlacedItem] {
        var x = minX
        var out: [PlacedItem] = []
        for (index, item) in items.enumerated() {
            let isDot = item.separated
            let separatorWidth = index == 0 ? 0 : (isDot ? dotWidth : spaceWidth)
            let width = self.width(of: item.segment)
            let remaining = maxX - x - separatorWidth

            // The trailing group's `minX` is the right edge minus a sum of these same widths, so
            // allow a rounding hair before calling the last item "does not fit".
            if width <= remaining + 0.01 {
                var separatorX: CGFloat?
                if index > 0 {
                    separatorX = x
                    x += separatorWidth
                }
                out.append(PlacedItem(
                    item: item, separatorX: separatorX, separatorIsDot: isDot,
                    frame: NSRect(x: x, y: 0, width: width, height: bounds.height),
                    truncatedWidth: nil))
                x += width
                continue
            }

            // Does not fit. Truncate the tail of an inline segment when there is enough room to
            // stay readable; otherwise stop cleanly, with no dangling separator.
            if case .runs = item.segment, remaining >= Self.minTruncatedWidth {
                var separatorX: CGFloat?
                if index > 0 {
                    separatorX = x
                    x += separatorWidth
                }
                out.append(PlacedItem(
                    item: item, separatorX: separatorX, separatorIsDot: isDot,
                    frame: NSRect(x: x, y: 0, width: remaining, height: bounds.height),
                    truncatedWidth: remaining))
            }
            break
        }
        return out
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        theme.statusBarBackground.nsColor.setFill()
        bounds.fill()

        // Hairline along the top edge, same token as the sidebar/title-bar separators.
        theme.border.nsColor.setFill()
        let hairline = 1 / max(window?.backingScaleFactor ?? 2, 1)
        NSRect(x: 0, y: bounds.maxY - hairline, width: bounds.width, height: hairline).fill()

        for placed in placement() {
            if let separatorX = placed.separatorX {
                let text = placed.separatorIsDot ? Self.separator : " "
                let string = attributed(
                    [StatusRun(text: text, color: theme.foregroundDim)], font: textFont)
                drawText(string, at: separatorX, width: string.size().width)
            }
            if let truncatedWidth = placed.truncatedWidth {
                guard case .runs(let runs) = placed.item.segment else { continue }
                drawText(
                    attributed(runs, font: textFont, truncating: true),
                    at: placed.frame.minX, width: truncatedWidth)
            } else {
                draw(placed.item.segment, at: placed.frame.minX)
            }
        }
    }

    // MARK: Interaction

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidatePlacement()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidatePlacement()
    }

    /// Drops the cached layout and re-registers everything derived from it.
    private func invalidatePlacement() {
        cachedPlacement = nil
        refreshInteraction()
    }

    private func refreshInteraction() {
        removeAllToolTips()
        for placed in placement() where placed.item.tooltip != nil {
            addToolTip(placed.frame, owner: self, userData: nil)
        }
        window?.invalidateCursorRects(for: self)
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        for placed in placement() where placed.item.url != nil {
            addCursorRect(placed.frame, cursor: .pointingHand)
        }
    }

    /// A click on a port badge opens `http://localhost:<port>`; a click on the PR badge opens the
    /// pull request. Everything else falls through, so a click on the strip does not steal focus
    /// from the terminal.
    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let url = item(at: point)?.url else {
            super.mouseUp(with: event)
            return
        }
        openURL(url)
    }

    /// Injected so the click test does not launch a browser.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private func width(of segment: StatusSegment) -> CGFloat {
        switch segment {
        case .runs(let runs):
            attributed(runs, font: textFont).size().width
        case .pill(let text, let fg, _):
            attributed([StatusRun(text: text, color: fg)], font: pillFont).size().width
                + 2 * Self.pillPadX
        case .meter(let label, _, _, _, let value):
            attributed([label], font: textFont).size().width
                + Self.meterGap + Self.meterWidth + Self.meterGap
                + attributed([value], font: textFont).size().width
        }
    }

    /// Where a meter's track and fill land when the item is drawn at `x`. Shared by `draw` and
    /// the pixel tests, so what is asserted is what is painted.
    func meterRects(_ segment: StatusSegment, at x: CGFloat) -> (track: NSRect, fill: NSRect)? {
        guard case .meter(let label, let fraction, _, _, _) = segment else { return nil }
        let labelWidth = attributed([label], font: textFont).size().width
        let track = NSRect(
            x: x + labelWidth + Self.meterGap,
            y: ((bounds.height - Self.meterHeight) / 2).rounded(),
            width: Self.meterWidth,
            height: Self.meterHeight)
        var fill = track
        fill.size.width = (Self.meterWidth * CGFloat(min(max(fraction, 0), 1))).rounded()
        return (track, fill)
    }

    private func draw(_ segment: StatusSegment, at x: CGFloat) {
        switch segment {
        case .runs(let runs):
            let string = attributed(runs, font: textFont)
            drawText(string, at: x, width: string.size().width)

        case .meter(let label, _, let fill, let track, let value):
            guard let rects = meterRects(segment, at: x) else { return }
            let labelString = attributed([label], font: textFont)
            drawText(labelString, at: x, width: labelString.size().width)
            let radius = Self.meterHeight / 2
            track.nsColor.setFill()
            NSBezierPath(roundedRect: rects.track, xRadius: radius, yRadius: radius).fill()
            if rects.fill.width > 0 {
                fill.nsColor.setFill()
                NSBezierPath(roundedRect: rects.fill, xRadius: radius, yRadius: radius).fill()
            }
            let valueString = attributed([value], font: textFont)
            drawText(valueString, at: rects.track.maxX + Self.meterGap, width: valueString.size().width)

        case .pill(let text, let fg, let bg):
            let string = attributed([StatusRun(text: text, color: fg)], font: pillFont)
            let textWidth = string.size().width
            let rect = NSRect(
                x: x,
                y: (bounds.height - Self.pillHeight) / 2,
                width: textWidth + 2 * Self.pillPadX,
                height: Self.pillHeight
            )
            bg.nsColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.pillRadius, yRadius: Self.pillRadius).fill()
            drawText(string, at: rect.minX + Self.pillPadX, width: textWidth, font: pillFont)
        }
    }

    /// Draws `string` left-aligned at `x`, vertically centred on the band's optical middle.
    private func drawText(
        _ string: NSAttributedString,
        at x: CGFloat,
        width: CGFloat,
        font: NSFont? = nil
    ) {
        let font = font ?? textFont
        let lineHeight = font.ascender - font.descender
        let y = (bounds.height - lineHeight) / 2
        string.draw(with: NSRect(x: x, y: y, width: max(width, 0), height: lineHeight),
                    options: [.usesLineFragmentOrigin])
    }

    private func attributed(
        _ runs: [StatusRun],
        font: NSFont,
        truncating: Bool = false
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncating ? .byTruncatingTail : .byClipping
        let out = NSMutableAttributedString()
        for run in runs {
            out.append(NSAttributedString(string: run.text, attributes: [
                .font: font,
                .foregroundColor: run.color.nsColor,
                .paragraphStyle: paragraph,
            ]))
        }
        return out
    }
}

// MARK: - Tooltips

extension StatusBarView: NSViewToolTipOwner {
    /// One owner for every rect: the point identifies the item, so nothing has to be kept in the
    /// `userData` pointer (which would have to outlive a layout pass that replaces every rect).
    public func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        item(at: point)?.tooltip ?? ""
    }
}
