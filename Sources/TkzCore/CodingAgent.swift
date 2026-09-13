// CodingAgent.swift — which AI coding CLI a new session starts.
//
// tkzmux grew up around `claude`, and everything that reads a session back — hooks, the shim's
// `launch` frame, transcripts, resume, spend — is still Claude's. What is *not* Claude-specific is
// the act of typing a command into a fresh shell in the repo root, so that part is pluggable: the
// user picks a default agent and "New session" runs its command instead of `claude`.
//
// The table is data, not configuration: an `id` persisted in `state.json` that no longer names a
// built-in resolves to Claude rather than failing the load (`CodingAgent.resolve(_:)`).

/// One AI coding CLI a session can be started with.
public struct CodingAgent: Hashable, Sendable, Identifiable {
    /// Stable key, persisted as `PersistedPreferences.defaultAgent`.
    public let id: String
    /// What the menus call it.
    public let name: String
    /// The executable typed into the shell, e.g. `grok`.
    public let command: String
    /// The flag that makes the agent create its own git worktree (`claude -w`). `nil` for an agent
    /// with no such flag: its "New worktree" entry is disabled rather than guessed at.
    public let worktreeFlag: String?

    public init(id: String, name: String, command: String, worktreeFlag: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.worktreeFlag = worktreeFlag
    }

    public static let claude = CodingAgent(id: "claude", name: "Claude", command: "claude", worktreeFlag: "-w")
    /// `grok -w [name]` — "Start the session in a new git worktree, optionally named" (Grok 1.0.30
    /// `--help`). Grok keeps its worktrees under `~/.grok/worktrees`, not in the repo.
    public static let grok = CodingAgent(id: "grok", name: "Grok", command: "grok", worktreeFlag: "-w")
    public static let codex = CodingAgent(id: "codex", name: "Codex", command: "codex")
    public static let gemini = CodingAgent(id: "gemini", name: "Gemini", command: "gemini")

    /// Every agent the menus offer, in menu order. Claude first: it is the default and the only
    /// one tkzmux has a full integration for.
    public static let builtIn: [CodingAgent] = [.claude, .grok, .codex, .gemini]

    /// The built-in agent with `id`, or Claude for an id nothing knows (a newer build's agent, a
    /// hand-edited `state.json`).
    public static func resolve(_ id: String) -> CodingAgent {
        builtIn.first { $0.id == id } ?? .claude
    }

    /// Whether this is Claude — the agent whose startup, hooks and resume tkzmux understands.
    public var isClaude: Bool { id == CodingAgent.claude.id }

    /// The command line for a plain launch in the repo root.
    public var launchCommand: String { command }

    /// `claude -w [name]`, or `nil` when the agent cannot make its own worktree.
    public func worktreeCommand(name: String? = nil) -> String? {
        guard let worktreeFlag else { return nil }
        return [command, worktreeFlag, name].compactMap { $0 }.joined(separator: " ")
    }

    /// The command line with `prompt` as its first argument, already shell-quoted by the caller.
    public func launchCommand(quotedPrompt: String) -> String {
        "\(command) \(quotedPrompt)"
    }
}
