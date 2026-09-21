// SettingsModel.swift — what the Settings window shows, as data (design 7a–d).
//
// The artboard's rule: every row is a title, one sentence saying what the option does, and one
// control. This file turns `AppState` plus the two facts that live outside the store (which
// producer feeds each account's status line, whether the shell integration is on disk) into that
// shape, so `SettingsView` only lays out and `SettingsWindowTests` can assert the words without a
// window. Pages exist only where a setting already exists: General, Shell, Appearance. The
// artboard's Sessions / Usage / Git are not drawn until something lives on them.

import AgentBridge
import TkzCore

/// One page of the nav column.
/// One page of the nav column.
///
/// `allCases` is the **order** the nav column draws in, not its membership: a page with nothing to
/// say is omitted from `SettingsModel.pages`, and the view iterates the model's pages rather than
/// this list (see `SettingsView`). `.agents` is the first page to use that — a per-group agent
/// picker is not a setting on a machine with one agent installed.
enum SettingsPage: String, CaseIterable, Hashable, Sendable {
    case general
    case agents
    case shell
    case appearance

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .shell: "Shell"
        case .appearance: "Appearance"
        }
    }

    /// The artboard's nav glyph.
    var glyph: String {
        switch self {
        case .general: "\u{2699}"      // ⚙
        case .agents: "\u{25C8}"       // ◈
        case .shell: "\u{2328}"        // ⌨
        case .appearance: "\u{25D0}"   // ◐
        }
    }
}

struct SettingsRow: Hashable, Sendable {
    /// Stable identity, so a re-render updates a control in place rather than rebuilding it.
    enum ID: Hashable, Sendable {
        case autoResume
        case originCheck
        case notifyOnDone
        case sessionSpend
        case statusline(accountKey: String)
        /// Codex's own consent-to-install hooks row (TKZ-87). Never produced for an account whose
        /// agent injects its hooks per invocation instead — see `hooksRows`.
        case hooks(accountKey: String)
        case shellStatus
        case removeShell
        case themePreset
        /// One group's agent. `GroupID` is `Hashable` and `Sendable`, so the enum's own
        /// conformances still synthesise.
        case groupAgent(groupID: GroupID)
    }

    enum Control: Hashable, Sendable {
        case toggle(isOn: Bool)
        case button(title: String, destructive: Bool)
        case popup(titles: [String], selected: Int)
        /// A read-only chip: a dot and a mono word, green when `active`.
        case status(text: String, active: Bool)
    }

    var id: ID
    var title: String
    var detail: String
    var control: Control
}

struct SettingsSection: Hashable, Sendable {
    var caption: String
    var rows: [SettingsRow]
}

struct SettingsModel: Hashable, Sendable {

