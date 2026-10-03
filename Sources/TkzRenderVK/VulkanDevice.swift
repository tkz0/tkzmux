// VulkanDevice — the logical device tkzmux draws with, on the GPU `DeviceSelector` picked
// (WOR-313 S1).
//
// One graphics queue, with `dynamicRendering` and `synchronization2` enabled. When presenting,
// the presentation extensions the device has are enabled too: all of them on a device the selector
// considers able to export, and whichever it reports on a readback-only one (lavapipe has all but
// VK_EXT_physical_device_drm), so WOR-313 S5a can still try an export there. Headless, none are.
//
// Vulkan handles are not Sendable, and neither is this class: it lives where it was made (the main
// actor in the app; one test function in tests).

import CVulkan
import Glibc
import TkzPlatform

public final class VulkanDevice {
    public let instance: VulkanInstance
    public let physicalDevice: VkPhysicalDevice
    public let handle: VkDevice
    public let queue: VkQueue
    public let queueFamily: UInt32
    public let candidate: GPUCandidate
    public let mode: GPUMode
    public let enabledExtensions: [String]
    public let memoryProperties: VkPhysicalDeviceMemoryProperties

    /// Creates the device on `candidate`, which `physicalDevice` describes.
    public init(instance: VulkanInstance, physicalDevice: VkPhysicalDevice, candidate: GPUCandidate, mode: GPUMode) throws {
        guard candidate.isEligible, let family = PhysicalDeviceProbe.graphicsQueueFamily(physicalDevice) else {
            throw VulkanError("vkCreateDevice(\(candidate.name)) (\(candidate.unmetRequirements.joined(separator: ", ")))", VK_ERROR_FEATURE_NOT_PRESENT)
        }
        let extensions = mode == .presenting
            ? VulkanRequirements.presentationExtensions.filter { !candidate.missingPresentationExtensions.contains($0) }
            : []

        var vulkan13 = VkPhysicalDeviceVulkan13Features()
        vulkan13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
        vulkan13.dynamicRendering = VkBool32(VK_TRUE)
        vulkan13.synchronization2 = VkBool32(VK_TRUE)
        var chain = VulkanChain()
        chain.append(vulkan13)

        var priority: Float = 1
        var device: VkDevice?
        let result = withUnsafePointer(to: &priority) { priority in
            var queueInfo = VkDeviceQueueCreateInfo()
            queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            queueInfo.queueFamilyIndex = family
            queueInfo.queueCount = 1
            queueInfo.pQueuePriorities = priority
            return withUnsafePointer(to: &queueInfo) { queueInfo in
                withCStrings(extensions) { names in
                    var info = VkDeviceCreateInfo()
                    info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                    info.pNext = UnsafeRawPointer(chain.head)
                    info.queueCreateInfoCount = 1
                    info.pQueueCreateInfos = queueInfo
                    info.enabledExtensionCount = UInt32(extensions.count)
                    info.ppEnabledExtensionNames = names
                    return vkCreateDevice(physicalDevice, &info, nil, &device)
                }
            }
        }
        try vkCheck(result, "vkCreateDevice(\(candidate.name))")
        guard let device else { throw VulkanError("vkCreateDevice", VK_ERROR_INITIALIZATION_FAILED) }

        var queue: VkQueue?
        vkGetDeviceQueue(device, family, 0, &queue)
        guard let queue else {
            vkDestroyDevice(device, nil)
            throw VulkanError("vkGetDeviceQueue", VK_ERROR_INITIALIZATION_FAILED)
        }

        var memory = VkPhysicalDeviceMemoryProperties()
        vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memory)

        self.instance = instance
        self.physicalDevice = physicalDevice
        self.handle = device
        self.queue = queue
        self.queueFamily = family
        self.candidate = candidate
        self.mode = mode
        self.enabledExtensions = extensions
        self.memoryProperties = memory
    }

    deinit {
        vkDeviceWaitIdle(handle)
        vkDestroyDevice(handle, nil)
    }

    /// The first memory type allowed by `typeBits` that has every flag in `required`.
    public func memoryTypeIndex(typeBits: UInt32, required: VkMemoryPropertyFlags) -> UInt32? {
        let types = withUnsafeBytes(of: memoryProperties.memoryTypes) { Array($0.bindMemory(to: VkMemoryType.self)) }
        for index in 0..<Int(memoryProperties.memoryTypeCount)
        where typeBits & (1 << UInt32(index)) != 0 && types[index].propertyFlags & required == required {
            return UInt32(index)
        }
        return nil
    }
}

// MARK: - Memory and one-shot commands (WOR-313 S4a)

extension VulkanDevice {
    /// Allocates `requirements.size` bytes of the first memory type that has all of `preferred`,
    /// else of the first that has all of `required`.
    func allocateMemory(
        _ requirements: VkMemoryRequirements, preferred: VkMemoryPropertyFlags, required: VkMemoryPropertyFlags,
        for purpose: @autoclosure () -> String
    ) throws -> VkDeviceMemory {
        guard let type = memoryTypeIndex(typeBits: requirements.memoryTypeBits, required: preferred | required)
            ?? memoryTypeIndex(typeBits: requirements.memoryTypeBits, required: required)
        else { throw VulkanError("vkAllocateMemory (no memory type for \(purpose()))", VK_ERROR_OUT_OF_DEVICE_MEMORY) }
        var info = VkMemoryAllocateInfo()
        info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        info.allocationSize = requirements.size
        info.memoryTypeIndex = type
        var memory: VkDeviceMemory?
        try vkCheck(vkAllocateMemory(handle, &info, nil, &memory), "vkAllocateMemory (\(purpose()))")
        guard let memory else { throw VulkanError("vkAllocateMemory (\(purpose()))", VK_ERROR_OUT_OF_DEVICE_MEMORY) }
        return memory
    }

