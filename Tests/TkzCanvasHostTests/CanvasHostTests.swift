// CanvasHostTests — WOR-314 S4. The seam's pure parts (geometry, the frame-holding policy, the
// broadcast) and `FakeCanvasHost` driving real presentation ladders, the way WOR-316's offscreen
// tests will: a client on a `CanvasPresenter` draws known bytes, and the host shows them.
//
// The GPU tests run on the first Vulkan device (lavapipe in CI, where TKZMUX_REQUIRE_VULKAN=1
// turns a missing device into a failure) and assert the validation layer counted no error.

import CVulkan
import Glibc
import Testing
import TkzCanvasHost
import TkzRenderVK

// MARK: - Pure

@Suite("canvas geometry")
struct CanvasGeometryTests {
    @Test("a frame is round(logical × scale) device pixels, per axis")
    func devicePixels() {
        let geometry = CanvasGeometry(logicalWidth: 800, logicalHeight: 501, scale: 1.6)
        #expect(geometry.pixelWidth == 1280)
        #expect(geometry.pixelHeight == 802, "801.6 rounds up")
        #expect(CanvasGeometry(logicalWidth: 4800, logicalHeight: 1350, scale: 1.6).pixelWidth == 7680,
                "the reference monitor's full logical width")
        #expect(CanvasGeometry(logicalWidth: 4800, logicalHeight: 1350, scale: 1.6).pixelHeight == 2160)
        // Every logical width at 1.6: within half a pixel of the exact product, and never 0.5 off.
        for logical in 0..<2000 {
            let pixels = CanvasGeometry.devicePixels(logical, scale: 1.6)
            #expect(abs(Double(pixels) - Double(logical) * 1.6) < 0.5)
        }
        #expect(CanvasGeometry(logicalWidth: 3, logicalHeight: 3, scale: 2).pixelWidth == 6)
        #expect(CanvasGeometry(logicalWidth: 3, logicalHeight: 3, scale: 1.25).pixelWidth == 4, "3.75 → 4")
    }

    @Test("an unallocated canvas is empty")
    func empty() {
        #expect(CanvasGeometry.empty.isEmpty)
        #expect(CanvasGeometry(logicalWidth: 10, logicalHeight: 0, scale: 1.6).isEmpty)
        #expect(!CanvasGeometry(logicalWidth: 1, logicalHeight: 1, scale: 1).isEmpty)
    }

    @Test("visibility: only a mapped, unsuspended toplevel is visible")
    func visibility() {
        #expect(CanvasVisibility(isMapped: true, isSuspended: false).isVisible)
        #expect(!CanvasVisibility(isMapped: true, isSuspended: true).isVisible)
        #expect(!CanvasVisibility.hidden.isVisible)
    }
}

@Suite("canvas frame queue")
@MainActor
struct CanvasFrameQueueTests {
    @Test("a shown frame goes back two shows later; one never shown goes back when replaced")
    func releaseOrder() {
        let queue = CanvasFrameQueue<Int>()
        var released: [Int] = []
        let release: @MainActor (Int) -> Void = { released.append($0) }
        #expect(queue.show() == nil)

        queue.submit(1, release: release)
        #expect(queue.show() == 1)
        queue.submit(2, release: release)
        #expect(queue.show() == 2)
        #expect(released.isEmpty, "1 may still be on screen until the compositor latches 2")
        queue.submit(3, release: release)
        #expect(queue.show() == 3)
        #expect(released == [1])
        #expect(queue.heldCount == 2)

        // Presented twice between two shows: 4 is never seen.
        queue.submit(4, release: release)
        queue.submit(5, release: release)
        #expect(released == [1, 4])
        #expect(queue.heldCount == 3, "a ring of three still has none free until the next show")
        #expect(queue.show() == 5)
        #expect(released == [1, 4, 2])

        // No new frame: the same one is shown again, nothing moves.
        #expect(queue.show() == 5)
        #expect(released == [1, 4, 2])

        queue.releaseAll()
        #expect(released == [1, 4, 2, 5, 3])
        #expect(queue.heldCount == 0)
    }

    @Test("a frame that cannot be shown is taken out unreleased, and the previous one is shown again")
    func removeShown() {
        let queue = CanvasFrameQueue<Int>()
        var released: [Int] = []
        queue.submit(1) { released.append($0) }
        queue.show()
        queue.submit(2) { released.append($0) }
        queue.show()
        #expect(queue.removeShown() == 2)
        #expect(released.isEmpty)
        #expect(queue.show() == 1)
        queue.releaseAll()
        #expect(released == [1])
    }
}

