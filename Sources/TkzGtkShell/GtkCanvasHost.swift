// GtkCanvasHost — TkzCanvasHost's seam on GTK: one undecorated window whose only pixels are
// tkzmux's own (WOR-314 S4).
//
// The widget tree is
//
//   GtkWindow (decorated = false, CSS class tkzmux-canvas)
//     └ GtkGraphicsOffload (black_background = true)
//         └ TkzCanvas
//
// and every frame is a ring slot appended as one texture node covering the canvas, so GSK has
// nothing to composite: GtkGraphicsOffload puts the texture on a subsurface of its own and GTK
// attaches the dma-buf to it (WOR-301 S1). black_background lets the offload hole stay opaque;
// CanvasStyle zeroes every theme pixel that would clip, round or blend it, which would turn
// offload off without a word (`GDK_DEBUG=offload` says why).
//
// Texel-exact: the canvas fills the window from (0, 0); a frame is logical × scale device pixels,
// with the scale read from the surface (`gdk_surface_get_scale`, fractional: 1.6 here), appended at
// its logical size, so the compositor maps one texel to one pixel. GTK offloads a texture only when
// its rect is whole device pixels (`scaled_rect_is_integral` in gdksubsurface-wayland.c, GTK
// 4.22.4), so at 1.6 the presented size is snapped down to a multiple of 5 logical pixels
// (`CanvasGeometry.presentable`); the client lays out in that size, and the strip left over on the
// right and bottom (under 5 logical pixels) is the window's black background. The offload widget
// itself is snapped too (start-aligned, its natural size the canvas's snapped measure), because
// its black background is a rect of its own size and must be whole device pixels as well.
// `notify::scale` on the surface (and every size_allocate) re-reads the geometry, tells the client
// before the next draw, and the client makes a ring at the new size.
//
// A frame: `requestFrame` queues a draw; the snapshot vfunc asks the client to draw when it was
// requested or the geometry changed (the client presents a slot), then appends the newest
// presented frame, or again the one already shown. One GdkTexture is built per ring slot and kept.
// That does not make GTK reuse wl_buffers: GTK 4.22.4 creates one per attach (a `create` roundtrip)
// and destroys it on `wl_buffer.release`, holding a texture reference until then (measured: one
// `zwp_linux_buffer_params_v1.create` per frame, with or without kept textures). The kept texture
// saves rebuilding, and its reference count is the release signal: `CanvasFrameQueue` says when a
// slot is old enough to go back to its ring, and the host gives it back only once nothing but its
// own cache refers to the texture (no render node, no wl_buffer the compositor has not released).
// A texture GDK cannot build steps the ladder down (`importFailed`, which logs), and the next frame
// is drawn on the new rung.
//
// S5 adds the DisplayLinkPolicy-gated tick, damage forwarding and the resize details; S3 the
// application lifecycle; S6 the window controls.

import CGtk
import TkzCanvasHost
import TkzLinuxShim
import TkzRenderVK

@MainActor
public final class GtkCanvasHost: CanvasHost, CanvasWidgetDelegate {
    public weak var client: (any CanvasHostClient)?

    /// The window and the canvas. Valid for as long as the host lives; the window is destroyed by
    /// `close()` or by the user.
    public let window: GObjectRef<UnsafeMutablePointer<GtkWidget>>
    public let canvas: CanvasWidget
    public let presentationTarget: CanvasPresentationTarget

    public private(set) var geometry = CanvasGeometry.empty
    public private(set) var visibility = CanvasVisibility.hidden

    public var textInput: (any CanvasTextInput)? { nil }
    public var clipboard: (any CanvasClipboard)? { nil }
    public var popupHost: (any CanvasPopupHost)? { nil }
    public var accessibilityRoot: (any CanvasAccessibilityNode)?

    /// Called on the window's `close-request`; true keeps the window open.
    public var onCloseRequest: (@MainActor () -> Bool)?

    /// What the host counted, for the presentation checks.
    public private(set) var stats = Stats()

    public struct Stats: Sendable, Hashable {
        public var snapshots = 0
        /// `canvasHostDraw` calls.
        public var draws = 0
        public var presents = 0
        /// Distinct frames appended (not counting re-appends of the frame already shown).
        public var shows = 0
        public var geometryChanges = 0
        /// GdkDmabufTextures built (one per ring slot and rung), and presents that reused one.
        public var dmabufTextures = 0
        public var textureReuses = 0
        /// GdkMemoryTextures built (one per readback frame).
        public var memoryTextures = 0
        public var importFailures = 0
        /// Slots whose release waited because GTK still referred to their texture.
        public var deferredReleases = 0
    }

