// AntigravityAdapter — the third conformer to the `AgentAdapter` seam.
//
// Sibling to the other supported agents' own adapters: same protocol, different agent. Every fact
// this file encodes about Antigravity's command line, file layout and hook shape came off a real
// logged-in **Antigravity CLI 1.2.7** during the measurement spike (see this module's test target's
// own `Fixtures/antigravity/`), not from documentation. Where the measurements contradicted the
// docs, the measurements won — and in two places they did:
//
//   * the documented `hooks.json` example produces a file `agy` silently ignores (see
//     `AntigravityHooksInstaller`);
//   * `--prompt`/`-p` is one-shot, so it does **not** satisfy `.prompt`; `--prompt-interactive`
//     does.
//
// Two shapes here have no counterpart in the other adapters and are worth knowing before reading:
//
//   * **One account per machine.** Ten candidate environment variables were tested against a
//     pristine `HOME`; none relocates the config dir, only `HOME` itself does. So
//     `environment(configDir:)` is always empty and `discoverAccounts` returns at most one entry.
//   * **The config dir is not `~/.antigravity`.** It is `~/.gemini`, inherited from the CLI this one
//     replaced, which is why this adapter has to answer `configDirectory(forAccountKey:home:)`
//     itself rather than let the default `~/.<key>` rule apply.

import Foundation
import TkzCore

public struct AntigravityAdapter: AgentAdapter, Sendable {
    /// Where this agent's hooks get installed once, with consent — the tkzmux support directory,
    /// handed to `AntigravityHooksInstaller` the same way the other installing agent's own
    /// adapter hands it its own.
    private let supportDirectory: URL

    /// The `PATH` this adapter's own gates are answered against — the twin of the other gated
    /// adapter's, and for the same reason: under a Finder launch the process's own `PATH` is
    /// launchd's and holds no `agy`, so the app hands in the user's login shell's (`UserPath`).
    private let searchPath: String?

    public init(
        supportDirectory: URL,
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.supportDirectory = supportDirectory
        self.searchPath = searchPath
    }

    public let kind: AgentKind = .antigravity
    public let displayName = "Antigravity"
    /// The binary is `agy`, not `antigravity` — which is also the shim's name, since
    /// `ShimResources.bundled()` derives that from the resource's basename.
    public let binaryName = "agy"

    /// The account key this agent's one account takes. Spelled out because it is **not** the
    /// basename of the config dir: the directory is `~/.gemini`, so the generic
    /// `Account.key(forConfigDirectory:)` rule would produce `gemini` and name the agent this one
    /// replaced.
    public static let accountKey = "antigravity"

    /// No `.observation`: Antigravity writes no per-pid descriptor file, so there is nothing for a
    /// watcher to tail. No `.worktree`: `agy --help` carries no worktree flag of any kind. No
    /// `.statusline`: that feature edits one specific agent's `settings.json` shape and has no
    /// counterpart here. No `.transcriptUsage`: **measured** — Antigravity records no token or cost
    /// accounting anywhere, so claiming it would put a number nobody can source on the row.
    public var capabilities: AgentCapabilities {
        [.hooks, .resume]
    }

    public func launchCommand(_ intent: LaunchIntent) -> String? {
        switch intent {
        case .new:
            return "agy"
        case .worktree:
            // No worktree flag exists (see `capabilities`), so there is no command line to return
            // for this intent at all — `nil` is the honest answer, not a guess.
            return nil
        case .resume(let conversationId):
            // `--conversation <id>`, **not** `--continue`/`-c`: that one reopens the most recent
            // conversation and ignores any id, so using it for a resume would silently reopen the
            // wrong conversation whenever the newest one is not the row's own.
            return "agy --conversation \(Self.shellQuoted(conversationId))"
        case .prompt(let prompt):
            // `--prompt-interactive`, **not** `--prompt`. `LaunchIntent.prompt`'s contract is
            // "start with a prompt already typed", i.e. still interactive; `--prompt`/`-p` is an
            // alias for `--print`, which runs one turn non-interactively and exits. Using it here
            // would leave the user staring at a dead pty.
            return "agy --prompt-interactive \(Self.shellQuoted(prompt))"
        }
    }

