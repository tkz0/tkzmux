// VulkanInterop — the small helpers every Vulkan call site in TkzRenderVK uses (WOR-313 S1).
//
//   VulkanError / vkCheck     a failed `VkResult` as a Swift error, naming the call
//   VulkanChain               a pNext chain whose structs live on the heap until it is dropped, so
//                             building one needs no nested `withUnsafe…` scopes
//   instanceProc / deviceProc extension entry points through `vkGet{Instance,Device}ProcAddr`,
//                             cast to their PFN type with `unsafeBitCast`
//   fixedString               a `char[N]` field (device and layer names) as a String
//   withCStrings              a [String] as `const char *const *` for create-info name lists
//
// Core 1.3 commands (vkCmdBeginRendering, vkQueueSubmit2, …) are exported by the loader and are
// called directly; only extension commands go through the proc helpers.

import CVulkan
import Glibc

/// A Vulkan call that did not return `VK_SUCCESS`.
public struct VulkanError: Error, Sendable, Equatable, CustomStringConvertible {
    public var operation: String
    public var result: Int32

    public init(_ operation: String, _ result: VkResult) {
        self.operation = operation
        self.result = result.rawValue
    }

    public var description: String { "\(operation) failed (VkResult \(result))" }
}

/// Throws unless `result` is `VK_SUCCESS`.
@inline(__always)
func vkCheck(_ result: VkResult, _ operation: @autoclosure () -> String) throws(VulkanError) {
    guard result == VK_SUCCESS else { throw VulkanError(operation(), result) }
}

/// A pNext chain built front to back. Each `append` copies the struct to the heap and links it
/// after the previous one; `head` is what the parent struct's `pNext` takes. The returned pointer
/// stays valid until the chain is dropped, which is how an output struct (a property or feature
/// query) is read back. Every Vulkan struct begins `{ VkStructureType sType; void *pNext; }`, so
/// the link is written through `VkBaseOutStructure`'s layout.
struct VulkanChain: ~Copyable {
    private var nodes: [(pointer: UnsafeMutableRawPointer, release: (UnsafeMutableRawPointer) -> Void)] = []

    init() {}

    /// The first struct, or nil for an empty chain.
    var head: UnsafeMutableRawPointer? { nodes.first?.pointer }

    @discardableResult
    mutating func append<Struct>(_ value: Struct) -> UnsafeMutablePointer<Struct> {
        let pointer = UnsafeMutablePointer<Struct>.allocate(capacity: 1)
        pointer.initialize(to: value)
        let raw = UnsafeMutableRawPointer(pointer)
        raw.storeBytes(of: nil, toByteOffset: Self.pNextOffset, as: UnsafeMutableRawPointer?.self)
        if let last = nodes.last {
            last.pointer.storeBytes(of: raw, toByteOffset: Self.pNextOffset, as: UnsafeMutableRawPointer?.self)
        }
        nodes.append((raw, { $0.assumingMemoryBound(to: Struct.self).deinitialize(count: 1).deallocate() }))
        return pointer
    }

    deinit {
        for node in nodes { node.release(node.pointer) }
    }

    private static let pNextOffset = MemoryLayout<VkBaseOutStructure>.offset(of: \.pNext)!
}

/// An instance-level entry point, or nil when neither the instance nor an enabled layer has it.
func instanceProc<Function>(_ instance: VkInstance?, _ name: String, as type: Function.Type) -> Function? {
    guard let address = vkGetInstanceProcAddr(instance, name) else { return nil }
    return unsafeBitCast(address, to: Function.self)
}

/// A device-level entry point, or nil when the device did not enable its extension.
func deviceProc<Function>(_ device: VkDevice, _ name: String, as type: Function.Type) -> Function? {
    guard let address = vkGetDeviceProcAddr(device, name) else { return nil }
    return unsafeBitCast(address, to: Function.self)
}

/// A NUL-terminated `char[N]` field, imported as a tuple, as a String.
func fixedString<Tuple>(_ tuple: Tuple) -> String {
    withUnsafeBytes(of: tuple) { bytes in
        let length = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<length], as: UTF8.self)
    }
}

/// Calls `body` with `strings` as an array of C strings that lives for the call.
func withCStrings<Result>(
    _ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) throws -> Result
) rethrows -> Result {
    let copies = strings.map { strdup($0) }
    defer { copies.forEach { free($0) } }
    let pointers = copies.map { $0.map { UnsafePointer<CChar>($0) } }
    return try pointers.withUnsafeBufferPointer { try body($0.baseAddress) }
}
