// `tkzmux --presentation-check` (hidden, WOR-314 S4): one `GtkCanvasHost` window presenting
// Vulkan frames through the real path, for scripts/linux/shell-local.sh and the headless CI test.
//
//   --seconds <s>         how long the window stays up (default 3); it closes itself after
//   --pattern bar         a 1-device-pixel checkerboard with a 64-px bar moving 8 px per frame,
//                         a frame every frame clock tick (the default)
//   --pattern checkerboard
//                         the checkerboard alone, presented once and then held (zero frames), for
//                         a byte-exact screenshot (`grim`) of the window
//   --size <w>x<h>        the window's default logical size (default 800x500)
//   --expect-dmabuf       fail unless the frames went out as dma-bufs (the local offload check)
//   --readback            present through the readback rung (GdkMemoryTexture, composited by
//                         GSK, never offloaded): the comparison case for the screenshot check
//
// The device is chosen with the compositor's dmabuf-feedback `main_device`, exactly as the app
// will; the log names it and why. Each frame uploads only what changed (the bar's old and new
// rects), so the ring copies the rest from the previous image, as it does for a real renderer.
//
// It prints, one line each:
//
//   display <name>
//   compositor main_device=<maj:min|unknown> formats=<n> xrgb8888=<n>
//   gpu <index> <name> kind=<kind> render=<maj:min|-> reason=<why>
//   geometry <logical w>x<h> scale=<s> pixels=<w>x<h>
//   frames presents=<n> shows=<n> snapshots=<n> draws=<n> dmabuf-textures=<n> texture-reuses=<n>
//          memory-textures=<n> import-failures=<n> deferred-releases=<n> geometry-changes=<n> ms=<n>
//   rung <rung> modifier=<hex|-> sync=<syncFile|cpuWait|->
//   validation errors=<n> warnings=<n>
//   boxes baseline=<n> end=<n> texture=<n> canvases-end=<n>
//   presentation-check ok|failed
//
// Exit 0 when frames were presented and shown, no Vulkan validation error was counted, nothing
// was left behind after the window closed (closure and texture boxes, canvases), and with
// --expect-dmabuf the rung was a dma-buf one. 1 otherwise; 77 without a display or a Vulkan device.

import CGtk
import Glibc
import TkzCanvasHost
import TkzGtkShell
import TkzLinuxShim
import TkzRenderVK

@MainActor
enum PresentationCheck {
    enum Pattern: String {
        case bar, checkerboard
    }