    private let display: OpaquePointer
    private let queue = CanvasFrameQueue<HeldFrame>()
    private var ladders: [LadderRecord] = []
    /// Frames old enough to go back to their ring whose texture GTK still refers to.
    private var draining: [HeldFrame] = []
    private var needsDraw = true
    private var surface: OpaquePointer?
    private var surfaceSignals: [SignalHandlerID] = []
    private var focused = false
    private let visibilityBroadcast = CanvasBroadcast<CanvasVisibility>()
    private let inputBroadcast = CanvasBroadcast<CanvasInputEvent>()

    /// One ladder the host has frames or textures of. The ladder's rings own the dma-buf fds, so
    /// it stays here until GDK has finalized every texture over them (`lease`).
    @MainActor
    final class LadderRecord {
        let ladder: PresentationLadder
        let lease: TextureLease
        /// One texture per slot of the ladder's current rung.
        var textures: [Int: GObjectRef<OpaquePointer>] = [:]
        var texturesGeneration = 0

        init(_ ladder: PresentationLadder, lease: TextureLease) {
            self.ladder = ladder
            self.lease = lease
        }
    }

    struct HeldFrame {
        let frame: LadderFrame
        let record: LadderRecord
        let texture: GObjectRef<OpaquePointer>
    }

    /// Makes the window (not yet shown). `application` (a `GtkApplication *`) makes it an
    /// application window; nil makes a plain one.
    public init(application: UnsafeMutablePointer<GtkApplication>? = nil, title: String,
                defaultWidth: Int32, defaultHeight: Int32) {
        let pointer = application.map { gtk_application_window_new($0)! } ?? gtk_window_new()!
        // Both are transfer none: GTK's toplevel list owns the window until it is destroyed.
        window = GObjectRef(retaining: pointer)
        display = gtk_widget_get_display(pointer)
        presentationTarget = GtkPresentation.target(for: display)
        canvas = CanvasWidget()
        CanvasStyle.install(on: display)

        let gtkWindow = tkz_window(pointer)
        gtk_window_set_decorated(gtkWindow, 0)
        gtk_window_set_title(gtkWindow, title)
        gtk_window_set_default_size(gtkWindow, defaultWidth, defaultHeight)
        gtk_widget_add_css_class(pointer, CanvasStyle.windowClass)

        // The offload widget is owned by the window from here on; the canvas by both.
        let offload = gtk_graphics_offload_new(canvas.widget.pointer)!
        gtk_graphics_offload_set_black_background(tkz_graphics_offload(offload), 1)
        // Its size is the canvas's measure (whole device pixels), not the window's.
        gtk_widget_set_halign(offload, GTK_ALIGN_START)
        gtk_widget_set_valign(offload, GTK_ALIGN_START)
        gtk_window_set_child(gtkWindow, offload)
        gtk_widget_set_focusable(canvas.widget.pointer, 1)

        canvas.delegate = self
        Signals.connect(pointer, "close-request", returning: { [weak self] in
            self?.onCloseRequest?() ?? false
        })
    }

    isolated deinit {
        // Straight back to the rings: the queue's release closures hold the host weakly. Without
        // its delegate the canvas draws nothing more, so no new frame reads these images.
        let held = [queue.pending, queue.shown, queue.previous].compactMap { $0?.frame } + draining
        for frame in held { frame.record.ladder.release(frame.frame) }
    }

    /// `gtk_window_present`.
    public func show() {
        gtk_window_present(tkz_window(window.pointer))
    }

    /// Destroys the window (no `close-request`). The host is inert afterwards.
    public func close() {
        gtk_window_destroy(tkz_window(window.pointer))
    }

    /// Ladders still held because a frame or a texture over their dma-bufs is alive.
    public var heldLadders: Int { ladders.count }

    // MARK: CanvasHost

    public func requestFrame() {
        needsDraw = true
        canvas.queueDraw()
    }

