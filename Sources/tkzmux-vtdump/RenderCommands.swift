// RenderCommands — the `render` and `atlas` subcommands of tkzmux-vtdump (M1.5).
//
//   tkzmux-vtdump render --out <out.png> [--cols n --rows n] [--scale s] <file.tkzrec>
//       Replays a recording into a headless `TerminalSession`, attaches a `TerminalSurface` and
//       renders the final screen through the real Metal pipelines into an offscreen texture. The
//       PNG this writes is the same image the app would put on screen, which is what makes the
//       golden-frame tests meaningful. `--scale` is the backing scale the font set is built at
//       (default 2, the Retina factor the goldens use; 1.6 is the Linux parity scale).
//
//   tkzmux-vtdump atlas --out <prefix> [--point-size n --scale n --sample "…" --thicken 0|1 --json]
//       Rasterizes a sample string (printable ASCII plus a CJK/emoji tail by default) and dumps
//       both atlases: `<prefix>-grayscale.png` and `<prefix>-color.png`. Runs with no Metal device
//       at all — `GlyphAtlas` (TkzRenderCore) is a CPU staging buffer; only the renderer uploads it.
//       `--json` also writes `<prefix>.json`, an `AtlasDump` (TkzRenderCore) with every glyph's
//       slot, bearings, `appliedScale`, ink box and CoreText face: the WOR-312 S1 parity reference
//       (FontDumpCommands.swift). The PNGs are the same with or without it.
//
// macOS only: on Linux, VulkanRenderCommands.swift draws `render` through Vulkan and stands in for
// `atlas` (WOR-313 S6). Each file also gives `framedump` its platform's font stack (WOR-322 S3).

#if canImport(Metal)
import Foundation
import Metal
import TkzCore
import TkzRenderCore
import TkzTerminalCore
import TkzTerminalRender

extension FrameDumpCommand {
    /// `framedump`'s font stack on the Mac: the glyph cache `TerminalRenderer(device:scale:)` builds,
    /// the theme's terminal font through CoreText.
    static func fontGlyphSource(scale: Double, fonts: String?) throws
        -> (source: any GlyphSource, origin: FrameDump.Source) {
        if fonts != nil { fail("tkzmux-vtdump framedump: --fonts is Linux only", code: 2) }
        let theme = Theme.default
        let fontSet = FontSet(family: theme.fontMono.family, fallback: theme.fontMono.fallback,
                              pointSize: CGFloat(theme.fontMono.terminal), scale: CGFloat(scale))
        return (CoreTextGlyphSource(fontSet: fontSet, thicken: theme.fontMono.thicken),
                FrameDump.Source(platform: "macos", glyphSource: "CoreText"))
    }
}

public enum RenderCommands {
    /// Anything that stops a subcommand before it can write its output.
    struct CommandError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Command lines

    /// `render`'s arguments, parsed here so that main.swift has nothing Metal-specific to say.
    static func runRender(_ argv: [String]) throws {
        let arguments = Arguments(argv, valueFlags: ["out", "cols", "rows", "scale"])
        guard let input = arguments.positionals.first else {
            fail("tkzmux-vtdump render: missing <file.tkzrec>", code: 2)
        }
        guard let out = arguments.value("out") else { fail("tkzmux-vtdump render: --out is required", code: 2) }
        var scale = 2.0
        if let text = arguments.value("scale") {
            guard let value = Double(text), value.isFinite, value > 0 else {
                fail("tkzmux-vtdump render: --scale must be a positive number", code: 2)
            }
            scale = value
        }
        try render(
            recording: URL(fileURLWithPath: input),
            png: URL(fileURLWithPath: out),
            cols: arguments.uint16("cols"),
            rows: arguments.uint16("rows"),
            scale: scale
        )
    }

    static func runAtlas(_ argv: [String]) throws {
        let arguments = Arguments(argv, valueFlags: ["out", "point-size", "scale", "sample", "thicken"])
        guard let out = arguments.value("out") else { fail("tkzmux-vtdump atlas: --out is required", code: 2) }
        try atlas(
            pngPrefix: URL(fileURLWithPath: out),
            pointSize: Double(arguments.value("point-size") ?? "") ?? 12.5,
            scale: Double(arguments.value("scale") ?? "") ?? 2,
            sample: arguments.value("sample"),
            thicken: arguments.value("thicken") != "0",
            json: arguments.has("json")
        )
    }

    // MARK: - render