@Suite("canvas broadcast")
@MainActor
struct CanvasBroadcastTests {
    @Test("every subscriber gets every value sent after it subscribed, and finish ends them")
    func fanOut() async {
        let broadcast = CanvasBroadcast<Int>()
        let first = broadcast.subscribe()
        broadcast.send(1)
        let second = broadcast.subscribe()
        broadcast.send(2)
        broadcast.finish()
        var a: [Int] = [], b: [Int] = []
        for await value in first { a.append(value) }
        for await value in second { b.append(value) }
        #expect(a == [1, 2])
        #expect(b == [2])
        #expect(broadcast.subscriberCount == 0)
    }
}

// MARK: - GPU: FakeCanvasHost

enum VulkanTestEnvironment {
    static let required = getenv("TKZMUX_REQUIRE_VULKAN").map { String(cString: $0) } == "1"
    static let deviceAvailable: Bool = {
        guard let instance = try? VulkanInstance(), let devices = try? instance.physicalDevices() else { return false }
        return !devices.isEmpty
    }()
    static var runs: Bool { deviceAvailable || required }
    static let skipReason: Comment = "no Vulkan device (TKZMUX_REQUIRE_VULKAN=1 makes this a failure)"
    static var validation: VulkanInstance.Validation { required ? .required : .ifAvailable }
}

/// A client that fills every frame with one colour per frame number, in full or only in a band.
@MainActor
final class SolidClient: CanvasHostClient {
    let presenter: CanvasPresenter
    var geometries: [CanvasGeometry] = []
    var draws = 0
    var presented = 0
    /// Draw only the top band after the first frame of a ladder (a partial frame).
    var partial = false

    init(presenter: CanvasPresenter) {
        self.presenter = presenter
    }

    static func color(_ frame: Int) -> [UInt8] { [UInt8(frame * 40 % 256), 0x20, 0x80, 0xFF] }

    func canvasHost(_ host: any CanvasHost, didChangeGeometry geometry: CanvasGeometry) {
        geometries.append(geometry)
    }

    func canvasHostDraw(_ host: any CanvasHost) {
        draws += 1
        let frame = draws
        let drew = try? presenter.frame(on: host) { target, fullRedraw in
            let width = Int(target.width)
            let height = fullRedraw || !partial ? Int(target.height) : 4
            let bytes = Array([[UInt8]](repeating: Self.color(frame), count: width * height).joined())
            try presenter.device.upload(bgra: bytes, width: width, height: height, to: target)
        }
        if drew == true { presented += 1 }
    }
}

