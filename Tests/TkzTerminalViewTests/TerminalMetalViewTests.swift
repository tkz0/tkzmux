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

    // MARK: Focus (TKZ-36)

    // Click-to-focus (`mouseDown` making itself first responder) is asserted at the window level,
    // in `MainWindowControllerTests`, where a click on a pane has to end up as `focusedTerminal`
    // in the store. It is deliberately *not* asserted here: this suite creates no window on
    // purpose, and a synthetic `NSWindow` off-screen does not run the responder chain the way a
    // real one does — an earlier attempt passed or failed depending on AppKit's own re-assertions
    // and cost 30 s a run.

    // MARK: Synchronous resize (TKZ-36)

    /// A divider drag is not a *window* resize, so `inLiveResize` stays false and the asynchronous
    /// branch of `setFrameSize` runs — Core Animation then stretches the previous texture over the
    /// new bounds for the length of the drag. `beginSynchronousResize` is what the split container
    /// brackets a drag with to get the transactional path instead.
    @Test("a synchronous resize renders inside setFrameSize, like a live resize")
    func synchronousResizeRendersImmediately() throws {
        guard let (_, view) = try makeView() else { return }
        let session = try makeSession()
        view.show(session)

        // Without it the grid is coalesced to the next tick — `resizeCoalesces` is that case.
        let asyncBaseline = view.gridResizeCount
        view.setFrameSize(NSSize(width: 700, height: 560))
        #expect(view.gridResizeCount == asyncBaseline)

        view.beginSynchronousResize()
        #expect(view.isSynchronousResizing)
        // The link must be parked for the same reason a live resize parks it: two paths calling
        // `nextDrawable()` against a 3-drawable pool deadlock.
        #expect(view.frameDriver.demand.isLiveResizing)

        // With it, the grid follows the frame inside `setFrameSize` instead of waiting for a tick.
        let baseline = view.gridResizeCount
        view.setFrameSize(NSSize(width: 640, height: 520))
        #expect(view.gridResizeCount > baseline, "a synchronous resize must apply in place")
        #expect(view.currentGridSize == view.gridSizeForBounds())

        view.endSynchronousResize()
        #expect(!view.isSynchronousResizing)
        #expect(!view.frameDriver.demand.isLiveResizing)
    }

    @Test("ending a synchronous resize inside a window drag leaves the window drag alone")
    func synchronousResizeNestedInALiveResize() throws {
        guard let (_, view) = try makeView() else { return }
        view.show(try makeSession())

        view.viewWillStartLiveResize()
        #expect(view.frameDriver.demand.isLiveResizing)
        view.beginSynchronousResize()
        view.endSynchronousResize()
        // The window is still being dragged: its transaction must survive the divider's.
        #expect(view.frameDriver.demand.isLiveResizing)
        view.viewDidEndLiveResize()
        #expect(!view.frameDriver.demand.isLiveResizing)
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

    // MARK: The scroll indicator (TKZ-45)

    /// Renders one offscreen frame, which is what refreshes `surface.scrollMetrics`, then hands it
    /// to the overlay. `renderNow` bails without a window, so the wiring is driven directly — the
    /// same two calls, in the same order, that `renderNow` makes.
    private func drawAndApplyIndicator(_ context: TerminalRenderContext, _ view: TerminalMetalView) throws {
        guard let texture = context.renderer.makeOffscreenTexture(width: 400, height: 200) else { return }
        _ = try context.renderer.render(surface: view.surface, to: texture)
        view.updateScrollIndicator()
    }

    @Test("a scrolled session shows a thumb; one with nothing to scroll shows none")
    func thumbFollowsTheScrollback() throws {
        guard let (context, view) = try makeView() else { return }
        let session = try makeSession()
        view.show(session)

        try drawAndApplyIndicator(context, view)
        #expect(view.scrollIndicator.thumbLayer?.isHidden ?? true,
                "a fresh session fits on screen: nothing to indicate")

        for line in 0..<500 { session.write(ptyText: "line \(line)\r\n") }
        try drawAndApplyIndicator(context, view)

        let thumb = try #require(view.scrollIndicator.thumbLayer)
        #expect(thumb.isHidden == false)
        #expect(thumb.superlayer === view.metalLayer, "the thumb is a sublayer of the Metal layer")
        #expect(thumb.frame.maxX == view.bounds.maxX - view.scrollIndicator.geometry.edgeInset)
        #expect(view.surface.scrollMetrics.isScrollable)
    }

    /// The M1.6 assertion, applied to the overlay: the thumb and its fade are Core Animation, not
    /// frames. Neither showing it nor fading it may move the display link's counters.
    @Test("the thumb and its fade schedule no frames")
    func thumbCostsNoFrames() throws {
        guard let (context, view) = try makeView() else { return }
        let session = try makeSession()
        view.show(session)
        for line in 0..<500 { session.write(ptyText: "line \(line)\r\n") }
        try drawAndApplyIndicator(context, view)
        #expect(view.scrollIndicator.thumbLayer?.isHidden == false, "precondition: a thumb is shown")

        // Settle, then take the baseline: from here nothing in the terminal changes, only the thumb.
        view.renderTick()
        let resumes = view.frameDriver.resumeCount
        let pauses = view.frameDriver.pauseCount
        let transitions = view.frameDriver.transitions.count
        #expect(view.frameDriver.isPaused, "precondition: an idle session parks the link")

        view.scrollIndicator.beginFade()
        view.renderTick()
        view.updateScrollIndicator()

        #expect(view.frameDriver.resumeCount == resumes, "the fade must not wake the link")
        #expect(view.frameDriver.pauseCount == pauses)
        #expect(view.frameDriver.transitions.count == transitions)
        #expect(view.frameDriver.isPaused)
    }

    @Test("switching sessions shows the incoming position, never the outgoing one's")
    func sessionSwitchResetsTheThumb() throws {
        guard let (context, view) = try makeView() else { return }
        let scrolled = try makeSession()
        for line in 0..<500 { scrolled.write(ptyText: "line \(line)\r\n") }
        let fresh = try makeSession()

        view.show(scrolled)
        try drawAndApplyIndicator(context, view)
        #expect(view.scrollIndicator.thumbLayer?.isHidden == false)
        #expect(view.scrollIndicator.lastApplied != nil)

        // The swap itself must drop the thumb, before the incoming session renders anything —
        // otherwise the old position is on screen for a frame.
        view.show(fresh)
        #expect(view.scrollIndicator.thumbLayer == nil, "no thumb may survive the swap")
        #expect(view.scrollIndicator.lastApplied == nil, "and no diff state, or the first frame is skipped")
        #expect(view.metalLayer?.sublayers?.isEmpty ?? true)

        // The incoming session has nothing to scroll, and gets no thumb of its own.
        try drawAndApplyIndicator(context, view)
        #expect(view.scrollIndicator.thumbLayer?.isHidden ?? true)
    }
}
