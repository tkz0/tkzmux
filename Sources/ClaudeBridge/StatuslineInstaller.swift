// StatuslineInstaller — the only code in tkzmux that writes `~/.claude/settings.json` (TKZ-32).
//
// Everything else about the Claude integration is deliberately non-invasive: `ShimInstaller` writes
// only into tkzmux's own Application Support directory, and the shim injects hooks per invocation
// via `claude --settings`. A statusline cannot work that way — Claude Code reads `statusLine` from
// the settings file, and the data it carries (rate limits, context usage) reaches disk nowhere else.
// So this one thing is a real, visible edit to a file the user owns, which is why it happens only
// behind an explicit consent sheet and why `uninstall` is held to a higher standard than "delete the
// key".
//
// The rewrite itself is delegated to `tkzmux-hook statusline-settings`, whose JSON parser preserves
// key order and number source text. That matters: the user's settings.json is a file they read and
// diff, and a round trip through `JSONSerialization` would silently reorder every key and reformat
// every number. The hook prints the new document; this type writes it atomically.
//
// Layout added under `directory` (normally `~/Library/Application Support/tkzmux`):
//     statusline/previous-<accountKey>.json   the `statusLine` value from before the install
//     statusline/usage-<accountKey>.json      written by the producer, read by `StatuslineReader`
//     statusline/context-<sessionId>.json     ditto
import Foundation

public enum StatuslineInstallerError: Error, Equatable, Sendable {
    /// settings.json exists but is not JSON we can rewrite safely.
    case settingsUnusable(path: String)
    /// `tkzmux-hook statusline-settings` failed; nothing was written.
    case rewriteFailed(path: String)
    /// Asked to uninstall when `statusLine` no longer points at tkzmux — the user changed it since,
    /// and clobbering their change would be worse than doing nothing.
    case notInstalled
    /// Asked to uninstall with no record of what came before. A missing companion file is *lost
    /// state*, not evidence there was nothing here, so the key is left alone.
    case previousMissing(path: String)
    case writeFailed(path: String, errno: Int32)
    case hookMissing(path: String)
}

/// What is producing the statusline data for one Claude config directory right now.
public enum StatuslineProducer: Equatable, Sendable {
    /// No `statusLine` configured at all.
    case none
    /// Ours. Nothing to offer.
    case tkzmux
    /// Somebody else's — claude-hud, a hand-written script, anything. This is the interesting case:
    /// tkzmux wraps it and passes its output through untouched.
    case other(command: String)
}

/// The exact before/after the consent sheet shows. Nothing has been written when this is built.
public struct StatuslineInstallPlan: Equatable, Sendable {
    public var settingsPath: String
    public var accountKey: String
    /// The current `statusLine` value, pretty-printed; nil when there is none.
    public var before: String?
    /// What `statusLine` will become.
    public var after: String
    public var producer: StatuslineProducer

    public init(
        settingsPath: String, accountKey: String, before: String?, after: String,
        producer: StatuslineProducer
    ) {
        self.settingsPath = settingsPath
        self.accountKey = accountKey
        self.before = before
        self.after = after
        self.producer = producer
    }
}

public struct StatuslineInstaller: Sendable {
    /// tkzmux's application support directory.
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The installed hook binary — the same one the shim uses, already signed and already copied
    /// into `bin/` by `ShimInstaller`. Installing a statusline therefore adds no new executable,
    /// no Makefile change and no second code-signing identity.
    public var hookBinary: URL {
        directory.appendingPathComponent("bin/tkzmux-hook", isDirectory: false)
    }

    public var statuslineDirectory: URL {
        directory.appendingPathComponent("statusline", isDirectory: true)
    }

    public func previousURL(accountKey: String) -> URL {
        statuslineDirectory.appendingPathComponent("previous-\(accountKey).json", isDirectory: false)
    }

    public static func settingsPath(configDir: String) -> String {
        (configDir as NSString).appendingPathComponent("settings.json")
    }

    /// The `statusLine.command` this installer writes. Quoted because the bin directory may contain
    /// spaces (`~/Library/Application Support/…`).
    public var command: String { "\"\(hookBinary.path)\" statusline" }

    // MARK: - Detection

    /// Reads the current `statusLine.command`. Parsing here is read-only, so `JSONSerialization` is
    /// fine — nothing this method touches is ever written back.
    public func detect(configDir: String, fileManager: FileManager = .default) -> StatuslineProducer {
        let path = Self.settingsPath(configDir: configDir)
        guard let data = fileManager.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              !command.isEmpty
        else { return .none }
        if command.contains(hookBinary.path) || command.contains("tkzmux-hook\" statusline") {
            return .tkzmux
        }
        return .other(command: command)
    }