    /// The facts the store does not hold.
    struct Environment: Sendable {
        /// Producer per account key. An account absent here reads as `.none`.
        var statusline: [String: StatuslineProducer] = [:]
        /// `nil` when there is no agent integration behind the window (tests, the dev window).
        var shellInstalled: Bool? = nil
        /// Where the shim lives, for the Shell page's sentence. `nil` falls back to the standard path.
        var shellDirectory: String? = nil
        /// The shim binary names actually on disk right now (`ShimInstaller` writes one per
        /// installed agent — TKZ-87), for the Shell page to name instead of speaking only in the
        /// abstract. Empty when nothing is wired (tests, the dev window), in which case the
        /// sentence falls back to the same generic wording it always used.
        var installedShims: [String] = []
        /// Names an account's own agent, e.g. "Claude" — from the adapter registry, so the
        /// statusline and hooks sentences never spell a product name of their own. Defaults to
        /// admitting it does not know rather than asserting one.
        var agentDisplayName: @Sendable (AgentKind) -> String = { _ in "the agent" }
        /// What an agent can do, keyed by kind — `AgentAdapter.capabilities`, without depending on
        /// any concrete adapter. Every row-builder below gates on this rather than on an agent's
        /// name, which is what lets a status-line row appear for exactly the adapters that answer
        /// `.statusline`. Defaults to Claude's own shipped capabilities and nothing for any other
        /// agent — today's behaviour, unchanged, for a caller that has not wired the real adapter
        /// table (tests, the dev window); production wires this from `AgentIntegration`'s own
        /// `adapters[agent]?.capabilities`.
        var capabilities: @Sendable (AgentKind) -> AgentCapabilities = { agent in
            agent == .claude
                ? [.hooks, .observation, .statusline, .transcriptUsage, .resume, .worktree]
                : []
        }
        /// True for an agent whose hooks have to be written into its own config once, with
        /// consent — `HookInstallStrategy.installed`, Codex's own case — as opposed to Claude's
        /// `.perInvocation` shim, which leaves nothing to install and so must never get a row here.
        /// That asymmetry is real (see `hooksRows`), not an oversight, which is why it is its own
        /// closure rather than folded into `capabilities`: both agents answer yes to `.hooks`
        /// (they both relay hook events), but only one of them needs a Settings row for it.
        /// Defaults to false for every agent — no row without real wiring; production wires this
        /// from `adapters[agent]?.hookInstall`.
        var hooksInstallRequired: @Sendable (AgentKind) -> Bool = { _ in false }
        /// Per-account Codex hooks detection (`CodexHooksInstaller.detect`), keyed by account key.
        /// An account absent here reads as `CodexHooksDetection(producer: .none,
        /// configTomlHasHooks: false, trust: .unknown)` — one nobody has looked at yet.
        var hooksDetection: [String: CodexHooksDetection] = [:]
    /// The agents whose binary is actually on `PATH`, in the order the ＋ menu draws them, so the
    /// two pickers never disagree. Empty means nothing has been wired (tests, the dev window), and
    /// the Agents page is omitted rather than drawn empty.
    var installedAgents: [AgentKind] = []

        init(
            statusline: [String: StatuslineProducer] = [:],
            shellInstalled: Bool? = nil,
            shellDirectory: String? = nil,
            installedShims: [String] = [],
            agentDisplayName: @escaping @Sendable (AgentKind) -> String = { _ in "the agent" },
            capabilities: @escaping @Sendable (AgentKind) -> AgentCapabilities = { agent in
                agent == .claude
                    ? [.hooks, .observation, .statusline, .transcriptUsage, .resume, .worktree]
                    : []
            },
            hooksInstallRequired: @escaping @Sendable (AgentKind) -> Bool = { _ in false },
            hooksDetection: [String: CodexHooksDetection] = [:],
            installedAgents: [AgentKind] = []
        ) {
            self.statusline = statusline
            self.shellInstalled = shellInstalled
            self.shellDirectory = shellDirectory
            self.installedShims = installedShims
            self.agentDisplayName = agentDisplayName
            self.capabilities = capabilities
            self.hooksInstallRequired = hooksInstallRequired
            self.hooksDetection = hooksDetection
            self.installedAgents = installedAgents
        }
    }

    var pages: [SettingsPage: [SettingsSection]]

    func sections(for page: SettingsPage) -> [SettingsSection] { pages[page] ?? [] }

    static func make(state: AppState, environment: Environment = Environment()) -> SettingsModel {
        var pages: [SettingsPage: [SettingsSection]] = [
            .general: general(state: state, environment: environment),
            .shell: shell(environment: environment),
            .appearance: appearance(state: state),
        ]
        let agents = agents(state: state, environment: environment)
        if !agents.isEmpty { pages[.agents] = agents }
        return SettingsModel(pages: pages)
    }

    // MARK: Agents

