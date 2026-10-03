// HostBuffer — a persistently mapped HOST_VISIBLE | HOST_COHERENT buffer (WOR-313 S4a).
//
// What a `FrameRing` slot is made of: instance storage buffers the shaders read, and the staging
// buffer atlas uploads copy from. It is mapped once, at creation, and stays mapped until it is
// destroyed. Coherent memory means a CPU write needs no flush: everything written before
// `vkQueueSubmit2` is visible to the commands it submits.
//
// Not `Sendable`, like every Vulkan object here. It owns its memory and frees it in `deinit`, so
// whoever drops the last reference must know the GPU is done with it; `FrameRing` keeps that
// promise with its per-slot fences.

import CVulkan

final class HostBuffer {
    /// Which memory a buffer prefers, beyond HOST_VISIBLE | HOST_COHERENT (which it always gets).
    enum Placement {
        /// DEVICE_LOCAL when the device has it host-visible (an iGPU, or a dGPU's BAR): data the
        /// GPU reads every frame.
        case gpuRead
        /// Plain system memory: data the GPU reads once, such as a staging buffer.
        case upload
        /// HOST_CACHED when available, so reading GPU results back is not uncached.
        case readback

        var preferred: VkMemoryPropertyFlags {
            switch self {
            case .gpuRead: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
            case .upload: 0
            case .readback: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_HOST_CACHED_BIT.rawValue)
            }
        }
    }

    let device: VulkanDevice
    let handle: VkBuffer
    /// The bytes asked for. The allocation may be larger (alignment); only these are used.
    let capacity: Int
    let mapped: UnsafeMutableRawPointer
    private let memory: VkDeviceMemory

    init(device: VulkanDevice, capacity: Int, usage: VkBufferUsageFlags, placement: Placement) throws {
        precondition(capacity > 0, "HostBuffer needs a non-empty size")
        let vk = device.handle
        var info = VkBufferCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        info.size = VkDeviceSize(capacity)
        info.usage = usage
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        var buffer: VkBuffer?
        try vkCheck(vkCreateBuffer(vk, &info, nil, &buffer), "vkCreateBuffer(\(capacity) bytes)")
        guard let buffer else { throw VulkanError("vkCreateBuffer", VK_ERROR_INITIALIZATION_FAILED) }

        var requirements = VkMemoryRequirements()
        vkGetBufferMemoryRequirements(vk, buffer, &requirements)
        let coherent = VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue)
        let memory: VkDeviceMemory
        do {
            memory = try device.allocateMemory(requirements, preferred: placement.preferred, required: coherent,
                                               for: "a \(capacity)-byte host buffer")
        } catch {
            vkDestroyBuffer(vk, buffer, nil)
            throw error
        }
        var mapped: UnsafeMutableRawPointer?
        let status = vkBindBufferMemory(vk, buffer, memory, 0) == VK_SUCCESS
            ? vkMapMemory(vk, memory, 0, VkDeviceSize(VK_WHOLE_SIZE), 0, &mapped)
            : VK_ERROR_MEMORY_MAP_FAILED
        guard status == VK_SUCCESS, let mapped else {
            vkDestroyBuffer(vk, buffer, nil)
            vkFreeMemory(vk, memory, nil)
            throw VulkanError("vkBindBufferMemory / vkMapMemory", status == VK_SUCCESS ? VK_ERROR_MEMORY_MAP_FAILED : status)
        }

        self.device = device
        self.handle = buffer
        self.capacity = capacity
        self.mapped = mapped
        self.memory = memory
    }

    deinit {
        let vk = device.handle
        vkUnmapMemory(vk, memory)
        vkDestroyBuffer(vk, handle, nil)
        vkFreeMemory(vk, memory, nil)
    }
}
