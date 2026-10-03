// CanvasTextures — presentation-ring frames as GdkTextures (WOR-314 S4).
//
// A dma-buf frame becomes a GdkDmabufTexture: the ring's fourcc (XRGB8888), modifier and planes,
// premultiplied, sRGB-encoded (a UNORM image holding sRGB bytes; ADR-0003), `pixelWidth ×
// pixelHeight` so the compositor maps it texel for pixel. GDK does not dup the fds: they must stay
// open until the texture's destroy-notify, so each texture holds a `TextureLease` on its ladder,
// and the host keeps the ladder (whose rings own the fds) until every lease is back.
//
// A readback frame (the ladder's last rung) becomes a GdkMemoryTexture over a copy of its bytes,
// B8G8R8A8 premultiplied. It holds no fd and needs no lease.
//
// The lease box is user data GDK owns, like a signal box: retained with `Unmanaged`, released by
// the destroy-notify only, counted in ClosureBoxes (`.texture`).

import CGtk
import Synchronization
import TkzRenderVK

/// How many textures over one ladder's dma-bufs GDK has not finalized yet. Any thread: GDK runs a
/// texture's destroy-notify wherever it drops the last reference.
final class TextureLease: Sendable {
    private let live = Atomic<Int>(0)
    /// Called on the main actor after a texture of this lease is finalized.
    private let onRelease: @Sendable @MainActor () -> Void

    init(onRelease: @escaping @Sendable @MainActor () -> Void) {
        self.onRelease = onRelease
    }

    var count: Int { live.load(ordering: .relaxed) }

    fileprivate func retain() { live.add(1, ordering: .relaxed) }

    fileprivate func release() {
        live.subtract(1, ordering: .relaxed)
        let onRelease = onRelease
        Task { @MainActor in onRelease() }
    }
}

/// A texture's destroy-notify data.
private final class TextureBox {
    let lease: TextureLease

    init(_ lease: TextureLease) {
        self.lease = lease
        lease.retain()
        ClosureBoxes.created(.texture)
    }

    deinit {
        ClosureBoxes.destroyed(.texture)
        lease.release()
    }
}

/// The destroy-notify: the box's only release.
private let releaseTextureBox: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
    Unmanaged<TextureBox>.fromOpaque(data!).release()
}

/// Why a frame could not become a texture.
struct TextureImportError: Error, CustomStringConvertible {
    var description: String
}

@MainActor
enum CanvasTextures {
    /// A GdkDmabufTexture for `dmabuf` on `display` (a `GdkDisplay *`), holding `lease` until GDK
    /// finalizes it.
    static func dmabufTexture(_ dmabuf: DmabufDescription, display: OpaquePointer,
                              lease: TextureLease) throws -> GObjectRef<OpaquePointer> {
        let builder = gdk_dmabuf_texture_builder_new()!
        defer { g_object_unref(UnsafeMutableRawPointer(builder)) }
        gdk_dmabuf_texture_builder_set_display(builder, display)
        gdk_dmabuf_texture_builder_set_width(builder, dmabuf.width)
        gdk_dmabuf_texture_builder_set_height(builder, dmabuf.height)
        gdk_dmabuf_texture_builder_set_fourcc(builder, dmabuf.fourcc.rawValue)
        gdk_dmabuf_texture_builder_set_modifier(builder, guint64(dmabuf.modifier))
        gdk_dmabuf_texture_builder_set_n_planes(builder, UInt32(dmabuf.planes.count))
        for (index, plane) in dmabuf.planes.enumerated() {
            gdk_dmabuf_texture_builder_set_fd(builder, UInt32(index), plane.fd)
            gdk_dmabuf_texture_builder_set_offset(builder, UInt32(index), plane.offset)
            gdk_dmabuf_texture_builder_set_stride(builder, UInt32(index), plane.stride)
        }
        gdk_dmabuf_texture_builder_set_premultiplied(builder, 1)
        gdk_dmabuf_texture_builder_set_color_state(builder, gdk_color_state_get_srgb())

        // GDK calls the destroy-notify only for a texture it made. The local reference tells the
        // two cases apart after a failure: still shared means the notify never ran.
        var box = TextureBox(lease)
        let data = Unmanaged.passRetained(box).toOpaque()
        var error: UnsafeMutablePointer<GError>?
        guard let texture = gdk_dmabuf_texture_builder_build(builder, releaseTextureBox, data, &error) else {
            if !isKnownUniquelyReferenced(&box) { Unmanaged<TextureBox>.fromOpaque(data).release() }
            let message = error.flatMap { $0.pointee.message.map { String(cString: $0) } } ?? "no reason given"
            if let error { g_error_free(error) }
            throw TextureImportError(description: "gdk_dmabuf_texture_builder_build: \(message)")
        }
        return GObjectRef(adopting: texture)
    }

    /// A GdkMemoryTexture over a copy of `frame`'s bytes.
    static func memoryTexture(_ frame: ReadbackFrame) -> GObjectRef<OpaquePointer> {
        let bytes = frame.bytes.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        let texture = gdk_memory_texture_new(Int32(frame.width), Int32(frame.height), GDK_MEMORY_B8G8R8A8_PREMULTIPLIED,
                                             bytes, gsize(frame.width) * 4)!
        return GObjectRef(adopting: texture)
    }
}
