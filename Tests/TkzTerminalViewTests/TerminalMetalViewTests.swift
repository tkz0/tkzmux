// TerminalMetalView, headless. No window is ever created: the view is exercised directly, and the
// one frame the tests need is rendered into an offscreen texture through the same renderer the
// view uses. Every Metal test returns early when there is no GPU (Swift Testing has no skip).
import AppKit
import Metal
import Testing
import TkzTerminalCore
import TkzTerminalRender
@testable import TkzTerminalView

@Suite("TerminalMetalView", .serialized)
@MainActor
struct TerminalMetalViewTests {
    /// A context + view at 2x, sized so the grid is comfortably larger than 1×1.
    private func makeView(width: CGFloat = 800, height: CGFloat = 600) throws -> (TerminalRenderContext, TerminalMetalView)? {
        guard MTLCreateSystemDefaultDevice() != nil else { return nil }
        let context = try TerminalRenderContext(scale: 2)
        let view = TerminalMetalView(
            renderContext: context, frame: NSRect(x: 0, y: 0, width: width, height: height))
        return (context, view)
    }

    private func makeSession() throws -> TerminalSession {
        try TerminalSession(options: TerminalSessionOptions(cols: 80, rows: 24))
    }

    // MARK: show()

    @Test("show attaches, and showing another session frees the previous render state")
    func showSwapsSurfaces() throws {
        guard let (_, view) = try makeView() else { return }
        let a = try makeSession()
        let b = try makeSession()

        #expect(view.surface.isAttached == false)

        view.show(a)
        #expect(view.surface.isAttached)
        #expect(view.surface.session === a)
        #expect(view.frameDriver.demand.hasVisibleSession)

        view.show(b)
        #expect(view.surface.session === b, "the previous session must be gone, not merely hidden")

        view.show(nil)
        #expect(view.surface.isAttached == false)
        #expect(view.surface.needsDisplay == false)
        #expect(view.surface.columns == 0 && view.surface.rowCount == 0,
                "detach must free the row caches, not keep them alive")
        #expect(view.frameDriver.demand.hasVisibleSession == false)
        #expect(view.frameDriver.isPaused, "nothing attached: the link must be parked")
    }

    @Test("the first frame after an attach is a full rebuild")
    func attachRebuildsFull() throws {
        guard let (context, view) = try makeView() else { return }
        let session = try makeSession()
        session.write(ptyText: "hello tkzmux\r\n")
        view.show(session)

        guard let texture = context.renderer.makeOffscreenTexture(width: 400, height: 200) else { return }
        let first = try context.renderer.render(surface: view.surface, to: texture)
        #expect(first.didEncode)
        #expect(first.update.dirty == .full)
        #expect(first.glyphCount > 0)

        // Nothing changed since: the renderer must skip without touching the GPU.
        let second = try context.renderer.render(surface: view.surface, to: texture)
        #expect(second.wasSkipped)

        // Re-showing the same session detaches and re-attaches: FULL again.
        view.show(session)
        let third = try context.renderer.render(surface: view.surface, to: texture)
        #expect(third.update.dirty == .full)
    }

    // MARK: The background-session guarantee

    @Test("a background session's output cannot wake the display link")
    func backgroundSessionDoesNotWakeTheLink() throws {
        guard let (_, view) = try makeView() else { return }
        let background = try makeSession()
        let visible = try makeSession()

        view.show(background)
        let backgroundRelay = try #require(view.renderSignalRelay)

        view.show(visible)
        let visibleRelay = try #require(view.renderSignalRelay)
        #expect(visibleRelay !== backgroundRelay)

        // Baselines: attaching a session resizes its grid, which is itself one signal.
        let backgroundBaseline = backgroundRelay.signalCount
        let visibleBaseline = visibleRelay.signalCount

        // Park the link: the switch itself requested a frame.
        view.frameDriver.update { $0.needsUpdate = false }
        #expect(view.frameDriver.isPaused)
        let resumesBefore = view.frameDriver.resumeCount

        // The backgrounded session produces a lot of output.
        for _ in 0..<50 { background.write(ptyText: "noise from a session nobody is looking at\r\n") }

        #expect(backgroundRelay.signalCount == backgroundBaseline,
                "show() cleared the old session's renderSignal — a backgrounded session signals nothing")
        #expect(view.frameDriver.isPaused)
        #expect(view.frameDriver.resumeCount == resumesBefore)

        // Positive control: the visible session does signal (delivery to the driver is one hop later).
        visible.write(ptyText: "x")
        #expect(visibleRelay.signalCount == visibleBaseline + 1)
    }

    // MARK: Resize coalescing

    @Test("N setFrameSize calls in one tick produce exactly one grid resize")
    func resizeCoalesces() throws {
        guard let (_, view) = try makeView() else { return }
        let session = try makeSession()
        view.show(session)
        let baseline = view.gridResizeCount

        for width in stride(from: 780.0, through: 700.0, by: -20.0) {
            view.setFrameSize(NSSize(width: width, height: 560))
        }
        #expect(view.gridResizeCount == baseline,
                "outside a live resize the grid must not follow every setFrameSize")

        view.renderTick()
        #expect(view.gridResizeCount == baseline + 1)
        let size = view.gridSizeForBounds()
        #expect(view.currentGridSize == size)
        #expect(session.size.cols == size.cols)
        #expect(session.size.rows == size.rows)

        // A second tick with nothing pending must not resize again.
        view.renderTick()
        #expect(view.gridResizeCount == baseline + 1)
    }

    @Test("a sub-cell resize still redraws: the drawable changed even though the grid did not")
    func subCellResizeMarksDirty() throws {
        guard let (context, view) = try makeView() else { return }
        let session = try makeSession()
        session.write(ptyText: "hello\r\n")
        view.show(session)
        guard let texture = context.renderer.makeOffscreenTexture(width: 400, height: 200) else { return }
        _ = try context.renderer.render(surface: view.surface, to: texture)
        #expect(view.surface.needsDisplay == false)

        view.setFrameSize(NSSize(width: view.frame.width + 3, height: view.frame.height))
        #expect(view.surface.needsDisplay,
                "a drawable-size change must redraw, or CA stretches the previous frame")

        _ = try context.renderer.render(surface: view.surface, to: texture)
        #expect(view.surface.needsDisplay == false)
        view.setFrameSize(view.frame.size)  // no change at all
        #expect(view.surface.needsDisplay == false)
    }

    // MARK: Backing scale

    @Test("a backing-scale change rebuilds the renderer, re-attaches the surface and re-grids")
    func backingScaleRebuild() throws {
        guard let (context, view) = try makeView() else { return }
        let session = try makeSession()
        view.show(session)

        let rendererBefore = context.renderer
        let cellBefore = context.metrics.width
        let gridBefore = view.currentGridSize

        view.applyBackingScale(1)

        #expect(context.rebuildCount == 1)
        #expect(context.scale == 1)
        #expect(context.renderer !== rendererBefore, "a new atlas needs a new renderer")
        #expect(context.metrics.width != cellBefore, "1x cells are not 2x cells")
        #expect(view.surface.isAttached, "the surface must be re-attached, not left detached")
        #expect(view.surface.session === session)
        #expect(view.currentGridSize != gridBefore, "new metrics fit a different number of cells")
        #expect(session.size.cols == view.currentGridSize.cols)

        // The re-attached surface rebuilds everything on its next frame.
        guard let texture = context.renderer.makeOffscreenTexture(width: 200, height: 100) else { return }
        let outcome = try context.renderer.render(surface: view.surface, to: texture)
        #expect(outcome.update.dirty == .full)

        // Idempotent: the same scale again rebuilds nothing.
        view.applyBackingScale(1)
        #expect(context.rebuildCount == 1)
    }

    @Test("the render context re-attaches every registered surface, not just the view's")
    func contextReattachesAllSurfaces() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let context = try TerminalRenderContext(scale: 2)
        let extra = TerminalSurface()
        let session = try makeSession()
        context.register(extra)
        try extra.attach(session)

        #expect(context.liveSurfaces().count == 1)
        try context.setScale(1)
        #expect(extra.isAttached)
        #expect(extra.session === session)

        context.unregister(extra)
        #expect(context.liveSurfaces().isEmpty)
    }

    // MARK: Geometry

    @Test("the grid is derived from device pixels and cell metrics")
    func gridGeometry() throws {
        guard let (context, view) = try makeView(width: 400, height: 300) else { return }
        let metrics = context.metrics
        let size = view.gridSizeForBounds()
        #expect(Int(size.cols) == Int(800) / metrics.width)   // 400 pt at 2x
        #expect(Int(size.rows) == Int(600) / metrics.height)
        #expect(Int(size.cellWidthPx) == metrics.width)
        #expect(view.gridGeometry.originPx == .zero, "the grid is pinned top-left, no padding")
    }

    // MARK: Rendering without a window

    @Test("a windowless view renders nothing and never asks for a drawable")
    func windowlessViewSkips() throws {
        guard let (context, view) = try makeView() else { return }
        let session = try makeSession()
        view.show(session)
        session.write(ptyText: "output\r\n")
        context.renderer.resetStats()

        view.renderTick()

        #expect(context.renderer.stats.drawableRequests == 0)
        #expect(view.framesRendered == 0)
    }
}