    /// `tkzmux-vtdump render --out <out.png> <file.tkzrec>` — replay, then render the final screen
    /// offscreen and write it as a PNG. `scale` is the backing scale of the renderer's default font
    /// set; 2 is exactly what `TerminalRenderer(device:)` built before the flag existed.
    public static func render(recording: URL, png out: URL, cols: UInt16?, rows: UInt16?,
                              scale: Double = 2) throws {
        let reader = try RecordingReader(contentsOf: recording)
        let columns = cols ?? reader.header.cols
        let rowCount = rows ?? reader.header.rows

        let session = try TerminalSession(
            options: TerminalSessionOptions(cols: columns, rows: rowCount))
        try reader.replay(into: session)
        if cols != nil || rows != nil {
            try session.resize(cols: columns, rows: rowCount)
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CommandError(description: "no Metal device (render needs a GPU)")
        }
        let renderer = try TerminalRenderer(device: device, scale: CGFloat(scale))
        let surface = TerminalSurface()
        try surface.attach(session)

        let size = renderer.drawableSize(columns: Int(columns), rows: Int(rowCount))
        guard let texture = renderer.makeOffscreenTexture(width: size.width, height: size.height) else {
            throw CommandError(description: "could not allocate a \(size.width)×\(size.height) texture")
        }
        let outcome = try renderer.render(surface: surface, to: texture)
        outcome.commandBuffer?.waitUntilCompleted()
        guard outcome.didEncode else {
            throw CommandError(description: "nothing to render (the recording left a blank screen)")
        }
        guard let data = TerminalRenderer.pngData(from: texture) else {
            throw CommandError(description: "PNG encoding failed")
        }
        try data.write(to: out, options: .atomic)

        surface.detach()
        FileHandle.standardError.write(Data("""
            rendered \(size.width)×\(size.height) px \
            (\(columns)×\(rowCount) cells, \(outcome.glyphCount) glyphs, \
            \(outcome.rectCount) rects) → \(out.path)\n
            """.utf8))
    }

    // MARK: - atlas

    /// `tkzmux-vtdump atlas --out <prefix>` — dump both glyph atlases as PNGs, and with `json` the
    /// `AtlasDump` that describes them.
    public static func atlas(pngPrefix: URL, pointSize: Double, scale: Double, sample: String?,
                             thicken: Bool = true, json: Bool = false) throws {
        let fontSet = FontSet(pointSize: pointSize, scale: scale)
        // The recorder only watches the source the cache would have built itself
        // (`GlyphCache(fontSet:thicken:)`), so the pages are the same either way.
        let recorder = AtlasRecorder(base: CoreTextGlyphSource(fontSet: fontSet, thicken: thicken))
        // Small atlases so the dump is legible rather than a postage stamp in a 2048² field.
        let cache = GlyphCache(source: recorder, grayscaleInitialSize: 512, colorInitialSize: 256)

        var glyphs: [AtlasDump.Glyph] = []
        let text = sample ?? defaultSample
        for character in text where !character.isNewline {
            for style in FontStyle.allCases {
                recorder.drawn = nil
                guard let placed = cache.glyph(for: character, style: style) else { continue }
                // Only a miss draws; a hit (a sprite in its second style, say) is already listed.
                if let entry = recorder.entry(for: Array(character.unicodeScalars), style: style, placed: placed) {
                    glyphs.append(entry)
                }
            }
        }
        if json, cache.grayscale.rebuildCount > 0 || cache.color.rebuildCount > 0 {
            // A rebuild drops earlier glyphs' pixels, and the slots listed for them with it.
            throw CommandError(description: "the sample overflowed a 2048² atlas; dump a shorter --sample")
        }

        let directory = pngPrefix.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let base = pngPrefix.lastPathComponent
        for (kind, suffix) in [(AtlasKind.grayscale, "grayscale"), (AtlasKind.color, "color")] {
            let atlas = cache.atlas(for: kind)
            guard let data = atlas.pngData() else {
                throw CommandError(description: "could not encode the \(suffix) atlas")
            }
            let url = directory.appendingPathComponent("\(base)-\(suffix).png")
            try data.write(to: url, options: .atomic)
            FileHandle.standardError.write(Data(
                "\(suffix): \(atlas.size)×\(atlas.size), \(cache.cachedCount) cached glyphs → \(url.path)\n".utf8))
        }
        guard json else { return }

        let dump = AtlasDump(
            platform: "macos", pointSize: pointSize, scale: scale, pixelSize: Double(fontSet.pixelSize),
            thicken: thicken, padding: recorder.padding, metrics: recorder.metrics,
            environment: MacFontEnvironment.current,
            pages: [
                AtlasDump.Page(kind: "grayscale", size: cache.grayscale.size, file: "\(base)-grayscale.png"),
                AtlasDump.Page(kind: "color", size: cache.color.size, file: "\(base)-color.png"),
            ],
            glyphs: glyphs)
        let url = directory.appendingPathComponent("\(base).json")
        try dump.encoded().write(to: url, options: .atomic)
        FileHandle.standardError.write(Data("json: \(glyphs.count) glyphs → \(url.path)\n".utf8))
    }

    /// Printable ASCII plus the interesting tail: box drawing, a CJK pair and two emoji.
    private static let defaultSample: String = {
        let ascii = String(String.UnicodeScalarView((0x20...0x7E).compactMap { Unicode.Scalar($0) }))
        return ascii + "─│┌┐└┘├┤┬┴┼█▀▄░▒▓你好世界😀🎉"
    }()
}
#endif
