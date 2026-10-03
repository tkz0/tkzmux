// DeviceSelectorTests — the pure selection rules (WOR-313 S1), no GPU needed.
//
// The fixtures are the reference machine's devices, as `tkzmux-vtdump gpu` lists them: the AMD
// iGPU (primary 226:2, render 226:129, the compositor's main_device), the RTX 5060 (226:1, 226:128)
// and lavapipe, which has no DRM node.

import Testing
@testable import TkzRenderVK

private let amd = GPUCandidate(index: 0, name: "AMD Radeon (RADV)", vendorID: 0x1002, kind: .integrated,
                               primaryNode: DRMNode(major: 226, minor: 2), renderNode: DRMNode(major: 226, minor: 129))
private let nvidia = GPUCandidate(index: 1, name: "NVIDIA GeForce RTX 5060", vendorID: 0x10DE, kind: .discrete,
                                  primaryNode: DRMNode(major: 226, minor: 1), renderNode: DRMNode(major: 226, minor: 128))
private let lavapipe = GPUCandidate(index: 2, name: "llvmpipe (LLVM)", vendorID: 0x10005, kind: .cpu,
                                    missingPresentationExtensions: ["VK_EXT_physical_device_drm"])

/// `candidates` renumbered into loader order, as enumeration would number them.
private func inLoaderOrder(_ candidates: GPUCandidate...) -> [GPUCandidate] {
    candidates.enumerated().map { index, candidate in
        var candidate = candidate
        candidate.index = index
        return candidate
    }
}

private func select(
    _ candidates: [GPUCandidate], mode: GPUMode = .presenting, main: DRMNode? = nil, preference: GPUPreference = .auto
) throws -> DeviceSelection {
    try DeviceSelector.select(candidates, mode: mode, mainDevice: main, preference: preference)
}

private let amdRender = DRMNode(major: 226, minor: 129)
private let amdPrimary = DRMNode(major: 226, minor: 2)
private let nvidiaRender = DRMNode(major: 226, minor: 128)
private let nvidiaPrimary = DRMNode(major: 226, minor: 1)

@Suite("Device selection")
struct DeviceSelectorTests {

    // MARK: main_device

    @Test("main_device matches a device by its render node, whatever the loader order")
    func mainDeviceRenderNode() throws {
        for devices in [inLoaderOrder(amd, nvidia), inLoaderOrder(nvidia, amd)] {
            let selection = try select(devices, main: amdRender)
            #expect(selection.candidate.name == amd.name)
            #expect(selection.reason == .mainDevice(amdRender, .render))
            #expect(selection.warnings.isEmpty)
        }
        let selection = try select(inLoaderOrder(amd, nvidia), main: nvidiaRender)
        #expect(selection.candidate.name == nvidia.name)
        #expect(selection.reason == .mainDevice(nvidiaRender, .render))
    }

    @Test("main_device matches a device by its primary node too")
    func mainDevicePrimaryNode() throws {
        let toAMD = try select(inLoaderOrder(nvidia, amd), main: amdPrimary)
        #expect(toAMD.candidate.name == amd.name)
        #expect(toAMD.reason == .mainDevice(amdPrimary, .primary))
        let toNVIDIA = try select(inLoaderOrder(amd, nvidia), main: nvidiaPrimary)
        #expect(toNVIDIA.candidate.name == nvidia.name)
        #expect(toNVIDIA.reason == .mainDevice(nvidiaPrimary, .primary))
    }

    @Test("a main_device no device has falls back to loader order, with a PRIME warning")
    func mainDeviceWithoutMatch() throws {
        let unknown = DRMNode(major: 226, minor: 200)
        let selection = try select(inLoaderOrder(amd, nvidia), main: unknown)
        #expect(selection.candidate.name == amd.name)
        #expect(selection.reason == .loaderOrder)
        #expect(selection.warnings.count == 1)
        #expect(selection.warnings.first?.contains("PRIME") == true)
        #expect(selection.warnings.first?.contains("226:200") == true)
    }

    // MARK: No feedback

    @Test("without main_device the first device in loader order wins")
    func loaderOrder() throws {
        let amdFirst = try select(inLoaderOrder(amd, nvidia))
        #expect(amdFirst.candidate.name == amd.name)
        #expect(amdFirst.reason == .loaderOrder)
        #expect(amdFirst.warnings.isEmpty)
        let nvidiaFirst = try select(inLoaderOrder(nvidia, amd))
        #expect(nvidiaFirst.candidate.name == nvidia.name)
        #expect(nvidiaFirst.reason == .loaderOrder)

        let alone = try select(inLoaderOrder(amd))
        #expect(alone.reason == .onlyDevice)
    }

