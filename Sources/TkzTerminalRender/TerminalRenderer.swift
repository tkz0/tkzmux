// TerminalRenderer — the three-pass Metal renderer (M1.5 / TKZ-11).
// See docs/design.md → Terminal engine → Metal renderer, and TkzShaderTypes.h for the contract.
//
// One instance app-wide: it owns the pipelines, the shared `GlyphCache` (both atlases), the
// `FrameBuilder` and a 3-deep ring of shared `MTLBuffer`s guarded by a semaphore. Sessions come and
// go through `TerminalSurface`; the renderer itself never changes.
//
// Draw order, all into one `.bgra8Unorm` attachment (see Terminal.metal):
//
//   1. background   full-screen triangle, blending OFF, `TkzBgCell[cols*rows]`
//   2. rects-below  filled cursor                       `.triangleStrip` × 4, instanced
//   3. glyphs       one quad per glyph                   both atlases bound, always
//   4. rects-above  underline / strike / hollow cursor   the *same* rect pipeline again
//
// ## The idle guarantee
//
// `dirty == FALSE` and no overlay change ⇒ **no drawable is acquired, not one byte is written to an
// instance buffer, and `render` returns early**. That is the headline acceptance criterion of this
// ticket, so it is instrumented rather than asserted: `stats` counts bytes written, drawables
// acquired, frames encoded and frames skipped, and the tests read those counters.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore
import TkzCore
import TkzShaderTypes
import UniformTypeIdentifiers

// MARK: - Stats

/// Instrumentation for the idle guarantee. Reset with `TerminalRenderer.resetStats()`.
public struct RenderStats: Sendable, Hashable {
    /// Frames actually encoded and committed.
    public var framesEncoded = 0
    /// Frames that returned early because nothing changed (or nothing was attached).
    public var framesSkipped = 0
    /// Frames that got as far as asking for a render target (`nextDrawable()` on the layer path).
    /// The idle guarantee is `drawableRequests == 0` for a skipped frame.
    public var drawableRequests = 0
    /// `CAMetalLayer.nextDrawable()` calls that returned a drawable.
    public var drawablesAcquired = 0
    /// Bytes copied into the bg / glyph / rect instance buffers.
    public var instanceBytesWritten = 0
    /// Bytes of `TkzUniforms` pushed with `setVertexBytes` / `setFragmentBytes`.
    public var uniformBytesWritten = 0

    public init() {}
}

/// What one `render` call did. Not `Sendable`: it carries the `MTLCommandBuffer` so the caller can
/// `waitUntilCompleted()` (offscreen readback) or simply drop it (on-screen presentation).
public struct RenderOutcome {
    public let didEncode: Bool
    public let commandBuffer: MTLCommandBuffer?
    public let update: FrameUpdate
    public let glyphCount: Int
    public let rectCount: Int

    /// The frame was skipped because nothing changed.
    public var wasSkipped: Bool { !didEncode }
}

// MARK: - TerminalRenderer

public final class TerminalRenderer {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let glyphCache: GlyphCache
    public let frameBuilder: FrameBuilder

    /// Theme used for the letterbox and the selection tint.
    public var theme: Theme {
        get { frameBuilder.theme }
        set { frameBuilder.theme = newValue }
    }

    /// `TkzUniforms.minContrast`. `1.0` (the default) disables the adjustment; `1.1` is the
    /// "only fix invisible text" setting design.md suggests.
    public var minContrast: Float = 1.0

    public private(set) var stats = RenderStats()

    private let bgPipeline: MTLRenderPipelineState
    private let rectPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState

    /// 3-deep ring: the CPU may be writing frame N+2's buffers while the GPU still reads frame N's.
    private static let ringDepth = 3
    private let inflight = DispatchSemaphore(value: TerminalRenderer.ringDepth)
    private var slots: [FrameSlot]
    private var slotIndex = 0

