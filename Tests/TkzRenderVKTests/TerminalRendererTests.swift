// TerminalRendererTests — the Vulkan renderer's idle guarantee, panes and pixels (WOR-313 S4b).
//
// Linux twins of Tests/TkzTerminalRenderTests/TerminalRendererTests.swift, test for test under the
// same names: the counters the Mac reads (`RenderStats`) carry the same names here, and the
// properties they prove are the same. The golden frames are S6's; the presentation ring's twin of
// `layerPathHonoursTheIdleGuarantee` is in PresentationDamageTests (S5b). The pane tests are
// Linux's own: every pane draws into its own rect of a shared target, and must clear and touch that
// rect only.
//
// Real sessions (libghostty-vt), real glyphs (FreeType over the bundled fonts), a real Vulkan
// device; skipped by name without one, and a failure in CI (TKZMUX_REQUIRE_VULKAN=1). Every test
// asserts the validation layer counted no error.

import CVulkan
import Foundation
import Testing
import TkzCore
import TkzFontsFT
import TkzRenderCore
import TkzTerminalCore
@testable import TkzRenderVK

// MARK: - Fixture

/// The Mac golden screen's content, one feature per line, without the recording round trip.
enum RendererScreen {
    static let columns: UInt16 = 40
    static let rows: UInt16 = 9

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

    static func makeSession(theme: Theme = .default) throws -> TerminalSession {
        let session = try TerminalSession(options: TerminalSessionOptions(cols: columns, rows: rows, theme: theme))
        session.write(ptyText: output)
        return session
    }
}

enum RendererFonts {
    static let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tkzmux-tests-fontconfig-\(getuid())", isDirectory: true)

    /// The Mac fixture's 12.5 pt at scale 2, through FreeType.
    static func cache() throws -> GlyphCache {
        let fallback = FontFallback(configuration: .system(bundled: BundledFonts.fontDirectories, cacheDirectory: cacheDirectory))
        return GlyphCache(source: FreeTypeGlyphSource(faces: try TerminalFaces(pointSize: 12.5, scale: 2, fallback: fallback)))
    }
}

/// A renderer plus an attached surface over the screen, and a target the screen's size.
private struct RendererFixture {
    let device: VulkanDevice
    let renderer: VulkanTerminalRenderer
    let session: TerminalSession
    let surface: TerminalSurface
    let target: OffscreenTarget

    init(theme: Theme = .default) throws {
        device = try VulkanTestDevice.make()
        renderer = try VulkanTerminalRenderer(device: device, glyphCache: try RendererFonts.cache(), theme: theme)
        session = try RendererScreen.makeSession(theme: theme)
        surface = TerminalSurface()
        try surface.attach(session)
        let size = renderer.drawableSize(columns: Int(RendererScreen.columns), rows: Int(RendererScreen.rows))
        target = try OffscreenTarget(device: device, width: UInt32(size.width), height: UInt32(size.height))
    }

    func makeSurfaces(_ count: Int) throws -> [(session: TerminalSession, surface: TerminalSurface)] {
        try (0..<count).map { _ in
            let session = try RendererScreen.makeSession()
            let surface = TerminalSurface()
            try surface.attach(session)
            return (session, surface)
        }
    }

    @discardableResult
    func renderAndWait() throws -> RenderOutcome {
        let outcome = try renderer.render(surface: surface, to: target)
        try outcome.frame?.waitUntilCompleted()
        return outcome
    }

    func expectNoValidationErrors(sourceLocation: SourceLocation = #_sourceLocation) {
        VulkanTestDevice.expectNoValidationErrors(device, sourceLocation: sourceLocation)
    }
}

/// Pixel `(x, y)` of tightly packed BGRA rows, as (b, g, r).
private func pixel(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
    let offset = (y * width + x) * 4
    return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
}

/// The `rect` of a `width`-wide BGRA image, as tightly packed rows.
func crop(_ pixels: [UInt8], width: Int, to rect: PixelRect) -> [UInt8] {
    var rows: [UInt8] = []
    rows.reserveCapacity(rect.width * rect.height * 4)
    for row in rect.y..<rect.y + rect.height {
        let start = (row * width + rect.x) * 4
        rows += pixels[start..<start + rect.width * 4]
    }
    return rows
}

