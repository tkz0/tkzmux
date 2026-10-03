// ComponentSnapshotTests — the harness itself (WOR-307 S1), before any golden exists.
//
// What these prove:
//
//   1. **Every way a component draws is captured**, at 2.0 and at 1.6: pure layer trees (a sidebar
//      row), `NSTextField` subviews inside a layer-backed view (the activity kind pill), a plain
//      `draw(_:)` view (the status bar) and a flipped layer-hosting view (the startup overlay).
//      Each is checked by finding a text run in the layout dump and requiring ink inside that
//      frame of the PNG, so a blank bitmap, or a dump whose frames are not where the pixels are,
//      fails.
//   2. **The dump's conventions**: logical points, top-left origin. The status dot of a 44 pt row
//      is at (30, 18, 7, 7) at both scales, ADR-0003's worked example 3.
//   3. **Fractional scales round the bitmap up and say so**: a 44 pt row is 71 px at 1.6.
//   4. **Determinism**: two renders of the same component are byte-identical, PNG and JSON, for
//      every preset and both scales.
//   5. **The appearance is forced and animations are frozen**, and the `contentsScale` seam is 2
//      unless a capture says otherwise.
//
// `@MainActor` and serialised like the other rendering suites: they share the process font
// registry, the `CATransaction` stack and `LayerContentsScale`.

import AppKit
import Testing
import TkzCore
import TkzPNG

@testable import TkzApp

// MARK: - Components

extension ComponentSnapshot.Component where Model == SidebarSessionRowModel {
    /// A session row, transparent where the outline view shows the sidebar through it.
    static var sessionRow: Self {
        Self(
            id: "sidebar.sessionRow",
            make: { model, theme, size in
                let row = SessionRowView(frame: NSRect(origin: .zero, size: size))
                row.configure(model, theme: theme)
                return row
            },
            backdrop: { $0.sidebarBackground },
            facts: { model, view in
                ["detailWraps": String(SessionRowView.detailWraps(for: model, width: view.bounds.width))]
            })
    }
}

extension ComponentSnapshot.Component where Model == ActivityEvent.Kind {
    /// The `NEEDS YOU · …` pill: an `NSTextField` in a layer-backed view with a rounded fill.
    static var activityKindPill: Self {
        Self(id: "activity.kindPill", make: { kind, theme, _ in ActivityKindPill(kind: kind, theme: theme) })
    }
}

extension ComponentSnapshot.Component where Model == StatusBarModel {
    /// The status strip, which draws everything in `draw(_:)`.
    static var statusBar: Self {
        Self(id: "statusBar", make: { model, theme, _ in StatusBarView(theme: theme, model: model) })
    }
}

extension ComponentSnapshot.Component where Model == PaneStartupModel {
    /// "Starting …" over a pane: a flipped view hosting layers, with a spinning one.
    static var startupOverlay: Self {
        Self(
            id: "panes.startupOverlay",
            make: { model, theme, _ in
                let overlay = PaneStartupOverlayView(theme: theme)
                overlay.agentDisplayName = "Claude"
                overlay.show(model, theme: theme)
                return overlay
            },
            backdrop: { $0.terminalBackground })
    }
}

// MARK: - Tests

@MainActor
@Suite(.serialized)
struct ComponentSnapshotTests {
    // MARK: Fixtures

    /// A working row from `AppState.fixture`, so the row is built the way the sidebar builds it.
    static func fixtureRow() throws -> SidebarSessionRowModel {
        let state = AppState.fixture
        let working = state.orderedSessions.filter { SidebarRowAdapter.status(of: $0) == .working }
        let session = try #require(working.first { $0.live?.git?.branch != nil } ?? working.first)
        return SidebarRowAdapter.sessionModel(session, in: state)
    }

    /// A one-line working row: the 44 pt row of ADR-0003's worked example 3.
    static let plainRow = SidebarSessionRowModel(title: "Fix the rounding bug", branch: "main", status: .working)

    static let pillKind = ActivityEvent.Kind.needsYou(reason: .permission, message: nil)

    static let statusModel = StatusBarModel(
        branch: "feature/tkz-18-main-window", isWorktree: true, modelName: "Sonnet 4.5",
        diffAdded: 142, diffRemoved: 38, contextPercent: 62)

    static let startupModel = PaneStartupModel(command: "claude -w feature")

    static func rowSize(_ model: SidebarSessionRowModel, width: Double = SidebarMetrics.sidebarWidth) -> CGSize {
        CGSize(width: width, height: SessionRowView.height(for: model, width: width))
    }

