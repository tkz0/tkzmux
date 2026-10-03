// PresentationRingTests — the exportable dma-buf ring and its explicit sync (WOR-313 S5a).
//
// The negotiation and barrier tests are pure. The GPU tests run on every device that reports the
// export extensions (RADV and NVIDIA on a desktop; lavapipe in CI, which has them all but
// VK_EXT_physical_device_drm), each logging the devices it leaves out; with none at all the test
// is cancelled with the reason, never passed silently. Every frame is checked the way a compositor
// would see it: a second VkDevice on the same GPU imports the dma-buf from its fd, modifier and
// plane layout, waits for the fences the ring attached, acquires it from
// VK_QUEUE_FAMILY_FOREIGN_EXT and reads it back. Every test asserts the validation layer (with
// synchronization validation in CI) counted no error.

import CVulkan
import Glibc
import Testing
import TkzCore
import TkzRenderCore
import TkzTerminalCore
@testable import TkzRenderVK

// MARK: - Pure: formats and negotiation

@Suite("dma-buf formats and modifier negotiation")
struct ModifierNegotiationTests {

    @Test("fourcc codes are drm_fourcc.h's, low byte first")
    func fourccs() {
        #expect(DRMFourCC.xrgb8888.rawValue == 0x3432_5258)
        #expect(DRMFourCC.argb8888.rawValue == 0x3432_5241)
        #expect(DRMFourCC.xrgb8888.description == "XR24")
        #expect(DRMFourCC("NV12").rawValue == 0x3231_564E)
        #expect(DRMModifier.hex(0x0200_0000_0040_1B03) == "0x0200000000401b03")
        #expect(DRMModifier.hex(DRMModifier.linear) == "0x0000000000000000")
    }

    private static let tiled: UInt64 = 0x0200_0000_0040_1B03
    private static let compressed: UInt64 = 0x0200_0000_0056_BB03
    private static let small: UInt64 = 0x0200_0000_0000_0901

    private static let device = [
        DeviceModifier(modifier: tiled, planeCount: 1, supportsTarget: true, exportable: true),
        DeviceModifier(modifier: compressed, planeCount: 3, supportsTarget: true, exportable: true),
        DeviceModifier(modifier: DRMModifier.linear, planeCount: 1, supportsTarget: true, exportable: true),
        DeviceModifier(modifier: small, planeCount: 1, supportsTarget: true, exportable: true, maxWidth: 4096, maxHeight: 4096),
    ]

    @Test("the intersection keeps the device's order and drops what the consumer did not offer")
    func intersection() throws {
        // The reference machine's feedback for XRGB8888, plus an ARGB-only entry and INVALID.
        let offered = [DRMModifier.linear, Self.compressed, 0x0200_0000_0040_1603, Self.tiled, DRMModifier.invalid, Self.tiled]
            .map { DRMFormat(fourcc: .xrgb8888, modifier: $0) }
            + [DRMFormat(fourcc: .argb8888, modifier: Self.small)]
        let common = try ModifierNegotiation.negotiate(
            offered: offered, fourcc: .xrgb8888, device: Self.device, width: 1896, height: 1000)
        #expect(common == [Self.tiled, Self.compressed, DRMModifier.linear])

        // The same list for ARGB8888 is only what was offered with that fourcc.
        #expect(try ModifierNegotiation.negotiate(
            offered: offered, fourcc: .argb8888, device: Self.device, width: 1896, height: 1000) == [Self.small])
    }

    @Test("a modifier the device cannot render to, export, or fit is left out")
    func deviceLimits() throws {
        let offered = [Self.tiled, Self.compressed, DRMModifier.linear, Self.small].map { DRMFormat(fourcc: .xrgb8888, modifier: $0) }
        var device = Self.device
        device[0].supportsTarget = false
        device[1].exportable = false
        device[2].planeCount = 5
        // 7680 wide (5K2K at 1.0, or 3840 at 2.0) is beyond `small`'s 4096.
        #expect(throws: ModifierNegotiationError.self) {
            try ModifierNegotiation.negotiate(offered: offered, fourcc: .xrgb8888, device: device, width: 7680, height: 2160)
        }
        #expect(try ModifierNegotiation.negotiate(
            offered: offered, fourcc: .xrgb8888, device: device, width: 4096, height: 2160) == [Self.small])
    }

    @Test("no common modifier and a non-B8G8R8A8 fourcc are errors that name what was on offer")
    func failures() {
        let offered = [DRMFormat(fourcc: .xrgb8888, modifier: DRMModifier.invalid), DRMFormat(fourcc: .xrgb8888, modifier: 0x42)]
        #expect(throws: ModifierNegotiationError.noCommonModifier(
            fourcc: .xrgb8888, offered: [DRMModifier.invalid, 0x42],
            device: [Self.tiled, Self.compressed, DRMModifier.linear, Self.small])) {
            try ModifierNegotiation.negotiate(offered: offered, fourcc: .xrgb8888, device: Self.device, width: 64, height: 64)
        }
        #expect(throws: ModifierNegotiationError.unsupportedFourCC(DRMFourCC("NV12"))) {
            try ModifierNegotiation.negotiate(offered: offered, fourcc: DRMFourCC("NV12"), device: Self.device, width: 64, height: 64)
        }
        #expect(ModifierNegotiationError.noCommonModifier(fourcc: .xrgb8888, offered: [], device: [0]).description
            .contains("0x0000000000000000"))
    }
}

