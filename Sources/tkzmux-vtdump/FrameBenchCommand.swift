// FrameBenchCommand — the per-frame CPU harness.
//
//   tkzmux-vtdump bench-frame [--cols n --rows n] [--frames n] [--warmup n] [--json out.json]
//                             [<file.tkzrec>]
//
// Everything else in this binary measures a *process* (RSS, threads, snapshot bytes). This measures
// one frame: `FrameBuilder.update` rebuilding every row, and the CPU half of a Metal encode. It
// exists because the app had no frame-level number at all — docs/perf.md measures session switching
// end to end, which bundles the rebuild with `show`, and nothing isolated the text path.
//
// **Why every iteration detaches and re-attaches.** `FrameBuilder` only walks rows libghostty
// reports dirty, so a second `update` over an unchanged screen is a no-op and would measure
// nothing. Re-attaching forces `GHOSTTY_RENDER_STATE_DIRTY_FULL` — the same thing a session switch
// does, and the same thing the `TKZMUX_DEV_SWITCH_BENCH` harness asserts 600 times. So these
// numbers are the full-rebuild cost, which is the case worth optimising: every switch and every
// scroll is a full rebuild.
//
// The headline number is **time**. The block counter alongside it is
// `malloc_zone_statistics(nil,)`'s `blocks_in_use`, which is *net live* blocks, not a cumulative
// allocation count: a temporary that is allocated and freed inside the frame never shows up in it.
// So it does not measure churn — it measures what a frame *retains*, which is the thing that would
// otherwise grow without anyone noticing (an unbounded cache, a leak). Churn shows up in the
// nanoseconds-per-glyph figure instead, which is why that one is printed.

import Darwin
import Foundation
import Metal
import TkzTerminalCore
import TkzTerminalRender

enum FrameBenchCommand {
    struct CommandError: Error, CustomStringConvertible {
        let description: String
    }

