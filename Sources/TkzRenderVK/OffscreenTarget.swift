// OffscreenTarget — a headless B8G8R8A8_UNORM colour target with BGRA readback (WOR-313 S1).
//
// The headless mode's target: vtdump, tests, and (WOR-313 S5b) the last rung of the presentation
// ladder all read frames back through it. The format is UNORM, never _SRGB: blending is gamma-space
// on the Mac, and parity means identical encoded bytes (ADR-0003). Readback rows are tightly packed
// (`width * 4` bytes), B, G, R, A per pixel, top row first, like the Metal renderer's `bgraBytes`.
//
// S1 clears it (through dynamic rendering, so the bootstrap exercises both required 1.3
// features). Since S4b it is also a `VulkanRenderTarget`: `VulkanTerminalRenderer` draws panes into
// it from their own `FrameRing` slots, and `bgraBytes()` reads the result back.

import CVulkan

/// One B8G8R8A8 pixel, in memory order.
public struct BGRA8: Hashable, Sendable, CustomStringConvertible {
    public var b: UInt8, g: UInt8, r: UInt8, a: UInt8

    public init(b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        self.b = b
        self.g = g
        self.r = r
        self.a = a
    }

    public var description: String {
        "BGRA(" + [b, g, r, a].map { String($0, radix: 16, uppercase: true) }.joined(separator: ",") + ")"
    }
}

public final class OffscreenTarget: VulkanRenderTarget {
    public static let format = VK_FORMAT_B8G8R8A8_UNORM

    public let device: VulkanDevice
    public let width: UInt32
    public let height: UInt32

    public let image: VkImage
    public let view: VkImageView
    /// Tracked as commands are recorded, here and by the renderer (`VulkanRenderTarget`).
    public var layout = VK_IMAGE_LAYOUT_UNDEFINED
    private let imageMemory: VkDeviceMemory
    private let readback: VkBuffer
    private let readbackMemory: VkDeviceMemory
    private let mapped: UnsafeMutableRawPointer
    private let pool: VkCommandPool
    private let commands: VkCommandBuffer
    private let fence: VkFence

    /// The readback buffer size: tightly packed BGRA rows.
    public var byteCount: Int { Int(width) * Int(height) * 4 }

    public init(device: VulkanDevice, width: UInt32, height: UInt32) throws {
        precondition(width > 0 && height > 0, "OffscreenTarget needs a non-empty size")
        let vk = device.handle
        self.device = device
        self.width = width
        self.height = height

        // Each step below frees what the earlier ones made if it fails: `cleanup` runs in reverse.
        var cleanup: [() -> Void] = []
        var committed = false
        defer { if !committed { cleanup.reversed().forEach { $0() } } }

        var imageInfo = VkImageCreateInfo()
        imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        imageInfo.imageType = VK_IMAGE_TYPE_2D
        imageInfo.format = Self.format
        imageInfo.extent = VkExtent3D(width: width, height: height, depth: 1)
        imageInfo.mipLevels = 1
        imageInfo.arrayLayers = 1
        imageInfo.samples = VK_SAMPLE_COUNT_1_BIT
        imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL
        imageInfo.usage = VkImageUsageFlags(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue)
        imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
        var image: VkImage?
        try vkCheck(vkCreateImage(vk, &imageInfo, nil, &image), "vkCreateImage")
        cleanup.append { vkDestroyImage(vk, image, nil) }

        var imageRequirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(vk, image, &imageRequirements)
        let deviceLocal = VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
        guard let imageType = device.memoryTypeIndex(typeBits: imageRequirements.memoryTypeBits, required: deviceLocal)
            ?? device.memoryTypeIndex(typeBits: imageRequirements.memoryTypeBits, required: 0)
        else { throw VulkanError("vkAllocateMemory (no memory type for the offscreen image)", VK_ERROR_OUT_OF_DEVICE_MEMORY) }
        let imageMemory = try Self.allocate(vk, size: imageRequirements.size, type: imageType)
        cleanup.append { vkFreeMemory(vk, imageMemory, nil) }
        try vkCheck(vkBindImageMemory(vk, image, imageMemory, 0), "vkBindImageMemory")

        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image = image
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        viewInfo.format = Self.format
        viewInfo.subresourceRange = colorSubresourceRange
        var view: VkImageView?
        try vkCheck(vkCreateImageView(vk, &viewInfo, nil, &view), "vkCreateImageView")
        cleanup.append { vkDestroyImageView(vk, view, nil) }

        var bufferInfo = VkBufferCreateInfo()
        bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        bufferInfo.size = VkDeviceSize(width) * VkDeviceSize(height) * 4
        bufferInfo.usage = VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue)
        bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        var readback: VkBuffer?
        try vkCheck(vkCreateBuffer(vk, &bufferInfo, nil, &readback), "vkCreateBuffer")
        cleanup.append { vkDestroyBuffer(vk, readback, nil) }

