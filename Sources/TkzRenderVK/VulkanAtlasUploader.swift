// VulkanAtlasUploader — the Vulkan side of the glyph atlases (WOR-313 S4a); `MetalAtlasUploader`'s
// twin.
//
// TkzRenderCore's `GlyphAtlas` packs into a CPU staging array and keeps one dirty bounding box. This
// owns the two sampled images that mirror a `GlyphCache`'s atlases: R8_UNORM coverage at 2048², and
// B8G8R8A8_UNORM colour at 1024² growing to 2048² (UNORM, never _SRGB: ADR-0003). Once per frame,
// before the frame draws, `upload(_:into:)` takes each atlas's dirty box, copies its rows into the
// frame slot's staging buffer, and records one `vkCmdCopyBufferToImage` per atlas between
// synchronization2 barriers in the slot's command buffer. An atlas with nothing pending records
// nothing, so an idle frame costs no upload.
//
// When an atlas has grown, a new image of the new size replaces the old one first; the grow marked
// the whole atlas dirty, so the same call fills it. A new image the pending box does not cover is
// cleared to zero first, so every texel is defined, as it is in the staging array.
//
// Replaced images are destroyed late, keyed on a fence: `FrameRing.Slot.retire(_:)` keeps the old
// image until the fence of the slot recording the grow has signalled, which also covers every frame
// any surface submitted before it (FrameRing.swift). That holds while each frame is recorded and
// submitted before the next frame's upload is recorded, which is how the renderer drives the rings.
// For the same reason, a frame that recorded an upload must be submitted even if it then draws
// nothing: the atlas has already forgotten the box, and the image's tracked layout assumes the
// copy ran. The slot asserts this when it comes round again (`FrameRing.Slot.mustSubmit`).
//
// Not `Sendable`; lives with the renderer, like the `GlyphCache` it mirrors.

import CVulkan
import TkzRenderCore

extension AtlasKind {
    /// The image format: coverage bytes, or premultiplied BGRA in memory order.
    public var vulkanFormat: VkFormat { self == .grayscale ? VK_FORMAT_R8_UNORM : VK_FORMAT_B8G8R8A8_UNORM }
}

/// Upload instrumentation, read by the tests.
public struct AtlasUploadStats: Sendable, Hashable {
    /// `vkCmdCopyBufferToImage` calls recorded.
    public var copies = 0
    /// Bytes copied into staging buffers for those copies.
    public var bytesUploaded = 0
    /// Images created, the first two included.
    public var imagesCreated = 0
    /// Images replaced because their atlas grew.
    public var imagesReplaced = 0
}

/// One atlas image, its memory and its view. Its layout is tracked as commands are recorded, which
/// is also the order they execute in (one queue, frames submitted in recording order).
final class AtlasImage {
    let device: VulkanDevice
    let kind: AtlasKind
    let size: Int
    let image: VkImage
    let view: VkImageView
    private let memory: VkDeviceMemory
    /// UNDEFINED until the first upload; SHADER_READ_ONLY_OPTIMAL between recorded uploads.
    var layout = VK_IMAGE_LAYOUT_UNDEFINED

    init(device: VulkanDevice, kind: AtlasKind, size: Int) throws {
        let vk = device.handle
        var cleanup: [() -> Void] = []
        var committed = false
        defer { if !committed { cleanup.reversed().forEach { $0() } } }

        var imageInfo = VkImageCreateInfo()
        imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        imageInfo.imageType = VK_IMAGE_TYPE_2D
        imageInfo.format = kind.vulkanFormat
        imageInfo.extent = VkExtent3D(width: UInt32(size), height: UInt32(size), depth: 1)
        imageInfo.mipLevels = 1
        imageInfo.arrayLayers = 1
        imageInfo.samples = VK_SAMPLE_COUNT_1_BIT
        imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL
        // TRANSFER_SRC for `VulkanAtlasUploader.readback`.
        imageInfo.usage = VkImageUsageFlags(VK_IMAGE_USAGE_SAMPLED_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
            | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue)
        imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
        var image: VkImage?
        try vkCheck(vkCreateImage(vk, &imageInfo, nil, &image), "vkCreateImage(atlas \(size)²)")
        cleanup.append { vkDestroyImage(vk, image, nil) }

        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(vk, image, &requirements)
        let memory = try device.allocateMemory(
            requirements, preferred: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue), required: 0,
            for: "a \(size)² atlas")
        cleanup.append { vkFreeMemory(vk, memory, nil) }
        try vkCheck(vkBindImageMemory(vk, image, memory, 0), "vkBindImageMemory")

        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image = image
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        viewInfo.format = kind.vulkanFormat
        viewInfo.subresourceRange = colorSubresourceRange
        var view: VkImageView?
        try vkCheck(vkCreateImageView(vk, &viewInfo, nil, &view), "vkCreateImageView")
        guard let image, let view else {
            if let view { vkDestroyImageView(vk, view, nil) }
            throw VulkanError("AtlasImage (a create call returned no handle)", VK_ERROR_INITIALIZATION_FAILED)
        }