    private final class FrameSlot {
        var background: MTLBuffer?
        var glyphs: MTLBuffer?
        var rectsBelow: MTLBuffer?
        var rectsAbove: MTLBuffer?
    }

    // MARK: - Init

    /// - Parameters:
    ///   - device: the Metal device; defaults to the system default.
    ///   - fontSet: the font set the glyph cache rasterizes with.
    ///   - theme: colours for the letterbox and the selection tint.
    public convenience init(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        fontSet: FontSet? = nil,
        theme: Theme = .default
    ) throws {
        guard let device else { throw RenderError(result: -1, operation: "MTLCreateSystemDefaultDevice") }
        let resolvedFontSet = fontSet ?? FontSet(
            family: theme.fontMono.family,
            fallback: theme.fontMono.fallback,
            pointSize: theme.fontMono.terminal,
            scale: 2)
        try self.init(
            device: device,
            glyphCache: GlyphCache(fontSet: resolvedFontSet, device: device, thicken: theme.fontMono.thicken),
            theme: theme)
    }

    public init(device: MTLDevice, glyphCache: GlyphCache, theme: Theme = .default) throws {
        self.device = device
        self.glyphCache = glyphCache
        self.frameBuilder = FrameBuilder(glyphCache: glyphCache, theme: theme)
        guard let queue = device.makeCommandQueue() else {
            throw RenderError(result: -1, operation: "MTLDevice.makeCommandQueue")
        }
        self.commandQueue = queue
        // The glyph pipeline declares both atlas textures; Metal validation faults on an unbound
        // argument even when the branch that samples it is not taken, so a CPU-only GlyphCache
        // (`device: nil`) can never drive a real renderer.
        guard glyphCache.grayscale.texture != nil, glyphCache.color.texture != nil else {
            throw RenderError(result: -1,
                              operation: "TerminalRenderer needs a GlyphCache built with a device")
        }

        let library = try TerminalRenderer.makeLibrary(device: device)
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else {
                throw RenderError(result: -1, operation: "MTLLibrary.makeFunction(\(name))")
            }
            return f
        }
        bgPipeline = try device.makeRenderPipelineState(
            descriptor: TerminalRenderer.descriptor(
                vertex: try function(TKZ_FN_BG_VERTEX),
                fragment: try function(TKZ_FN_BG_FRAGMENT),
                blending: false))
        rectPipeline = try device.makeRenderPipelineState(
            descriptor: TerminalRenderer.descriptor(
                vertex: try function(TKZ_FN_RECT_VERTEX),
                fragment: try function(TKZ_FN_RECT_FRAGMENT),
                blending: true))
        glyphPipeline = try device.makeRenderPipelineState(
            descriptor: TerminalRenderer.descriptor(
                vertex: try function(TKZ_FN_GLYPH_VERTEX),
                fragment: try function(TKZ_FN_GLYPH_FRAGMENT),
                blending: true))

