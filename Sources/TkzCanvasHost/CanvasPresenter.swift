// CanvasPresenter — a client's ring for one host, kept at the host's size (WOR-314 S4).
//
// Every client of a `CanvasHost` does the same thing per frame: make sure its `PresentationLadder`
// matches the host's pixel size (a new one after a resize or a scale change), acquire the image,
// draw, present it, and hand it to the host. This is that, once. The ladder is made from the
// host's `presentationTarget`, so on the fake host (no formats) it is the readback rung and on
// GTK it is a dma-buf ring with a modifier the compositor imports.

import TkzRenderVK

@MainActor
public final class CanvasPresenter {
    public let device: VulkanDevice
    /// The current ladder; nil until the first frame, or while the canvas is empty.
    public private(set) var ladder: PresentationLadder?
    /// Ladders made so far (one per pixel size the canvas had).
    public private(set) var laddersMade = 0
    /// Overrides the host's `presentationTarget` for the next ladder (diagnostics: an empty format
    /// list forces the readback rung). Nil: the host's.
    public var presentationTarget: CanvasPresentationTarget?

    public init(device: VulkanDevice) {
        self.device = device
    }

    /// The ladder for `host`'s current geometry: the same one while the pixel size holds, a new
    /// one after it changed. Nil for an empty canvas.
    public func ladder(for host: any CanvasHost) throws -> PresentationLadder? {
        let geometry = host.geometry
        guard !geometry.isEmpty else {
            ladder = nil
            return nil
        }
        let width = UInt32(geometry.pixelWidth), height = UInt32(geometry.pixelHeight)
        if let ladder, ladder.width == width, ladder.height == height { return ladder }
        let target = presentationTarget ?? host.presentationTarget
        let made = try PresentationLadder(device: device, width: width, height: height, fourcc: target.fourcc,
                                          offered: target.formats)
        ladder = made
        laddersMade += 1
        return made
    }

    /// One frame for `host`: acquires the image, lets `draw` fill it (told whether it must draw
    /// everything: a new ladder or rung has no previous frame to keep), presents it and hands it to
    /// the host. Returns false when nothing was presented: an empty canvas, or every image still
    /// held by the compositor, in which case it asks the host for another frame itself (the
    /// caller stays dirty).
    @discardableResult
    public func frame(on host: any CanvasHost,
                      draw: (_ target: any VulkanRenderTarget, _ fullRedraw: Bool) throws -> Void) throws -> Bool {
        guard let ladder = try ladder(for: host) else { return false }
        let fullRedraw = ladder.needsFullRedraw
        guard let target = try ladder.acquire() else {
            host.requestFrame()
            return false
        }
        try draw(target, fullRedraw)
        guard let frame = try ladder.present() else { return false }
        host.present(frame, from: ladder)
        return true
    }
}
