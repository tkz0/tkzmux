// DeviceSelector — which Vulkan device draws tkzmux (WOR-313 S1).
//
// Pure: it sees each physical device as a `GPUCandidate` (what the enumeration in
// PhysicalDeviceProbe.swift read) and never calls Vulkan, so every rule is tested without a GPU.
//
//   1. A device is eligible when it has Vulkan 1.3, `dynamicRendering`, `synchronization2` and a
//      graphics queue.
//   2. Presenting, the pool is the eligible devices that can hand a dmabuf to the compositor: a DRM
//      node (`VK_EXT_physical_device_drm`) and every presentation extension. When none can, it is
//      the eligible devices with a DRM node, and only when none has one either is it the rest
//      (lavapipe has no DRM node). Such a device presents through CPU readback (the last rung of
//      WOR-313 S5b's ladder). Headless, the pool is every eligible device.
//   3. `TKZMUX_GPU=integrated|discrete` picks the first pool device of that type, in loader order.
//   4. Otherwise the device whose primary or render node is the compositor's dmabuf-feedback
//      `main_device` (WOR-314 S4 supplies it; vtdump has none).
//   5. Otherwise the first pool device in loader order. Mesa's `device_select` layer already puts
//      the compositor's GPU first (boot_vga), which is what vtdump relies on.
//
// A choice that is not `main_device` is kept but warned about: the compositor then reads every
// frame across GPUs (a PRIME copy), and on the reference machine it rejects the cross-GPU dmabuf
// outright, so GTK composites instead of offloading (docs/linux/spikes.md, WOR-301 S4).

/// A DRM device node as `major:minor`, the form `dev_t`, `VkPhysicalDeviceDrmPropertiesEXT` and
/// dmabuf feedback's `main_device` share.
public struct DRMNode: Hashable, Sendable, CustomStringConvertible {
    public var major: UInt32
    public var minor: UInt32

    public init(major: UInt32, minor: UInt32) {
        self.major = major
        self.minor = minor
    }

    /// Decodes a glibc `dev_t` (what `gnu_dev_major`/`gnu_dev_minor` do), so a `main_device` read
    /// from the compositor converts without a libc call.
    public init(dev: UInt64) {
        major = UInt32(truncatingIfNeeded: ((dev >> 8) & 0xFFF) | ((dev >> 32) & ~0xFFF))
        minor = UInt32(truncatingIfNeeded: (dev & 0xFF) | ((dev >> 12) & ~0xFF))
    }

    /// Parses `major:minor`, the form `--main-device` and `stat -c %Hr:%Lr` use.
    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = UInt32(parts[0]), let minor = UInt32(parts[1]) else { return nil }
        self.init(major: major, minor: minor)
    }

    /// The glibc `dev_t` encoding (`gnu_dev_makedev`).
    public var dev: UInt64 {
        let major = UInt64(major), minor = UInt64(minor)
        return ((major & 0xFFF) << 8) | ((major & ~0xFFF) << 32) | (minor & 0xFF) | ((minor & ~0xFF) << 12)
    }

    public var description: String { "\(major):\(minor)" }
}

/// A packed Vulkan version (`VK_MAKE_API_VERSION`), decoded in Swift so the selector stays pure.
public struct VulkanVersion: Hashable, Sendable, CustomStringConvertible {
    public var raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    public init(major: UInt32, minor: UInt32, patch: UInt32 = 0) {
        raw = (major << 22) | (minor << 12) | patch
    }

    public var major: UInt32 { (raw >> 22) & 0x7F }
    public var minor: UInt32 { (raw >> 12) & 0x3FF }
    public var patch: UInt32 { raw & 0xFFF }

    /// The version tkzmux requires.
    public static let required = VulkanVersion(major: 1, minor: 3)

