// PresentationRing — the window-level ring of exportable dma-buf images (WOR-313 S5a).
//
// Every visible pixel on Linux is drawn by tkzmux into one of these images and handed to GTK as a
// `GdkDmabufTexture` (WOR-314). One ring per window, not per pane: the panes of a frame are drawn
// into the same image, each into its own rect, each from its own surface's `FrameRing` slot.
//
// ## The images
//
// `depth` B8G8R8A8_UNORM images (never _SRGB; ADR-0003), with DRM-format-modifier tiling and
// dma-buf-exportable memory: one dedicated allocation each, exported once as one fd shared by
// every memory plane. The modifier comes from the intersection of what the consumer offers for the
// fourcc and what the device can render to and export (`ModifierNegotiation`); the driver picks
// among those for the first image, and the others are made with that one, so every image of a
// ring has the same modifier and plane layout. XRGB8888 is the opaque window; ARGB8888 is the same
// image with the fourth byte meaning alpha.
//
// ## A frame
//
//   acquire()     the next image the consumer is not holding, or nil (the renderer then skips the
//                 frame and the surface stays dirty). An image the consumer had is taken back:
//                 the consumer's implicit fences on the dma-buf are exported as a sync_file and
//                 waited on by the GPU (on the CPU where they cannot be), then an acquire barrier
//                 moves it from VK_QUEUE_FAMILY_FOREIGN_EXT to the graphics queue (GENERAL →
//                 COLOR_ATTACHMENT, contents kept). One small submission of its own.
//   (render)      every pane that needs drawing, through `VulkanTerminalRenderer.render(… acquire:)`:
//                 the image is a `VulkanRenderTarget`, and the renderer's own barriers follow the
//                 layout it tracks.
//   present(_:)   a release barrier hands the image to VK_QUEUE_FAMILY_FOREIGN_EXT in GENERAL, and
//                 its submission signals a render-done semaphore. That semaphore is exported as a
//                 SYNC_FD and attached to the dma-buf as its write fence
//                 (`tkz_dma_buf_import_sync_file`), so the consumer's implicit sync waits for the
//                 frame and `present` returns at once. Where that path is missing it waits for the
//                 frame on the CPU instead (`PresentationSync.cpuWait`); the ring logs which.
//   releaseSlot   the consumer is done with the image (WOR-314: the texture's destroy-notify).
//                 Reads it already submitted are covered by the fences waited on at re-acquire.
//
// The ownership transfers are not optional: without them the compositor's GPU may read stale or
// compressed-but-unresolved data, and validation only notices sometimes. `GdkDmabufTextureBuilder`
// takes no fence, so the sync_file import is what keeps NVIDIA correct without a CPU wait.
//
// Every image has its own command pool, two fences (its acquire and present submissions) and two
// semaphores (render-done, exportable; consumer-done, for the imported sync_file). Like every
// Vulkan object here the ring is not `Sendable` and lives on the main actor; nothing crosses a
// thread. Each image waits for its own submissions when it goes. A consumer still holding a
// dma-buf keeps its memory alive in the kernel, but not its fd number (GDK reads the fd until the
// texture's destroy-notify), so drop a ring only after every presented image has been released.
// Per-image buffer age, damage and the fallback ladder are WOR-313 S5b's.

import CVulkan
import Glibc

/// How a presented frame's completion reaches the consumer.
public enum PresentationSync: String, Sendable {
    /// The render-done semaphore, exported as a sync_file, is the dma-buf's write fence: the
    /// consumer's implicit sync waits for it, and `present` does not wait at all.
    case syncFile
    /// `present` waits on the CPU until the frame has finished: the device cannot export a SYNC_FD
    /// semaphore, or the kernel refused the import. Correct, at a latency cost.
    case cpuWait
}

/// Ring instrumentation, read by the tests.
public struct PresentationStats: Sendable, Hashable {
    /// `acquire` calls that handed out an image.
    public var acquires = 0
    /// `acquire` calls that found every image held by the consumer.
    public var starved = 0
    /// Acquires that took an image back from the consumer (queue family ownership acquire).
    public var foreignAcquires = 0
    /// Of those, the ones where the GPU waited on the consumer's fences, exported from the dma-buf.
    public var consumerFenceWaits = 0
    public var presents = 0
    /// Presents whose render-done fence was attached to the dma-buf as a sync_file.
    public var syncFileImports = 0
    /// Presents that waited for the GPU on the CPU instead.
    public var cpuWaits = 0
    /// `releaseSlot` calls that freed an image.
    public var releases = 0

    public init() {}
}

/// What `present` hands the consumer.
public struct PresentedFrame: Sendable, Hashable {
    /// The image's slot, for `releaseSlot`.
    public var slot: Int
    public var dmabuf: DmabufDescription
    /// How this frame's completion was signalled.
    public var sync: PresentationSync
}

