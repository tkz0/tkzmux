// SettingsModel.swift — what the Settings window shows, as data (design 7a–d).
//
// The artboard's rule: every row is a title, one sentence saying what the option does, and one
// control. This file turns `AppState` plus the two facts that live outside the store (which
// producer feeds each account's status line, whether the shell integration is on disk) into that
// shape, so `SettingsView` only lays out and `SettingsWindowTests` can assert the words without a
// window. Pages exist only where a setting already exists: General, Shell, Appearance. The
// artboard's Sessions / Usage / Git are not drawn until something lives on them.

import ClaudeBridge
import TkzCore

/// One page of the nav column.
enum SettingsPage: String, CaseIterable, Hashable, Sendable {
    case general
    case shell
    case appearance

    var title: String {
        switch self {
        case .general: "General"
        case .shell: "Shell"
        case .appearance: "Appearance"
        }
    }

    /// The artboard's nav glyph.
    var glyph: String {
        switch self {
        case .general: "\u{2699}"      // ⚙
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
        case shellStatus
        case removeShell
        case themePreset
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
        /// `nil` when there is no `ClaudeIntegration` behind the window (tests, the dev window).
        var shellInstalled: Bool? = nil
        /// Where the shim lives, for the Shell page's sentence. `nil` falls back to the standard path.
        var shellDirectory: String? = nil

        init(
            statusline: [String: StatuslineProducer] = [:],
            shellInstalled: Bool? = nil,
            shellDirectory: String? = nil
        ) {
            self.statusline = statusline
            self.shellInstalled = shellInstalled
            self.shellDirectory = shellDirectory
        }
    }

    var pages: [SettingsPage: [SettingsSection]]

    func sections(for page: SettingsPage) -> [SettingsSection] { pages[page] ?? [] }

    static func make(state: AppState, environment: Environment = Environment()) -> SettingsModel {
        SettingsModel(pages: [
            .general: general(state: state, environment: environment),
            .shell: shell(environment: environment),
            .appearance: appearance(state: state),
        ])
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
        return [
            SettingsSection(caption: "On launch", rows: [
                SettingsRow(
                    id: .autoResume, title: "Resume previous sessions",
                    detail: "Reopen every Claude conversation that was running when tkzmux last "
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
                    id: .notifyOnDone, title: "Notify when Claude finishes",
                    detail: "Show a macOS notification when Claude finishes a turn in a session you "
                        + "are not looking at. NEEDS YOU banners follow the system notification "
                        + "setting and have no switch of their own.",
                    control: .toggle(isOn: state.notifyOnDone)),
            ]),
            SettingsSection(caption: "Status bar", rows: statusBar),
        ]
    }

    /// One row per account, the default account first, then by key. With one account the row
    /// carries no account name; with several, each row names its own — the same rule the sidebar
    /// chip follows (nothing to say about the only account there is).
    static func statuslineRows(state: AppState, environment: Environment) -> [SettingsRow] {
        // This view is Claude-only today (it configures Claude Code's own status line), so every
        // account here carries `.claude`; comparing each against its own agent's default key
        // keeps the sort correct once a second agent's accounts can appear.
        let accounts = state.accounts.values.sorted { a, b in
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
                ? "Status line integration \u{00B7} \(account.label)"
                : "Status line integration"
            let detail: String
            let button: String
            switch producer {
            case .none:
                detail = "Let Claude Code write its usage and context into the tkzmux status bar. "
                    + "Edits \(file) only after you confirm."
                button = "Configure\u{2026}"
            case .other:
                detail = "Let Claude Code write its usage and context into the tkzmux status bar. "
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

    // MARK: Shell

    private static func shell(environment: Environment) -> [SettingsSection] {
        let directory = environment.shellDirectory ?? "~/Library/Application Support/tkzmux"
        let status: SettingsRow.Control
        switch environment.shellInstalled {
        case true?: status = .status(text: "Active", active: true)
        case false?: status = .status(text: "Not installed", active: false)
        case nil: status = .status(text: "Unavailable", active: false)
        }
        return [
            SettingsSection(caption: "Shell integration", rows: [
                SettingsRow(
                    id: .shellStatus, title: "Integration status",
                    detail: "The claude shim and the zsh, bash and fish wrappers under "
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
