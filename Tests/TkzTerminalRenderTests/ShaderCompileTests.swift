// ShaderCompileTests — the shader half of M1.5 (TKZ-11), verified without a renderer.
//
// Three things are proven here:
//   1. Swift's view of TkzShaderTypes.h matches, field for field, the `_Static_assert`s the C and
//      Metal compilers check. Swift, C and Metal cannot silently disagree about a struct layout.
//   2. `Resources/Shaders/Terminal.metal` compiles at *runtime* through
//      `device.makeLibrary(source:)` — the fallback path design.md requires when a hand-built
//      `default.metallib` is absent (`swift run`, `swift test`) — and every entry point exists.
//   3. All three pipelines build with the real pixel format and blend state, and the background
//      pipeline actually rasterises the grid correctly into an offscreen `.bgra8Unorm` texture.
//
// Every test creates its own `MTLDevice` (no shared state under strict concurrency) and returns
// early when there is no GPU. Swift Testing has no "skip", so a headless machine reports these as
// passing-but-empty; the layout tests below need no device and always run.

import Foundation
import Metal
import Testing
import TkzShaderTypes

// MARK: - Loading the shader source the way the renderer must

/// TkzTerminalRender's resource bundle. `Bundle.module` inside this *test* target resolves to
/// `tkzmux_TkzTerminalRenderTests.bundle`; the renderer's bundle is its sibling. Inside
/// `TkzTerminalRender` itself the renderer just uses `Bundle.module` directly.
private func renderResourceBundle() throws -> Bundle {
    let neighbours = Bundle.module.bundleURL.deletingLastPathComponent()
    let direct = neighbours.appendingPathComponent("tkzmux_TkzTerminalRender.bundle")
    if let bundle = Bundle(url: direct) { return bundle }

    // Fall back to a scan, so a change in SwiftPM's bundle-naming scheme is a clear failure and
    // not a mysterious nil.
    let candidates = try FileManager.default.contentsOfDirectory(
        at: neighbours, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasSuffix("TkzTerminalRender.bundle") }
    guard let url = candidates.first, let bundle = Bundle(url: url) else {
        struct MissingBundle: Error { let searched: URL }
        throw MissingBundle(searched: neighbours)
    }
    return bundle
}

private func resourceText(_ name: String, in bundle: Bundle) throws -> String {
    guard let url = bundle.url(forResource: "Shaders/\(name)", withExtension: nil) else {
        struct MissingResource: Error { let name: String }
        throw MissingResource(name: name)
    }
    return try String(contentsOf: url, encoding: .utf8)
}

/// Assemble the source for `device.makeLibrary(source:)`.
///
/// `makeLibrary(source:)` has no include search path and no file on disk to resolve `#include
/// "TkzShaderTypes.h"` against, so the header text is prepended. Terminal.metal guards its include
/// with `#if !defined(TKZ_SHADER_TYPES_H)`, which is exactly why the header uses a classic include
/// guard instead of `#pragma once` — a `#pragma once` sets no macro and the guard could not fire.
/// The `#line` directive keeps compiler diagnostics pointing at real Terminal.metal line numbers.
///
/// This is the function `TerminalRenderer` should mirror when `default.metallib` is missing.
func tkzTerminalShaderSource(in bundle: Bundle) throws -> String {
    let header = try resourceText("TkzShaderTypes.h", in: bundle)
    let shader = try resourceText("Terminal.metal", in: bundle)
    return header + "\n#line 1 \"Terminal.metal\"\n" + shader
}

// MARK: - Layout

@Suite("Shader struct layout")
struct ShaderLayoutTests {
    // The literals below are duplicated from the TKZ_STATIC_ASSERTs at the bottom of
    // TkzShaderTypes.h. If one side changes, this fails before anything renders.

    @Test func uniformsLayoutMatchesTheCHeader() {
        #expect(MemoryLayout<TkzUniforms>.size == 80)
        #expect(MemoryLayout<TkzUniforms>.stride == 80)
        #expect(MemoryLayout<TkzUniforms>.alignment == 8)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.viewportSizePx) == 0)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.cellSizePx) == 8)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.gridOriginPx) == 16)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.grayscaleAtlasSizePx) == 24)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.colorAtlasSizePx) == 32)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.gridSize) == 40)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.defaultBackground) == 48)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.defaultForeground) == 52)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.cursorColor) == 56)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.cursorTextColor) == 60)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.minContrast) == 64)
        #expect(MemoryLayout<TkzUniforms>.offset(of: \.reserved0) == 68)
    }

    @Test func bgCellLayoutMatchesTheCHeader() {
        #expect(MemoryLayout<TkzBgCell>.size == 4)
        #expect(MemoryLayout<TkzBgCell>.stride == 4)
        #expect(MemoryLayout<TkzBgCell>.alignment == 4)
        #expect(MemoryLayout<TkzBgCell>.offset(of: \.color) == 0)
    }

