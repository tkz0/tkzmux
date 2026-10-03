// FrameRing — the per-surface instance-buffer ring of the Vulkan renderer (WOR-313 S4a).
//
// The Mac's `FrameRing` (TkzTerminalRender) with Vulkan synchronization, per surface for the same
// reasons: N panes in one tick take slots from N rings, so no pane waits on another pane's frames;
// each pane's buffers are sized to that pane; and `TerminalSurface.detach()` drops the whole ring.
//
// What differs is how a slot comes back. Metal signals a semaphore from a completion handler on
// another thread, which is why the Mac ring has a `Sendable` releaser. Here every slot has its own
// `VkFence`, signalled by the submission that last used the slot, and `acquire()` waits for that
// fence on the main actor before handing the slot out again. Nothing crosses a thread, and reusing
// a slot waits on that slot's previous frame only, never on another slot or another surface. A
// frame that bails out before `submit` needs no release either: fences are reset only in `submit`,
// so the slot's fence still holds the state of its last submission. (Except a frame that recorded
// an atlas upload, which must be submitted; see `Slot.mustSubmit`.)
//
// A slot holds:
//   - one persistently mapped HOST_VISIBLE | HOST_COHERENT buffer per `SlotBuffer` role, made on
//     first use and grown by doubling, like the Mac's `upload(_:into:)`;
//   - the staging buffer that atlas uploads copy from (`VulkanAtlasUploader`);
//   - the descriptor sets that bind those buffers and the atlases (`FrameDescriptors`, S4b);
//   - one primary command buffer, begun on first use and submitted with the slot's fence;
//   - whatever was retired while the slot was recorded (a buffer that grew, an atlas image the
//     uploader replaced). It is kept until the slot's fence signals after the submission that
//     followed the retirement. That fence covers more than its own batch: a fence signal operation's
//     first synchronization scope includes every command submitted earlier to the same queue, and
//     the renderer has one queue. So an atlas image that other surfaces' earlier frames sampled is
//     safe to destroy then too.
//
// Not `Sendable`. Like the Mac ring it lives where the renderer runs (the main actor in the app, one
// test function in tests); `VulkanDevice` and every handle here are confined the same way.

import CVulkan
import TkzRenderCore

/// The buffers of one ring slot. The four instance roles are the Mac `FrameRing.Slot`'s.
public enum SlotBuffer: CaseIterable, Sendable {
    case background
    case glyphs
    case rectsBelow
    case rectsAbove
    /// Atlas upload rows (`VulkanAtlasUploader`).
    case staging

    /// Instance buffers are read by the shaders as storage buffers, and are TRANSFER_SRC so a test
    /// or diagnostic can copy one back.
    var usage: VkBufferUsageFlags {
        self == .staging
            ? VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue)
            : VkBufferUsageFlags(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue)
    }

    var placement: HostBuffer.Placement { self == .staging ? .upload : .gpuRead }
}

/// A buffer written for this frame: what to bind, and how many bytes the write took.
public struct SlotBinding {
    public let buffer: VkBuffer
    public let byteCount: Int
}

/// Ring instrumentation, read by the tests.
public struct RingStats: Sendable, Hashable {
    /// `acquire` calls that handed out a slot.
    public var acquires = 0
    /// `acquire` calls that found the slot's fence unsignalled and blocked on it (or timed out).
    /// Zero while the GPU keeps up.
    public var fenceWaits = 0
    /// Frames submitted.
    public var submits = 0
    /// Buffers created, first allocations and grows alike.
    public var bufferAllocations = 0
}

/// Three slots, cycled so the CPU can write frame N+2 while the GPU still reads frame N.
public final class FrameRing {
    public static let depth = 3

    /// A staging buffer larger than this is freed when its slot is next acquired. Only whole-atlas
    /// uploads (the first frame, a grow, a rebuild: up to 20 MiB at 2048²) need one that big, and
    /// keeping it would hold that much per slot of every pane.
    static let stagingRetainLimit = 4 << 20

