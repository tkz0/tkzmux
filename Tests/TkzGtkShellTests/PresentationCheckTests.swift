// PresentationCheckTests — WOR-314 S4. `GtkCanvasHost` presents Vulkan frames for a few seconds,
// shows them, and leaves no box, canvas or ladder behind once its window closes.
//
// Like CanvasCycleTests this runs the `tkzmux` binary (`--presentation-check`), because GTK must
// own the process main thread, and only with TKZMUX_REQUIRE_DISPLAY=1, so a plain `swift test`
// opens no window. It also needs a Vulkan device: without one the check exits 77 ("no-gpu") and
// the test is cancelled, unless TKZMUX_REQUIRE_VULKAN=1 makes that a failure. Under headless sway
// (pixman) the compositor takes no dma-bufs, so the frames go out through the readback rung; on a
// real compositor scripts/linux/shell-local.sh runs the same check with --expect-dmabuf.
import Foundation
import Testing

@Suite(.serialized)
struct PresentationCheckTests {
    static let vulkanRequired = ProcessInfo.processInfo.environment["TKZMUX_REQUIRE_VULKAN"] == "1"

    static func runCheck(_ arguments: [String], environment: [String: String] = [:]) throws -> MainLoopBridgeTests.Report {
        let binary = try MainLoopBridgeTests.tkzmux()
        try #require(FileManager.default.isExecutableFile(atPath: binary.path),
                     "no tkzmux at \(binary.path): build it, or set \(MainLoopBridgeTests.stubVariable)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/timeout")
        process.arguments = ["300", binary.path, "--presentation-check"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return MainLoopBridgeTests.Report(
            status: process.terminationStatus,
            lines: String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init),
            stderr: "")
    }

    @Test("frames are presented, shown and released, and nothing outlives the window",
          .enabled(if: CanvasCycleTests.required, "TKZMUX_REQUIRE_DISPLAY is not set (the asan-valgrind job sets it)"))
    func presentsAndCleansUp() throws {
        let report = try Self.runCheck(["--seconds", "2"])
        if report.status == 77, report.lines.contains(where: { $0.hasPrefix("presentation-check no-gpu") }),
           !Self.vulkanRequired {
            try Test.cancel("no Vulkan device: \(report.lines.last ?? "")")
        }
        #expect(report.status == 0, "\(report.lines)")
        #expect(report.lines.contains("presentation-check ok"), "\(report.lines)")

        let frames = report.fields("frames")
        #expect((frames["presents"].flatMap(Int.init) ?? 0) > 1, "the bar animates: \(report.lines)")
        #expect((frames["shows"].flatMap(Int.init) ?? 0) > 1, "\(report.lines)")
        #expect(frames["import-failures"] == "0", "\(report.lines)")
        #expect(report.fields("validation")["errors"] == "0", "\(report.lines)")
        let boxes = report.fields("boxes")
        #expect(boxes["end"] != nil && boxes["end"] == boxes["baseline"], "\(report.lines)")
        #expect(boxes["texture"] == "0", "every dma-buf texture was finalized: \(report.lines)")
        #expect(boxes["canvases-end"] == "0", "\(report.lines)")
        // The geometry is whole device pixels at the surface's scale.
        let geometry = report.fields("geometry")
        if let scale = geometry["scale"].flatMap(Double.init), let pixels = geometry["pixels"],
           let size = report.lines.first(where: { $0.hasPrefix("geometry ") })?.split(separator: " ").dropFirst().first {
            let logical = size.split(separator: "x").compactMap { Double($0) }
            let device = pixels.split(separator: "x").compactMap { Double($0) }
            #expect(logical.count == 2 && device.count == 2, "\(report.lines)")
            if logical.count == 2, device.count == 2 {
                #expect(abs(logical[0] * scale - device[0]) < 1e-6 && abs(logical[1] * scale - device[1]) < 1e-6, "\(report.lines)")
            }
        }
    }

    /// Without a display the check says so and exits 77. Always runs (see CanvasCycleTests).
    @Test func withoutADisplayTheCheckSkips() throws {
        let report = try Self.runCheck(["--seconds", "1"], environment: [
            "GDK_BACKEND": "wayland", "WAYLAND_DISPLAY": "tkzmux-no-such-display", "DISPLAY": "",
        ])
        #expect(report.status == 77, "\(report.lines)")
        #expect(report.lines.contains("presentation-check no-display"), "\(report.lines)")
    }
}