public enum PresentationRingError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The device did not enable what exporting needs (headless, or a device without them).
    case missingExtensions([String])
    /// The driver chose different modifiers for images made from the same list.
    case inconsistentModifiers([UInt64])

    public var description: String {
        switch self {
        case .missingExtensions(let names): "the device cannot export dma-bufs (missing \(names.joined(separator: ", ")))"
        case .inconsistentModifiers(let modifiers): "ring images got different modifiers: \(modifiers.map(DRMModifier.hex))"
        }
    }
}

public final class PresentationRing {
    public static let depth = 3
    public static let format = VK_FORMAT_B8G8R8A8_UNORM

    /// What exporting an image needs. VK_KHR_external_semaphore_fd is optional: without it the
    /// ring falls back to `PresentationSync.cpuWait`.
    public static let requiredExtensions = [
        "VK_EXT_external_memory_dma_buf",
        "VK_KHR_external_memory_fd",
        "VK_EXT_image_drm_format_modifier",
        "VK_EXT_queue_family_foreign",
    ]
    static let semaphoreExtension = "VK_KHR_external_semaphore_fd"

    /// Colour attachment for the renderer; transfer source for readback, destination for WOR-313
    /// S5b's copy from the previous image.
    static let usage = VkImageUsageFlags(
        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue
            | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue)
    /// The tiling features `usage` and the renderer's blending need.
    static let requiredFeatures = VkFormatFeatureFlags(
        VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT.rawValue | VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT.rawValue
            | VK_FORMAT_FEATURE_TRANSFER_SRC_BIT.rawValue | VK_FORMAT_FEATURE_TRANSFER_DST_BIT.rawValue)

    public let device: VulkanDevice
    public let width: UInt32
    public let height: UInt32
    public let fourcc: DRMFourCC
    /// The modifier every image was made with, and its memory plane count.
    public let modifier: UInt64
    public let planeCount: Int
    public let images: [Image]
    /// How frames reach the consumer. Starts as the best the device offers (or what `init` was
    /// told) and drops to `.cpuWait` for good if the kernel refuses a sync_file import.
    public private(set) var sync: PresentationSync
    public private(set) var stats = PresentationStats()

    private let procs: DmabufProcs
    /// The last image handed out; the first `acquire` hands out image 0.
    private var lastAcquired = PresentationRing.depth - 1

    /// Makes the ring's images for a `width × height` window presented as `fourcc`, with a
    /// modifier the consumer lists in `offered` (`gdk_display_get_dmabuf_formats`, WOR-314).
    /// `sync` forces a completion path; nil takes the best the device has.
    public init(
        device: VulkanDevice, width: UInt32, height: UInt32, fourcc: DRMFourCC = .xrgb8888,
        offered: [DRMFormat], sync: PresentationSync? = nil
    ) throws {
        precondition(width > 0 && height > 0, "PresentationRing needs a non-empty size")
        let missing = Self.requiredExtensions.filter { !device.enabledExtensions.contains($0) }
        guard missing.isEmpty else { throw PresentationRingError.missingExtensions(missing) }
        let procs = try DmabufProcs(device)

        let supported = Self.deviceModifiers(device.physicalDevice)
        let candidates = try ModifierNegotiation.negotiate(
            offered: offered, fourcc: fourcc, device: supported, width: width, height: height)

        let semaphores = Self.semaphoreSupport(device, procs: procs)
        let resolvedSync: PresentationSync = switch sync {
        case .cpuWait: .cpuWait
        case .syncFile, nil: semaphores.exportable ? .syncFile : .cpuWait
        }

        // The driver picks from the list for the first image; the rest get its choice, so the
        // ring has one layout.
        var images: [Image] = []
        for index in 0..<Self.depth {
            let image = try Image(
                device: device, index: index, width: width, height: height, fourcc: fourcc,
                modifiers: images.first.map { [$0.dmabuf.modifier] } ?? candidates,
                planeCounts: Dictionary(supported.map { ($0.modifier, $0.planeCount) }, uniquingKeysWith: { first, _ in first }),
                procs: procs, exportsRenderDone: resolvedSync == .syncFile, importsConsumerFences: semaphores.importable)
            images.append(image)
        }
        let chosen = Set(images.map(\.dmabuf.modifier))
        guard chosen.count == 1, let modifier = chosen.first else {
            throw PresentationRingError.inconsistentModifiers(images.map(\.dmabuf.modifier))
        }

        self.device = device
        self.width = width
        self.height = height
        self.fourcc = fourcc
        self.modifier = modifier
        self.planeCount = images[0].dmabuf.planes.count
        self.images = images
        self.sync = resolvedSync
        self.procs = procs

        let planes = images[0].dmabuf.planes.map { "offset \($0.offset) stride \($0.stride)" }.joined(separator: ", ")
        vulkanLog.notice("""
            presentation ring \(width)×\(height) \(fourcc.description, privacy: .public) \
            modifier \(DRMModifier.hex(modifier), privacy: .public) (of \(candidates.count) common), \
            \(images[0].dmabuf.planes.count) plane(s): \(planes, privacy: .public); sync \(resolvedSync.rawValue, privacy: .public)
            """)
        if resolvedSync == .cpuWait && sync != .cpuWait {
            vulkanLog.warning("presentation ring: no sync_file path on \(device.candidate.name, privacy: .public); every present waits for the GPU")
        }
    }

