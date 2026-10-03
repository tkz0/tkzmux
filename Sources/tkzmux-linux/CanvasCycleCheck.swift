// `tkzmux --canvas-cycle-check [--cycles N]` (hidden, WOR-314 S2): opens and closes N undecorated
// windows, each holding one TkzCanvas, and shows that nothing GTK was handed outlives its window.
//
// Needs a display (`gtk_init_check`): headless sway in CI, the session's compositor locally. The
// process main thread owns the default GMainContext, as it will under `g_application_run`, with
// the main-queue GSource attached. Each cycle presents a window, waits until the canvas is mapped
// and has drawn a frame, moves keyboard focus into it, asks it for its first accessible child,
// closes it with `gtk_window_close` (so `close-request` runs) and waits until the canvas is
// finalized. One more "orphan" cycle drops the CanvasWidget before its window maps, so every
// vfunc there takes GtkWidget's fallback. Then it reports, one line each:
//
//   display <name>
//   cycles n=<n> realize=<n> unrealize=<n> snapshot=<n> measure=<n> size-allocate=<n>
//          focus=<n> a11y=<n> close-request=<n> ms=<n>      the vfuncs that reached the delegate
//   orphan ok|failed
//   boxes baseline=<n> open=<n> end=<n> signal=<n> canvas=<n>
//                                                           ClosureBoxes: before, the most seen
//                                                           while a window was open, after
//   canvases baseline=<n> end=<n>                           live TkzCanvas instances
//   toplevels baseline=<n> end=<n>                          gtk_window_get_toplevels()
//   canvas-cycle-check ok|failed
//
// Exits 0 when every cycle drew; realize, unrealize, the accessibility slot and close-request
// reached the probe once per cycle (snapshot, measure, size-allocate and focus at least once);
// each open window held exactly its three boxes (two signal handlers, one canvas context); and the
// three counts are back at their baselines. 1 otherwise; 77 (skipped, in automake's convention)
// without a display. Under Valgrind or ASan this is the open/close-window test of the asan-valgrind
// job (scripts/linux/asan-valgrind.sh).

import CGtk
import Glibc
import TkzGtkShell
import TkzLinuxShim

@MainActor
enum CanvasCycleCheck {
    static let defaultCycles = 100
    /// Per wait. A frame on a 60 Hz output takes 17 ms; Valgrind slows that down a lot.
    static let timeoutMilliseconds: UInt32 = 20_000

    static func run(arguments: [String]) -> Int32 {
        // Before exit's handlers: LeakSanitizer's ends the process without flushing stdio.
        defer { fflush(nil) }
        var cycles = defaultCycles
        if let index = arguments.firstIndex(of: "--cycles"), index + 1 < arguments.count {
            guard let value = Int(arguments[index + 1]), value > 0 else {
                print("canvas-cycle-check: --cycles needs a positive count")
                return 1
            }
            cycles = value
        }

        MainQueueBridge.attach()
        guard gtk_init_check() != 0, let display = gdk_display_get_default() else {
            print("canvas-cycle-check no-display")
            return 77
        }
        print("display \(String(cString: gdk_display_get_name(display)))")

        let boxes = ClosureBoxes.live
        let canvases = CanvasWidget.liveInstances
        let toplevels = toplevelCount()
        let probe = Probe()
        var ok = true

        let start = ContinuousClock.now
        for cycle in 0..<cycles {
            if let failure = openAndClose(probe) {
                print("cycle \(cycle) \(failure)")
                ok = false
                break
            }
        }
        let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
        let counts = probe.counts
        print("cycles n=\(cycles) realize=\(counts.realize) unrealize=\(counts.unrealize) "
              + "snapshot=\(counts.snapshot) measure=\(counts.measure) size-allocate=\(counts.sizeAllocate) "
              + "focus=\(counts.focus) a11y=\(counts.a11y) close-request=\(counts.closeRequest) ms=\(milliseconds)")
        // GTK's own initial focus on present also reaches `focus`, so it is at least once a cycle.
        ok = ok && counts.realize == cycles && counts.unrealize == cycles && counts.a11y == cycles
            && counts.closeRequest == cycles && counts.focus >= cycles && counts.snapshot >= cycles
            && counts.measure >= cycles && counts.sizeAllocate >= cycles

        let orphan = ok ? openAndCloseOrphan() : "skipped"
        print("orphan \(orphan ?? "ok")")
        ok = ok && orphan == nil && probe.counts == counts

        let boxesEnd = ClosureBoxes.live
        print("boxes baseline=\(boxes) open=\(probe.openBoxes) end=\(boxesEnd) "
              + "signal=\(ClosureBoxes.live(.signal)) canvas=\(ClosureBoxes.live(.canvas))")
        print("canvases baseline=\(canvases) end=\(CanvasWidget.liveInstances)")
        print("toplevels baseline=\(toplevels) end=\(toplevelCount())")
        ok = ok && probe.openBoxes == boxes + 3 && boxesEnd == boxes
            && CanvasWidget.liveInstances == canvases && toplevelCount() == toplevels

        print("canvas-cycle-check \(ok ? "ok" : "failed")")
        return ok ? 0 : 1
    }

