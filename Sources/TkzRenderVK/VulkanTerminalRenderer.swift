// VulkanTerminalRenderer — the three-pass terminal renderer on Vulkan (WOR-313 S4b); the Metal
// `TerminalRenderer`'s twin. See TkzShaderTypes.h for the contract and TerminalPipelines.swift for
// the pipelines.
//
// One instance app-wide: it owns the pipelines, the shared `GlyphCache` and the images that mirror
// its atlases (`VulkanAtlasUploader`), and the `FrameBuilder`. Each `TerminalSurface` owns its
// `FrameRing` (instance buffers, descriptor sets, command buffer and fence per slot), so N panes in
// one tick never wait on each other.
//
// Draw order, all into one B8G8R8A8_UNORM attachment, as on the Mac:
//
//   1. background   full-screen triangle, blending OFF, `TkzBgCell[cols*rows]`
//   2. rects-below  filled cursor                       TRIANGLE_STRIP × 4, instanced
//   3. glyphs       one quad per glyph                   both atlases bound, always
//   4. rects-above  underline / strike / hollow cursor   the same rect pipeline again
//
// ## Panes
//
// A frame draws one surface into one device-pixel rect of a target that may hold other panes:
// the viewport and the scissor are that rect, and so is the render area, whose `LOAD_OP_CLEAR`
// clears that rect and nothing else. With the viewport on the rect, every vertex position is
// pane-local, exactly the Metal renderer's whole-drawable frame (grid origin 0; the decoration
// rects the surface caches are grid-relative). Only the background fragment works in framebuffer
// pixels (`gl_FragCoord`), so its draw is the one that sees the rect's origin as `gridOriginPx`.
// With the rect covering the whole target, the frame is the Mac's, uniform for uniform. Once the
// frame is submitted the target is told the rect (`didDraw`): the presentation ring copies the
// panes nobody drew from the previous image, and must not copy over this one (WOR-313 S5b).
//
// ## The idle guarantee
//
// `dirty == FALSE` and no overlay change ⇒ **no target is acquired, no ring slot is taken, not one
// byte is written to an instance buffer, and `render` returns early**. The skip check below is the
// Mac's, line for line (it did not move to TkzRenderCore), and runs before anything else; `stats`
// carries the same counters under the same names, and the Linux twins of the Mac's idle tests read
// them.

import CVulkan
import TkzCore
import TkzRenderCore
import TkzShaderTypes

// MARK: - Stats

/// Instrumentation for the idle guarantee; the Mac's `RenderStats`, name for name. Reset with
/// `VulkanTerminalRenderer.resetStats()`.
public struct RenderStats: Sendable, Hashable {
    /// Frames actually recorded and submitted.
    public var framesEncoded = 0
    /// Frames that returned early because nothing changed (or nothing was attached).
    public var framesSkipped = 0
    /// Frames that got as far as asking for a render target. The idle guarantee is
    /// `drawableRequests == 0` for a skipped frame.
    public var drawableRequests = 0
    /// Targets handed over by an `acquire` closure (the presentation ring's images; WOR-313 S5a).
    /// A fixed target passed to `render(surface:to:in:)` is not acquired, like the Mac's offscreen
    /// texture.
    public var drawablesAcquired = 0
    /// Bytes copied into the bg / glyph / rect instance buffers.
    public var instanceBytesWritten = 0
    /// Bytes of `TkzUniforms` pushed with `vkCmdPushConstants`.
    public var uniformBytesWritten = 0

    public init() {}
}

/// A rect in device pixels, origin top-left: where a pane lands in its target.
public struct PixelRect: Sendable, Hashable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The whole of a `width × height` target.
    public init(width: Int, height: Int) {
        self.init(x: 0, y: 0, width: width, height: height)
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The part of this rect inside a `width × height` target; empty when there is none.
    public func clamped(width targetWidth: Int, height targetHeight: Int) -> PixelRect {
        let left = max(x, 0), top = max(y, 0)
        let right = min(x + width, targetWidth), bottom = min(y + height, targetHeight)
        return PixelRect(x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0))
    }

    var vulkan: VkRect2D {
        VkRect2D(offset: VkOffset2D(x: Int32(x), y: Int32(y)), extent: VkExtent2D(width: UInt32(width), height: UInt32(height)))
    }

    public var description: String { "\(width)×\(height)+\(x)+\(y)" }
}

