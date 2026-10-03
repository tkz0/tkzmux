// CanvasHost — the one seam between tkzmux's own pixels and the platform shell (WOR-314 S4).
//
// On Linux GTK never draws a visible pixel (ADR-0001): tkzmux renders every frame with Vulkan
// (TkzRenderVK) into a presentation ring and hands it to a host, which shows it. The canvas
// toolkit (TkzCanvasUI, WOR-316) and the Linux app reach the platform only through this protocol,
// never through GTK, so:
//
//   - TkzGtkShell's `GtkCanvasHost` is the real host: GtkWindow → GtkGraphicsOffload → TkzCanvas,
//     each frame a GdkDmabufTexture the compositor scans out or composites as a subsurface;
//   - `FakeCanvasHost` (this module) is the offscreen one, for tests: it presents through CPU
//     readback, so a frame's bytes can be compared without a display;
//   - a raw-Wayland host, WOR-301's fallback if GTK's offload ever fails us, would be a third.
//
// What a host carries:
//
//   geometry               logical size and the surface scale; frames are `pixelWidth ×
//                          pixelHeight`, round(logical × scale), so one texel is one device pixel
//   presentationTarget     what the client needs to make its device and ring: the formats the
//                          compositor imports and its dmabuf-feedback `main_device`
//   requestFrame/present   the client asks for a frame; the host calls `canvasHostDraw` on its
//                          frame clock, and the client presents a ring slot (`present(_:from:)`)
//   visibility             mapped and suspended (occlusion), current value plus a stream
//   inputEvents            a stream of input (WOR-315 fills it; focus only for now)
//   textInput, clipboard,  slots for WOR-315 (IME, clipboard) and WOR-317 (popups); nil until those
//   popupHost              land
//   accessibilityRoot      the a11y slot (WOR-316 nodes, bridged to AT-SPI by WOR-325)
//
// Hosts and clients live on the main actor, which on Linux is the GTK thread (MainQueueBridge).

import TkzRenderVK

/// A canvas's size in logical pixels and its surface scale (fractional: 1.6 is 192/120). Never
/// derived from `GDK_SCALE` (ADR-0002 D8): the host reads the scale of the surface it is on.
public struct CanvasGeometry: Sendable, Hashable, CustomStringConvertible {
    public var logicalWidth: Int
    public var logicalHeight: Int
    public var scale: Double

    public init(logicalWidth: Int, logicalHeight: Int, scale: Double) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.scale = scale
    }

    /// Nothing to draw yet (not allocated, or no surface).
    public static let empty = CanvasGeometry(logicalWidth: 0, logicalHeight: 0, scale: 1)

    /// The device pixels `logical` logical pixels cover at `scale`: round(logical × scale). The
    /// texture of a frame is exactly this size, so the compositor maps it texel for pixel.
    public static func devicePixels(_ logical: Int, scale: Double) -> Int {
        Int((Double(logical) * scale).rounded(.toNearestOrAwayFromZero))
    }

    public var pixelWidth: Int { Self.devicePixels(logicalWidth, scale: scale) }
    public var pixelHeight: Int { Self.devicePixels(logicalHeight, scale: scale) }

    public var isEmpty: Bool { pixelWidth <= 0 || pixelHeight <= 0 }

    /// The step, in logical pixels, at which a length covers a whole number of device pixels at
    /// `scale`: 5 at 1.6 (192/120), 4 at 1.25, 1 at any integer scale. Scales are 120ths on
    /// Wayland (wp_fractional_scale_v1); anything else is treated as the nearest 120th.
    public static func wholePixelStep(scale: Double) -> Int {
        let numerator = Int((scale * 120).rounded())
        guard numerator > 0 else { return 1 }
        var a = numerator, b = 120
        while b != 0 { (a, b) = (b, a % b) }
        return 120 / a
    }

    /// The largest geometry within `logicalWidth × logicalHeight` whose sides are whole device
    /// pixels at `scale`, which GTK requires before it offloads a texture to a subsurface: at 1.6 a
    /// 583×646 canvas presents 580×645 (928×1032 px), and the rest of the window (under 5 logical
    /// pixels on the right and at the bottom) is the window's black background.
    public static func presentable(logicalWidth: Int, logicalHeight: Int, scale: Double) -> CanvasGeometry {
        let step = wholePixelStep(scale: scale)
        return CanvasGeometry(logicalWidth: logicalWidth / step * step, logicalHeight: logicalHeight / step * step,
                              scale: scale)
    }

    public var description: String {
        "\(logicalWidth)×\(logicalHeight)@\(scale) → \(pixelWidth)×\(pixelHeight) px"
    }
}

/// Whether the compositor shows the canvas's toplevel.
public struct CanvasVisibility: Sendable, Hashable, CustomStringConvertible {
    /// The surface is mapped.
    public var isMapped: Bool
    /// The compositor says the toplevel is not visible at all (`GDK_TOPLEVEL_STATE_SUSPENDED`:
    /// another workspace, fully covered, minimized). Not every compositor sends it.
    public var isSuspended: Bool

