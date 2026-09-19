// NewSessionMenu.swift — the “＋ New session…” menu (M2.4).
//
// An `NSMenuToolbarItem` scoped to the selected group with *New worktree*, *In repo root*,
// *In another repo…*, an Agent submenu and an Account submenu. The two launch rows run **the
// group's own agent** (`Group.agent`, resolved by ``NewSessionMenu/effectiveAgent``); every other
// installed agent lives one level down under *Other agent ▸* for a one-off launch.
//
// The rule this ticket exists for: **the user must never wonder what "New session" does.** Every
// entry names its target — the group in the header, the command in a mono hint, the directory the
// child would start in, and, for the disabled entries, *why* they are disabled ("no repo"). That is
// asserted in `NewSessionMenuTests`, not left to the eye.
//
// Launching is a **stub** in this ticket: ``onLaunch`` receives the resolved
// `(command, cwd, accountKey)` and, when nothing is attached, the menu logs the exact command line
// it would run. M2.5 replaces the closure with the real `TerminalHost` call.

import AppKit
import AgentBridge
import TkzCore
import os

/// Builds and owns the group-scoped new-session menu.
///
/// Assign ``group``/``accounts`` (or call ``configure(state:groupID:)``), then hand ``menu`` to
/// `MainToolbarController.newSessionMenu`. The menu rebuilds itself in `menuNeedsUpdate(_:)`, so a
/// group rename or a new account shows up on the next open with no wiring; tests call
/// ``rebuild()`` directly.
@MainActor
public final class NewSessionMenu: NSObject, NSMenuDelegate {

    /// What a chosen entry resolves to — exactly the tuple M2.5 needs to start a session.
    public struct Launch: Hashable, Sendable {
        public enum Kind: String, Sendable {
            case worktree, repoRoot
            /// A bare login shell with nothing typed into it — the toolbar's `>_` button. The one
            /// launch that does not depend on `claude` being installed or the group being a repo.
            case shell
        }

        public let kind: Kind
        /// The command line to run in the pty, e.g. `claude -w` or `claude --permission-mode plan`.
        /// **Empty for `.shell`**: the pty opens and nothing is typed into it.
        public let command: String
        /// The directory to start in, **verbatim from the model** — tilde expansion is the real
        /// launcher's job, not the menu's.
        public let cwd: String
        /// `CLAUDE_CONFIG_DIR` selection: the group's default. `nil` — a group with no default —
        /// leaves `CLAUDE_CONFIG_DIR` unset, so the user's shell decides; see
        /// ``effectiveAccountKey``.
        public let accountKey: String?
        public let groupID: GroupID
        /// Which agent this row runs. Defaults to `.claude` so every call site that predates the
        /// adapter registry keeps compiling and keeps meaning what it always meant — but every
        /// caller inside this file now passes one, resolved from the group.
        public let agent: AgentKind

        public init(
            kind: Kind,
            command: String,
            cwd: String,
            accountKey: String?,
            groupID: GroupID,
            agent: AgentKind = .claude
        ) {
            self.kind = kind
            self.command = command
            self.cwd = cwd
            self.accountKey = accountKey
            self.groupID = groupID
            self.agent = agent
        }

        /// The one-line description the stub logs — and what the tests assert on.
        /// `cd <cwd> && CLAUDE_CONFIG_DIR=<key> claude -w`
        public var logLine: String {
            if command.isEmpty { return "cd \(cwd)" }
            var line = "cd \(cwd) && "
            if let accountKey { line += "CLAUDE_CONFIG_DIR=\(accountKey) " }
            return line + command
        }
    }

    public let menu = NSMenu()

