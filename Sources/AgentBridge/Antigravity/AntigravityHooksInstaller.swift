// AntigravityHooksInstaller — writing tkzmux's hooks into Antigravity's own `hooks.json`, once,
// with the user's consent.
//
// Antigravity has no per-invocation settings flag, so its hooks have to live in a file the user
// owns. That makes this the same shape as the other installers in this module: detect
// first, plan and show the diff, install only on consent, and keep a record so uninstall can put
// back exactly what was there.
//
// **The trap this file exists to avoid.** `agy` accepts a malformed `hooks.json`, logs one warning
// to its own log file, and then runs the whole session with no hooks at all — nothing on stdout,
// nothing in the TUI. During the measurement spike a hooks.json written from the *documented*
// example produced exactly that:
//
//     W hooks.go:103] Failed to parse hooks file …/hooks.json:
//       invalid hook "tkzmux-probe": command hook must specify 'command'
//
// because the structure is **per event** and the docs state it only in a table:
//
//   * `PreToolUse` / `PostToolUse` — grouped: `[{ "matcher": …, "hooks": [handler, …] }]`
//   * `PreInvocation` / `PostInvocation` / `Stop` — flat: `[handler, …]`, no wrapper
//
// Both shapes are committed as fixtures (`hooks-json-verified.json`, `hooks-json-rejected.json`)
// precisely so a refactor cannot quietly regress to the one that parses as JSON and does nothing.
// Everything this file writes goes through ``entry(for:command:)``, which is the only place that
// knows which events are grouped.

import Foundation

/// What is producing this machine's Antigravity hooks right now, from `hooks.json` alone.
public enum AntigravityHooksProducer: Equatable, Sendable {
    /// No `hooks.json`, or it carries no entry for any event this installer manages.
    case none
    /// Every managed event already carries exactly the command this build would write.
    case tkzmux
    /// A `tkzmux-hook` command is present for at least one managed event, but it runs a binary at
    /// a different support-directory path than this build's own — an older install, a `.build`
    /// binary, a second checkout. The paths reported are exactly what a repair would repoint.
    case stale(paths: Set<String>)
    /// At least one managed event already carries an entry that is not a `tkzmux-hook` command —
    /// the user's own hook, or another tool's. Install adds ours alongside; nothing is replaced.
    case other
}

/// The full picture `detect` can offer, without writing anything.
public struct AntigravityHooksDetection: Equatable, Sendable {
    public var producer: AntigravityHooksProducer
    /// True when a workspace-local `.agents/hooks.json` was found for the workspace being examined.
    /// Antigravity merges that with the user-level file, so a `.none` producer here does not mean
    /// the user has no hooks configured anywhere — the caller must surface this alongside it.
    public var workspaceHooksPresent: Bool

    public init(producer: AntigravityHooksProducer, workspaceHooksPresent: Bool = false) {
        self.producer = producer
        self.workspaceHooksPresent = workspaceHooksPresent
    }
}

/// The exact before/after a consent sheet shows. Nothing has been written when this is built.
public struct AntigravityHooksInstallPlan: Equatable, Sendable {
    public var hooksPath: String
    public var accountKey: String
    /// `hooks.json`'s current text, verbatim; `nil` when the file does not exist yet.
    public var before: String?
    /// What `hooks.json` will become.
    public var after: String
    public var detection: AntigravityHooksDetection

    public init(
        hooksPath: String, accountKey: String, before: String?, after: String,
        detection: AntigravityHooksDetection
    ) {
        self.hooksPath = hooksPath
        self.accountKey = accountKey
        self.before = before
        self.after = after
        self.detection = detection
    }
}

public enum AntigravityHooksInstallerError: Error, Equatable, Sendable {
    /// `hooks.json` exists but is not JSON this installer can safely merge into — a syntax error,
    /// a non-object root, or a managed event whose value is not an array. Refusing beats guessing:
    /// rewriting a file we do not understand is how a user loses their own hooks.
    case unreadable(path: String)
    case writeFailed(path: String, underlying: String)
}