    /// Records `body` into a command buffer of its own, submits it, and waits for it. For
    /// diagnostics and test readbacks only; frames go through a `FrameRing` slot. The submission is
    /// ordered after everything submitted before it on the one queue.
    func submitOnce(_ body: (VkCommandBuffer) throws -> Void) throws {
        var poolInfo = VkCommandPoolCreateInfo()
        poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        poolInfo.flags = VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_TRANSIENT_BIT.rawValue)
        poolInfo.queueFamilyIndex = queueFamily
        var pool: VkCommandPool?
        try vkCheck(vkCreateCommandPool(handle, &poolInfo, nil, &pool), "vkCreateCommandPool")
        defer { vkDestroyCommandPool(handle, pool, nil) }

        var allocateInfo = VkCommandBufferAllocateInfo()
        allocateInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocateInfo.commandPool = pool
        allocateInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocateInfo.commandBufferCount = 1
        var commands: VkCommandBuffer?
        try vkCheck(vkAllocateCommandBuffers(handle, &allocateInfo, &commands), "vkAllocateCommandBuffers")
        guard let commands else { throw VulkanError("vkAllocateCommandBuffers", VK_ERROR_INITIALIZATION_FAILED) }

        var fenceInfo = VkFenceCreateInfo()
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        var fence: VkFence?
        try vkCheck(vkCreateFence(handle, &fenceInfo, nil, &fence), "vkCreateFence")
        defer { vkDestroyFence(handle, fence, nil) }

        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
        try vkCheck(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer")
        try body(commands)
        try vkCheck(vkEndCommandBuffer(commands), "vkEndCommandBuffer")

        var commandInfo = VkCommandBufferSubmitInfo()
        commandInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO
        commandInfo.commandBuffer = commands
        let result = withUnsafePointer(to: &commandInfo) { commandInfo in
            var submit = VkSubmitInfo2()
            submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2
            submit.commandBufferInfoCount = 1
            submit.pCommandBufferInfos = commandInfo
            return vkQueueSubmit2(queue, 1, &submit, fence)
        }
        try vkCheck(result, "vkQueueSubmit2")
        try vkCheck(vkWaitForFences(handle, 1, &fence, VkBool32(VK_TRUE), UInt64.max), "vkWaitForFences")
    }
}

// MARK: - Bootstrap

/// Everything the bootstrap found, for `vtdump gpu` and the log.
public struct GPUBootstrapReport: Sendable {
    public var candidates: [GPUCandidate]
    public var selection: DeviceSelection
    public var preference: GPUPreference
    public var mainDevice: DRMNode?
}

extension VulkanDevice {
    /// Enumerates `instance`'s devices, selects one (``DeviceSelector``), logs the choice and its
    /// reason, and creates the device. `preference` defaults to `TKZMUX_GPU`. `mainDevice` is the
    /// compositor's dmabuf-feedback `main_device`; WOR-314 S4 supplies it, vtdump and tests pass nil.
    public static func make(
        instance: VulkanInstance, mode: GPUMode, mainDevice: DRMNode? = nil, preference: GPUPreference? = nil
    ) throws -> (device: VulkanDevice, report: GPUBootstrapReport) {
        let resolvedPreference: GPUPreference
        if let preference {
            resolvedPreference = preference
        } else {
            let parsed = GPUPreference.parse(ProcessEnvironment.value(GPUPreference.environmentVariable))
            if let warning = parsed.warning { vulkanLog.warning("\(warning, privacy: .public)") }
            resolvedPreference = parsed.preference
        }

        let physical = try instance.physicalDevices()
        let candidates = try physical.enumerated().map { try PhysicalDeviceProbe.candidate($1, index: $0) }
        let selection = try DeviceSelector.select(candidates, mode: mode, mainDevice: mainDevice, preference: resolvedPreference)
        let chosen = selection.candidate
        vulkanLog.notice("""
            GPU \(chosen.index): \(chosen.name, privacy: .public) (\(chosen.kind.rawValue, privacy: .public), \
            Vulkan \(chosen.apiVersion.description, privacy: .public), \(mode.rawValue, privacy: .public)): \
            \(selection.reason.description, privacy: .public)
            """)
        for warning in selection.warnings { vulkanLog.warning("\(warning, privacy: .public)") }

        let device = try VulkanDevice(instance: instance, physicalDevice: physical[chosen.index], candidate: chosen, mode: mode)
        let report = GPUBootstrapReport(candidates: candidates, selection: selection, preference: resolvedPreference, mainDevice: mainDevice)
        return (device, report)
    }
}

/// `getenv` as a String, without Foundation.
enum ProcessEnvironment {
    static func value(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }
}
