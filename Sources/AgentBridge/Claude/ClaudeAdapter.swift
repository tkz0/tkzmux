// ClaudeAdapter — the first conformer to the `AgentAdapter` seam (TKZ-82).
//
// There is no new logic here: everything this wraps already existed (`ClaudeHookMapper`,
// `ClaudeSessionWatcher`, the transcript readers, and the account-discovery rule that used to live
// in `TkzApp.ClaudeIntegration`). This file is composition — the one place that knows Claude's own
// command-line flags, environment variable and file layout, so the rest of the app can stop
// knowing them.

import Foundation
import TkzCore

/// One coding agent, Claude Code, as the rest of tkzmux needs to know it.
public struct ClaudeAdapter: AgentAdapter, Sendable {
    public init() {}

    public let kind: AgentKind = .claude
    public let displayName = "Claude"
    public let binaryName = "claude"

    public var capabilities: AgentCapabilities {
        [.hooks, .observation, .statusline, .transcriptUsage, .resume, .worktree]
    }

    public func launchCommand(_ intent: LaunchIntent) -> String? {
        switch intent {
        case .new:
            return "claude"
        case .worktree(let name):
            guard let name else { return "claude -w" }
            return "claude -w \(name)"
        case .resume(let conversationId):
            return "claude --resume \(conversationId)"
        case .prompt(let prompt):
            return "claude \(Self.shellQuoted(prompt))"
        }
    }

    /// Single-quoted for `/bin/sh`, the way the pty will read it: the only character that needs
    /// care inside single quotes is the single quote itself. This matters because `prompt` is user
    /// text about to land on a command line — unescaped, a stray `'` in it would let the rest of
    /// the string be read as shell syntax instead of being typed at Claude as plain text.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Empty when no account was chosen, which is meaningful: it means the user's own environment
    /// decides, so this must not set `CLAUDE_CONFIG_DIR` to anything rather than to some default.
    public func environment(configDir: String?) -> [String: String] {
        guard let configDir else { return [:] }
        return ["CLAUDE_CONFIG_DIR": configDir]
    }

    /// `~/.claude` (always) and every `~/.claude-*` directory that carries `settings.json`,
    /// `sessions/` or `.claude.json`.
    ///
    /// Deliberately **not** gated on `claude` being on `PATH`: a Claude user always has `~/.claude`
    /// on disk whether or not the binary is currently findable, and gating here would change
    /// behaviour for existing users in a move that must not. Codex's adapter gates its own
    /// discovery, but for a different reason — nobody installed it, so it should contribute no
    /// phantom accounts at all.
    public func discoverAccounts(home: String, fileManager: FileManager = .default) -> [Account] {
        let labels = accountLabels(home: home, fileManager: fileManager)
        var out: [Account] = []
        let primary = (home as NSString).appendingPathComponent(".claude")
        let defaultKey = Account.defaultKey(for: .claude)
        // Every account this produces is Claude's — stamped explicitly rather than left to the
        // initializer's default.
        out.append(
            Account(
                key: defaultKey, configDir: primary,
                label: labels[defaultKey] ?? defaultKey, agent: .claude))
        let entries = (try? fileManager.contentsOfDirectory(atPath: home)) ?? []
        for name in entries.sorted() where name.hasPrefix(".claude-") {
            let path = (home as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            let markers = ["settings.json", "sessions", ".claude.json"]
            guard
                markers.contains(where: {
                    fileManager.fileExists(atPath: (path as NSString).appendingPathComponent($0))
                })
            else { continue }
            let key = Account.key(forConfigDirectory: path)
            out.append(Account(key: key, configDir: path, label: labels[key] ?? key, agent: .claude))
        }
        return out
    }

    /// The account-label overlay: `~/.claude/dash-accounts.json`, shape
    /// `{"labels": {"<account key>": "<display name>"}}`.
    ///
    /// This is the only place a **human-written** account name comes from, and CLAUDE.md is
    /// explicit that names belong in config rather than in code — so the file is read and no name
    /// is ever spelled out here. It is read from the *primary* config dir, not per-account: the
    /// point is one table naming all of them, and an account cannot name itself before it is
    /// discovered.
    ///
    /// Written by another program, so decoding is forgiving in the same way the descriptor is: a
    /// missing file, a torn write or a non-string value yields no overlay at all, and every key
    /// then falls back to being its own label. Empty and whitespace-only names are dropped — a
    /// blank chip would be worse than the raw key.
    public func accountLabels(home: String, fileManager: FileManager = .default) -> [String: String] {
        let path = (home as NSString).appendingPathComponent(".claude/dash-accounts.json")
        guard let data = fileManager.contents(atPath: path),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let labels = root["labels"] as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in labels {
            guard let name = value as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out[key] = trimmed }
        }
        return out
    }

