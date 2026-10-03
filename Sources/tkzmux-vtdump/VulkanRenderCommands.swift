// VulkanRenderCommands — `render` on Linux, through the Vulkan renderer (WOR-313 S6).
//
//   tkzmux-vtdump render --out <out.png> [--cols n --rows n] [--scale s] [--fonts system|parity]
//                        [--no-validation] <file.tkzrec>
//       RenderCommands.swift's `render`, drawn by `VulkanTerminalRenderer` on the device the app
//       would select (headless: TKZMUX_GPU and loader order, no compositor) into an offscreen
//       B8G8R8A8_UNORM target, read back and written with TkzPNG. The same frame as the Mac's: the
//       theme's terminal font (14 pt) at backing scale `--scale` (default 2; 1.6 is the Linux parity
//       scale), glyphs from FreeType. `--fonts parity` resolves fallback faces from the pinned parity
//       fonts only (FontconfigConfiguration.parity), as the parity producers do; the default is the
//       app's own configuration. The validation layer is loaded when installed, and its error
//       count fails the command.
//
//   tkzmux-vtdump atlas
//       Still a stand-in that exits 1: the FreeType atlas dump is WOR-312's (AtlasDumper).
//
// `VulkanFrameSetup` is shared with the Linux bench-frame (FrameBenchVulkan.swift).

#if os(Linux)
import Foundation
import TkzCore
import TkzFontsFT
import TkzPNG
import TkzRenderCore
import TkzRenderVK
import TkzTerminalCore

/// A headless device and a renderer over the theme's terminal font, as both commands use them.
struct VulkanFrameSetup {
    /// Which fontconfig configuration fallback faces come from.
    enum Fonts: String {
        /// The app's: bundled fonts, then the system's (FontconfigConfiguration.system).
        case system
        /// The bundled fonts and the pinned parity fonts only (scripts/fetch-parity-fonts.sh).
        case parity
    }

    let instance: VulkanInstance
    let device: VulkanDevice
    let renderer: VulkanTerminalRenderer

    init(scale: Double, fonts: Fonts, validation: VulkanInstance.Validation, theme: Theme = .default) throws {
        instance = try VulkanInstance(validation: validation, applicationName: "tkzmux-vtdump")
        device = try VulkanDevice.make(instance: instance, mode: .headless).device
        let source = try Self.glyphSource(scale: scale, fonts: fonts, theme: theme)
        renderer = try VulkanTerminalRenderer(device: device, glyphCache: GlyphCache(source: source), theme: theme)
    }

    /// The theme's terminal font through FreeType at `scale`: what `render` draws with, and what
    /// `framedump` dumps (FrameDumpCommand.swift).
    static func glyphSource(scale: Double, fonts: Fonts, theme: Theme = .default) throws -> FreeTypeGlyphSource {
        let fallback: FontFallback = switch fonts {
        case .system: .system
        case .parity: FontFallback(configuration: .parity(
            bundled: BundledFonts.fontDirectories, testFonts: FontconfigConfiguration.defaultParityFontDirectory))
        }
        let faces = try TerminalFaces(pointSize: theme.fontMono.terminal, scale: scale, fallback: fallback)
        return FreeTypeGlyphSource(faces: faces, thicken: theme.fontMono.thicken)
    }

    /// "<device> (<kind>), validation on|off": for the summary line.
    var deviceDescription: String {
        "\(device.candidate.name) (\(device.candidate.kind.rawValue)), validation \(instance.validationEnabled ? "on" : "off")"
    }

    /// Fails the command when the validation layer counted an error.
    func checkValidation(_ command: String) {
        let log = instance.validationLog
        guard log.errorCount > 0 else { return }
        for message in log.messages where message.isError {
            FileHandle.standardError.write(Data("\(message.id): \(message.text)\n".utf8))
        }
        fail("tkzmux-vtdump \(command): \(log.errorCount) validation errors", code: 1)
    }

    static func parseFonts(_ arguments: Arguments, command: String) -> Fonts {
        guard let text = arguments.value("fonts") else { return .system }
        guard let fonts = Fonts(rawValue: text) else { fail("tkzmux-vtdump \(command): --fonts is system or parity", code: 2) }
        return fonts
    }

