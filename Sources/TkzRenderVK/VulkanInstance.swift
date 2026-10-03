// VulkanInstance — the Vulkan 1.3 instance, its validation layer and debug messenger (WOR-313 S1).
//
// Validation is opt-in per instance: tests turn it on wherever the Khronos layer is installed, and
// CI (TKZMUX_REQUIRE_VULKAN=1) requires it. The VK_EXT_debug_utils messenger is installed whenever
// the loader offers the extension (it always does: the loader implements it), with or without the
// layer, and counts every warning and error into a `ValidationLog` that tests assert on.
//
// The instance owns its messenger and log; `VulkanDevice` keeps the instance alive.

import CVulkan
import Synchronization
import TkzPlatform

let vulkanLog = TkzLogger(subsystem: "se.tkz.tkzmux", category: "gpu")

/// Warnings and errors the debug messenger saw. The messenger can be called from any thread the
/// driver or layer uses, so the counts sit behind a `Mutex`.
public final class ValidationLog: Sendable {
    public struct Message: Sendable, Equatable {
        public var isError: Bool
        public var id: String
        public var text: String
    }

    private struct State {
        var errors = 0
        var warnings = 0
        var messages: [Message] = []
    }

    private let state = Mutex(State())

    /// The first messages are kept for test diagnostics; the counts keep going.
    static let keptMessages = 32

    public init() {}

    public var errorCount: Int { state.withLock { $0.errors } }
    public var warningCount: Int { state.withLock { $0.warnings } }
    public var messages: [Message] { state.withLock { $0.messages } }

    func record(_ message: Message) {
        state.withLock { state in
            if message.isError { state.errors += 1 } else { state.warnings += 1 }
            if state.messages.count < Self.keptMessages { state.messages.append(message) }
        }
    }
}

public final class VulkanInstance {
    /// Whether to load VK_LAYER_KHRONOS_validation.
    public enum Validation: Sendable {
        case off
        /// When the layer is installed.
        case ifAvailable
        /// Throws when the layer is missing.
        case required
    }

    public static let validationLayer = "VK_LAYER_KHRONOS_validation"

    public let handle: VkInstance
    public let validationLog = ValidationLog()
    /// Whether the validation layer is loaded (so a zero error count means something).
    public let validationEnabled: Bool
    /// The loader's own version (`vkEnumerateInstanceVersion`).
    public let loaderVersion: VulkanVersion
    /// How long `vkCreateInstance` took. The loader reads every ICD manifest and loads each driver
    /// here, so this is most of the GPU start-up cost (docs/linux/perf-budgets.md).
    public let creationNanoseconds: UInt64

    private var messenger: VkDebugUtilsMessengerEXT?
    private let destroyMessenger: PFN_vkDestroyDebugUtilsMessengerEXT?

    public init(validation: Validation = .off, applicationName: String = "tkzmux") throws {
        var version: UInt32 = 0
        try vkCheck(vkEnumerateInstanceVersion(&version), "vkEnumerateInstanceVersion")
        loaderVersion = VulkanVersion(raw: version)
        guard loaderVersion.isAtLeast(.required) else {
            throw VulkanError("vkEnumerateInstanceVersion (loader \(loaderVersion) < 1.3)", VK_ERROR_INCOMPATIBLE_DRIVER)
        }

        let layers = Set(try Self.availableLayers())
        let extensions = Set(try Self.availableInstanceExtensions())
        let wantValidation: Bool
        switch validation {
        case .off: wantValidation = false
        case .ifAvailable: wantValidation = layers.contains(Self.validationLayer)
        case .required:
            guard layers.contains(Self.validationLayer) else {
                throw VulkanError("loading \(Self.validationLayer) (not installed)", VK_ERROR_LAYER_NOT_PRESENT)
            }
            wantValidation = true
        }
        let debugUtils = extensions.contains(VK_EXT_DEBUG_UTILS_EXTENSION_NAME)
        let enabledLayers = wantValidation ? [Self.validationLayer] : []
        let enabledExtensions = debugUtils ? [VK_EXT_DEBUG_UTILS_EXTENSION_NAME] : []

        // Chained into the create info as well, so messages from vkCreateInstance and
        // vkDestroyInstance themselves are counted too.
        let messengerInfo = Self.messengerCreateInfo(log: validationLog)
        var chain = VulkanChain()
        if debugUtils { chain.append(messengerInfo) }

        var instance: VkInstance?
        let start = Clocks.monotonicNanos
        let result = applicationName.withCString { name in
            var app = VkApplicationInfo()
            app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
            app.pApplicationName = name
            app.pEngineName = name
            app.apiVersion = tkz_vk_api_version_1_3()
            return withUnsafePointer(to: &app) { app in
                withCStrings(enabledLayers) { layerNames in
                    withCStrings(enabledExtensions) { extensionNames in
                        var info = VkInstanceCreateInfo()
                        info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                        info.pNext = UnsafeRawPointer(chain.head)
                        info.pApplicationInfo = app
                        info.enabledLayerCount = UInt32(enabledLayers.count)
                        info.ppEnabledLayerNames = layerNames
                        info.enabledExtensionCount = UInt32(enabledExtensions.count)
                        info.ppEnabledExtensionNames = extensionNames
                        return vkCreateInstance(&info, nil, &instance)
                    }
                }
            }
        }
        creationNanoseconds = Clocks.monotonicNanos - start
        try vkCheck(result, "vkCreateInstance")
        guard let instance else { throw VulkanError("vkCreateInstance", VK_ERROR_INITIALIZATION_FAILED) }
        handle = instance
        validationEnabled = wantValidation

        if debugUtils,
           let create = instanceProc(instance, "vkCreateDebugUtilsMessengerEXT", as: PFN_vkCreateDebugUtilsMessengerEXT.self) {
            var info = messengerInfo
            var created: VkDebugUtilsMessengerEXT?
            let status = create(instance, &info, nil, &created)
            // `deinit` does not run for a half-initialized object, so the instance is freed here.
            guard status == VK_SUCCESS else {
                vkDestroyInstance(instance, nil)
                throw VulkanError("vkCreateDebugUtilsMessengerEXT", status)
            }
            messenger = created
            destroyMessenger = instanceProc(instance, "vkDestroyDebugUtilsMessengerEXT", as: PFN_vkDestroyDebugUtilsMessengerEXT.self)
        } else {
            destroyMessenger = nil
        }
    }

