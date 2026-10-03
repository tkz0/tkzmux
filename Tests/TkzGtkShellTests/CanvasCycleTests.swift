// CanvasCycleTests — WOR-314 S2. After 100 open/close cycles of an undecorated window holding a
// TkzCanvas, every closure box, canvas and toplevel is gone again, and every canvas vfunc reached
// its delegate.
//
// Like MainLoopBridgeTests this runs the `tkzmux` binary (`--canvas-cycle-check`), because GTK
// must own the process main thread, which the test process cannot give it. Unlike that check it
// needs a display, and it opens windows: it runs only with TKZMUX_REQUIRE_DISPLAY=1, which the
// asan-valgrind CI job sets under headless sway, and which makes a missing display a failure.
// Without it the test is skipped by name, so a plain `swift test` never opens windows on the
// desktop. Locally: `scripts/linux/headless-sway.sh env TKZMUX_REQUIRE_DISPLAY=1 swift test …`,
// or TKZMUX_REQUIRE_DISPLAY=1 in the session itself.
import Foundation
import Testing

@Suite(.serialized)
struct CanvasCycleTests {
    static let required = ProcessInfo.processInfo.environment["TKZMUX_REQUIRE_DISPLAY"] == "1"

    /// Runs `tkzmux --canvas-cycle-check` with `arguments` under `timeout`, stdout and stderr
    /// together (GTK may warn on stderr, more than a pipe buffer holds under a sanitizer).
    static func runCheck(_ arguments: [String], environment: [String: String] = [:]) throws -> MainLoopBridgeTests.Report {
        let binary = try MainLoopBridgeTests.tkzmux()
        try #require(FileManager.default.isExecutableFile(atPath: binary.path),
                     "no tkzmux at \(binary.path): build it, or set \(MainLoopBridgeTests.stubVariable)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/timeout")
        process.arguments = ["600", binary.path, "--canvas-cycle-check"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return MainLoopBridgeTests.Report(
            status: process.terminationStatus,
            lines: text.split(separator: "\n").map(String.init),
            stderr: "")
    }

    @Test("100 open/close cycles leave no box, canvas or toplevel behind",
          .enabled(if: required, "TKZMUX_REQUIRE_DISPLAY is not set (the asan-valgrind job sets it)"))
    func hundredCyclesReturnToBaseline() throws {
        let report = try Self.runCheck(["--cycles", "100"])
        #expect(report.status == 0, "\(report.lines)")
        #expect(report.lines.contains("canvas-cycle-check ok"), "\(report.lines)")

        let cycles = report.fields("cycles")
        #expect(cycles["n"] == "100", "\(report.lines)")
        for vfunc in ["realize", "unrealize", "a11y", "close-request"] {
            #expect(cycles[vfunc] == "100", "\(vfunc): \(report.lines)")
        }
        for vfunc in ["snapshot", "measure", "size-allocate", "focus"] {
            #expect((cycles[vfunc].flatMap(Int.init) ?? 0) >= 100, "\(vfunc): \(report.lines)")
        }
        #expect(report.lines.contains("orphan ok"), "\(report.lines)")

        let boxes = report.fields("boxes")
        let baseline = try #require(boxes["baseline"].flatMap(Int.init), "\(report.lines)")
        #expect(boxes["end"].flatMap(Int.init) == baseline, "\(report.lines)")
        // Two signal handlers and one canvas context per open window: the counter really counts.
        #expect(boxes["open"].flatMap(Int.init) == baseline + 3, "\(report.lines)")
        for count in ["canvases", "toplevels"] {
            let fields = report.fields(count)
            #expect(fields["baseline"] != nil && fields["end"] == fields["baseline"], "\(count): \(report.lines)")
        }
    }

    /// Without a display the check says so and exits 77, never crashes or hangs. Always runs: the
    /// Wayland socket named here does not exist, and X11 is not tried.
    @Test func withoutADisplayTheCheckSkips() throws {
        let report = try Self.runCheck(["--cycles", "1"], environment: [
            "GDK_BACKEND": "wayland", "WAYLAND_DISPLAY": "tkzmux-no-such-display", "DISPLAY": "",
        ])
        #expect(report.status == 77, "\(report.lines)")
        #expect(report.lines.contains("canvas-cycle-check no-display"), "\(report.lines)")
    }
}
