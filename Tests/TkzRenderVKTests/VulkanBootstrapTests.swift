// VulkanBootstrapTests — instance, messenger, device and the headless clear + readback on a real
// Vulkan device (WOR-313 S1).
//
// They need a Vulkan driver: lavapipe in CI, RADV or NVIDIA on a desktop. Without one they are
// skipped, by name, through `.enabled(if:)`, never by returning early. CI sets
// TKZMUX_REQUIRE_VULKAN=1, which turns a missing device or a missing validation layer into a
// failure instead, so the job cannot pass by skipping. The validation layer is loaded wherever it
// is installed; every test that drew something asserts the messenger counted no error.

import CVulkan
import Glibc
import Testing
@testable import TkzRenderVK

enum VulkanTestEnvironment {
    /// TKZMUX_REQUIRE_VULKAN=1 (CI): no skipping, and the validation layer must be there.
    static let required = getenv("TKZMUX_REQUIRE_VULKAN").map { String(cString: $0) } == "1"

    /// Whether an instance can be made and has at least one physical device.
    static let deviceAvailable: Bool = {
        guard let instance = try? VulkanInstance(), let devices = try? instance.physicalDevices() else { return false }
        return !devices.isEmpty
    }()

    /// Run the GPU tests when there is a device, or when CI requires one (and then fail without it).
    static var runs: Bool { deviceAvailable || required }

    static let skipReason: Comment = "no Vulkan device (TKZMUX_REQUIRE_VULKAN=1 makes this a failure)"

    static var validation: VulkanInstance.Validation { required ? .required : .ifAvailable }

    /// The validation messages, for an assertion's comment.
    static func messages(_ instance: VulkanInstance) -> String {
        instance.validationLog.messages.map { "\($0.id): \($0.text)" }.joined(separator: "\n")
    }
}

/// Tightly packed BGRA bytes where every pixel is not `color`, as a count.
private func pixelsDiffering(_ bytes: [UInt8], from color: BGRA8) -> Int {
    let expected = [color.b, color.g, color.r, color.a]
    return stride(from: 0, to: bytes.count, by: 4).count { !bytes[$0..<$0 + 4].elementsEqual(expected) }
}

@Suite("Vulkan bootstrap", .serialized)
struct VulkanBootstrapTests {

    @Test("CI has a Vulkan device and the validation layer, so the tests below run",
          .enabled(if: VulkanTestEnvironment.required, "TKZMUX_REQUIRE_VULKAN is not set (CI sets it)"))
    func vulkanRequired() throws {
        #expect(VulkanTestEnvironment.deviceAvailable, "no Vulkan device: install a driver (lavapipe: vulkan-swrast)")
        let layers = try VulkanInstance.availableLayers()
        #expect(layers.contains(VulkanInstance.validationLayer), "install vulkan-validation-layers")
    }