    public func present(_ frame: LadderFrame, from ladder: PresentationLadder) {
        stats.presents += 1
        drain()
        let record = self.record(for: ladder)
        do {
            let texture = try self.texture(for: frame, in: record)
            queue.submit(HeldFrame(frame: frame, record: record, texture: texture)) { [weak self] held in
                self?.release(held)
            }
        } catch {
            stats.importFailures += 1
            shellLog.error("""
                canvas: GDK cannot import a \(frame.rung.description, privacy: .public) frame: \
                \(String(describing: error), privacy: .public); stepping the presentation ladder down
                """)
            do {
                try ladder.importFailed(frame, reason: String(describing: error))
            } catch {
                shellLog.fault("canvas: the presentation ladder cannot step down: \(String(describing: error), privacy: .public)")
            }
            requestFrame()
        }
        pruneLadders()
    }

    public func visibilityUpdates() -> AsyncStream<CanvasVisibility> { visibilityBroadcast.subscribe() }

    public func inputEvents() -> AsyncStream<CanvasInputEvent> { inputBroadcast.subscribe() }

    // MARK: CanvasWidgetDelegate

    public func canvasSnapshot(_ canvas: CanvasWidget, snapshot: OpaquePointer) {
        stats.snapshots += 1
        updateGeometry()
        drain()
        if needsDraw {
            needsDraw = false
            if !geometry.isEmpty, let client {
                stats.draws += 1
                client.canvasHostDraw(self)
            }
        }
        let promoted = queue.pending != nil
        let held = queue.show()
        if promoted { stats.shows += 1 }
        pruneLadders()

        var bounds = graphene_rect_t()
        bounds.size.width = Float(geometry.logicalWidth)
        bounds.size.height = Float(geometry.logicalHeight)
        if let held, !geometry.isEmpty {
            gtk_snapshot_append_texture(snapshot, held.texture.pointer, &bounds)
        } else {
            var black = GdkRGBA(red: 0, green: 0, blue: 0, alpha: 1)
            gtk_snapshot_append_color(snapshot, &black, &bounds)
        }
    }

    /// The surface's size snapped down to whole device pixels: what the window gives the offload
    /// widget (start-aligned) and the canvas. GtkWidget's own measure before there is a surface.
    public func canvasMeasure(_ canvas: CanvasWidget, orientation: GtkOrientation, forSize: Int32) -> CanvasWidget.Measure? {
        guard let surface else { return nil }
        let snapped = CanvasGeometry.presentable(
            logicalWidth: Int(gdk_surface_get_width(surface)), logicalHeight: Int(gdk_surface_get_height(surface)),
            scale: gdk_surface_get_scale(surface))
        let natural = orientation == GTK_ORIENTATION_HORIZONTAL ? snapped.logicalWidth : snapped.logicalHeight
        return CanvasWidget.Measure(minimum: 0, natural: Int32(natural))
    }

    public func canvasSizeAllocate(_ canvas: CanvasWidget, width: Int32, height: Int32, baseline: Int32) {
        updateGeometry()
    }

    public func canvasRealize(_ canvas: CanvasWidget) {
        guard let native = gtk_widget_get_native(canvas.widget.pointer),
              let surface = gtk_native_get_surface(native) else { return }
        self.surface = surface
        surfaceSignals = [
            Signals.connect(surface, "notify::scale", withArgument: { [weak self] _ in self?.surfaceResized() }),
            Signals.connect(surface, "notify::width", withArgument: { [weak self] _ in self?.surfaceResized() }),
            Signals.connect(surface, "notify::height", withArgument: { [weak self] _ in self?.surfaceResized() }),
            Signals.connect(surface, "notify::mapped", withArgument: { [weak self] _ in self?.updateState() }),
            Signals.connect(surface, "notify::state", withArgument: { [weak self] _ in self?.updateState() }),
        ]
        gtk_widget_queue_resize(canvas.widget.pointer)
        updateGeometry()
        updateState()
    }

    public func canvasUnrealize(_ canvas: CanvasWidget) {
        if let surface {
            for id in surfaceSignals where id != 0 { Signals.disconnect(surface, id) }
        }
        surfaceSignals = []
        surface = nil
        queue.releaseAll()
        // The surface is gone, and with it every wl_buffer: nothing reads the images any more.
        for held in draining { held.record.ladder.release(held.frame) }
        draining = []
        pruneLadders()
        setVisibility(.hidden)
        if focused {
            focused = false
            inputBroadcast.send(.focus(false))
        }
    }

    // MARK: Geometry and state

    /// The surface's size or scale changed: the canvas's measure did too.
    private func surfaceResized() {
        gtk_widget_queue_resize(canvas.widget.pointer)
        updateGeometry()
    }