    // MARK: - A frame

    /// The next image the consumer is not holding, ready to be drawn into, or nil when it holds
    /// them all. Taking back an image the consumer had waits (on the GPU) for its reads to finish.
    public func acquire() throws -> Image? {
        let order = (1...Self.depth).map { images[(lastAcquired + $0) % Self.depth] }
        guard let image = order.first(where: { $0.state == .free }) else {
            stats.starved += 1
            return nil
        }
        if image.ownedByConsumer {
            let waited = try image.takeBack(procs: procs)
            stats.foreignAcquires += 1
            if waited { stats.consumerFenceWaits += 1 }
        }
        image.state = .acquired
        lastAcquired = image.index
        stats.acquires += 1
        return image
    }

    /// Hands `image`, drawn into since `acquire`, to the consumer: release to the foreign queue
    /// family, then the render-done fence onto the dma-buf (or a CPU wait). Returns what the
    /// consumer imports.
    public func present(_ image: Image) throws -> PresentedFrame {
        precondition(images.indices.contains(image.index) && images[image.index] === image, "an image is presented to its own ring")
        precondition(image.state == .acquired, "only an acquired image can be presented")
        let signalled = try image.release(signalRenderDone: sync == .syncFile)
        image.state = .presented
        stats.presents += 1

        var frameSync = sync
        if sync == .syncFile {
            switch image.attachRenderDone(procs: procs) {
            case .attached, .alreadySignalled:
                stats.syncFileImports += 1
            case .failed(let reason):
                // The semaphore is spent either way (an export is a wait); from here on, wait.
                vulkanLog.warning("presentation ring: \(reason, privacy: .public); falling back to a CPU wait per frame")
                sync = .cpuWait
                frameSync = .cpuWait
            }
        }
        if frameSync == .cpuWait || !signalled {
            try image.waitForPresent()
            stats.cpuWaits += 1
        }
        return PresentedFrame(slot: image.index, dmabuf: image.dmabuf, sync: frameSync)
    }

    /// The consumer no longer needs image `slot` (WOR-314: a texture's destroy-notify). An
    /// acquired image that will not be presented is handed back the same way. Releasing a free
    /// image does nothing.
    public func releaseSlot(_ slot: Int) {
        precondition(images.indices.contains(slot), "slot \(slot) is not in the ring")
        guard images[slot].state != .free else { return }
        images[slot].state = .free
        stats.releases += 1
    }

    // MARK: - Device capabilities

    /// Every modifier the device reports for B8G8R8A8_UNORM, with what an image of the ring's
    /// usage can do with it.
    public static func deviceModifiers(_ physicalDevice: VkPhysicalDevice) -> [DeviceModifier] {
        func query(_ properties: UnsafeMutablePointer<VkDrmFormatModifierPropertiesEXT>?, count: UInt32) -> UInt32 {
            var list = VkDrmFormatModifierPropertiesListEXT()
            list.sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT
            list.drmFormatModifierCount = count
            list.pDrmFormatModifierProperties = properties
            var chain = VulkanChain()
            let reply = chain.append(list)
            var formatProperties = VkFormatProperties2()
            formatProperties.sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2
            formatProperties.pNext = chain.head
            vkGetPhysicalDeviceFormatProperties2(physicalDevice, format, &formatProperties)
            return reply.pointee.drmFormatModifierCount
        }
        var count = query(nil, count: 0)
        var properties = [VkDrmFormatModifierPropertiesEXT](repeating: VkDrmFormatModifierPropertiesEXT(), count: Int(count))
        count = properties.withUnsafeMutableBufferPointer { query($0.baseAddress, count: count) }
        return properties.prefix(Int(count)).map { entry in
            let limits = exportLimits(physicalDevice, modifier: entry.drmFormatModifier)
            return DeviceModifier(
                modifier: entry.drmFormatModifier, planeCount: Int(entry.drmFormatModifierPlaneCount),
                supportsTarget: entry.drmFormatModifierTilingFeatures & requiredFeatures == requiredFeatures,
                exportable: limits.exportable, maxWidth: limits.maxWidth, maxHeight: limits.maxHeight)
        }
    }