        // Cached when the device offers it (reading uncached write-combined memory is slow);
        // coherent always, so no invalidate is needed after the fence.
        var bufferRequirements = VkMemoryRequirements()
        vkGetBufferMemoryRequirements(vk, readback, &bufferRequirements)
        let coherent = VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue)
        let cached = coherent | VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_HOST_CACHED_BIT.rawValue)
        guard let bufferType = device.memoryTypeIndex(typeBits: bufferRequirements.memoryTypeBits, required: cached)
            ?? device.memoryTypeIndex(typeBits: bufferRequirements.memoryTypeBits, required: coherent)
        else { throw VulkanError("vkAllocateMemory (no host-visible coherent memory for readback)", VK_ERROR_OUT_OF_HOST_MEMORY) }
        let readbackMemory = try Self.allocate(vk, size: bufferRequirements.size, type: bufferType)
        cleanup.append { vkFreeMemory(vk, readbackMemory, nil) }
        try vkCheck(vkBindBufferMemory(vk, readback, readbackMemory, 0), "vkBindBufferMemory")
        var mapped: UnsafeMutableRawPointer?
        try vkCheck(vkMapMemory(vk, readbackMemory, 0, VkDeviceSize(VK_WHOLE_SIZE), 0, &mapped), "vkMapMemory")

        var poolInfo = VkCommandPoolCreateInfo()
        poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        poolInfo.flags = VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
        poolInfo.queueFamilyIndex = device.queueFamily
        var pool: VkCommandPool?
        try vkCheck(vkCreateCommandPool(vk, &poolInfo, nil, &pool), "vkCreateCommandPool")
        cleanup.append { vkDestroyCommandPool(vk, pool, nil) }

        var allocateInfo = VkCommandBufferAllocateInfo()
        allocateInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocateInfo.commandPool = pool
        allocateInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocateInfo.commandBufferCount = 1
        var commands: VkCommandBuffer?
        try vkCheck(vkAllocateCommandBuffers(vk, &allocateInfo, &commands), "vkAllocateCommandBuffers")

        var fenceInfo = VkFenceCreateInfo()
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        var fence: VkFence?
        try vkCheck(vkCreateFence(vk, &fenceInfo, nil, &fence), "vkCreateFence")

        guard let image, let view, let readback, let mapped, let pool, let commands, let fence else {
            if let fence { vkDestroyFence(vk, fence, nil) }
            throw VulkanError("OffscreenTarget (a create call returned no handle)", VK_ERROR_INITIALIZATION_FAILED)
        }
        self.image = image
        self.imageMemory = imageMemory
        self.view = view
        self.readback = readback
        self.readbackMemory = readbackMemory
        self.mapped = mapped
        self.pool = pool
        self.commands = commands
        self.fence = fence
        committed = true
    }

    deinit {
        // `clear` and `bgraBytes` wait for their fence before they return or throw; a frame the
        // renderer drew into the image may still be in flight, so wait for the queue.
        vkQueueWaitIdle(device.queue)
        let vk = device.handle
        vkDestroyFence(vk, fence, nil)
        vkDestroyCommandPool(vk, pool, nil)
        vkUnmapMemory(vk, readbackMemory)
        vkDestroyBuffer(vk, readback, nil)
        vkFreeMemory(vk, readbackMemory, nil)
        vkDestroyImageView(vk, view, nil)
        vkDestroyImage(vk, image, nil)
        vkFreeMemory(vk, imageMemory, nil)
    }

    /// Clears the whole target to `color` with a dynamic-rendering `LOAD_OP_CLEAR`, copies it into
    /// the readback buffer, waits for the GPU and returns the bytes.
    public func clear(to color: BGRA8) throws -> [UInt8] {
        try record { commands in
            // From UNDEFINED: the clear discards the old contents. The source scope still orders
            // the clear after whatever last wrote the image (a frame the renderer drew into it).
            pipelineBarrier(commands, images: [imageBarrier(
                image, from: VK_IMAGE_LAYOUT_UNDEFINED, to: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                source: lastAccess(of: layout),
                destination: (VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT))])
            layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL

            var attachment = VkRenderingAttachmentInfo()
            attachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
            attachment.imageView = view
            attachment.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
            attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE
            attachment.clearValue = VkClearValue(color: VkClearColorValue(float32: (
                Float(color.r) / 255, Float(color.g) / 255, Float(color.b) / 255, Float(color.a) / 255)))
            withUnsafePointer(to: &attachment) { attachment in
                var rendering = VkRenderingInfo()
                rendering.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
                rendering.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: width, height: height))
                rendering.layerCount = 1
                rendering.colorAttachmentCount = 1
                rendering.pColorAttachments = attachment
                vkCmdBeginRendering(commands, &rendering)
                vkCmdEndRendering(commands)
            }
            recordReadback(commands)
        }
        return Array(UnsafeRawBufferPointer(start: mapped, count: byteCount))
    }

    /// The image as it is now (after everything submitted to the queue so far, such as the frames
    /// a `VulkanTerminalRenderer` drew into it), as tightly packed BGRA rows, top row first: the
    /// Metal renderer's `bgraBytes(of:)`. Waits for the GPU. An image nothing has written yet reads
    /// back undefined bytes.
    public func bgraBytes() throws -> [UInt8] {
        try record { recordReadback($0) }
        return Array(UnsafeRawBufferPointer(start: mapped, count: byteCount))
    }

    // MARK: Helpers

    /// Records the copy of the whole image into the readback buffer, made visible to the host.
    private func recordReadback(_ commands: VkCommandBuffer) {
        pipelineBarrier(commands, images: [imageBarrier(
            image, from: layout, to: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            source: lastAccess(of: layout), destination: (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_READ_BIT))])
        layout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL

        var region = VkBufferImageCopy()
        region.imageSubresource = VkImageSubresourceLayers(
            aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
        region.imageExtent = VkExtent3D(width: width, height: height, depth: 1)
        vkCmdCopyImageToBuffer(commands, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &region)

        // Make the copy visible to the host read after the fence.
        pipelineBarrier(commands, buffers: [bufferBarrier(
            readback, source: (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT),
            destination: (VK_PIPELINE_STAGE_2_HOST_BIT, VK_ACCESS_2_HOST_READ_BIT))])
    }

    /// Records `body` into the target's command buffer, submits it and waits for its fence, which
    /// also covers everything submitted to the queue before it.
    private func record(_ body: (VkCommandBuffer) -> Void) throws {
        let vk = device.handle
        try vkCheck(vkResetFences(vk, 1, [fence]), "vkResetFences")
        try vkCheck(vkResetCommandBuffer(commands, 0), "vkResetCommandBuffer")
        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
        try vkCheck(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer")
        body(commands)
        try vkCheck(vkEndCommandBuffer(commands), "vkEndCommandBuffer")
        try submitAndWait()
    }

    private func submitAndWait() throws {
        var commandInfo = VkCommandBufferSubmitInfo()
        commandInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO
        commandInfo.commandBuffer = commands
        let result = withUnsafePointer(to: &commandInfo) { commandInfo in
            var submit = VkSubmitInfo2()
            submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2
            submit.commandBufferInfoCount = 1
            submit.pCommandBufferInfos = commandInfo
            return vkQueueSubmit2(device.queue, 1, &submit, fence)
        }
        try vkCheck(result, "vkQueueSubmit2")
        try vkCheck(vkWaitForFences(device.handle, 1, [fence], VkBool32(VK_TRUE), UInt64.max), "vkWaitForFences")
    }

    private static func allocate(_ device: VkDevice, size: VkDeviceSize, type: UInt32) throws -> VkDeviceMemory {
        var info = VkMemoryAllocateInfo()
        info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        info.allocationSize = size
        info.memoryTypeIndex = type
        var memory: VkDeviceMemory?
        try vkCheck(vkAllocateMemory(device, &info, nil, &memory), "vkAllocateMemory")
        guard let memory else { throw VulkanError("vkAllocateMemory", VK_ERROR_OUT_OF_DEVICE_MEMORY) }
        return memory
    }
}