@Suite("fake canvas host", .serialized, .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
@MainActor
struct FakeCanvasHostTests {
    static func device() throws -> (VulkanInstance, VulkanDevice) {
        let instance = try VulkanInstance(validation: VulkanTestEnvironment.validation)
        let made = try VulkanDevice.make(instance: instance, mode: .presenting, preference: .auto)
        return (instance, made.device)
    }

    static func pixels(_ bytes: [UInt8]?, differingFrom color: [UInt8], rows: Range<Int>? = nil, width: Int) -> Int {
        guard let bytes else { return -1 }
        let rowRange = rows ?? 0..<(bytes.count / (width * 4))
        var count = 0
        for row in rowRange {
            for column in 0..<width where !bytes[(row * width + column) * 4..<(row * width + column) * 4 + 4].elementsEqual(color) {
                count += 1
            }
        }
        return count
    }

    @Test("idle runs no frame; a request draws once, and the shown bytes are the client's")
    func requestAndShow() throws {
        let (instance, device) = try Self.device()
        let host = FakeCanvasHost(geometry: CanvasGeometry(logicalWidth: 50, logicalHeight: 20, scale: 1.6))
        let client = SolidClient(presenter: CanvasPresenter(device: device))
        host.client = client

        #expect(try host.runFrame(), "the first frame runs: the geometry is new to the client")
        #expect(client.geometries == [host.geometry])
        #expect(host.shownFrame?.rung == .readback, "the fake host offers no dma-buf formats")
        #expect(host.shownFrame?.readback?.width == 80 && host.shownFrame?.readback?.height == 32)
        #expect(Self.pixels(host.shownBytes, differingFrom: SolidClient.color(1), width: 80) == 0)

        for _ in 0..<10 { #expect(try !host.runFrame(), "nothing requested, nothing changed: no frame") }
        #expect(client.draws == 1)

        host.requestFrame()
        host.requestFrame()
        #expect(try host.runFrame())
        #expect(try !host.runFrame(), "two requests are one frame")
        #expect(client.draws == 2)
        #expect(Self.pixels(host.shownBytes, differingFrom: SolidClient.color(2), width: 80) == 0)
        #expect(host.stats.shows == 2)
        #expect(instance.validationLog.errorCount == 0)
    }

    @Test("a resize or a scale change reaches the client first, and the next frame has the new size")
    func geometryChanges() throws {
        let (instance, device) = try Self.device()
        let host = FakeCanvasHost(geometry: CanvasGeometry(logicalWidth: 40, logicalHeight: 10, scale: 1))
        let client = SolidClient(presenter: CanvasPresenter(device: device))
        host.client = client
        try host.runFrame()

        host.setGeometry(CanvasGeometry(logicalWidth: 40, logicalHeight: 10, scale: 1.6))
        #expect(try host.runFrame(), "a scale change is a frame without a request")
        #expect(client.geometries.last?.scale == 1.6)
        #expect(host.shownFrame?.readback?.width == 64 && host.shownFrame?.readback?.height == 16)
        #expect(client.presenter.laddersMade == 2)

        host.setGeometry(CanvasGeometry(logicalWidth: 41, logicalHeight: 10, scale: 1.6))
        try host.runFrame()
        #expect(host.shownFrame?.readback?.width == 66, "65.6 → 66")
        #expect(client.presenter.laddersMade == 3)
        host.setGeometry(host.geometry)
        #expect(try !host.runFrame(), "the same geometry again is no change")
        #expect(instance.validationLog.errorCount == 0)
    }

    @Test("dma-buf frames: a ring of three never starves under the host's release policy, partial frames keep the rest, and a failed import steps down to readback")
    func dmabufFrames() throws {
        let (instance, device) = try Self.device()
        // Every modifier the device has but LINEAR, so a failed import steps straight to readback.
        let offered = PresentationRing.deviceModifiers(device.physicalDevice).map(\.modifier)
            .filter { $0 != DRMModifier.linear }.map { DRMFormat(fourcc: .xrgb8888, modifier: $0) }
        let host = FakeCanvasHost(geometry: CanvasGeometry(logicalWidth: 40, logicalHeight: 25, scale: 1.6),
                                  presentationTarget: CanvasPresentationTarget(formats: offered, mainDevice: nil))
        let client = SolidClient(presenter: CanvasPresenter(device: device))
        client.partial = true
        host.client = client
        try host.runFrame()
        guard let rung = host.shownFrame?.rung, rung != .readback else {
            try Test.cancel("\(device.candidate.name) presents through readback only: no dma-buf ring to hold")
        }

        for frame in 2...20 {
            host.requestFrame()
            try host.runFrame()
            #expect(host.shownFrame?.dmabuf != nil, "frame \(frame)")
            #expect(host.heldFrames <= 2)
        }
        #expect(client.presented == 20, "every frame found a free image: \(client.presented)")

        host.failNextImport = "test: the compositor refused the modifier"
        host.requestFrame()
        try host.runFrame()
        #expect(host.stats.importFailures == 1)
        #expect(try host.runFrame(), "the step-down asks for a frame by itself")
        #expect(host.shownFrame?.rung == .readback, "the only rung left: \(String(describing: host.shownFrame?.rung))")
        // The new rung has no previous frame: the whole image is drawn, not just the band.
        let width = host.geometry.pixelWidth
        #expect(Self.pixels(host.shownBytes, differingFrom: SolidClient.color(client.draws), width: width) == 0)

        host.releaseAll()
        #expect(host.heldFrames == 0)
        #expect(instance.validationLog.errorCount == 0)
    }

    @Test("visibility and input reach every subscriber")
    func streams() async {
        let host = FakeCanvasHost(geometry: .empty)
        let visibility = host.visibilityUpdates()
        let input = host.inputEvents()
        host.setVisibility(CanvasVisibility(isMapped: true, isSuspended: true))
        host.setVisibility(CanvasVisibility(isMapped: true, isSuspended: true))
        host.send(.focus(true))
        var visibilityIterator = visibility.makeAsyncIterator()
        var inputIterator = input.makeAsyncIterator()
        #expect(await visibilityIterator.next() == CanvasVisibility(isMapped: true, isSuspended: true))
        #expect(await inputIterator.next() == .focus(true))
    }
}
