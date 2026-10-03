// GtkPresentation — what the compositor behind a GdkDisplay takes, as TkzCanvasHost's
// `CanvasPresentationTarget` (WOR-314 S4).
//
//   formats      `gdk_display_get_dmabuf_formats`: the (fourcc, modifier) pairs GDK can import and
//                hand to the compositor, LINEAR and the implicit modifier included. The ladder's
//                modifier rung is the intersection of these with what the device exports.
//   mainDevice   the compositor's dmabuf-feedback `main_device`, read by TkzLinuxShim on GDK's own
//                Wayland connection (GDK does not publish it). `VulkanDevice.make(mainDevice:)`
//                picks the GPU with that DRM node, which on the reference machine is the AMD iGPU;
//                rendering on the other GPU turns offload off (WOR-301 S4).
//
// Both are read once per display and logged.

import CGtk
import TkzCanvasHost
import TkzLinuxShim
import TkzPlatform
import TkzRenderVK

let shellLog = TkzLogger(subsystem: "se.tkz.tkzmux", category: "shell")

@MainActor
public enum GtkPresentation {
    private static var targets: [UInt: CanvasPresentationTarget] = [:]

    /// The presentation target of `display` (a `GdkDisplay *`), read once and cached.
    public static func target(for display: OpaquePointer) -> CanvasPresentationTarget {
        let key = UInt(bitPattern: UnsafeRawPointer(display))
        if let known = targets[key] { return known }
        let formats = dmabufFormats(display)
        let mainDevice = self.mainDevice(display)
        let fourcc = DRMFourCC.xrgb8888
        let modifiers = formats.filter { $0.fourcc == fourcc }.map { DRMModifier.hex($0.modifier) }
        shellLog.notice("""
            compositor: main_device \(mainDevice.map(\.description) ?? "unknown", privacy: .public); \
            GDK imports \(formats.count) dma-buf formats, \(modifiers.count) for \(fourcc.description, privacy: .public): \
            \(modifiers.joined(separator: " "), privacy: .public)
            """)
        let target = CanvasPresentationTarget(formats: formats, mainDevice: mainDevice, fourcc: fourcc)
        targets[key] = target
        return target
    }

    /// Every (fourcc, modifier) pair in `gdk_display_get_dmabuf_formats`, in GDK's order.
    static func dmabufFormats(_ display: OpaquePointer) -> [DRMFormat] {
        guard let formats = gdk_display_get_dmabuf_formats(display) else { return [] }
        return (0..<gdk_dmabuf_formats_get_n_formats(formats)).map { index in
            var fourcc: UInt32 = 0
            var modifier: guint64 = 0
            gdk_dmabuf_formats_get_format(formats, index, &fourcc, &modifier)
            return DRMFormat(fourcc: DRMFourCC(rawValue: fourcc), modifier: UInt64(modifier))
        }
    }

    /// The compositor's `main_device`, or nil (logged with the reason).
    static func mainDevice(_ display: OpaquePointer) -> DRMNode? {
        var device: guint64 = 0
        let result = tkz_dmabuf_main_device(display, &device)
        switch result {
        case TKZ_MAIN_DEVICE_FOUND:
            return DRMNode(dev: UInt64(device))
        case TKZ_MAIN_DEVICE_NOT_WAYLAND:
            shellLog.warning("compositor: not a Wayland display, so no dmabuf main_device; the GPU is the loader's first")
        case TKZ_MAIN_DEVICE_NO_LIBWAYLAND:
            shellLog.warning("compositor: libwayland-client is not usable through GDK; no dmabuf main_device")
        case TKZ_MAIN_DEVICE_NO_DMABUF:
            shellLog.warning("compositor: no zwp_linux_dmabuf_v1 v4, so no dmabuf feedback and no main_device")
        default:
            shellLog.warning("compositor: the dmabuf feedback named no main_device")
        }
        return nil
    }
}