// MARK: - Pure: the ownership transfers

@Suite("presentation ring ownership barriers")
struct OwnershipBarrierTests {
    /// Validation reports a missing foreign transfer only intermittently, and on one GPU the bytes
    /// usually come out right without it, so the barriers themselves are pinned here.
    private static var image: VkImage { VkImage(bitPattern: 0x1000)! }

    @Test("present releases to VK_QUEUE_FAMILY_FOREIGN_EXT in GENERAL, after the frame's writes")
    func release() {
        let barrier = PresentationRing.Image.releaseBarrier(Self.image, from: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, family: 2)
        #expect(barrier.srcQueueFamilyIndex == 2)
        #expect(barrier.dstQueueFamilyIndex == VK_QUEUE_FAMILY_FOREIGN_EXT)
        #expect(barrier.oldLayout == VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL && barrier.newLayout == VK_IMAGE_LAYOUT_GENERAL)
        #expect(barrier.srcStageMask == VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT)
        #expect(barrier.srcAccessMask == VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT)
        #expect(barrier.dstStageMask == VK_PIPELINE_STAGE_2_NONE && barrier.dstAccessMask == VK_ACCESS_2_NONE)
        #expect(barrier.image == Self.image)
    }

    @Test("take-back acquires from VK_QUEUE_FAMILY_FOREIGN_EXT out of GENERAL, keeping the contents")
    func acquire() {
        let barrier = PresentationRing.Image.acquireBarrier(Self.image, family: 2)
        #expect(barrier.srcQueueFamilyIndex == VK_QUEUE_FAMILY_FOREIGN_EXT)
        #expect(barrier.dstQueueFamilyIndex == 2)
        #expect(barrier.oldLayout == VK_IMAGE_LAYOUT_GENERAL, "not UNDEFINED: WOR-313 S5b copies from what is there")
        #expect(barrier.newLayout == VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        #expect(barrier.srcStageMask == VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, "ordered after the wait on the consumer's fences")
        #expect(barrier.dstStageMask & VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT != 0)
    }
}

// MARK: - GPU fixture

/// One device that can export, with everything a test needs to make another device on it.
struct ExportingGPU {
    let instance: VulkanInstance
    let physical: VkPhysicalDevice
    let candidate: GPUCandidate
    let device: VulkanDevice

    var name: String { candidate.name }

    /// Every eligible device that reports the ring's extensions, each as a presenting device. The
    /// rest are logged; with none, the calling test is cancelled with the reason.
    static func all(sourceLocation: SourceLocation = #_sourceLocation) throws -> [ExportingGPU] {
        let exporting = try available()
        if exporting.isEmpty {
            try Test.cancel("no Vulkan device reports \(PresentationRing.requiredExtensions.joined(separator: ", "))",
                            sourceLocation: sourceLocation)
        }
        return exporting
    }