        self.device = device
        self.kind = kind
        self.size = size
        self.image = image
        self.view = view
        self.memory = memory
        committed = true
    }

    deinit {
        let vk = device.handle
        vkDestroyImageView(vk, view, nil)
        vkDestroyImage(vk, image, nil)
        vkFreeMemory(vk, memory, nil)
    }
}

/// The GPU copies of one `GlyphCache`'s atlases. Owned by the renderer that draws with the cache.
public final class VulkanAtlasUploader {
    public let device: VulkanDevice
    private(set) var grayscale: AtlasImage
    private(set) var color: AtlasImage
    public private(set) var stats = AtlasUploadStats()
    /// Increments whenever either image is replaced, so the renderer knows to point its
    /// descriptors at the new view.
    public private(set) var imageGeneration = 0

    /// Images at the cache's current atlas sizes. Their contents arrive with the first `upload`.
    public init(device: VulkanDevice, cache: GlyphCache) throws {
        self.device = device
        grayscale = try AtlasImage(device: device, kind: .grayscale, size: cache.grayscale.size)
        color = try AtlasImage(device: device, kind: .color, size: cache.color.size)
        stats.imagesCreated = 2
    }

    deinit {
        // Frames still in flight may sample the images, and the uploader keeps no fence of its own.
        // Dropping a renderer is rare (teardown, a device change), so waiting for the queue is fine.
        vkQueueWaitIdle(device.queue)
    }

    /// The view to bind for `kind` (WOR-313 S4b binds both, always).
    public func view(for kind: AtlasKind) -> VkImageView { image(for: kind).view }

    /// The edge length of the `kind` image.
    public func size(of kind: AtlasKind) -> Int { image(for: kind).size }

    func image(for kind: AtlasKind) -> AtlasImage { kind == .grayscale ? grayscale : color }

    // MARK: - Upload

