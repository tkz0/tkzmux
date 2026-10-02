// Shared by the tests that run the repo's shell scripts or the built Linux stub (WOR-303 S4).
import Foundation

enum ScriptSupport {
    /// The repo root, located from this file rather than the working directory.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/TkzCoreTests/ScriptSupport.swift
            .deletingLastPathComponent()          // Tests/TkzCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // <repo>
    }

    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs `executable` to completion. `environment` nil inherits this process's environment.
    static func run(
        _ executable: URL, _ arguments: [String] = [], environment: [String: String]? = nil,
        directory: URL? = nil
    ) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // The scripts and the stub print a few lines, far below a pipe buffer, so reading one pipe
        // to the end before the other cannot block the child.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self))
    }

    /// `bash <script> <arguments>` from the repo root, with this process's environment minus
    /// `VERSION`, plus `extraEnvironment`.
    static func bash(_ arguments: [String], extraEnvironment: [String: String] = [:]) throws -> Output {
        var environment = ProcessInfo.processInfo.environment
        environment["VERSION"] = nil
        environment.merge(extraEnvironment) { $1 }
        return try run(URL(fileURLWithPath: "/bin/bash"), arguments, environment: environment, directory: repoRoot)
    }

    /// `git <arguments>` in the repo, trimmed; empty when git fails (as `$(git …)` is in a script).
    static func git(_ arguments: [String]) throws -> String {
        let result = try run(
            URL(fileURLWithPath: "/usr/bin/env"), ["git"] + arguments, directory: repoRoot)
        guard result.status == 0 else { return "" }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `vendor/ghostty-vt/COMMIT`, trimmed.
    static func ghosttyCommit() throws -> String {
        try String(contentsOf: repoRoot.appending(path: "vendor/ghostty-vt/COMMIT"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A fresh temporary directory, with `resolvingSymlinksInPath()` applied to its path.
    static func makeTemporaryDirectory(_ prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
}