    /// `all()` for a test that also runs without one: the devices left out are logged.
    static func available() throws -> [ExportingGPU] {
        let instance = try VulkanInstance(validation: VulkanTestEnvironment.validation)
        let physical = try instance.physicalDevices()
        var exporting: [ExportingGPU] = []
        for (index, device) in physical.enumerated() {
            let candidate = try PhysicalDeviceProbe.candidate(device, index: index)
            let missing = PresentationRing.requiredExtensions.filter { candidate.missingPresentationExtensions.contains($0) }
            guard candidate.isEligible, missing.isEmpty else {
                print("PresentationRingTests: skipping \(candidate.name): "
                    + (candidate.isEligible ? "missing \(missing.joined(separator: ", "))" : "not eligible"))
                continue
            }
            let presenting = try VulkanDevice(instance: instance, physicalDevice: device, candidate: candidate, mode: .presenting)
            exporting.append(ExportingGPU(instance: instance, physical: device, candidate: candidate, device: presenting))
        }
        return exporting
    }

    /// What a consumer that takes anything the device exports would offer; with `fallbacks`, also
    /// LINEAR and the implicit modifier, as GTK lists them.
    func offered(_ fourcc: DRMFourCC = .xrgb8888, fallbacks: Bool = false) -> [DRMFormat] {
        PresentationRing.deviceModifiers(physical).map { DRMFormat(fourcc: fourcc, modifier: $0.modifier) }
            + (fallbacks ? [DRMModifier.linear, DRMModifier.invalid].map { DRMFormat(fourcc: fourcc, modifier: $0) } : [])
    }

    func expectNoValidationErrors(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(instance.validationLog.errorCount == 0, "\(name): \(VulkanTestEnvironment.messages(instance))",
                sourceLocation: sourceLocation)
    }
}

/// A compositor stand-in: a second VkDevice on the same GPU that imports a presented dma-buf from
/// its fd, modifier and plane layout (VkImageDrmFormatModifierExplicitCreateInfoEXT), waits for
/// the dma-buf's write fences, takes it from VK_QUEUE_FAMILY_FOREIGN_EXT, copies it out and hands
/// it back in GENERAL, as a compositor's GPU does. An implicit-modifier frame is imported the way
/// the same driver infers it: a VK_IMAGE_TILING_LINEAR image, whose row pitch must be the stride.
final class DmabufReader {
    let device: VulkanDevice
    private let memoryFdProperties: PFN_vkGetMemoryFdPropertiesKHR

    init(_ gpu: ExportingGPU) throws {
        device = try VulkanDevice(instance: gpu.instance, physicalDevice: gpu.physical, candidate: gpu.candidate, mode: .presenting)
        memoryFdProperties = try #require(deviceProc(device.handle, "vkGetMemoryFdPropertiesKHR", as: PFN_vkGetMemoryFdPropertiesKHR.self))
    }