    @Test("the instance asks for 1.3, installs the messenger, and the messenger counts errors",
          .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
    func messengerCounts() throws {
        let instance = try VulkanInstance(validation: VulkanTestEnvironment.validation)
        #expect(instance.loaderVersion.isAtLeast(.required))
        #expect(instance.hasMessenger)
        #expect(instance.validationLog.errorCount == 0, "\(VulkanTestEnvironment.messages(instance))")

        // Synthetic messages through vkSubmitDebugUtilsMessageEXT, an extension entry point loaded
        // with vkGetInstanceProcAddr: the counts move by exactly what was sent.
        instance.submitDebugMessage("tkzmux test: synthetic warning", error: false)
        instance.submitDebugMessage("tkzmux test: synthetic error", error: true)
        #expect(instance.validationLog.errorCount == 1)
        #expect(instance.validationLog.warningCount == 1)
        #expect(instance.validationLog.messages.map(\.text) == [
            "tkzmux test: synthetic warning", "tkzmux test: synthetic error",
        ])
    }

    @Test("headless: the selected device clears a B8G8R8A8_UNORM target and reads back exact BGRA bytes",
          .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
    func headlessClearAndReadback() throws {
        let instance = try VulkanInstance(validation: VulkanTestEnvironment.validation)
        let (device, report) = try VulkanDevice.make(instance: instance, mode: .headless, preference: .auto)
        #expect(device.enabledExtensions.isEmpty, "headless enables no presentation extension")
        #expect(report.candidates.contains(report.selection.candidate))

        // An odd size, so a row-pitch mistake cannot hide; distinct channels, so a swizzle cannot.
        let target = try OffscreenTarget(device: device, width: 61, height: 7)
        let first = BGRA8(b: 0x20, g: 0x80, r: 0xC0, a: 0xFF)
        let bytes = try target.clear(to: first)
        #expect(bytes.count == 61 * 7 * 4)
        #expect(Array(bytes.prefix(4)) == [0x20, 0x80, 0xC0, 0xFF], "B, G, R, A in memory")
        #expect(pixelsDiffering(bytes, from: first) == 0)

        // Reusing the target (fence and command buffer reset) with every channel at its extremes
        // and a non-opaque alpha.
        let second = BGRA8(b: 0xFF, g: 0x00, r: 0x01, a: 0x7F)
        #expect(pixelsDiffering(try target.clear(to: second), from: second) == 0)

        #expect(instance.validationLog.errorCount == 0, "\(VulkanTestEnvironment.messages(instance))")
    }

    @Test("every eligible device clears and reads back, headless and presenting",
          .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
    func everyDevice() throws {
        let instance = try VulkanInstance(validation: VulkanTestEnvironment.validation)
        let physical = try instance.physicalDevices()
        let candidates = try physical.enumerated().map { try PhysicalDeviceProbe.candidate($1, index: $0) }
        #expect(candidates.contains { $0.isEligible }, "\(candidates.map(\.name))")
        let color = BGRA8(b: 0x10, g: 0x32, r: 0x54, a: 0xFF)
        for candidate in candidates where candidate.isEligible {
            for mode in [GPUMode.headless, .presenting] {
                let device = try VulkanDevice(instance: instance, physicalDevice: physical[candidate.index],
                                              candidate: candidate, mode: mode)
                let expected = mode == .presenting
                    ? VulkanRequirements.presentationExtensions.filter { !candidate.missingPresentationExtensions.contains($0) }
                    : []
                #expect(device.enabledExtensions == expected, "\(candidate.name) \(mode)")
                let target = try OffscreenTarget(device: device, width: 33, height: 17)
                #expect(pixelsDiffering(try target.clear(to: color), from: color) == 0, "\(candidate.name) \(mode)")
            }
            // A DRM node is what main_device is matched against; a device that says it has the
            // extension must report one.
            if !candidate.missingPresentationExtensions.contains("VK_EXT_physical_device_drm") {
                #expect(candidate.hasDRMNode, "\(candidate.name)")
            }
        }
        #expect(instance.validationLog.errorCount == 0, "\(VulkanTestEnvironment.messages(instance))")
    }

    @Test("selection on the real devices agrees with the pure selector, and main_device picks by node",
          .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
    func realSelection() throws {
        let instance = try VulkanInstance(validation: VulkanTestEnvironment.validation)
        let (device, report) = try VulkanDevice.make(instance: instance, mode: .presenting, preference: .auto)
        let pure = try DeviceSelector.select(report.candidates, mode: .presenting, mainDevice: nil, preference: .auto)
        #expect(device.candidate == pure.candidate)
        #expect(report.selection == pure)

        // Feeding each device's render node in as main_device selects that device.
        for candidate in report.candidates where candidate.isEligible && candidate.canExportToCompositor {
            guard let node = candidate.renderNode else { continue }
            let (byNode, nodeReport) = try VulkanDevice.make(instance: instance, mode: .presenting, mainDevice: node, preference: .auto)
            #expect(byNode.candidate.index == candidate.index)
            #expect(nodeReport.selection.reason == .mainDevice(node, .render))
        }
        #expect(instance.validationLog.errorCount == 0, "\(VulkanTestEnvironment.messages(instance))")
    }
}

@Suite("Vulkan interop")
struct VulkanInteropTests {

    @Test("the shim's version macros agree with VulkanVersion")
    func versionShim() {
        let packed = tkz_vk_make_api_version(0, 1, 3, 290)
        #expect(VulkanVersion(raw: packed) == VulkanVersion(major: 1, minor: 3, patch: 290))
        #expect(tkz_vk_api_version_major(packed) == 1)
        #expect(tkz_vk_api_version_minor(packed) == 3)
        #expect(tkz_vk_api_version_patch(packed) == 290)
        #expect(tkz_vk_api_version_variant(packed) == 0)
        #expect(VulkanVersion(raw: tkz_vk_api_version_1_3()) == .required)
        #expect(VulkanVersion(raw: tkz_vk_header_version_complete()).isAtLeast(.required))
    }

    @Test("a pNext chain links its structs in order and keeps them readable")
    func chain() {
        var chain = VulkanChain()
        #expect(chain.head == nil)
        var drm = VkPhysicalDeviceDrmPropertiesEXT()
        drm.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT
        drm.renderMinor = 129
        let first = chain.append(drm)
        var features = VkPhysicalDeviceVulkan13Features()
        features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
        let second = chain.append(features)

        #expect(chain.head == UnsafeMutableRawPointer(first))
        #expect(first.pointee.pNext == UnsafeMutableRawPointer(second))
        #expect(second.pointee.pNext == nil)
        #expect(first.pointee.renderMinor == 129)
        // Written through the pointer, as a driver writes an output struct.
        second.pointee.dynamicRendering = VkBool32(VK_TRUE)
        #expect(second.pointee.dynamicRendering == VkBool32(VK_TRUE))
        #expect(second.pointee.sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES)
    }

    @Test("fixed-size C strings stop at the NUL, and a full one is read whole")
    func fixedStrings() {
        var properties = VkLayerProperties()
        withUnsafeMutableBytes(of: &properties.layerName) { bytes in
            for (index, byte) in "VK_LAYER_test".utf8.enumerated() { bytes[index] = byte }
        }
        #expect(fixedString(properties.layerName) == "VK_LAYER_test")
        let full: (CChar, CChar, CChar) = (0x61, 0x62, 0x63)
        #expect(fixedString(full) == "abc")
    }

    @Test("a VulkanError names the call and the result")
    func errors() {
        #expect(throws: VulkanError("vkCreateThing", VK_ERROR_OUT_OF_HOST_MEMORY)) {
            try vkCheck(VK_ERROR_OUT_OF_HOST_MEMORY, "vkCreateThing")
        }
        #expect(VulkanError("vkCreateThing", VK_ERROR_DEVICE_LOST).description == "vkCreateThing failed (VkResult -4)")
    }
}