    /// Re-reads the canvas's logical size and its surface's scale; a change reaches the client and
    /// asks for a frame.
    private func updateGeometry() {
        let width = Int(gtk_widget_get_width(canvas.widget.pointer))
        let height = Int(gtk_widget_get_height(canvas.widget.pointer))
        let scale = surface.map { gdk_surface_get_scale($0) } ?? 1
        let next = CanvasGeometry.presentable(logicalWidth: width, logicalHeight: height, scale: scale)
        guard next != geometry else { return }
        let scaleChanged = next.scale != geometry.scale && !geometry.isEmpty
        geometry = next
        stats.geometryChanges += 1
        let trimmed = next.logicalWidth != width || next.logicalHeight != height
            ? " (of \(width)×\(height): whole device pixels for offload)" : ""
        let note = trimmed + (scaleChanged ? " (scale changed)" : "")
        shellLog.info("canvas: \(next.description, privacy: .public)\(note, privacy: .public)")
        client?.canvasHost(self, didChangeGeometry: next)
        requestFrame()
    }

    /// Mapped, suspended and focused, from the toplevel surface.
    private func updateState() {
        guard let surface else { return }
        let state = gdk_toplevel_get_state(tkz_toplevel(UnsafeMutableRawPointer(surface))).rawValue
        setVisibility(CanvasVisibility(
            isMapped: gdk_surface_get_mapped(surface) != 0,
            isSuspended: state & GDK_TOPLEVEL_STATE_SUSPENDED.rawValue != 0))
        let isFocused = state & GDK_TOPLEVEL_STATE_FOCUSED.rawValue != 0
        if isFocused != focused {
            focused = isFocused
            inputBroadcast.send(.focus(isFocused))
        }
    }

    private func setVisibility(_ next: CanvasVisibility) {
        guard next != visibility else { return }
        visibility = next
        visibilityBroadcast.send(next)
    }

    // MARK: Textures and ladders

    /// Gives `held`'s slot back to its ring now if nothing but the host refers to its texture,
    /// else once that is so (`drain`).
    private func release(_ held: HeldFrame) {
        if held.frame.dmabuf != nil && tkz_object_ref_count(held.texture.pointer.gpointer) > 1 {
            stats.deferredReleases += 1
            draining.append(held)
        } else {
            held.record.ladder.release(held.frame)
        }
    }

    /// Releases the draining slots GTK has let go of since.
    private func drain() {
        draining.removeAll { held in
            guard tkz_object_ref_count(held.texture.pointer.gpointer) <= 1 else { return false }
            held.record.ladder.release(held.frame)
            return true
        }
    }

    private func record(for ladder: PresentationLadder) -> LadderRecord {
        if let known = ladders.first(where: { $0.ladder === ladder }) { return known }
        let record = LadderRecord(ladder, lease: TextureLease { [weak self] in self?.pruneLadders() })
        ladders.append(record)
        return record
    }

    /// The texture for `frame`: the slot's kept GdkDmabufTexture (built on first use, and again
    /// after the ladder stepped to another rung), or a new GdkMemoryTexture for a readback frame.
    private func texture(for frame: LadderFrame, in record: LadderRecord) throws -> GObjectRef<OpaquePointer> {
        switch frame.content {
        case .readback(let bytes):
            stats.memoryTextures += 1
            return CanvasTextures.memoryTexture(bytes)
        case .dmabuf(let presented):
            if record.texturesGeneration != frame.generation {
                record.textures = [:]
                record.texturesGeneration = frame.generation
            }
            if let kept = record.textures[presented.slot] {
                stats.textureReuses += 1
                return kept
            }
            let texture = try CanvasTextures.dmabufTexture(presented.dmabuf, display: display, lease: record.lease)
            stats.dmabufTextures += 1
            record.textures[presented.slot] = texture
            return texture
        }
    }

    /// Drops the textures of ladders the host no longer shows, and the ladders themselves once GDK
    /// has finalized every texture over their dma-bufs.
    private func pruneLadders() {
        let current = queue.pending?.frame.record ?? queue.shown?.frame.record
        let held = [queue.pending, queue.shown, queue.previous].compactMap { $0?.frame.record } + draining.map(\.record)
        for record in ladders where record !== current && !held.contains(where: { $0 === record }) {
            record.textures = [:]
        }
        ladders.removeAll { record in
            record !== current && !held.contains { $0 === record } && record.lease.count == 0
        }
    }
}
