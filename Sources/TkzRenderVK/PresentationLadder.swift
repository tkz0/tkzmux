// PresentationLadder — a window's frames, on the best presentation path that works (WOR-313 S5b).
//
// The rungs, best first:
//
//   negotiatedModifier   a `PresentationRing` with a modifier from the intersection of what the
//                        consumer offers and the device exports (S5a)
//   linear               the same ring with DRM_FORMAT_MOD_LINEAR: every driver reads plain rows
//   implicit             VK_IMAGE_TILING_LINEAR images presented as DRM_FORMAT_MOD_INVALID, for a
//                        consumer whose driver infers the layout
//   readback             no dma-buf at all: one offscreen image, read back into CPU memory every
//                        frame (WOR-314 wraps the bytes in a `GdkMemoryTexture`). Slow at full
//                        resolution, and it cannot be offloaded, so it is logged as an error.
//
// A rung is skipped when the consumer does not offer it (LINEAR and INVALID are entries of
// `gdk_display_get_dmabuf_formats` like any modifier) or the device cannot make it (no export
// extensions, no common modifier, no linear export at this size); each skip is logged with the
// reason. The ladder also steps down when the consumer cannot import a frame: multi-GPU setups
// reject modifiers the device happily exports (WOR-301: Hyprland on the AMD iGPU refuses every
// NVIDIA dma-buf, LINEAR included). `importFailed` retires the ring (kept until the consumer has
// released all of it), excludes its modifier, and makes the next rung; nothing is retried upward.
//
// ## A frame
//
//   needsFullRedraw     true until the current rung has presented: draw every pane (`forceEncode`)
//   acquire()           per pane, from the renderer's acquire seam: the first call takes a ring
//                       image (or the readback image); the others of the same frame get the same one
//   present()           the frame as a dma-buf or as bytes, with its damage; nil when no pane drew
//   release(_:)         the consumer is done with a dma-buf frame (WOR-314: destroy-notify)
//
// Damage is the ring's (`PresentedFrame.damage`); on the readback rung the one image always holds
// the previous frame, so only what was drawn is read back, into a buffer that keeps the rest. Not
// `Sendable`; like the ring it lives on the main actor.

import CVulkan

public enum PresentationRung: Int, Sendable, CaseIterable, Comparable, CustomStringConvertible {
    case negotiatedModifier
    case linear
    case implicit
    case readback

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .negotiatedModifier: "negotiated modifier"
        case .linear: "LINEAR"
        case .implicit: "implicit modifier"
        case .readback: "CPU readback"
        }
    }
}

/// A frame read back into memory: tightly packed B, G, R, A rows (premultiplied), top row first.
public struct ReadbackFrame: Sendable {
    public var width: UInt32
    public var height: UInt32
    public var bytes: [UInt8]
}

/// What `PresentationLadder.present()` hands the consumer.
public struct LadderFrame: Sendable {
    public enum Content: Sendable {
        case dmabuf(PresentedFrame)
        case readback(ReadbackFrame)
    }

    public var rung: PresentationRung
    /// Which of the ladder's rings (or readback images) made the frame, for `release(_:)` after a
    /// step down.
    public var generation: Int
    public var content: Content
    /// Where the frame differs from the previous one, as disjoint rects (WOR-314 S5).
    public var damage: [PixelRect]

    public var dmabuf: PresentedFrame? {
        if case .dmabuf(let frame) = content { frame } else { nil }
    }

    public var readback: ReadbackFrame? {
        if case .readback(let frame) = content { frame } else { nil }
    }
}

public final class PresentationLadder {
    public let device: VulkanDevice
    public let width: UInt32
    public let height: UInt32
    public let fourcc: DRMFourCC
    public let offered: [DRMFormat]
    public private(set) var rung: PresentationRung
    /// The current rung's ring; nil on the readback rung.
    public private(set) var ring: PresentationRing?
    /// Incremented by every rung the ladder settles on.
    public private(set) var generation = 0
    /// Modifiers the consumer failed to import (DRM_FORMAT_MOD_INVALID for the implicit rung).
    public private(set) var failedModifiers: Set<UInt64> = []