    /// Live `blocks_in_use` for the default malloc zone.
    static func mallocBlocks() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.blocks_in_use)
    }

    static func nanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// One measured frame.
    struct Sample {
        var buildNanos: UInt64
        var encodeNanos: UInt64
        var buildBlocks: Int
        var frameBlocks: Int
        var rowsRebuilt: Int
        var glyphCount: Int
        var wasFull: Bool
    }

    // MARK: - Corpus

    /// Fill modes, so the frame time can be attributed rather than guessed at.
    ///
    /// `blank` leaves the screen untouched: libghostty reports short rows, so this is the floor —
    /// the cost of walking the grid with almost no cells in it. `spaces` writes a full screen of
    /// U+0020, every one of which reaches the glyph path and rasterizes to *empty bounds*; the gap
    /// between `spaces` and `blank` is therefore the cost of the blank-cell path alone. `text` is
    /// the realistic mix.
    enum Fill: String {
        case blank, spaces, text
    }

    /// A full screen of spaces — the cell path with no ink at the end of it.
    static func fillSpaces(_ session: TerminalSession, columns: Int, rows: Int) throws {
        var text = ""
        for row in 0..<rows {
            text += String(repeating: " ", count: columns - 1)
            if row < rows - 1 { text += "\r\n" }
        }
        session.write(ptyBytes: Data(text.utf8))
    }

    /// The default screen when no recording is given: representative terminal output — prose, a
    /// path-heavy line, an SGR-styled run, and a CJK/emoji tail so the wide-cell and colour-atlas
    /// paths are both exercised rather than measuring pure ASCII.
    static func fillSynthetic(_ session: TerminalSession, columns: Int, rows: Int) throws {
        let lines = [
            "swift build --configuration release --product tkzmux",
            "[142/199] Compiling TkzTerminalRender FrameBuilder.swift",
            "\u{1B}[32m✓\u{1B}[0m  TkzTerminalCoreTests   \u{1B}[2m41 passed\u{1B}[0m  0.284s",
            "\u{1B}[1;31merror:\u{1B}[0m cannot find 'glyphScratch' in scope",
            "  Sources/TkzTerminalRender/FrameBuilder.swift:291:9",
            "\u{1B}[4;34mhttps://github.com/tkz0/tkzmux/pull/39\u{1B}[0m  merged",
            "日本語のテキストと絵文字 🎉 の混在した行",
            "total 43696  drwxr-xr-x@ 18 thomaskrantz staff 576 Sep 12 16:29 .",
        ]
        var text = ""
        for row in 0..<rows {
            text += lines[row % lines.count]
            if row < rows - 1 { text += "\r\n" }
        }
        session.write(ptyBytes: Data(text.utf8))
    }

    // MARK: - run

    static func run(_ argv: [String]) throws {
        let arguments = Arguments(
            argv, valueFlags: ["cols", "rows", "frames", "warmup", "json", "fill"])
        let columns = Int(arguments.uint16("cols") ?? 125)
        let rowCount = Int(arguments.uint16("rows") ?? 40)
        let frames = arguments.value("frames").flatMap(Int.init) ?? 200
        let warmup = arguments.value("warmup").flatMap(Int.init) ?? 20
        guard columns > 0, rowCount > 0, frames > 0 else {
            throw CommandError(description: "bench-frame: --cols/--rows/--frames must be positive")
        }

        let session = try TerminalSession(
            options: TerminalSessionOptions(cols: UInt16(columns), rows: UInt16(rowCount)))
        let fill = Fill(rawValue: arguments.value("fill") ?? "text") ?? .text
        var corpus = fill.rawValue
        if let path = arguments.positionals.first {
            let reader = try RecordingReader(contentsOf: URL(fileURLWithPath: path))
            try reader.replay(into: session)
            try session.resize(cols: UInt16(columns), rows: UInt16(rowCount))
            corpus = (path as NSString).lastPathComponent
        } else {
            switch fill {
            case .blank: break
            case .spaces: try fillSpaces(session, columns: columns, rows: rowCount)
            case .text: try fillSynthetic(session, columns: columns, rows: rowCount)
            }
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CommandError(description: "bench-frame: no Metal device")
        }
        let renderer = try TerminalRenderer(device: device)
        let surface = TerminalSurface()
        let size = renderer.drawableSize(columns: columns, rows: rowCount)
        guard let texture = renderer.makeOffscreenTexture(width: size.width, height: size.height)
        else {
            throw CommandError(
                description: "bench-frame: could not allocate a \(size.width)×\(size.height) texture")
        }

        // Warm-up runs are thrown away: they populate the glyph atlas and the shaper cache, grow
        // the instance buffers to their steady-state size, and build the Metal pipelines. Measuring
        // those would measure a cold start, which happens once per launch and is not the number
        // this harness is for.
        for _ in 0..<warmup {
            surface.detach()
            try surface.attach(session)
            _ = try renderer.render(surface: surface, to: texture)
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

            // `render` runs `frameBuilder.update` again — by now a no-op, the rows are clean — and
            // then does the part being measured here: flatten, upload, encode.
            let encodeStart = nanos()
            let outcome = try renderer.render(surface: surface, to: texture)
            let encodeEnd = nanos()
            let blocksAfterFrame = mallocBlocks()
            outcome.commandBuffer?.waitUntilCompleted()

            samples.append(Sample(
                buildNanos: buildEnd - buildStart,
                encodeNanos: encodeEnd - encodeStart,
                buildBlocks: blocksAfterBuild - blocksBefore,
                frameBlocks: blocksAfterFrame - blocksBefore,
                rowsRebuilt: update.rowsRebuilt,
                glyphCount: update.glyphCount,
                wasFull: update.dirty == .full))
        }

        report(samples, corpus: corpus, columns: columns, rows: rowCount,
               json: arguments.value("json"))
    }

    // MARK: - Reporting

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    static func stats(_ values: [Double]) -> (min: Double, median: Double, p99: Double, max: Double) {
        let sorted = values.sorted()
        return (sorted.first ?? 0, percentile(sorted, 0.5), percentile(sorted, 0.99), sorted.last ?? 0)
    }

    static func format(_ value: Double) -> String { String(format: "%.3f", value) }

    static func report(_ samples: [Sample], corpus: String, columns: Int, rows: Int, json: String?) {
        let build = stats(samples.map { Double($0.buildNanos) / 1e6 })
        let encode = stats(samples.map { Double($0.encodeNanos) / 1e6 })
        let buildBlocks = samples.map { Double($0.buildBlocks) }
        let frameBlocks = samples.map { Double($0.frameBlocks) }
        let allocBuild = stats(buildBlocks)
        let allocFrame = stats(frameBlocks)
        let fullCount = samples.filter(\.wasFull).count
        let rowsRebuilt = samples.first?.rowsRebuilt ?? 0
        let glyphCount = samples.first?.glyphCount ?? 0
        // The most interpretable figure: a dictionary hit should cost tens of nanoseconds, so this
        // says directly how much the per-cell path is spending above what a lookup has to cost.
        let nsPerGlyph = glyphCount > 0 ? build.median * 1e6 / Double(glyphCount) : 0

        // A run where the rebuild was optimised away would look wonderful and mean nothing, so the
        // two properties that make the numbers real are printed next to them: every frame reported
        // DIRTY_FULL, and every frame rebuilt every row.
        print("""
            bench-frame corpus=\(corpus) grid=\(columns)x\(rows) frames=\(samples.count)
              full=\(fullCount)/\(samples.count) rowsRebuilt=\(rowsRebuilt) glyphs=\(glyphCount)
              build  ms  min=\(format(build.min)) median=\(format(build.median)) \
            p99=\(format(build.p99)) max=\(format(build.max))
              encode ms  min=\(format(encode.min)) median=\(format(encode.median)) \
            p99=\(format(encode.p99)) max=\(format(encode.max))
              per glyph  \(format(nsPerGlyph)) ns   (build median / glyphs)
              net live blocks/frame  build median=\(Int(allocBuild.median)) max=\(Int(allocBuild.max))  \
            frame median=\(Int(allocFrame.median)) max=\(Int(allocFrame.max))
            """)
        if fullCount != samples.count {
            print("  WARNING: \(samples.count - fullCount) frame(s) were not DIRTY_FULL — "
                + "the re-attach is not forcing a full rebuild and these numbers are not comparable")
        }

        guard let json else { return }
        let record: [String: Any] = [
            "corpus": corpus, "columns": columns, "rows": rows, "frames": samples.count,
            "full": fullCount, "rowsRebuilt": rowsRebuilt, "glyphCount": glyphCount,
            "buildMs": ["min": build.min, "median": build.median, "p99": build.p99, "max": build.max],
            "encodeMs": ["min": encode.min, "median": encode.median, "p99": encode.p99, "max": encode.max],
            "nsPerGlyph": nsPerGlyph,
            "netLiveBlocksBuild": ["median": allocBuild.median, "max": allocBuild.max],
            "netLiveBlocksFrame": ["median": allocFrame.median, "max": allocFrame.max],
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: json))
            print("  wrote \(json)")
        }
    }
}