    static func run(arguments: [String]) -> Int32 {
        defer { fflush(nil) }
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let seconds = value("--seconds").flatMap(Double.init) ?? 3
        guard let pattern = Pattern(rawValue: value("--pattern") ?? "bar") else {
            print("presentation-check: --pattern is bar or checkerboard")
            return 1
        }
        var size: (width: Int32, height: Int32) = (800, 500)
        if let text = value("--size") {
            let parts = text.split(separator: "x").compactMap { Int32($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
                print("presentation-check: --size wants <w>x<h>")
                return 1
            }
            size = (parts[0], parts[1])
        }
        let expectDmabuf = arguments.contains("--expect-dmabuf")

        MainQueueBridge.attach()
        guard gtk_init_check() != 0, let display = gdk_display_get_default() else {
            print("presentation-check no-display")
            return 77
        }
        print("display \(String(cString: gdk_display_get_name(display)))")
        let boxes = ClosureBoxes.live
        let canvases = CanvasWidget.liveInstances

        var host: GtkCanvasHost? = GtkCanvasHost(title: "tkzmux presentation-check",
                                                 defaultWidth: size.width, defaultHeight: size.height)
        let target = host!.presentationTarget
        print("compositor main_device=\(target.mainDevice.map(\.description) ?? "unknown") "
              + "formats=\(target.formats.count) xrgb8888=\(target.formats.count { $0.fourcc == target.fourcc })")

        let instance: VulkanInstance
        let device: VulkanDevice
        do {
            instance = try VulkanInstance(validation: .ifAvailable)
            let made = try VulkanDevice.make(instance: instance, mode: .presenting, mainDevice: target.mainDevice)
            device = made.device
            let chosen = made.report.selection.candidate
            print("gpu \(chosen.index) \(chosen.name) kind=\(chosen.kind.rawValue) "
                  + "render=\(chosen.renderNode.map(\.description) ?? "-") reason=\(made.report.selection.reason)")
            for warning in made.report.selection.warnings { print("gpu-warning \(warning)") }
        } catch {
            print("presentation-check no-gpu \(error)")
            host?.close()
            return 77
        }

        let presenter = CanvasPresenter(device: device)
        if arguments.contains("--readback") { presenter.presentationTarget = .readbackOnly }
        var client: PatternClient? = PatternClient(presenter: presenter, pattern: pattern)
        host!.client = client
        var closedByUser = false
        host!.onCloseRequest = {
            closedByUser = true
            return false
        }
        host!.show()

        // A frame every frame clock tick for the bar: after each paint, ask for the next.
        var clockSignal: (clock: OpaquePointer, id: SignalHandlerID)?
        let realized = MainQueueBridge.iterate(timeoutMilliseconds: 10_000) {
            gtk_widget_get_realized(host!.canvas.widget.pointer) != 0
        }
        if realized, pattern == .bar, let clock = gtk_widget_get_frame_clock(host!.canvas.widget.pointer) {
            clockSignal = (clock, Signals.connect(clock, "after-paint") { [weak host] in host?.requestFrame() })
        }

        let start = ContinuousClock.now
        let deadline = start + .milliseconds(Int(seconds * 1000))
        _ = MainQueueBridge.iterate(timeoutMilliseconds: UInt32(seconds * 1000)) {
            closedByUser || ContinuousClock.now >= deadline
        }
        let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
        if let clockSignal { Signals.disconnect(clockSignal.clock, clockSignal.id) }

        let stats = host!.stats
        let geometry = host!.geometry
        let ladder = client!.presenter.ladder
        print("geometry \(geometry.logicalWidth)x\(geometry.logicalHeight) scale=\(geometry.scale) "
              + "pixels=\(geometry.pixelWidth)x\(geometry.pixelHeight)")
        print("frames presents=\(stats.presents) shows=\(stats.shows) snapshots=\(stats.snapshots) draws=\(stats.draws) "
              + "dmabuf-textures=\(stats.dmabufTextures) texture-reuses=\(stats.textureReuses) "
              + "memory-textures=\(stats.memoryTextures) import-failures=\(stats.importFailures) "
              + "deferred-releases=\(stats.deferredReleases) "
              + "geometry-changes=\(stats.geometryChanges) ms=\(milliseconds)")
        let rung = ladder?.rung
        print("rung \(rung.map { "\($0)".replacingOccurrences(of: " ", with: "-") } ?? "-") "
              + "modifier=\(ladder?.ring.map { DRMModifier.hex($0.modifier) } ?? "-") "
              + "sync=\(ladder?.ring?.sync.rawValue ?? "-")")
        let log = instance.validationLog
        print("validation errors=\(log.errorCount) warnings=\(log.warningCount)")

        var ok = !client!.failed && stats.presents > 0 && stats.shows > 0 && log.errorCount == 0
        if expectDmabuf { ok = ok && rung != nil && rung != .readback && stats.dmabufTextures > 0 }

        // Close, then wait until GDK has let go of every texture and the canvas is finalized.
        host!.close()
        client = nil
        host = nil
        let released = MainQueueBridge.iterate(timeoutMilliseconds: 10_000) {
            ClosureBoxes.live == boxes && CanvasWidget.liveInstances == canvases
        }
        print("boxes baseline=\(boxes) end=\(ClosureBoxes.live) texture=\(ClosureBoxes.live(.texture)) "
              + "canvases-end=\(CanvasWidget.liveInstances - canvases)")
        ok = ok && released
        print("presentation-check \(ok ? "ok" : "failed")")
        return ok ? 0 : 1
    }

    /// Draws the pattern: the whole checkerboard on a full redraw, then only the bar's old and new
    /// rects.
    @MainActor
    final class PatternClient: CanvasHostClient {
        let presenter: CanvasPresenter
        let pattern: Pattern
        /// The bar's left edge in the image drawn last; nil before the first frame of a ring.
        private var barX: Int?
        private(set) var failed = false

        static let barWidth = 64
        static let barStep = 8
        static let barColor: [UInt8] = [0xE0, 0x80, 0x20, 0xFF]   // B, G, R, A

        init(presenter: CanvasPresenter, pattern: Pattern) {
            self.presenter = presenter
            self.pattern = pattern
        }

        func canvasHost(_ host: any CanvasHost, didChangeGeometry geometry: CanvasGeometry) {
            barX = nil
        }

        func canvasHostDraw(_ host: any CanvasHost) {
            do {
                try presenter.frame(on: host) { target, fullRedraw in
                    let width = Int(target.width), height = Int(target.height)
                    let previous = fullRedraw ? nil : barX
                    let next = pattern == .bar ? ((previous ?? -Self.barStep) + Self.barStep) % max(width, 1) : nil
                    if previous == nil {
                        try upload(PixelRect(width: width, height: height), bar: next, to: target)
                    } else if let previous, let next {
                        try upload(barRect(previous, width: width, height: height), bar: nil, to: target)
                        try upload(barRect(next, width: width, height: height), bar: next, to: target)
                    }
                    barX = next ?? 0
                }
            } catch {
                print("presentation-check frame failed: \(error)")
                failed = true
            }
        }

        private func barRect(_ x: Int, width: Int, height: Int) -> PixelRect {
            PixelRect(x: x, y: 0, width: min(Self.barWidth, width - x), height: height)
        }

        /// Writes `rect` of the pattern (the checkerboard, and the bar where it overlaps `bar`).
        private func upload(_ rect: PixelRect, bar: Int?, to target: any VulkanRenderTarget) throws {
            var bytes = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
            bytes.withUnsafeMutableBufferPointer { buffer in
                var index = 0
                for y in rect.y..<rect.y + rect.height {
                    for x in rect.x..<rect.x + rect.width {
                        if let bar, x >= bar, x < bar + Self.barWidth {
                            buffer[index] = Self.barColor[0]
                            buffer[index + 1] = Self.barColor[1]
                            buffer[index + 2] = Self.barColor[2]
                        } else if (x ^ y) & 1 == 1 {
                            buffer[index] = 0xFF
                            buffer[index + 1] = 0xFF
                            buffer[index + 2] = 0xFF
                        }
                        buffer[index + 3] = 0xFF
                        index += 4
                    }
                }
            }
            try presenter.device.upload(bgra: bytes, width: rect.width, height: rect.height, to: target, x: rect.x, y: rect.y)
        }
    }
}
