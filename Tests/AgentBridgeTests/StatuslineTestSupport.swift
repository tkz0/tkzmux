// StatuslineTestSupport — running the built `tkzmux-hook` and making temp directories, shared by
// StatuslineTests (the producer and the installer) and StatuslineReaderTests (the consumer).
import Foundation

enum StatuslineTestSupport {
    enum Failure: Error { case binaryNotFound }

    /// The built `tkzmux-hook`, found the same way `HookBinaryTests` finds it.
    static func hookBinary() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["TKZMUX_HOOK_BIN"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            let candidate = bundle.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("tkzmux-hook")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        for argument in ProcessInfo.processInfo.arguments {
            guard let range = argument.range(of: ".xctest") else { continue }
            let products = URL(fileURLWithPath: String(argument[argument.startIndex..<range.upperBound]))
                .deletingLastPathComponent()
            let candidate = products.appendingPathComponent("tkzmux-hook")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw Failure.binaryNotFound
    }

    static func tempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkzmux-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies the built hook into `<support>/bin/tkzmux-hook`, which is where an installed tkzmux
    /// has it and where `StatuslineInstaller` looks.
    static func installHook(into support: URL) throws -> URL {
        let bin = support.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let destination = bin.appendingPathComponent("tkzmux-hook")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: try hookBinary(), to: destination)
        return destination
    }

    static func environment(_ overrides: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("TKZMUX_") || key == "CLAUDE_CONFIG_DIR" {
            env.removeValue(forKey: key)
        }
        for (key, value) in overrides { env[key] = value }
        return env
    }

    @discardableResult
    static func run(
        _ binary: URL, _ arguments: [String], stdin: String = "", environment: [String: String]
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Written and closed on *this* thread, before a byte of output is read. The dispatched
        // write this replaced deadlocked once the suite grew: every running test parks its own
        // thread in `readDataToEndOfFile` below, and with enough of them in flight the queued
        // closes never get a thread to run on — so no child ever sees EOF on stdin, and
        // `readStdin` blocks forever. Safe because every payload here is a few KB against a
        // 64 KiB pipe buffer; a larger one would need the write back on a thread of its own.
        if !stdin.isEmpty { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: out, encoding: .utf8) ?? "",
            String(data: err, encoding: .utf8) ?? ""
        )
    }

    /// A payload carrying every field the producer maps, in the shapes Claude Code actually sends
    /// (verified against its docs and a live capture on 2026-09-09).
    static let fullPayload = """
        {
          "session_id": "abc-123_XYZ",
          "session_name": "pricing work",
          "cwd": "/Users/x/dev/repo",
          "model": { "id": "claude-opus-5", "display_name": "Opus 5" },
          "workspace": {
            "current_dir": "/Users/x/dev/repo",
            "project_dir": "/Users/x/dev/repo",
            "git_worktree": "pricing",
            "repo": { "host": "github.com", "owner": "tkz0", "name": "tkzmux" }
          },
          "cost": { "total_cost_usd": 1.50 },
          "context_window": { "used_percentage": 62.4, "context_window_size": 200000 },
          "rate_limits": {
            "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
            "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
          },
          "pr": {
            "number": 412, "url": "https://github.com/tkz0/tkzmux/pull/412",
            "review_state": "approved"
          },
          "worktree": { "name": "pricing", "path": "/w/pricing" }
        }
        """

    static func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
