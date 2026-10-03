// DmabufFormat — DRM formats and modifiers, and the negotiation of the modifier the presentation
// ring's images are made with (WOR-313 S5a).
//
// The consumer (GTK through `gdk_display_get_dmabuf_formats`, WOR-314) offers a list of
// `(fourcc, modifier)` pairs it can import. The device reports, per modifier of
// B8G8R8A8_UNORM, how many memory planes it has, what the tiling can do, and whether an image of
// that modifier can be exported as a dma-buf at the window's size. The modifiers an image may be
// created with are the intersection, in the device's order; the driver picks one of them at
// `vkCreateImage` (VkImageDrmFormatModifierListCreateInfoEXT).
//
// Both fourccs tkzmux presents are B8G8R8A8_UNORM in memory (little-endian B, G, R, A/X bytes):
// XRGB8888 for the opaque window, ARGB8888 for a translucent one. The image is the same; only
// what the consumer does with the fourth byte differs.
//
// Pure: no Vulkan calls (`PresentationRing` gathers the device side), so the tests cover it
// without a GPU. The implicit modifier (DRM_FORMAT_MOD_INVALID) never takes part: Vulkan never
// reports it, and creating an image for it is the fallback ladder's business (WOR-313 S5b).

/// A DRM fourcc (`drm_fourcc.h`), built from its four characters like `fourcc_code`.
public struct DRMFourCC: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// `fourcc_code(a, b, c, d)`: the first character in the low byte.
    public init(_ code: StaticString) {
        precondition(code.utf8CodeUnitCount == 4, "a fourcc has four characters")
        let bytes = UnsafeBufferPointer(start: code.utf8Start, count: 4)
        rawValue = bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// `DRM_FORMAT_XRGB8888`: B, G, R, X in memory. The opaque window.
    public static let xrgb8888 = DRMFourCC("XR24")
    /// `DRM_FORMAT_ARGB8888`: B, G, R, A in memory, premultiplied for GTK.
    public static let argb8888 = DRMFourCC("AR24")

    /// The fourccs a B8G8R8A8_UNORM image can be presented as.
    public static let b8g8r8a8 = [xrgb8888, argb8888]

    public var description: String {
        let characters = (0..<4).map { Character(UnicodeScalar(UInt8(truncatingIfNeeded: rawValue >> ($0 * 8)))) }
        return String(characters)
    }
}

/// DRM format modifiers with a meaning of their own (`drm_fourcc.h`).
public enum DRMModifier {
    /// `DRM_FORMAT_MOD_LINEAR`: plain rows.
    public static let linear: UInt64 = 0
    /// `DRM_FORMAT_MOD_INVALID`: "whatever the driver does without modifiers" (implicit).
    public static let invalid: UInt64 = 0x00ff_ffff_ffff_ffff

    /// `0x020000000056bb03`-style hex, as the dmabuf feedback and `WAYLAND_DEBUG` print them.
    public static func hex(_ modifier: UInt64) -> String {
        let digits = String(modifier, radix: 16)
        return "0x" + String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}

/// One `(fourcc, modifier)` pair a consumer can import, as `gdk_dmabuf_formats_get_format` lists them.
public struct DRMFormat: Hashable, Sendable, CustomStringConvertible {
    public var fourcc: DRMFourCC
    public var modifier: UInt64

    public init(fourcc: DRMFourCC, modifier: UInt64) {
        self.fourcc = fourcc
        self.modifier = modifier
    }

    public var description: String { "\(fourcc):\(DRMModifier.hex(modifier))" }
}

/// What the device can do with one modifier of B8G8R8A8_UNORM, for an image of the ring's usage.
public struct DeviceModifier: Hashable, Sendable {
    public var modifier: UInt64
    /// Memory planes (`drmFormatModifierPlaneCount`): 1 for plain tilings, more with compression
    /// metadata. All of them live in the image's one allocation and are exported through one fd.
    public var planeCount: Int
    /// The tiling has every feature the ring's images use: colour attachment with blending (the
    /// renderer), transfer source (readback) and destination (WOR-313 S5b's copy from the previous
    /// image).
    public var supportsTarget: Bool
    /// `vkGetPhysicalDeviceImageFormatProperties2` accepts an image of this modifier with the
    /// ring's usage and dma-buf export, and says it is exportable.
    public var exportable: Bool
    /// The largest image of this modifier, from the same query (0 when it is not supported).
    public var maxWidth: UInt32
    public var maxHeight: UInt32