    /// Whether an image of the ring's usage and `modifier` can be exported as a dma-buf, and how
    /// large it can be.
    private static func exportLimits(_ physicalDevice: VkPhysicalDevice, modifier: UInt64)
        -> (exportable: Bool, maxWidth: UInt32, maxHeight: UInt32)
    {
        var external = VkPhysicalDeviceExternalImageFormatInfo()
        external.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO
        external.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT
        var modifierInfo = VkPhysicalDeviceImageDrmFormatModifierInfoEXT()
        modifierInfo.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT
        modifierInfo.drmFormatModifier = modifier
        modifierInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        var input = VulkanChain()
        input.append(external)
        input.append(modifierInfo)
        var info = VkPhysicalDeviceImageFormatInfo2()
        info.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2
        info.pNext = UnsafeRawPointer(input.head)
        info.format = format
        info.type = VK_IMAGE_TYPE_2D
        info.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
        info.usage = usage

        var externalProperties = VkExternalImageFormatProperties()
        externalProperties.sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES
        var output = VulkanChain()
        let reply = output.append(externalProperties)
        var properties = VkImageFormatProperties2()
        properties.sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2
        properties.pNext = output.head
        guard vkGetPhysicalDeviceImageFormatProperties2(physicalDevice, &info, &properties) == VK_SUCCESS else {
            return (false, 0, 0)
        }
        let features = reply.pointee.externalMemoryProperties.externalMemoryFeatures
        let extent = properties.imageFormatProperties.maxExtent
        return (features & VkExternalMemoryFeatureFlags(VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT.rawValue) != 0,
                extent.width, extent.height)
    }

    /// Whether a binary semaphore can be exported as, and receive an import of, a sync_file.
    private static func semaphoreSupport(_ device: VulkanDevice, procs: DmabufProcs) -> (exportable: Bool, importable: Bool) {
        guard device.enabledExtensions.contains(semaphoreExtension), procs.getSemaphoreFd != nil, procs.importSemaphoreFd != nil
        else { return (false, false) }
        var info = VkPhysicalDeviceExternalSemaphoreInfo()
        info.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO
        info.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT
        var properties = VkExternalSemaphoreProperties()
        properties.sType = VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES
        vkGetPhysicalDeviceExternalSemaphoreProperties(device.physicalDevice, &info, &properties)
        let features = properties.externalSemaphoreFeatures
        return (features & VkExternalSemaphoreFeatureFlags(VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT.rawValue) != 0,
                features & VkExternalSemaphoreFeatureFlags(VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT.rawValue) != 0)
    }
}

// MARK: - Extension entry points

/// The device-level extension commands the ring calls, loaded once.
struct DmabufProcs {
    let getMemoryFd: PFN_vkGetMemoryFdKHR
    let getImageModifier: PFN_vkGetImageDrmFormatModifierPropertiesEXT
    /// VK_KHR_external_semaphore_fd, when the device enabled it.
    let getSemaphoreFd: PFN_vkGetSemaphoreFdKHR?
    let importSemaphoreFd: PFN_vkImportSemaphoreFdKHR?

    init(_ device: VulkanDevice) throws {
        let vk = device.handle
        guard let getMemoryFd = deviceProc(vk, "vkGetMemoryFdKHR", as: PFN_vkGetMemoryFdKHR.self),
              let getImageModifier = deviceProc(vk, "vkGetImageDrmFormatModifierPropertiesEXT",
                                                as: PFN_vkGetImageDrmFormatModifierPropertiesEXT.self)
        else { throw VulkanError("vkGetDeviceProcAddr (dma-buf export commands)", VK_ERROR_EXTENSION_NOT_PRESENT) }
        self.getMemoryFd = getMemoryFd
        self.getImageModifier = getImageModifier
        let semaphores = device.enabledExtensions.contains(PresentationRing.semaphoreExtension)
        getSemaphoreFd = semaphores ? deviceProc(vk, "vkGetSemaphoreFdKHR", as: PFN_vkGetSemaphoreFdKHR.self) : nil
        importSemaphoreFd = semaphores ? deviceProc(vk, "vkImportSemaphoreFdKHR", as: PFN_vkImportSemaphoreFdKHR.self) : nil
    }
}

// MARK: - Image

extension PresentationRing {
    /// One exportable image of the ring, and everything its acquire and present submissions use.
    public final class Image: VulkanRenderTarget {
        public enum State: Sendable {
            /// Neither drawn into nor held by the consumer.
            case free
            /// Handed out by `acquire`, not yet presented.
            case acquired
            /// Presented; the consumer holds it until `releaseSlot`.
            case presented
        }

        public let index: Int
        public let device: VulkanDevice
        public let image: VkImage
        public let view: VkImageView
        public let width: UInt32
        public let height: UInt32
        /// The fd, fourcc, modifier and plane layout the consumer imports.
        public let dmabuf: DmabufDescription
        /// Tracked as commands are recorded (`VulkanRenderTarget`); GENERAL while the consumer has it.
        public var layout = VK_IMAGE_LAYOUT_UNDEFINED
        public internal(set) var state = State.free
        /// Released to VK_QUEUE_FAMILY_FOREIGN_EXT by the last present, not yet acquired back.
        public private(set) var ownedByConsumer = false