    /// Whether this version meets `other`, comparing major and minor only: a 1.3 device with any
    /// patch level meets 1.3.
    public func isAtLeast(_ other: VulkanVersion) -> Bool {
        (major, minor) >= (other.major, other.minor)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// `VkPhysicalDeviceType`, without the C type.
public enum GPUKind: String, Sendable, CaseIterable {
    case integrated, discrete, virtual, cpu, other
}

/// One physical device as the selector sees it, in loader order.
public struct GPUCandidate: Hashable, Sendable {
    /// The position in `vkEnumeratePhysicalDevices`.
    public var index: Int
    public var name: String
    public var vendorID: UInt32
    public var deviceID: UInt32
    public var kind: GPUKind
    public var apiVersion: VulkanVersion
    public var driverVersion: UInt32
    /// Both nil when the device has no `VK_EXT_physical_device_drm` or no node of that kind.
    public var primaryNode: DRMNode?
    public var renderNode: DRMNode?
    public var dynamicRendering: Bool
    public var synchronization2: Bool
    public var hasGraphicsQueue: Bool
    /// The entries of ``VulkanRequirements/presentationExtensions`` the device does not report.
    public var missingPresentationExtensions: [String]

    public init(index: Int, name: String, vendorID: UInt32 = 0, deviceID: UInt32 = 0, kind: GPUKind,
                apiVersion: VulkanVersion = .required, driverVersion: UInt32 = 0,
                primaryNode: DRMNode? = nil, renderNode: DRMNode? = nil,
                dynamicRendering: Bool = true, synchronization2: Bool = true, hasGraphicsQueue: Bool = true,
                missingPresentationExtensions: [String] = []) {
        self.index = index
        self.name = name
        self.vendorID = vendorID
        self.deviceID = deviceID
        self.kind = kind
        self.apiVersion = apiVersion
        self.driverVersion = driverVersion
        self.primaryNode = primaryNode
        self.renderNode = renderNode
        self.dynamicRendering = dynamicRendering
        self.synchronization2 = synchronization2
        self.hasGraphicsQueue = hasGraphicsQueue
        self.missingPresentationExtensions = missingPresentationExtensions
    }

    /// Why the device cannot draw tkzmux at all; empty when it is eligible.
    public var unmetRequirements: [String] {
        var unmet: [String] = []
        if !apiVersion.isAtLeast(.required) { unmet.append("Vulkan \(apiVersion.major).\(apiVersion.minor) < 1.3") }
        if !dynamicRendering { unmet.append("no dynamicRendering") }
        if !synchronization2 { unmet.append("no synchronization2") }
        if !hasGraphicsQueue { unmet.append("no graphics queue") }
        return unmet
    }

    public var isEligible: Bool { unmetRequirements.isEmpty }

    /// Whether the device has a DRM node at all (lavapipe has none).
    public var hasDRMNode: Bool { primaryNode != nil || renderNode != nil }

    /// Whether the device can hand its frames to the compositor as dmabufs.
    public var canExportToCompositor: Bool { hasDRMNode && missingPresentationExtensions.isEmpty }

    /// Which of its nodes is `node`, if either.
    func matches(_ node: DRMNode) -> DeviceSelection.MatchedNode? {
        if renderNode == node { return .render }
        if primaryNode == node { return .primary }
        return nil
    }
}

/// The device features and extensions tkzmux asks for.
public enum VulkanRequirements {
    /// Enabled only when presenting: dmabuf export with an explicit DRM modifier, the foreign-queue
    /// ownership transfer, sync_file export, and the DRM node used to match `main_device`.
    public static let presentationExtensions = [
        "VK_EXT_external_memory_dma_buf",
        "VK_KHR_external_memory_fd",
        "VK_EXT_image_drm_format_modifier",
        "VK_EXT_queue_family_foreign",
        "VK_EXT_physical_device_drm",
        "VK_KHR_external_semaphore_fd",
    ]
}

/// `TKZMUX_GPU`: `auto` (the default), `integrated` or `discrete`.
public enum GPUPreference: String, Sendable, CaseIterable {
    case auto, integrated, discrete

    /// The variable's name, for messages.
    public static let environmentVariable = "TKZMUX_GPU"

    /// Parses the variable's value. Unset or empty is `auto`; anything else unknown is `auto` plus
    /// a warning, so a typo never stops the app from drawing.
    public static func parse(_ raw: String?) -> (preference: GPUPreference, warning: String?) {
        guard let raw, !raw.isEmpty else { return (.auto, nil) }
        if let preference = GPUPreference(rawValue: raw.lowercased()) { return (preference, nil) }
        return (.auto, "\(environmentVariable)=\(raw) is not auto, integrated or discrete; using auto")
    }

    var kind: GPUKind? {
        switch self {
        case .auto: nil
        case .integrated: .integrated
        case .discrete: .discrete
        }
    }
}

/// What the device is for: presenting to the compositor (the app) or offscreen only (vtdump's
/// render and bench commands, tests).
public enum GPUMode: String, Sendable {
    case presenting, headless
}

/// The selector's answer.
public struct DeviceSelection: Sendable, Equatable {
    public enum MatchedNode: String, Sendable {
        case primary, render
    }

    public enum Reason: Sendable, Equatable, CustomStringConvertible {
        /// `TKZMUX_GPU` named the device's type.
        case preference(GPUPreference)
        /// One of the device's nodes is the compositor's `main_device`.
        case mainDevice(DRMNode, MatchedNode)
        /// The first device in loader order, among several.
        case loaderOrder
        /// The only device in the pool.
        case onlyDevice

        public var description: String {
            switch self {
            case .preference(let preference):
                "\(GPUPreference.environmentVariable)=\(preference.rawValue)"
            case .mainDevice(let node, let matched):
                "its \(matched.rawValue) node is the compositor's main_device \(node)"
            case .loaderOrder:
                "first eligible device in loader order"
            case .onlyDevice:
                "the only eligible device"
            }
        }
    }

    public var candidate: GPUCandidate
    public var reason: Reason
    /// Things worth a warning in the log: a mismatch with `main_device`, an unusable preference, a
    /// device that presents through readback.
    public var warnings: [String]
}

/// No device can draw tkzmux; one line per device says why.
public struct NoEligibleGPU: Error, Sendable, Equatable, CustomStringConvertible {
    public var rejections: [String]

    public var description: String {
        rejections.isEmpty
            ? "no Vulkan device found"
            : "no eligible Vulkan device: " + rejections.joined(separator: "; ")
    }
}

public enum DeviceSelector {
    /// Picks the device; see the file header for the rules. `candidates` are in loader order.
    public static func select(
        _ candidates: [GPUCandidate], mode: GPUMode, mainDevice: DRMNode?, preference: GPUPreference
    ) throws(NoEligibleGPU) -> DeviceSelection {
        let eligible = candidates.filter(\.isEligible)
        guard !eligible.isEmpty else {
            throw NoEligibleGPU(rejections: candidates.map {
                "\($0.index) \($0.name): \($0.unmetRequirements.joined(separator: ", "))"
            })
        }

        var warnings: [String] = []
        var pool = eligible
        if mode == .presenting {
            let exporting = eligible.filter(\.canExportToCompositor)
            let withNode = eligible.filter(\.hasDRMNode)
            if !exporting.isEmpty { pool = exporting } else if !withNode.isEmpty { pool = withNode }
        }

        let chosen: GPUCandidate
        let reason: DeviceSelection.Reason
        if let kind = preference.kind, let match = pool.first(where: { $0.kind == kind }) {
            chosen = match
            reason = .preference(preference)
        } else {
            if preference != .auto {
                warnings.append("\(GPUPreference.environmentVariable)=\(preference.rawValue): no eligible \(preference.rawValue) device; ignoring it")
            }
            if let mainDevice,
               let (match, node) = pool.lazy.compactMap({ candidate in candidate.matches(mainDevice).map { (candidate, $0) } }).first {
                chosen = match
                reason = .mainDevice(mainDevice, node)
            } else {
                chosen = pool[0]
                reason = pool.count == 1 ? .onlyDevice : .loaderOrder
            }
        }

        if let mainDevice, chosen.matches(mainDevice) == nil {
            warnings.append("\(chosen.name) is not the compositor's main_device \(mainDevice): every frame crosses GPUs (PRIME copy), and the compositor may refuse its dmabufs, which turns off offload")
        }
        if mode == .presenting && !chosen.canExportToCompositor {
            let why = chosen.hasDRMNode
                ? "missing " + chosen.missingPresentationExtensions.joined(separator: ", ")
                : "no DRM node"
            warnings.append("\(chosen.name) cannot export dmabufs (\(why)): frames reach the compositor through CPU readback")
        }
        return DeviceSelection(candidate: chosen, reason: reason, warnings: warnings)
    }
}
