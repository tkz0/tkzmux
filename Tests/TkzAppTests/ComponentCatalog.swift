// ComponentCatalog — every component WOR-307 S2 commits a golden for, with its fixture model and
// logical size. Each entry is rendered for the 3 presets at 2.0 and 1.6
// (`ComponentSnapshotGoldenTests`), so an entry here is six PNGs and six layout dumps inside the
// 4 MiB share of ADR-0003 §5: sizes are the component's real ones, but the free-standing views
// (overlays, split views) are kept as small as the component allows.
//
// Models come from `AppState.fixture` where the app derives them from the store (sidebar rows,
// group rows, palette results), and are literals where the app gets them from elsewhere (git,
// the transcript, the update checker). Nothing reads the clock: every `now` is `Fixture.now`.
//
// Each render paints a theme token under the component (`Backdrop`), named in the dump's
// `facts["backdrop"]`: the surface the component sits on in the app. For the overlays that sit on
// `.hudWindow` glass the token stands in for the material, which ADR-0003 masks anyway.
//
// Glass sheets and the prompt card are rendered inside an `NSVisualEffectView` styled exactly as
// `GlassSheetPanel.make` and `PromptCardController` style theirs. The real ones are the content
// view of an `NSPanel`; a view in a window would take the window's backing scale, which on a CI
// runner is whatever its virtual display says, so the snapshot builds the same chrome without one.

import AgentBridge
import AppKit
import GitStatus
import Testing
import TkzCore

@testable import TkzApp

// MARK: - A case

/// One golden: a named component with its model and size, renderable at any preset and scale.
/// Plain data with a main-actor render closure, so it can be a Swift Testing argument.
struct ComponentCase: Sendable, CustomTestStringConvertible {
    typealias Snapshot = (png: Data, layout: LayoutDump)

    let name: String
    let render: @MainActor @Sendable (Theme, Double) throws -> Snapshot

    var testDescription: String { name }
}

/// The surface painted under a component, by token name.
enum Backdrop: String, Sendable {
    case sidebarBackground, terminalBackground, windowBackground

    func color(in theme: Theme) -> RGB {
        switch self {
        case .sidebarBackground: theme.sidebarBackground
        case .terminalBackground: theme.terminalBackground
        case .windowBackground: theme.windowBackground
        }
    }
}

/// How a case gets its logical size. Every size is computed on the main actor: most of them read
/// a view's own static metrics, which are main-actor isolated.
enum Sizing<Model>: Sendable {
    /// From the model and theme, without building the view (a row's own height function).
    case computed(@MainActor @Sendable (Model, Theme) -> CGSize)
    /// The view's `fittingSize`, as the panels that host these size themselves.
    case fitting
    /// `fittingSize.height` at a fixed width (a settings card in its column).
    case fittingHeight(width: @MainActor @Sendable () -> Double)

    /// A size that depends on neither the model nor the theme.
    static func fixed(_ size: @escaping @MainActor @Sendable () -> CGSize) -> Self {
        .computed { _, _ in size() }
    }
}

enum CatalogError: Error, CustomStringConvertible {
    case missingFixture(String)

    var description: String {
        switch self {
        case .missingFixture(let what): "AppState.fixture has no \(what)"
        }
    }
}

extension ComponentCase {
    /// The usual case: build the view from the model, size it, render it over `backdrop`.
    ///
    /// `make` gets the final size, or a zero (`.fitting`) or zero-height (`.fittingHeight`) size
    /// while the case is measured; views whose root opts out of autoresizing pin themselves to a
    /// non-zero size with `pin(_:to:)`.
    static func of<Model>(
        _ name: String,
        backdrop: Backdrop?,
        model makeModel: @escaping @MainActor @Sendable () throws -> Model,
        size sizing: Sizing<Model>,
        make: @escaping @MainActor @Sendable (Model, Theme, CGSize) -> NSView,
        facts: (@MainActor @Sendable (Model, NSView) -> [String: String])? = nil
    ) -> ComponentCase {
        ComponentCase(name: name) { theme, scale in
            var paint: (@MainActor (Theme) -> RGB)?
            if let backdrop { paint = { backdrop.color(in: $0) } }
            let component = ComponentSnapshot.Component<Model>(
                id: name,
                make: make,
                backdrop: paint,
                facts: { model, view in
                    var out = facts?(model, view) ?? [:]
                    if let backdrop { out["backdrop"] = backdrop.rawValue }
                    return out
                })
            let model = try makeModel()
            let size: CGSize
            switch sizing {
            case .computed(let compute):
                size = compute(model, theme)
            case .fitting:
                let probe = make(model, theme, .zero)
                probe.layoutSubtreeIfNeeded()
                size = probe.fittingSize
            case .fittingHeight(let widthOf):
                let width = widthOf()
                let probe = make(model, theme, CGSize(width: width, height: 0))
                probe.setFrameSize(NSSize(width: width, height: 1_000))
                probe.layoutSubtreeIfNeeded()
                size = CGSize(width: width, height: probe.fittingSize.height)
            }
            return try ComponentSnapshot.render(id: component, model: model, size: size, theme: theme, scale: scale)
        }
    }
}

