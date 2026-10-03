// GPUFrameTimer — the GPU time of one terminal frame, from a timestamp-query pair (WOR-313 S6).
//
// For `tkzmux-vtdump bench-frame` only: in-app GPU timestamps are WOR-323 S5's. Set on
// `VulkanTerminalRenderer.frameTimer`, it brackets everything a frame records into its ring slot:
// the pair is reset and the first timestamp written (TOP_OF_PIPE) as soon as the slot's command
// buffer begins, before the atlas upload, and the second (ALL_COMMANDS: once every earlier command
// has finished) after the last pass. A frame skipped by the idle guarantee records neither, and a
// frame that took a slot but found no target to draw into records only the first; `elapsed` is nil
// for both.
//
// One pair, so one frame at a time: read `elapsed` (which waits for the frame) before the next
// encode, as the bench does. A second frame in flight would reset the pair under the first.

import CVulkan

public final class GPUFrameTimer {
    public let device: VulkanDevice
    /// Nanoseconds per timestamp tick (`VkPhysicalDeviceLimits.timestampPeriod`).
    public let period: Double
    /// The queue family's `timestampValidBits`: the bits of a timestamp that count.
    public let validBits: UInt32

    private let pool: VkQueryPool
    /// The frame recorded so far: nothing, the first timestamp, or both.
    private var recorded = 0

    /// Throws when the device's queue cannot write timestamps.
    public init(device: VulkanDevice) throws {
        var properties = VkPhysicalDeviceProperties()
        vkGetPhysicalDeviceProperties(device.physicalDevice, &properties)
        var count: UInt32 = 0
        vkGetPhysicalDeviceQueueFamilyProperties(device.physicalDevice, &count, nil)
        var families = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(), count: Int(count))
        vkGetPhysicalDeviceQueueFamilyProperties(device.physicalDevice, &count, &families)
        let validBits = Int(device.queueFamily) < families.count ? families[Int(device.queueFamily)].timestampValidBits : 0
        guard validBits > 0, properties.limits.timestampPeriod > 0 else {
            throw VulkanError("GPUFrameTimer (\(device.candidate.name) has no timestamps on queue family \(device.queueFamily))",
                              VK_ERROR_FEATURE_NOT_PRESENT)
        }

        var info = VkQueryPoolCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO
        info.queryType = VK_QUERY_TYPE_TIMESTAMP
        info.queryCount = 2
        var pool: VkQueryPool?
        try vkCheck(vkCreateQueryPool(device.handle, &info, nil, &pool), "vkCreateQueryPool")
        guard let pool else { throw VulkanError("vkCreateQueryPool", VK_ERROR_INITIALIZATION_FAILED) }

        self.device = device
        self.period = Double(properties.limits.timestampPeriod)
        self.validBits = validBits
        self.pool = pool
    }

    deinit {
        // The pool may still be named by a submitted frame.
        vkQueueWaitIdle(device.queue)
        vkDestroyQueryPool(device.handle, pool, nil)
    }

    /// Records the reset and the first timestamp at the start of a frame's command buffer.
    func begin(_ commands: VkCommandBuffer) {
        vkCmdResetQueryPool(commands, pool, 0, 2)
        vkCmdWriteTimestamp2(commands, VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, pool, 0)
        recorded = 1
    }

    /// Records the second timestamp after the frame's last command.
    func end(_ commands: VkCommandBuffer) {
        guard recorded == 1 else { return }
        vkCmdWriteTimestamp2(commands, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, pool, 1)
        recorded = 2
    }

    /// The GPU time of the last frame in nanoseconds, waiting for it to finish; nil when the last
    /// frame did not record both timestamps (skipped, or no target). Call it once per frame.
    public func elapsed() throws -> Double? {
        guard recorded == 2 else { return nil }
        recorded = 0
        var ticks: (UInt64, UInt64) = (0, 0)
        let flags = VkQueryResultFlags(VK_QUERY_RESULT_64_BIT.rawValue | VK_QUERY_RESULT_WAIT_BIT.rawValue)
        try withUnsafeMutableBytes(of: &ticks) { raw in
            try vkCheck(vkGetQueryPoolResults(device.handle, pool, 0, 2, raw.count, raw.baseAddress,
                                              VkDeviceSize(MemoryLayout<UInt64>.stride), flags), "vkGetQueryPoolResults")
        }
        let mask: UInt64 = validBits >= 64 ? .max : (1 << UInt64(validBits)) - 1
        // Wrapping subtraction under the mask: a counter that wrapped between the two still counts.
        let delta = ((ticks.1 & mask) &- (ticks.0 & mask)) & mask
        return Double(delta) * period
    }
}