    /// One row per group: which agent its new sessions start.
    ///
    /// **Omitted entirely** with fewer than two installed agents, or with no groups — a popup with
    /// one choice is not a setting, and this page's whole content is popups. That is the same rule
    /// the Hooks section follows, and it is why the nav column is driven by the model's pages
    /// rather than by `SettingsPage.allCases`.
    ///
    /// Row-per-group rather than a group *selector*: a selector would change what the page shows
    /// rather than change a setting, which is a control semantics `SettingsView` does not have —
    /// every row here is a title, one sentence and one control. The known limit is that this scales
    /// badly past a few dozen groups; the context menus are the fast path either way.
    static func agents(state: AppState, environment: Environment) -> [SettingsSection] {
        let installed = environment.installedAgents
        guard installed.count > 1 else { return [] }
        let groups = state.orderedGroups
        guard !groups.isEmpty else { return [] }

        let titles = installed.map { environment.agentDisplayName($0) }
        let rows = groups.map { group -> SettingsRow in
            // A group that has chosen nothing, or has chosen an agent nobody has installed, shows
            // the one that will actually run — the same resolution `NewSessionMenu.effectiveAgent`
            // does, and for the same reason: the UI must name what a launch would really start.
            let resolved = group.agent.flatMap { installed.contains($0) ? $0 : nil }
                ?? (installed.contains(.claude) ? .claude : installed[0])
            let name = environment.agentDisplayName(resolved)
            var detail = "New sessions here start \(name)."
            if let chosen = group.agent, chosen != resolved {
                detail += " \(environment.agentDisplayName(chosen)) is not installed."
            }
            detail += " " + (group.repoRoot ?? "No repo \u{2014} only shells.")
            return SettingsRow(
                id: .groupAgent(groupID: group.id),
                title: group.name,
                detail: detail,
                control: .popup(
                    titles: titles, selected: installed.firstIndex(of: resolved) ?? 0))
        }
        return [SettingsSection(caption: "Default agent per group", rows: rows)]
    }

    // MARK: General

    private static func general(state: AppState, environment: Environment) -> [SettingsSection] {
        var statusBar: [SettingsRow] = [
            SettingsRow(
                id: .sessionSpend, title: "Show token usage and spend",
                detail: "Read each session's transcript for tokens and an estimated cost, shown on "
                    + "the row and in the status bar. A row's context menu can opt one session out.",
                control: .toggle(isOn: state.showSessionSpend)),
        ]
        statusBar += statuslineRows(state: state, environment: environment)
        var sections = [
            SettingsSection(caption: "On launch", rows: [
                SettingsRow(
                    id: .autoResume, title: "Resume previous sessions",
                    detail: "Reopen every conversation that was running when tkzmux last "
                        + "quit, in the same groups and splits.",
                    control: .toggle(isOn: state.autoResumeOnLaunch)),
            ]),
            SettingsSection(caption: "Git", rows: [
                SettingsRow(
                    id: .originCheck, title: "Check origin periodically",
                    detail: "Fetch each repo's base branch every 5 min, under your git credentials, "
                        + "so behind-base hints and \u{2191}\u{2193} counts stay current. Off by default.",
                    control: .toggle(isOn: state.checkOriginPeriodically)),
            ]),
            SettingsSection(caption: "Notifications", rows: [
                SettingsRow(
                    id: .notifyOnDone, title: "Notify when a session finishes",
                    detail: "Show a macOS notification when a session finishes a turn you "
                        + "are not looking at. NEEDS YOU banners follow the system notification "
                        + "setting and have no switch of their own.",
                    control: .toggle(isOn: state.notifyOnDone)),
            ]),
            SettingsSection(caption: "Status bar", rows: statusBar),
        ]
        // Only for an agent whose hooks need installing with consent (Codex today) — see
        // `hooksInstallRequired`'s own doc comment. Omitted entirely rather than shown empty, so a
        // Claude-only install (today's default, and every existing fixture) never grows a page
        // section with nothing in it.
        let hooks = hooksRows(state: state, environment: environment)
        if !hooks.isEmpty {
            sections.append(SettingsSection(caption: "Hooks integration", rows: hooks))
        }
        return sections
    }

