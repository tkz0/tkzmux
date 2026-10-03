// RenderCommands — the `render` and `atlas` subcommands of tkzmux-vtdump (M1.5).
//
//   tkzmux-vtdump render --out <out.png> [--cols n --rows n] [--scale s] <file.tkzrec>
//       Replays a recording into a headless `TerminalSession`, attaches a `TerminalSurface` and
//       renders the final screen through the real Metal pipelines into an offscreen texture. The
//       PNG this writes is the same image the app would put on screen, which is what makes the
//       golden-frame tests meaningful. `--scale` is the backing scale the font set is built at
//       (default 2, the Retina factor the goldens use; 1.6 is the Linux parity scale).
//
//   tkzmux-vtdump atlas --out <prefix> [--point-size n --scale n --sample "…"]
//       Rasterizes a sample string (printable ASCII plus a CJK/emoji tail by default) and dumps
//       both atlases: `<prefix>-grayscale.png` and `<prefix>-color.png`. Runs with no Metal device
//       at all — `GlyphAtlas` (TkzRenderCore) is a CPU staging buffer; only the renderer uploads it.
//
// macOS only: on Linux, VulkanRenderCommands.swift draws `render` through Vulkan and stands in for
// `atlas` (WOR-313 S6).

#if canImport(Metal)
import Foundation
import Metal
import TkzRenderCore
import TkzTerminalCore
import TkzTerminalRender

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
            thicken: arguments.value("thicken") != "0"
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

    /// `tkzmux-vtdump atlas --out <prefix>` — dump both glyph atlases as PNGs.
    public static func atlas(pngPrefix: URL, pointSize: Double, scale: Double, sample: String?,
                             thicken: Bool = true) throws {
        let fontSet = FontSet(pointSize: pointSize, scale: scale)
        // Small atlases so the dump is legible rather than a postage stamp in a 2048² field.
        let cache = GlyphCache(fontSet: fontSet, grayscaleInitialSize: 512, colorInitialSize: 256,
                               thicken: thicken)

        let text = sample ?? defaultSample
        for character in text where !character.isNewline {
            for style in FontStyle.allCases {
                _ = cache.glyph(for: character, style: style)
            }
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
    }

    /// Printable ASCII plus the interesting tail: box drawing, a CJK pair and two emoji.
    private static let defaultSample: String = {
        let ascii = String(String.UnicodeScalarView((0x20...0x7E).compactMap { Unicode.Scalar($0) }))
        return ascii + "─│┌┐└┘├┤┬┴┼█▀▄░▒▓你好世界😀🎉"
    }()
}
#endif