/// Writes tkzmux's relay into Antigravity's `hooks.json`.
public struct AntigravityHooksInstaller: HookConfigInstaller {
    /// tkzmux's own support directory — where `bin/tkzmux-hook` lives and where the undo record is
    /// kept. Handed in rather than derived, exactly as the sibling installers take it.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The five events Antigravity actually supports in `hooks.json`, and nothing else.
    ///
    /// Measured: `SessionStart`, `PreTurn` and `PostTurn` exist as types inside the binary but are
    /// **not** configurable here — a probe registering them was silently ignored. Writing them
    /// anyway would put keys in the user's file that do nothing.
    static let managedEvents = [
        "PreInvocation", "PostInvocation", "Stop", "PreToolUse", "PostToolUse",
    ]

    /// The events that take the grouped `{matcher, hooks}` wrapper. Everything else is flat.
    /// This set **is** the trap described in this file's header.
    static let groupedEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    /// The top-level hook name tkzmux owns. Antigravity's file is keyed by hook name, so ours is
    /// namespaced and the user's own entries are never touched.
    static let hookName = "tkzmux"

    /// `~/.gemini/config/hooks.json` — the **shared** user-level file.
    ///
    /// Not `~/.gemini/antigravity-cli/hooks.json`: the binary's own changelog records writing there
    /// as a bug it fixed, because the TUI and the backend both read the shared one. A future
    /// version moving it again is a real risk, which is why this is one function.
    public static func hooksPath(configDir: String) -> String {
        ((configDir as NSString).appendingPathComponent("config") as NSString)
            .appendingPathComponent("hooks.json")
    }

    /// The relay command for one event, as it is written into the file.
    func command(forEvent event: String) -> String {
        let binary = directory.appendingPathComponent("bin/tkzmux-hook").path
        return "\(shellQuoted(binary)) relay --agent antigravity --event \(event)"
    }

    /// Single-quoted for `sh -c`, which is what Antigravity runs the command with.
    func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One event's entry, in **that event's own shape**. The single place the grouped/flat split is
    /// encoded — see this file's header for what happens when it is got wrong.
    static func entry(for event: String, command: String) -> [String: Any] {
        let handler: [String: Any] = ["type": "command", "command": command, "timeout": 10]
        guard groupedEvents.contains(event) else { return handler }
        return ["matcher": "*", "hooks": [handler]]
    }

    // MARK: - Detect

    public func isInstalled(configDir: String, fileManager: FileManager) -> Bool {
        if case .tkzmux = detect(configDir: configDir, fileManager: fileManager).producer {
            return true
        }
        return false
    }

    public func detect(
        configDir: String, fileManager: FileManager = .default, workspace: String? = nil
    ) -> AntigravityHooksDetection {
        let workspaceHooks = workspace.map {
            fileManager.fileExists(
                atPath: ((($0 as NSString).appendingPathComponent(".agents")) as NSString)
                    .appendingPathComponent("hooks.json"))
        } ?? false

        let path = Self.hooksPath(configDir: configDir)
        guard let root = Self.readObject(path: path, fileManager: fileManager) else {
            return AntigravityHooksDetection(
                producer: .none, workspaceHooksPresent: workspaceHooks)
        }

        var commands: [String] = []
        for (_, value) in root {
            guard let spec = value as? [String: Any] else { continue }
            for event in Self.managedEvents {
                commands.append(contentsOf: Self.commands(in: spec[event], grouped: Self.groupedEvents.contains(event)))
            }
        }
        guard !commands.isEmpty else {
            return AntigravityHooksDetection(producer: .none, workspaceHooksPresent: workspaceHooks)
        }

        let ours = Set(Self.managedEvents.map { command(forEvent: $0) })
        let relays = commands.filter { $0.contains("tkzmux-hook") }
        if relays.isEmpty {
            return AntigravityHooksDetection(producer: .other, workspaceHooksPresent: workspaceHooks)
        }
        let stale = Set(relays.filter { !ours.contains($0) })
        if !stale.isEmpty {
            return AntigravityHooksDetection(
                producer: .stale(paths: stale), workspaceHooksPresent: workspaceHooks)
        }
        // Every managed event has to be present, not just some of them, or a partial install would
        // report as complete and the missing events would never be written.
        let present = Set(relays)
        if ours.isSubset(of: present) {
            return AntigravityHooksDetection(producer: .tkzmux, workspaceHooksPresent: workspaceHooks)
        }
        return AntigravityHooksDetection(producer: .other, workspaceHooksPresent: workspaceHooks)
    }