    private let sync: PresentationSync?
    private var readbackTarget: ReadbackTarget?
    /// Rings stepped down from, by generation, until the consumer has released their images.
    private(set) var retired: [Int: PresentationRing] = [:]
    private var acquired: (any VulkanRenderTarget)?

    /// Settles on the best rung from `start` on that the consumer offers and the device can make.
    /// `sync` is passed to every ring (nil: the best the device has).
    public init(
        device: VulkanDevice, width: UInt32, height: UInt32, fourcc: DRMFourCC = .xrgb8888, offered: [DRMFormat],
        startingAt start: PresentationRung = .negotiatedModifier, sync: PresentationSync? = nil
    ) throws {
        precondition(width > 0 && height > 0, "PresentationLadder needs a non-empty size")
        self.device = device
        self.width = width
        self.height = height
        self.fourcc = fourcc
        self.offered = offered
        self.sync = sync
        rung = start
        try settle(on: Self.rungs(from: start, offered: offered, fourcc: fourcc, failedModifiers: []))
    }

    /// The rungs from `start` down that are worth trying: those the consumer offers for `fourcc`,
    /// minus modifiers it already failed to import. Readback is always last.
    public static func rungs(
        from start: PresentationRung, offered: [DRMFormat], fourcc: DRMFourCC, failedModifiers: Set<UInt64>
    ) -> [PresentationRung] {
        let modifiers = Set(offered.lazy.filter { $0.fourcc == fourcc }.map(\.modifier)).subtracting(failedModifiers)
        return PresentationRung.allCases.filter { rung in
            guard rung >= start else { return false }
            return switch rung {
            case .negotiatedModifier: modifiers.contains { $0 != DRMModifier.invalid }
            case .linear: modifiers.contains(DRMModifier.linear)
            case .implicit: modifiers.contains(DRMModifier.invalid)
            case .readback: true
            }
        }
    }

    /// The next frame must draw every pane: the current rung has not presented yet, so there is
    /// no previous frame to keep clean panes from.
    public var needsFullRedraw: Bool {
        if let ring { return ring.needsFullRedraw }
        return !(readbackTarget?.holdsFrame ?? false)
    }

    // MARK: - A frame

    /// The image this frame draws into, the same for every pane until `present`, or nil when the
    /// consumer holds every ring image (the frame is skipped and the panes stay dirty).
    public func acquire() throws -> (any VulkanRenderTarget)? {
        if let acquired { return acquired }
        if let ring {
            guard let image = try ring.acquire() else { return nil }
            acquired = image
            return image
        }
        guard let target = readbackTarget else { preconditionFailure("the ladder has a ring or a readback image") }
        if !target.holdsFrame {
            // Whatever no pane covers is black, as on a ring's first frame.
            _ = try target.offscreen.clear(to: BGRA8(b: 0, g: 0, r: 0, a: 0xFF))
        }
        target.drawn = DamageRegion()
        acquired = target
        return target
    }

    /// Presents what this frame drew: a dma-buf to import, or the bytes. Nil when nothing was
    /// acquired (every pane was clean: the idle guarantee holds for the window too).
    public func present() throws -> LadderFrame? {
        guard let target = acquired else { return nil }
        acquired = nil
        if let image = target as? PresentationRing.Image {
            guard let ring, ring.images.contains(where: { $0 === image }) else {
                preconditionFailure("an image is presented by the ladder that acquired it")
            }
            let frame = try ring.present(image)
            return LadderFrame(rung: rung, generation: generation, content: .dmabuf(frame), damage: frame.damage)
        }
        guard let readback = target as? ReadbackTarget else { preconditionFailure("the ladder acquired its own target") }
        let damage = readback.holdsFrame ? readback.drawn.rects : [PixelRect(width: Int(width), height: Int(height))]
        let bytes = try readback.offscreen.bgraBytes(updating: damage)
        readback.holdsFrame = true
        return LadderFrame(rung: .readback, generation: generation,
                           content: .readback(ReadbackFrame(width: width, height: height, bytes: bytes)), damage: damage)
    }

