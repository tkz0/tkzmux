// StatusBarView.swift — the 36 pt strip along the bottom of the main window.
//
// The line, as the artboards draw it:
//   `⎇ branch` · `WT` · `FABLE 5.1` · `+142 −38 · 12 files` · `↑0 ↓2` · `⇅ #418`   …   ports ·
//   `Context 62%` · `Usage 5% · 41%`
// The group from the ports onward sits flush right (2c.1); the rest flows from the left edge.
//
// 2c.1 (and its light twin 4a) were redrawn on 2026-09-12: the band grew 30 → 36 pt, the mono text
// 10.5 → 12 pt and the PR glyph 11 → 13 pt, the model badge became an *outlined* uppercase pill
// instead of a filled one, and `Usage` became **two stacked bars** — the five-hour session quota
// over the rolling seven-day one — which retired the separate `resets 4d 12h` segment into the
// meter's tooltip. The amber/red steps above 70 % / 90 % are the one thing here that no artboard
// draws; see ``meterFill(percent:base:theme:)``.
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
// both presets work.
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

/// The glyphs a ``StatusIcon`` can draw. Drawn as paths in `StatusBarView`, not loaded: the app
/// bundles no assets, and SF Symbols has no pull-request icon — `arrow.triangle.pull` is Apple's
/// "pull" arrow, which at 11 pt reads as a broken stub rather than as GitHub's badge.
enum StatusGlyph: Equatable, Sendable {
    /// GitHub's `git-pull-request` octicon: two rings on the left joined by a line, and on the
    /// right a ring with a line rising from it that turns into an arrowhead pointing left.
    case pullRequest
    /// GitHub's `git-merge` octicon: the same left column, with a curve sweeping from the top ring
    /// down and right into a ring at mid-height.
    case merge
}

/// A small glyph drawn inline before a run of text — the PR badge's pull-request / merge icon.
struct StatusIcon: Equatable, Sendable {
    var glyph: StatusGlyph
    var color: RGB
}

/// One bar of a ``StatusSegment/meter``. A meter carries a list so `Context` (one bar) and
/// `Usage` (session over weekly) are the same segment kind drawn at two different bar heights,
/// rather than two near-identical cases with two near-identical draw paths.
struct MeterBar: Equatable, Sendable {
    /// 0…1, already clamped by whoever built it.
    var fraction: Double
    var fill: RGB
    var track: RGB
}

/// One logical item on the strip. Segments are joined by ` · ` **only between the ones that are
/// actually drawn**, which is what makes a `nil` field collapse without leaving a stray separator.
enum StatusSegment: Equatable, Sendable {
    /// Inline text, one or more differently coloured runs.
    case runs([StatusRun])
    /// A rounded badge. `WT` is filled (`background`, no `border`); the model badge is outlined
    /// (`border` in the text colour over the bare strip) and tracked out, the way 2c.1 draws it.
    case pill(text: String, foreground: RGB, background: RGB, border: RGB?, tracking: Double)
    /// `Context ▬▬▬▬ 62%` — one 50 × 4.5 pt bar — or `Usage ▬ / ▬ 5% · 41%`, two 50 × 3.5 pt bars
    /// stacked 2 pt apart. The label comes first, the numbers last.
    case meter(label: StatusRun, bars: [MeterBar], value: [StatusRun])
    /// A glyph and the text after it, 4 pt apart (2c.1: the pull-request glyph and `#418`).
    case iconRuns(icon: StatusIcon, runs: [StatusRun])

    /// The segment's text with no styling; used for the accessibility value and by tests.
    var plainText: String {
        switch self {
        case .runs(let runs): runs.map(\.text).joined()
        case .pill(let text, _, _, _, _): text
        // The label and the numbers are separate runs with only geometry between them, so the
        // space that makes `Context 62%` a sentence has to be put back for VoiceOver and tests.
        case .meter(let label, _, let value): label.text + " " + value.map(\.text).joined()
        case .iconRuns(_, let runs): runs.map(\.text).joined()
        }
    }