/// A submitted frame, to wait on before reading its target back. Waiting on it after its slot has
/// been reused waits for the newer frame, which is later still: never too early.
public struct SubmittedFrame {
    let ring: FrameRing
    let slot: FrameRing.Slot

    /// Blocks until the frame (and everything submitted before it) has finished on the GPU.
    public func waitUntilCompleted() throws {
        try ring.waitUntilCompleted(slot)
    }
}

/// What one `render` call did. Not `Sendable`: it carries the submission.
public struct RenderOutcome {
    public let didEncode: Bool
    /// The submission, for a caller that reads the target back; nil for a skipped frame.
    public let frame: SubmittedFrame?
    public let update: FrameUpdate
    public let glyphCount: Int
    public let rectCount: Int

    /// The frame was skipped because nothing changed.
    public var wasSkipped: Bool { !didEncode }
}

// MARK: - VulkanTerminalRenderer

public final class VulkanTerminalRenderer {
    public let device: VulkanDevice
    public let glyphCache: GlyphCache
    /// The atlas images the glyph pass samples, kept in step with `glyphCache` once per frame.
    public let atlasUploader: VulkanAtlasUploader
    public let frameBuilder: FrameBuilder

    /// Theme used for the selection tint and `TkzUniforms.minContrast`.
    public var theme: Theme {
        get { frameBuilder.theme }
        set { frameBuilder.theme = newValue }
    }

    public private(set) var stats = RenderStats()

    let pipelines: TerminalPipelines

    public init(device: VulkanDevice, glyphCache: GlyphCache, theme: Theme = .default) throws {
        self.device = device
        self.glyphCache = glyphCache
        self.frameBuilder = FrameBuilder(glyphCache: glyphCache, theme: theme)
        self.atlasUploader = try VulkanAtlasUploader(device: device, cache: glyphCache)
        self.pipelines = try TerminalPipelines(device: device)
    }

    public func resetStats() { stats = RenderStats() }

    /// The target size a `columns × rows` grid needs at the current cell metrics.
    public func drawableSize(columns: Int, rows: Int) -> (width: Int, height: Int) {
        (max(1, columns * glyphCache.metrics.width), max(1, rows * glyphCache.metrics.height))
    }

    // MARK: - Public render entry points

    /// Renders `surface` into `rect` of `target` (the whole target by default): tests, vtdump, the
    /// readback rung. The frame is submitted, not waited on: wait on `RenderOutcome.frame` (or read
    /// the target back, which waits) before looking at the pixels.
    @discardableResult
    public func render(surface: TerminalSurface, to target: some VulkanRenderTarget, in rect: PixelRect? = nil) throws -> RenderOutcome {
        try renderFrame(
            surface: surface, targetWidth: Int(target.width), targetHeight: Int(target.height),
            rect: rect ?? PixelRect(width: Int(target.width), height: Int(target.height)),
            forceEncode: false, acquire: { (target, false) })
    }

