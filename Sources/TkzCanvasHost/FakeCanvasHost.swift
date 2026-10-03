// FakeCanvasHost — a `CanvasHost` with no display, for offscreen tests (WOR-314 S4, for WOR-316).
//
// It behaves like `GtkCanvasHost` where a client can tell: geometry changes reach the client
// before the next draw, `requestFrame` is idempotent until the frame runs, presented frames are
// held and released by the same `CanvasFrameQueue` policy, and a frame that cannot be shown steps
// the ladder down. The differences are what it lacks: its frame clock is the test calling
// `runFrame()`, and it offers no dma-buf formats, so a `CanvasPresenter` on it presents through
// the readback rung and every shown frame's bytes are in `shownBytes`.
//
// A dma-buf frame (a test that builds its own ladder with formats) is held and released like any
// other, but its pixels are not read; `shownFrame` still says which slot is on screen.

import TkzRenderVK

@MainActor
public final class FakeCanvasHost: CanvasHost {
    public weak var client: (any CanvasHostClient)?

    public private(set) var geometry: CanvasGeometry
    public var presentationTarget: CanvasPresentationTarget
    public private(set) var visibility = CanvasVisibility(isMapped: true, isSuspended: false)

    public var textInput: (any CanvasTextInput)?
    public var clipboard: (any CanvasClipboard)?
    public var popupHost: (any CanvasPopupHost)?
    public var accessibilityRoot: (any CanvasAccessibilityNode)?

    /// A frame has been asked for since the last `runFrame`.
    public private(set) var frameRequested = false
    /// What the host counted, for the tests' idle and resize assertions.
    public private(set) var stats = Stats()

    public struct Stats: Sendable, Hashable {
        /// `runFrame` calls that ran a frame (something was requested or the geometry changed).
        public var frames = 0
        /// `canvasHostDraw` calls.
        public var draws = 0
        public var geometryChanges = 0
        public var presents = 0
        /// Frames shown by a frame (a new one; an unchanged frame is not counted again).
        public var shows = 0
        public var importFailures = 0
    }

    /// The frame on screen, and its pixels when it came through readback (B, G, R, A rows,
    /// premultiplied, `pixelWidth × pixelHeight`).
    public private(set) var shownFrame: LadderFrame?
    public private(set) var shownBytes: [UInt8]?

    /// Makes `runFrame` report the next shown dma-buf frame as not importable, as GDK does when a
    /// texture cannot be built: the ladder steps down.
    public var failNextImport: String?

    private let queue = CanvasFrameQueue<HeldFrame>()
    private let visibilityBroadcast = CanvasBroadcast<CanvasVisibility>()
    private let inputBroadcast = CanvasBroadcast<CanvasInputEvent>()
    private var geometryChanged = true

    private struct HeldFrame {
        let frame: LadderFrame
        let ladder: PresentationLadder
    }

    public init(geometry: CanvasGeometry, presentationTarget: CanvasPresentationTarget = .readbackOnly) {
        self.geometry = geometry
        self.presentationTarget = presentationTarget
    }

    /// Frames still held by the host (not yet given back to their ladders).
    public var heldFrames: Int { queue.heldCount }

    // MARK: CanvasHost

    public func requestFrame() {
        frameRequested = true
    }

    public func present(_ frame: LadderFrame, from ladder: PresentationLadder) {
        stats.presents += 1
        queue.submit(HeldFrame(frame: frame, ladder: ladder)) { $0.ladder.release($0.frame) }
    }

    public func visibilityUpdates() -> AsyncStream<CanvasVisibility> { visibilityBroadcast.subscribe() }

    public func inputEvents() -> AsyncStream<CanvasInputEvent> { inputBroadcast.subscribe() }

    // MARK: Driving it

    /// Resizes or rescales the canvas; the client hears of it at the next `runFrame`.
    public func setGeometry(_ geometry: CanvasGeometry) {
        guard geometry != self.geometry else { return }
        self.geometry = geometry
        geometryChanged = true
    }

    public func setVisibility(_ visibility: CanvasVisibility) {
        guard visibility != self.visibility else { return }
        self.visibility = visibility
        visibilityBroadcast.send(visibility)
    }

    public func send(_ event: CanvasInputEvent) {
        inputBroadcast.send(event)
    }

    /// One tick of the frame clock: tells the client about a geometry change, asks it to draw if a
    /// frame was requested (or the geometry changed), then shows the latest presented frame.
    /// Returns whether a frame ran; an idle host runs none.
    @discardableResult
    public func runFrame() throws -> Bool {
        guard frameRequested || geometryChanged else { return false }
        stats.frames += 1
        frameRequested = false
        if geometryChanged {
            geometryChanged = false
            stats.geometryChanges += 1
            client?.canvasHost(self, didChangeGeometry: geometry)
        }
        if let client {
            stats.draws += 1
            client.canvasHostDraw(self)
        }
        let promoted = queue.pending != nil
        guard let held = queue.show() else { return true }
        if let reason = failNextImport, promoted, held.frame.dmabuf != nil {
            failNextImport = nil
            stats.importFailures += 1
            _ = queue.removeShown()
            try held.ladder.importFailed(held.frame, reason: reason)
            frameRequested = true
            return true
        }
        if promoted { stats.shows += 1 }
        shownFrame = held.frame
        shownBytes = held.frame.readback?.bytes
        return true
    }

    /// Gives every held frame back, as a host does when its surface goes.
    public func releaseAll() {
        queue.releaseAll()
        shownFrame = nil
        shownBytes = nil
    }
}
