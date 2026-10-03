// PresentationDamageTests — buffer age, damage and the fallback ladder (WOR-313 S5b).
//
// The region algebra and the rung plan are pure. The GPU tests draw a window of four terminal
// panes through a `PresentationLadder` the way the frame driver will (every pane through the
// renderer's acquire seam, then one present), and check every presented frame against a full
// redraw of the same panes, byte for byte: a frame read back by the compositor stand-in
// (`DmabufReader`) on a dma-buf rung, the frame's own bytes on the readback rung. They run on
// every exporting device (RADV and NVIDIA on a desktop, lavapipe in CI) and on the readback rung
// of a headless device, which every Vulkan driver has, so nothing here depends on export support
// to run at all. Every test asserts the validation layer counted no error.

import CVulkan
import Testing
import TkzCore
import TkzRenderCore
import TkzTerminalCore
@testable import TkzRenderVK

// MARK: - Pure: regions

@Suite("damage regions")
struct DamageRegionTests {

    @Test("a rect minus another is up to four disjoint bands, and nothing of the other")
    func rectSubtraction() {
        let rect = PixelRect(x: 10, y: 10, width: 100, height: 50)
        let hole = PixelRect(x: 40, y: 20, width: 10, height: 10)
        let pieces = rect.subtracting(hole)
        #expect(pieces.count == 4)
        #expect(pieces.reduce(0) { $0 + $1.area } == 100 * 50 - 10 * 10)
        #expect(pieces.allSatisfy { $0.intersection(hole) == nil })
        #expect(DamageRegion(pieces).area == 100 * 50 - 10 * 10, "the bands are disjoint")

        #expect(rect.subtracting(PixelRect(x: 500, y: 0, width: 5, height: 5)) == [rect])
        #expect(rect.subtracting(PixelRect(x: 0, y: 0, width: 1000, height: 1000)).isEmpty)
        // Touching edges do not overlap.
        #expect(rect.intersection(PixelRect(x: 110, y: 10, width: 5, height: 5)) == nil)
    }

    @Test("a union counts every pixel once, subtraction is exact, and only simplify() over-approximates")
    func regions() {
        var region = DamageRegion(PixelRect(x: 0, y: 0, width: 10, height: 10))
        region.formUnion(PixelRect(x: 5, y: 5, width: 10, height: 10))
        region.formUnion(PixelRect(x: 0, y: 0, width: 10, height: 10))
        #expect(region.area == 175)
        #expect(region.bounds == PixelRect(x: 0, y: 0, width: 15, height: 15))
        #expect(region.subtracting(DamageRegion(PixelRect(x: 0, y: 0, width: 15, height: 15))).isEmpty)
        #expect(region.subtracting(DamageRegion(PixelRect(x: 0, y: 0, width: 10, height: 10))).area == 75)
        #expect(DamageRegion(PixelRect(x: 3, y: 3, width: 0, height: 9)).isEmpty)

        // Many small rects collapse to their bounds, a superset.
        var many = DamageRegion((0..<(DamageRegion.maxRects + 1)).map { PixelRect(x: $0 * 4, y: 0, width: 2, height: 2) })
        let exact = many.area
        many.simplify()
        #expect(many.rects == [PixelRect(x: 0, y: 0, width: DamageRegion.maxRects * 4 + 2, height: 2)])
        #expect(many.area > exact)
        var few = DamageRegion([PixelRect(x: 0, y: 0, width: 2, height: 2), PixelRect(x: 8, y: 0, width: 2, height: 2)])
        few.simplify()
        #expect(few.rects.count == 2, "a short list is left exact")
    }
}

// MARK: - Pure: the rungs

@Suite("presentation fallback ladder plan")
struct LadderPlanTests {
    /// The reference machine's XRGB8888 feedback (WOR-301): four tiled modifiers, LINEAR, INVALID.
    private static let gtk = [0x0200_0000_0056_BB03, 0x0200_0000_0040_1B03, 0x0200_0000_0040_1603, 0x0200_0000_0000_0901,
                              DRMModifier.linear, DRMModifier.invalid].map { DRMFormat(fourcc: .xrgb8888, modifier: $0) }