    /// One row per account whose agent claims `.statusline`, the default account first, then by
    /// key. With one account the row carries no account name; with several, each row names its
    /// own — the same rule the sidebar chip follows (nothing to say about the only account there
    /// is). The name is `Account.qualifiedName` rather than the bare label, because two config
    /// dirs signed into the same organisation share a label and the rows would otherwise be
    /// indistinguishable except by the path buried in their body text.
    ///
    /// Gated on the capability rather than on `account.agent == .claude`: today that capability
    /// happens to belong to Claude alone, but the row-builder itself does not know that, which is
    /// what keeps a Codex account from growing a status-line row it cannot back.
    static func statuslineRows(state: AppState, environment: Environment) -> [SettingsRow] {
        let accounts = state.accounts.values
            .filter { environment.capabilities($0.agent).contains(.statusline) }
            .sorted { a, b in
                let aIsDefault = a.key == Account.defaultKey(for: a.agent)
                let bIsDefault = b.key == Account.defaultKey(for: b.agent)
                if aIsDefault { return !bIsDefault }
                if bIsDefault { return false }
                return a.key < b.key
            }
        let named = accounts.count > 1
        return accounts.map { account in
            let producer = environment.statusline[account.key] ?? .none
            let file = "\(account.configDir)/settings.json"
            let title = named
                ? "Status line integration \u{00B7} \(account.qualifiedName)"
                : "Status line integration"
            let agentName = environment.agentDisplayName(account.agent)
            let detail: String
            let button: String
            switch producer {
            case .none:
                detail = "Let \(agentName) write its usage and context into the tkzmux status bar. "
                    + "Edits \(file) only after you confirm."
                button = "Configure\u{2026}"
            case .other:
                detail = "Let \(agentName) write its usage and context into the tkzmux status bar. "
                    + "Your current status line keeps running underneath. "
                    + "Edits \(file) only after you confirm."
                button = "Configure\u{2026}"
            case .tkzmux:
                detail = "Installed. Usage and context in the status bar come from it; removing "
                    + "puts back whatever \(file) had before."
                button = "Remove\u{2026}"
            case .stale:
                detail = "A tkzmux status line from another build is configured in \(file). It is "
                    + "repaired at launch; removing puts back what was there before."
                button = "Remove\u{2026}"
            }
            return SettingsRow(
                id: .statusline(accountKey: account.key), title: title, detail: detail,
                control: .button(title: button, destructive: false))
        }
    }

    /// One row per account whose agent needs its hooks written into its own config once, with
    /// consent (`hooksInstallRequired`) — Codex today, never Claude: Claude's shim injects hooks on
    /// every invocation (`HookInstallStrategy.perInvocation`), so there is nothing to install and
    /// nothing to show here for it. Same shape and sort as `statuslineRows`.
    static func hooksRows(state: AppState, environment: Environment) -> [SettingsRow] {
        let accounts = state.accounts.values
            .filter { environment.hooksInstallRequired($0.agent) }
            .sorted { a, b in
                let aIsDefault = a.key == Account.defaultKey(for: a.agent)
                let bIsDefault = b.key == Account.defaultKey(for: b.agent)
                if aIsDefault { return !bIsDefault }
                if bIsDefault { return false }
                return a.key < b.key
            }
        let named = accounts.count > 1
        return accounts.map { account in
            let detection = environment.hooksDetection[account.key]
                ?? CodexHooksDetection(producer: .none, configTomlHasHooks: false, trust: .unknown)
            let file = "\(account.configDir)/hooks.json"
            let title = named
                ? "Hooks integration \u{00B7} \(account.qualifiedName)"
                : "Hooks integration"
            let agentName = environment.agentDisplayName(account.agent)
            // Codex also reads hooks straight out of its own `config.toml` and merges the two
            // sources rather than letting one win (measured against a real binary — see
            // `CodexHooksInstaller`'s own header comment), so a row that only mentioned
            // `hooks.json` would leave the user thinking installing here replaces something it
            // only adds alongside.
            let configTomlClause = detection.configTomlHasHooks
                ? " \(agentName) also runs hooks from its own config.toml; this only adds tkzmux's, alongside them."
                : ""
            let detail: String
            let button: String
            switch detection.producer {
            case .none:
                detail = "Let \(agentName) relay session events to tkzmux by writing hooks into "
                    + "\(file). Edits it only after you confirm.\(configTomlClause)"
                button = "Configure\u{2026}"
            case .other:
                detail = "Let \(agentName) relay session events to tkzmux by writing hooks into "
                    + "\(file), alongside the hooks already there. Edits it only after you "
                    + "confirm.\(configTomlClause)"
                button = "Configure\u{2026}"
            case .tkzmux:
                detail = "Installed. \(Self.hooksTrustSentence(agentName: agentName, trust: detection.trust)) "
                    + "Removing puts back whatever \(file) had before."
                button = "Remove\u{2026}"
            case .stale:
                detail = "A tkzmux hook from another build is configured in \(file). It is "
                    + "repointed at launch. \(Self.hooksTrustSentence(agentName: agentName, trust: detection.trust)) "
                    + "Removing puts back what was there before."
                button = "Remove\u{2026}"
            }
            return SettingsRow(
                id: .hooks(accountKey: account.key), title: title, detail: detail,
                control: .button(title: button, destructive: false))
        }
    }