        private let memory: VkDeviceMemory
        private let fd: Int32
        private let pool: VkCommandPool
        private let acquireCommands: VkCommandBuffer
        private let presentCommands: VkCommandBuffer
        private let acquireFence: VkFence
        private let presentFence: VkFence
        /// Signalled by the present submission and exported as a SYNC_FD; nil on the CPU-wait path.
        private let renderDone: VkSemaphore?
        /// Receives the consumer's fences (a temporary SYNC_FD import) for the GPU to wait on.
        private let consumerDone: VkSemaphore?

        init(
            device: VulkanDevice, index: Int, width: UInt32, height: UInt32, fourcc: DRMFourCC, modifiers: [UInt64],
            planeCounts: [UInt64: Int], procs: DmabufProcs, exportsRenderDone: Bool, importsConsumerFences: Bool
        ) throws {
            let vk = device.handle
            // Each step below frees what the earlier ones made if it fails: `cleanup` runs in reverse.
            var cleanup: [() -> Void] = []
            var committed = false
            defer { if !committed { cleanup.reversed().forEach { $0() } } }

            // An image the driver tiles with one of `modifiers`, its memory exportable as a dma-buf.
            var image: VkImage?
            let created = modifiers.withUnsafeBufferPointer { modifiers in
                var list = VkImageDrmFormatModifierListCreateInfoEXT()
                list.sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT
                list.drmFormatModifierCount = UInt32(modifiers.count)
                list.pDrmFormatModifiers = modifiers.baseAddress
                var external = VkExternalMemoryImageCreateInfo()
                external.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
                external.handleTypes = VkExternalMemoryHandleTypeFlags(VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT.rawValue)
                var chain = VulkanChain()
                chain.append(external)
                chain.append(list)

                var info = VkImageCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
                info.pNext = UnsafeRawPointer(chain.head)
                info.imageType = VK_IMAGE_TYPE_2D
                info.format = PresentationRing.format
                info.extent = VkExtent3D(width: width, height: height, depth: 1)
                info.mipLevels = 1
                info.arrayLayers = 1
                info.samples = VK_SAMPLE_COUNT_1_BIT
                info.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
                info.usage = PresentationRing.usage
                info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
                info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
                return vkCreateImage(vk, &info, nil, &image)
            }
            try vkCheck(created, "vkCreateImage (dma-buf, \(modifiers.count) modifier(s))")
            guard let image else { throw VulkanError("vkCreateImage", VK_ERROR_INITIALIZATION_FAILED) }
            cleanup.append { vkDestroyImage(vk, image, nil) }

            // One dedicated allocation, exportable as a dma-buf.
            var requirements = VkMemoryRequirements()
            vkGetImageMemoryRequirements(vk, image, &requirements)
            let deviceLocal = VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
            guard let type = device.memoryTypeIndex(typeBits: requirements.memoryTypeBits, required: deviceLocal)
                ?? device.memoryTypeIndex(typeBits: requirements.memoryTypeBits, required: 0)
            else { throw VulkanError("vkAllocateMemory (no memory type for a dma-buf image)", VK_ERROR_OUT_OF_DEVICE_MEMORY) }
            var dedicated = VkMemoryDedicatedAllocateInfo()
            dedicated.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO
            dedicated.image = image
            var export = VkExportMemoryAllocateInfo()
            export.sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO
            export.handleTypes = VkExternalMemoryHandleTypeFlags(VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT.rawValue)
            var memoryChain = VulkanChain()
            memoryChain.append(export)
            memoryChain.append(dedicated)
            var allocateInfo = VkMemoryAllocateInfo()
            allocateInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
            allocateInfo.pNext = UnsafeRawPointer(memoryChain.head)
            allocateInfo.allocationSize = requirements.size
            allocateInfo.memoryTypeIndex = type
            var memory: VkDeviceMemory?
            try vkCheck(vkAllocateMemory(vk, &allocateInfo, nil, &memory), "vkAllocateMemory (dma-buf image)")
            guard let memory else { throw VulkanError("vkAllocateMemory", VK_ERROR_OUT_OF_DEVICE_MEMORY) }
            cleanup.append { vkFreeMemory(vk, memory, nil) }
            try vkCheck(vkBindImageMemory(vk, image, memory, 0), "vkBindImageMemory (dma-buf image)")

            var fdInfo = VkMemoryGetFdInfoKHR()
            fdInfo.sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR
            fdInfo.memory = memory
            fdInfo.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT
            var fd: Int32 = -1
            try vkCheck(procs.getMemoryFd(vk, &fdInfo, &fd), "vkGetMemoryFdKHR")
            cleanup.append { close(fd) }

            // The modifier the driver chose, and where each memory plane is.
            var modifierProperties = VkImageDrmFormatModifierPropertiesEXT()
            modifierProperties.sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT
            try vkCheck(procs.getImageModifier(vk, image, &modifierProperties), "vkGetImageDrmFormatModifierPropertiesEXT")
            let modifier = modifierProperties.drmFormatModifier
            let planeCount = planeCounts[modifier] ?? 1
            guard (1...DmabufDescription.maxPlanes).contains(planeCount) else {
                throw VulkanError("PresentationRing (modifier \(DRMModifier.hex(modifier)) has \(planeCount) planes)", VK_ERROR_FORMAT_NOT_SUPPORTED)
            }
            var planes: [DmabufPlane] = []
            for plane in 0..<planeCount {
                var subresource = VkImageSubresource()
                subresource.aspectMask = VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT.rawValue << UInt32(plane)
                var layout = VkSubresourceLayout()
                vkGetImageSubresourceLayout(vk, image, &subresource, &layout)
                guard let offset = UInt32(exactly: layout.offset), let stride = UInt32(exactly: layout.rowPitch) else {
                    throw VulkanError("PresentationRing (plane \(plane) offset or stride beyond 32 bits)", VK_ERROR_FORMAT_NOT_SUPPORTED)
                }
                planes.append(DmabufPlane(fd: fd, offset: offset, stride: stride))
            }

            var viewInfo = VkImageViewCreateInfo()
            viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
            viewInfo.image = image
            viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
            viewInfo.format = PresentationRing.format
            viewInfo.subresourceRange = colorSubresourceRange
            var view: VkImageView?
            try vkCheck(vkCreateImageView(vk, &viewInfo, nil, &view), "vkCreateImageView (dma-buf image)")
            guard let view else { throw VulkanError("vkCreateImageView", VK_ERROR_INITIALIZATION_FAILED) }
            cleanup.append { vkDestroyImageView(vk, view, nil) }

            // Its own pool, so the image needs nothing from the ring to be torn down.
            var poolInfo = VkCommandPoolCreateInfo()
            poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
            poolInfo.flags = VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
            poolInfo.queueFamilyIndex = device.queueFamily
            var pool: VkCommandPool?
            try vkCheck(vkCreateCommandPool(vk, &poolInfo, nil, &pool), "vkCreateCommandPool")
            guard let pool else { throw VulkanError("vkCreateCommandPool", VK_ERROR_INITIALIZATION_FAILED) }
            cleanup.append { vkDestroyCommandPool(vk, pool, nil) }
            var commandInfo = VkCommandBufferAllocateInfo()
            commandInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
            commandInfo.commandPool = pool
            commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
            commandInfo.commandBufferCount = 2
            var commands = [VkCommandBuffer?](repeating: nil, count: 2)
            try vkCheck(vkAllocateCommandBuffers(vk, &commandInfo, &commands), "vkAllocateCommandBuffers")

            // Signalled at creation: an image that was never submitted is free.
            var fenceInfo = VkFenceCreateInfo()
            fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
            fenceInfo.flags = VkFenceCreateFlags(VK_FENCE_CREATE_SIGNALED_BIT.rawValue)
            var fences: [VkFence] = []
            for _ in 0..<2 {
                var fence: VkFence?
                try vkCheck(vkCreateFence(vk, &fenceInfo, nil, &fence), "vkCreateFence")
                guard let fence else { throw VulkanError("vkCreateFence", VK_ERROR_INITIALIZATION_FAILED) }
                cleanup.append { vkDestroyFence(vk, fence, nil) }
                fences.append(fence)
            }

            func semaphore(exportable: Bool) throws -> VkSemaphore {
                var exportInfo = VkExportSemaphoreCreateInfo()
                exportInfo.sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO
                exportInfo.handleTypes = VkExternalSemaphoreHandleTypeFlags(VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT.rawValue)
                var chain = VulkanChain()
                if exportable { chain.append(exportInfo) }
                var info = VkSemaphoreCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
                info.pNext = UnsafeRawPointer(chain.head)
                var semaphore: VkSemaphore?
                try vkCheck(vkCreateSemaphore(vk, &info, nil, &semaphore), "vkCreateSemaphore")
                guard let semaphore else { throw VulkanError("vkCreateSemaphore", VK_ERROR_INITIALIZATION_FAILED) }
                cleanup.append { vkDestroySemaphore(vk, semaphore, nil) }
                return semaphore
            }
            let renderDone = exportsRenderDone ? try semaphore(exportable: true) : nil
            let consumerDone = importsConsumerFences ? try semaphore(exportable: false) : nil

            guard let acquireCommands = commands[0], let presentCommands = commands[1] else {
                throw VulkanError("vkAllocateCommandBuffers", VK_ERROR_INITIALIZATION_FAILED)
            }
            self.index = index
            self.device = device
            self.image = image
            self.view = view
            self.width = width
            self.height = height
            self.dmabuf = DmabufDescription(width: width, height: height, fourcc: fourcc, modifier: modifier, planes: planes)
            self.memory = memory
            self.fd = fd
            self.pool = pool
            self.acquireCommands = acquireCommands
            self.presentCommands = presentCommands
            self.acquireFence = fences[0]
            self.presentFence = fences[1]
            self.renderDone = renderDone
            self.consumerDone = consumerDone
            committed = true
        }

