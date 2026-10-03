// The parity runner's plumbing (WOR-322 S3): where the repository, the references and the reports
// are, where the built tkzmux-vtdump is, and how a producer's child process is started.
//
// Producers run as child processes so that their environment is exactly what the runner gives
// them: the environment-isolation reruns (EnvironmentIsolationTests) change variables that a font
// stack reads once, at load, which an in-process `setenv` could not reach and would race with
// every other test. Every child starts from `ParityEnvironment.base`: this process's environment
// without a display (`WAYLAND_DISPLAY`, `DISPLAY`) and without the variables the isolation reruns
// set, so the baseline is clean on a developer's desktop too.

import Foundation
import TkzParity

enum ParityPaths {
    /// The repository root, from this file.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // Tests/TkzParityRunnerTests/ParityRunnerSupport.swift
            .deletingLastPathComponent()  // Tests/TkzParityRunnerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // <repo>
    }

    static var layerManifest: URL { repoRoot.appending(path: "Tests/Parity/layers.json") }
    static var references: URL { repoRoot.appending(path: "Tests/Parity/References", directoryHint: .isDirectory) }

    /// Where the runner writes what it produced and its reports: `$TKZMUX_PARITY_OUT`, else
    /// `<repo>/.build/parity`. CI uploads this directory when the job fails.
    static var output: URL {
        if let override = ProcessInfo.processInfo.environment["TKZMUX_PARITY_OUT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return repoRoot.appending(path: ".build/parity", directoryHint: .isDirectory)
    }

    /// `L2@1.6`: the directory name and the label of one row.
    static func rowName(_ layer: String, _ scale: Double) -> String { "\(layer)@\(scale)" }

    /// A fresh, empty directory under `output`.
    static func freshDirectory(_ components: String...) throws -> URL {
        var url = output
        for component in components { url.append(path: component, directoryHint: .isDirectory) }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The built `tkzmux-vtdump`: `$TKZMUX_VTDUMP`, else next to the test bundle (`swift test`
    /// builds every product), else `<repo>/.build/debug`.
    static func vtdump() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["TKZMUX_VTDUMP"], !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw ParityRunnerError("TKZMUX_VTDUMP=\(override) is not an executable")
            }
            return URL(fileURLWithPath: override)
        }
        var candidates: [URL] = []
        for argument in CommandLine.arguments {
            guard let range = argument.range(of: ".xctest") else { continue }
            candidates.append(URL(fileURLWithPath: String(argument[..<range.upperBound])).deletingLastPathComponent())
        }
        if let executable = Bundle.main.executableURL { candidates.append(executable.deletingLastPathComponent()) }
        candidates.append(repoRoot.appending(path: ".build/debug", directoryHint: .isDirectory))
        for directory in candidates {
            let binary = directory.appending(path: "tkzmux-vtdump")
            if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
        }
        throw ParityRunnerError("""
            no built tkzmux-vtdump next to the test bundle or in .build/debug \
            (swift build --build-system native --product tkzmux-vtdump, or set TKZMUX_VTDUMP)
            """)
    }
}

struct ParityRunnerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum ParityEnvironment {
    /// Variables a producer must never see from the runner's own session: the display, and every
    /// variable an isolation rerun sets on purpose.
    static let removed = [
        "WAYLAND_DISPLAY", "DISPLAY", "GDK_SCALE", "GDK_DPI_SCALE", "FREETYPE_PROPERTIES",
        "FONTCONFIG_FILE", "FONTCONFIG_PATH", "GSETTINGS_BACKEND",
    ]

    /// The environment every producer starts from.
    static var base: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in removed { environment.removeValue(forKey: key) }
        return environment
    }
}

/// One child process, its output captured in a log file.
enum ParityProcess {
    struct Outcome {
        let status: Int32
        let log: URL

        /// The log's last lines, for a failure message.
        var tail: String {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n")
        }
    }

    /// Runs `executable` with exactly `environment`, stdout and stderr appended to `log`.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], log: URL) throws -> Outcome {
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus, log: log)
    }
}

/// Reports every producer can write: compact sorted-key JSON, and for image layers the TkzParity
/// comparison with its heatmap, so `.build/parity/` holds what CI uploads on a failure.
enum ParityReports {
    static func writeJSON(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Compares two PNGs under `gate` (ADR-0003's constants, never a number of the caller's) and
    /// writes `<name>.json` and `<name>.heatmap.png` into `directory`. For the image layers' producers
    /// (L3–L6) as they are registered.
    static func compareImages(reference: URL, produced: URL, masks: ParityMaskSet? = nil, gate: ParityGate,
                              name: String, into directory: URL) throws -> ImageComparisonReport {
        var result = ImageComparison.compare(try ParityImage(contentsOf: reference), try ParityImage(contentsOf: produced),
                                             masks: masks, gate: gate)
        result.report.a = reference.path
        result.report.b = produced.path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let png = try ImageComparison.heatmapPNG(result) {
            let heatmap = directory.appending(path: "\(name).heatmap.png")
            try Data(png).write(to: heatmap, options: .atomic)
            result.report.heatmap = heatmap.path
        }
        try writeJSON(result.report, to: directory.appending(path: "\(name).json"))
        return result.report
    }
}