    @Test func glyphInstanceLayoutMatchesTheCHeader() {
        #expect(MemoryLayout<TkzGlyphInstance>.size == 32)
        #expect(MemoryLayout<TkzGlyphInstance>.stride == 32)
        #expect(MemoryLayout<TkzGlyphInstance>.alignment == 4)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.gridPos) == 0)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.offsetPx) == 4)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.sizePx) == 8)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.atlasPos) == 12)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.color) == 16)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.bgColor) == 20)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.flags) == 24)
        #expect(MemoryLayout<TkzGlyphInstance>.offset(of: \.reserved0) == 28)
    }

    @Test func rectInstanceLayoutMatchesTheCHeader() {
        #expect(MemoryLayout<TkzRectInstance>.size == 32)
        #expect(MemoryLayout<TkzRectInstance>.stride == 32)
        #expect(MemoryLayout<TkzRectInstance>.alignment == 8)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.originPx) == 0)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.sizePx) == 8)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.color) == 16)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.style) == 20)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.thicknessPx) == 24)
        #expect(MemoryLayout<TkzRectInstance>.offset(of: \.reserved0) == 28)
    }

    /// The binding contract and the flag bits are part of the header, so pin them here too: a
    /// renumbering would otherwise only show up as a blank terminal.
    @Test func bindingContractIsStable() {
        #expect(TKZ_BUFFER_INDEX_UNIFORMS == 0)
        #expect(TKZ_BUFFER_INDEX_INSTANCES == 1)
        #expect(TKZ_TEXTURE_INDEX_GRAYSCALE == 0)
        #expect(TKZ_TEXTURE_INDEX_COLOR == 1)

        #expect(TKZ_GLYPH_FLAG_COLOR == 1)
        #expect(TKZ_GLYPH_FLAG_UNDER_CURSOR == 2)
        #expect(TKZ_GLYPH_FLAG_MIN_CONTRAST == 4)
        #expect(TKZ_GLYPH_FLAG_WIDE == 8)

        #expect(TKZ_RECT_STYLE_SOLID == 0)
        #expect(TKZ_RECT_STYLE_HOLLOW == 1)
        #expect(TKZ_RECT_STYLE_UNDERLINE_SINGLE == 2)
        #expect(TKZ_RECT_STYLE_UNDERLINE_DOUBLE == 3)
        #expect(TKZ_RECT_STYLE_UNDERLINE_CURLY == 4)
        #expect(TKZ_RECT_STYLE_UNDERLINE_DOTTED == 5)
        #expect(TKZ_RECT_STYLE_UNDERLINE_DASHED == 6)
        #expect(TKZ_RECT_STYLE_STRIKETHROUGH == 7)
        #expect(TKZ_RECT_STYLE_COUNT == 8)
    }
}

// MARK: - Source integrity