    /// Single-quoted for `/bin/sh`, identical in spirit to the other adapters' own — the only
    /// character that needs care inside single quotes is the single quote itself.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// **Always empty, and measured to be so.**
    ///
    /// `GEMINI_HOME`, `GEMINI_CONFIG_DIR`, `GEMINI_DIR`, `GEMINI_CLI_HOME`, `ANTIGRAVITY_HOME`,
    /// `ANTIGRAVITY_CONFIG_DIR`, `ANTIGRAVITY_CLI_HOME`, `AGY_HOME`, `AGY_CONFIG_DIR` and
    /// `XDG_CONFIG_HOME` were each tested by running `agy` under a pristine `HOME` with that
    /// variable pointing elsewhere; in every case the tree was created under `HOME` regardless.
    /// Only `HOME` moves it, and tkzmux must not rewrite a child's `HOME`.
    ///
    /// So there is no config-dir variable to export, and consequently **one account per machine**.
    /// Returning a made-up variable here would be worse than returning nothing: the shell wrappers
    /// re-export whatever this names (`TKZMUX_REEXPORT`), so a guess would end up in the user's
    /// environment doing nothing under a name that looks official.
    public func environment(configDir: String?) -> [String: String] { [:] }

    /// `~/.gemini`, gated on `agy` being on `PATH`.
    ///
    /// The gate matters more here than anywhere else: `~/.gemini` is also where the CLI this one
    /// replaced kept its files, so the directory survives on machines that have not run `agy` in
    /// months. Without the gate every such machine would grow a phantom Antigravity account out of
    /// a leftover directory. Satisfies the protocol requirement by deferring to the overload below
    /// with the real `PATH`, exactly as the other gated adapter does.
    public func discoverAccounts(home: String, fileManager: FileManager = .default) -> [Account] {
        discoverAccounts(home: home, fileManager: fileManager, searchPath: searchPath)
    }

    /// `searchPath` is an extra parameter beyond the protocol requirement, so a test can construct
    /// a `PATH` with or without an `agy` on it and assert the gate directly.
    func discoverAccounts(home: String, fileManager: FileManager, searchPath: String?) -> [Account] {
        guard isInstalled(path: searchPath) else { return [] }
        let configDir = Self.configDirectory(home: home)
        // The directory itself must be there. A machine with `agy` on `PATH` that has never been
        // run has no config dir yet, and inventing an account for it would put a row's resume on a
        // directory that does not exist.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: configDir, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return [] }
        return [
            Account(
                key: Self.accountKey, configDir: configDir, label: Self.accountKey,
                agent: .antigravity)
        ]
    }

    /// Antigravity has no file anywhere that lets a human name an account — and with one account
    /// per machine there would be nothing to disambiguate anyway — so there is no overlay to read.
    public func accountLabels(home: String, fileManager: FileManager = .default) -> [String: String] {
        [:]
    }

    /// `~/.gemini`, **not** `~/.antigravity`.
    ///
    /// This is the override the protocol's default rule cannot express: `Account`'s generic
    /// `~/.<key>` mapping assumes the config dir's basename is the agent's own name, which holds
    /// for every other agent and does not hold here. A restored row has nothing but its account key
    /// to go on, so without this its resume would look in a directory that does not exist.
    public func configDirectory(forAccountKey key: String, home: String) -> String? {
        guard key == Self.accountKey else { return nil }
        return Self.configDirectory(home: home)
    }

    static func configDirectory(home: String) -> String {
        (home as NSString).appendingPathComponent(".gemini")
    }

    public func mapHook(_ payload: HookPayload) -> AgentEvent? {
        AntigravityHookMapper.map(payload)
    }

    /// `nil`: measured, not merely unmeasured. A recorded pty session was grepped for `ESC ] 9 ;`
    /// and `ESC ] 777 ;` and carried neither, so Antigravity emits no OSC 9 notification for this
    /// to classify. Re-check when the CLI's major version moves.
    public func mapTerminalNotification(title: String, body: String) -> AgentEvent? { nil }

    /// Antigravity writes no per-pid descriptor file, so there is nothing for a watcher to tail
    /// (see `capabilities`'s note on `.observation`).
    public func makeObservationWatcher(
        configDirs: [String], onEvent: @escaping @Sendable (ObservationEvent) -> Void
    ) -> (any AgentObservationWatcher)? { nil }

    public var transcript: any TranscriptProvider { AntigravityTranscriptReader() }

    /// Antigravity's hooks have to be written into its own config file once, with consent — there
    /// is no per-invocation settings flag to inject them with. See `AntigravityHooksInstaller` for
    /// the shape trap that makes this more than a file write.
    public var hookInstall: HookInstallStrategy {
        .installed(AntigravityHooksInstaller(directory: supportDirectory))
    }

    /// Named for the binary, since the shim has to shadow `agy` on `PATH`.
    public var shimScript: ShimResource {
        ShimResource(binaryName: "agy", resourceName: "agy.sh")
    }
}