    /// Every `command` string under one event's value, in whichever shape that event uses.
    static func commands(in value: Any?, grouped: Bool) -> [String] {
        guard let array = value as? [Any] else { return [] }
        if !grouped {
            return array.compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
        return array.flatMap { element -> [String] in
            guard let group = element as? [String: Any], let hooks = group["hooks"] as? [Any]
            else { return [] }
            return hooks.compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    // MARK: - Plan

    public func plan(
        configDir: String, accountKey: String, fileManager: FileManager = .default
    ) throws -> AntigravityHooksInstallPlan {
        let path = Self.hooksPath(configDir: configDir)
        let before = fileManager.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
        var root: [String: Any] = [:]
        if before != nil {
            guard let parsed = Self.readObject(path: path, fileManager: fileManager) else {
                throw AntigravityHooksInstallerError.unreadable(path: path)
            }
            root = parsed
        }
        let after = try Self.serialize(merged(into: root))
        return AntigravityHooksInstallPlan(
            hooksPath: path, accountKey: accountKey, before: before, after: after,
            detection: detect(configDir: configDir, fileManager: fileManager))
    }

    /// tkzmux's own hook block, replacing any previous one of ours and leaving every other
    /// top-level key untouched.
    func merged(into root: [String: Any]) -> [String: Any] {
        var root = root
        var spec: [String: Any] = [:]
        for event in Self.managedEvents {
            spec[event] = [Self.entry(for: event, command: command(forEvent: event))]
        }
        root[Self.hookName] = spec
        return root
    }

    // MARK: - Install / uninstall

    public func install(configDir: String, accountKey: String, fileManager: FileManager) throws {
        let path = Self.hooksPath(configDir: configDir)
        let plan = try plan(configDir: configDir, accountKey: accountKey, fileManager: fileManager)
        try recordPrevious(plan.before, accountKey: accountKey, fileManager: fileManager)
        try write(plan.after, to: path, fileManager: fileManager)
    }

    public func uninstall(configDir: String, accountKey: String, fileManager: FileManager) throws {
        let path = Self.hooksPath(configDir: configDir)
        guard var root = Self.readObject(path: path, fileManager: fileManager) else { return }
        root.removeValue(forKey: Self.hookName)
        // An empty object is left as an empty object rather than deleted: the file may have been
        // the user's before it was ours, and removing it outright is a bigger claim than removing
        // the key we added.
        try write(try Self.serialize(root), to: path, fileManager: fileManager)
    }

    /// `<support>/antigravity-hooks/previous-<accountKey>.json`, so uninstall can put back exactly
    /// what was there.
    ///
    /// A record naming a real previous value is never traded down for one naming an absence: if a
    /// record already exists, it is the original and this leaves it alone. Overwriting it on a
    /// second install would lose the user's own file forever.
    func recordPrevious(
        _ before: String?, accountKey: String, fileManager: FileManager
    ) throws {
        let directory = self.directory.appendingPathComponent("antigravity-hooks")
        let record = directory.appendingPathComponent("previous-\(accountKey).json")
        guard !fileManager.fileExists(atPath: record.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = ["hooksJson": before as Any]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: record, options: .atomic)
    }

    // MARK: - File helpers

    static func readObject(path: String, fileManager: FileManager) -> [String: Any]? {
        guard let data = fileManager.contents(atPath: path), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func serialize(_ root: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw AntigravityHooksInstallerError.unreadable(path: "<memory>")
        }
        return text + "\n"
    }

    func write(_ text: String, to path: String, fileManager: FileManager) throws {
        let url = URL(fileURLWithPath: path)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw AntigravityHooksInstallerError.writeFailed(
                path: path, underlying: String(describing: error))
        }
    }
}