    /// One cycle; nil when it went through, else what timed out.
    static func openAndClose(_ probe: Probe) -> String? {
        let instances = CanvasWidget.liveInstances
        let before = probe.counts
        var window: GObjectRef<UnsafeMutablePointer<GtkWidget>>? = makeWindow(probe)
        var canvas: CanvasWidget? = CanvasWidget(delegate: probe)
        gtk_window_set_child(tkz_window(window!.pointer), canvas!.widget.pointer)
        Signals.connect(canvas!.widget.pointer, "notify::scale-factor", withArgument: { _ in })
        gtk_window_present(tkz_window(window!.pointer))

        let drawn = MainQueueBridge.iterate(timeoutMilliseconds: timeoutMilliseconds) {
            gtk_widget_get_mapped(canvas!.widget.pointer) != 0 && probe.counts.snapshot > before.snapshot
        }
        guard drawn else { return "timeout waiting for the first frame" }
        probe.openBoxes = max(probe.openBoxes, ClosureBoxes.live)

        _ = gtk_widget_child_focus(canvas!.widget.pointer, GTK_DIR_TAB_FORWARD)
        if let child = gtk_accessible_get_first_accessible_child(tkz_accessible(canvas!.widget.pointer)) {
            g_object_unref(UnsafeMutableRawPointer(child))
        }

        gtk_window_close(tkz_window(window!.pointer))
        window = nil
        canvas = nil
        let finalized = MainQueueBridge.iterate(timeoutMilliseconds: timeoutMilliseconds) {
            CanvasWidget.liveInstances == instances
        }
        return finalized ? nil : "timeout waiting for the canvas to be finalized"
    }

    /// A cycle whose CanvasWidget is gone before the window maps: GTK still realizes, measures,
    /// draws and unrealizes the canvas, and every vfunc falls back without reaching the probe.
    static func openAndCloseOrphan() -> String? {
        let instances = CanvasWidget.liveInstances
        let probe = Probe()
        var window: GObjectRef<UnsafeMutablePointer<GtkWidget>>? = makeWindow(nil)
        do {
            let canvas = CanvasWidget(delegate: probe)
            gtk_window_set_child(tkz_window(window!.pointer), canvas.widget.pointer)
        }
        gtk_window_present(tkz_window(window!.pointer))
        let child = gtk_window_get_child(tkz_window(window!.pointer))!
        let mapped = MainQueueBridge.iterate(timeoutMilliseconds: timeoutMilliseconds) {
            gtk_widget_get_mapped(child) != 0
        }
        guard mapped else { return "timeout waiting for the orphan to map" }
        // One more frame, so the snapshot vfunc runs too.
        gtk_widget_queue_draw(child)
        _ = MainQueueBridge.iterate(timeoutMilliseconds: 100) { false }
        guard tkz_canvas_get_context(child) != nil else { return "context released while the canvas lives" }

        gtk_window_close(tkz_window(window!.pointer))
        window = nil
        let finalized = MainQueueBridge.iterate(timeoutMilliseconds: timeoutMilliseconds) {
            CanvasWidget.liveInstances == instances
        }
        guard finalized else { return "timeout waiting for the orphan to be finalized" }
        return probe.counts == Probe.Counts() ? nil : "a vfunc reached the released delegate: \(probe.counts)"
    }

    /// An undecorated 320×200 window. With a probe, its `close-request` handler counts the close
    /// and lets it go ahead.
    static func makeWindow(_ probe: Probe?) -> GObjectRef<UnsafeMutablePointer<GtkWidget>> {
        // gtk_window_new is transfer none: GTK's toplevel list owns the window until it is
        // destroyed. This reference is the check's own.
        let window = GObjectRef(retaining: gtk_window_new()!)
        gtk_window_set_decorated(tkz_window(window.pointer), 0)
        gtk_window_set_default_size(tkz_window(window.pointer), 320, 200)
        gtk_window_set_title(tkz_window(window.pointer), "tkzmux canvas-cycle-check")
        if let probe {
            Signals.connect(window.pointer, "close-request", returning: {
                probe.counts.closeRequest += 1
                return false
            })
        }
        return window
    }

    static func toplevelCount() -> UInt32 {
        g_list_model_get_n_items(gtk_window_get_toplevels())
    }

    /// Counts what reached the delegate, and draws one flat colour.
    @MainActor
    final class Probe: CanvasWidgetDelegate {
        struct Counts: Equatable {
            var realize = 0, unrealize = 0, snapshot = 0, measure = 0, sizeAllocate = 0
            var focus = 0, a11y = 0, closeRequest = 0
        }

        var counts = Counts()
        var openBoxes = 0

        func canvasSnapshot(_ canvas: CanvasWidget, snapshot: OpaquePointer) {
            counts.snapshot += 1
            var color = GdkRGBA(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
            var bounds = graphene_rect_t()
            bounds.size.width = Float(gtk_widget_get_width(canvas.widget.pointer))
            bounds.size.height = Float(gtk_widget_get_height(canvas.widget.pointer))
            gtk_snapshot_append_color(snapshot, &color, &bounds)
        }

        func canvasMeasure(_ canvas: CanvasWidget, orientation: GtkOrientation, forSize: Int32) -> CanvasWidget.Measure? {
            counts.measure += 1
            return CanvasWidget.Measure(minimum: 16, natural: orientation == GTK_ORIENTATION_HORIZONTAL ? 320 : 200)
        }

        func canvasSizeAllocate(_ canvas: CanvasWidget, width: Int32, height: Int32, baseline: Int32) {
            counts.sizeAllocate += 1
        }

        func canvasRealize(_ canvas: CanvasWidget) { counts.realize += 1 }

        func canvasUnrealize(_ canvas: CanvasWidget) { counts.unrealize += 1 }

        func canvasFocus(_ canvas: CanvasWidget, direction: GtkDirectionType) -> Bool? {
            counts.focus += 1
            return false
        }

        func canvasFirstAccessibleChild(_ canvas: CanvasWidget) -> OpaquePointer? {
            counts.a11y += 1
            return nil
        }
    }
}