        deinit {
            let vk = device.handle
            var fences: [VkFence?] = [acquireFence, presentFence]
            vkWaitForFences(vk, 2, &fences, VkBool32(VK_TRUE), UInt64.max)
            if let renderDone { vkDestroySemaphore(vk, renderDone, nil) }
            if let consumerDone { vkDestroySemaphore(vk, consumerDone, nil) }
            vkDestroyFence(vk, acquireFence, nil)
            vkDestroyFence(vk, presentFence, nil)
            vkDestroyCommandPool(vk, pool, nil)
            vkDestroyImageView(vk, view, nil)
            vkDestroyImage(vk, image, nil)
            vkFreeMemory(vk, memory, nil)
            close(fd)
        }

        // MARK: Acquire

        /// Takes the image back from the consumer: waits (on the GPU) for the fences its reads left
        /// on the dma-buf, and acquires it from VK_QUEUE_FAMILY_FOREIGN_EXT into
        /// COLOR_ATTACHMENT_OPTIMAL, keeping its contents. Returns whether a GPU wait was set up.
        func takeBack(procs: DmabufProcs) throws -> Bool {
            let vk = device.handle
            try wait(for: acquireFence)

            // Every fence a writer must wait for: the consumer's reads (and our own last write),
            // waited on by the GPU when the semaphore can take them, else here.
            var waits: [VkSemaphoreSubmitInfo] = []
            var syncFile: Int32 = -1
            let exported = tkz_dma_buf_export_sync_file(fd, tkz_dma_buf_sync_write(), &syncFile) == 0
            if exported, syncFile >= 0 {
                if let consumerDone, let importFd = procs.importSemaphoreFd {
                    var info = VkImportSemaphoreFdInfoKHR()
                    info.sType = VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR
                    info.semaphore = consumerDone
                    info.flags = VkSemaphoreImportFlags(VK_SEMAPHORE_IMPORT_TEMPORARY_BIT.rawValue)
                    info.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT
                    info.fd = syncFile
                    // On success the semaphore owns the fd.
                    if importFd(vk, &info) == VK_SUCCESS {
                        syncFile = -1
                        var wait = VkSemaphoreSubmitInfo()
                        wait.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO
                        wait.semaphore = consumerDone
                        wait.stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT
                        waits.append(wait)
                    }
                }
                if syncFile >= 0 {
                    Self.poll(syncFile, for: POLLIN)
                    close(syncFile)
                }
            } else if !exported {
                // A kernel without the ioctl (before Linux 6.0): polling the dma-buf itself for
                // writing waits for the same fences.
                Self.poll(fd, for: POLLOUT)
            }

            try vkCheck(vkResetCommandBuffer(acquireCommands, 0), "vkResetCommandBuffer")
            var begin = VkCommandBufferBeginInfo()
            begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
            begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
            try vkCheck(vkBeginCommandBuffer(acquireCommands, &begin), "vkBeginCommandBuffer")
            pipelineBarrier(acquireCommands, images: [Self.acquireBarrier(image, family: device.queueFamily)])
            try vkCheck(vkEndCommandBuffer(acquireCommands), "vkEndCommandBuffer")
            try submit(acquireCommands, waits: waits, signals: [], fence: acquireFence)
            layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            ownedByConsumer = false
            return !waits.isEmpty
        }

