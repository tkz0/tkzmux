// StatusBarView.swift — the 30 pt strip along the bottom of the main window.
//
// design.md → App architecture → Status bar:
//   `⎇ branch` · `WT` · model badge · `+142 −38 · 12 files` · `↑0 ↓2` · ports · `Context 62%` ·
//   `Usage 5% · resets 4d 12h`
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
// all five presets work. Real data arrives in M4.2.

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

    /// The segment's text with no styling; used for the accessibility value and by tests.
    var plainText: String {
        switch self {
        case .runs(let runs): runs.map(\.text).joined()
        case .pill(let text, _, _): text
        }
    }

    /// Every colour the segment paints text with, in order. Lets a test assert that `+142` really
    /// uses the `diffAdd` token rather than something that merely looks green.
    var colors: [RGB] {
        switch self {
        case .runs(let runs): runs.map(\.color)
        case .pill(_, let fg, let bg): [fg, bg]
        }
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

    /// Turns the model into the ordered list of segments the design specifies. Pure and
    /// synchronous — the whole content decision lives here, `draw` only places it.
    static func segments(for model: StatusBarModel, theme: Theme) -> [StatusSegment] {
        var out: [StatusSegment] = []

        if let branch = model.branch, !branch.isEmpty {
            out.append(.runs([
                StatusRun(text: "\u{2387} ", color: theme.foregroundDim),   // ⎇
                StatusRun(text: branch, color: theme.foreground),
            ]))
        }

        if model.isWorktree == true {
            out.append(.pill(text: "WT", foreground: theme.wtText, background: theme.wtBackground))
        }

        if let name = model.modelName, !name.isEmpty {
            // No dedicated badge token exists; `border` is the design's low-alpha overlay and is
            // defined for every preset (see DESIGN.MD DELTA in the ticket report).
            out.append(.pill(text: name, foreground: theme.foregroundMuted, background: theme.border))
        }

        var diff: [StatusRun] = []
        if let added = model.diffAdded {
            diff.append(StatusRun(text: "+\(added)", color: theme.diffAdd))
        }
        if let removed = model.diffRemoved {
            if !diff.isEmpty { diff.append(StatusRun(text: " ", color: theme.foregroundDim)) }
            diff.append(StatusRun(text: "\u{2212}\(removed)", color: theme.diffRemove))  // −
        }
        if !diff.isEmpty { out.append(.runs(diff)) }

        if let files = model.diffFiles {
            out.append(.runs([
                StatusRun(text: "\(files) file\(files == 1 ? "" : "s")", color: theme.foregroundMuted)
            ]))
        }

        var sync: [StatusRun] = []
        if let ahead = model.ahead {
            sync.append(StatusRun(text: "\u{2191}\(ahead)", color: theme.foregroundMuted))  // ↑
        }
        if let behind = model.behind {
            if !sync.isEmpty { sync.append(StatusRun(text: " ", color: theme.foregroundMuted)) }
            sync.append(StatusRun(text: "\u{2193}\(behind)", color: theme.foregroundMuted))  // ↓
        }
        if !sync.isEmpty { out.append(.runs(sync)) }

        if let ports = model.ports, !ports.isEmpty {
            let text = ports.sorted().map { ":\($0)" }.joined(separator: " ")
            out.append(.runs([StatusRun(text: text, color: theme.foregroundMuted)]))
        }

        if let context = model.contextPercent {
            out.append(.runs([
                StatusRun(text: "Context ", color: theme.foregroundDim),
                StatusRun(text: "\(context)%", color: theme.foreground),
            ]))
        }

        if let usage = model.usagePercent {
            out.append(.runs([
                StatusRun(text: "Usage ", color: theme.foregroundDim),
                StatusRun(text: "\(usage)%", color: theme.foreground),
            ]))
        }

        if let resets = model.usageResetsIn {
            out.append(.runs([
                StatusRun(
                    text: "resets \(StatusBarModel.formatResetsIn(resets))",
                    color: theme.foregroundDim
                )
            ]))
        }

        return out
    }

    /// The segments this view currently shows. Convenience for tests and for wave 2's window.
    var currentSegments: [StatusSegment] { Self.segments(for: model, theme: theme) }

    // MARK: Drawing

    private var textFont: NSFont { Theme.Fonts.mono(theme.fontMono.statusBar) }
    private var pillFont: NSFont { Theme.Fonts.mono(theme.fontMono.detail, weight: .medium) }

    public override func draw(_ dirtyRect: NSRect) {
        theme.statusBarBackground.nsColor.setFill()
        bounds.fill()

        // Hairline along the top edge, same token as the sidebar/title-bar separators.
        theme.border.nsColor.setFill()
        let hairline = 1 / max(window?.backingScaleFactor ?? 2, 1)
        NSRect(x: 0, y: bounds.maxY - hairline, width: bounds.width, height: hairline).fill()

        let segments = currentSegments
        guard !segments.isEmpty else { return }

        let maxX = bounds.maxX - Self.insetX
        var x = bounds.minX + Self.insetX
        let separatorString = attributed(
            [StatusRun(text: Self.separator, color: theme.foregroundDim)],
            font: textFont
        )
        let separatorWidth = separatorString.size().width

        for (index, segment) in segments.enumerated() {
            let sepWidth = index == 0 ? 0 : separatorWidth
            let width = self.width(of: segment)
            let remaining = maxX - x - sepWidth

            if width <= remaining {
                if index > 0 {
                    drawText(separatorString, at: x, width: separatorWidth)
                    x += separatorWidth
                }
                draw(segment, at: x)
                x += width
                continue
            }

            // Does not fit. Truncate the tail of an inline segment when there is enough room to
            // stay readable; otherwise stop cleanly, with no dangling separator.
            if case .runs(let runs) = segment, remaining >= Self.minTruncatedWidth {
                if index > 0 {
                    drawText(separatorString, at: x, width: separatorWidth)
                    x += separatorWidth
                }
                drawText(attributed(runs, font: textFont, truncating: true), at: x, width: remaining)
            }
            return
        }
    }

    private func width(of segment: StatusSegment) -> CGFloat {
        switch segment {
        case .runs(let runs):
            attributed(runs, font: textFont).size().width
        case .pill(let text, let fg, _):
            attributed([StatusRun(text: text, color: fg)], font: pillFont).size().width
                + 2 * Self.pillPadX
        }
    }

    private func draw(_ segment: StatusSegment, at x: CGFloat) {
        switch segment {
        case .runs(let runs):
            let string = attributed(runs, font: textFont)
            drawText(string, at: x, width: string.size().width)

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