    @Test("every rung the consumer offers, best first, readback always last")
    func fullLadder() {
        #expect(PresentationLadder.rungs(from: .negotiatedModifier, offered: Self.gtk, fourcc: .xrgb8888, failedModifiers: [])
            == [.negotiatedModifier, .linear, .implicit, .readback])
        #expect(PresentationLadder.rungs(from: .linear, offered: Self.gtk, fourcc: .xrgb8888, failedModifiers: [])
            == [.linear, .implicit, .readback])
        #expect(PresentationLadder.rungs(from: .readback, offered: Self.gtk, fourcc: .xrgb8888, failedModifiers: []) == [.readback])
    }

    @Test("a rung whose modifier failed to import, or that was not offered for the fourcc, is skipped")
    func skips() {
        // Lavapipe's only modifier is LINEAR: when the negotiated ring (LINEAR) fails, LINEAR is not
        // retried.
        #expect(PresentationLadder.rungs(from: .linear, offered: Self.gtk, fourcc: .xrgb8888, failedModifiers: [DRMModifier.linear])
            == [.implicit, .readback])
        #expect(PresentationLadder.rungs(from: .linear, offered: Self.gtk, fourcc: .argb8888, failedModifiers: []) == [.readback])
        let implicitOnly = [DRMFormat(fourcc: .xrgb8888, modifier: DRMModifier.invalid)]
        #expect(PresentationLadder.rungs(from: .negotiatedModifier, offered: implicitOnly, fourcc: .xrgb8888, failedModifiers: [])
            == [.implicit, .readback])
        #expect(PresentationLadder.rungs(from: .negotiatedModifier, offered: [], fourcc: .xrgb8888, failedModifiers: []) == [.readback])
    }
}

// MARK: - GPU fixture

/// Four terminal panes tiled 2×2 with a gutter no pane covers, drawn into one window through a
/// `PresentationLadder` the way the frame driver does it.
private final class PaneWindow {
    static let gutter = 3
    static let black = BGRA8(b: 0, g: 0, r: 0, a: 0xFF)

    let device: VulkanDevice
    let renderer: VulkanTerminalRenderer
    let panes: [(session: TerminalSession, surface: TerminalSurface)]
    let rects: [PixelRect]
    let width: Int
    let height: Int
    let ladder: PresentationLadder
    let reader: DmabufReader?
    let name: String

    init(device: VulkanDevice, offered: [DRMFormat], startingAt start: PresentationRung = .negotiatedModifier,
         reader: DmabufReader?) throws {
        self.device = device
        self.reader = reader
        name = "\(device.candidate.name) (\(device.mode))"
        renderer = try VulkanTerminalRenderer(device: device, glyphCache: try RendererFonts.cache())
        panes = try (0..<4).map { index in
            let session = try TerminalSession(options: TerminalSessionOptions(cols: 24, rows: 5, theme: .default))
            session.write(ptyText: "pane \(index)\r\n\u{1b}[1;31mbold red\u{1b}[0m \u{1b}[4munder\u{1b}[0m \u{1b}[48;5;18mblue\u{1b}[0m\r\n")
            let surface = TerminalSurface()
            try surface.attach(session)
            return (session, surface)
        }
        let pane = renderer.drawableSize(columns: 24, rows: 5)
        rects = (0..<4).map {
            PixelRect(x: ($0 % 2) * (pane.width + Self.gutter), y: ($0 / 2) * (pane.height + Self.gutter), width: pane.width, height: pane.height)
        }
        width = pane.width * 2 + Self.gutter
        height = pane.height * 2 + Self.gutter
        ladder = try PresentationLadder(device: device, width: UInt32(width), height: UInt32(height), offered: offered, startingAt: start)
    }

    /// One tick: every pane through the acquire seam (forced while the ladder needs a full
    /// redraw), then the present. Returns the frame (nil when every pane was clean) and the
    /// instance bytes each pane wrote.
    func tick() throws -> (frame: LadderFrame?, bytesPerPane: [Int]) {
        let force = ladder.needsFullRedraw
        var bytesPerPane: [Int] = []
        for (pane, rect) in zip(panes, rects) {
            let before = renderer.stats.instanceBytesWritten
            try renderer.render(surface: pane.surface, targetWidth: width, targetHeight: height, in: rect, forceEncode: force) {
                try self.ladder.acquire()
            }
            bytesPerPane.append(renderer.stats.instanceBytesWritten - before)
        }
        return (try ladder.present(), bytesPerPane)
    }

    /// The frame's pixels as the consumer gets them.
    func bytes(_ frame: LadderFrame) throws -> [UInt8] {
        switch frame.content {
        case .dmabuf(let presented): try #require(reader).read(presented)
        case .readback(let readback): readback.bytes
        }
    }