    public func mapHook(_ payload: HookPayload) -> AgentEvent? {
        ClaudeHookMapper.map(payload)
    }

    /// Claude reports its status through hooks, which is a richer channel than a terminal
    /// notification could ever be, and today's Claude Code sends nothing over OSC 9 that this
    /// method could tell apart from another. `nil` here is a decision, not a placeholder: were a
    /// future Claude Code version to start sending a classifiable notification, mapping it would
    /// mean reading `title`/`body`, not guessing at what "richer than hooks" might one day contain.
    public func mapTerminalNotification(title: String, body: String) -> AgentEvent? { nil }

    public func makeObservationWatcher(
        configDirs: [String], onEvent: @escaping @Sendable (ObservationEvent) -> Void
    ) -> (any AgentObservationWatcher)? {
        ClaudeSessionWatcher(configDirs: configDirs) { event in
            // The projection at this boundary is the whole reason `ClaudeSessionInfo.observation`
            // exists: everything Claude-specific about the descriptor (`jobId`,
            // `messagingSocketPath`, and the rest) stops here.
            switch event {
            case .updated(let info, let alive):
                onEvent(.updated(info.observation, alive: alive))
            case .removed(let key):
                onEvent(.removed(pid: key.pid, configDir: key.configDir))
            }
        }
    }

    public var transcript: any TranscriptProvider { ClaudeTranscriptProvider() }

    /// Claude's hooks ride in on `--settings` from the shim on every invocation, so there is
    /// nothing to install into the user's own config and nothing to ask consent for. Contrast
    /// Codex, whose hooks have to be written into its own config file once, with consent, through
    /// `.installed` — the case this one exists to be the opposite of.
    public var hookInstall: HookInstallStrategy { .perInvocation }

    public var shimScript: ShimResource { ShimResource(binaryName: "claude", resourceName: "claude.sh") }
}

/// Wraps the free-function transcript readers behind the `TranscriptProvider` seam. Every call
/// takes the config dir or path it needs rather than holding one, matching the readers themselves:
/// a single instance serves every Claude account.
public struct ClaudeTranscriptProvider: TranscriptProvider {
    public init() {}

    public func locate(conversationId: String, configDir: String, fileManager: FileManager) -> String? {
        TranscriptReader.locate(sessionId: conversationId, configDir: configDir, fileManager: fileManager)
    }

    public func summary(path: String) throws -> TranscriptSummary {
        try TranscriptReader.read(path: path)
    }

    /// `nil` when nothing has ever been parsed for this session — distinct from zero, and the
    /// caller must not render it as "$0 spent" (see `TranscriptUsageReader.refresh`).
    public func usage(
        conversationId: String, path: String, reader: TranscriptUsageReader
    ) async -> SessionUsage? {
        await reader.refresh(sessionId: conversationId, transcriptPath: path)
    }

    public func searchIndex(path: String, existing: TranscriptIndex?) throws -> TranscriptIndex {
        try TranscriptIndex.build(path: path, existing: existing)
    }
}