/// Pins a view that does not translate its autoresizing mask to `size`, per non-zero axis, so the
/// layout engine agrees with the frame the harness sets.
@MainActor
func pin(_ view: NSView, to size: CGSize) {
    if size.width > 0 { view.widthAnchor.constraint(equalToConstant: size.width).isActive = true }
    if size.height > 0 { view.heightAnchor.constraint(equalToConstant: size.height).isActive = true }
}

// MARK: - Fixtures

@MainActor
enum CatalogFixtures {
    static let state = AppState.fixture

    static func session(_ n: Int) throws -> Session {
        guard let session = state.sessions[Fixture.sessionID(n)] else {
            throw CatalogError.missingFixture("session \(n)")
        }
        return session
    }

    /// Fixture session `n` as the sidebar shows it.
    static func row(_ n: Int) throws -> SidebarSessionRowModel {
        SidebarRowAdapter.sessionModel(try session(n), in: state)
    }

    static func group(_ n: Int) throws -> SidebarGroupRowModel {
        guard let group = state.groups[Fixture.groupID(n)] else { throw CatalogError.missingFixture("group \(n)") }
        return SidebarRowAdapter.groupModel(group, in: state)
    }

    /// The best palette hit of `kind` for `query`, as ⇧⌘P / ⌘F rank it.
    static func paletteResult(_ query: String, kind: PaletteItem.Kind) throws -> PaletteResult {
        let source = PaletteDataSource(state: state, mode: .all)
        guard let result = source.search(query).first(where: { $0.item.kind == kind }) else {
            throw CatalogError.missingFixture("\(kind) palette hit for \"\(query)\"")
        }
        return result
    }

    /// The first occurrence of `needle` in `text`, as a highlight range.
    static func ranges(of needle: String, in text: String) throws -> [Range<String.Index>] {
        guard let range = text.range(of: needle) else { throw CatalogError.missingFixture("\"\(needle)\" in \"\(text)\"") }
        return [range]
    }

    /// The ADR-0003 worked-example row: one detail line, 44 pt, the dot at (30, 18, 7, 7).
    static let plainRow = SidebarSessionRowModel(title: "Fix the rounding bug", branch: "main", status: .working)

    /// `…/reporting · ⎇ feature/reporting-scheduler-rewrite WT` cannot fit 240 pt: a 59 pt row.
    static let wrappingRow = SidebarSessionRowModel(
        title: "Move reporting onto the new scheduler",
        branch: "feature/reporting-scheduler-rewrite",
        directory: "reporting",
        isWorktree: true,
        status: .working)

    static let leaf = TerminalID(uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000301")!)

    static func event(
        _ n: Int, session: Int, kind: ActivityEvent.Kind, minutesAgo: Double, title: String, unread: Bool
    ) -> ActivityEvent {
        ActivityEvent(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", 500 + n))!,
            sessionID: Fixture.sessionID(session),
            kind: kind,
            at: Fixture.now.addingTimeInterval(-minutesAgo * 60),
            sessionTitle: title,
            groupName: "Northwind Trading",
            unread: unread)
    }

    /// The `NSVisualEffectView` a sheet or the prompt card is the content of, styled as
    /// `GlassSheetPanel.make` / `PromptCardController` style theirs, with `content` pinned to its
    /// four edges as their controllers pin it.
    static func glass(_ content: NSView, theme: Theme, cornerRadius: CGFloat, borderAlpha: Double, size: CGSize) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.borderWidth = 1
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let accent = theme.accent
        effect.layer?.borderColor = RGB(r: accent.r, g: accent.g, b: accent.b, a: borderAlpha).cgColor
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        pin(effect, to: size)
        return effect
    }

    /// What a glass chrome's layer was given, for ADR-0003 worked example 1.
    static func chromeFacts(_ view: NSView) -> [String: String] {
        guard let layer = view.layer else { return [:] }
        return [
            "borderWidth": "\(Double(layer.borderWidth))",
            "cornerRadius": "\(Double(layer.cornerRadius))",
        ]
    }
}

// MARK: - The catalog

enum ComponentCatalog {
    /// Every golden, in a stable order. Built statement by statement rather than as one literal so
    /// each case type-checks on its own.
    static let all: [ComponentCase] = {
        var cases: [ComponentCase] = []
        cases += ComponentCatalog.sidebar()
        cases += ComponentCatalog.statusBar()
        cases += ComponentCatalog.panes()
        cases += ComponentCatalog.palette()
        cases += ComponentCatalog.sheets()
        cases += ComponentCatalog.activity()
        cases += ComponentCatalog.settings()
        return cases
    }()

