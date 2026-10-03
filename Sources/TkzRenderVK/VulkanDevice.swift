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
