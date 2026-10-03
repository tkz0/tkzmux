// FrameBenchVulkan — `bench-frame` on Linux, through the Vulkan renderer (WOR-313 S6).
//
//   tkzmux-vtdump bench-frame [--cols n --rows n] [--size <w>x<h>] [--scale s] [--frames n]
//                             [--warmup n] [--fill blank|spaces|text] [--fonts system|parity]
//                             [--validation] [--json out.json] [<file.tkzrec>]
//
// FrameBenchCommand.swift's harness, measured the same way (every frame re-attaches, so every frame
// is a DIRTY_FULL rebuild), with the Vulkan renderer's CPU half as `encode`: flatten, the instance
// writes, recording and `vkQueueSubmit2`. Two additions:
//
//   - the GPU time of every measured frame, from a timestamp-query pair around everything the
//     frame records (`GPUFrameTimer`: the atlas upload, if any, and the four passes). Each frame is
//     waited for before the next, as on the Mac, so the pair is never shared by two frames.
//   - `--size <w>x<h>`: the target size, for frames larger than the grid (a 7680×2160 window). The
//     grid then defaults to the cells that fit and the rest is letterbox, drawn by the background
//     pass. Without it, the target is the grid's size and the grid defaults to 125×40, as on the Mac.
//
// The device is the one the app would select headless (TKZMUX_GPU, loader order). Validation is off
// unless `--validation`, so it does not time the layer.

#if os(Linux)
import Foundation
import TkzRenderCore
import TkzRenderVK

extension FrameBenchCommand {
    static func run(_ argv: [String]) throws {
        let arguments = Arguments(
            argv, valueFlags: ["cols", "rows", "frames", "warmup", "json", "fill", "size", "scale", "fonts"])
        var scale = 2.0
        if let text = arguments.value("scale") {
            guard let value = Double(text), value.isFinite, value > 0 else {
                throw CommandError(description: "bench-frame: --scale must be a positive number")
            }
            scale = value
        }
        var size: (width: Int, height: Int)?
        if let text = arguments.value("size") {
            let parts = text.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
                throw CommandError(description: "bench-frame: --size wants <w>x<h>")
            }
            size = (parts[0], parts[1])
        }
        let frames = arguments.value("frames").flatMap(Int.init) ?? 200
        let warmup = arguments.value("warmup").flatMap(Int.init) ?? 20

        let setup = try VulkanFrameSetup(
            scale: scale, fonts: VulkanFrameSetup.parseFonts(arguments, command: "bench-frame"),
            validation: arguments.has("validation") ? .ifAvailable : .off)
        let renderer = setup.renderer
        let metrics = renderer.glyphCache.metrics
        let columns = Int(arguments.uint16("cols") ?? UInt16(clamping: size.map { $0.width / metrics.width } ?? 125))
        let rowCount = Int(arguments.uint16("rows") ?? UInt16(clamping: size.map { $0.height / metrics.height } ?? 40))
        guard columns > 0, rowCount > 0, frames > 0 else {
            throw CommandError(description: "bench-frame: --cols/--rows/--frames must be positive")
        }
        let targetSize = size ?? renderer.drawableSize(columns: columns, rows: rowCount)

        let (session, corpus) = try makeSession(arguments, columns: columns, rows: rowCount)
        let surface = TerminalSurface()
        let target = try OffscreenTarget(device: setup.device, width: UInt32(targetSize.width), height: UInt32(targetSize.height))
        do {
            renderer.frameTimer = try GPUFrameTimer(device: setup.device)
        } catch {
            print("  no GPU time: \(error)")
        }

        // Warm-up, as on the Mac: the atlases, the shaper cache, the ring's buffers at their
        // steady-state size, and the pipelines' first use.
        for _ in 0..<warmup {
            surface.detach()
            try surface.attach(session)
            try renderer.render(surface: surface, to: target).frame?.waitUntilCompleted()
            _ = try renderer.frameTimer?.elapsed()
        }

        var samples: [Sample] = []
        samples.reserveCapacity(frames)
        for _ in 0..<frames {
            surface.detach()
            try surface.attach(session)

            let blocksBefore = mallocBlocks()
            let buildStart = nanos()
            let update = try renderer.frameBuilder.update(surface)
            let buildEnd = nanos()
            let blocksAfterBuild = mallocBlocks()

            // `render` runs `frameBuilder.update` again (a no-op now), then the measured part:
            // flatten, the instance writes, recording and submission.
            let encodeStart = nanos()
            let outcome = try renderer.render(surface: surface, to: target)
            let encodeEnd = nanos()
            let blocksAfterFrame = mallocBlocks()
            try outcome.frame?.waitUntilCompleted()

            samples.append(Sample(
                buildNanos: buildEnd - buildStart,
                encodeNanos: encodeEnd - encodeStart,
                buildBlocks: blocksAfterBuild - blocksBefore,
                frameBlocks: blocksAfterFrame - blocksBefore,
                rowsRebuilt: update.rowsRebuilt,
                glyphCount: update.glyphCount,
                wasFull: update.dirty == .full,
                gpuNanos: try renderer.frameTimer?.elapsed()))
        }
        surface.detach()
        renderer.frameTimer = nil

        report(samples, corpus: corpus, columns: columns, rows: rowCount, json: arguments.value("json"),
               target: targetSize, device: setup.deviceDescription)
        setup.checkValidation("bench-frame")
    }
}
#endif