    /// Renders `surface` into `rect` of a `targetWidth × targetHeight` target that `acquire`
    /// hands over only once the frame is known to need one: the presentation ring's path
    /// (WOR-313 S5a), where acquiring waits for the compositor to release an image. A skipped frame
    /// never calls `acquire`. `acquire` may return nil (no image to draw into); the frame is then
    /// skipped and the surface stays dirty. The target it returns must have the size given. Every
    /// pane of a window frame calls it, so it hands all of them the same image
    /// (`PresentationLadder.acquire`).
    ///
    /// `forceEncode` suspends the idle guarantee for this call: a clean surface is drawn anyway.
    /// The Mac needs it while `presentsWithTransaction` is set (a skipped frame stalls a live
    /// resize); on Linux it is for the same promise to the toolkit, a configure that must be
    /// answered with a frame (WOR-314). It is never set for an idle tick.
    @discardableResult
    public func render(
        surface: TerminalSurface, targetWidth: Int, targetHeight: Int, in rect: PixelRect? = nil,
        forceEncode: Bool = false, acquire: () throws -> (any VulkanRenderTarget)?
    ) throws -> RenderOutcome {
        try renderFrame(
            surface: surface, targetWidth: targetWidth, targetHeight: targetHeight,
            rect: rect ?? PixelRect(width: targetWidth, height: targetHeight),
            forceEncode: forceEncode,
            acquire: { try acquire().map { ($0, true) } })
    }

    // MARK: - The frame

    private func renderFrame(
        surface: TerminalSurface,
        targetWidth: Int,
        targetHeight: Int,
        rect requested: PixelRect,
        forceEncode: Bool,
        acquire: () throws -> (target: any VulkanRenderTarget, counts: Bool)?
    ) throws -> RenderOutcome {
        // ---- The idle guarantee. Everything below this point is skipped when nothing changed. ---
        guard surface.isAttached else {
            return skipped(FrameUpdate(dirty: .none, rowsRebuilt: 0, glyphCount: 0, rectCount: 0), glyphCount: 0, rectCount: 0)
        }
        let update = try frameBuilder.update(surface)
        let rect = requested.clamped(width: targetWidth, height: targetHeight)
        guard surface.needsDisplay || forceEncode, !rect.isEmpty else {
            return skipped(update, glyphCount: surface.glyphCount, rectCount: surface.rectCount)
        }

        // Pane-local geometry: grid at the viewport's origin, the viewport the pane's rect.
        let geometry = GridGeometry(metrics: glyphCache.metrics, viewportWidth: rect.width, viewportHeight: rect.height)
        let rectsBelow = surface.rectInstancesBelow(geometry: geometry)

        // Lazily, because a `TerminalSurface` has no device of its own: it holds the ring, the
        // renderer creates it on first encode. `acquire` waits on this slot's own fence only.
        let ring = try surface.frameRing(on: device)
        let slot = try ring.acquire()

        // From here every path submits the slot, even one that draws nothing: an atlas upload
        // recorded into it must reach the GPU (`FrameRing.Slot.mustSubmit`).
        var reachedSubmit = false
        do {
            // One copy per atlas per frame, before anything is drawn.
            try atlasUploader.upload(glyphCache, into: slot)

            var buffers: [SlotBuffer: VkBuffer] = [:]
            func keep(_ binding: SlotBinding?, as role: SlotBuffer) {
                guard let binding else { return }
                buffers[role] = binding.buffer
                stats.instanceBytesWritten += binding.byteCount
            }
            keep(try slot.write(surface.backgroundCells, to: .background), as: .background)
            // Borrowed, not returned: the surface flattens into a buffer it keeps.
            let glyphInstanceCount = try surface.withGlyphInstances { instances in
                keep(try slot.write(instances, to: .glyphs), as: .glyphs)
                return instances.count
            }
            let aboveCount = try surface.withRectInstancesAbove(geometry: geometry) { instances in
                keep(try slot.write(instances, to: .rectsAbove), as: .rectsAbove)
                return instances.count
            }
            keep(try slot.write(rectsBelow, to: .rectsBelow), as: .rectsBelow)
            let rectCount = rectsBelow.count + aboveCount

            // The ring slot is taken before the target, as on the Mac (where the command buffer
            // is made before the drawable): once a target is held, no wait on a slot can follow.
            stats.drawableRequests += 1
            guard let acquired = try acquire() else {
                reachedSubmit = true
                try ring.submit(slot)
                return skipped(update, glyphCount: glyphInstanceCount, rectCount: rectCount)
            }
            let target = acquired.target
            if acquired.counts { stats.drawablesAcquired += 1 }
            guard Int(target.width) == targetWidth, Int(target.height) == targetHeight else {
                throw VulkanError("VulkanTerminalRenderer.render (acquired a \(target.width)×\(target.height) target for "
                    + "\(targetWidth)×\(targetHeight))", VK_ERROR_UNKNOWN)
            }

            try record(
                into: slot, target: target, rect: rect, buffers: buffers,
                uniforms: makeUniforms(surface: surface, geometry: geometry),
                counts: (background: surface.backgroundCells.count, below: rectsBelow.count,
                         glyphs: glyphInstanceCount, above: aboveCount),
                clear: surface.colors.background)

            reachedSubmit = true
            try ring.submit(slot)
            target.didDraw(rect)
            surface.clearNeedsDisplay()
            stats.framesEncoded += 1
            return RenderOutcome(didEncode: true, frame: SubmittedFrame(ring: ring, slot: slot), update: update,
                                 glyphCount: glyphInstanceCount, rectCount: rectCount)
        } catch {
            if !reachedSubmit { try? ring.submit(slot) }
            throw error
        }
    }