    public func isInstalled(configDir: String, fileManager: FileManager = .default) -> Bool {
        detect(configDir: configDir, fileManager: fileManager) == .tkzmux
    }

    /// Builds the before/after for the consent sheet without writing anything.
    public func plan(
        configDir: String, accountKey: String, fileManager: FileManager = .default
    ) throws -> StatuslineInstallPlan {
        let path = Self.settingsPath(configDir: configDir)
        let producer = detect(configDir: configDir, fileManager: fileManager)
        let saved = try runHook(["statusline-settings", path, "value", "-"])
        // `before` is nil when the saved document records `{"statusLine": null}`.
        let before = saved.contains("\"statusLine\": null") ? nil : saved

        var after: [String: Any] = ["type": "command", "command": command]
        if let data = fileManager.contents(atPath: path),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = root["statusLine"] as? [String: Any] {
            for key in ["refreshInterval", "padding"] where existing[key] != nil {
                after[key] = existing[key]
            }
        }
        let afterText = (try? JSONSerialization.data(
            withJSONObject: ["statusLine": after],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? command

        return StatuslineInstallPlan(
            settingsPath: path, accountKey: accountKey, before: before, after: afterText,
            producer: producer)
    }

    // MARK: - Install / uninstall

    /// Saves the previous `statusLine` verbatim, then points `statusLine.command` at tkzmux.
    ///
    /// The companion file is written *first*, so a failure part-way through leaves the user's
    /// settings.json untouched (and a stale companion file that the next install overwrites) rather
    /// than a wrapped statusline with nothing to unwrap back to.
    public func install(
        configDir: String, accountKey: String, fileManager: FileManager = .default
    ) throws {
        // Installing twice would save *our own* command as "what came before", and the next
        // uninstall would then restore tkzmux instead of the user's statusline. The UI never asks
        // twice, but the API must not depend on that.
        guard detect(configDir: configDir, fileManager: fileManager) != .tkzmux else { return }
        let path = Self.settingsPath(configDir: configDir)
        try fileManager.createDirectory(at: statuslineDirectory, withIntermediateDirectories: true)

        let saved = try runHook(["statusline-settings", path, "value", "-"])
        try Self.write(saved, to: previousURL(accountKey: accountKey), fileManager: fileManager)

        let rewritten = try runHook(["statusline-settings", path, "install", "-"])
        try Self.write(rewritten, to: URL(fileURLWithPath: path), fileManager: fileManager)
    }

    /// Puts back exactly what was there, or removes the key when there was nothing.
    ///
    /// Refuses in two cases, both of which mean "we would be destroying something": the live
    /// `statusLine` no longer points at us (the user rewired it), or the companion file is gone.
    public func uninstall(
        configDir: String, accountKey: String, fileManager: FileManager = .default
    ) throws {
        let path = Self.settingsPath(configDir: configDir)
        guard detect(configDir: configDir, fileManager: fileManager) == .tkzmux else {
            throw StatuslineInstallerError.notInstalled
        }
        let previous = previousURL(accountKey: accountKey)
        guard fileManager.fileExists(atPath: previous.path) else {
            throw StatuslineInstallerError.previousMissing(path: previous.path)
        }
        let rewritten = try runHook(["statusline-settings", path, "uninstall", previous.path])
        try Self.write(rewritten, to: URL(fileURLWithPath: path), fileManager: fileManager)
        try? fileManager.removeItem(at: previous)
    }

    // MARK: - Plumbing

    /// Runs `tkzmux-hook` and returns its stdout. It prints nothing and exits non-zero on any
    /// problem, so empty output is always an error and never a truncated settings file.
    private func runHook(_ arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: hookBinary.path) else {
            throw StatuslineInstallerError.hookMissing(path: hookBinary.path)
        }
        let process = Process()
        process.executableURL = hookBinary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TKZMUX_BIN"] = hookBinary.deletingLastPathComponent().path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw StatuslineInstallerError.rewriteFailed(path: arguments.first ?? "")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw StatuslineInstallerError.rewriteFailed(path: arguments.count > 1 ? arguments[1] : "")
        }
        return text
    }

    private static func write(_ text: String, to url: URL, fileManager: FileManager) throws {
        var contents = text
        if !contents.hasSuffix("\n") { contents += "\n" }
        try ShimInstaller.writeAtomically(
            Data(contents.utf8), to: url, permissions: 0o644, fileManager: fileManager)
    }
}