    public init(modifier: UInt64, planeCount: Int, supportsTarget: Bool, exportable: Bool,
                maxWidth: UInt32 = .max, maxHeight: UInt32 = .max) {
        self.modifier = modifier
        self.planeCount = planeCount
        self.supportsTarget = supportsTarget
        self.exportable = exportable
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    /// Whether a `width × height` ring image can use it.
    func fits(width: UInt32, height: UInt32) -> Bool {
        supportsTarget && exportable && planeCount >= 1 && planeCount <= DmabufDescription.maxPlanes
            && width <= maxWidth && height <= maxHeight
    }
}

/// Why no modifier was agreed on.
public enum ModifierNegotiationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The fourcc is not one a B8G8R8A8_UNORM image can be presented as.
    case unsupportedFourCC(DRMFourCC)
    /// The consumer offers no explicit modifier for the fourcc that the device can export at this
    /// size. WOR-313 S5b steps down the fallback ladder from here.
    case noCommonModifier(fourcc: DRMFourCC, offered: [UInt64], device: [UInt64])

    public var description: String {
        switch self {
        case .unsupportedFourCC(let fourcc):
            "\(fourcc) is not a B8G8R8A8 layout (XR24 or AR24)"
        case .noCommonModifier(let fourcc, let offered, let device):
            "no common \(fourcc) modifier: the consumer offers [\(offered.map(DRMModifier.hex).joined(separator: " "))], "
                + "the device exports [\(device.map(DRMModifier.hex).joined(separator: " "))]"
        }
    }
}

public enum ModifierNegotiation {
    /// The modifiers a `width × height` image presented as `fourcc` may be created with: those the
    /// consumer offers for `fourcc` and the device can render to and export at that size, in the
    /// device's order, without duplicates. Never empty: no common modifier throws.
    public static func negotiate(
        offered: [DRMFormat], fourcc: DRMFourCC, device: [DeviceModifier], width: UInt32, height: UInt32
    ) throws(ModifierNegotiationError) -> [UInt64] {
        guard DRMFourCC.b8g8r8a8.contains(fourcc) else { throw .unsupportedFourCC(fourcc) }
        let consumer = Set(offered.lazy.filter { $0.fourcc == fourcc && $0.modifier != DRMModifier.invalid }.map(\.modifier))
        var seen = Set<UInt64>()
        let common = device.filter {
            consumer.contains($0.modifier) && $0.fits(width: width, height: height) && seen.insert($0.modifier).inserted
        }.map(\.modifier)
        guard !common.isEmpty else {
            throw .noCommonModifier(
                fourcc: fourcc,
                offered: offered.filter { $0.fourcc == fourcc }.map(\.modifier),
                device: device.filter { $0.fits(width: width, height: height) }.map(\.modifier))
        }
        return common
    }
}

// MARK: - What the consumer imports

/// One memory plane of an exported image: the fd, and where the plane is in it.
public struct DmabufPlane: Hashable, Sendable {
    /// Owned by the ring, shared by every plane of the image, and valid while the ring lives.
    /// A consumer that needs it longer (GDK does not) dups it.
    public var fd: Int32
    public var offset: UInt32
    public var stride: UInt32

    public init(fd: Int32, offset: UInt32, stride: UInt32) {
        self.fd = fd
        self.offset = offset
        self.stride = stride
    }
}

/// Everything `GdkDmabufTextureBuilder` needs for one ring image (WOR-314): size, fourcc,
/// modifier and planes. The pixels are premultiplied, and sRGB-encoded in a UNORM image (never an
/// _SRGB format; parity means identical encoded bytes, ADR-0003).
public struct DmabufDescription: Hashable, Sendable {
    /// `GDK_DMABUF_MAX_PLANES`, and the most any DRM format modifier uses.
    public static let maxPlanes = 4

    public var width: UInt32
    public var height: UInt32
    public var fourcc: DRMFourCC
    public var modifier: UInt64
    public var planes: [DmabufPlane]

    public init(width: UInt32, height: UInt32, fourcc: DRMFourCC, modifier: UInt64, planes: [DmabufPlane]) {
        self.width = width
        self.height = height
        self.fourcc = fourcc
        self.modifier = modifier
        self.planes = planes
    }
}