    /// The frame's pixels as tightly packed BGRA rows, once the fences on its dma-buf have signalled.
    func read(_ frame: PresentedFrame) throws -> [UInt8] {
        let vk = device.handle
        let dmabuf = frame.dmabuf

        var image: VkImage?
        let layouts = dmabuf.planes.map {
            VkSubresourceLayout(offset: VkDeviceSize($0.offset), size: 0, rowPitch: VkDeviceSize($0.stride), arrayPitch: 0, depthPitch: 0)
        }
        let implicit = dmabuf.modifier == DRMModifier.invalid
        let created = layouts.withUnsafeBufferPointer { layouts in
            var explicit = VkImageDrmFormatModifierExplicitCreateInfoEXT()
            explicit.sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT
            explicit.drmFormatModifier = dmabuf.modifier
            explicit.drmFormatModifierPlaneCount = UInt32(layouts.count)
            explicit.pPlaneLayouts = layouts.baseAddress
            var external = VkExternalMemoryImageCreateInfo()
            external.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
            external.handleTypes = VkExternalMemoryHandleTypeFlags(VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT.rawValue)
            var chain = VulkanChain()
            chain.append(external)
            if !implicit { chain.append(explicit) }
            var info = VkImageCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
            info.pNext = UnsafeRawPointer(chain.head)
            info.imageType = VK_IMAGE_TYPE_2D
            info.format = PresentationRing.format
            info.extent = VkExtent3D(width: dmabuf.width, height: dmabuf.height, depth: 1)
            info.mipLevels = 1
            info.arrayLayers = 1
            info.samples = VK_SAMPLE_COUNT_1_BIT
            info.tiling = implicit ? VK_IMAGE_TILING_LINEAR : VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
            info.usage = VkImageUsageFlags(VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue)
            info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
            info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
            return vkCreateImage(vk, &info, nil, &image)
        }
        try vkCheck(created, "vkCreateImage (imported dma-buf)")
        defer { vkDestroyImage(vk, image, nil) }
        if implicit, let image {
            var subresource = VkImageSubresource()
            subresource.aspectMask = VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue)
            var layout = VkSubresourceLayout()
            vkGetImageSubresourceLayout(vk, image, &subresource, &layout)
            #expect(layout.rowPitch == VkDeviceSize(dmabuf.planes[0].stride) && layout.offset == VkDeviceSize(dmabuf.planes[0].offset),
                    "the inferred layout is the one presented")
        }

        // The import takes ownership of the dup on success.
        let fd = dup(dmabuf.planes[0].fd)
        #expect(fd >= 0)
        var fdProperties = VkMemoryFdPropertiesKHR()
        fdProperties.sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR
        try vkCheck(memoryFdProperties(vk, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, fd, &fdProperties), "vkGetMemoryFdPropertiesKHR")
        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(vk, image, &requirements)
        let type = try #require(device.memoryTypeIndex(typeBits: requirements.memoryTypeBits & fdProperties.memoryTypeBits, required: 0))
        var importInfo = VkImportMemoryFdInfoKHR()
        importInfo.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR
        importInfo.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT
        importInfo.fd = fd
        var dedicated = VkMemoryDedicatedAllocateInfo()
        dedicated.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO
        dedicated.image = image
        var chain = VulkanChain()
        chain.append(importInfo)
        chain.append(dedicated)
        var allocateInfo = VkMemoryAllocateInfo()
        allocateInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocateInfo.pNext = UnsafeRawPointer(chain.head)
        allocateInfo.allocationSize = requirements.size
        allocateInfo.memoryTypeIndex = type
        var memory: VkDeviceMemory?
        let allocated = vkAllocateMemory(vk, &allocateInfo, nil, &memory)
        if allocated != VK_SUCCESS { close(fd) }
        try vkCheck(allocated, "vkAllocateMemory (dma-buf import)")
        defer { vkFreeMemory(vk, memory, nil) }
        try vkCheck(vkBindImageMemory(vk, image, memory, 0), "vkBindImageMemory (dma-buf import)")
        let source = try #require(image)

        // Implicit sync, as a reader: wait for the writers' fences the producer attached.
        #expect(try PresentationRingTests.waitForWriters(dmabuf, timeoutMilliseconds: 10_000), "the frame's fence never signalled")

        let byteCount = Int(dmabuf.width) * Int(dmabuf.height) * 4
        let readback = try HostBuffer(device: device, capacity: byteCount,
                                      usage: VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue), placement: .readback)
        let family = device.queueFamily
        try device.submitOnce { commands in
            pipelineBarrier(commands, images: [imageBarrier(
                source, from: VK_IMAGE_LAYOUT_GENERAL, to: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                source: (VK_PIPELINE_STAGE_2_NONE, VK_ACCESS_2_NONE),
                destination: (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_READ_BIT),
                ownership: (VK_QUEUE_FAMILY_FOREIGN_EXT, family))])
            var region = VkBufferImageCopy()
            region.imageSubresource = VkImageSubresourceLayers(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
            region.imageExtent = VkExtent3D(width: dmabuf.width, height: dmabuf.height, depth: 1)
            vkCmdCopyImageToBuffer(commands, source, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.handle, 1, &region)
            pipelineBarrier(commands, images: [imageBarrier(
                source, from: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, to: VK_IMAGE_LAYOUT_GENERAL,
                source: (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_NONE), destination: (VK_PIPELINE_STAGE_2_NONE, VK_ACCESS_2_NONE),
                ownership: (family, VK_QUEUE_FAMILY_FOREIGN_EXT))],
                buffers: [bufferBarrier(
                    readback.handle, source: (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT),
                    destination: (VK_PIPELINE_STAGE_2_HOST_BIT, VK_ACCESS_2_HOST_READ_BIT))])
        }
        return Array(UnsafeRawBufferPointer(start: readback.mapped, count: byteCount))
    }
}