        // MARK: Present

        /// Records and submits the release to VK_QUEUE_FAMILY_FOREIGN_EXT, in GENERAL, signalling
        /// `renderDone` when asked and the image has one. Returns whether it was signalled.
        func release(signalRenderDone: Bool) throws -> Bool {
            try wait(for: presentFence)
            try vkCheck(vkResetCommandBuffer(presentCommands, 0), "vkResetCommandBuffer")
            var begin = VkCommandBufferBeginInfo()
            begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
            begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
            try vkCheck(vkBeginCommandBuffer(presentCommands, &begin), "vkBeginCommandBuffer")
            pipelineBarrier(presentCommands, images: [Self.releaseBarrier(image, from: layout, family: device.queueFamily)])
            try vkCheck(vkEndCommandBuffer(presentCommands), "vkEndCommandBuffer")

            var signals: [VkSemaphoreSubmitInfo] = []
            if signalRenderDone, let renderDone {
                var signal = VkSemaphoreSubmitInfo()
                signal.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO
                signal.semaphore = renderDone
                signal.stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT
                signals.append(signal)
            }
            try submit(presentCommands, waits: [], signals: signals, fence: presentFence)
            layout = VK_IMAGE_LAYOUT_GENERAL
            ownedByConsumer = true
            return !signals.isEmpty
        }

        enum Attachment {
            case attached
            /// The export found the frame already finished (fd -1): nothing to attach.
            case alreadySignalled
            case failed(String)
        }