    /// One frame's buffers, command buffer and fence.
    public final class Slot {
        /// The slot's position in its ring, 0..<depth.
        public let index: Int
        let device: VulkanDevice
        let fence: VkFence
        let commandBuffer: VkCommandBuffer
        /// True between the first `commands()` of a frame and its `submit`.
        private(set) var isRecording = false
        /// The frame recorded work that cannot be dropped (an atlas upload, whose box the atlas has
        /// already forgotten): it must be submitted, not bailed out of. Checked when the slot comes
        /// round again.
        private(set) var mustSubmit = false

        private var buffers: [SlotBuffer: HostBuffer] = [:]
        /// The renderer's descriptor sets for this slot (WOR-313 S4b), made on its first encode.
        /// Rewritten only after `acquire` has waited for the slot's fence, so never while in use.
        var descriptors: FrameDescriptors?
        /// Retired while this frame was recorded; no submission covers it yet.
        private var retiring: [AnyObject] = []
        /// Retired before the slot's last submission; freed once its fence has signalled.
        private var retired: [AnyObject] = []
        fileprivate var allocations = 0

        fileprivate init(index: Int, device: VulkanDevice, fence: VkFence, commandBuffer: VkCommandBuffer) {
            self.index = index
            self.device = device
            self.fence = fence
            self.commandBuffer = commandBuffer
        }

        /// The slot's command buffer, begun on the first call of the frame. Everything the frame
        /// records goes here; `FrameRing.submit` ends and submits it.
        public func commands() throws -> VkCommandBuffer {
            if !isRecording {
                var begin = VkCommandBufferBeginInfo()
                begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
                begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
                try vkCheck(vkBeginCommandBuffer(commandBuffer, &begin), "vkBeginCommandBuffer")
                isRecording = true
            }
            return commandBuffer
        }

        /// Copies `values` into the `role` buffer, growing it first when it is too small, and
        /// returns what to bind. Returns nil, writing nothing, for no values: a zero-length buffer
        /// must never be bound.
        @discardableResult
        public func write<T>(_ values: UnsafeBufferPointer<T>, to role: SlotBuffer) throws -> SlotBinding? {
            guard !values.isEmpty, let base = values.baseAddress else { return nil }
            let length = MemoryLayout<T>.stride * values.count
            let target = try buffer(role, atLeast: length)
            target.mapped.copyMemory(from: base, byteCount: length)
            return SlotBinding(buffer: target.handle, byteCount: length)
        }

        @discardableResult
        public func write<T>(_ values: [T], to role: SlotBuffer) throws -> SlotBinding? {
            try values.withUnsafeBufferPointer { try write($0, to: role) }
        }

        /// The `role` buffer, at least `length` bytes. A buffer that is too small is replaced by
        /// one of `max(length, 2 × capacity)` bytes, so a growing screen does not reallocate every
        /// frame; the old one is retired, since this frame may already have recorded a use of it.
        func buffer(_ role: SlotBuffer, atLeast length: Int) throws -> HostBuffer {
            let current = buffers[role]
            if let current, current.capacity >= length { return current }
            let capacity = max(length, (current?.capacity ?? 0) * 2)
            let grown = try HostBuffer(device: device, capacity: capacity, usage: role.usage, placement: role.placement)
            if let current { retiring.append(current) }
            buffers[role] = grown
            allocations += 1
            return grown
        }

        /// The `role` buffer's capacity, or nil before its first write.
        public func capacity(of role: SlotBuffer) -> Int? { buffers[role]?.capacity }

        /// Marks the frame as one that must reach `FrameRing.submit` (`mustSubmit`).
        func requireSubmission() {
            mustSubmit = true
        }

        /// Keeps `object` alive until the GPU has finished every frame submitted up to and
        /// including this one. For an object this frame stops using, such as a replaced atlas image.
        func retire(_ object: AnyObject) {
            retiring.append(object)
        }

        /// Retired objects this slot still holds (diagnostics and tests).
        var heldRetirements: Int { retiring.count + retired.count }

        var hasUncoveredRetirements: Bool { !retiring.isEmpty }

        fileprivate var byteCount: Int { buffers.values.reduce(0) { $0 + $1.capacity } }

        /// After the slot's fence has signalled: the GPU is done with everything the slot held.
        fileprivate func recycle() throws {
            assert(!mustSubmit, "a frame that recorded an atlas upload bailed out before submitting it")
            mustSubmit = false
            try vkCheck(vkResetCommandBuffer(commandBuffer, 0), "vkResetCommandBuffer")
            isRecording = false
            retired.removeAll()
            if let staging = buffers[.staging], staging.capacity > FrameRing.stagingRetainLimit {
                buffers[.staging] = nil
            }
        }