/// Clears all of `target` to `color` and waits: a stand-in frame for the ring tests. Like the
/// renderer, it tells the target what it drew.
private func clear(_ target: some VulkanRenderTarget, to color: BGRA8, on device: VulkanDevice) throws {
    try device.submitOnce { commands in
        pipelineBarrier(commands, images: [imageBarrier(
            target.image, from: target.layout, to: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            source: lastAccess(of: target.layout),
            destination: (VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT))])
        target.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        var attachment = VkRenderingAttachmentInfo()
        attachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
        attachment.imageView = target.view
        attachment.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
        attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE
        attachment.clearValue = VkClearValue(color: VkClearColorValue(float32: (
            Float(color.r) / 255, Float(color.g) / 255, Float(color.b) / 255, Float(color.a) / 255)))
        withUnsafePointer(to: &attachment) { attachment in
            var rendering = VkRenderingInfo()
            rendering.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
            rendering.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: target.width, height: target.height))
            rendering.layerCount = 1
            rendering.colorAttachmentCount = 1
            rendering.pColorAttachments = attachment
            vkCmdBeginRendering(commands, &rendering)
            vkCmdEndRendering(commands)
        }
    }
    target.didDraw(PixelRect(width: Int(target.width), height: Int(target.height)))
}

/// Pixels of tightly packed BGRA bytes that are not `color`.
private func pixelsDiffering(_ bytes: [UInt8], from color: BGRA8) -> Int {
    let expected = [color.b, color.g, color.r, color.a]
    return stride(from: 0, to: bytes.count, by: 4).count { !bytes[$0..<$0 + 4].elementsEqual(expected) }
}

// MARK: - GPU: the ring

