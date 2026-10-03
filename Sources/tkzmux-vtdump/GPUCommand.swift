// GPUCommand — `tkzmux-vtdump gpu`, the Vulkan bootstrap on its own (WOR-313 S1, Linux only).
//
//   gpu [--headless] [--main-device <major:minor>] [--no-validation] [--size <w>x<h>] [--no-clear]
//
// Creates the instance, lists every physical device in loader order with what the selector reads
// from it, selects one exactly as the app does (TKZMUX_GPU included) and logs the choice and its
// reason, creates the device, then clears an offscreen B8G8R8A8_UNORM target and checks every
// read-back byte. vtdump has no compositor connection, so without --main-device the choice is the
// loader's order, which Mesa's device_select layer starts with the compositor's GPU; --main-device
// stands in for the dmabuf-feedback `main_device` that WOR-314 S4 reads.
//
// The validation layer is loaded when installed (--no-validation skips it, e.g. to time
// vkCreateInstance alone). Exit 0 when the readback matches and the messenger counted no error,
// 1 otherwise or when no device is eligible, 2 on a usage error.

#if os(Linux)
import Foundation
import TkzRenderVK

enum GPUCommand {
    static func run(_ argv: [String]) throws {
        let arguments = Arguments(argv, valueFlags: ["main-device", "size"])
        let known: Set<String> = ["headless", "main-device", "no-validation", "size", "no-clear"]
        if let unknown = arguments.flags.keys.sorted().first(where: { !known.contains($0) }) {
            fail("tkzmux-vtdump gpu: unknown option --\(unknown)", code: 2)
        }
        var mainDevice: DRMNode?
        if let text = arguments.value("main-device") {
            guard let node = DRMNode(text) else { fail("tkzmux-vtdump gpu: --main-device wants <major>:<minor>", code: 2) }
            mainDevice = node
        }
        var size = (width: UInt32(64), height: UInt32(64))
        if let text = arguments.value("size") {
            let parts = text.split(separator: "x").compactMap { UInt32($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("tkzmux-vtdump gpu: --size wants <w>x<h>", code: 2) }
            size = (parts[0], parts[1])
        }
        let mode: GPUMode = arguments.has("headless") ? .headless : .presenting

        let instance = try VulkanInstance(validation: arguments.has("no-validation") ? .off : .ifAvailable,
                                          applicationName: "tkzmux-vtdump")
        let layer = instance.validationEnabled ? "on"
            : arguments.has("no-validation") ? "off" : "off (\(VulkanInstance.validationLayer) not installed)"
        print("loader: Vulkan \(instance.loaderVersion), vkCreateInstance \(milliseconds(instance.creationNanoseconds)) ms, validation \(layer)")

        let made: (device: VulkanDevice, report: GPUBootstrapReport)
        do {
            made = try VulkanDevice.make(instance: instance, mode: mode, mainDevice: mainDevice)
        } catch let error as NoEligibleGPU {
            fail("tkzmux-vtdump gpu: \(error)", code: 1)
        }
        let report = made.report
        print("devices (loader order):")
        for candidate in report.candidates { print("  " + describe(candidate)) }
        print("mode: \(mode.rawValue), \(GPUPreference.environmentVariable)=\(report.preference.rawValue), "
              + "main_device: \(report.mainDevice.map(\.description) ?? "none")")
        let chosen = report.selection.candidate
        print("selected \(chosen.index): \(chosen.name): \(report.selection.reason)")
        for warning in report.selection.warnings { print("warning: \(warning)") }
        print("enabled extensions: \(made.device.enabledExtensions.isEmpty ? "none" : made.device.enabledExtensions.joined(separator: " "))")

        var failed = false
        if !arguments.has("no-clear") {
            let target = try OffscreenTarget(device: made.device, width: size.width, height: size.height)
            let color = BGRA8(b: 0x20, g: 0x80, r: 0xC0, a: 0xFF)
            let bytes = try target.clear(to: color)
            let expected = [color.b, color.g, color.r, color.a]
            let mismatches = stride(from: 0, to: bytes.count, by: 4).count { !bytes[$0..<$0 + 4].elementsEqual(expected) }
            print("clear+readback \(size.width)x\(size.height) B8G8R8A8_UNORM \(color): "
                  + (mismatches == 0 ? "ok" : "\(mismatches) pixels differ"))
            failed = mismatches != 0
        }
        let log = instance.validationLog
        print("validation messages: \(log.errorCount) errors, \(log.warningCount) warnings")
        if failed || log.errorCount > 0 { exit(1) }
    }

    private static func describe(_ candidate: GPUCandidate) -> String {
        var fields = [
            "\(candidate.index)", candidate.name, candidate.kind.rawValue, "Vulkan \(candidate.apiVersion)",
            "vendor 0x" + String(candidate.vendorID, radix: 16), "device 0x" + String(candidate.deviceID, radix: 16),
            "primary " + (candidate.primaryNode?.description ?? "-"), "render " + (candidate.renderNode?.description ?? "-"),
        ]
        let unmet = candidate.unmetRequirements
        fields.append(unmet.isEmpty ? "eligible" : "ineligible: " + unmet.joined(separator: ", "))
        if !candidate.missingPresentationExtensions.isEmpty {
            fields.append("missing " + candidate.missingPresentationExtensions.joined(separator: " "))
        }
        return fields.joined(separator: "  ")
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.2f", Double(nanoseconds) / 1e6)
    }
}
#endif