    // MARK: TKZMUX_GPU

    @Test("TKZMUX_GPU picks the first device of its type, over loader order")
    func preferenceOverride() throws {
        let discrete = try select(inLoaderOrder(amd, nvidia), preference: .discrete)
        #expect(discrete.candidate.name == nvidia.name)
        #expect(discrete.reason == .preference(.discrete))
        #expect(discrete.warnings.isEmpty)

        let integrated = try select(inLoaderOrder(nvidia, amd), preference: .integrated)
        #expect(integrated.candidate.name == amd.name)
        #expect(integrated.reason == .preference(.integrated))
    }

    @Test("TKZMUX_GPU beats main_device, and the mismatch is warned about")
    func preferenceOverMainDevice() throws {
        let selection = try select(inLoaderOrder(amd, nvidia), main: amdRender, preference: .discrete)
        #expect(selection.candidate.name == nvidia.name)
        #expect(selection.reason == .preference(.discrete))
        #expect(selection.warnings.count == 1)
        #expect(selection.warnings.first?.contains("main_device 226:129") == true)

        // Agreeing with main_device is not a mismatch.
        let agreeing = try select(inLoaderOrder(amd, nvidia), main: amdRender, preference: .integrated)
        #expect(agreeing.candidate.name == amd.name)
        #expect(agreeing.warnings.isEmpty)
    }

    @Test("TKZMUX_GPU naming a type nobody has is ignored with a warning")
    func preferenceWithoutMatch() throws {
        let selection = try select(inLoaderOrder(amd), main: amdRender, preference: .discrete)
        #expect(selection.candidate.name == amd.name)
        #expect(selection.reason == .mainDevice(amdRender, .render))
        #expect(selection.warnings == ["TKZMUX_GPU=discrete: no eligible discrete device; ignoring it"])
    }

    @Test("TKZMUX_GPU parses case-insensitively, and an unknown value is auto plus a warning")
    func preferenceParsing() {
        let clean: [(String?, GPUPreference)] = [(nil, .auto), ("", .auto), ("auto", .auto), ("integrated", .integrated), ("Discrete", .discrete)]
        for (raw, expected) in clean {
            let parsed = GPUPreference.parse(raw)
            #expect(parsed.preference == expected, "\(raw ?? "nil")")
            #expect(parsed.warning == nil, "\(raw ?? "nil")")
        }
        let bogus = GPUPreference.parse("nvidia")
        #expect(bogus.preference == .auto)
        #expect(bogus.warning == "TKZMUX_GPU=nvidia is not auto, integrated or discrete; using auto")
    }

    // MARK: No DRM node

    @Test("presenting, a device without a DRM node is passed over while another can export")
    func noDRMPresenting() throws {
        let selection = try select(inLoaderOrder(lavapipe, nvidia))
        #expect(selection.candidate.name == nvidia.name)
        #expect(selection.reason == .onlyDevice)
        #expect(selection.warnings.isEmpty)
    }

    @Test("presenting, a device without a DRM node is chosen when it is alone, and warned about")
    func noDRMAlone() throws {
        let selection = try select(inLoaderOrder(lavapipe))
        #expect(selection.candidate.name == lavapipe.name)
        #expect(selection.reason == .onlyDevice)
        #expect(selection.warnings == ["llvmpipe (LLVM) cannot export dmabufs (no DRM node): frames reach the compositor through CPU readback"])

        // With a main_device too: still chosen, and the mismatch is said.
        let withFeedback = try select(inLoaderOrder(lavapipe), main: amdRender)
        #expect(withFeedback.candidate.name == lavapipe.name)
        #expect(withFeedback.warnings.count == 2)
    }

    @Test("headless, a device without a DRM node is an ordinary candidate")
    func noDRMHeadless() throws {
        let first = try select(inLoaderOrder(lavapipe, amd), mode: .headless)
        #expect(first.candidate.name == lavapipe.name)
        #expect(first.reason == .loaderOrder)
        #expect(first.warnings.isEmpty)

        let alone = try select(inLoaderOrder(lavapipe), mode: .headless)
        #expect(alone.candidate.name == lavapipe.name)
        #expect(alone.reason == .onlyDevice)
        #expect(alone.warnings.isEmpty)

        // The preference still applies headless.
        let discrete = try select(inLoaderOrder(lavapipe, amd, nvidia), mode: .headless, preference: .discrete)
        #expect(discrete.candidate.name == nvidia.name)
    }

