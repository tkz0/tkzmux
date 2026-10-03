// PixelUpload — CPU pixels into a render target (WOR-314 S4).
//
// For test patterns and diagnostics, not frames: the presentation checks fill ring images with a
// 1-device-pixel checkerboard to prove texel-exact presentation, and offscreen tests of a
// `CanvasHost` fill them with known bytes. One staging buffer and one waited submission per call
// (`submitOnce`), so it is far too slow for a real frame, which goes through a renderer.
//
// The target is told what was written (`didDraw`), like a renderer's pane, so a presentation ring
// copies the rest from the previous image.

import CVulkan

extension VulkanDevice {
    /// Copies `bytes`, tightly packed B, G, R, A rows of a `width × height` rect, into `target` at
    /// (`x`, `y`), and waits for the copy. The rect must lie inside the target.
    public func upload(bgra bytes: [UInt8], width: Int, height: Int, to target: some VulkanRenderTarget,
                       x: Int = 0, y: Int = 0) throws {
        let rect = PixelRect(x: x, y: y, width: width, height: height)
        precondition(!rect.isEmpty && rect.clamped(width: Int(target.width), height: Int(target.height)) == rect,
                     "the upload rect \(rect) lies inside the \(target.width)×\(target.height) target")
        precondition(bytes.count == width * height * 4, "\(bytes.count) bytes for a \(width)×\(height) BGRA rect")
        let staging = try HostBuffer(device: self, capacity: bytes.count,
                                     usage: VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue), placement: .upload)
        bytes.withUnsafeBytes { staging.mapped.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        try submitOnce { commands in
            pipelineBarrier(commands, images: [imageBarrier(
                target.image, from: target.layout, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                source: lastAccess(of: target.layout), destination: (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT))])
            target.layout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
            var copy = VkBufferImageCopy()
            copy.imageSubresource = VkImageSubresourceLayers(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
            copy.imageOffset = VkOffset3D(x: Int32(x), y: Int32(y), z: 0)
            copy.imageExtent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
            vkCmdCopyBufferToImage(commands, staging.handle, target.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy)
        }
        target.didDraw(rect)
    }
}
