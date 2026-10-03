// MainLoopBridgeTests — WOR-314 S1. The main actor and libdispatch's main queue run on the thread
// that iterates the default GMainContext, through the main-queue GSource.
//
// This cannot run inside the test process: Swift Testing's async main parks the process main
// thread in `dispatch_main()`, so the main queue drains on a libdispatch worker, which the GSource
// must never compete with (WOR-300 S3, docs/linux/spikes.md). So
// the test runs `tkzmux --main-loop-check`, where the process main thread owns the GLib loop as
// it will under `g_application_run`, headless (no display, no `gtk_init`), and reads its report.
//
// The binary is `$TKZMUX_TEST_STUB` when set (CI points it at the release build), else the debug
// `tkzmux` that `swift test` builds next to the test runner.
import Foundation
import Testing

@Suite(.serialized)
struct MainLoopBridgeTests {
    static let stubVariable = "TKZMUX_TEST_STUB"

    static func tkzmux() throws -> URL {
        if let path = ProcessInfo.processInfo.environment[stubVariable], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let runner = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        return URL(fileURLWithPath: runner).deletingLastPathComponent().appending(path: "tkzmux")
    }

    struct Report {
        var status: Int32
        var lines: [String]
        var stderr: String

        /// The `key=value` fields of the line that starts with `prefix`.
        func fields(_ prefix: String) -> [String: String] {
            guard let line = lines.first(where: { $0.hasPrefix(prefix + " ") }) else { return [:] }
            var fields: [String: String] = [:]
            for part in line.split(separator: " ").dropFirst() {
                let pair = part.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            return fields
        }
    }

    /// Runs the check under `timeout`, so a stalled loop fails the test instead of hanging it.
    static func runCheck() throws -> Report {
        let binary = try tkzmux()
        try #require(FileManager.default.isExecutableFile(atPath: binary.path),
                     "no tkzmux at \(binary.path): build it, or set \(stubVariable)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/timeout")
        process.arguments = ["60", binary.path, "--main-loop-check"]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // A few hundred bytes, far below a pipe buffer: reading one pipe to the end first cannot
        // block the child.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Report(
            status: process.terminationStatus,
            lines: String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init),
            stderr: String(decoding: err, as: UTF8.self))
    }

    @Test func mainActorAndMainQueueRunOnTheGLibThread() throws {
        let report = try Self.runCheck()
        #expect(report.status == 0, "\(report.lines) \(report.stderr)")
        #expect(report.lines.last == "main-loop-check ok")

        // A @MainActor Task, Task.sleep, a DispatchSource on .main and a DispatchSourceTimer.
        for primitive in ["task", "task-sleep", "dispatch-source", "dispatch-timer"] {
            #expect(report.lines.contains("fired \(primitive) main-thread"), "\(primitive): \(report.lines)")
        }

        // The eventfd is reset before each drain: a handful of dispatches, not a spin.
        let drains = report.lines.first { $0.hasPrefix("drains ") }.flatMap { Int($0.dropFirst(7)) }
        #expect(drains.map { $0 >= 1 && $0 <= 200 } == true, "\(report.lines)")

        // Nothing posted, nothing drained.
        #expect(report.fields("idle")["drains"] == "0", "\(report.lines)")
    }

    /// p99 < 1 ms over 10,000 posts from a background queue (WOR-300 S2 measured 4.9 µs).
    @Test func mainQueueLatencyP99IsUnderOneMillisecond() throws {
        let report = try Self.runCheck()
        let latency = report.fields("latency")
        #expect(latency["posts"] == "10000", "\(report.lines)")
        #expect(latency["off-thread"] == "0", "\(report.lines)")
        let p99 = try #require(latency["p99-us"].flatMap(Double.init), "\(report.lines)")
        #expect(p99 < 1_000, "p99 \(p99) µs")
    }
}