    /// Records everything `cache` staged since the last call into `slot`: at most one copy per
    /// atlas. Call once per frame, before the frame draws; the slot must then be submitted.
    public func upload(_ cache: GlyphCache, into slot: FrameRing.Slot) throws {
        // 1. A grown atlas gets a new image; the old one lives until the slot's fence.
        for atlas in [cache.grayscale, cache.color] where image(for: atlas.kind).size != atlas.size {
            let replacement = try AtlasImage(device: device, kind: atlas.kind, size: atlas.size)
            slot.retire(image(for: atlas.kind))
            if atlas.kind == .grayscale { grayscale = replacement } else { color = replacement }
            stats.imagesCreated += 1
            stats.imagesReplaced += 1
            imageGeneration += 1
        }

        // 2. What each atlas needs: its pending box, and a clear when its image is new and the box
        //    does not cover it.
        struct Job {
            let atlas: GlyphAtlas
            let image: AtlasImage
            let region: AtlasRegion?
            let stagingOffset: Int
            let clear: Bool
        }
        var jobs: [Job] = []
        var stagingBytes = 0
        for atlas in [cache.grayscale, cache.color] {
            let image = image(for: atlas.kind)
            let region = atlas.pendingRegion.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
            let isNew = image.layout == VK_IMAGE_LAYOUT_UNDEFINED
            guard region != nil || isNew else {
                atlas.takePendingRegion()  // an empty box: nothing to copy
                continue
            }
            let coversImage = region.map { $0.x == 0 && $0.y == 0 && $0.width == image.size && $0.height == image.size } ?? false
            jobs.append(Job(atlas: atlas, image: image, region: region, stagingOffset: stagingBytes, clear: isNew && !coversImage))
            if let region {
                // A copy's bufferOffset must be a multiple of the texel size (4 for BGRA).
                stagingBytes += (region.width * region.height * atlas.kind.bytesPerPixel + 15) & ~15
            }
        }
        guard !jobs.isEmpty else { return }
        let commands = try slot.commands()
        slot.requireSubmission()

        // 3. The rows, tightly packed, into the slot's staging buffer. The boxes are taken only
        //    once the bytes are safely staged.
        var staging: HostBuffer?
        if stagingBytes > 0 {
            let buffer = try slot.buffer(.staging, atLeast: stagingBytes)
            staging = buffer
            for job in jobs {
                guard let region = job.region else { continue }
                let bpp = job.atlas.kind.bytesPerPixel
                let rowBytes = region.width * bpp
                let stride = job.atlas.bytesPerRow
                job.atlas.staging.withUnsafeBytes { source in
                    guard let base = source.baseAddress else { return }
                    for row in 0..<region.height {
                        (buffer.mapped + job.stagingOffset + row * rowBytes).copyMemory(
                            from: base + (region.y + row) * stride + region.x * bpp, byteCount: rowBytes)
                    }
                }
                job.atlas.takePendingRegion()
                stats.bytesUploaded += rowBytes * region.height
            }
        }

        // 4. Record: into TRANSFER_DST (after the fragment reads of earlier frames), clear, copy,
        //    back to SHADER_READ_ONLY for this frame's fragment reads.
        let transfer: VulkanScope = (VK_PIPELINE_STAGE_2_COPY_BIT | VK_PIPELINE_STAGE_2_CLEAR_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT)
        let sampling: VulkanScope = (VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT, VK_ACCESS_2_SHADER_SAMPLED_READ_BIT)
        pipelineBarrier(commands, images: jobs.map { job in
            let isNew = job.image.layout == VK_IMAGE_LAYOUT_UNDEFINED
            return imageBarrier(job.image.image, from: job.image.layout, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                source: isNew ? (VK_PIPELINE_STAGE_2_NONE, VK_ACCESS_2_NONE) : (sampling.stage, VK_ACCESS_2_NONE),
                                destination: transfer)
        })

        var zero = VkClearColorValue(float32: (0, 0, 0, 0))
        var range = colorSubresourceRange
        let cleared = jobs.filter(\.clear)
        for job in cleared {
            vkCmdClearColorImage(commands, job.image.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &zero, 1, &range)
        }
        // The copy may overwrite cleared texels: order the two writes.
        pipelineBarrier(commands, images: cleared.filter { $0.region != nil }.map { job in
            imageBarrier(job.image.image, from: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                         source: (VK_PIPELINE_STAGE_2_CLEAR_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT),
                         destination: (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT))
        })

        if let staging {
            for job in jobs {
                guard let region = job.region else { continue }
                var copy = VkBufferImageCopy()
                copy.bufferOffset = VkDeviceSize(job.stagingOffset)
                copy.bufferRowLength = 0  // tightly packed
                copy.bufferImageHeight = 0
                copy.imageSubresource = VkImageSubresourceLayers(
                    aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
                copy.imageOffset = VkOffset3D(x: Int32(region.x), y: Int32(region.y), z: 0)
                copy.imageExtent = VkExtent3D(width: UInt32(region.width), height: UInt32(region.height), depth: 1)
                vkCmdCopyBufferToImage(commands, staging.handle, job.image.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy)
                stats.copies += 1
            }
        }

        pipelineBarrier(commands, images: jobs.map { job in
            imageBarrier(job.image.image, from: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, to: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                         source: transfer, destination: sampling)
        })
        for job in jobs { job.image.layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL }
    }

    // MARK: - Readback

    /// The whole `kind` image as tightly packed rows, top row first, in the atlas staging layout:
    /// after an upload has been submitted, it equals `GlyphAtlas.staging`. Waits for the GPU;
    /// diagnostics and tests only. Nil before the first upload, when the image has no contents.
    func readback(_ kind: AtlasKind) throws -> [UInt8]? {
        let atlas = image(for: kind)
        guard atlas.layout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else { return nil }
        let byteCount = atlas.size * atlas.size * kind.bytesPerPixel
        let buffer = try HostBuffer(device: device, capacity: byteCount,
                                    usage: VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue), placement: .readback)
        try device.submitOnce { commands in
            let reading: VulkanScope = (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_READ_BIT)
            pipelineBarrier(commands, images: [imageBarrier(
                atlas.image, from: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, to: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                source: (VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT), destination: reading)])
            var copy = VkBufferImageCopy()
            copy.imageSubresource = VkImageSubresourceLayers(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
            copy.imageExtent = VkExtent3D(width: UInt32(atlas.size), height: UInt32(atlas.size), depth: 1)
            vkCmdCopyImageToBuffer(commands, atlas.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer.handle, 1, &copy)
            pipelineBarrier(
                commands,
                images: [imageBarrier(atlas.image, from: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, to: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                      source: (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_NONE),
                                      destination: (VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_NONE))],
                buffers: [bufferBarrier(buffer.handle, source: (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT),
                                        destination: (VK_PIPELINE_STAGE_2_HOST_BIT, VK_ACCESS_2_HOST_READ_BIT))])
        }
        return Array(UnsafeRawBufferPointer(start: buffer.mapped, count: byteCount))
    }
}