    static var names: [String] { ComponentCatalog.all.map(\.name) }

    // MARK: Sidebar

    static let sidebarWidth = SidebarMetrics.sidebarWidth

    static func sessionRow(
        _ variant: String, width: Double = ComponentCatalog.sidebarWidth, hovered: Bool = false,
        _ model: @escaping @MainActor @Sendable () throws -> SidebarSessionRowModel
    ) -> ComponentCase {
        .of(
            "sidebar.sessionRow.\(variant)", backdrop: .sidebarBackground, model: model,
            size: .computed { model, _ in
                CGSize(width: width, height: SessionRowView.height(for: model, width: width))
            },
            make: { model, theme, size in
                let row = SessionRowView(frame: NSRect(origin: .zero, size: size))
                row.configure(model, theme: theme)
                if hovered { row.setHovered(true) }
                return row
            },
            facts: { model, view in
                ["detailWraps": String(SessionRowView.detailWraps(for: model, width: view.bounds.width))]
            })
    }

    static func groupRow(_ variant: String, _ model: @escaping @MainActor @Sendable () throws -> SidebarGroupRowModel) -> ComponentCase {
        .of(
            "sidebar.groupRow.\(variant)", backdrop: .sidebarBackground, model: model,
            size: .fixed { CGSize(width: ComponentCatalog.sidebarWidth, height: SidebarMetrics.groupRowHeight) },
            make: { model, theme, size in
                let row = GroupRowView(frame: NSRect(origin: .zero, size: size))
                row.configure(model, theme: theme)
                return row
            })
    }

    static func sidebar() -> [ComponentCase] {
        var cases: [ComponentCase] = []
        cases.append(sessionRow("plain") { CatalogFixtures.plainRow })
        cases.append(sessionRow("wrapped", width: SidebarMetrics.sidebarMinWidth) { CatalogFixtures.wrappingRow })
        cases.append(sessionRow("selected") {
            var model = try CatalogFixtures.row(0)
            model.isSelected = true
            return model
        })
        cases.append(sessionRow("hover", hovered: true) {
            var model = try CatalogFixtures.row(9)
            model.isSelected = false
            return model
        })
        // Every badge at once: NEEDS YOU, MUTED, memory, spend, the account chip, and a title long
        // enough to truncate.
        cases.append(sessionRow("badges") {
            var model = try CatalogFixtures.row(1)
            model.isSelected = false
            model.isMuted = true
            model.memoryBadge = "6.2 GB"
            model.spendBadge = "$4.20"
            return model
        })
        cases.append(sessionRow("worktree") {
            var model = try CatalogFixtures.row(2)
            model.isSelected = false
            return model
        })
        cases.append(sessionRow("merged") {
            var model = try CatalogFixtures.row(16)
            model.isSelected = false
            model.isWorktree = true
            model.isMerged = true
            return model
        })
        cases.append(groupRow("expanded") { try CatalogFixtures.group(0) })
        cases.append(groupRow("collapsed") { try CatalogFixtures.group(4) })
        cases.append(.of(
            "sidebar.header", backdrop: .sidebarBackground, model: { true },
            size: .fixed { CGSize(width: ComponentCatalog.sidebarWidth, height: SidebarHeaderView.height) },
            make: { soundOn, theme, size in
                let header = SidebarHeaderView(frame: NSRect(origin: .zero, size: size))
                header.configure(theme: theme)
                header.setSoundOn(soundOn)
                return header
            }))
        cases.append(.of(
            "sidebar.updateCard", backdrop: .sidebarBackground,
            model: {
                UpdateNoticeModel(
                    title: "Update available \u{2014} v9.9.9",
                    runs: [
                        UpdateNoticeModel.Run("Update via Homebrew", action: .upgrade),
                        UpdateNoticeModel.Run("What\u{2019}s new", action: .openReleasePage),
                    ])
            },
            size: .fixed { CGSize(width: ComponentCatalog.sidebarWidth, height: UpdateNoticeView.height) },
            make: { model, theme, size in
                let card = UpdateNoticeView(frame: NSRect(origin: .zero, size: size))
                card.configure(model, theme: theme)
                return card
            }))
        // The app's one empty state: the detail pane with no session selected.
        cases.append(.of(
            "detail.emptyState", backdrop: .terminalBackground, model: { EmptyStateView.noSelectionMessage },
            size: .fixed { CGSize(width: 400, height: 80) },
            make: { message, theme, size in
                let view = EmptyStateView(frame: NSRect(origin: .zero, size: size))
                view.message = message
                view.apply(theme: theme)
                return view
            }))
        return cases
    }

