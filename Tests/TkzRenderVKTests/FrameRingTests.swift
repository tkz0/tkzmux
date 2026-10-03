// FrameRingTests — the per-surface ring of the Vulkan renderer on a real device (WOR-313 S4a).
//
// Slot reuse waits on that slot's own fence and nothing else; buffers are made on first write and
// grow by doubling; what a slot retires lives until its fence; the ring belongs to its surface and
// goes with `detach()`. Like the bootstrap tests, these need a Vulkan driver and are skipped by name
// without one (a failure under TKZMUX_REQUIRE_VULKAN=1), and every one asserts the validation
// messenger counted no error.

import CVulkan
import Testing
import TkzRenderCore
@testable import TkzRenderVK

enum VulkanTestDevice {
    /// A headless device on the GPU TKZMUX_GPU selects (the loader's first by default), with the
    /// validation layer wherever it is installed.
    static func make() throws -> VulkanDevice {
        let instance = try VulkanInstance(validation: VulkanTestEnvironment.validation)
        return try VulkanDevice.make(instance: instance, mode: .headless).device
    }

    /// Copies `byteCount` bytes of `source` back to the host. The copy is submitted after, and so
    /// ordered after, everything already submitted.
    static func read(_ source: VkBuffer, byteCount: Int, on device: VulkanDevice) throws -> [UInt8] {
        let target = try HostBuffer(device: device, capacity: byteCount,
                                    usage: VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue), placement: .readback)
        try device.submitOnce { commands in
            var region = VkBufferCopy(srcOffset: 0, dstOffset: 0, size: VkDeviceSize(byteCount))
            vkCmdCopyBuffer(commands, source, target.handle, 1, &region)
            pipelineBarrier(commands, buffers: [bufferBarrier(
                target.handle, source: (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT),
                destination: (VK_PIPELINE_STAGE_2_HOST_BIT, VK_ACCESS_2_HOST_READ_BIT))])
        }
        return Array(UnsafeRawBufferPointer(start: target.mapped, count: byteCount))
    }

    static func expectNoValidationErrors(_ device: VulkanDevice, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(device.instance.validationLog.errorCount == 0, "\(VulkanTestEnvironment.messages(device.instance))",
                sourceLocation: sourceLocation)
    }
}