        /// Exports `renderDone` (just signalled by `release`) as a sync_file and adds it to the
        /// dma-buf's implicit fences as its write fence.
        func attachRenderDone(procs: DmabufProcs) -> Attachment {
            guard let renderDone, let getFd = procs.getSemaphoreFd else { return .failed("no exportable render-done semaphore") }
            var info = VkSemaphoreGetFdInfoKHR()
            info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR
            info.semaphore = renderDone
            info.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT
            var syncFile: Int32 = -1
            let result = getFd(device.handle, &info, &syncFile)
            guard result == VK_SUCCESS else { return .failed("vkGetSemaphoreFdKHR(SYNC_FD) returned \(result.rawValue)") }
            guard syncFile >= 0 else { return .alreadySignalled }
            defer { close(syncFile) }
            let status = tkz_dma_buf_import_sync_file(fd, syncFile, tkz_dma_buf_sync_write())
            guard status == 0 else { return .failed("DMA_BUF_IOCTL_IMPORT_SYNC_FILE failed (errno \(-status))") }
            return .attached
        }

        /// Blocks until the last present submission (and everything before it) has finished.
        func waitForPresent() throws {
            var fence: VkFence? = presentFence
            try vkCheck(vkWaitForFences(device.handle, 1, &fence, VkBool32(VK_TRUE), UInt64.max), "vkWaitForFences")
        }

        // MARK: The ownership transfers

        /// The acquire from VK_QUEUE_FAMILY_FOREIGN_EXT: GENERAL (as the release left it) to
        /// COLOR_ATTACHMENT_OPTIMAL, contents kept. Its source stage matches the semaphore wait on
        /// the consumer's fences, so the layout transition follows that wait.
        static func acquireBarrier(_ image: VkImage, family: UInt32) -> VkImageMemoryBarrier2 {
            imageBarrier(
                image, from: VK_IMAGE_LAYOUT_GENERAL, to: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                source: (VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_NONE),
                destination: (VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_2_COPY_BIT,
                              VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
                                  | VK_ACCESS_2_TRANSFER_READ_BIT | VK_ACCESS_2_TRANSFER_WRITE_BIT),
                ownership: (VK_QUEUE_FAMILY_FOREIGN_EXT, family))
        }

        /// The release to VK_QUEUE_FAMILY_FOREIGN_EXT, from wherever the frame left the image to
        /// GENERAL. The destination scope is the foreign consumer's, so it is empty here.
        static func releaseBarrier(_ image: VkImage, from layout: VkImageLayout, family: UInt32) -> VkImageMemoryBarrier2 {
            imageBarrier(
                image, from: layout, to: VK_IMAGE_LAYOUT_GENERAL,
                source: lastAccess(of: layout), destination: (VK_PIPELINE_STAGE_2_NONE, VK_ACCESS_2_NONE),
                ownership: (family, VK_QUEUE_FAMILY_FOREIGN_EXT))
        }

        // MARK: Helpers

        /// Waits for `fence`: the previous submission of the command buffer it guards.
        private func wait(for fence: VkFence) throws {
            var fence: VkFence? = fence
            try vkCheck(vkWaitForFences(device.handle, 1, &fence, VkBool32(VK_TRUE), UInt64.max), "vkWaitForFences")
        }

        /// Blocks until `fd` (a sync_file or a dma-buf) is ready for `events`.
        private static func poll(_ fd: Int32, for events: Int32) {
            var poller = pollfd(fd: fd, events: Int16(events), revents: 0)
            while Glibc.poll(&poller, 1, -1) < 0 && errno == EINTR {}
        }

        /// Resets `fence` and submits `commands` with it. The fence is reset only here, so a frame
        /// that fails before this leaves it signalled and the next wait on it cannot hang.
        private func submit(
            _ commands: VkCommandBuffer, waits: [VkSemaphoreSubmitInfo], signals: [VkSemaphoreSubmitInfo], fence: VkFence
        ) throws {
            var resettable: VkFence? = fence
            try vkCheck(vkResetFences(device.handle, 1, &resettable), "vkResetFences")
            var commandInfo = VkCommandBufferSubmitInfo()
            commandInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO
            commandInfo.commandBuffer = commands
            let result = withUnsafePointer(to: &commandInfo) { commandInfo in
                waits.withUnsafeBufferPointer { waits in
                    signals.withUnsafeBufferPointer { signals in
                        var submit = VkSubmitInfo2()
                        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2
                        submit.waitSemaphoreInfoCount = UInt32(waits.count)
                        submit.pWaitSemaphoreInfos = waits.baseAddress
                        submit.commandBufferInfoCount = 1
                        submit.pCommandBufferInfos = commandInfo
                        submit.signalSemaphoreInfoCount = UInt32(signals.count)
                        submit.pSignalSemaphoreInfos = signals.baseAddress
                        return vkQueueSubmit2(device.queue, 1, &submit, fence)
                    }
                }
            }
            guard result == VK_SUCCESS else {
                // The fence was reset and nothing will signal it; an empty submission does, so the
                // next wait on it cannot hang (unless the device is gone, when it fails anyway).
                _ = vkQueueSubmit2(device.queue, 0, nil, fence)
                throw VulkanError("vkQueueSubmit2 (presentation ring)", result)
            }
        }
    }
}