    // MARK: Status bar

    /// The strip, with where each item was placed: the status bar draws its text in `draw(_:)`, so
    /// the dump has no text runs for it and the placement stands in for them.
    static func statusBar(_ variant: String, width: Double, _ model: @escaping @MainActor @Sendable () -> StatusBarModel) -> ComponentCase {
        .of(
            "statusBar.\(variant)", backdrop: nil, model: model,
            size: .fixed { CGSize(width: width, height: StatusBarView.height) },
            make: { model, theme, _ in StatusBarView(theme: theme, model: model) },
            facts: { _, view in
                guard let bar = view as? StatusBarView else { return [:] }
                var out: [String: String] = [:]
                for (index, placed) in bar.placement().enumerated() {
                    var line = "\(placed.item.segment.plainText) x=\(Double(placed.frame.minX)) w=\(Double(placed.frame.width))"
                    if let truncated = placed.truncatedWidth { line += " truncated=\(Double(truncated))" }
                    out[String(format: "placed.%02d", index)] = line
                }
                return out
            })
    }

    /// `StatusBarViewTests.full`, the design's example strip.
    static let fullStrip = StatusBarModel(
        branch: "feature/tkz-18-main-window", isWorktree: true, modelName: "Sonnet 4.5",
        diffAdded: 142, diffRemoved: 38, diffFiles: 12, ahead: 0, behind: 2,
        baseBranch: "origin/main", behindBase: 7, ports: [5173, 3000], contextPercent: 62,
        sessionUsage: .init(percent: 5, resetsIn: .seconds(2 * 3_600)),
        weeklyUsage: .init(percent: 41, resetsIn: .seconds(4 * 86_400 + 12 * 3_600)))

    /// `StatusBarViewTests.hot`: every meter past a threshold.
    static let hotStrip = StatusBarModel(
        branch: "feature/tkz-18-main-window", modelName: "Sonnet 4.5", contextPercent: 88,
        sessionUsage: .init(percent: 74), weeklyUsage: .init(percent: 96))

    static func statusBar() -> [ComponentCase] {
        var cases: [ComponentCase] = []
        // The five `StatusBarViewTests.writesInspectionPngs` cases. Its `wide-light` is
        // `statusBar.wide` in the light preset, which every case is rendered in anyway.
        cases.append(statusBar("wide", width: 1_240) { ComponentCatalog.fullStrip })
        cases.append(statusBar("narrow", width: 480) { ComponentCatalog.fullStrip })
        cases.append(statusBar("ellipsis", width: 150) { ComponentCatalog.fullStrip })
        cases.append(statusBar("hot", width: 1_240) { ComponentCatalog.hotStrip })
        // Every segment kind the full strip does not draw: running agents and shells, an open PR,
        // spend, the in-sync arrows.
        cases.append(statusBar("segments.live", width: 1_240) {
            var model = StatusBarModel(
                branch: "feature/live-reload", isWorktree: true, worktreeName: "live-reload",
                modelName: "Opus 4.1", diffAdded: 12, diffRemoved: 3, diffFiles: 1, ahead: 3, behind: 0,
                upstream: "origin/feature/live-reload",
                pullRequest: PRInfo(number: 418, state: "OPEN", reviewDecision: "APPROVED"),
                ports: [8080], contextPercent: 41,
                sessionUsage: .init(percent: 12), weeklyUsage: .init(percent: 22), spendUSD: 4.2)
            model.runningAgents = 2
            model.runningShells = 1
            return model
        })
        // No upstream (`↑– ↓–`), a merged PR (the merge glyph), one quota window (a single bar).
        cases.append(statusBar("segments.git", width: 720) {
            StatusBarModel(
                branch: "fix/csv-import", upstreamMissing: true,
                pullRequest: PRInfo(number: 402, state: "MERGED"),
                weeklyUsage: .init(percent: 39))
        })
        // A rebase running (the dimmed pill), a closed PR, a shell with no count.
        cases.append(statusBar("segments.rebasing", width: 720) {
            var model = StatusBarModel(
                branch: "feat/hangfire", ahead: 1, behind: 0, baseBranch: "origin/develop", behindBase: 4,
                isRebasing: true, pullRequest: PRInfo(number: 77, state: "CLOSED"))
            model.runningShells = 0
            return model
        })
        cases.append(statusBar("segments.draft", width: 480) {
            StatusBarModel(branch: "spike/graphql", diffFiles: 1, pullRequest: PRInfo(number: 409, isDraft: true))
        })
        cases.append(statusBar("notice", width: 600) {
            StatusBarModel(notice: "Restored sidebar from backup")
        })
        return cases
    }

    // MARK: Panes