    /// Stable identities for the menu's rows. `NSMenuItem.title` is *not* one: assigning an
    /// `attributedTitle` (which every named row does, to carry its command hint) overwrites `title`
    /// with the full rendered text. Wave 3 and the tests address rows through these.
    public enum ItemID {
        public static let header = NSUserInterfaceItemIdentifier("tkzmux.newSession.header")
        public static let worktree = NSUserInterfaceItemIdentifier("tkzmux.newSession.worktree")
        public static let repoRoot = NSUserInterfaceItemIdentifier("tkzmux.newSession.repoRoot")
        /// One agent's "New worktree" row **inside the "Other agent" submenu**. The plain
        /// ``worktree`` id above is always the top-level row, which belongs to the group's own
        /// agent; these namespaced ones address the one-off rows for the other installed agents.
        public static func worktree(for agent: AgentKind) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier(worktree.rawValue + "." + agent.rawValue)
        }
        /// One agent's "In repo root" row inside the submenu. See ``worktree(for:)``.
        public static func repoRoot(for agent: AgentKind) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier(repoRoot.rawValue + "." + agent.rawValue)
        }
        /// The disabled section header naming an agent inside the "Other agent" submenu.
        public static func agentHeader(_ agent: AgentKind) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("tkzmux.newSession.agentHeader." + agent.rawValue)
        }
        /// The "Other agent ▸" parent row. Absent when no other agent is installed.
        public static let otherAgent = NSUserInterfaceItemIdentifier("tkzmux.newSession.otherAgent")
        /// The "Agent: …" picker parent row, twin of ``account``.
        public static let agent = NSUserInterfaceItemIdentifier("tkzmux.newSession.agent")
        /// One row of the agent picker, addressed by kind.
        public static func agentRow(_ agent: AgentKind) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("tkzmux.newSession.agentRow." + agent.rawValue)
        }
        /// The group names an agent with no installed adapter; the rows below run something else
        /// and this disabled row says so. The agent twin of ``accountMissing``.
        public static let agentMissing = NSUserInterfaceItemIdentifier("tkzmux.newSession.agentMissing")
        /// Nothing is installed at all, so there is nothing to launch.
        public static let noAgent = NSUserInterfaceItemIdentifier("tkzmux.newSession.noAgent")
        /// The same, inside the Default-account submenu.
        public static func accountSectionHeader(_ agent: AgentKind) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("tkzmux.newSession.accountSectionHeader." + agent.rawValue)
        }
        public static let anotherRepo = NSUserInterfaceItemIdentifier("tkzmux.newSession.anotherRepo")
        public static let account = NSUserInterfaceItemIdentifier("tkzmux.newSession.account")
        public static let accountRow = NSUserInterfaceItemIdentifier("tkzmux.newSession.accountRow")
        /// One account row, addressed by `Account.key`.
        public static func accountRow(_ key: String) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier(accountRow.rawValue + "." + key)
        }
        public static let accountNone = NSUserInterfaceItemIdentifier("tkzmux.newSession.accountNone")
        /// The group's default names an account that is not in `state.accounts` any more.
        public static let accountMissing = NSUserInterfaceItemIdentifier("tkzmux.newSession.accountMissing")
    }

    /// The row with this identifier, in the menu or in one of its submenus.
    public func item(_ id: NSUserInterfaceItemIdentifier) -> NSMenuItem? {
        menu.items.first { $0.identifier == id }
            ?? menu.items.compactMap { $0.submenu?.items.first { $0.identifier == id } }.first
    }

    /// Sends a row's action exactly as a click would — the assembler never needs this; tests do.
    ///
    /// The action goes straight to the row's own target rather than through
    /// `NSMenu.performActionForItem(at:)`. That call routes through the shared `NSApplication`,
    /// which a test process only has if some *other* test happened to touch `NSApplication.shared`
    /// first — so this suite passed or failed depending on which suites ran before it, and failed
    /// outright when run alone. Every row here sets an explicit target, so dispatching directly is
    /// both what a click does and independent of global application state.
    ///
    /// Returns `false` when there is no such row, or when it has no target to send to.
    @discardableResult
    public func performItem(_ id: NSUserInterfaceItemIdentifier) -> Bool {
        for host in [menu] + menu.items.compactMap(\.submenu) {
            guard let item = host.items.first(where: { $0.identifier == id }) else { continue }
            guard let action = item.action, let target = item.target as? NSObject else { return false }
            target.perform(action, with: item)
            return true
        }
        return false
    }

    /// The group the menu is scoped to. `nil` builds a single disabled "No group selected" row.
    public var group: Group?
    /// Accounts by key, for the Account submenu.
    public var accounts: [String: Account] = [:]
    /// The agents this menu can start, normally the assembler's whole registry — installed and not.
    ///
    /// Defaults to Claude alone, matching `AgentIntegration` and `SessionLauncher`, so a menu built
    /// before the assembler has wired anything still offers the agent tkzmux has always launched.
    /// Empty genuinely means no agents and draws no agent rows; there is deliberately no fallback
    /// to a hard-coded command, because a second code path that only runs when the registry is
    /// missing is a path nothing exercises in production.
    public var adapters: [any AgentAdapter] = [ClaudeAdapter()]
    /// Whether an adapter's binary is on `PATH` — `AgentAdapter.isInstalled()` by default. A
    /// closure, like ``isSessionAttended`` elsewhere, so a test can mark a stub adapter
    /// "installed" without a real binary of that name existing anywhere.
    public var isAdapterInstalled: (any AgentAdapter) -> Bool = { $0.isInstalled() }
    public var theme: Theme

    /// Where a resolved launch goes. Unset = ``logStub`` (this ticket's deliverable).
    public var onLaunch: ((Launch) -> Void)?
    /// “In another repo…” — the assembler opens the repo picker / `NSOpenPanel`.
    public var onChooseAnotherRepo: (() -> Void)?
    /// The Account submenu picked a **default for one group** — `nil` clears it. The store update
    /// is the assembler's call, and it must re-``configure(state:groupID:)`` afterwards: ``group``
    /// is a value copy, so the next `menuNeedsUpdate` would otherwise rebuild from the old one.
    public var onSelectAccount: ((GroupID, String?) -> Void)?
    /// The Agent submenu picked the agent **for one group** — the twin of ``onSelectAccount``, and
    /// with the same obligation on the assembler: update the store, then re-``configure`` this
    /// menu, because ``group`` is a value copy.
    public var onSelectAgent: ((GroupID, AgentKind?) -> Void)?

    /// The last launch the menu resolved — the stub's record, and what tests read.
    public private(set) var lastLaunch: Launch?

    private static let log = Logger(subsystem: "se.tkz.tkzmux", category: "new-session")

    public init(theme: Theme = .default) {
        self.theme = theme
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        rebuild()
    }

    // MARK: Configuration

    /// Scopes the menu to one group of a state — the toolbar's `＋` and the sidebar's per-group `＋`
    /// both go through this, which is what makes the per-group button scope correctly.
    public func configure(state: AppState, groupID: GroupID?) {
        group = groupID.flatMap { state.groups[$0] }
        accounts = state.accounts
        rebuild()
    }

    /// Follows the selected session's group — the toolbar's default scope.
    public func configureForSelection(state: AppState) {
        configure(state: state, groupID: state.selectedSession?.groupID ?? state.orderedGroups.first?.id)
    }

    /// The adapters this menu can actually launch, in the order they were given.
    private var installedAdapters: [any AgentAdapter] {
        adapters.filter(isAdapterInstalled)
    }

    /// The agent the menu's top-level rows run.
    ///
    /// The group's own choice when an adapter for it is installed; otherwise Claude, which is what
    /// every call site in this app meant before `Group.agent` existed; otherwise the first
    /// installed adapter, so a machine without Claude still gets a menu that runs *something*.
    /// A substitution is never silent — see ``configuredAgentMissing``.
    public var effectiveAgent: AgentKind {
        let installed = installedAdapters
        if let configured = group?.agent, installed.contains(where: { $0.kind == configured }) {
            return configured
        }
        if installed.contains(where: { $0.kind == .claude }) { return .claude }
        return installed.first?.kind ?? .claude
    }

    /// The agent the group asked for, when nobody has an adapter for it — so the rows are running
    /// ``effectiveAgent`` instead. `nil` when the group got what it asked for.
    ///
    /// This exists so the substitution can be *stated*. Quietly running a different agent than the
    /// group is set to is the one outcome here that would genuinely confuse; the rows show what
    /// will really run, and one disabled row explains why it is not what was asked for.
    public var configuredAgentMissing: AgentKind? {
        guard let configured = group?.agent, configured != effectiveAgent else { return nil }
        return configured
    }

    /// The group's default account, but only when it names an account of `agent`'s own.
    ///
    /// This is the same rule `AppState.createSession` applies (its `groupDefaultFits`), enforced
    /// again here because `SessionLauncher.start` passes this key to `createSession(accountKey:)`
    /// **explicitly**, which short-circuits that rule. Without the filter, a group set to one agent
    /// with a default account belonging to another would point the new row's config-dir variable at
    /// a directory of the wrong shape entirely.
    ///
    /// `nil` stays `nil` rather than collapsing to `Account.defaultKey`:
    /// `SessionLauncher.environment` leaves the variable unset for a `nil` key, which is how a
    /// group opts out and lets the user's shell rc pick the account.
    public func accountKey(for agent: AgentKind) -> String? {
        guard let key = group?.defaultAccountKey else { return nil }
        return (accounts[key]?.agent ?? .claude) == agent ? key : nil
    }

    /// The account a launch of the group's own agent will use: **the group's default**, filtered by
    /// ``accountKey(for:)``. There is deliberately no per-menu override — one used to live here,
    /// and because it was never cleared it followed the user into every other group's menu.
    public var effectiveAccountKey: String? {
        accountKey(for: effectiveAgent)
    }

    // MARK: Menu construction

    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    /// Rebuilds the menu from the current group/accounts.
    public func rebuild() {
        menu.removeAllItems()

        guard let group else {
            menu.addItem(disabled(title: "No group selected"))
            return
        }

        // Header — the group is named before anything else, so "New session" is never ambiguous.
        let header = disabled(title: "New session in \(group.name)")
        header.identifier = ItemID.header
        header.attributedTitle = NSAttributedString(
            string: header.title,
            attributes: [
                .font: Theme.Fonts.ui(theme.fontUI.caption, weight: .semibold),
                .foregroundColor: theme.foregroundMuted.nsColor,
            ])
        menu.addItem(header)

        let repoRoot = group.repoRoot
        let installed = installedAdapters
        // The menu used to emit a block of rows *per installed adapter*, which grew it linearly
        // with the agent count. The group decides now: the top-level rows are this group's agent's,
        // and the others are one level down under "Other agent".
        let chosen = effectiveAgent
        let sectioned = installed.count > 1

        if let missing = configuredAgentMissing {
            let name = adapters.first { $0.kind == missing }?.displayName ?? missing.rawValue
            let running = adapters.first { $0.kind == chosen }?.displayName ?? chosen.rawValue
            let row = disabled(title: name)
            row.identifier = ItemID.agentMissing
            row.attributedTitle = attributed(
                title: name, hint: nil, detail: "not installed \u{2014} using \(running)", enabled: false)
            menu.addItem(row)
        }

        if let adapter = installed.first(where: { $0.kind == chosen }) {
            addRows(for: adapter, repoRoot: repoRoot, namespaced: false)
        } else {
            // Nothing installed at all. Drawing nothing here would leave a menu that is silently
            // two rows long and never says why.
            let none = disabled(title: "No agent installed")
            none.identifier = ItemID.noAgent
            none.attributedTitle = attributed(
                title: "No agent installed", hint: nil, detail: "nothing to run", enabled: false)
            menu.addItem(none)
        }

        // Omitted entirely, not drawn disabled, when there is nothing else to offer: an empty
        // submenu is noise, and leaving it out keeps a single-agent install almost exactly the
        // menu tkzmux has always drawn.
        let others = installed.filter { $0.kind != chosen }
        if !others.isEmpty {
            menu.addItem(otherAgentItem(others, repoRoot: repoRoot))
        }

        let another = entry(
            title: "In another repo\u{2026}",
            hint: nil,
            detail: "choose a folder \u{2014} it becomes a new group",
            enabled: true,
            action: #selector(chooseAnotherRepo(_:))
        )
        another.identifier = ItemID.anotherRepo
        menu.addItem(another)

        menu.addItem(.separator())
        menu.addItem(agentItem(group: group, chosen: chosen, installed: installed))
        menu.addItem(accountItem(group: group, sectioned: sectioned))
    }

    /// "Other agent ▸": the one-off escape hatch. Every other installed agent's own rows, under its
    /// own header.
    ///
    /// The headers appear here **unconditionally**, even with a single other agent — which is a
    /// deliberately different rule from the one the top level used to use (`installed.count > 1`).
    /// These rows are otherwise indistinguishable from the ones above them: two rows reading "New
    /// worktree" and "In repo root" with nothing naming whose they are.
    private func otherAgentItem(_ others: [any AgentAdapter], repoRoot: String?) -> NSMenuItem {
        let item = NSMenuItem(title: "Other agent", action: nil, keyEquivalent: "")
        item.identifier = ItemID.otherAgent
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (offset, adapter) in others.enumerated() {
            if offset > 0 { submenu.addItem(.separator()) }
            submenu.addItem(
                sectionHeader(for: adapter, identifier: ItemID.agentHeader(adapter.kind)))
            for row in rows(for: adapter, repoRoot: repoRoot, namespaced: true) {
                submenu.addItem(row)
            }
        }
        item.submenu = submenu
        return item
    }

    /// "Agent: … ▸": which agent **every new session in this group** starts.
    ///
    /// Twin of ``accountItem(group:sectioned:)``, with one deliberate difference: there is no
    /// "None" row. "None" for an account means "leave the config-dir variable unset", which is a
    /// real launch; "None" for an agent would mean "this menu has no top-level rows". A group
    /// always resolves to some agent, so `Group.agent == nil` simply shows the resolved one
    /// checked, and picking a row is how you pin it.
    private func agentItem(
        group: Group, chosen: AgentKind, installed: [any AgentAdapter]
    ) -> NSMenuItem {
        let name = adapters.first { $0.kind == chosen }?.displayName ?? chosen.rawValue
        let item = NSMenuItem(title: "Agent: \(name)", action: nil, keyEquivalent: "")
        item.identifier = ItemID.agent
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for adapter in installed {
            let row = NSMenuItem(
                title: adapter.displayName, action: #selector(selectAgentItem(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = GroupAgentChoice(groupID: group.id, agent: adapter.kind)
            row.identifier = ItemID.agentRow(adapter.kind)
            row.state = adapter.kind == chosen ? .on : .off
            row.attributedTitle = attributed(
                title: adapter.displayName, hint: adapter.launchCommand(.new), detail: nil,
                enabled: true)
            submenu.addItem(row)
        }
        // A group pointing at an agent nobody has installed keeps its row, checked, exactly the way
        // `accountMissing` does: the group really is still set to it, and only the user can decide
        // where to point it instead.
        if let missing = configuredAgentMissing {
            let name = adapters.first { $0.kind == missing }?.displayName ?? missing.rawValue
            let row = disabled(title: name)
            row.state = .on
            row.identifier = ItemID.agentRow(missing)
            row.attributedTitle = attributed(
                title: name, hint: nil, detail: "not installed", enabled: false)
            submenu.addItem(row)
        }
        if installed.isEmpty && configuredAgentMissing == nil {
            submenu.addItem(disabled(title: "No agents installed"))
        }
        item.submenu = submenu
        return item
    }

    /// Which group, and which agent — the agent twin of ``GroupAccountChoice``'s role in
    /// `MainWindowController`, for the same reason: a menu row carries one `representedObject`.
    private struct GroupAgentChoice {
        let groupID: GroupID
        let agent: AgentKind
    }

    /// One adapter's rows, appended to the menu itself. See ``rows(for:repoRoot:namespaced:)``.
    private func addRows(for adapter: any AgentAdapter, repoRoot: String?, namespaced: Bool) {
        for row in rows(for: adapter, repoRoot: repoRoot, namespaced: namespaced) {
            menu.addItem(row)
        }
    }

    /// One adapter's rows: "New worktree" only when it has the capability, "In repo root" always.
    ///
    /// **No worktree row means no worktree row** — not a disabled one. tkzmux does not create git
    /// worktrees itself (TKZ-87), so for an agent with no worktree flag of its own there is nothing
    /// the entry could ever do. The disabled-with-a-reason rows elsewhere in this menu all describe
    /// conditions the user can act on ("no repo — add one to this group first"); a row explaining a
    /// permanent fact of the agent would be a dead line on every open.
    ///
    /// `namespaced` moves the identifiers off the plain ``ItemID/worktree``/``ItemID/repoRoot``,
    /// which the top-level rows keep; it is `true` for the "Other agent" submenu's copies.
    private func rows(
        for adapter: any AgentAdapter, repoRoot: String?, namespaced: Bool
    ) -> [NSMenuItem] {
        let noRepo = "no repo \u{2014} add one to this group first"
        var out: [NSMenuItem] = []
        if adapter.capabilities.contains(.worktree) {
            let hint = adapter.launchCommand(.worktree(name: nil)) ?? ""
            let item = entry(
                title: "New worktree", hint: hint, detail: repoRoot ?? noRepo,
                enabled: repoRoot != nil, action: #selector(newWorktree(_:)))
            item.identifier = namespaced ? ItemID.worktree(for: adapter.kind) : ItemID.worktree
            item.representedObject = adapter.kind
            out.append(item)
        }

        let rootHint = adapter.launchCommand(.new) ?? ""
        let root = entry(
            title: "In repo root", hint: rootHint, detail: repoRoot ?? noRepo,
            enabled: repoRoot != nil, action: #selector(newInRepoRoot(_:)))
        root.identifier = namespaced ? ItemID.repoRoot(for: adapter.kind) : ItemID.repoRoot
        root.representedObject = adapter.kind
        out.append(root)
        return out
    }

    /// A disabled row naming an agent — the section header above its rows, or above its accounts
    /// in the Default-account submenu.
    private func sectionHeader(
        for adapter: any AgentAdapter, identifier: NSUserInterfaceItemIdentifier
    ) -> NSMenuItem {
        let item = disabled(title: adapter.displayName)
        item.identifier = identifier
        item.attributedTitle = NSAttributedString(
            string: adapter.displayName,
            attributes: [
                .font: Theme.Fonts.ui(theme.fontUI.caption, weight: .semibold),
                .foregroundColor: theme.foregroundMuted.nsColor,
            ])
        return item
    }

    /// The adapter this menu knows for `kind`, or `nil` when ``adapters`` has nothing for it —
    /// the legacy-registry case, and the ordinary case for an agent nobody has installed.
    private func adapter(for kind: AgentKind) -> (any AgentAdapter)? {
        adapters.first { $0.kind == kind }
    }

    /// "Default account ▸": which account **every new session in this group** gets.
    ///
    /// Picking a row writes `Group.defaultAccountKey` through ``onSelectAccount``, so it persists to
    /// `state.json` and stays with the group. The checkmark therefore *is* the group default and no
    /// row has to say so in words.
    ///
    /// Changing it affects new sessions only: a running one already has `CLAUDE_CONFIG_DIR` in its
    /// child environment, and its `Session.accountKey` follows what the process actually reports
    /// (`AgentIntegration.learnAccount`), not what was asked for.
    private func accountItem(group: Group, sectioned: Bool) -> NSMenuItem {
        let current = group.defaultAccountKey
        let known = current.flatMap { accounts[$0] }
        let label = current.map { known?.label ?? $0 } ?? "none"
        let item = NSMenuItem(title: "Default account: \(label)", action: nil, keyEquivalent: "")
        item.identifier = ItemID.account
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // Unchanged with one agent: a flat, key-sorted list. Grouped only once a second adapter
        // means "which agent is this account for" is no longer obvious from the list alone.
        if sectioned {
            for adapter in adapters.filter(isAdapterInstalled) {
                let keys = accounts.keys.filter { accounts[$0]?.agent == adapter.kind }.sorted()
                guard !keys.isEmpty else { continue }
                submenu.addItem(sectionHeader(for: adapter, identifier: ItemID.accountSectionHeader(adapter.kind)))
                for key in keys { submenu.addItem(accountRow(key: key, current: current)) }
            }
        } else {
            for key in accounts.keys.sorted() {
                submenu.addItem(accountRow(key: key, current: current))
            }
        }
        if accounts.isEmpty {
            submenu.addItem(disabled(title: "No accounts configured"))
        }
        // A default whose config dir has gone away stays visible and checked. Leaving every row
        // unchecked would read as "no default", when the group really is still pointing at that
        // key — and only the user can decide where to point it instead.
        if let current, known == nil {
            let missing = disabled(title: current)
            missing.state = .on
            missing.identifier = ItemID.accountMissing
            missing.attributedTitle = attributed(
                title: current, hint: nil, detail: "not found", enabled: false)
            submenu.addItem(missing)
        }
        submenu.addItem(.separator())
        let none = NSMenuItem(title: "None", action: #selector(selectNoAccountItem(_:)), keyEquivalent: "")
        none.target = self
        none.identifier = ItemID.accountNone
        none.state = current == nil ? .on : .off
        none.attributedTitle = attributed(
            title: "None", hint: nil,
            detail: "inherit \u{2014} CLAUDE_CONFIG_DIR left unset", enabled: true)
        submenu.addItem(none)
        item.submenu = submenu
        return item
    }

    // MARK: Item helpers

    /// One row of the Default-account submenu: the account's label, its config dir as the detail,
    /// and the checkmark for the group's current default.
    private func accountRow(key: String, current: String?) -> NSMenuItem {
        let account = accounts[key]
        let row = NSMenuItem(
            title: account?.label ?? key, action: #selector(selectAccountItem(_:)), keyEquivalent: "")
        row.target = self
        row.representedObject = key
        row.identifier = ItemID.accountRow(key)
        row.state = key == current ? .on : .off
        // Name the target: which config dir this account means.
        row.attributedTitle = attributed(
            title: row.title, hint: nil, detail: account?.configDir ?? key, enabled: true)
        return row
    }

    private func disabled(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func entry(
        title: String, hint: String?, detail: String?, enabled: Bool, action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = enabled ? self : nil
        item.isEnabled = enabled
        item.attributedTitle = attributed(title: title, hint: hint, detail: detail, enabled: enabled)
        item.toolTip = [title, hint, detail].compactMap { $0 }.joined(separator: " \u{2014} ")
        return item
    }

    /// `New worktree  claude -w  ~/dev/northwind` — the command hint in the mono face, the target
    /// directory dim behind it.
    private func attributed(title: String, hint: String?, detail: String?, enabled: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: Theme.Fonts.ui(theme.fontUI.body),
                .foregroundColor: (enabled ? theme.foreground : theme.foregroundDim).nsColor,
            ])
        if let hint, !hint.isEmpty {
            out.append(
                NSAttributedString(
                    string: "   \(hint)",
                    attributes: [
                        .font: Theme.Fonts.mono(theme.fontMono.detail),
                        .foregroundColor: theme.accent.nsColor,
                    ]))
        }
        if let detail, !detail.isEmpty {
            out.append(
                NSAttributedString(
                    string: "   \(detail)",
                    attributes: [
                        .font: Theme.Fonts.ui(theme.fontUI.caption),
                        .foregroundColor: theme.foregroundDim.nsColor,
                    ]))
        }
        return out
    }

    // MARK: Resolution

    /// A worktree session, started from the repo root — the agent creates the worktree itself and
    /// chdirs into it, which is why this launches from the *main* checkout.
    ///
    /// `agent` defaults to the group's own (``effectiveAgent``); the "Other agent" rows pass one
    /// explicitly. `nil` when that agent has no adapter registered, or when its adapter cannot make
    /// a worktree. There is deliberately no fallback command: guessing a command line for an agent
    /// we know nothing about is how you end up running the wrong binary with the wrong flags.
    public func worktreeLaunch(name: String? = nil, agent: AgentKind? = nil) -> Launch? {
        guard let group, let repoRoot = group.repoRoot else { return nil }
        let agent = agent ?? effectiveAgent
        guard let command = adapter(for: agent)?.launchCommand(.worktree(name: name)) else { return nil }
        return Launch(
            kind: .worktree, command: command, cwd: repoRoot,
            accountKey: accountKey(for: agent), groupID: group.id, agent: agent)
    }

    /// A bare login shell in the group's directory. The toolbar's `>_` ("new terminal") button.
    ///
    /// Unlike the two `claude` rows this does **not** need `group.repoRoot`: any group can host a
    /// shell, and a bucket group falls back to `fallbackDirectory`.
    public func shellLaunch(fallbackDirectory: String = "~") -> Launch? {
        guard let group else { return nil }
        return Launch(
            kind: .shell,
            command: "",
            cwd: group.repoRoot ?? fallbackDirectory,
            accountKey: effectiveAccountKey,
            groupID: group.id)
    }

    /// `agent` defaults to the group's own (``effectiveAgent``). `nil` when it has no adapter
    /// registered — see ``worktreeLaunch(name:agent:)`` for why there is no fallback command.
    public func repoRootLaunch(agent: AgentKind? = nil) -> Launch? {
        guard let group, let repoRoot = group.repoRoot else { return nil }
        let agent = agent ?? effectiveAgent
        guard let command = adapter(for: agent)?.launchCommand(.new) else { return nil }
        return Launch(
            kind: .repoRoot, command: command, cwd: repoRoot,
            accountKey: accountKey(for: agent), groupID: group.id, agent: agent)
    }

    /// Hands a resolved launch to ``onLaunch``, or logs it. Public so the assembler can replay one.
    public func perform(_ launch: Launch) {
        lastLaunch = launch
        if let onLaunch {
            onLaunch(launch)
        } else {
            logStub(launch)
        }
    }

    /// This ticket's deliverable: say exactly what would run, and run nothing.
    private func logStub(_ launch: Launch) {
        Self.log.info("new session (stub, nothing started): \(launch.logLine, privacy: .public)")
        FileHandle.standardError.write(Data("tkzmux: would run: \(launch.logLine)\n".utf8))
    }

    // MARK: Actions

    @objc private func newWorktree(_ sender: NSMenuItem) {
        guard let launch = worktreeLaunch(agent: sender.representedObject as? AgentKind) else { return }
        perform(launch)
    }

    @objc private func newInRepoRoot(_ sender: NSMenuItem) {
        guard let launch = repoRootLaunch(agent: sender.representedObject as? AgentKind) else { return }
        perform(launch)
    }

    @objc private func selectAgentItem(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? GroupAgentChoice else { return }
        onSelectAgent?(choice.groupID, choice.agent)
    }

    @objc private func chooseAnotherRepo(_ sender: NSMenuItem) {
        onChooseAnotherRepo?()
    }

    @objc private func selectAccountItem(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let group else { return }
        onSelectAccount?(group.id, key)
    }

    /// "None": clear the group's default, so the agent's config-dir variable is left unset again.
    @objc private func selectNoAccountItem(_ sender: NSMenuItem) {
        guard let group else { return }
        onSelectAccount?(group.id, nil)
    }
}