    public init(isMapped: Bool, isSuspended: Bool) {
        self.isMapped = isMapped
        self.isSuspended = isSuspended
    }

    public static let hidden = CanvasVisibility(isMapped: false, isSuspended: false)

    /// Frames drawn now can be seen.
    public var isVisible: Bool { isMapped && !isSuspended }

    public var description: String { isMapped ? (isSuspended ? "suspended" : "visible") : "unmapped" }
}

/// Input delivered to the canvas. WOR-315 adds keys, pointer, scroll and IME.
public enum CanvasInputEvent: Sendable, Hashable {
    /// The toplevel holding the canvas gained (true) or lost (false) keyboard focus.
    case focus(Bool)
}

/// What the client needs to make the device and the ring it presents from.
public struct CanvasPresentationTarget: Sendable, Hashable {
    /// The `(fourcc, modifier)` pairs the host can show as dma-bufs (GDK's
    /// `gdk_display_get_dmabuf_formats`). Empty: present through CPU readback only.
    public var formats: [DRMFormat]
    /// The compositor's dmabuf-feedback `main_device`, for `VulkanDevice.make(mainDevice:)`; nil
    /// when it is unknown.
    public var mainDevice: DRMNode?
    /// The fourcc frames are presented as: XRGB8888, the opaque window.
    public var fourcc: DRMFourCC

    public init(formats: [DRMFormat], mainDevice: DRMNode?, fourcc: DRMFourCC = .xrgb8888) {
        self.formats = formats
        self.mainDevice = mainDevice
        self.fourcc = fourcc
    }

    /// No dma-buf at all: what `FakeCanvasHost` offers.
    public static let readbackOnly = CanvasPresentationTarget(formats: [], mainDevice: nil)
}

/// A rect in the canvas's logical pixels.
public struct CanvasRect: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Slots for later issues

/// Input-method state for the focused text field (WOR-315).
@MainActor
public protocol CanvasTextInput: AnyObject {
    var isEnabled: Bool { get set }
    /// Where the caret is, so the IME places its candidate window next to it.
    func setCursorRect(_ rect: CanvasRect)
    /// Drops any preedit, after the field changes under it.
    func reset()
}

/// Which selection a clipboard call means.
public enum CanvasSelection: Sendable, Hashable {
    case clipboard
    /// The X11-style primary selection (middle-click paste).
    case primary
}

/// The clipboard and the primary selection (WOR-315).
@MainActor
public protocol CanvasClipboard: AnyObject {
    func readText(from selection: CanvasSelection) async -> String?
    func writeText(_ text: String, to selection: CanvasSelection)
}

/// Popups that leave the window's bounds, each with a canvas of its own (WOR-317).
@MainActor
public protocol CanvasPopupHost: AnyObject {
    func openPopup(anchoredAt rect: CanvasRect, width: Int, height: Int) -> any CanvasHost
}

/// The root of the canvas's accessibility tree (WOR-316 gives nodes their id, role, label, value
/// and state; WOR-325 bridges them to AT-SPI through TkzCanvas's accessibility slot).
@MainActor
public protocol CanvasAccessibilityNode: AnyObject {}

// MARK: - The seam

/// Who draws into a host.
@MainActor
public protocol CanvasHostClient: AnyObject {
    /// The canvas's logical size or scale changed. Called before the next `canvasHostDraw`; the
    /// next frame must be `geometry.pixelWidth × pixelHeight` (a new ring when the size changed).
    func canvasHost(_ host: any CanvasHost, didChangeGeometry geometry: CanvasGeometry)
    /// The host's frame clock asks for a frame, after `requestFrame` or a geometry change: draw
    /// what changed and `present` it, or present nothing to keep showing the previous frame.
    func canvasHostDraw(_ host: any CanvasHost)
}

@MainActor
public protocol CanvasHost: AnyObject {
    /// Who draws. Weak in every implementation: the client owns the host, not the other way.
    var client: (any CanvasHostClient)? { get set }

    var geometry: CanvasGeometry { get }
    var presentationTarget: CanvasPresentationTarget { get }

    /// Asks for one `canvasHostDraw` on the next frame. Idempotent until that frame.
    func requestFrame()
    /// Shows `frame` from the next frame on. The host gives the slot back to `ladder` once the
    /// compositor can no longer read it, and steps the ladder down (`importFailed`) when it cannot
    /// show the frame at all. A frame presented while another is still waiting to be shown
    /// replaces it.
    func present(_ frame: LadderFrame, from ladder: PresentationLadder)

    var visibility: CanvasVisibility { get }
    /// The visibility from now on, each change once.
    func visibilityUpdates() -> AsyncStream<CanvasVisibility>
    func inputEvents() -> AsyncStream<CanvasInputEvent>

    var textInput: (any CanvasTextInput)? { get }
    var clipboard: (any CanvasClipboard)? { get }
    var popupHost: (any CanvasPopupHost)? { get }
    var accessibilityRoot: (any CanvasAccessibilityNode)? { get set }
}