        /// Ends recording, if the frame recorded anything. Returns whether it did.
        fileprivate func endRecording() throws -> Bool {
            guard isRecording else { return false }
            isRecording = false
            mustSubmit = false
            try vkCheck(vkEndCommandBuffer(commandBuffer), "vkEndCommandBuffer")
            return true
        }

        /// The submission that covers this frame's retirements has been queued.
        fileprivate func submitted() {
            retired.append(contentsOf: retiring)
            retiring.removeAll()
        }
    }

    public let device: VulkanDevice
    private let pool: VkCommandPool
    private let slots: [Slot]
    /// The last slot handed out; the first `acquire` hands out slot 0.
    private var index = FrameRing.depth - 1
    private var counters = RingStats()

    public init(device: VulkanDevice) throws {
        let vk = device.handle
        var poolInfo = VkCommandPoolCreateInfo()
        poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        poolInfo.flags = VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
        poolInfo.queueFamilyIndex = device.queueFamily
        var pool: VkCommandPool?
        try vkCheck(vkCreateCommandPool(vk, &poolInfo, nil, &pool), "vkCreateCommandPool")
        guard let pool else { throw VulkanError("vkCreateCommandPool", VK_ERROR_INITIALIZATION_FAILED) }

        // Destroying the pool frees its command buffers; the fences go one by one.
        var fences: [VkFence] = []
        var committed = false
        defer {
            if !committed {
                fences.forEach { vkDestroyFence(vk, $0, nil) }
                vkDestroyCommandPool(vk, pool, nil)
            }
        }

        var allocateInfo = VkCommandBufferAllocateInfo()
        allocateInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocateInfo.commandPool = pool
        allocateInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocateInfo.commandBufferCount = UInt32(Self.depth)
        var commandBuffers = [VkCommandBuffer?](repeating: nil, count: Self.depth)
        try vkCheck(vkAllocateCommandBuffers(vk, &allocateInfo, &commandBuffers), "vkAllocateCommandBuffers")

        // Signalled at creation, so a slot that has never been submitted is free.
        var fenceInfo = VkFenceCreateInfo()
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        fenceInfo.flags = VkFenceCreateFlags(VK_FENCE_CREATE_SIGNALED_BIT.rawValue)
        var slots: [Slot] = []
        for slotIndex in 0..<Self.depth {
            var fence: VkFence?
            try vkCheck(vkCreateFence(vk, &fenceInfo, nil, &fence), "vkCreateFence")
            guard let fence, let commands = commandBuffers[slotIndex] else {
                throw VulkanError("FrameRing (a create call returned no handle)", VK_ERROR_INITIALIZATION_FAILED)
            }
            fences.append(fence)
            slots.append(Slot(index: slotIndex, device: device, fence: fence, commandBuffer: commands))
        }

        self.device = device
        self.pool = pool
        self.slots = slots
        committed = true
    }

    deinit {
        // Detaching a surface drops its ring while its last frames may still be in flight.
        let vk = device.handle
        var fences: [VkFence?] = slots.map(\.fence)
        vkWaitForFences(vk, UInt32(fences.count), &fences, VkBool32(VK_TRUE), UInt64.max)
        // A retirement no submission covered (its frame bailed out) may still be in use by other
        // surfaces' frames; only the whole queue going idle says otherwise. An error path, so rare.
        if slots.contains(where: \.hasUncoveredRetirements) { vkQueueWaitIdle(device.queue) }
        for slot in slots { vkDestroyFence(vk, slot.fence, nil) }
        vkDestroyCommandPool(vk, pool, nil)
    }

    public var stats: RingStats {
        var stats = counters
        stats.bufferAllocations = slots.reduce(0) { $0 + $1.allocations }
        return stats
    }

    /// Total bytes the ring's buffers hold. Diagnostics, as on the Mac (docs/perf.md).
    public var byteCount: Int { slots.reduce(0) { $0 + $1.byteCount } }