    @Test("presenting, a DRM device missing a presentation extension ranks like one without DRM")
    func missingPresentationExtension() throws {
        var noModifiers = amd
        noModifiers.missingPresentationExtensions = ["VK_EXT_image_drm_format_modifier"]
        let other = try select(inLoaderOrder(noModifiers, nvidia))
        #expect(other.candidate.name == nvidia.name)

        // Still ahead of a device with no DRM node at all, whatever the loader order.
        let overLavapipe = try select(inLoaderOrder(lavapipe, noModifiers))
        #expect(overLavapipe.candidate.name == amd.name)
        #expect(overLavapipe.reason == .onlyDevice)

        let alone = try select(inLoaderOrder(noModifiers))
        #expect(alone.candidate.name == amd.name)
        #expect(alone.warnings == ["AMD Radeon (RADV) cannot export dmabufs (missing VK_EXT_image_drm_format_modifier): frames reach the compositor through CPU readback"])
    }

    // MARK: Requirements

    @Test("devices without Vulkan 1.3, dynamicRendering, synchronization2 or graphics are never chosen")
    func requirements() throws {
        var old = amd
        old.apiVersion = VulkanVersion(major: 1, minor: 2, patch: 280)
        #expect(old.unmetRequirements == ["Vulkan 1.2 < 1.3"])
        var noDynamic = amd
        noDynamic.dynamicRendering = false
        var noSync2 = amd
        noSync2.synchronization2 = false
        var noGraphics = amd
        noGraphics.hasGraphicsQueue = false
        for unusable in [old, noDynamic, noSync2, noGraphics] {
            #expect(!unusable.isEligible)
            let selection = try select(inLoaderOrder(unusable, nvidia), main: amdRender)
            #expect(selection.candidate.name == nvidia.name)
        }

        // A newer patch or minor version is fine.
        var newer = amd
        newer.apiVersion = VulkanVersion(major: 1, minor: 4, patch: 354)
        #expect(newer.isEligible)
    }

    @Test("no eligible device throws, naming each device and why")
    func noEligibleDevice() {
        var old = amd
        old.apiVersion = VulkanVersion(major: 1, minor: 1)
        var crippled = lavapipe
        crippled.dynamicRendering = false
        crippled.synchronization2 = false
        #expect(throws: NoEligibleGPU(rejections: [
            "0 AMD Radeon (RADV): Vulkan 1.1 < 1.3",
            "1 llvmpipe (LLVM): no dynamicRendering, no synchronization2",
        ])) {
            try select(inLoaderOrder(old, crippled))
        }
        #expect(throws: NoEligibleGPU(rejections: [])) { try select([]) }
        #expect(NoEligibleGPU(rejections: []).description == "no Vulkan device found")
    }

    // MARK: Values

    @Test("DRMNode parses major:minor and round-trips glibc's dev_t encoding")
    func drmNode() {
        #expect(DRMNode("226:129") == amdRender)
        #expect(DRMNode("226:129")?.description == "226:129")
        for bad in ["", "226", "226:", ":129", "a:b", "226:129:0", "-1:2"] {
            #expect(DRMNode(bad) == nil, "\(bad)")
        }
        // 226:129 is 0xE281; large numbers use glibc's split high bits.
        #expect(amdRender.dev == 0xE281)
        #expect(DRMNode(dev: 0xE281) == amdRender)
        let large = DRMNode(major: 0x12345, minor: 0x6789A)
        #expect(DRMNode(dev: large.dev) == large)
    }

    @Test("VulkanVersion meets 1.3 on major.minor, whatever the patch")
    func version() {
        #expect(VulkanVersion(major: 1, minor: 3, patch: 0).isAtLeast(.required))
        #expect(VulkanVersion(major: 1, minor: 3, patch: 290).isAtLeast(.required))
        #expect(!VulkanVersion(major: 1, minor: 2, patch: 999).isAtLeast(.required))
        #expect(VulkanVersion(major: 2, minor: 0).isAtLeast(.required))
        #expect(VulkanVersion(major: 1, minor: 4, patch: 354).description == "1.4.354")
    }
}
