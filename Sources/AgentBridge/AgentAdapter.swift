// AgentBridge — the seam. Everything that knows a path, a JSON schema or a CLI flag lives behind
// this protocol; everything in front of it is written once and works for every agent.
//
// It lives here rather than in TkzCore because it needs Foundation and because its members traffic
// in bridge types (`HookPayload`, the transcript readers). TkzCore stays the agent-blind domain
// model; this is the layer that translates one agent into it.
//
// The test of whether the seam is real: adding an agent must mean adding an adapter and nothing
// else. `AgentIntegration` holds `[AgentKind: any AgentAdapter]` and never names a concrete one,
// which is what a stub adapter in the tests proves.

import Foundation
import TkzCore

/// What an agent can do, so the UI can offer exactly that and no more.
///
/// An `OptionSet` rather than a pile of booleans because the questions are all of the same shape
/// ("does this agent do X?") and the menu, the settings page and the sidebar all ask several at
/// once. `ClaudeAdapter` answers yes to everything; Codex will not, and the New-session menu hides
/// its worktree entry on the strength of that alone.
public struct AgentCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Relays hook events to us, so status can come from evidence rather than guesswork.
    public static let hooks = AgentCapabilities(rawValue: 1 << 0)
    /// Writes a descriptor file we can watch — an `AgentObservation` source.
    public static let observation = AgentCapabilities(rawValue: 1 << 1)
    /// Supports a custom status line we can install (Claude only, so far).
    public static let statusline = AgentCapabilities(rawValue: 1 << 2)
    /// Keeps a transcript we can sum token usage from.
    public static let transcriptUsage = AgentCapabilities(rawValue: 1 << 3)
    /// Can reopen a past conversation by id.
    public static let resume = AgentCapabilities(rawValue: 1 << 4)
    /// Has a worktree flag of its own, so "New worktree" means something.
    public static let worktree = AgentCapabilities(rawValue: 1 << 5)
}

/// Why we are about to start the agent. The adapter turns this into its own command line.
public enum LaunchIntent: Hashable, Sendable {
    /// A plain new conversation in the given directory.
    case new
    /// A new conversation in a worktree the agent creates itself. `nil` lets the agent name it.
    /// Only meaningful for an adapter with `.worktree`.
    case worktree(name: String?)
    /// Reopen a past conversation.
    case resume(conversationId: String)
    /// Start with a prompt already typed. The adapter is responsible for quoting it.
    case prompt(String)
}

/// How an agent's hooks get in front of it.
public enum HookInstallStrategy: Sendable {
    /// The shim injects them on every invocation, so there is nothing to install and nothing to
    /// consent to — Claude's `--settings` trick.
    case perInvocation
    /// They have to be written into the agent's own config, once, with the user's consent.
    case installed(any HookConfigInstaller)
}

/// Writes an agent's hooks into a file the user owns. Modelled on `StatuslineInstaller`, which is
/// the only other place tkzmux edits a user-owned file: detect first, plan and show the diff,
/// install only on consent, and keep a record so uninstall can put back exactly what was there.
public protocol HookConfigInstaller: Sendable {
    func isInstalled(configDir: String, fileManager: FileManager) -> Bool
    func install(configDir: String, accountKey: String, fileManager: FileManager) throws
    func uninstall(configDir: String, accountKey: String, fileManager: FileManager) throws
}

/// The shim script for an agent, and the name it is installed under in `bin/`.
public struct ShimResource: Hashable, Sendable {
    /// The basename the shim takes, which must be the agent's own binary name so it shadows it on
    /// `PATH`.
    public var binaryName: String
    /// The resource file under `Resources/shim/`, e.g. `claude.sh`.
    public var resourceName: String

    public init(binaryName: String, resourceName: String) {
        self.binaryName = binaryName
        self.resourceName = resourceName
    }
}

/// One observation source, as the adapter exposes it. `ClaudeSessionWatcher` is the only
/// implementation today; an agent that writes no descriptor file returns `nil` instead of one.
public protocol AgentObservationWatcher: AnyObject, Sendable {
    func start()
    func stop()
    func setConfigDirs(_ configDirs: [String])
}

/// What an observation watcher reports, already projected off the agent's own descriptor type.
public enum ObservationEvent: Sendable {
    case updated(AgentObservation, alive: Bool)
    /// The descriptor for this pid under this config dir is gone.
    case removed(pid: pid_t, configDir: String)
}

/// Where an agent keeps its conversation, and what can be read out of it.
///
/// Every call takes the config dir rather than the provider holding one: a single adapter instance
/// serves every account of that agent, and accounts are exactly what different config dirs are.
public protocol TranscriptProvider: Sendable {
    /// The transcript file for a conversation, or `nil` if it cannot be found.
    func locate(conversationId: String, configDir: String, fileManager: FileManager) -> String?
    /// First prompt, recap and title, from a bounded head-and-tail read.
    func summary(path: String) throws -> TranscriptSummary
    /// Token usage so far. `nil` when the transcript yields nothing countable, which is different
    /// from zero and must leave the spend badge hidden rather than showing a total of nothing.
    func usage(conversationId: String, path: String, reader: TranscriptUsageReader) async -> SessionUsage?
    /// A searchable index over the conversation, extended from `existing` when it has only grown.
    func searchIndex(path: String, existing: TranscriptIndex?) throws -> TranscriptIndex
}

/// One coding agent, as tkzmux needs to know it.
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    /// What the UI calls it. Every user-facing string interpolates this rather than spelling a
    /// product name, which is what lets one set of strings serve every agent.
    var displayName: String { get }
    /// The executable name, which is also the shim name and what "is it installed?" looks for.
    var binaryName: String { get }
    var capabilities: AgentCapabilities { get }

    /// The command line for an intent, or `nil` when this agent cannot do that — a `.worktree`
    /// intent on an agent without the capability, for instance.
    func launchCommand(_ intent: LaunchIntent) -> String?
    /// The environment that points the agent at one account's config dir. Empty when no account was
    /// chosen, in which case the user's own environment decides.
    func environment(configDir: String?) -> [String: String]
    /// The accounts of this agent present on disk. Must return nothing when the agent is not
    /// installed, so an uninstalled agent produces no phantom accounts.
    func discoverAccounts(home: String, fileManager: FileManager) -> [Account]
    /// Human-readable labels for account keys, where the agent offers them.
    func accountLabels(home: String, fileManager: FileManager) -> [String: String]

    /// Translate one hook frame into the store's vocabulary. `nil` drops the frame.
    func mapHook(_ payload: HookPayload) -> AgentEvent?
    /// Translate an OSC 9 desktop notification arriving through our pty. `nil` means "not evidence",
    /// which is the honest answer for an agent whose notifications we cannot classify.
    func mapTerminalNotification(title: String, body: String) -> AgentEvent?

    /// A watcher for this agent's descriptor files, or `nil` when it writes none.
    func makeObservationWatcher(
        configDirs: [String], onEvent: @escaping @Sendable (ObservationEvent) -> Void
    ) -> (any AgentObservationWatcher)?

    var transcript: any TranscriptProvider { get }
    var hookInstall: HookInstallStrategy { get }
    var shimScript: ShimResource { get }
}

extension AgentAdapter {
    /// Whether this agent's binary is on `PATH`. The menu and account discovery both gate on it, so
    /// an agent nobody has installed contributes nothing to the UI.
    public func isInstalled(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let fileManager = FileManager.default
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = (String(directory) as NSString).appendingPathComponent(binaryName)
            if fileManager.isExecutableFile(atPath: candidate) { return true }
        }
        return false
    }
}