    private func skipped(_ update: FrameUpdate, glyphCount: Int, rectCount: Int) -> RenderOutcome {
        stats.framesSkipped += 1
        return RenderOutcome(didEncode: false, frame: nil, update: update, glyphCount: glyphCount, rectCount: rectCount)
    }

    /// Records the four passes into `slot`'s command buffer.
    private func record(
        into slot: FrameRing.Slot, target: any VulkanRenderTarget, rect: PixelRect, buffers: [SlotBuffer: VkBuffer],
        uniforms: TkzUniforms, counts: (background: Int, below: Int, glyphs: Int, above: Int), clear: UInt32
    ) throws {
        let commands = try slot.commands()
        if slot.descriptors?.pipelines != ObjectIdentifier(pipelines) {
            slot.descriptors = try FrameDescriptors(device: device, pipelines: pipelines)
        }
        // Rewritten before any bind is recorded (FrameDescriptors).
        let sets = slot.descriptors!.update(
            buffers: buffers, atlases: (atlasUploader.view(for: .grayscale), atlasUploader.view(for: .color)))

        // Into COLOR_ATTACHMENT_OPTIMAL after whatever last touched the target (another pane's frame,
        // a readback). Not from UNDEFINED unless it is new: the other panes' pixels must survive.
        pipelineBarrier(commands, images: [imageBarrier(
            target.image, from: target.layout, to: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            source: lastAccess(of: target.layout),
            destination: (VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                          VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT))])
        target.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL

        // The render area is the pane: LOAD_OP_CLEAR clears that rect only.
        let background = RGB(packed: clear)
        var attachment = VkRenderingAttachmentInfo()
        attachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
        attachment.imageView = target.view
        attachment.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
        attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE
        attachment.clearValue = VkClearValue(color: VkClearColorValue(float32: (
            Float(background.r), Float(background.g), Float(background.b), 1)))
        withUnsafePointer(to: &attachment) { attachment in
            var rendering = VkRenderingInfo()
            rendering.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
            rendering.renderArea = rect.vulkan
            rendering.layerCount = 1
            rendering.colorAttachmentCount = 1
            rendering.pColorAttachments = attachment
            vkCmdBeginRendering(commands, &rendering)
        }

        var viewport = VkViewport(x: Float(rect.x), y: Float(rect.y), width: Float(rect.width), height: Float(rect.height),
                                  minDepth: 0, maxDepth: 1)
        vkCmdSetViewport(commands, 0, 1, &viewport)
        var scissor = rect.vulkan
        vkCmdSetScissor(commands, 0, 1, &scissor)

        // The bg fragment maps `gl_FragCoord` (framebuffer pixels) to cells, so its grid origin is
        // the pane's; every other pass is pane-local through the viewport.
        var pushed = uniforms
        pushed.gridOriginPx = uniforms.gridOriginPx + SIMD2<Float>(Float(rect.x), Float(rect.y))
        push(&pushed, commands)

        // 1. Background: one triangle covering the viewport, no blending.
        if let buffer = sets.instances[.background], counts.background > 0 {
            vkCmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelines.background)
            bind([buffer], commands)
            vkCmdDraw(commands, 3, 1, 0, 0)
        }
        if pushed.gridOriginPx != uniforms.gridOriginPx {
            var origin = uniforms.gridOriginPx
            let offset = UInt32(MemoryLayout<TkzUniforms>.offset(of: \.gridOriginPx)!)
            vkCmdPushConstants(commands, pipelines.layout, TerminalPipelines.pushConstantStages, offset,
                               UInt32(MemoryLayout<SIMD2<Float>>.size), &origin)
            stats.uniformBytesWritten += MemoryLayout<SIMD2<Float>>.size
        }