    static func paneChrome(_ variant: String, _ model: @escaping @MainActor @Sendable () -> PaneHeaderModel) -> ComponentCase {
        .of(
            "panes.chrome.\(variant)", backdrop: nil, model: model,
            size: .fixed { CGSize(width: 360, height: 96) },
            make: { model, theme, size in
                let content = FocusableStubView(frame: .zero)
                content.wantsLayer = true
                content.layer?.backgroundColor = theme.terminalBackground.cgColor
                let chrome = PaneChromeView(content: content, theme: theme)
                chrome.frame = NSRect(origin: .zero, size: size)
                chrome.setHeaderVisible(true)
                chrome.header.configure(model, theme: theme)
                chrome.setFocused(model.isFocused)
                return chrome
            },
            facts: { _, view in
                guard let chrome = view as? PaneChromeView else { return [:] }
                return ["focusRingWidth": "\(Double(chrome.ringWidth))"]
            })
    }

    /// Two empty panes either side of one divider, the divider at the middle. 247 pt is two
    /// `SplitMetrics.minPaneSide` panes and the 7 pt divider, so the delegate's clamp is a no-op.
    static func split(_ variant: String, axis: PaneAxis, size: CGSize) -> ComponentCase {
        .of(
            "panes.split.\(variant)", backdrop: .terminalBackground, model: { axis },
            size: .fixed { size },
            make: { axis, theme, size in
                let split = PaneSplitView(axis: axis, anchorLeaf: CatalogFixtures.leaf, anchorLevels: 0, theme: theme)
                split.frame = NSRect(origin: .zero, size: size)
                for _ in 0..<2 {
                    let pane = FocusableStubView(frame: .zero)
                    pane.wantsLayer = true
                    pane.layer?.backgroundColor = theme.terminalBackground.cgColor
                    split.addArrangedSubview(pane)
                }
                split.adjustSubviews()
                let extent = axis == .horizontal ? size.width : size.height
                split.setPosition((extent - SplitMetrics.dividerThickness) / 2, ofDividerAt: 0)
                return split
            })
    }

    static func panes() -> [ComponentCase] {
        var cases: [ComponentCase] = []
        cases.append(.of(
            "panes.tabStrip", backdrop: .terminalBackground,
            model: {
                TabStripModel(items: [
                    TabStripItem(title: "claude", terminalCount: 2),
                    TabStripItem(title: "zsh", isSelected: true),
                    TabStripItem(title: "dev server"),
                ])
            },
            size: .fixed { CGSize(width: 600, height: TabStripMetrics.stripHeight) },
            make: { model, theme, size in
                let strip = TabStripView(theme: theme)
                strip.frame = NSRect(origin: .zero, size: size)
                strip.configure(model, theme: theme)
                return strip
            }))
        cases.append(paneChrome("focused") {
            PaneHeaderModel(title: "northwind", path: "~/dev/northwind", status: .working, isFocused: true)
        })
        cases.append(paneChrome("unfocused") {
            PaneHeaderModel(
                title: "pricing-engine", path: "~/dev/northwind/.claude/worktrees/pricing-engine",
                status: .waiting, needsAttention: true, isFocused: false)
        })
        cases.append(split("vertical", axis: .horizontal, size: CGSize(width: 247, height: 96)))
        cases.append(split("horizontal", axis: .vertical, size: CGSize(width: 140, height: 247)))
        cases.append(.of(
            "panes.startupOverlay", backdrop: .terminalBackground,
            model: { PaneStartupModel(command: "claude -w feature") },
            size: .fixed { CGSize(width: 320, height: 160) },
            make: { model, theme, _ in
                let overlay = PaneStartupOverlayView(theme: theme)
                overlay.agentDisplayName = "Claude"
                overlay.show(model, theme: theme)
                return overlay
            }))
        return cases
    }

    // MARK: Palette and search

    /// ⇧⌘P's panel at its 560 pt search width, less the 6 pt scroll inset either side.
    @MainActor static var paletteRowWidth: Double { CommandPaletteController.searchWidth - 12 }

    static func paletteRow(_ name: String, height: Double, _ model: @escaping @MainActor @Sendable () throws -> PaletteResult,
                           make: @escaping @MainActor @Sendable (PaletteResult, Theme, CGSize) -> NSView) -> ComponentCase {
        .of(name, backdrop: .windowBackground, model: model,
            size: .fixed { CGSize(width: ComponentCatalog.paletteRowWidth, height: height) }, make: make)
    }