        slots = (0..<TerminalRenderer.ringDepth).map { _ in FrameSlot() }
    }

    /// The hand-built `default.metallib` inside the `.app` if it has our entry points, else the
    /// `makeLibrary(source:)` fallback that `swift run` / `swift test` take.
    ///
    /// `makeLibrary(source:)` has no include search path, so the header's text is prepended;
    /// Terminal.metal guards its `#include` with `#if !defined(TKZ_SHADER_TYPES_H)`, which is why
    /// the header uses a classic include guard and not `#pragma once`.
    static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let bundled = try? device.makeDefaultLibrary(bundle: .main),
           bundled.makeFunction(name: TKZ_FN_BG_VERTEX) != nil {
            return bundled
        }
        guard let headerURL = ModuleResources.bundle.url(forResource: "Shaders/TkzShaderTypes.h", withExtension: nil),
              let shaderURL = ModuleResources.bundle.url(forResource: "Shaders/Terminal.metal", withExtension: nil)
        else { throw RenderError(result: -1, operation: "Bundle.module Shaders/*") }
        let source = try String(contentsOf: headerURL, encoding: .utf8)
            + "\n#line 1 \"Terminal.metal\"\n"
            + String(contentsOf: shaderURL, encoding: .utf8)
        return try device.makeLibrary(source: source, options: nil)
    }

    private static func descriptor(
        vertex: MTLFunction, fragment: MTLFunction, blending: Bool
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        // Quads come from [[vertex_id]] + [[instance_id]]; there is no vertex buffer to describe.
        descriptor.vertexDescriptor = nil
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = blending
        if blending {
            // Every fragment function returns premultiplied.
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return descriptor
    }

    public func resetStats() { stats = RenderStats() }

    // MARK: - Public render entry points

    /// Renders `surface` into an offscreen texture (tests, `tkzmux-vtdump render --png`).
    ///
    /// The command buffer is committed but **not** waited on — call `waitUntilCompleted()` on
    /// `RenderOutcome.commandBuffer` before reading the texture back.
    @discardableResult
    public func render(surface: TerminalSurface, to texture: MTLTexture) throws -> RenderOutcome {
        try renderFrame(
            surface: surface,
            width: texture.width,
            height: texture.height,
            presentViaCommandBuffer: true,
            forceEncode: false,
            acquire: { (texture, nil) })
    }

    /// Renders `surface` into `layer`'s next drawable and presents it. The seam M1.6 uses.
    ///
    /// A skipped frame never calls `nextDrawable()`, so an idle terminal holds no drawable and the
    /// display link can stay parked.
    ///
    /// When `layer.presentsWithTransaction` is true — the live-resize path — a drawable must NOT be
    /// presented by the command buffer. Core Animation requires the caller to wait for scheduling
    /// and then present on the calling thread, inside the same CATransaction as the layer-bounds
    /// change, or the resize tears. `renderFrame` therefore skips `commandBuffer.present` and this
    /// method does the `waitUntilScheduled()` + `drawable.present()` itself, so the caller does not
    /// have to reach around the renderer to acquire drawables (which would also lose the
    /// `drawablesAcquired` accounting).
    @discardableResult
    public func render(surface: TerminalSurface, layer: CAMetalLayer) throws -> RenderOutcome {
        let size = layer.drawableSize
        let synchronous = layer.presentsWithTransaction
        var acquired: (any CAMetalDrawable)?
        let outcome = try renderFrame(
            surface: surface,
            width: Int(size.width),
            height: Int(size.height),
            presentViaCommandBuffer: !synchronous,
            // `presentsWithTransaction` is a promise to Core Animation that this transaction will
            // be completed by an explicit `present()`. Skipping the frame breaks that promise: the
            // transaction never completes, and a live resize visibly stalls until the flag goes
            // back off on mouse-up. So while it is set, the idle guarantee is suspended and every
            // frame is encoded. It is only ever set during a live resize, so idle cost is unchanged.
            forceEncode: synchronous,
            acquire: { [weak self] in
                guard let drawable = layer.nextDrawable() else { return (nil, nil) }
                self?.stats.drawablesAcquired += 1
                acquired = drawable
                return (drawable.texture, drawable)
            })
        if synchronous, let drawable = acquired, let buffer = outcome.commandBuffer {
            buffer.waitUntilScheduled()
            drawable.present()
        }
        return outcome
    }

    /// A `.bgra8Unorm` `.shared` texture suitable for `render(surface:to:)` and `pngData(from:)`.
    public func makeOffscreenTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: max(1, width), height: max(1, height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    /// The drawable size a `columns × rows` grid needs at the current cell metrics.
    public func drawableSize(columns: Int, rows: Int) -> (width: Int, height: Int) {
        (max(1, columns * glyphCache.metrics.width), max(1, rows * glyphCache.metrics.height))
    }

    // MARK: - The frame

    private func renderFrame(
        surface: TerminalSurface,
        width: Int,
        height: Int,
        presentViaCommandBuffer: Bool,
        forceEncode: Bool,
        acquire: () -> (MTLTexture?, CAMetalDrawable?)
    ) throws -> RenderOutcome {
        // ---- The idle guarantee. Everything below this point is skipped when nothing changed. ---
        guard surface.isAttached else {
            stats.framesSkipped += 1
            return RenderOutcome(didEncode: false, commandBuffer: nil,
                                 update: FrameUpdate(dirty: .none, rowsRebuilt: 0,
                                                     glyphCount: 0, rectCount: 0),
                                 glyphCount: 0, rectCount: 0)
        }
        let update = try frameBuilder.update(surface)
        guard surface.needsDisplay || forceEncode, width > 0, height > 0 else {
            stats.framesSkipped += 1
            return RenderOutcome(didEncode: false, commandBuffer: nil, update: update,
                                 glyphCount: surface.glyphCount, rectCount: surface.rectCount)
        }

        let metrics = glyphCache.metrics
        let geometry = GridGeometry(metrics: metrics, viewportWidth: width, viewportHeight: height)
        let glyphs = surface.glyphInstances()
        let rectsBelow = surface.rectInstancesBelow(geometry: geometry)
        let rectsAbove = surface.rectInstancesAbove(geometry: geometry)

        // One `replace(region:)` per atlas per frame, before anything is encoded.
        glyphCache.flushUploads()

        inflight.wait()
        slotIndex = (slotIndex + 1) % TerminalRenderer.ringDepth
        let slot = slots[slotIndex]

        let backgroundBuffer = upload(surface.backgroundCells, into: &slot.background)
        let glyphBuffer = upload(glyphs, into: &slot.glyphs)
        let belowBuffer = upload(rectsBelow, into: &slot.rectsBelow)
        let aboveBuffer = upload(rectsAbove, into: &slot.rectsAbove)

        // The command buffer is created *before* the drawable is acquired. A drawable that is
        // acquired and never presented is only returned to the layer's pool when it deallocates,
        // and with `maximumDrawableCount = 2` a couple of those make `nextDrawable()` block for
        // about a second each — which looks exactly like a frozen window.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inflight.signal()
            stats.framesSkipped += 1
            return RenderOutcome(didEncode: false, commandBuffer: nil, update: update,
                                 glyphCount: glyphs.count,
                                 rectCount: rectsBelow.count + rectsAbove.count)
        }
        stats.drawableRequests += 1
        let (target, drawable) = acquire()
        guard let target else {
            inflight.signal()
            stats.framesSkipped += 1
            return RenderOutcome(didEncode: false, commandBuffer: nil, update: update,
                                 glyphCount: glyphs.count,
                                 rectCount: rectsBelow.count + rectsAbove.count)
        }

        var uniforms = makeUniforms(surface: surface, geometry: geometry)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor(surface.colors.background)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal()
            stats.framesSkipped += 1
            return RenderOutcome(didEncode: false, commandBuffer: nil, update: update,
                                 glyphCount: glyphs.count,
                                 rectCount: rectsBelow.count + rectsAbove.count)
        }
        encoder.label = "tkzmux terminal frame"

        // 1. Background: one triangle covering the drawable, no blending.
        if let backgroundBuffer, !surface.backgroundCells.isEmpty {
            encoder.setRenderPipelineState(bgPipeline)
            setUniforms(&uniforms, on: encoder)
            encoder.setFragmentBuffer(backgroundBuffer, offset: 0, index: Int(TKZ_BUFFER_INDEX_INSTANCES))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // 2. Rects below the text: the filled cursor.
        drawRects(belowBuffer, count: rectsBelow.count, uniforms: &uniforms, encoder: encoder)

        // 3. Glyphs. Both atlas textures are always bound — Metal validation faults on an unbound
        //    argument the function declares, even when the branch that samples it is not taken.
        if let glyphBuffer, !glyphs.isEmpty {
            encoder.setRenderPipelineState(glyphPipeline)
            setUniforms(&uniforms, on: encoder)
            encoder.setVertexBuffer(glyphBuffer, offset: 0, index: Int(TKZ_BUFFER_INDEX_INSTANCES))
            encoder.setFragmentTexture(glyphCache.grayscale.texture, index: Int(TKZ_TEXTURE_INDEX_GRAYSCALE))
            encoder.setFragmentTexture(glyphCache.color.texture, index: Int(TKZ_TEXTURE_INDEX_COLOR))
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: glyphs.count)
        }

        // 4. Rects above the text: underline, strikethrough, hollow cursor. Same pipeline.
        drawRects(aboveBuffer, count: rectsAbove.count, uniforms: &uniforms, encoder: encoder)

        encoder.endEncoding()

        let semaphore = inflight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        if presentViaCommandBuffer, let drawable { commandBuffer.present(drawable) }
        commandBuffer.commit()

        surface.clearNeedsDisplay()
        stats.framesEncoded += 1
        return RenderOutcome(didEncode: true, commandBuffer: commandBuffer, update: update,
                             glyphCount: glyphs.count,
                             rectCount: rectsBelow.count + rectsAbove.count)
    }

    private func drawRects(
        _ buffer: MTLBuffer?, count: Int,
        uniforms: inout TkzUniforms, encoder: MTLRenderCommandEncoder
    ) {
        guard let buffer, count > 0 else { return }
        encoder.setRenderPipelineState(rectPipeline)
        setUniforms(&uniforms, on: encoder)
        encoder.setVertexBuffer(buffer, offset: 0, index: Int(TKZ_BUFFER_INDEX_INSTANCES))
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: count)
    }

    private func setUniforms(_ uniforms: inout TkzUniforms, on encoder: MTLRenderCommandEncoder) {
        withUnsafeBytes(of: &uniforms) { raw in
            guard let base = raw.baseAddress else { return }
            encoder.setVertexBytes(base, length: raw.count, index: Int(TKZ_BUFFER_INDEX_UNIFORMS))
            encoder.setFragmentBytes(base, length: raw.count, index: Int(TKZ_BUFFER_INDEX_UNIFORMS))
            stats.uniformBytesWritten += raw.count * 2
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
        uniforms.minContrast = minContrast
        uniforms.reserved0 = 0
        uniforms.reserved1 = 0
        uniforms.reserved2 = 0
        return uniforms
    }

    /// Copies `values` into `buffer`, growing it when needed, and counts the bytes.
    /// Returns `nil` (writing nothing) for an empty array — a zero-length buffer must never be bound.
    private func upload<T>(_ values: [T], into buffer: inout MTLBuffer?) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        let length = MemoryLayout<T>.stride * values.count
        if buffer == nil || buffer!.length < length {
            // Round up so a growing screen does not reallocate on every frame.
            let capacity = max(length, (buffer?.length ?? 0) * 2)
            buffer = device.makeBuffer(length: capacity, options: .storageModeShared)
        }
        guard let target = buffer else { return nil }
        values.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            target.contents().copyMemory(from: base, byteCount: length)
        }
        stats.instanceBytesWritten += length
        return target
    }

    private func clearColor(_ packed: UInt32) -> MTLClearColor {
        let color = RGB(packed: packed)
        return MTLClearColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
    }

    // MARK: - Readback

    /// PNG bytes of a `.bgra8Unorm` `.shared` texture. Used by the golden tests and by
    /// `tkzmux-vtdump render --png`.
    public static func pngData(from texture: MTLTexture) -> Data? {
        guard let image = makeCGImage(from: texture) else { return nil }
        return GlyphRasterizer.pngData(from: image)
    }

    /// A `CGImage` of a `.bgra8Unorm` `.shared` texture.
    public static func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Raw BGRA bytes of a `.shared` texture, for pixel-level assertions.
    public static func bgraBytes(of texture: MTLTexture) -> [UInt8] {
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }
}