        // 2. Rects below the text: the filled cursor.
        drawRects(sets.instances[.rectsBelow], count: counts.below, commands)

        // 3. Glyphs, with both atlases bound, always.
        if let buffer = sets.instances[.glyphs], counts.glyphs > 0 {
            vkCmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelines.glyph)
            bind([buffer, sets.atlases], commands)
            vkCmdDraw(commands, 4, UInt32(counts.glyphs), 0, 0)
        }

        // 4. Rects above the text: underline, strikethrough, hollow cursor. Same pipeline.
        drawRects(sets.instances[.rectsAbove], count: counts.above, commands)

        vkCmdEndRendering(commands)
    }

    private func drawRects(_ set: VkDescriptorSet?, count: Int, _ commands: VkCommandBuffer) {
        guard let set, count > 0 else { return }
        vkCmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelines.rect)
        bind([set], commands)
        vkCmdDraw(commands, 4, UInt32(count), 0, 0)
    }

    /// Binds `sets` from set 0 (`TerminalDescriptorSet.instances`) on.
    private func bind(_ sets: [VkDescriptorSet?], _ commands: VkCommandBuffer) {
        sets.withUnsafeBufferPointer { sets in
            vkCmdBindDescriptorSets(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelines.layout, TerminalDescriptorSet.instances,
                                    UInt32(sets.count), sets.baseAddress, 0, nil)
        }
    }

    private func push(_ uniforms: inout TkzUniforms, _ commands: VkCommandBuffer) {
        withUnsafeBytes(of: &uniforms) { raw in
            vkCmdPushConstants(commands, pipelines.layout, TerminalPipelines.pushConstantStages, 0, UInt32(raw.count), raw.baseAddress)
            stats.uniformBytesWritten += raw.count
        }
    }

    private func makeUniforms(surface: TerminalSurface, geometry: GridGeometry) -> TkzUniforms {
        var uniforms = TkzUniforms()
        uniforms.viewportSizePx = geometry.viewportSizePx
        uniforms.cellSizePx = geometry.cellSizePx
        uniforms.gridOriginPx = geometry.originPx
        uniforms.grayscaleAtlasSizePx = SIMD2<Float>(repeating: Float(glyphCache.grayscale.size))
        uniforms.colorAtlasSizePx = SIMD2<Float>(repeating: Float(glyphCache.color.size))
        uniforms.gridSize = SIMD2<UInt32>(UInt32(surface.columns), UInt32(surface.rowCount))
        uniforms.defaultBackground = surface.colors.background
        uniforms.defaultForeground = surface.colors.foreground
        uniforms.cursorColor = surface.colors.effectiveCursor
        // Text under a filled cursor is drawn in the background colour — the classic inversion.
        uniforms.cursorTextColor = surface.colors.background
        uniforms.minContrast = Float(theme.terminalMinContrast)
        uniforms.reserved0 = 0
        uniforms.reserved1 = 0
        uniforms.reserved2 = 0
        return uniforms
    }
}