    static func palette() -> [ComponentCase] {
        var cases: [ComponentCase] = []
        // ⇧⌘P (centred): two-line rows.
        cases.append(paletteRow("palette.row.session", height: 40, { try CatalogFixtures.paletteResult("pricing", kind: .session) }) {
            result, theme, _ in PaletteRowView(result: result, theme: theme)
        })
        cases.append(paletteRow("palette.row.command", height: 40, { try CatalogFixtures.paletteResult("split", kind: .command) }) {
            result, theme, _ in PaletteRowView(result: result, theme: theme)
        })
        // ⌘F (search): one-line rows, the chip bar and the key-hint footer.
        cases.append(paletteRow("search.row.session", height: 30, { try CatalogFixtures.paletteResult("pricing", kind: .session) }) {
            result, theme, _ in SearchSessionRowView(result: result, state: CatalogFixtures.state, theme: theme)
        })
        cases.append(.of(
            "search.row.transcript", backdrop: .windowBackground,
            model: {
                let excerpt = "the websocket client drops the connection after the pricing engine restarts"
                return TranscriptRow(
                    sessionID: Fixture.sessionID(1),
                    sessionTitle: "deal pipeline: replace the valuation service",
                    turn: 9, kind: .assistant, excerpt: excerpt,
                    matchRanges: try CatalogFixtures.ranges(of: "pricing", in: excerpt), at: nil)
            },
            size: .fixed { CGSize(width: ComponentCatalog.paletteRowWidth, height: 28) },
            make: { hit, theme, _ in SearchTranscriptRowView(hit: hit, theme: theme) }))
        cases.append(.of(
            "search.row.file", backdrop: .windowBackground,
            model: {
                let path = "src/Pricing/PricingEngine.swift"
                return FileRow(
                    sessionID: Fixture.sessionID(1), sessionTitle: "deal pipeline", path: path, status: "M",
                    matchRanges: try CatalogFixtures.ranges(of: "Pricing", in: path))
            },
            size: .fixed { CGSize(width: ComponentCatalog.paletteRowWidth, height: 28) },
            make: { hit, theme, _ in SearchFileRowView(hit: hit, theme: theme) }))
        cases.append(.of(
            "search.row.action", backdrop: .windowBackground,
            model: {
                SearchAction(
                    kind: .newSessionWithPrompt,
                    title: "\u{FF0B} New session in Northwind Trading with prompt \u{201C}pricing\u{201D}",
                    trailing: "\u{2318}\u{21A9}", groupID: Fixture.groupID(0), prompt: "pricing")
            },
            size: .fixed { CGSize(width: ComponentCatalog.paletteRowWidth, height: 28) },
            make: { action, theme, _ in SearchActionRowView(action: action, theme: theme) }))
        cases.append(.of(
            "search.chipBar", backdrop: .windowBackground, model: { SearchScope.transcripts },
            size: .fixed { CGSize(width: CommandPaletteController.searchWidth, height: SearchChipBarView.height) },
            make: { scope, theme, _ in
                let bar = SearchChipBarView(theme: theme)
                bar.update(scope: scope, filterTitle: "All groups", theme: theme)
                return bar
            }))
        cases.append(.of(
            "search.footer", backdrop: .windowBackground, model: { () },
            size: .fixed { CGSize(width: CommandPaletteController.searchWidth, height: SearchFooterView.height) },
            make: { _, theme, _ in SearchFooterView(theme: theme) }))
        return cases
    }

    // MARK: Sheets and the prompt card