    static let statusBarSize = CGSize(width: 480, height: StatusBarView.height)
    static let overlaySize = CGSize(width: 480, height: 300)

    // MARK: Pixel helpers

    static func decode(_ png: Data) throws -> PNGImage {
        try PNG.decode([UInt8](png))
    }

    /// How many pixels inside `rect` (top-left logical points) differ from the most common value
    /// there: zero for a uniform area, so a text box with nothing drawn in it scores zero.
    static func ink(in rect: LayoutDump.Rect, of image: PNGImage, scale: Double) -> Int {
        let x0 = max(0, Int((rect.x * scale).rounded(.down)))
        let y0 = max(0, Int((rect.y * scale).rounded(.down)))
        let x1 = min(image.width, Int((rect.maxX * scale).rounded(.up)))
        let y1 = min(image.height, Int((rect.maxY * scale).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var counts: [UInt32: Int] = [:]
        for y in y0..<y1 {
            for x in x0..<x1 {
                counts[pixel(image, x: x, y: y), default: 0] += 1
            }
        }
        let mostCommon = counts.values.max() ?? 0
        return (x1 - x0) * (y1 - y0) - mostCommon
    }

    static func pixel(_ image: PNGImage, x: Int, y: Int) -> UInt32 {
        let offset = (y * image.width + x) * 4
        return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(image.pixels[offset + $1]) }
    }

    static func textNode(_ layout: LayoutDump, string: String) throws -> LayoutDump.Node {
        try #require(
            layout.allNodes.first { $0.text?.string == string },
            "no text run \"\(string)\" in \(layout.component)")
    }

    /// Whether any layer under `layer` still has an animation attached.
    static func hasAnimations(_ layer: CALayer) -> Bool {
        !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains(where: hasAnimations)
    }

    static func checkSize(_ snapshot: (png: Data, layout: LayoutDump)) throws -> PNGImage {
        let image = try decode(snapshot.png)
        #expect(image.width == snapshot.layout.pixels.width.pixels)
        #expect(image.height == snapshot.layout.pixels.height.pixels)
        return image
    }

    // MARK: 1. Every kind of drawing is captured

    @Test("A sidebar row (layers only) renders with its title in its dumped frame", arguments: ComponentSnapshot.scales)
    func sessionRow(scale: Double) throws {
        let model = try Self.fixtureRow()
        let snapshot = try ComponentSnapshot.render(
            id: .sessionRow, model: model, size: Self.rowSize(model), theme: .default, scale: scale)
        try ComponentSnapshot.writeArtifacts(snapshot)
        let image = try Self.checkSize(snapshot)

        let title = try Self.textNode(snapshot.layout, string: model.title)
        #expect(title.kind == .layer)
        #expect(title.type == "CATextLayer")
        #expect(Self.ink(in: title.frame, of: image, scale: scale) >= 20)
        let wraps = SessionRowView.detailWraps(for: model, width: SidebarMetrics.sidebarWidth)
        #expect(snapshot.layout.facts["detailWraps"] == String(wraps))
        #expect(snapshot.layout.root.type == "SessionRowView")
    }

    @Test("An NSTextField inside a layer-backed view renders, over the view's own fill", arguments: ComponentSnapshot.scales)
    func textFieldComponent(scale: Double) throws {
        let size = ComponentSnapshot.fittingSize(of: .activityKindPill, model: Self.pillKind, theme: .default)
        #expect(size.width > 0 && size.height > 0)
        let snapshot = try ComponentSnapshot.render(
            id: .activityKindPill, model: Self.pillKind, size: size, theme: .default, scale: scale)
        try ComponentSnapshot.writeArtifacts(snapshot)
        let image = try Self.checkSize(snapshot)

        let label = try Self.textNode(snapshot.layout, string: ActivityFeedModel.kindLabel(Self.pillKind))
        #expect(label.kind == .view)
        #expect(label.type == "NSTextField")
        #expect(Self.ink(in: label.frame, of: image, scale: scale) >= 20)
        // The pill's own layer fill is drawn too: the middle of its 4.5 pt leading inset is opaque.
        let inset = Self.pixel(image, x: Int((1.5 * scale).rounded()), y: image.height / 2)
        #expect(inset & 0xFF > 0, "the pill's background was not drawn")
    }

