// TerminalRendererTests — the GPU half of M1.5 (TKZ-11).
//
// Two things are proven here that nothing else can prove:
//
//   1. **The golden frame.** A synthetic `.tkzrec` recording — generated in code, covering bold,
//      italic, underline, a 256-colour run, a 24-bit colour run, reverse video, a CJK cell, an
//      emoji cell, a block cursor, a bar cursor and a selection — is replayed through a real
//      `TerminalSession`, rendered through the real Metal pipelines into an offscreen texture and
//      compared pixel-by-pixel with a committed PNG. Regenerate with
//      `TKZMUX_UPDATE_GOLDEN=1 swift test --filter TkzTerminalRenderTests`, exactly as
//      `docs/keys.md` is regenerated with `TKZMUX_UPDATE_KEYS_DOC=1`.
//
//   2. **The idle guarantee.** Rendering the same unchanged state twice must write zero bytes into
//      the instance buffers, acquire no drawable and return early on the second call. The renderer
//      carries counters for exactly this, so it is measured rather than asserted.
//
// Every Metal test returns early when `MTLCreateSystemDefaultDevice()` is nil (Swift Testing has no
// "skip"), so a headless machine reports them as passing-but-empty.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore
import Testing
import TkzCore
import TkzShaderTypes
import TkzTerminalCore
@testable import TkzTerminalRender

// MARK: - The synthetic recording

/// The screen the golden frames are built from. One feature per line so a diff in the PNG points at
/// a feature rather than at "the frame changed".
///
/// Deliberately *not* `claude-boot.tkzrec`: this file must be reproducible from source alone.
enum GoldenScreen {
    static let columns: UInt16 = 40
    static let rows: UInt16 = 9

    /// The pty bytes, as a program would emit them.
    static var output: String {
        var text = ""
        text += "\u{1b}[1mbold\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m \u{1b}[4munderline\u{1b}[0m\r\n"
        text += "\u{1b}[1;31mbold red\u{1b}[0m \u{1b}[31mred\u{1b}[0m\r\n"
        text += "\u{1b}[38;5;208m256-colour\u{1b}[0m \u{1b}[48;5;18mon blue\u{1b}[0m\r\n"
        text += "\u{1b}[38;2;255;128;0m24-bit\u{1b}[0m \u{1b}[48;2;20;60;20mrgb bg\u{1b}[0m\r\n"
        text += "\u{1b}[7mreverse video\u{1b}[0m plain\r\n"
        text += "wide 你好 emoji 😀 tail\r\n"
        text += "\u{1b}[9mstruck\u{1b}[0m \u{1b}[4:3mcurly\u{1b}[0m \u{1b}[4:5mdashed\u{1b}[0m\r\n"
        text += "select this line\r\n"
        text += "\u{1b}[8;1H"  // park the cursor on the last row, column 1
        return text
    }

    /// The same content as a real `.tkzrec` file, so the golden path exercises the recording
    /// reader that `tkzmux-vtdump render` uses.
    static func makeRecording() throws -> RecordingReader {
        let header = RecordingHeader(
            cols: columns, rows: rows, argv: ["synthetic"], env: [:],
            startedAt: 0, note: "M1.5 golden frame")
        let writer = RecordingWriter(header: header)
        var data = try writer.headerLine()
        data.append(writer.encode(.output(elapsedNanos: 0, bytes: Data(output.utf8))))
        return try RecordingReader(data: data)
    }

    /// A session with the recording already replayed into it.
    static func makeSession(theme: Theme = .default) throws -> TerminalSession {
        let session = try TerminalSession(
            options: TerminalSessionOptions(cols: columns, rows: rows, theme: theme))
        try makeRecording().replay(into: session)
        return session
    }
}

// MARK: - Golden-image plumbing

