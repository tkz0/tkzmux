// CodexAdapter — the second conformer to the `AgentAdapter` seam (TKZ-86 part 1).
//
// Sibling to the other supported agent's own adapter: same protocol, different agent, and every
// fact this file encodes about Codex's command line, environment variable and file layout came off
// a real logged-in codex-cli 0.155.0 during the TKZ-86 spike (see this module's test target's own
// `Fixtures/codex/`), not from documentation. Where the ticket's assumptions turned out wrong, the
// fixtures win.
import Foundation
import TkzCore

/// One coding agent, Codex CLI, as the rest of tkzmux needs to know it.
public struct CodexAdapter: AgentAdapter, Sendable {
    /// Where this agent's hooks get installed once, with consent — the tkzmux support directory,
    /// handed to `CodexHooksInstaller` exactly the way `AgentIntegration` already hands
    /// `StatuslineInstaller` its own.
    private let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    public let kind: AgentKind = .codex
    public let displayName = "Codex"
    public let binaryName = "codex"

    /// No `.observation`: Codex writes no descriptor file, so there is nothing for a watcher to
    /// tail. No `.worktree`: Codex has no `-w`-equivalent flag of its own. No `.statusline`: that
    /// feature edits the other supported agent's own `settings.json` shape and has no Codex
    /// counterpart.
    public var capabilities: AgentCapabilities {
        [.hooks, .transcriptUsage, .resume]
    }

    public func launchCommand(_ intent: LaunchIntent) -> String? {
        switch intent {
        case .new:
            return "codex"
        case .worktree:
            // Codex has no worktree flag of its own (see `capabilities`), so there is no command
            // line to return for this intent at all — `nil` is the honest answer, not a guess.
            return nil
        case .resume(let conversationId):
            return "codex resume \(conversationId)"
        case .prompt(let prompt):
            return "codex \(Self.shellQuoted(prompt))"
        }
    }

    /// Single-quoted for `/bin/sh`, identical in spirit to the other adapter's own `shellQuoted` —
    /// the only character that needs care inside single quotes is the single quote itself.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Empty when no account was chosen, exactly like the other adapter's own
    /// `environment(configDir:)`: it means the user's own environment decides, so this must not
    /// set `CODEX_HOME` to anything rather than to some default.
    public func environment(configDir: String?) -> [String: String] {
        guard let configDir else { return [:] }
        return ["CODEX_HOME": configDir]
    }

    /// `~/.codex` (key `codex`) plus every `~/.codex-*` directory that carries `config.toml` or
    /// `auth.json`, gated on `codex` being on `PATH`.
    ///
    /// This gate is the deliberate difference from the other adapter's own `discoverAccounts`,
    /// which does **not** gate: an existing user of that agent always has its config directory on
    /// disk whether or not its binary is currently findable, so gating there would change
    /// behaviour for existing users. Codex is the opposite case — a leftover `~/.codex` from an
    /// agent the user has since uninstalled must not produce a phantom account in the sidebar, so
    /// discovery here contributes nothing at all unless the binary is actually reachable.
    /// Satisfies the protocol requirement by deferring to the overload below with the real `PATH`
    /// — a protocol witness cannot itself carry an extra parameter, even a defaulted one, so the
    /// testable gate lives one level down.
    public func discoverAccounts(home: String, fileManager: FileManager = .default) -> [Account] {
        discoverAccounts(
            home: home, fileManager: fileManager, searchPath: ProcessInfo.processInfo.environment["PATH"])
    }

    /// `searchPath` is an extra parameter beyond the protocol requirement, exactly like
    /// `isInstalled(path:)` — it exists so a test can construct a `PATH` with or without a `codex`
    /// on it and assert the gate directly, rather than mutating the process environment out from
    /// under whatever else is running.
    func discoverAccounts(home: String, fileManager: FileManager, searchPath: String?) -> [Account] {
        guard isInstalled(path: searchPath) else { return [] }
        var out: [Account] = []
        let primary = (home as NSString).appendingPathComponent(".codex")
        let defaultKey = Account.defaultKey(for: .codex)
        out.append(
            Account(key: defaultKey, configDir: primary, label: defaultKey, agent: .codex))
        let entries = (try? fileManager.contentsOfDirectory(atPath: home)) ?? []
        for name in entries.sorted() where name.hasPrefix(".codex-") {
            let path = (home as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            let markers = ["config.toml", "auth.json"]
            guard
                markers.contains(where: {
                    fileManager.fileExists(atPath: (path as NSString).appendingPathComponent($0))
                })
            else { continue }
            let key = Account.key(forConfigDirectory: path)
            out.append(Account(key: key, configDir: path, label: key, agent: .codex))
        }
        return out
    }

    /// Codex has no `dash-accounts.json` equivalent — no file anywhere that lets a human name an
    /// account — so there is no overlay to read and every account label falls back to being its
    /// own key.
    public func accountLabels(home: String, fileManager: FileManager = .default) -> [String: String] {
        [:]
    }

    public func mapHook(_ payload: HookPayload) -> AgentEvent? {
        CodexHookMapper.map(payload)
    }

    /// `nil`: Codex's OSC 9 title and body have not been measured. `tui.notifications` is a TUI
    /// feature and does not apply to the `codex exec` runs the TKZ-86 spike could actually drive,
    /// so there is no captured fixture to model a mapping on. A guessed mapping would be worse than
    /// none — it would silently misread a row's status on shapes nobody has verified — so this
    /// stays `nil` until a real notification is captured, the same discipline the other adapter
    /// applies to its own (verified-empty) case.
    public func mapTerminalNotification(title: String, body: String) -> AgentEvent? { nil }

    /// Codex writes no descriptor file, so there is nothing for a watcher to tail (see
    /// `capabilities`'s doc comment on `.observation`).
    public func makeObservationWatcher(
        configDirs: [String], onEvent: @escaping @Sendable (ObservationEvent) -> Void
    ) -> (any AgentObservationWatcher)? { nil }

    public var transcript: any TranscriptProvider { CodexTranscriptReader() }

    /// Codex's hooks have to be written into its own config file once, with the user's consent —
    /// the opposite of the other agent's `--settings` trick, which is what `.perInvocation` exists
    /// to be the opposite of (see the other adapter's own `hookInstall`).
    public var hookInstall: HookInstallStrategy {
        .installed(CodexHooksInstaller(directory: supportDirectory))
    }

    public var shimScript: ShimResource { ShimResource(binaryName: "codex", resourceName: "codex.sh") }
}