    /// The consumer is done with `frame`. Bytes need no release; a dma-buf frame frees its image,
    /// in a retired ring too (dropped once all of it is free).
    public func release(_ frame: LadderFrame) {
        guard let presented = frame.dmabuf else { return }
        if frame.generation == generation, let ring {
            ring.releaseSlot(presented.slot)
        } else if let old = retired[frame.generation] {
            old.releaseSlot(presented.slot)
            if old.images.allSatisfy({ $0.state == .free }) { retired[frame.generation] = nil }
        }
    }

    /// The consumer could not import `frame` (WOR-314: `gdk_dmabuf_texture_builder_build` failed):
    /// steps down to the next rung that can be made, and releases the frame. The frame is lost;
    /// draw the next one in full (`needsFullRedraw`). A failure reported for a rung the ladder has
    /// already left only releases the frame.
    public func importFailed(_ frame: LadderFrame, reason: String) throws {
        release(frame)
        guard frame.generation == generation, frame.rung != .readback else { return }
        precondition(acquired == nil, "step down between frames")
        if let ring {
            vulkanLog.warning("""
                presentation ladder: the consumer could not import a \(self.rung.description, privacy: .public) frame \
                (\(DRMModifier.hex(ring.modifier), privacy: .public)): \(reason, privacy: .public); stepping down
                """)
            failedModifiers.insert(ring.modifier)
            if !ring.images.allSatisfy({ $0.state == .free }) { retired[generation] = ring }
            self.ring = nil
        }
        try settle(on: Self.rungs(
            from: PresentationRung(rawValue: rung.rawValue + 1) ?? .readback, offered: offered, fourcc: fourcc,
            failedModifiers: failedModifiers))
    }

    // MARK: - Rungs

    /// Makes the first of `rungs` the device can, logging every one it cannot.
    private func settle(on rungs: [PresentationRung]) throws {
        func makeRing(_ layout: PresentationRing.ImageLayout) throws -> PresentationRing {
            try PresentationRing(device: device, width: width, height: height, fourcc: fourcc, layout: layout, sync: sync)
        }
        for candidate in rungs {
            do {
                switch candidate {
                case .negotiatedModifier:
                    ring = try PresentationRing(device: device, width: width, height: height, fourcc: fourcc,
                                                offered: offered, sync: sync)
                case .linear:
                    ring = try makeRing(.modifiers([DRMModifier.linear]))
                case .implicit:
                    ring = try makeRing(.implicit)
                case .readback:
                    ring = nil
                    readbackTarget = try ReadbackTarget(device: device, width: width, height: height)
                    let tenths = (Int(width) * Int(height) * 4 + 50_000) / 100_000
                    vulkanLog.error("""
                        presentation ladder: presenting \(self.width)×\(self.height) through CPU readback on \
                        \(self.device.candidate.name, privacy: .public): no dma-buf, no offload, up to \
                        \(tenths / 10).\(tenths % 10) MB read back per frame
                        """)
                }
                rung = candidate
                generation += 1
                if candidate != .readback {
                    vulkanLog.notice("presentation ladder: \(candidate.description, privacy: .public) (generation \(self.generation))")
                }
                return
            } catch {
                guard candidate != .readback else { throw error }
                vulkanLog.warning("""
                    presentation ladder: no \(candidate.description, privacy: .public) rung: \(String(describing: error), privacy: .public)
                    """)
            }
        }
        preconditionFailure("the readback rung is always tried")
    }
}

/// The readback rung's image: an `OffscreenTarget` that remembers what a frame drew.
final class ReadbackTarget: VulkanRenderTarget {
    let offscreen: OffscreenTarget
    /// A frame has been presented from it, so it holds the previous frame.
    var holdsFrame = false
    var drawn = DamageRegion()

    init(device: VulkanDevice, width: UInt32, height: UInt32) throws {
        offscreen = try OffscreenTarget(device: device, width: width, height: height)
    }

    var image: VkImage { offscreen.image }
    var view: VkImageView { offscreen.view }
    var width: UInt32 { offscreen.width }
    var height: UInt32 { offscreen.height }
    var layout: VkImageLayout {
        get { offscreen.layout }
        set { offscreen.layout = newValue }
    }

    func didDraw(_ rect: PixelRect) {
        drawn.formUnion(rect.clamped(width: Int(width), height: Int(height)))
    }
}