/// Repo root, from this file's path (`<root>/Tests/TkzTerminalRenderTests/…`).
private func repoRoot(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

private func goldenSourceURL(_ name: String) -> URL {
    repoRoot().appendingPathComponent("Tests/TkzTerminalRenderTests/Fixtures/\(name)")
}

/// BGRA bytes of a PNG on disk, at its native size.
private func decodePNG(_ url: URL) throws -> (width: Int, height: Int, pixels: [UInt8]) {
    let data = try Data(contentsOf: url)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        struct UndecodablePNG: Error { let url: URL }
        throw UndecodablePNG(url: url)
    }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { raw in
        guard let context = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (width, height, pixels)
}

/// Compares a rendered texture with a committed golden PNG, or rewrites the golden when
/// `TKZMUX_UPDATE_GOLDEN` is set. Returns false only when the environment cannot run the check.
@discardableResult
private func assertMatchesGolden(
    texture: MTLTexture, named name: String,
    channelTolerance: Int = 2, pixelTolerance: Double = 0.002,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Bool {
    guard let png = TerminalRenderer.pngData(from: texture) else {
        Issue.record("could not encode the rendered texture as PNG", sourceLocation: sourceLocation)
        return false
    }
    let source = goldenSourceURL(name)
    if ProcessInfo.processInfo.environment["TKZMUX_UPDATE_GOLDEN"] != nil {
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: source, options: .atomic)
        return true
    }

    // Read the copy in the test bundle when it is there (that is what `swift test` ships), else the
    // source tree — a golden that has just been regenerated is not in the bundle yet.
    let bundled = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
    let goldenURL = bundled ?? source
    guard FileManager.default.fileExists(atPath: goldenURL.path) else {
        Issue.record("""
            missing golden \(name). Regenerate with:
              TKZMUX_UPDATE_GOLDEN=1 swift test --filter TkzTerminalRenderTests
            """, sourceLocation: sourceLocation)
        return false
    }

    let golden = try decodePNG(goldenURL)
    let rendered = (width: texture.width, height: texture.height,
                    pixels: TerminalRenderer.bgraBytes(of: texture))
    #expect(golden.width == rendered.width && golden.height == rendered.height,
            "\(name): golden is \(golden.width)×\(golden.height), rendered \(rendered.width)×\(rendered.height)",
            sourceLocation: sourceLocation)
    guard golden.width == rendered.width, golden.height == rendered.height else { return false }

    var differing = 0
    var worstChannel = 0
    var firstBad: (x: Int, y: Int)?
    for index in stride(from: 0, to: rendered.pixels.count, by: 4) {
        var bad = false
        for channel in 0..<4 {
            let delta = abs(Int(rendered.pixels[index + channel]) - Int(golden.pixels[index + channel]))
            worstChannel = max(worstChannel, delta)
            if delta > channelTolerance { bad = true }
        }
        if bad {
            differing += 1
            if firstBad == nil {
                let pixel = index / 4
                firstBad = (pixel % rendered.width, pixel / rendered.width)
            }
        }
    }
    let fraction = Double(differing) / Double(rendered.width * rendered.height)
    #expect(fraction <= pixelTolerance, """
        \(name): \(differing) of \(rendered.width * rendered.height) pixels differ \
        (\(String(format: "%.3f", fraction * 100))%, worst channel delta \(worstChannel)\
        \(firstBad.map { ", first at (\($0.x), \($0.y))" } ?? "")).
        Inspect, then regenerate with:
          TKZMUX_UPDATE_GOLDEN=1 swift test --filter TkzTerminalRenderTests
        """, sourceLocation: sourceLocation)
    return true
}

/// A renderer plus an attached surface over the golden screen.
private struct RendererFixture {
    let device: MTLDevice
    let renderer: TerminalRenderer
    let session: TerminalSession
    let surface: TerminalSurface
    let texture: MTLTexture

    init?(theme: Theme = .default) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        renderer = try TerminalRenderer(
            device: device,
            glyphCache: GlyphCache(fontSet: FontSet(pointSize: 12.5, scale: 2), device: device),
            theme: theme)
        session = try GoldenScreen.makeSession(theme: theme)
        surface = TerminalSurface()
        try surface.attach(session)
        let size = renderer.drawableSize(columns: Int(GoldenScreen.columns),
                                         rows: Int(GoldenScreen.rows))
        guard let texture = renderer.makeOffscreenTexture(width: size.width, height: size.height)
        else { return nil }
        self.texture = texture
    }

    @discardableResult
    func renderAndWait() throws -> RenderOutcome {
        let outcome = try renderer.render(surface: surface, to: texture)
        outcome.commandBuffer?.waitUntilCompleted()
        #expect(outcome.commandBuffer?.error == nil)
        return outcome
    }
}

// MARK: - Golden frames

@Suite(.serialized)
struct TerminalRendererGoldenTests {
    @Test("the golden frame: styles, colours, wide/emoji cells, a block cursor and a selection")
    func blockCursorGolden() throws {
        guard let fixture = try RendererFixture() else { return }
        try setSelection(fixture.session, startX: 0, startY: 7, endX: 15, endY: 7)

        let outcome = try fixture.renderAndWait()
        #expect(outcome.didEncode)
        #expect(outcome.update.dirty == .full)
        #expect(outcome.glyphCount > 40, "the golden screen is far from empty")
        #expect(outcome.rectCount >= 4, "underline, curly, dashed, strike and the cursor")
        try assertMatchesGolden(texture: fixture.texture, named: "golden-block-cursor.png")
    }

    @Test("the golden frame with a bar cursor (DECSCUSR 5) and no selection")
    func barCursorGolden() throws {
        guard let fixture = try RendererFixture() else { return }
        fixture.session.write(ptyText: "\u{1b}[5 q")

        let outcome = try fixture.renderAndWait()
        #expect(outcome.didEncode)
        #expect(fixture.surface.cursor.style == .bar)
        try assertMatchesGolden(texture: fixture.texture, named: "golden-bar-cursor.png")
    }
}

// MARK: - The idle guarantee

@Suite(.serialized)
struct TerminalRendererIdleTests {
    @Test("rendering unchanged state twice writes zero bytes and acquires no drawable")
    func secondFrameIsFree() throws {
        guard let fixture = try RendererFixture() else { return }

        let first = try fixture.renderAndWait()
        #expect(first.didEncode)
        let afterFirst = fixture.renderer.stats
        #expect(afterFirst.framesEncoded == 1)
        #expect(afterFirst.instanceBytesWritten > 0)

        fixture.renderer.resetStats()
        let second = try fixture.renderer.render(surface: fixture.surface, to: fixture.texture)
        #expect(!second.didEncode, "an unchanged surface must return early")
        #expect(second.commandBuffer == nil, "no command buffer means no GPU work at all")

        let idle = fixture.renderer.stats
        #expect(idle.instanceBytesWritten == 0, "not one byte may reach an instance buffer")
        #expect(idle.uniformBytesWritten == 0)
        #expect(idle.drawableRequests == 0, "a skipped frame must not even ask for a render target")
        #expect(idle.drawablesAcquired == 0, "an idle terminal must not hold a drawable")
        #expect(idle.framesEncoded == 0)
        #expect(idle.framesSkipped == 1)

        // A third idle tick is just as free, and a real change wakes it up again.
        _ = try fixture.renderer.render(surface: fixture.surface, to: fixture.texture)
        #expect(fixture.renderer.stats.instanceBytesWritten == 0)

        fixture.session.write(ptyText: "wake up")
        let third = try fixture.renderAndWait()
        #expect(third.didEncode)
        #expect(third.update.dirty == .partial)
        #expect(fixture.renderer.stats.instanceBytesWritten > 0)
    }

    @Test("a cursor blink is a frame, but not a row rebuild")
    func blinkCostsAFrameButNotARebuild() throws {
        guard let fixture = try RendererFixture() else { return }
        try fixture.renderAndWait()
        fixture.renderer.resetStats()

        fixture.surface.cursorBlinkOn = false
        let outcome = try fixture.renderAndWait()
        #expect(outcome.didEncode, "the cursor has to disappear, so the frame must be redrawn")
        #expect(outcome.update.dirty == .none, "…but libghostty reported nothing dirty")
        #expect(outcome.update.rowsRebuilt == 0)
        #expect(fixture.renderer.stats.framesEncoded == 1)
    }

    @Test("the CAMetalLayer seam acquires a drawable for a real frame and none for an idle one")
    func layerPathHonoursTheIdleGuarantee() throws {
        guard let fixture = try RendererFixture() else { return }
        let layer = CAMetalLayer()
        layer.device = fixture.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        let size = fixture.renderer.drawableSize(columns: Int(GoldenScreen.columns),
                                                 rows: Int(GoldenScreen.rows))
        layer.drawableSize = CGSize(width: size.width, height: size.height)

        let first = try fixture.renderer.render(surface: fixture.surface, layer: layer)
        first.commandBuffer?.waitUntilCompleted()
        #expect(first.didEncode)
        #expect(first.commandBuffer?.error == nil)
        #expect(fixture.renderer.stats.drawablesAcquired == 1)

        fixture.renderer.resetStats()
        let second = try fixture.renderer.render(surface: fixture.surface, layer: layer)
        #expect(!second.didEncode)
        #expect(fixture.renderer.stats.drawableRequests == 0,
                "the skip path must return before nextDrawable() is ever called")
        #expect(fixture.renderer.stats.drawablesAcquired == 0)
        #expect(fixture.renderer.stats.instanceBytesWritten == 0)
    }

    /// Regression: reported from real use — the window would not resize while dragging, only on
    /// mouse-up. `presentsWithTransaction` is a promise to Core Animation that the transaction will
    /// be completed by an explicit `present()`; the idle guarantee was breaking that promise on
    /// every layout pass where the size had not changed, so the transaction never completed and the
    /// resize stalled. While the flag is set, every frame must be encoded and presented.
    @Test("presentsWithTransaction suspends the idle guarantee, because a skipped frame stalls the resize")
    func transactionalPresentNeverSkips() throws {
        guard let fixture = try RendererFixture() else { return }
        let layer = CAMetalLayer()
        layer.device = fixture.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        let size = fixture.renderer.drawableSize(columns: Int(GoldenScreen.columns),
                                                 rows: Int(GoldenScreen.rows))
        layer.drawableSize = CGSize(width: size.width, height: size.height)

        // Draw once so the surface is clean, exactly as it is between two layout passes in a drag.
        let first = try fixture.renderer.render(surface: fixture.surface, layer: layer)
        first.commandBuffer?.waitUntilCompleted()
        #expect(first.didEncode)
        #expect(!fixture.surface.needsDisplay)

        // Off: a clean surface still skips, so the idle guarantee is intact where it matters.
        fixture.renderer.resetStats()
        let idle = try fixture.renderer.render(surface: fixture.surface, layer: layer)
        #expect(!idle.didEncode)
        #expect(fixture.renderer.stats.drawableRequests == 0)

        // On: the same clean surface must still produce a presented frame.
        layer.presentsWithTransaction = true
        defer { layer.presentsWithTransaction = false }
        fixture.renderer.resetStats()
        let forced = try fixture.renderer.render(surface: fixture.surface, layer: layer)
        forced.commandBuffer?.waitUntilCompleted()
        #expect(forced.didEncode, "a clean surface must still be drawn while presentsWithTransaction is set")
        #expect(forced.commandBuffer?.error == nil)
        #expect(fixture.renderer.stats.drawablesAcquired == 1)
        #expect(fixture.renderer.stats.framesSkipped == 0)
    }

    @Test("a detached surface renders nothing and touches no buffer")
    func detachedSurfaceIsSkipped() throws {
        guard let fixture = try RendererFixture() else { return }
        try fixture.renderAndWait()
        fixture.surface.detach()
        fixture.renderer.resetStats()

        let outcome = try fixture.renderer.render(surface: fixture.surface, to: fixture.texture)
        #expect(!outcome.didEncode)
        #expect(fixture.renderer.stats.framesSkipped == 1)
        #expect(fixture.renderer.stats.instanceBytesWritten == 0)
    }
}

// MARK: - Pixels

@Suite(.serialized)
struct TerminalRendererPixelTests {
    /// `.bgra8Unorm` read-back order is B, G, R, A.
    private func pixel(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }

    @Test("an explicit cell background reaches the drawable, and the rest is the theme background")
    func backgroundsLandWhereTheGridSaysTheyDo() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let theme = Theme.default
        let renderer = try TerminalRenderer(
            device: device,
            glyphCache: GlyphCache(fontSet: FontSet(pointSize: 12.5, scale: 2), device: device),
            theme: theme)
        let session = try TerminalSession(options: TerminalSessionOptions(cols: 4, rows: 2, theme: theme))
        // A red background in cell (1,0), and nothing anywhere else.
        session.write(ptyText: "\u{1b}[H \u{1b}[48;2;255;0;0m \u{1b}[0m")
        let surface = TerminalSurface()
        try surface.attach(session)

        let metrics = renderer.glyphCache.metrics
        let size = renderer.drawableSize(columns: 4, rows: 2)
        let texture = try #require(renderer.makeOffscreenTexture(width: size.width, height: size.height))
        let outcome = try renderer.render(surface: surface, to: texture)
        outcome.commandBuffer?.waitUntilCompleted()
        #expect(outcome.commandBuffer?.error == nil)

        let pixels = TerminalRenderer.bgraBytes(of: texture)
        let inCell1 = pixel(pixels, width: size.width,
                            x: metrics.width + metrics.width / 2, y: metrics.height / 2)
        #expect(inCell1 == (0, 0, 255), "cell (1,0) was given an explicit red background")

        let themeBytes = theme.terminalBackground.bytes
        let inCell3 = pixel(pixels, width: size.width,
                            x: metrics.width * 3 + metrics.width / 2, y: metrics.height / 2)
        #expect(inCell3 == (themeBytes.b, themeBytes.g, themeBytes.r),
                "a cell with no explicit background composites to the theme background")
    }

    @Test("the shader library loads through the makeLibrary(source:) fallback")
    func libraryLoads() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try TerminalRenderer.makeLibrary(device: device)
        for name in [TKZ_FN_BG_VERTEX, TKZ_FN_BG_FRAGMENT, TKZ_FN_RECT_VERTEX,
                     TKZ_FN_RECT_FRAGMENT, TKZ_FN_GLYPH_VERTEX, TKZ_FN_GLYPH_FRAGMENT] {
            #expect(library.makeFunction(name: name) != nil, "missing \(name)")
        }
    }
}
