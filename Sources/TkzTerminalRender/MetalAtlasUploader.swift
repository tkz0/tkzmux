// MetalAtlasUploader — the Metal side of the glyph atlases (M1.4; split out in WOR-311 S3).
//
// TkzRenderCore's `GlyphAtlas` packs into a CPU staging buffer and keeps one dirty bounding box.
// This owns the two `MTLTexture`s that mirror a `GlyphCache`'s atlases: once per frame, before
// encoding, `upload(_:)` copies each atlas's dirty box with a single `replace(region:)`. When an
// atlas has grown it first swaps in a texture of the new size; the grow already marked the whole
// atlas dirty, so the same call fills it.
//
// The CoreGraphics dump `tkzmux-vtdump atlas` writes lives here too, reading the same staging bytes.

import CoreGraphics
import Foundation
import Metal
import TkzRenderCore

extension AtlasKind {
    public var pixelFormat: MTLPixelFormat { self == .grayscale ? .r8Unorm : .bgra8Unorm }
}

/// The GPU copies of one `GlyphCache`'s atlases. Owned by the `TerminalRenderer` that draws with
/// the cache.
///
/// Not `Sendable` (`MTLTexture` is not); lives on the render thread.
public final class MetalAtlasUploader {
    public let device: MTLDevice
    /// The grayscale atlas texture, `r8Unorm`. Replaced when the atlas grows.
    public private(set) var grayscale: MTLTexture
    /// The colour atlas texture, `bgra8Unorm`. Replaced when the atlas grows.
    public private(set) var color: MTLTexture

    /// Textures at the cache's current atlas sizes, or `nil` when the device cannot allocate them.
    public init?(device: MTLDevice, cache: GlyphCache) {
        guard let grayscale = MetalAtlasUploader.makeTexture(
                  device: device, kind: .grayscale, size: cache.grayscale.size),
              let color = MetalAtlasUploader.makeTexture(
                  device: device, kind: .color, size: cache.color.size)
        else { return nil }
        self.device = device
        self.grayscale = grayscale
        self.color = color
    }

    public func texture(for kind: AtlasKind) -> MTLTexture {
        kind == .grayscale ? grayscale : color
    }

    private static func makeTexture(device: MTLDevice, kind: AtlasKind, size: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: kind.pixelFormat, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: - Upload

    /// Uploads everything staged since the last call, one `replace(region:)` per atlas.
    /// Call once per frame, before encoding.
    public func upload(_ cache: GlyphCache) {
        upload(cache.grayscale, into: &grayscale)
        upload(cache.color, into: &color)
    }

    private func upload(_ atlas: GlyphAtlas, into texture: inout MTLTexture) {
        if texture.width != atlas.size {
            // The atlas grew. Until a texture of the new size exists, keep the pixels pending: the
            // old texture is too small to take them.
            guard let grown = MetalAtlasUploader.makeTexture(
                device: device, kind: atlas.kind, size: atlas.size) else { return }
            texture = grown
        }
        guard let region = atlas.takePendingRegion(), region.width > 0, region.height > 0 else { return }
        let bpp = atlas.kind.bytesPerPixel
        let stride = atlas.bytesPerRow
        let target = texture
        atlas.staging.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            target.replace(
                region: MTLRegionMake2D(region.x, region.y, region.width, region.height),
                mipmapLevel: 0,
                withBytes: base.advanced(by: region.y * stride + region.x * bpp),
                bytesPerRow: stride)
        }
    }
}

// MARK: - Dump

extension GlyphAtlas {
    /// The whole atlas as a `CGImage`, for `tkzmux-vtdump atlas --png`.
    public func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(staging) as CFData) else { return nil }
        if kind == .color {
            return CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PNG bytes of the whole atlas.
    public func pngData() -> Data? {
        guard let image = makeCGImage() else { return nil }
        return GlyphRasterizer.pngData(from: image)
    }
}