    static func sheets() -> [ComponentCase] {
        var cases: [ComponentCase] = []
        cases.append(.of(
            "sheets.rebase", backdrop: .terminalBackground,
            model: {
                var model = RebaseSheetModel(baseRef: "origin/main")
                model.behind = 7
                model.shortcut = "\u{2325}\u{2318}R"
                model.phase = .ready
                return model
            },
            size: .fitting,
            make: { model, theme, size in
                let sheet = RebaseSheetView(theme: theme)
                sheet.setModel(model)
                return CatalogFixtures.glass(
                    sheet, theme: theme, cornerRadius: GlassSheetMetrics.cornerRadius, borderAlpha: 0.30, size: size)
            },
            facts: { _, view in CatalogFixtures.chromeFacts(view) }))
        // Unmerged and dirty: the second button and the acknowledgement both show.
        cases.append(.of(
            "sheets.deleteWorktree", backdrop: .terminalBackground,
            model: {
                var model = DeleteWorktreeSheetModel(worktreePath: "/Users/x/dev/northwind/.claude/worktrees/pricing-engine")
                model.home = "/Users/x"
                model.branch = "feat/pricing-engine"
                model.baseRef = "origin/main"
                model.merge = .unmerged(commits: 3, base: "origin/main")
                model.isDirty = true
                model.dirtyFileCount = 2
                model.phase = .ready
                return model
            },
            size: .fitting,
            make: { model, theme, size in
                let sheet = DeleteWorktreeSheetView(theme: theme)
                sheet.setModel(model)
                return CatalogFixtures.glass(
                    sheet, theme: theme, cornerRadius: GlassSheetMetrics.cornerRadius, borderAlpha: 0.30, size: size)
            },
            facts: { _, view in CatalogFixtures.chromeFacts(view) }))
        cases.append(.of(
            "sheets.deleteMerged", backdrop: .terminalBackground,
            model: {
                var model = DeleteMergedWorktreesSheetModel(groupName: "Northwind Trading")
                model.rows = [
                    .init(id: Fixture.sessionID(1), title: "deal pipeline", worktreeName: "pricing-engine",
                          branch: "feat/pricing-engine", statusLine: "PR #401 merged",
                          isChecked: true, isEnabled: true, disabledReason: nil),
                    .init(id: Fixture.sessionID(3), title: "reporting", worktreeName: "reporting",
                          branch: "feat/reporting", statusLine: "Branch fully merged into main",
                          isChecked: true, isEnabled: true, disabledReason: nil),
                    .init(id: Fixture.sessionID(6), title: "elicitation", worktreeName: "audit-log",
                          branch: "feat/audit-log",
                          statusLine: "PR #406 merged \u{2014} uncommitted changes",
                          isChecked: false, isEnabled: false, disabledReason: "Uncommitted changes"),
                ]
                model.phase = .ready
                return model
            },
            size: .fitting,
            make: { model, theme, size in
                let sheet = DeleteMergedWorktreesSheetView(theme: theme)
                sheet.setModel(model)
                return CatalogFixtures.glass(
                    sheet, theme: theme, cornerRadius: GlassSheetMetrics.cornerRadius, borderAlpha: 0.30, size: size)
            },
            facts: { _, view in CatalogFixtures.chromeFacts(view) }))
        // No timestamps, so the meta lines never depend on the clock or the time zone.
        cases.append(.of(
            "prompt.card", backdrop: .terminalBackground,
            model: {
                TranscriptSummary(
                    firstPrompt: "Replace the valuation service with the new pricing engine and keep the old API working.",
                    recap: "Swapped the valuation calls for the pricing engine behind the same API; the integration tests pass.",
                    recapSource: .awaySummary)
            },
            size: .fitting,
            make: { summary, theme, size in
                let card = PromptCardView(theme: theme)
                card.agentDisplayName = "Claude"
                card.setSummary(summary, now: Fixture.now)
                return CatalogFixtures.glass(
                    card, theme: theme, cornerRadius: PromptCardView.Metrics.cornerRadius, borderAlpha: 0.35, size: size)
            },
            facts: { _, view in CatalogFixtures.chromeFacts(view) }))
        return cases
    }

    // MARK: Activity feed and cheat sheet

    /// The feed's 640 pt panel less the 6 pt scroll inset either side.
    @MainActor static var activityRowWidth: Double { ActivityFeedController.width - 12 }

    static func activity() -> [ComponentCase] {
        var cases: [ComponentCase] = []
        cases.append(.of(
            "activity.row.working", backdrop: .windowBackground,
            model: {
                ActivityFeedModel.WorkingRow(
                    sessionID: Fixture.sessionID(0), title: "northwind", groupName: "Northwind Trading",
                    elapsed: "12m", titleRanges: [])
            },
            size: .computed { row, _ in
                CGSize(width: ComponentCatalog.activityRowWidth, height: ActivityFeedController.height(of: .working(row)))
            },
            make: { row, theme, _ in ActivityWorkingRowView(row: row, theme: theme) }))
        cases.append(.of(
            "activity.row.thread", backdrop: .windowBackground,
            model: {
                let head = CatalogFixtures.event(
                    1, session: 1,
                    kind: .needsYou(reason: .permission, message: "Run swift test --filter PricingEngineTests?\nAllow once, always, or deny."),
                    minutesAgo: 12, title: "deal pipeline", unread: true)
                return ActivityFeedModel.ThreadRow(
                    sessionID: Fixture.sessionID(1), head: head, olderCount: 2, unread: true, ended: false,
                    expanded: false, titleRanges: [], previewRanges: [])
            },
            size: .computed { row, _ in
                CGSize(width: ComponentCatalog.activityRowWidth, height: ActivityFeedController.height(of: .thread(row)))
            },
            make: { row, theme, _ in
                ActivityThreadRowView(row: row, age: ActivityFeedModel.age(of: row.head, now: Fixture.now), theme: theme)
            }))
        cases.append(.of(
            "activity.row.folded", backdrop: .windowBackground,
            model: {
                let event = CatalogFixtures.event(
                    2, session: 1, kind: .stop(message: "Done. The pricing tests are green."),
                    minutesAgo: 125, title: "deal pipeline", unread: false)
                return ActivityFeedModel.FoldedRow(sessionID: Fixture.sessionID(1), event: event, previewRanges: [])
            },
            size: .computed { row, _ in
                CGSize(width: ComponentCatalog.activityRowWidth, height: ActivityFeedController.height(of: .folded(row)))
            },
            make: { row, theme, _ in
                ActivityFoldedRowView(row: row, age: ActivityFeedModel.age(of: row.event, now: Fixture.now), theme: theme)
            }))
        // The ⌘-hold card, shown without its fade, over the terminal it washes.
        cases.append(.of(
            "cheatSheet", backdrop: .terminalBackground,
            model: {
                [
                    CheatSheetSection(title: "Sessions", rows: [
                        CheatSheetRow(keys: "\u{2303}\u{2318}N", title: "New Session\u{2026}"),
                        CheatSheetRow(keys: "\u{2318}W", title: "Close Terminal"),
                    ]),
                    CheatSheetSection(title: "View", rows: [
                        CheatSheetRow(keys: "\u{2303}\u{2318}S", title: "Toggle Sidebar"),
                        CheatSheetRow(keys: "\u{21E7}\u{2318}P", title: "Command Palette"),
                    ]),
                ]
            },
            size: .computed { sections, theme in
                let probe = CheatSheetOverlayView(theme: theme)
                probe.setSections(sections)
                let card = probe.subviews.first { $0 is NSVisualEffectView }
                card?.layoutSubtreeIfNeeded()
                let fit = card?.fittingSize ?? CGSize(width: 400, height: 160)
                return CGSize(width: (fit.width + 32).rounded(.up), height: (fit.height + 32).rounded(.up))
            },
            make: { sections, theme, size in
                let overlay = CheatSheetOverlayView(theme: theme)
                overlay.frame = NSRect(origin: .zero, size: size)
                overlay.setSections(sections)
                overlay.isHidden = false
                overlay.alphaValue = 1
                return overlay
            }))
        return cases
    }