    /// Tightly packed premultiplied BGRA rows as a straight-alpha RGBA PNG: what the Mac's
    /// `TerminalRenderer.pngData` writes for the same pixels. Terminal frames are opaque, so this
    /// is a channel swap; a translucent pixel is un-premultiplied.
    static func png(bgra: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: bgra.count)
        for index in stride(from: 0, to: bgra.count, by: 4) {
            let alpha = bgra[index + 3]
            func straight(_ value: UInt8) -> UInt8 {
                alpha == 255 || alpha == 0 ? value : UInt8(min(255, (Int(value) * 255 + Int(alpha) / 2) / Int(alpha)))
            }
            rgba[index] = straight(bgra[index + 2])
            rgba[index + 1] = straight(bgra[index + 1])
            rgba[index + 2] = straight(bgra[index])
            rgba[index + 3] = alpha
        }
        return try PNG.encode(rgba, width: width, height: height, colorType: .rgba)
    }
}

extension FrameDumpCommand {
    /// `framedump`'s font stack on Linux: `render`'s FreeType source, the theme's terminal font.
    static func fontGlyphSource(scale: Double, fonts: String?) throws
        -> (source: any GlyphSource, origin: FrameDump.Source) {
        var selected = VulkanFrameSetup.Fonts.system
        if let fonts {
            guard let parsed = VulkanFrameSetup.Fonts(rawValue: fonts) else {
                fail("tkzmux-vtdump framedump: --fonts is system or parity", code: 2)
            }
            selected = parsed
        }
        let source = try VulkanFrameSetup.glyphSource(scale: scale, fonts: selected)
        return (source, FrameDump.Source(platform: "linux", glyphSource: "FreeType",
                                         environment: ["fonts": selected.rawValue]))
    }
}

enum RenderCommands {
    /// Anything that stops a subcommand before it can write its output.
    struct CommandError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Command lines

    static func runRender(_ argv: [String]) throws {
        let arguments = Arguments(argv, valueFlags: ["out", "cols", "rows", "scale", "fonts"])
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
            scale: scale,
            fonts: VulkanFrameSetup.parseFonts(arguments, command: "render"),
            validation: arguments.has("no-validation") ? .off : .ifAvailable
        )
    }

    static func runAtlas(_ argv: [String]) throws {
        fail("tkzmux-vtdump atlas: not yet available on Linux (see WOR-312)", code: 1)
    }

    // MARK: - render

    /// Replays `recording`, renders the final screen offscreen through Vulkan and writes it as a
    /// PNG. The frame is read back from the render target, never from a screen (ADR-0003 §4).
    static func render(recording: URL, png out: URL, cols: UInt16?, rows: UInt16?, scale: Double,
                       fonts: VulkanFrameSetup.Fonts, validation: VulkanInstance.Validation) throws {
        let reader = try RecordingReader(contentsOf: recording)
        let columns = cols ?? reader.header.cols
        let rowCount = rows ?? reader.header.rows

        let session = try TerminalSession(
            options: TerminalSessionOptions(cols: columns, rows: rowCount))
        try reader.replay(into: session)
        if cols != nil || rows != nil {
            try session.resize(cols: columns, rows: rowCount)
        }

        let setup = try VulkanFrameSetup(scale: scale, fonts: fonts, validation: validation)
        let renderer = setup.renderer
        let surface = TerminalSurface()
        try surface.attach(session)

        let size = renderer.drawableSize(columns: Int(columns), rows: Int(rowCount))
        let target = try OffscreenTarget(device: setup.device, width: UInt32(size.width), height: UInt32(size.height))
        let outcome = try renderer.render(surface: surface, to: target)
        guard outcome.didEncode else {
            throw CommandError(description: "nothing to render (the recording left a blank screen)")
        }
        // Waits for the frame: the readback is submitted after it on the same queue.
        let pixels = try target.bgraBytes()
        let data = try VulkanFrameSetup.png(bgra: pixels, width: size.width, height: size.height)
        try Data(data).write(to: out, options: .atomic)

        surface.detach()
        setup.checkValidation("render")
        FileHandle.standardError.write(Data("""
            rendered \(size.width)×\(size.height) px \
            (\(columns)×\(rowCount) cells, \(outcome.glyphCount) glyphs, \
            \(outcome.rectCount) rects) on \(setup.deviceDescription) → \(out.path)\n
            """.utf8))
    }
}
#endif