@Suite("Vulkan presentation ring", .serialized, .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
struct PresentationRingTests {

    /// Polls a sync_file of the dma-buf's write fences (what a reader waits for) until it signals.
    static func waitForWriters(_ dmabuf: DmabufDescription, timeoutMilliseconds: Int32) throws -> Bool {
        var syncFile: Int32 = -1
        let status = tkz_dma_buf_export_sync_file(dmabuf.planes[0].fd, tkz_dma_buf_sync_read(), &syncFile)
        try #require(status == 0, "DMA_BUF_IOCTL_EXPORT_SYNC_FILE failed (errno \(-status))")
        defer { close(syncFile) }
        var poller = pollfd(fd: syncFile, events: Int16(POLLIN), revents: 0)
        var ready: Int32
        repeat { ready = poll(&poller, 1, timeoutMilliseconds) } while ready < 0 && errno == EINTR
        return ready == 1
    }

    @Test("every exporting GPU: images export with one modifier and layout, cycle through the foreign queue, and read back exactly")
    func exportAndCycle() throws {
        for gpu in try ExportingGPU.all() {
            let offered = gpu.offered()
            let ring = try PresentationRing(device: gpu.device, width: 301, height: 77, offered: offered)
            let reader = try DmabufReader(gpu)
            print("PresentationRingTests: \(gpu.name): modifier \(DRMModifier.hex(ring.modifier)), \(ring.planeCount) plane(s) "
                + "\(ring.images[0].dmabuf.planes.map { "offset \($0.offset) stride \($0.stride)" }), sync \(ring.sync.rawValue)")

            // One modifier and one plane layout for the whole ring, from the consumer's list, each
            // image with its own fd shared by its planes.
            #expect(offered.contains(DRMFormat(fourcc: .xrgb8888, modifier: ring.modifier)))
            #expect(Set(ring.images.map(\.dmabuf.planes.count)) == [ring.planeCount])
            #expect(Set(ring.images.map { $0.dmabuf.planes.map(\.stride) }).count == 1)
            for image in ring.images {
                #expect(image.dmabuf.fourcc == .xrgb8888 && image.dmabuf.modifier == ring.modifier)
                #expect(image.dmabuf.width == 301 && image.dmabuf.height == 77)
                #expect(Set(image.dmabuf.planes.map(\.fd)).count == 1 && image.dmabuf.planes[0].fd >= 0)
                #expect(image.dmabuf.planes[0].stride >= 301 * 4)
            }
            #expect(Set(ring.images.map { $0.dmabuf.planes[0].fd }).count == PresentationRing.depth)

            // Seven frames: every image twice and one a third time, each read back by the consumer
            // and released, so from the 4th frame on every acquire takes an image back from the foreign
            // queue family.
            for frame in 0..<7 {
                let image = try #require(try ring.acquire())
                #expect(image.index == frame % PresentationRing.depth)
                #expect(image.state == .acquired && !image.ownedByConsumer)
                let color = BGRA8(b: UInt8(frame * 30), g: 0x80, r: UInt8(255 - frame * 20), a: 0xFF)
                try clear(image, to: color, on: gpu.device)
                let presented = try ring.present(image)
                #expect(presented.slot == image.index && presented.dmabuf == image.dmabuf)
                #expect(image.state == .presented && image.ownedByConsumer && image.layout == VK_IMAGE_LAYOUT_GENERAL)
                let bytes = try reader.read(presented)
                #expect(pixelsDiffering(bytes, from: color) == 0, "\(gpu.name) frame \(frame)")
                ring.releaseSlot(presented.slot)
            }
            #expect(ring.stats.acquires == 7 && ring.stats.presents == 7 && ring.stats.releases == 7)
            #expect(ring.stats.foreignAcquires == 4)
            #expect(ring.stats.starved == 0)
            if ring.sync == .syncFile {
                #expect(ring.stats.syncFileImports == 7 && ring.stats.cpuWaits == 0)
            } else {
                #expect(ring.stats.cpuWaits == 7)
            }
            print("PresentationRingTests: \(gpu.name): \(ring.stats)")
            gpu.expectNoValidationErrors()
        }
    }

    @Test("the render-done sync_file lands on the dma-buf as its write fence and signals; forced CPU waits read back the same")
    func explicitSync() throws {
        for gpu in try ExportingGPU.all() {
            let reader = try DmabufReader(gpu)
            for mode in [PresentationSync.syncFile, .cpuWait] {
                let ring = try PresentationRing(device: gpu.device, width: 64, height: 48, offered: gpu.offered(), sync: mode)
                if mode == .syncFile {
                    // RADV, NVIDIA and lavapipe export SYNC_FD; a device that cannot is logged.
                    if ring.sync != .syncFile { print("PresentationRingTests: \(gpu.name): no SYNC_FD export, CPU waits") }
                } else {
                    #expect(ring.sync == .cpuWait)
                }
                let color = BGRA8(b: 0x11, g: 0x22, r: 0x33, a: 0xFF)
                for _ in 0..<4 {
                    let image = try #require(try ring.acquire())
                    try clear(image, to: color, on: gpu.device)
                    let frame = try ring.present(image)
                    #expect(frame.sync == ring.sync)
                    // The writers' fence is there and signals; a reader that waits for it sees the frame.
                    #expect(try Self.waitForWriters(frame.dmabuf, timeoutMilliseconds: 10_000))
                    #expect(pixelsDiffering(try reader.read(frame), from: color) == 0, "\(gpu.name) \(mode)")
                    ring.releaseSlot(frame.slot)
                }
                if ring.sync == .syncFile {
                    #expect(ring.stats.syncFileImports == 4 && ring.stats.cpuWaits == 0, "\(gpu.name)")
                    // The kernel always has a fence to export (a signalled stub at worst), so every
                    // take-back waited for the consumer on the GPU.
                    #expect(ring.stats.consumerFenceWaits == ring.stats.foreignAcquires, "\(gpu.name)")
                } else {
                    #expect(ring.stats.cpuWaits == 4 && ring.stats.syncFileImports == 0, "\(gpu.name)")
                }
            }
            gpu.expectNoValidationErrors()
        }
    }

    @Test("a held ring starves instead of blocking; releaseSlot frees an image; an unpresented image comes back without a foreign acquire")
    func slotLifecycle() throws {
        let gpu = try #require(try ExportingGPU.all().first)
        let ring = try PresentationRing(device: gpu.device, width: 32, height: 32, fourcc: .argb8888, offered: gpu.offered(.argb8888))
        #expect(ring.images.allSatisfy { $0.dmabuf.fourcc == .argb8888 })

        // The consumer holds all three: the fourth acquire is nil, at once.
        var presented: [PresentedFrame] = []
        for _ in 0..<PresentationRing.depth {
            let image = try #require(try ring.acquire())
            try clear(image, to: BGRA8(b: 0, g: 0, r: 0, a: 0x80), on: gpu.device)
            presented.append(try ring.present(image))
        }
        #expect(try ring.acquire() == nil)
        #expect(ring.stats.starved == 1)

        // Releasing one frees exactly that one, taken back from the foreign queue family.
        ring.releaseSlot(presented[1].slot)
        let reused = try #require(try ring.acquire())
        #expect(reused.index == 1)
        #expect(ring.stats.foreignAcquires == 1)
        #expect(try ring.acquire() == nil, "slots 0 and 2 are still held")

        // Handed back unpresented: still ours, so no ownership acquire the next time.
        ring.releaseSlot(reused.index)
        #expect(reused.state == .free && !reused.ownedByConsumer)
        let again = try #require(try ring.acquire())
        #expect(again === reused)
        #expect(ring.stats.foreignAcquires == 1)
        try clear(again, to: BGRA8(b: 1, g: 2, r: 3, a: 4), on: gpu.device)
        _ = try ring.present(again)

        // A second release of a free image (a duplicate destroy-notify) changes nothing.
        let releases = ring.stats.releases
        for slot in 0..<PresentationRing.depth { ring.releaseSlot(slot) }
        ring.releaseSlot(0)
        #expect(ring.stats.releases == releases + PresentationRing.depth)
        gpu.expectNoValidationErrors()
    }

    @Test("a device without the export extensions cannot make a ring")
    func headlessCannotExport() throws {
        let device = try VulkanTestDevice.make()
        #expect(throws: PresentationRingError.missingExtensions(PresentationRing.requiredExtensions)) {
            try PresentationRing(device: device, width: 8, height: 8, offered: [DRMFormat(fourcc: .xrgb8888, modifier: 0)])
        }
    }

    @Test("the renderer draws a terminal into a ring image through the acquire seam, byte for byte the offscreen frame")
    func rendererDrawsIntoTheRing() throws {
        for gpu in try ExportingGPU.all() {
            let renderer = try VulkanTerminalRenderer(device: gpu.device, glyphCache: try RendererFonts.cache())
            let session = try RendererScreen.makeSession()
            let surface = TerminalSurface()
            try surface.attach(session)
            let size = renderer.drawableSize(columns: Int(RendererScreen.columns), rows: Int(RendererScreen.rows))
            let ring = try PresentationRing(device: gpu.device, width: UInt32(size.width), height: UInt32(size.height),
                                            offered: gpu.offered())
            let reader = try DmabufReader(gpu)

            var acquired: PresentationRing.Image?
            func renderIntoRing() throws -> RenderOutcome {
                try renderer.render(surface: surface, targetWidth: size.width, targetHeight: size.height) {
                    acquired = try ring.acquire()
                    return acquired
                }
            }
            let outcome = try renderIntoRing()
            #expect(outcome.didEncode)
            #expect(renderer.stats.drawablesAcquired == 1)
            let image = try #require(acquired)
            let frame = try ring.present(image)
            let presentedBytes = try reader.read(frame)
            ring.releaseSlot(frame.slot)

            // The same surface, forced, into an offscreen target on the same device.
            let offscreen = try OffscreenTarget(device: gpu.device, width: UInt32(size.width), height: UInt32(size.height))
            let reference = try renderer.render(surface: surface, targetWidth: size.width, targetHeight: size.height,
                                                forceEncode: true) { offscreen }
            try reference.frame?.waitUntilCompleted()
            let expected = try offscreen.bgraBytes()
            #expect(presentedBytes.count == expected.count)
            #expect(presentedBytes == expected, "\(gpu.name): \(zip(presentedBytes, expected).count { $0 != $1 }) bytes differ")

            // Unchanged state takes no ring image (the window-level twin is in PresentationDamageTests).
            acquired = nil
            renderer.resetStats()
            let idle = try renderIntoRing()
            #expect(!idle.didEncode && acquired == nil)
            #expect(renderer.stats.drawableRequests == 0)
            #expect(ring.stats.acquires == 1)
            gpu.expectNoValidationErrors()
        }
    }
}
