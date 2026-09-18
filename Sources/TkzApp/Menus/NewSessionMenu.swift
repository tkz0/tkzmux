// NewSessionMenu.swift — the “＋ New session…” menu (M2.4).
//
// An `NSMenuToolbarItem` scoped to the selected group with
// *New worktree (claude -w)*, *In repo root (claude)*, *In another repo…* and an Account submenu;
// new worktree runs `claude -w [name]` **from the repo root**, repo root runs
// `claude`.
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
import ClaudeBridge
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
        /// Which agent's row this is. Defaults to `.claude` so every call site that predates the
        /// adapter registry keeps compiling and keeps meaning what it always meant.
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
        /// One agent's "New worktree" row, once a second adapter means the plain ``worktree`` id
        /// would be ambiguous between them. With exactly one installed adapter the plain id is
        /// used instead — see `NewSessionMenu.rebuild()` — so a Claude-only menu is unaffected.
        public static func worktree(for agent: AgentKind) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier(worktree.rawValue + "." + agent.rawValue)
        }
        /// One agent's "In repo root" row. See ``worktree(for:)``.
        public static func repoRoot(for agent: AgentKind) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier(repoRoot.rawValue + "." + agent.rawValue)
        }
        /// The disabled section header naming an agent, shown only once a second adapter is
        /// installed.
        public static func agentHeader(_ agent: AgentKind) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("tkzmux.newSession.agentHeader." + agent.rawValue)
        }
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

    /// The account a launch will use: **the group's default**,
    /// and nothing else. There is deliberately no per-menu override — one used to live here, and
    /// because it was never cleared it followed the user into every other group's menu.
    ///
    /// `nil` (a group with no default) stays `nil` rather than collapsing to `Account.defaultKey`:
    /// `SessionLauncher.environment` leaves `CLAUDE_CONFIG_DIR` unset for a `nil` key, which is how
    /// a group opts out and lets the user's shell rc pick the account.
    public var effectiveAccountKey: String? {
        group?.defaultAccountKey
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
        let installed = adapters.filter(isAdapterInstalled)
        // More than one installed adapter is what earns the per-agent section headers. With exactly
        // one the rows keep their plain identifiers and their original titles and hints, so a
        // single-agent menu is indistinguishable from the one tkzmux has always drawn — pinned by
        // `singleAdapterMenuIsTheMenuItHasAlwaysBeen`.
        let sectioned = installed.count > 1

        for adapter in installed {
            if sectioned {
                menu.addItem(sectionHeader(for: adapter, identifier: ItemID.agentHeader(adapter.kind)))
            }
            addRows(for: adapter, repoRoot: repoRoot, namespaced: sectioned)
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
        menu.addItem(accountItem(group: group, sectioned: sectioned))
    }

    /// One adapter's rows: "New worktree" only when it has the capability, "In repo root"
    /// always. `namespaced` is `true` once a second adapter is on the menu, which is what moves
    /// the identifiers off the plain ``ItemID/worktree``/``ItemID/repoRoot`` — see
    /// ``ItemID/worktree(for:)``.
    private func addRows(for adapter: any AgentAdapter, repoRoot: String?, namespaced: Bool) {
        let noRepo = "no repo \u{2014} add one to this group first"
        if adapter.capabilities.contains(.worktree) {
            let hint = adapter.launchCommand(.worktree(name: nil)) ?? ""
            let item = entry(
                title: "New worktree", hint: hint, detail: repoRoot ?? noRepo,
                enabled: repoRoot != nil, action: #selector(newWorktree(_:)))
            item.identifier = namespaced ? ItemID.worktree(for: adapter.kind) : ItemID.worktree
            item.representedObject = adapter.kind
            menu.addItem(item)
        }

        let rootHint = adapter.launchCommand(.new) ?? ""
        let root = entry(
            title: "In repo root", hint: rootHint, detail: repoRoot ?? noRepo,
            enabled: repoRoot != nil, action: #selector(newInRepoRoot(_:)))
        root.identifier = namespaced ? ItemID.repoRoot(for: adapter.kind) : ItemID.repoRoot
        root.representedObject = adapter.kind
        menu.addItem(root)
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
    /// `nil` when `agent` has no adapter registered, or when its adapter cannot make a worktree.
    /// There is deliberately no fallback command: guessing a command line for an agent we know
    /// nothing about is how you end up running the wrong binary with the wrong flags.
    public func worktreeLaunch(name: String? = nil, agent: AgentKind = .claude) -> Launch? {
        guard let group, let repoRoot = group.repoRoot else { return nil }
        guard let command = adapter(for: agent)?.launchCommand(.worktree(name: name)) else { return nil }
        return Launch(
            kind: .worktree, command: command, cwd: repoRoot,
            accountKey: effectiveAccountKey, groupID: group.id, agent: agent)
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

    /// `nil` when `agent` has no adapter registered — see ``worktreeLaunch(name:agent:)`` for why
    /// there is no fallback command.
    public func repoRootLaunch(agent: AgentKind = .claude) -> Launch? {
        guard let group, let repoRoot = group.repoRoot else { return nil }
        guard let command = adapter(for: agent)?.launchCommand(.new) else { return nil }
        return Launch(
            kind: .repoRoot, command: command, cwd: repoRoot,
            accountKey: effectiveAccountKey, groupID: group.id, agent: agent)
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
        let kind = sender.representedObject as? AgentKind ?? .claude
        guard let launch = worktreeLaunch(agent: kind) else { return }
        perform(launch)
    }

    @objc private func newInRepoRoot(_ sender: NSMenuItem) {
        let kind = sender.representedObject as? AgentKind ?? .claude
        guard let launch = repoRootLaunch(agent: kind) else { return }
        perform(launch)
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