    deinit {
        if let messenger, let destroyMessenger { destroyMessenger(handle, messenger, nil) }
        vkDestroyInstance(handle, nil)
    }

    /// Whether the debug messenger is installed.
    public var hasMessenger: Bool { messenger != nil }

    /// The physical devices in loader order.
    public func physicalDevices() throws -> [VkPhysicalDevice] {
        var count: UInt32 = 0
        try vkCheck(vkEnumeratePhysicalDevices(handle, &count, nil), "vkEnumeratePhysicalDevices")
        var devices = [VkPhysicalDevice?](repeating: nil, count: Int(count))
        try vkCheck(vkEnumeratePhysicalDevices(handle, &count, &devices), "vkEnumeratePhysicalDevices")
        return devices.prefix(Int(count)).compactMap { $0 }
    }

    /// Sends a message through the messenger as if a layer had reported it; tests use it to prove
    /// that the count works without needing a real validation error.
    public func submitDebugMessage(_ text: String, error: Bool) {
        guard let submit = instanceProc(handle, "vkSubmitDebugUtilsMessageEXT", as: PFN_vkSubmitDebugUtilsMessageEXT.self) else { return }
        text.withCString { message in
            var data = VkDebugUtilsMessengerCallbackDataEXT()
            data.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CALLBACK_DATA_EXT
            data.pMessage = message
            let severity = error ? VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT : VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
            submit(handle, severity, VkDebugUtilsMessageTypeFlagsEXT(VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT.rawValue), &data)
        }
    }

    // MARK: Enumeration

    public static func availableLayers() throws -> [String] {
        var count: UInt32 = 0
        try vkCheck(vkEnumerateInstanceLayerProperties(&count, nil), "vkEnumerateInstanceLayerProperties")
        var properties = [VkLayerProperties](repeating: VkLayerProperties(), count: Int(count))
        try vkCheck(vkEnumerateInstanceLayerProperties(&count, &properties), "vkEnumerateInstanceLayerProperties")
        return properties.prefix(Int(count)).map { fixedString($0.layerName) }
    }

    public static func availableInstanceExtensions() throws -> [String] {
        var count: UInt32 = 0
        try vkCheck(vkEnumerateInstanceExtensionProperties(nil, &count, nil), "vkEnumerateInstanceExtensionProperties")
        var properties = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
        try vkCheck(vkEnumerateInstanceExtensionProperties(nil, &count, &properties), "vkEnumerateInstanceExtensionProperties")
        return properties.prefix(Int(count)).map { fixedString($0.extensionName) }
    }

    // MARK: Messenger

    private static func messengerCreateInfo(log: ValidationLog) -> VkDebugUtilsMessengerCreateInfoEXT {
        var info = VkDebugUtilsMessengerCreateInfoEXT()
        info.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
        info.messageSeverity = VkDebugUtilsMessageSeverityFlagsEXT(
            VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT.rawValue | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT.rawValue)
        info.messageType = VkDebugUtilsMessageTypeFlagsEXT(
            VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT.rawValue | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT.rawValue
                | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT.rawValue)
        info.pfnUserCallback = debugMessengerCallback
        // Unretained: the instance owns the log and destroys the messenger before releasing it.
        info.pUserData = Unmanaged.passUnretained(log).toOpaque()
        return info
    }
}

/// The messenger callback: count, then log. Returns VK_FALSE, as the spec requires of an
/// application callback.
private func debugMessengerCallback(
    severity: VkDebugUtilsMessageSeverityFlagBitsEXT,
    types: VkDebugUtilsMessageTypeFlagsEXT,
    data: UnsafePointer<VkDebugUtilsMessengerCallbackDataEXT>?,
    userData: UnsafeMutableRawPointer?
) -> VkBool32 {
    guard let userData else { return VkBool32(VK_FALSE) }
    let log = Unmanaged<ValidationLog>.fromOpaque(userData).takeUnretainedValue()
    let isError = severity.rawValue & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT.rawValue != 0
    let id = data?.pointee.pMessageIdName.map { String(cString: $0) } ?? ""
    let text = data?.pointee.pMessage.map { String(cString: $0) } ?? ""
    log.record(ValidationLog.Message(isError: isError, id: id, text: text))
    let source = id.isEmpty ? "Vulkan" : "Vulkan \(id)"
    if isError {
        vulkanLog.error("\(source, privacy: .public): \(text, privacy: .public)")
    } else {
        vulkanLog.warning("\(source, privacy: .public): \(text, privacy: .public)")
    }
    return VkBool32(VK_FALSE)
}