/// How two equal-sized BGRA images differ: the number of differing pixels and the first one, for
/// an assertion message that does not print megabytes of bytes. Nil when they are equal.
func difference(_ a: [UInt8], _ b: [UInt8], width: Int) -> String? {
    guard a.count == b.count else { return "sizes differ: \(a.count) and \(b.count) bytes" }
    var count = 0
    var first: Int?
    for index in stride(from: 0, to: a.count, by: 4) where a[index..<index + 4] != b[index..<index + 4] {
        count += 1
        if first == nil { first = index / 4 }
    }
    guard let first else { return nil }
    let index = first * 4
    return "\(count) pixels differ, first at (\(first % width), \(first / width)): "
        + "\(Array(a[index..<index + 4])) vs \(Array(b[index..<index + 4]))"
}

/// The largest per-channel difference between two equal-sized images.
private func maxChannelDelta(_ a: [UInt8], _ b: [UInt8]) -> Int {
    zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
}

// MARK: - The idle guarantee

@Suite("Vulkan renderer: the idle guarantee", .serialized,
       .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
struct VulkanRendererIdleTests {

    @Test("rendering unchanged state twice writes zero bytes and acquires no target")
    func secondFrameIsFree() throws {
        let fixture = try RendererFixture()

        let first = try fixture.renderAndWait()
        #expect(first.didEncode)
        #expect(first.update.dirty == .full)
        #expect(first.glyphCount > 40, "the screen is far from empty")
        #expect(first.rectCount >= 4, "underline, curly, dashed, strike and the cursor")
        let afterFirst = fixture.renderer.stats
        #expect(afterFirst.framesEncoded == 1)
        #expect(afterFirst.instanceBytesWritten > 0)
        #expect(afterFirst.uniformBytesWritten > 0)

        fixture.renderer.resetStats()
        let ring = try #require(fixture.surface.frameRing)
        let ringBefore = ring.stats
        let second = try fixture.renderer.render(surface: fixture.surface, to: fixture.target)
        #expect(!second.didEncode, "an unchanged surface must return early")
        #expect(second.frame == nil, "no submission means no GPU work at all")

        let idle = fixture.renderer.stats
        #expect(idle.instanceBytesWritten == 0, "not one byte may reach an instance buffer")
        #expect(idle.uniformBytesWritten == 0)
        #expect(idle.drawableRequests == 0, "a skipped frame must not even ask for a render target")
        #expect(idle.drawablesAcquired == 0, "an idle terminal must not hold a target")
        #expect(idle.framesEncoded == 0)
        #expect(idle.framesSkipped == 1)
        #expect(ring.stats == ringBefore, "nor take a ring slot, wait on a fence or submit")

        // A third idle tick is just as free, and a real change wakes it up again.
        _ = try fixture.renderer.render(surface: fixture.surface, to: fixture.target)
        #expect(fixture.renderer.stats.instanceBytesWritten == 0)

        fixture.session.write(ptyText: "wake up")
        let third = try fixture.renderAndWait()
        #expect(third.didEncode)
        #expect(third.update.dirty == .partial)
        #expect(fixture.renderer.stats.instanceBytesWritten > 0)
        fixture.expectNoValidationErrors()
    }

    @Test("a cursor blink is a frame, but not a row rebuild")
    func blinkCostsAFrameButNotARebuild() throws {
        let fixture = try RendererFixture()
        try fixture.renderAndWait()
        fixture.renderer.resetStats()

        fixture.surface.cursorBlinkOn = false
        let outcome = try fixture.renderAndWait()
        #expect(outcome.didEncode, "the cursor has to disappear, so the frame must be redrawn")
        #expect(outcome.update.dirty == .none, "…but libghostty reported nothing dirty")
        #expect(outcome.update.rowsRebuilt == 0)
        #expect(fixture.renderer.stats.framesEncoded == 1)
        fixture.expectNoValidationErrors()
    }

    @Test("the acquire seam acquires a target for a real frame and never calls acquire for an idle one")
    func acquirePathHonoursTheIdleGuarantee() throws {
        let fixture = try RendererFixture()
        let target = fixture.target
        var calls = 0
        func render() throws -> RenderOutcome {
            try fixture.renderer.render(surface: fixture.surface, targetWidth: Int(target.width), targetHeight: Int(target.height)) {
                calls += 1
                return target
            }
        }

        let first = try render()
        try first.frame?.waitUntilCompleted()
        #expect(first.didEncode)
        #expect(calls == 1)
        #expect(fixture.renderer.stats.drawablesAcquired == 1)

        fixture.renderer.resetStats()
        let second = try render()
        #expect(!second.didEncode)
        #expect(calls == 1, "the skip path must return before acquire is ever called")
        #expect(fixture.renderer.stats.drawableRequests == 0)
        #expect(fixture.renderer.stats.drawablesAcquired == 0)
        #expect(fixture.renderer.stats.instanceBytesWritten == 0)

        // No target to be had: skipped, and the surface keeps its change for the next tick.
        fixture.session.write(ptyText: "x")
        let starved = try fixture.renderer.render(
            surface: fixture.surface, targetWidth: Int(target.width), targetHeight: Int(target.height)) { nil }
        #expect(!starved.didEncode)
        #expect(fixture.surface.needsDisplay)
        #expect(fixture.renderer.stats.drawableRequests == 1)
        let retried = try render()
        try retried.frame?.waitUntilCompleted()
        #expect(retried.didEncode)
        fixture.expectNoValidationErrors()
    }

    /// The Mac's live-resize promise (`presentsWithTransaction`) is `forceEncode` here: the frame a
    /// toolkit configure must be answered with (WOR-314).
    @Test("forceEncode suspends the idle guarantee, because a skipped frame stalls the resize")
    func transactionalPresentNeverSkips() throws {
        let fixture = try RendererFixture()
        let target = fixture.target
        func render(force: Bool) throws -> RenderOutcome {
            try fixture.renderer.render(surface: fixture.surface, targetWidth: Int(target.width), targetHeight: Int(target.height),
                                        forceEncode: force) { target }
        }

        // Draw once so the surface is clean, exactly as it is between two configures in a drag.
        let first = try render(force: false)
        try first.frame?.waitUntilCompleted()
        #expect(first.didEncode)
        #expect(!fixture.surface.needsDisplay)

        // Off: a clean surface still skips, so the idle guarantee is intact where it matters.
        fixture.renderer.resetStats()
        let idle = try render(force: false)
        #expect(!idle.didEncode)
        #expect(fixture.renderer.stats.drawableRequests == 0)

        // On: the same clean surface must still produce a frame.
        fixture.renderer.resetStats()
        let forced = try render(force: true)
        try forced.frame?.waitUntilCompleted()
        #expect(forced.didEncode, "a clean surface must still be drawn while forceEncode is set")
        #expect(fixture.renderer.stats.drawablesAcquired == 1)
        #expect(fixture.renderer.stats.framesSkipped == 0)
        fixture.expectNoValidationErrors()
    }

    @Test("a detached surface renders nothing and touches no buffer")
    func detachedSurfaceIsSkipped() throws {
        let fixture = try RendererFixture()
        try fixture.renderAndWait()
        fixture.surface.detach()
        fixture.renderer.resetStats()

        let outcome = try fixture.renderer.render(surface: fixture.surface, to: fixture.target)
        #expect(!outcome.didEncode)
        #expect(fixture.renderer.stats.framesSkipped == 1)
        #expect(fixture.renderer.stats.instanceBytesWritten == 0)
        #expect(fixture.renderer.stats.drawableRequests == 0)
        #expect(fixture.surface.frameRing == nil)
        fixture.expectNoValidationErrors()
    }
}

// MARK: - Several surfaces at once

@Suite("Vulkan renderer: several surfaces", .serialized,
       .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
struct VulkanRendererMultiSurfaceTests {

    /// The idle guarantee is per surface, not per renderer: one dirty pane and one quiet one in the
    /// same tick must encode exactly one frame and ask for exactly one target.
    @Test("a dirty pane and a quiet pane in one tick encode one frame between them")
    func theIdleGuaranteeIsPerSurface() throws {
        let fixture = try RendererFixture()
        let panes = try fixture.makeSurfaces(2)

        // Settle both, so neither is dirty merely from being attached.
        for pane in panes {
            try fixture.renderer.render(surface: pane.surface, to: fixture.target).frame?.waitUntilCompleted()
        }
        fixture.renderer.resetStats()

        panes[0].session.write(ptyText: "only this pane changed")
        for pane in panes {
            _ = try fixture.renderer.render(surface: pane.surface, to: fixture.target)
        }

        let stats = fixture.renderer.stats
        #expect(stats.framesEncoded == 1)
        #expect(stats.framesSkipped == 1)
        #expect(stats.drawableRequests == 1, "the quiet pane must not even ask for a target")
        _ = try fixture.target.bgraBytes()
        fixture.expectNoValidationErrors()
    }

    /// The reason the ring is per surface: with one shared 3-deep ring the fourth `render` in a
    /// tick would block the main thread on the GPU. No wait anywhere, and no ring waited on a fence.
    /// First as on the Mac, every pane over the whole target, so each frame's clear lands on the
    /// previous frame's pixels and only the renderer's barrier orders the two; then one tick of the
    /// panes tiled into quarters.
    @Test("four panes encode in one tick without waiting on the GPU", .timeLimit(.minutes(1)))
    func fourPanesDoNotStall() throws {
        let fixture = try RendererFixture()
        let panes = try fixture.makeSurfaces(4)
        fixture.renderer.resetStats()

        for pane in panes {
            let outcome = try fixture.renderer.render(surface: pane.surface, to: fixture.target)
            #expect(outcome.didEncode)
        }
        #expect(fixture.renderer.stats.framesEncoded == 4)

        for pane in panes { pane.session.write(ptyText: "next tick") }
        fixture.renderer.resetStats()
        let width = Int(fixture.target.width), height = Int(fixture.target.height)
        let quarters = [
            PixelRect(x: 0, y: 0, width: width / 2, height: height / 2),
            PixelRect(x: width / 2, y: 0, width: width - width / 2, height: height / 2),
            PixelRect(x: 0, y: height / 2, width: width / 2, height: height - height / 2),
            PixelRect(x: width / 2, y: height / 2, width: width - width / 2, height: height - height / 2),
        ]
        for (pane, rect) in zip(panes, quarters) {
            let outcome = try fixture.renderer.render(surface: pane.surface, to: fixture.target, in: rect)
            #expect(outcome.didEncode)
        }
        #expect(fixture.renderer.stats.framesEncoded == 4)
        for pane in panes {
            #expect(pane.surface.frameRing?.stats.fenceWaits == 0, "a fresh ring hands out its slots without waiting")
        }

        _ = try fixture.target.bgraBytes()
        for pane in panes { pane.surface.detach() }
        fixture.expectNoValidationErrors()
    }

    /// Each surface owns its buffers, and `detach` gives them back.
    @Test("each surface owns its ring, and detaching frees it")
    func everySurfaceOwnsItsRing() throws {
        let fixture = try RendererFixture()
        let panes = try fixture.makeSurfaces(2)
        for pane in panes {
            try fixture.renderer.render(surface: pane.surface, to: fixture.target).frame?.waitUntilCompleted()
        }

        let a = try #require(panes[0].surface.frameRing)
        let b = try #require(panes[1].surface.frameRing)
        #expect(a !== b)
        #expect(a.byteCount > 0)

        panes[0].surface.detach()
        #expect(panes[0].surface.frameRing == nil)
        #expect(panes[1].surface.frameRing != nil, "detaching one pane must not disturb the other")
        fixture.expectNoValidationErrors()
    }
}

// MARK: - Panes and pixels

@Suite("Vulkan renderer: panes and pixels", .serialized,
       .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
struct VulkanRendererPixelTests {

    @Test("an explicit cell background reaches the target, and the rest is the theme background")
    func backgroundsLandWhereTheGridSaysTheyDo() throws {
        let theme = Theme.default
        let device = try VulkanTestDevice.make()
        let renderer = try VulkanTerminalRenderer(device: device, glyphCache: try RendererFonts.cache(), theme: theme)
        let session = try TerminalSession(options: TerminalSessionOptions(cols: 4, rows: 2, theme: theme))
        // A red background in cell (1,0), and nothing anywhere else.
        session.write(ptyText: "\u{1b}[H \u{1b}[48;2;255;0;0m \u{1b}[0m")
        let surface = TerminalSurface()
        try surface.attach(session)

        let metrics = renderer.glyphCache.metrics
        let size = renderer.drawableSize(columns: 4, rows: 2)
        let target = try OffscreenTarget(device: device, width: UInt32(size.width), height: UInt32(size.height))
        #expect(try renderer.render(surface: surface, to: target).didEncode)
        let pixels = try target.bgraBytes()

        let inCell1 = pixel(pixels, width: size.width, x: metrics.width + metrics.width / 2, y: metrics.height / 2)
        #expect(inCell1 == (0, 0, 255), "cell (1,0) was given an explicit red background")

        let themeBytes = theme.terminalBackground.bytes
        let inCell3 = pixel(pixels, width: size.width, x: metrics.width * 3 + metrics.width / 2, y: metrics.height / 2)
        #expect(inCell3 == (themeBytes.b, themeBytes.g, themeBytes.r),
                "a cell with no explicit background composites to the theme background")
        VulkanTestDevice.expectNoValidationErrors(device)
    }

    /// Regression (Mac): on the light theme, a program's dark-theme pastel was drawn as sent and
    /// all but vanished. The min-contrast fix runs in the glyph vertex shader.
    @Test("on the light theme a program's pastel is deepened to the theme's minimum contrast, keeps its hue, and theme text is untouched")
    func lightThemeLiftsProgramColoursToMinimumContrast() throws {
        let theme = Theme.light
        let device = try VulkanTestDevice.make()
        let renderer = try VulkanTerminalRenderer(device: device, glyphCache: try RendererFonts.cache(), theme: theme)
        let session = try TerminalSession(options: TerminalSessionOptions(cols: 4, rows: 1, theme: theme))
        // Cell 0: a full block in the pastel. Cell 2: a full block in the theme's own foreground.
        session.write(ptyText: "\u{1b}[H\u{1b}[38;2;177;185;249m\u{2588}\u{1b}[0m \u{2588}")
        let surface = TerminalSurface()
        try surface.attach(session)

        let metrics = renderer.glyphCache.metrics
        let size = renderer.drawableSize(columns: 4, rows: 1)
        let target = try OffscreenTarget(device: device, width: UInt32(size.width), height: UInt32(size.height))
        #expect(try renderer.render(surface: surface, to: target).didEncode)
        let pixels = try target.bgraBytes()

        let pastel = pixel(pixels, width: size.width, x: metrics.width / 2, y: metrics.height / 2)
        let drawn = RGB(rgb: pastel.r, pastel.g, pastel.b)
        let ratio = drawn.contrastRatio(against: theme.terminalBackground)
        #expect(ratio >= theme.terminalMinContrast - 0.1, "drawn at \(ratio):1")
        #expect(ratio < theme.terminalMinContrast + 0.5, "only as far as needed, not to black: \(ratio):1")
        #expect(pastel.b > pastel.r && pastel.b > pastel.g, "still blue: \(pastel)")

        let themed = pixel(pixels, width: size.width, x: metrics.width * 2 + metrics.width / 2, y: metrics.height / 2)
        let fg = theme.terminalForeground.bytes
        #expect(themed == (fg.b, fg.g, fg.r), "theme-coloured text is drawn exactly as the theme says")
        VulkanTestDevice.expectNoValidationErrors(device)
    }

    @Test("a pane clears and draws its own rect only; the rest of the target keeps its pixels")
    func aPaneClearsOnlyItsRect() throws {
        let fixture = try RendererFixture()
        let width = Int(fixture.target.width), height = Int(fixture.target.height)
        let sentinel = BGRA8(b: 0x12, g: 0x34, r: 0x56, a: 0xFF)
        _ = try fixture.target.clear(to: sentinel)

        // An odd offset and size, so a viewport or scissor mistake cannot hide.
        let rect = PixelRect(x: 37, y: 11, width: width / 2 + 3, height: height / 2 + 5)
        #expect(try fixture.renderer.render(surface: fixture.surface, to: fixture.target, in: rect).didEncode)
        let pixels = try fixture.target.bgraBytes()

        var outside = 0, changedOutside = 0
        for y in 0..<height {
            for x in 0..<width where !(rect.x..<rect.x + rect.width).contains(x) || !(rect.y..<rect.y + rect.height).contains(y) {
                outside += 1
                if pixel(pixels, width: width, x: x, y: y) != (sentinel.b, sentinel.g, sentinel.r) { changedOutside += 1 }
            }
        }
        #expect(outside > 0)
        #expect(changedOutside == 0, "\(changedOutside) of \(outside) pixels outside the pane changed")

        // Inside, the pane's grid starts at the rect's corner: its top-left cell is the theme
        // background (the bold "b" of row 0 does not reach the cell's corner).
        let background = RGB(packed: fixture.surface.colors.background).bytes
        #expect(pixel(pixels, width: width, x: rect.x, y: rect.y) == (background.b, background.g, background.r))
        fixture.expectNoValidationErrors()
    }

    /// Panes drawn side by side through viewport and scissor are the frames each pane draws alone
    /// into a target of its own. Not byte for byte away from the origin: the rasterizer evaluates
    /// varyings at framebuffer coordinates, so an offset pane's analytic coverage (underlines, the
    /// curly wave) can round one LSB the other way. Measured on lavapipe: 320 pixels of a 40×9
    /// pane, all ±1. That is the conformance bound (WOR-313 S3), and pane offsets do not exist on
    /// the Mac, where every pane has a layer of its own.
    @Test("four panes tiled into one target match the whole-target frame within ±1, and a dirty pane leaves the others' bytes alone")
    func panesMatchWholeTargetFrames() throws {
        let fixture = try RendererFixture()
        let paneWidth = Int(fixture.target.width), paneHeight = Int(fixture.target.height)

        // The reference: the screen alone, the whole target.
        try fixture.renderAndWait()
        let reference = try fixture.target.bgraBytes()

        // The same screen in each quadrant of a 2×2 target, every pane its own surface.
        let shared = try OffscreenTarget(device: fixture.device, width: UInt32(paneWidth * 2), height: UInt32(paneHeight * 2))
        let panes = try fixture.makeSurfaces(4)
        let rects = (0..<4).map { PixelRect(x: ($0 % 2) * paneWidth, y: ($0 / 2) * paneHeight, width: paneWidth, height: paneHeight) }
        for (pane, rect) in zip(panes, rects) {
            #expect(try fixture.renderer.render(surface: pane.surface, to: shared, in: rect).didEncode)
        }
        let tiled = try shared.bgraBytes()
        let panePixels = rects.map { crop(tiled, width: paneWidth * 2, to: $0) }
        #expect(difference(panePixels[0], reference, width: paneWidth) == nil, "at the origin the pane is the whole-target frame")
        for (pixels, rect) in zip(panePixels, rects) {
            let delta = maxChannelDelta(pixels, reference)
            #expect(delta <= 1, "pane at \(rect): \(difference(pixels, reference, width: paneWidth) ?? "")")
        }

        // Dirtying one pane redraws that pane only; the others' pixels stay exactly as they were.
        fixture.renderer.resetStats()
        panes[3].session.write(ptyText: "\u{1b}[2J\u{1b}[H")
        for (pane, rect) in zip(panes, rects) {
            _ = try fixture.renderer.render(surface: pane.surface, to: shared, in: rect)
        }
        #expect(fixture.renderer.stats.framesEncoded == 1)
        #expect(fixture.renderer.stats.framesSkipped == 3)
        let after = try shared.bgraBytes()
        for (pixels, rect) in zip(panePixels, rects).prefix(3) {
            let difference = difference(crop(after, width: paneWidth * 2, to: rect), pixels, width: paneWidth)
            #expect(difference == nil, "untouched pane at \(rect): \(difference ?? "")")
        }
        #expect(difference(crop(after, width: paneWidth * 2, to: rects[3]), panePixels[3], width: paneWidth) != nil,
                "the cleared pane was redrawn")
        fixture.expectNoValidationErrors()
    }
}

// MARK: - GPU time

@Suite("Vulkan renderer: GPU frame timer", .serialized,
       .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
struct VulkanFrameTimerTests {

    /// `bench-frame`'s GPU time (WOR-313 S6): a timestamp pair around each encoded frame, and none
    /// for a frame that drew nothing.
    @Test("an encoded frame has a GPU time; a skipped frame and a frame without a target have none")
    func encodedFramesAreTimed() throws {
        let fixture = try RendererFixture()
        let timer = try GPUFrameTimer(device: fixture.device)
        #expect(timer.period > 0 && timer.validBits > 0)
        fixture.renderer.frameTimer = timer

        try fixture.renderAndWait()
        let first = try #require(try timer.elapsed())
        #expect(first > 0 && first < 1e9, "a 40×9 frame takes well under a second: \(first) ns")
        #expect(try timer.elapsed() == nil, "each frame's time is read once")

        _ = try fixture.renderer.render(surface: fixture.surface, to: fixture.target)
        #expect(try timer.elapsed() == nil, "an idle frame records no timestamps")

        fixture.session.write(ptyText: "x")
        let target = fixture.target
        let starved = try fixture.renderer.render(
            surface: fixture.surface, targetWidth: Int(target.width), targetHeight: Int(target.height)) { nil }
        #expect(!starved.didEncode)
        _ = try target.bgraBytes()  // waits for the submitted slot
        #expect(try timer.elapsed() == nil, "a frame that found no target has only its first timestamp")

        try fixture.renderAndWait()
        #expect(try timer.elapsed() != nil)
        fixture.renderer.frameTimer = nil
        fixture.expectNoValidationErrors()
    }
}