    @Test("A draw(_:) view (the status bar) renders its text", arguments: ComponentSnapshot.scales)
    func drawBasedView(scale: Double) throws {
        let snapshot = try ComponentSnapshot.render(
            id: .statusBar, model: Self.statusModel, size: Self.statusBarSize, theme: .default, scale: scale)
        try ComponentSnapshot.writeArtifacts(snapshot)
        let image = try Self.checkSize(snapshot)
        // Below the top hairline, the strip is its background plus whatever text was drawn.
        let band = LayoutDump.Rect(x: 0, y: 2, width: Double(Self.statusBarSize.width), height: 32)
        #expect(Self.ink(in: band, of: image, scale: scale) >= 100)
    }

    @Test("A flipped view's layers land where the dump says, top to bottom", arguments: ComponentSnapshot.scales)
    func flippedLayerHost(scale: Double) throws {
        let snapshot = try ComponentSnapshot.render(
            id: .startupOverlay, model: Self.startupModel, size: Self.overlaySize, theme: .default, scale: scale)
        try ComponentSnapshot.writeArtifacts(snapshot)
        let image = try Self.checkSize(snapshot)
        #expect(snapshot.layout.root.flipped == true)

        let spinner = try #require(snapshot.layout.nodes(ofType: "CAShapeLayer").first)
        let title = try Self.textNode(snapshot.layout, string: "Starting Claude\u{2026}")
        let caption = try Self.textNode(snapshot.layout, string: Self.startupModel.command)
        // Spinner over title over caption, in top-left coordinates.
        #expect(spinner.frame.maxY <= title.frame.y)
        #expect(title.frame.maxY <= caption.frame.y)
        #expect(Self.ink(in: title.frame, of: image, scale: scale) >= 20)
        #expect(Self.ink(in: caption.frame, of: image, scale: scale) >= 20)
    }

    // MARK: 2. Dump conventions

    @Test("Frames are logical and top-left: the dot of a 44 pt row is at (30, 18, 7, 7)", arguments: ComponentSnapshot.scales)
    func dotFrameMatchesADRExample(scale: Double) throws {
        let size = Self.rowSize(Self.plainRow)
        #expect(size.height == 44)
        let snapshot = try ComponentSnapshot.render(
            id: .sessionRow, model: Self.plainRow, size: size, theme: .default, scale: scale)
        let dot = try #require(snapshot.layout.nodes(ofType: "StatusDotLayer").first)
        #expect(dot.frame == LayoutDump.Rect(x: 30, y: 18, width: 7, height: 7))
        #expect(snapshot.layout.root.frame == LayoutDump.Rect(x: 0, y: 0, width: 300, height: 44))
        #expect(snapshot.layout.facts["detailWraps"] == "false")
    }

    // MARK: 3. Fractional scales

    @Test("At 1.6 a fractional pixel size is rounded up and recorded; at 2.0 nothing is")
    func pixelRounding() throws {
        let size = Self.rowSize(Self.plainRow)
        let fractional = try ComponentSnapshot.render(
            id: .sessionRow, model: Self.plainRow, size: size, theme: .default, scale: 1.6)
        #expect(fractional.layout.pixels.width == LayoutDump.PixelExtent(logical: 300, scale: 1.6))
        #expect(fractional.layout.pixels.width.pixels == 480)
        #expect(fractional.layout.pixels.width.roundedUp == false)
        #expect(fractional.layout.pixels.height.pixels == 71)
        #expect(fractional.layout.pixels.height.exact == 70.4)
        #expect(fractional.layout.pixels.height.roundedUp)
        _ = try Self.checkSize(fractional)

        let whole = try ComponentSnapshot.render(
            id: .sessionRow, model: Self.plainRow, size: size, theme: .default, scale: 2)
        #expect(whole.layout.pixels.width.pixels == 600)
        #expect(whole.layout.pixels.height.pixels == 88)
        #expect(!whole.layout.pixels.width.roundedUp && !whole.layout.pixels.height.roundedUp)
        _ = try Self.checkSize(whole)
    }

    // MARK: 4. Determinism

