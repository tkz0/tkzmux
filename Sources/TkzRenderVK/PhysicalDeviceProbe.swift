// PhysicalDeviceProbe — reads one physical device into the selector's `GPUCandidate` (WOR-313 S1).
//
// Each optional struct is chained only when the device can answer it: the DRM properties need
// VK_EXT_physical_device_drm, and VkPhysicalDeviceVulkan13Features needs a 1.3 device. Chaining
// either one otherwise is invalid usage, and lavapipe (no DRM node) would report a validation
// error for it.

import CVulkan

enum PhysicalDeviceProbe {
    static func candidate(_ device: VkPhysicalDevice, index: Int) throws -> GPUCandidate {
        let extensions = Set(try deviceExtensions(device))

        var drmChain = VulkanChain()
        let drm = extensions.contains(VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME)
            ? drmChain.append(drmProperties()) : nil
        var properties2 = VkPhysicalDeviceProperties2()
        properties2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
        properties2.pNext = drmChain.head
        vkGetPhysicalDeviceProperties2(device, &properties2)
        let properties = properties2.properties
        let apiVersion = VulkanVersion(raw: properties.apiVersion)

        var dynamicRendering = false
        var synchronization2 = false
        if apiVersion.isAtLeast(.required) {
            var featureChain = VulkanChain()
            var vulkan13 = VkPhysicalDeviceVulkan13Features()
            vulkan13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
            let features13 = featureChain.append(vulkan13)
            var features2 = VkPhysicalDeviceFeatures2()
            features2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
            features2.pNext = featureChain.head
            vkGetPhysicalDeviceFeatures2(device, &features2)
            dynamicRendering = features13.pointee.dynamicRendering != 0
            synchronization2 = features13.pointee.synchronization2 != 0
        }

        var primary: DRMNode?
        var render: DRMNode?
        if let drm {
            if drm.pointee.hasPrimary != 0 {
                primary = DRMNode(major: UInt32(truncatingIfNeeded: drm.pointee.primaryMajor),
                                  minor: UInt32(truncatingIfNeeded: drm.pointee.primaryMinor))
            }
            if drm.pointee.hasRender != 0 {
                render = DRMNode(major: UInt32(truncatingIfNeeded: drm.pointee.renderMajor),
                                 minor: UInt32(truncatingIfNeeded: drm.pointee.renderMinor))
            }
        }

        return GPUCandidate(
            index: index,
            name: fixedString(properties.deviceName),
            vendorID: properties.vendorID,
            deviceID: properties.deviceID,
            kind: kind(properties.deviceType),
            apiVersion: apiVersion,
            driverVersion: properties.driverVersion,
            primaryNode: primary,
            renderNode: render,
            dynamicRendering: dynamicRendering,
            synchronization2: synchronization2,
            hasGraphicsQueue: graphicsQueueFamily(device) != nil,
            missingPresentationExtensions: VulkanRequirements.presentationExtensions.filter { !extensions.contains($0) }
        )
    }

    static func deviceExtensions(_ device: VkPhysicalDevice) throws -> [String] {
        var count: UInt32 = 0
        try vkCheck(vkEnumerateDeviceExtensionProperties(device, nil, &count, nil), "vkEnumerateDeviceExtensionProperties")
        var properties = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
        try vkCheck(vkEnumerateDeviceExtensionProperties(device, nil, &count, &properties), "vkEnumerateDeviceExtensionProperties")
        return properties.prefix(Int(count)).map { fixedString($0.extensionName) }
    }

    /// The first queue family with graphics (which implies transfer).
    static func graphicsQueueFamily(_ device: VkPhysicalDevice) -> UInt32? {
        var count: UInt32 = 0
        vkGetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
        var families = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(), count: Int(count))
        vkGetPhysicalDeviceQueueFamilyProperties(device, &count, &families)
        let graphics = VkQueueFlags(VK_QUEUE_GRAPHICS_BIT.rawValue)
        return families.prefix(Int(count)).firstIndex { $0.queueFlags & graphics != 0 && $0.queueCount > 0 }
            .map { UInt32($0) }
    }

    private static func drmProperties() -> VkPhysicalDeviceDrmPropertiesEXT {
        var drm = VkPhysicalDeviceDrmPropertiesEXT()
        drm.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT
        return drm
    }

    private static func kind(_ type: VkPhysicalDeviceType) -> GPUKind {
        switch type {
        case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: .integrated
        case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: .discrete
        case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: .virtual
        case VK_PHYSICAL_DEVICE_TYPE_CPU: .cpu
        default: .other
        }
    }
}