@Suite("Vulkan FrameRing", .serialized, .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
struct FrameRingTests {

    @Test("reusing a slot waits on that slot's fence only; fresh slots and other rings never wait")
    func reuseWaitsOnItsOwnFence() throws {
        let device = try VulkanTestDevice.make()
        let vk = device.handle
        let ring = try FrameRing(device: device)
        let other = try FrameRing(device: device)

        let held = try ring.acquire()
        #expect(held.index == 0)
        try held.write([UInt8](repeating: 1, count: 256), to: .glyphs)
        try ring.submit(held)
        try ring.waitUntilCompleted(held)
        // Hold slot 0's frame open: its fence unsignalled, as while the GPU is still on the frame.
        // (A GPU-side gate is not an option: waiting on a host-set VkEvent from a pending command
        // buffer is invalid usage, VUID-vkSetEvent-event-09543.)
        var fence: VkFence? = held.fence
        try vkCheck(vkResetFences(vk, 1, &fence), "vkResetFences")

        // The other two slots were never submitted: handed out at once.
        let second = try ring.acquire()
        let third = try ring.acquire()
        #expect([second.index, third.index] == [1, 2])
        #expect(ring.stats.fenceWaits == 0)

        // Another surface's ring goes round more than once without waiting on this one's frame.
        for expected in [0, 1, 2, 0] { #expect(try other.acquire().index == expected) }
        #expect(other.stats.fenceWaits == 0)

        // Slot 0 again: its frame has not finished, so the acquire blocks (here: times out) and
        // the ring does not advance. The other slots' fences are signalled throughout.
        #expect(try ring.acquire(timeoutNanoseconds: 20_000_000) == nil)
        #expect(ring.stats.fenceWaits == 1)
        #expect(vkGetFenceStatus(vk, second.fence) == VK_SUCCESS)
        #expect(vkGetFenceStatus(vk, third.fence) == VK_SUCCESS)

        // The frame finishes (an empty submission signals the fence): the same slot comes back,
        // with the buffer it already had.
        try vkCheck(vkQueueSubmit2(device.queue, 0, nil, held.fence), "vkQueueSubmit2")
        let reused = try ring.acquire()
        #expect(reused === held)
        #expect(reused.capacity(of: .glyphs) == 256)
        #expect(ring.stats.acquires == 4)
        #expect(ring.stats.submits == 1)

        VulkanTestDevice.expectNoValidationErrors(device)
    }

    @Test("a slot whose frame bailed out before submitting is free again, with a fresh command buffer")
    func bailedFrameNeedsNoRelease() throws {
        let device = try VulkanTestDevice.make()
        let ring = try FrameRing(device: device)
        for _ in 0..<(2 * FrameRing.depth) {
            let slot = try ring.acquire()
            _ = try slot.commands()  // begun, never submitted
            #expect(slot.isRecording)
        }
        #expect(ring.stats.fenceWaits == 0)
        let slot = try ring.acquire()
        #expect(!slot.isRecording)
        try ring.submit(slot)
        try ring.waitUntilCompleted(slot)
        VulkanTestDevice.expectNoValidationErrors(device)
    }

    @Test("buffers are made on first write and grow by doubling, per slot and per role")
    func buffersGrowByDoubling() throws {
        let device = try VulkanTestDevice.make()
        let ring = try FrameRing(device: device)
        #expect(ring.byteCount == 0, "lazy: a new ring holds no buffers")

        let slot = try ring.acquire()
        #expect(slot.capacity(of: .glyphs) == nil)
        #expect(try slot.write([UInt32](), to: .glyphs) == nil, "nothing to bind for no values")
        #expect(slot.capacity(of: .glyphs) == nil)

        // (bytes written, capacity after): first allocation exact, then max(needed, 2 × capacity).
        let steps = [(100, 100), (150, 200), (200, 200), (1000, 1000), (1001, 2000), (64, 2000)]
        var handles: [VkBuffer] = []
        for (bytes, capacity) in steps {
            let binding = try #require(try slot.write([UInt8](repeating: UInt8(bytes & 0xFF), count: bytes), to: .glyphs))
            #expect(binding.byteCount == bytes)
            #expect(slot.capacity(of: .glyphs) == capacity, "after writing \(bytes) bytes")
            handles.append(binding.buffer)
        }
        #expect(handles[1] == handles[2] && handles[4] == handles[5], "no reallocation while it fits")
        #expect(Set(handles.map { UInt(bitPattern: $0) }).count == 4)
        #expect(ring.stats.bufferAllocations == 4)
        #expect(slot.heldRetirements == 3, "outgrown buffers live until the slot's fence")

        // Typed writes count stride × count bytes, and the GPU reads what the CPU wrote (coherent
        // memory, no flush).
        let words: [UInt32] = (0..<300).map { $0 &* 2_654_435_761 }
        let binding = try #require(try slot.write(words, to: .background))
        #expect(binding.byteCount == 1200)
        #expect(slot.capacity(of: .background) == 1200)
        #expect(slot.capacity(of: .rectsBelow) == nil && slot.capacity(of: .rectsAbove) == nil)
        #expect(ring.byteCount == 2000 + 1200)
        try ring.submit(slot)
        let read = try VulkanTestDevice.read(binding.buffer, byteCount: binding.byteCount, on: device)
        #expect(read == words.withUnsafeBytes { Array($0) })

        // Other slots are sized on their own.
        let next = try ring.acquire()
        #expect(next.index != slot.index)
        #expect(next.capacity(of: .glyphs) == nil)
        try next.write([UInt8](repeating: 1, count: 10), to: .glyphs)
        #expect(next.capacity(of: .glyphs) == 10)
        #expect(slot.capacity(of: .glyphs) == 2000)
        try ring.submit(next)

        // Back to the first slot: its fence has signalled, the outgrown buffers are gone, and the
        // grown one is kept.
        try ring.submit(try ring.acquire())
        let again = try ring.acquire()
        #expect(again === slot)
        #expect(again.heldRetirements == 0)
        #expect(again.capacity(of: .glyphs) == 2000)
        VulkanTestDevice.expectNoValidationErrors(device)
    }

    @Test("a whole-atlas staging buffer is freed when its slot comes round again; a small one is kept")
    func oversizedStagingIsTrimmed() throws {
        let device = try VulkanTestDevice.make()
        let ring = try FrameRing(device: device)
        let big = try ring.acquire()
        _ = try big.buffer(.staging, atLeast: FrameRing.stagingRetainLimit + 1)
        try ring.submit(big)
        let small = try ring.acquire()
        _ = try small.buffer(.staging, atLeast: 4096)
        try ring.submit(small)
        try ring.submit(try ring.acquire())

        #expect(try ring.acquire() === big)
        #expect(big.capacity(of: .staging) == nil)
        try ring.submit(big)
        #expect(try ring.acquire() === small)
        #expect(small.capacity(of: .staging) == 4096)
        try ring.submit(small)
        VulkanTestDevice.expectNoValidationErrors(device)
    }

    @Test("every surface owns its ring, made on first use; detach drops it once its frames are done")
    func everySurfaceOwnsItsRing() throws {
        let device = try VulkanTestDevice.make()
        let first = TerminalSurface()
        let second = TerminalSurface()
        #expect(first.frameRing == nil)

        weak var dropped: FrameRing?
        do {
            let ring = try first.frameRing(on: device)
            #expect(try first.frameRing(on: device) === ring)
            #expect(try second.frameRing(on: device) !== ring)
            #expect(ring.byteCount == 0)
            // A frame still in flight when the surface detaches: the ring waits for it before it
            // destroys its fences and buffers (validation would flag a fence or buffer in use).
            let slot = try ring.acquire()
            try slot.write([UInt8](repeating: 7, count: 4096), to: .glyphs)
            try ring.submit(slot)
            dropped = ring
        }
        #expect(dropped != nil)
        first.detach()
        #expect(first.frameRing == nil)
        #expect(dropped == nil)
        #expect(second.frameRing != nil, "the other surface keeps its own")
        VulkanTestDevice.expectNoValidationErrors(device)
    }
}