    @Test("Two renders are byte-identical, PNG and JSON, for every preset and scale", arguments: Theme.allPresets)
    func deterministic(theme: Theme) throws {
        let row = try Self.fixtureRow()
        let pill = ComponentSnapshot.fittingSize(of: .activityKindPill, model: Self.pillKind, theme: theme)
        for scale in ComponentSnapshot.scales {
            let renders: [() throws -> (png: Data, layout: LayoutDump)] = [
                { try ComponentSnapshot.render(id: .sessionRow, model: row, size: Self.rowSize(row), theme: theme, scale: scale) },
                { try ComponentSnapshot.render(id: .activityKindPill, model: Self.pillKind, size: pill, theme: theme, scale: scale) },
                { try ComponentSnapshot.render(id: .statusBar, model: Self.statusModel, size: Self.statusBarSize, theme: theme, scale: scale) },
                { try ComponentSnapshot.render(id: .startupOverlay, model: Self.startupModel, size: Self.overlaySize, theme: theme, scale: scale) },
            ]
            for render in renders {
                let first = try render()
                let second = try render()
                let name = ComponentSnapshot.fileStem(first.layout)
                #expect(first.png == second.png, "\(name): PNG differs between two renders")
                #expect(try first.layout.jsonData() == second.layout.jsonData(), "\(name): JSON differs between two renders")
                try ComponentSnapshot.writeArtifacts(first)
            }
        }
    }

    // MARK: 5. Appearance, animations, the scale seam

    @Test("The appearance follows the theme, on the view and while drawing", arguments: Theme.allPresets)
    func appearanceIsForced(theme: Theme) throws {
        let probe = ComponentSnapshot.Component<ActivityEvent.Kind>(
            id: "test.appearanceProbe",
            make: { kind, theme, _ in ActivityKindPill(kind: kind, theme: theme) },
            facts: { _, view in
                let names: [NSAppearance.Name] = [.aqua, .darkAqua]
                return [
                    "view": view.effectiveAppearance.bestMatch(from: names)?.rawValue ?? "none",
                    "drawing": NSAppearance.currentDrawing().bestMatch(from: names)?.rawValue ?? "none",
                ]
            })
        let size = ComponentSnapshot.fittingSize(of: probe, model: Self.pillKind, theme: theme)
        let snapshot = try ComponentSnapshot.render(
            id: probe, model: Self.pillKind, size: size, theme: theme, scale: 2)
        let expected: NSAppearance.Name = theme.isDark ? .darkAqua : .aqua
        #expect(snapshot.layout.appearance == expected.rawValue)
        #expect(snapshot.layout.facts["view"] == expected.rawValue)
        #expect(snapshot.layout.facts["drawing"] == expected.rawValue)
    }

    @Test("Animations are recorded in the dump and removed before drawing")
    func animationsAreFrozen() throws {
        // The overlay attaches its spin on `show`, window or not.
        let overlay = PaneStartupOverlayView(theme: .default)
        overlay.show(Self.startupModel, theme: .default)
        #expect(overlay.isSpinning)

        let frozen = ComponentSnapshot.Component<PaneStartupModel>(
            id: "test.frozenOverlay", make: { _, _, _ in overlay })
        let snapshot = try ComponentSnapshot.render(
            id: frozen, model: Self.startupModel, size: Self.overlaySize, theme: .default, scale: 2)
        let spinner = try #require(snapshot.layout.nodes(ofType: "CAShapeLayer").first)
        #expect(spinner.animations?.contains(PaneStartupOverlayView.spinAnimationKey) == true)
        #expect(!overlay.isSpinning, "the spin is still attached after the capture")
        #expect(overlay.layer.map(Self.hasAnimations) == false, "an animation survived the capture")
    }

    @Test("The contentsScale seam is 2 unless a capture sets it, and a capture puts it back")
    func contentsScaleSeam() throws {
        func textLayer() -> CATextLayer {
            SidebarLayers.text(NSFont.systemFont(ofSize: 11), color: NSColor.white.cgColor)
        }
        #expect(LayerContentsScale.production == 2)
        #expect(LayerContentsScale.current == 2)
        #expect(textLayer().contentsScale == 2)
        #expect(SidebarLayers.chevron(side: 10, lineWidth: 1.5).contentsScale == 2)

        let scoped = LayerContentsScale.withScale(1.6) {
            (textLayer().contentsScale, SidebarLayers.chevron(side: 10, lineWidth: 1.5).contentsScale)
        }
        #expect(scoped.0 == 1.6)
        #expect(scoped.1 == 1.6)
        #expect(LayerContentsScale.current == 2)

        _ = try ComponentSnapshot.render(
            id: .sessionRow, model: Self.plainRow, size: Self.rowSize(Self.plainRow), theme: .default, scale: 1.6)
        #expect(LayerContentsScale.current == 2)
        #expect(textLayer().contentsScale == 2)
    }
}