    /// The sentence that keeps an "Installed" hooks row honest. Measured against a real logged-in
    /// codex-cli 0.155.0 (`CodexHooksInstaller`'s own header comment): a hook tkzmux writes does
    /// not run until the user trusts it once inside Codex's own `/hooks` review, and `detect` can
    /// only text-scan the trust ledger for whether it mentions this file at all — never proof that
    /// *these* hooks specifically were the ones reviewed. So every branch below stays as weak as
    /// what was actually measured, and none of them ever mentions
    /// `--dangerously-bypass-hook-trust`: that flag bypasses trust for every hook of the
    /// invocation, including the user's own, so suggesting it here would be worse than saying
    /// nothing.
    private static func hooksTrustSentence(agentName: String, trust: CodexHooksTrustState) -> String {
        switch trust {
        case .mentionsOurConfig:
            return "\(agentName)'s own trust ledger already mentions this file, so at least one "
                + "of these hooks has likely run."
        case .doesNotMentionOurConfig:
            return "\(agentName) has not trusted this yet, so nothing fires until you run /hooks "
                + "there and approve it."
        case .unknown:
            return "tkzmux cannot tell whether \(agentName) has trusted this yet — run /hooks "
                + "there to check."
        }
    }

    // MARK: Shell

    private static func shell(environment: Environment) -> [SettingsSection] {
        let directory = environment.shellDirectory ?? "~/Library/Application Support/tkzmux"
        let status: SettingsRow.Control
        switch environment.shellInstalled {
        case true?: status = .status(text: "Active", active: true)
        case false?: status = .status(text: "Not installed", active: false)
        case nil: status = .status(text: "Unavailable", active: false)
        }
        // `ShimInstaller` writes one shim per installed agent (TKZ-87), so the sentence names them
        // when it can rather than staying abstract; with nothing wired (tests, the dev window) it
        // falls back to the same wording this row has always had.
        let shimClause: String
        switch environment.installedShims.count {
        case 0:
            shimClause = "Each installed agent's shim"
        case 1:
            shimClause = "The `\(environment.installedShims[0])` shim"
        default:
            let names = environment.installedShims.map { "`\($0)`" }
            shimClause = "The \(names.dropLast().joined(separator: ", ")) and \(names.last!) shims"
        }
        return [
            SettingsSection(caption: "Shell integration", rows: [
                SettingsRow(
                    id: .shellStatus, title: "Integration status",
                    detail: "\(shimClause), and the zsh, bash and fish wrappers under "
                        + "\(directory). Installed again at every launch; your rc files are never edited.",
                    control: status),
                SettingsRow(
                    id: .removeShell, title: "Remove shell integration",
                    detail: "Deletes the shim and wrappers until the next launch, when they are "
                        + "installed again. Sessions keep running, but new shells stop reporting "
                        + "to tkzmux.",
                    control: .button(title: "Remove\u{2026}", destructive: true)),
            ]),
        ]
    }

    // MARK: Appearance

    private static func appearance(state: AppState) -> [SettingsSection] {
        let presets = Theme.Preset.allCases
        return [
            SettingsSection(caption: "Theme", rows: [
                SettingsRow(
                    id: .themePreset, title: "Colour scheme",
                    detail: "Applies to the window, the sidebar and the terminal palette. "
                        + "View \u{203A} Toggle Light / Dark Theme flips between the two.",
                    control: .popup(
                        titles: presets.map(\.displayName),
                        selected: presets.firstIndex(of: state.themePreset) ?? 0)),
            ]),
        ]
    }
}