    /// The reference: every pane drawn again, forced, into a fresh target cleared to black.
    func fullRedraw() throws -> [UInt8] {
        let target = try OffscreenTarget(device: device, width: UInt32(width), height: UInt32(height))
        _ = try target.clear(to: Self.black)
        for (pane, rect) in zip(panes, rects) {
            try renderer.render(surface: pane.surface, targetWidth: width, targetHeight: height, in: rect, forceEncode: true) { target }
        }
        return try target.bgraBytes()
    }

    func expectMatchesFullRedraw(_ frame: LadderFrame, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let difference = difference(try bytes(frame), try fullRedraw(), width: width)
        #expect(difference == nil, "\(name) \(label): \(difference ?? "")", sourceLocation: sourceLocation)
    }

    func expectNoValidationErrors(sourceLocation: SourceLocation = #_sourceLocation) {
        VulkanTestDevice.expectNoValidationErrors(device, sourceLocation: sourceLocation)
    }
}

/// A window per device the tests can present on: the dma-buf ring of every exporting device,
/// and the readback rung of the headless device, which needs no export support.
private func windows() throws -> [PaneWindow] {
    let exporting = try ExportingGPU.available()
    if exporting.isEmpty { print("PresentationDamageTests: no exporting device; the readback rung only") }
    return try exporting.map { gpu in
        try PaneWindow(device: gpu.device, offered: gpu.offered(fallbacks: true), reader: try DmabufReader(gpu))
    } + [PaneWindow(device: try VulkanTestDevice.make(), offered: [], reader: nil)]
}

// MARK: - GPU: damage and age