    /// Every colour the segment paints with, in order. Lets a test assert that `+142` really
    /// uses the `diffAdd` token rather than something that merely looks green.
    var colors: [RGB] {
        switch self {
        case .runs(let runs): runs.map(\.color)
        case .pill(_, let fg, let bg, let border, _): [fg, bg] + (border.map { [$0] } ?? [])
        case .meter(let label, let bars, let value):
            [label.color] + bars.flatMap { [$0.fill, $0.track] } + value.map(\.color)
        case .iconRuns(let icon, let runs): [icon.color] + runs.map(\.color)
        }
    }

    /// The glyph an `.iconRuns` segment draws; `nil` for every other kind.
    var glyph: StatusGlyph? {
        if case .iconRuns(let icon, _) = self { return icon.glyph }
        return nil
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
    /// Fixed height from the design. Not derived from the font: the bar is a 36 pt band whatever
    /// the text metrics do.
    public static let height: CGFloat = 36

    /// Horizontal padding at both ends of the strip.
    private static let insetX: CGFloat = 15
    /// Text drawn between two adjacent visible segments.
    private static let separator = " · "
    /// Horizontal padding inside a pill, and its corner radius / height.
    private static let pillPadX: CGFloat = 5
    private static let pillHeight: CGFloat = 16
    private static let pillRadius: CGFloat = 3
    /// 2c.1's `letter-spacing:0.03em` on the model badge, in points at the pill's size.
    static let pillTracking: Double = 0.03 * Theme.Fonts.mono.detail
    /// A segment that does not fit is drawn truncated only if at least this much room is left;
    /// below that it is dropped entirely (a two-character stub reads as damage, not as data).
    private static let minTruncatedWidth: CGFloat = 30
    /// The meter bar: 50 pt wide, fully rounded, 5 pt from the label and from the number.
    static let meterWidth: CGFloat = 50
    /// Height of a meter that has the segment to itself (`Context`).
    static let meterHeight: CGFloat = 4.5
    /// Height of each bar, and the space between them, once a meter stacks two (`Usage`).
    static let stackedBarHeight: CGFloat = 3.5
    static let stackedBarGap: CGFloat = 2
    static let meterGap: CGFloat = 5
    /// 2c.1 gives the stacked meter one more point of air on either side of the bars than the
    /// single one, because the taller block needs it to stop crowding the label.
    static let stackedMeterGap: CGFloat = 6
    /// The PR badge's glyph: 13 pt square, 4 pt before the number (2c.1).
    static let iconSize: CGFloat = 13
    static let iconGap: CGFloat = 4

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
                .pill(
                    text: "WT", foreground: theme.wtText, background: theme.wtBackground,
                    border: nil, tracking: 0),
                tooltip: name.map { "Worktree \($0)" } ?? "Git worktree"))
        }

        if let name = model.modelName, !name.isEmpty {
            // 2c.1 draws this one uppercased, tracked out and *outlined in its own text colour*
            // over the bare strip — not filled like `WT`. The two badges sit next to each other,
            // so they have to differ in more than their words.
            out.append(StatusItem(
                .pill(
                    text: name.uppercased(), foreground: theme.statusBarText, background: .clear,
                    border: theme.statusBarText, tracking: Self.pillTracking),
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
                meter("Context", percents: [context], base: theme.contextMeter, theme: theme),
                tooltip: "\(context)% of the model's context window used",
                trailing: true))
        }

        // The two quota windows are one segment: 2c.1 stacks the session bar over the weekly one
        // behind a single `Usage` label. Either may be missing — a fresh account has no five-hour
        // window yet — and then the meter quietly becomes the single bar it used to be.
        let quotas = [("Session", model.sessionUsage), ("Weekly", model.weeklyUsage)]
            .compactMap { name, quota in quota.map { (name: name, quota: $0) } }
        if !quotas.isEmpty {
            var lines = quotas.map { entry -> String in
                var line = "\(entry.name) quota \(entry.quota.percent)%"
                if let resets = entry.quota.resetsIn {
                    line += " · resets \(StatusBarModel.formatResetsIn(resets))"
                }
                if let at = entry.quota.resetsAtText { line += " (\(at))" }
                return line
            }
            if let accounts = model.usageTooltip, !accounts.isEmpty { lines.append(accounts) }
            out.append(StatusItem(
                meter(
                    "Usage", percents: quotas.map(\.quota.percent), base: theme.usageMeter,
                    theme: theme),
                tooltip: lines.joined(separator: "\n"),
                trailing: true))
        }

        return out
    }

    /// A meter as the artboards draw it: the label in the base text, one bar per percentage, and
    /// the numbers in the terminal foreground joined by ` · `. The numbers are what is *reported*;
    /// each bar clamps to 0…100 % so a stray 104 % from a reader does not paint outside its track.
    ///
    /// With two bars the second one — the weekly quota — is carried at half alpha while it is in
    /// the normal band, which is how 2c.1 keeps the pair reading as primary over secondary. Once
    /// it crosses into amber or red it goes back to full strength: a warning that has been faded
    /// out is not a warning.
    private static func meter(
        _ label: String, percents: [Int], base: RGB, theme: Theme
    ) -> StatusSegment {
        let bars = percents.enumerated().map { index, percent -> MeterBar in
            var fill = meterFill(percent: percent, base: base, theme: theme)
            if index > 0, fill == base { fill.a *= 0.5 }
            return MeterBar(
                fraction: min(max(Double(percent) / 100, 0), 1),
                fill: fill,
                track: theme.meterTrack)
        }
        var value: [StatusRun] = []
        for percent in percents {
            if !value.isEmpty {
                value.append(StatusRun(text: " · ", color: theme.statusBarText))
            }
            value.append(StatusRun(text: "\(percent)%", color: theme.terminalForeground))
        }
        return .meter(
            label: StatusRun(text: label, color: theme.statusBarText), bars: bars, value: value)
    }

    /// The colour a bar is filled with at `percent`. **No artboard draws this** — 2c.1 paints
    /// every meter in one colour. Thomas asked for the two steps so that a quota about to run out
    /// is visible from across the room without reading the number: past 70 % the bar turns the
    /// preset's amber, past 90 % its red. Both bounds are exclusive, so exactly 70 % is still
    /// nominal and exactly 90 % is still a warning.
    static func meterFill(percent: Int, base: RGB, theme: Theme) -> RGB {
        if percent > 90 { return theme.meterDanger }
        if percent > 70 { return theme.meterWarn }
        return base
    }

    /// The PR badge as 2c.1 draws it: the pull-request glyph and `#418`, both in one colour that
    /// says what the PR *is* — open (green), merged (purple, and the merge glyph), closed (the
    /// remove red) or a draft (dimmed). The review decision no longer colours the badge; it is in
    /// the tooltip, as is the URL a click opens.
    private static func prItem(_ pr: PRInfo, theme: Theme) -> StatusItem {
        let state = pr.state?.uppercased()
        let decision = pr.reviewDecision?.uppercased()
        let glyph: StatusGlyph
        let color: RGB
        let stateText: String
        switch state {
        case "MERGED":
            glyph = .merge
            color = theme.prMerged
            stateText = "Merged"
        case "CLOSED":
            glyph = .pullRequest
            color = theme.diffRemove
            stateText = "Closed"
        default:
            glyph = .pullRequest
            if pr.isDraft {
                color = theme.foregroundDim
                stateText = "Draft"
            } else {
                color = theme.prOpen
                stateText = "Open"
            }
        }

        var lines = ["Pull request #\(pr.number)", stateText]
        if let decision, !decision.isEmpty {
            lines.append("Review \(decision.replacingOccurrences(of: "_", with: " ").lowercased())")
        }
        if let url = pr.url, !url.isEmpty { lines.append(url) }

        return StatusItem(
            .iconRuns(
                icon: StatusIcon(glyph: glyph, color: color),
                runs: [StatusRun(text: "#\(pr.number)", color: color)]),
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
    private var pillFont: NSFont { Theme.Fonts.mono(theme.fontMono.detail, weight: .semibold) }

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
        case .pill(let text, let fg, _, _, let tracking):
            attributed([StatusRun(text: text, color: fg)], font: pillFont, tracking: tracking)
                .size().width + 2 * Self.pillPadX
        case .meter(let label, let bars, let value):
            attributed([label], font: textFont).size().width
                + 2 * Self.meterGap(barCount: bars.count) + Self.meterWidth
                + attributed(value, font: textFont).size().width
        case .iconRuns(_, let runs):
            Self.iconSize + Self.iconGap + attributed(runs, font: textFont).size().width
        }
    }

    /// The outline of a glyph, laid out on the octicon 16-unit grid and scaled into `rect`. Every
    /// part is a stroke — rings, spines, the arrowhead — in one path, so a single `stroke()` paints
    /// it in one colour with round joins, and it stays crisp at any size and scale factor.
    static func glyphPath(_ glyph: StatusGlyph, in rect: NSRect) -> NSBezierPath {
        let unit = rect.width / 16
        // The view is not flipped: grid `y` grows downward, so map it onto `rect.maxY`.
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * unit, y: rect.maxY - y * unit)
        }
        let ring: CGFloat = 2 * unit           // ring radius, centre to stroke centre
        let path = NSBezierPath()
        path.lineWidth = max(1.5 * unit, 1)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        func addRing(_ x: CGFloat, _ y: CGFloat) {
            path.appendOval(in: NSRect(
                x: p(x, y).x - ring, y: p(x, y).y - ring, width: 2 * ring, height: 2 * ring))
        }

        // Left column, shared: rings at the top and bottom joined by a line.
        addRing(3.5, 3.5)
        addRing(3.5, 12.5)
        path.move(to: p(3.5, 5.5))
        path.line(to: p(3.5, 10.5))

        switch glyph {
        case .pullRequest:
            // Right column: a ring at the bottom, a line up from it that turns left at the top,
            // and the arrowhead pointing back toward the left column.
            addRing(12.5, 12.5)
            path.move(to: p(12.5, 10.5))
            path.line(to: p(12.5, 5))
            path.curve(to: p(11, 3.5), controlPoint1: p(12.5, 4.17), controlPoint2: p(11.83, 3.5))
            path.line(to: p(8.25, 3.5))
            path.move(to: p(10.25, 1.5))
            path.line(to: p(8.25, 3.5))
            path.line(to: p(10.25, 5.5))
        case .merge:
            // A curve leaving the top ring, sweeping down and right into a ring at mid-height.
            addRing(12.5, 8)
            path.move(to: p(3.5, 5.5))
            path.curve(to: p(10.5, 8), controlPoint1: p(3.5, 7.5), controlPoint2: p(6.5, 8))
        }
        return path
    }

    /// Where an `.iconRuns` glyph lands when the item is drawn at `x`: an `iconSize` square on the
    /// band's optical middle.
    func iconRect(at x: CGFloat) -> NSRect {
        NSRect(
            x: x, y: ((bounds.height - Self.iconSize) / 2).rounded(),
            width: Self.iconSize, height: Self.iconSize)
    }

    /// The space between a meter's label and its bars, and between the bars and the numbers.
    /// One bar gets 2c.1's 5 pt, a stacked pair its 6 pt.
    static func meterGap(barCount: Int) -> CGFloat {
        barCount > 1 ? stackedMeterGap : meterGap
    }

    /// Where a meter's bars land when the item is drawn at `x`, top bar first. Shared by `draw`
    /// and the pixel tests, so what is asserted is what is painted. Empty for a non-meter.
    func meterRects(_ segment: StatusSegment, at x: CGFloat) -> [(track: NSRect, fill: NSRect)] {
        guard case .meter(let label, let bars, _) = segment, !bars.isEmpty else { return [] }
        let labelWidth = attributed([label], font: textFont).size().width
        let barHeight = bars.count > 1 ? Self.stackedBarHeight : Self.meterHeight
        let blockHeight =
            CGFloat(bars.count) * barHeight + CGFloat(bars.count - 1) * Self.stackedBarGap
        // Not flipped: `y` grows upward, so the *first* bar is the topmost one.
        var top = ((bounds.height + blockHeight) / 2).rounded()
        var out: [(track: NSRect, fill: NSRect)] = []
        for bar in bars {
            top -= barHeight
            let track = NSRect(
                x: x + labelWidth + Self.meterGap(barCount: bars.count), y: top,
                width: Self.meterWidth, height: barHeight)
            var fill = track
            fill.size.width = (Self.meterWidth * CGFloat(min(max(bar.fraction, 0), 1))).rounded()
            out.append((track, fill))
            top -= Self.stackedBarGap
        }
        return out
    }

    private func draw(_ segment: StatusSegment, at x: CGFloat) {
        switch segment {
        case .runs(let runs):
            let string = attributed(runs, font: textFont)
            drawText(string, at: x, width: string.size().width)

        case .meter(let label, let bars, let value):
            let rects = meterRects(segment, at: x)
            guard let first = rects.first else { return }
            let labelString = attributed([label], font: textFont)
            drawText(labelString, at: x, width: labelString.size().width)
            for (bar, rect) in zip(bars, rects) {
                let radius = rect.track.height / 2
                bar.track.nsColor.setFill()
                NSBezierPath(roundedRect: rect.track, xRadius: radius, yRadius: radius).fill()
                if rect.fill.width > 0 {
                    bar.fill.nsColor.setFill()
                    NSBezierPath(roundedRect: rect.fill, xRadius: radius, yRadius: radius).fill()
                }
            }
            let valueString = attributed(value, font: textFont)
            drawText(
                valueString, at: first.track.maxX + Self.meterGap(barCount: bars.count),
                width: valueString.size().width)

        case .pill(let text, let fg, let bg, let border, let tracking):
            let string = attributed(
                [StatusRun(text: text, color: fg)], font: pillFont, tracking: tracking)
            let textWidth = string.size().width
            let rect = NSRect(
                x: x,
                y: ((bounds.height - Self.pillHeight) / 2).rounded(),
                width: textWidth + 2 * Self.pillPadX,
                height: Self.pillHeight
            )
            let path = NSBezierPath(
                roundedRect: rect, xRadius: Self.pillRadius, yRadius: Self.pillRadius)
            if bg.a > 0 {
                bg.nsColor.setFill()
                path.fill()
            }
            if let border {
                // Inset by the half stroke so the 1 pt outline lands inside `rect`; otherwise the
                // badge measures a point wider than the layout pass reserved for it.
                let outline = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: Self.pillRadius, yRadius: Self.pillRadius)
                outline.lineWidth = 1
                border.nsColor.setStroke()
                outline.stroke()
            }
            drawText(
                string, at: rect.minX + Self.pillPadX, width: textWidth, font: pillFont,
                tracking: tracking)

        case .iconRuns(let icon, let runs):
            icon.color.nsColor.setStroke()
            Self.glyphPath(icon.glyph, in: iconRect(at: x)).stroke()
            let string = attributed(runs, font: textFont)
            drawText(string, at: x + Self.iconSize + Self.iconGap, width: string.size().width)
        }
    }

    /// Draws `string` left-aligned at `x`, vertically centred on the band's optical middle.
    private func drawText(
        _ string: NSAttributedString,
        at x: CGFloat,
        width: CGFloat,
        font: NSFont? = nil,
        tracking: Double = 0
    ) {
        let font = font ?? textFont
        let lineHeight = font.ascender - font.descender
        let y = (bounds.height - lineHeight) / 2
        // Tracking is trailing space on the *last* glyph too, so the run measures one step wider
        // than it paints; shifting by half a step re-centres it inside the pill.
        string.draw(with: NSRect(x: x - tracking / 2, y: y, width: max(width, 0), height: lineHeight),
                    options: [.usesLineFragmentOrigin])
    }

    private func attributed(
        _ runs: [StatusRun],
        font: NSFont,
        truncating: Bool = false,
        tracking: Double = 0
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncating ? .byTruncatingTail : .byClipping
        let out = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: run.color.nsColor,
                .paragraphStyle: paragraph,
            ]
            if tracking != 0 { attributes[.kern] = tracking }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
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