    // MARK: Settings

    /// The content column: the 720 pt window less the 176 pt nav, its 1 pt border and 22 pt
    /// either side (`SettingsView.Metrics`).
    @MainActor static var settingsCardWidth: Double {
        SettingsView.Metrics.width - SettingsView.Metrics.navWidth - 1 - 2 * SettingsView.Metrics.contentSide
    }

    static func themedSwitch(_ variant: String, isOn: Bool) -> ComponentCase {
        .of(
            "settings.switch.\(variant)", backdrop: .windowBackground, model: { isOn },
            size: .fixed { CGSize(width: ThemedSwitch.Metrics.width, height: ThemedSwitch.Metrics.height) },
            make: { isOn, theme, size in
                let toggle = ThemedSwitch(theme: theme)
                toggle.isOn = isOn
                pin(toggle, to: size)
                return toggle
            })
    }

    static func settings() -> [ComponentCase] {
        var cases: [ComponentCase] = []
        // One card with each control kind: switch, popup, status chip, destructive button.
        cases.append(.of(
            "settings.card", backdrop: .windowBackground,
            model: {
                SettingsSection(caption: "General", rows: [
                    SettingsRow(
                        id: .autoResume, title: "Resume sessions at launch",
                        detail: "Reopen every row that was running when the app quit.",
                        control: .toggle(isOn: true)),
                    SettingsRow(
                        id: .themePreset, title: "Theme", detail: "Applies to every window.",
                        control: .popup(titles: Theme.Preset.allCases.map(\.displayName), selected: 0)),
                    SettingsRow(
                        id: .statusline(accountKey: "claude"), title: "Status line",
                        detail: "Feeds the context and usage meters.",
                        control: .status(text: "Active", active: true)),
                    SettingsRow(
                        id: .removeShell, title: "Shell integration", detail: "Removes the shim and its rc lines.",
                        control: .button(title: "Remove\u{2026}", destructive: true)),
                ])
            },
            size: .fittingHeight { ComponentCatalog.settingsCardWidth },
            make: { section, theme, size in
                let view = SectionView(section: section, theme: theme)
                pin(view, to: size)
                return view
            }))
        // The nav column's rows as `SettingsView.build` stacks them, General selected.
        cases.append(.of(
            "settings.nav", backdrop: .sidebarBackground, model: { SettingsPage.general },
            size: .fixed {
                let rows = CGFloat(SettingsPage.allCases.count)
                return CGSize(
                    width: SettingsView.Metrics.navWidth - 2 * SettingsView.Metrics.navInset,
                    height: rows * SettingsView.Metrics.navRowHeight + (rows - 1) * 2)
            },
            make: { selected, theme, size in
                let stack = NSStackView(frame: NSRect(origin: .zero, size: size))
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 2
                for page in SettingsPage.allCases {
                    let row = NavRowView(page: page, theme: theme)
                    row.isSelected = page == selected
                    stack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
                return stack
            }))
        cases.append(themedSwitch("on", isOn: true))
        cases.append(themedSwitch("off", isOn: false))
        return cases
    }
}