    /// Waits until the next slot's previous frame has finished on the GPU, then hands the slot out
    /// with its command buffer reset. Waits on that slot's fence only.
    public func acquire() throws -> Slot {
        guard let slot = try acquire(timeoutNanoseconds: UInt64.max) else {
            throw VulkanError("vkWaitForFences", VK_TIMEOUT)
        }
        return slot
    }

    /// `acquire()`, giving up after `timeoutNanoseconds`; nil then, and the ring does not advance.
    func acquire(timeoutNanoseconds: UInt64) throws -> Slot? {
        let next = (index + 1) % Self.depth
        let slot = slots[next]
        let vk = device.handle
        let status = vkGetFenceStatus(vk, slot.fence)
        if status == VK_NOT_READY {
            counters.fenceWaits += 1
            var fence: VkFence? = slot.fence
            let result = vkWaitForFences(vk, 1, &fence, VkBool32(VK_TRUE), timeoutNanoseconds)
            if result == VK_TIMEOUT { return nil }
            try vkCheck(result, "vkWaitForFences")
        } else {
            try vkCheck(status, "vkGetFenceStatus")
        }
        try slot.recycle()
        index = next
        counters.acquires += 1
        return slot
    }

    /// Ends `slot`'s command buffer and submits it, signalling the slot's fence. A frame that
    /// recorded nothing still submits (an empty batch), so the fence always describes the slot's
    /// latest frame. `waits` and `signals` are the frame's semaphores (WOR-313 S5a).
    public func submit(
        _ slot: Slot, waits: [VkSemaphoreSubmitInfo] = [], signals: [VkSemaphoreSubmitInfo] = []
    ) throws {
        precondition(slots[slot.index] === slot, "a slot is submitted to the ring that handed it out")
        let vk = device.handle
        let hasCommands = try slot.endRecording()
        var fence: VkFence? = slot.fence
        try vkCheck(vkResetFences(vk, 1, &fence), "vkResetFences")

        var commandInfo = VkCommandBufferSubmitInfo()
        commandInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO
        commandInfo.commandBuffer = slot.commandBuffer
        let result = withUnsafePointer(to: &commandInfo) { commandInfo in
            waits.withUnsafeBufferPointer { waits in
                signals.withUnsafeBufferPointer { signals in
                    var submit = VkSubmitInfo2()
                    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2
                    submit.waitSemaphoreInfoCount = UInt32(waits.count)
                    submit.pWaitSemaphoreInfos = waits.baseAddress
                    submit.commandBufferInfoCount = hasCommands ? 1 : 0
                    submit.pCommandBufferInfos = hasCommands ? commandInfo : nil
                    submit.signalSemaphoreInfoCount = UInt32(signals.count)
                    submit.pSignalSemaphoreInfos = signals.baseAddress
                    return vkQueueSubmit2(device.queue, 1, &submit, slot.fence)
                }
            }
        }
        guard result == VK_SUCCESS else {
            // The fence is reset and nothing will signal it; an empty submission does, so the next
            // `acquire` of this slot cannot hang (unless the device is gone, when it fails anyway).
            _ = vkQueueSubmit2(device.queue, 0, nil, slot.fence)
            throw VulkanError("vkQueueSubmit2", result)
        }
        slot.submitted()
        counters.submits += 1
    }

    /// Blocks until `slot`'s last submission has finished: what a readback waits for.
    public func waitUntilCompleted(_ slot: Slot) throws {
        var fence: VkFence? = slot.fence
        try vkCheck(vkWaitForFences(device.handle, 1, &fence, VkBool32(VK_TRUE), UInt64.max), "vkWaitForFences")
    }
}

// The surface is device-free (TkzRenderCore) and holds its GPU state as an opaque
// `SurfaceRenderResources`; this is the Vulkan renderer's typed view of that slot.
extension FrameRing: SurfaceRenderResources {}

extension TerminalSurface {
    /// The surface's `FrameRing`, dropped by `detach()`.
    public var frameRing: FrameRing? {
        get { renderResources as? FrameRing }
        set { renderResources = newValue }
    }

    /// The surface's ring, created on first use: the renderer calls this on its first encode, since
    /// a surface has no device of its own.
    public func frameRing(on device: VulkanDevice) throws -> FrameRing {
        if let ring = frameRing, ring.device === device { return ring }
        let ring = try FrameRing(device: device)
        frameRing = ring
        return ring
    }
}