@Suite("Vulkan presentation: buffer age, damage and the fallback ladder", .serialized,
       .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
struct PresentationDamageTests {

    /// The Mac's test of the same name, for the window: an unchanged frame acquires no ring image.
    @Test("the presentation path acquires an image for a real frame and none for an unchanged one")
    func layerPathHonoursTheIdleGuarantee() throws {
        for window in try windows() {
            let first = try window.tick()
            #expect(first.frame != nil)
            #expect(window.renderer.stats.drawablesAcquired == 4, "one image, handed to each pane")
            let acquires = window.ladder.ring?.stats.acquires
            if let ring = window.ladder.ring { #expect(ring.stats.acquires == 1) }
            if let frame = first.frame { window.ladder.release(frame) }

            window.renderer.resetStats()
            let second = try window.tick()
            #expect(second.frame == nil, "\(window.name): nothing to present")
            #expect(window.renderer.stats.drawableRequests == 0, "the skip path must return before an image is ever asked for")
            #expect(window.renderer.stats.drawablesAcquired == 0)
            #expect(window.renderer.stats.instanceBytesWritten == 0)
            #expect(window.ladder.ring?.stats.acquires == acquires, "no ring image taken")
            window.expectNoValidationErrors()
        }
    }

    /// The whole point of buffer age: the image being drawn is not the previous frame, yet one
    /// dirty pane of four encodes one pane. The consumer holds and releases frames in a pattern
    /// that walks the images through ages 0 (fresh), 3, 2, 1 and 6.
    @Test("dirtying one pane of four encodes that pane only, copies the rest, and matches a full redraw byte for byte")
    func onePaneOfFourIsCopiedNotReencoded() throws {
        for window in try windows() {
            let full = PixelRect(width: window.width, height: window.height)

            // Frame 1: nothing presented yet, so every pane is drawn.
            #expect(window.ladder.needsFullRedraw)
            let first = try window.tick()
            let f1 = try #require(first.frame)
            #expect(first.bytesPerPane.allSatisfy { $0 > 0 })
            #expect(f1.damage == [full])
            #expect(!window.ladder.needsFullRedraw)
            try window.expectMatchesFullRedraw(f1, "frame 1")

            // (dirty panes, frames released after presenting, expected age on a ring)
            var held: [Int: LadderFrame] = [1: f1]
            let script: [(dirty: [Int], release: [Int], age: Int)] = [
                ([1], [1], 0),       // 2: a fresh image; everything but pane 1 copied
                ([2], [2], 0),       // 3: the last fresh image
                ([3], [], 3),        // 4: image 0 again; frame 3 stays held
                ([0], [4], 3),       // 5
                ([1], [5], 2),       // 6: image 2 is held, so image 0 comes round early
                ([2], [7], 2),       // 7: … and the consumer drops frame 7 at once
                ([3], [3, 6, 8], 1), // 8: images 2 and 0 held: the latest frame's own image, nothing to copy
                ([0, 2], [], 6),     // 10 (9 is idle): image 2 last held frame 3
            ]
            var number = 1
            for step in script {
                number += 1
                if number == 9 {
                    // An idle tick between frames 8 and 10.
                    let idle = try window.tick()
                    #expect(idle.frame == nil && idle.bytesPerPane == [0, 0, 0, 0])
                    number += 1
                }
                for pane in step.dirty { window.panes[pane].session.write(ptyText: "x\(number)") }
                let copiedBefore = window.ladder.ring?.stats.pixelsCopied ?? 0
                let accumulated = window.ladder.ring?.images.map(\.accumulatedDamage) ?? []
                let outcome = try window.tick()
                let frame = try #require(outcome.frame, "\(window.name) frame \(number)")

                for pane in 0..<4 {
                    if step.dirty.contains(pane) {
                        #expect(outcome.bytesPerPane[pane] > 0, "\(window.name) frame \(number): pane \(pane) redrawn")
                    } else {
                        #expect(outcome.bytesPerPane[pane] == 0, "\(window.name) frame \(number): clean pane \(pane) wrote instance bytes")
                    }
                }
                #expect(Set(frame.damage) == Set(step.dirty.map { window.rects[$0] }), "\(window.name) frame \(number)")
                try window.expectMatchesFullRedraw(frame, "frame \(number)")

                if let presented = frame.dmabuf, let ring = window.ladder.ring {
                    #expect(presented.age == step.age, "\(window.name) frame \(number): age")
                    // What was copied is exactly what the image lacked and the frame did not draw.
                    let drawn = DamageRegion(step.dirty.map { window.rects[$0] })
                    let lacked = accumulated[presented.slot]
                    #expect(step.age != 1 || lacked.isEmpty, "the latest frame's image lacks nothing")
                    #expect(step.age != 0 || lacked == DamageRegion(full), "a fresh image lacks everything")
                    #expect(ring.stats.pixelsCopied - copiedBefore == lacked.subtracting(drawn).area,
                            "\(window.name) frame \(number): copied")
                }
                held[number] = frame
                for released in step.release {
                    if let frame = held.removeValue(forKey: released) { window.ladder.release(frame) }
                }
            }
            if let ring = window.ladder.ring {
                #expect(ring.stats.firstFrameClears == 1)
                #expect(ring.stats.starved == 0)
                print("PresentationDamageTests: \(window.name): \(ring.stats)")
            }
            window.expectNoValidationErrors()
        }
    }

    /// The frames above are each read back before the next, and a host wait orders everything;
    /// here nothing waits between presents, so only the ring's own synchronization (the timeline
    /// wait before a copy, the consumer-fence wait at take-back) orders the copies, and
    /// synchronization validation sees every hazard it would miss otherwise.
    @Test("back-to-back frames with copies and no wait between them stay exact and hazard-free")
    func framesBackToBack() throws {
        for window in try windows() {
            var held: [LadderFrame] = []
            for number in 0..<24 {
                let dirty = (number * 7 + 3) % 4
                window.panes[dirty].session.write(ptyText: "\(number) ")
                let frame = try #require(try window.tick().frame)
                held.append(frame)
                // The consumer keeps the latest one or two frames, as a compositor does.
                while held.count > (number % 3 == 0 ? 2 : 1) { window.ladder.release(held.removeFirst()) }
            }
            try window.expectMatchesFullRedraw(try #require(held.last), "after 24 frames")
            if let ring = window.ladder.ring {
                #expect(ring.stats.starved == 0 && ring.stats.regionCopies >= 20, "\(window.name): \(ring.stats)")
            }
            held.forEach(window.ladder.release)
            window.expectNoValidationErrors()
        }
    }

    /// The forced failure: the consumer rejects every dma-buf it is given, so the ladder walks all
    /// the way down, each rung's first frame a full redraw equal to the first rung's dma-buf.
    @Test("a forced import failure steps down the ladder, and the readback bytes equal the dma-buf render")
    func forcedImportFailureStepsDown() throws {
        for gpu in try ExportingGPU.all() {
            let window = try PaneWindow(device: gpu.device, offered: gpu.offered(fallbacks: true), reader: try DmabufReader(gpu))
            #expect(window.ladder.rung == .negotiatedModifier)
            var visited = [window.ladder.rung]
            let first = try #require(try window.tick().frame)
            try window.expectMatchesFullRedraw(first, "negotiated rung")

            // A frame the consumer still holds keeps its ring alive past the step down.
            window.panes[0].session.write(ptyText: "held")
            let held = try #require(try window.tick().frame)
            window.ladder.release(first)
            window.panes[0].session.write(ptyText: "\u{1b}[2K\r")
            let failing = try #require(try window.tick().frame)
            // What the negotiated rung rendered; the panes do not change below, so every rung's
            // first frame must be these bytes, the readback rung's included.
            let dmabufBytes = try window.bytes(failing)
            let negotiated = try #require(window.ladder.ring).modifier

            try window.ladder.importFailed(failing, reason: "forced by the test")
            #expect(window.ladder.failedModifiers == [negotiated])
            #expect(window.ladder.retired.count == 1, "the held frame's ring waits for its release")
            window.ladder.release(held)
            #expect(window.ladder.retired.isEmpty)
            visited.append(window.ladder.rung)
            var current = try #require(try window.tick().frame)
            let expected = try window.fullRedraw()
            #expect(difference(dmabufBytes, expected, width: window.width) == nil, "\(gpu.name): negotiated rung")

            while true {
                #expect(current.rung == window.ladder.rung && current.generation == window.ladder.generation)
                #expect(current.damage == [PixelRect(width: window.width, height: window.height)], "each rung starts with a full frame")
                let bytes = try window.bytes(current)
                #expect(difference(bytes, dmabufBytes, width: window.width) == nil, "\(gpu.name) \(current.rung) vs the dma-buf render")
                guard window.ladder.rung != .readback else { break }
                try window.ladder.importFailed(current, reason: "forced by the test")
                #expect(window.ladder.needsFullRedraw)
                visited.append(window.ladder.rung)
                current = try #require(try window.tick().frame)
            }
            print("PresentationDamageTests: \(gpu.name): rungs \(visited.map(\.description)), negotiated \(DRMModifier.hex(negotiated))")
            #expect(visited == visited.sorted() && Set(visited).count == visited.count, "strictly down")
            #expect(visited.last == .readback)
            // LINEAR and implicit are tried wherever the device can make them (NVIDIA reports
            // neither for a B8G8R8A8 render target; RADV has no implicit-modifier export).
            let linear = PresentationRing.deviceModifiers(gpu.physical)
                .contains { $0.modifier == DRMModifier.linear && $0.fits(width: UInt32(window.width), height: UInt32(window.height)) }
            #expect(visited.contains(.linear) == (linear && negotiated != DRMModifier.linear))
            #expect(visited.contains(.implicit)
                == PresentationRing.linearExportable(gpu.physical, width: UInt32(window.width), height: UInt32(window.height)))

            // The readback rung keeps the damage path: one dirty pane, one pane encoded, the bytes
            // still a full redraw.
            window.panes[2].session.write(ptyText: "\u{1b}[2J\u{1b}[Hafter")
            let after = try window.tick()
            #expect(after.bytesPerPane[0] == 0 && after.bytesPerPane[1] == 0 && after.bytesPerPane[3] == 0)
            let last = try #require(after.frame)
            #expect(last.damage == [window.rects[2]])
            try window.expectMatchesFullRedraw(last, "readback, one dirty pane")
            window.expectNoValidationErrors()
        }
    }

    @Test("a device that cannot export settles on the readback rung at once")
    func headlessPresentsThroughReadback() throws {
        let device = try VulkanTestDevice.make()
        let offered = [DRMModifier.linear, DRMModifier.invalid].map { DRMFormat(fourcc: .xrgb8888, modifier: $0) }
        let ladder = try PresentationLadder(device: device, width: 64, height: 32, offered: offered)
        #expect(ladder.rung == .readback && ladder.ring == nil && ladder.generation == 1)
        #expect(ladder.needsFullRedraw)
        #expect(try ladder.present() == nil, "nothing acquired, nothing presented")

        let target = try #require(try ladder.acquire())
        #expect(try ladder.acquire() === target, "every pane of a frame gets the same image")
        let frame = try #require(try ladder.present())
        let bytes = try #require(frame.readback).bytes
        #expect(bytes.count == 64 * 32 * 4)
        #expect(stride(from: 0, to: bytes.count, by: 4).allSatisfy { bytes[$0..<$0 + 4].elementsEqual([0, 0, 0, 0xFF]) },
                "nothing drawn on the first frame: black")
        #expect(!ladder.needsFullRedraw)
        VulkanTestDevice.expectNoValidationErrors(device)
    }
}