@Suite("Shader source resources")
struct ShaderResourceTests {
    /// The bundled header must stay byte-identical to the canonical one the C target and
    /// `xcrun metal -I` compile. It is a copy and not a symlink because SwiftPM reproduces symlinks
    /// verbatim inside the resource bundle, where the relative target no longer resolves.
    @Test func bundledHeaderIsIdenticalToThisOne() throws {
        let bundled = try resourceText("TkzShaderTypes.h", in: renderResourceBundle())

        // #filePath = <repo>/Tests/TkzTerminalRenderTests/ShaderCompileTests.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TkzTerminalRenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo>
        let canonicalURL = repoRoot
            .appendingPathComponent("Sources/TkzShaderTypes/include/TkzShaderTypes.h")
        let canonical = try String(contentsOf: canonicalURL, encoding: .utf8)

        #expect(bundled == canonical, """
            The bundled copy of TkzShaderTypes.h has drifted from the canonical header. Run:
              cp Sources/TkzShaderTypes/include/TkzShaderTypes.h \
            Sources/TkzTerminalRender/Resources/Shaders/TkzShaderTypes.h
            """)
    }

    /// Terminal.metal must keep its include guarded, or the runtime-source path breaks with
    /// "'TkzShaderTypes.h' file not found" the moment `default.metallib` is missing.
    @Test func shaderGuardsItsIncludeForTheRuntimePath() throws {
        let shader = try resourceText("Terminal.metal", in: renderResourceBundle())
        #expect(shader.contains("#if !defined(TKZ_SHADER_TYPES_H)"))
        #expect(shader.contains("#include \"TkzShaderTypes.h\""))
    }
}

// MARK: - Compilation and pipelines

@Suite("Metal shader compilation")
struct ShaderCompileTests {
    private static let functionNames = [
        TKZ_FN_BG_VERTEX, TKZ_FN_BG_FRAGMENT,
        TKZ_FN_RECT_VERTEX, TKZ_FN_RECT_FRAGMENT,
        TKZ_FN_GLYPH_VERTEX, TKZ_FN_GLYPH_FRAGMENT,
    ]

    /// The `.bgra8Unorm`, premultiplied-alpha state every pipeline in the renderer uses.
    /// `vertexDescriptor` deliberately stays nil: quads come from `[[vertex_id]]`/`[[instance_id]]`.
    private static func pipelineDescriptor(
        vertex: MTLFunction, fragment: MTLFunction, blending: Bool
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.vertexDescriptor = nil
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = blending
        if blending {
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return descriptor
    }

    @Test func compilesFromSourceAtRuntimeAndExposesEveryEntryPoint() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }  // no GPU: nothing to prove
        let source = try tkzTerminalShaderSource(in: renderResourceBundle())

        let library = try device.makeLibrary(source: source, options: nil)
        for name in Self.functionNames {
            #expect(library.makeFunction(name: name) != nil, "missing entry point \(name)")
        }
    }

    @Test func buildsAllThreePipelineStates() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try device.makeLibrary(
            source: tkzTerminalShaderSource(in: renderResourceBundle()), options: nil
        )

        // Background: no blending — it paints every pixel of the drawable, opaque.
        let bg = try #require(library.makeFunction(name: TKZ_FN_BG_VERTEX))
        let bgFragment = try #require(library.makeFunction(name: TKZ_FN_BG_FRAGMENT))
        _ = try device.makeRenderPipelineState(
            descriptor: Self.pipelineDescriptor(vertex: bg, fragment: bgFragment, blending: false)
        )

        // Rects and glyphs: premultiplied blending over whatever is already there.
        for (vertexName, fragmentName) in [
            (TKZ_FN_RECT_VERTEX, TKZ_FN_RECT_FRAGMENT),
            (TKZ_FN_GLYPH_VERTEX, TKZ_FN_GLYPH_FRAGMENT),
        ] {
            let vertex = try #require(library.makeFunction(name: vertexName))
            let fragment = try #require(library.makeFunction(name: fragmentName))
            _ = try device.makeRenderPipelineState(
                descriptor: Self.pipelineDescriptor(
                    vertex: vertex, fragment: fragment, blending: true
                )
            )
        }
    }

    /// Actually rasterise the background pass into a 4×4 `.bgra8Unorm` texture with a 2×2 grid of
    /// 2×2-pixel cells, and read the pixels back. This proves the cell-index arithmetic, the
    /// top-left/+y-down convention and the full-screen triangle all agree — the parts a "does it
    /// compile" test cannot reach.
    @Test func backgroundPassRasterisesTheCellGrid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        guard let queue = device.makeCommandQueue() else { return }

        let library = try device.makeLibrary(
            source: tkzTerminalShaderSource(in: renderResourceBundle()), options: nil
        )
        let pipeline = try device.makeRenderPipelineState(
            descriptor: Self.pipelineDescriptor(
                vertex: try #require(library.makeFunction(name: TKZ_FN_BG_VERTEX)),
                fragment: try #require(library.makeFunction(name: TKZ_FN_BG_FRAGMENT)),
                blending: false
            )
        )

        let side = 4
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: textureDescriptor))

        var uniforms = TkzUniforms()
        uniforms.viewportSizePx = SIMD2<Float>(Float(side), Float(side))
        uniforms.cellSizePx = SIMD2<Float>(2, 2)
        uniforms.gridOriginPx = SIMD2<Float>(0, 0)
        uniforms.gridSize = SIMD2<UInt32>(2, 2)
        uniforms.defaultBackground = 0xFF00_0000          // opaque black
        uniforms.minContrast = 1

        // Row-major: (0,0) red, (1,0) green, (0,1) blue, (1,1) transparent → theme background.
        let cells = [
            TkzBgCell(color: 0xFF00_00FF),  // a=FF b=00 g=00 r=FF
            TkzBgCell(color: 0xFF00_FF00),
            TkzBgCell(color: 0xFFFF_0000),
            TkzBgCell(color: 0x0000_0000),
        ]

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store

        let buffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(buffer.makeRenderCommandEncoder(descriptor: descriptor))
        encoder.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: &uniforms) { raw in
            encoder.setFragmentBytes(
                raw.baseAddress!, length: raw.count, index: Int(TKZ_BUFFER_INDEX_UNIFORMS)
            )
        }
        cells.withUnsafeBytes { raw in
            encoder.setFragmentBytes(
                raw.baseAddress!, length: raw.count, index: Int(TKZ_BUFFER_INDEX_INSTANCES)
            )
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.error == nil)

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(
                raw.baseAddress!, bytesPerRow: side * 4,
                from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0
            )
        }

        /// `.bgra8Unorm` read-back order is B, G, R, A.
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = (y * side + x) * 4
            return Array(pixels[offset ..< offset + 4])
        }

        #expect(pixel(0, 0) == [0x00, 0x00, 0xFF, 0xFF], "cell (0,0) should be red")
        #expect(pixel(1, 1) == [0x00, 0x00, 0xFF, 0xFF], "cell (0,0) covers 2x2 pixels")
        #expect(pixel(2, 0) == [0x00, 0xFF, 0x00, 0xFF], "cell (1,0) should be green")
        #expect(pixel(0, 2) == [0xFF, 0x00, 0x00, 0xFF], "cell (0,1) should be blue — +y is down")
        #expect(pixel(3, 3) == [0x00, 0x00, 0x00, 0xFF], "alpha 0 falls back to defaultBackground")
    }
}
