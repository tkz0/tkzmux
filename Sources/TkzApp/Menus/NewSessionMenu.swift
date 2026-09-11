// NewSessionMenu.swift — the “＋ New session…” menu (M2.4 / TKZ-20).
//
// design.md → App architecture → Toolbar: an `NSMenuToolbarItem` scoped to the selected group with
// *New worktree (claude -w)*, *In repo root (claude)*, *In another repo…* and an Account submenu;
// → Session flows: new worktree runs `claude -w [name]` **from the repo root**, repo root runs
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

        public init(
            kind: Kind,
            command: String,
            cwd: String,
            accountKey: String?,
            groupID: GroupID
        ) {
            self.kind = kind
            self.command = command
            self.cwd = cwd
            self.accountKey = accountKey
            self.groupID = groupID
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
    @discardableResult
    public func performItem(_ id: NSUserInterfaceItemIdentifier) -> Bool {
        for host in [menu] + menu.items.compactMap(\.submenu) {
            if let index = host.items.firstIndex(where: { $0.identifier == id }) {
                host.performActionForItem(at: index)
                return true
            }
        }
        return false
    }

    /// The group the menu is scoped to. `nil` builds a single disabled "No group selected" row.
    public var group: Group?
    /// Accounts by key, for the Account submenu.
    public var accounts: [String: Account] = [:]
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

        let worktree = entry(
            title: "New worktree",
            hint: "claude -w",
            detail: repoRoot ?? "no repo \u{2014} add one to this group first",
            enabled: repoRoot != nil,
            action: #selector(newWorktree)
        )
        worktree.identifier = ItemID.worktree
        menu.addItem(worktree)

        let root = entry(
            title: "In repo root",
            hint: "claude",
            detail: repoRoot ?? "no repo \u{2014} add one to this group first",
            enabled: repoRoot != nil,
            action: #selector(newInRepoRoot)
        )
        root.identifier = ItemID.repoRoot
        menu.addItem(root)

        let another = entry(
            title: "In another repo\u{2026}",
            hint: nil,
            detail: "choose a folder \u{2014} it becomes a new group",
            enabled: true,
            action: #selector(chooseAnotherRepo)
        )
        another.identifier = ItemID.anotherRepo
        menu.addItem(another)

        menu.addItem(.separator())
        menu.addItem(accountItem(group: group))
    }

    /// "Default account ▸": which account **every new session in this group** gets.
    ///
    /// Picking a row writes `Group.defaultAccountKey` through ``onSelectAccount``, so it persists to
    /// `state.json` and stays with the group. The checkmark therefore *is* the group default and no
    /// row has to say so in words.
    ///
    /// Changing it affects new sessions only: a running one already has `CLAUDE_CONFIG_DIR` in its
    /// child environment, and its `Session.accountKey` follows what the process actually reports
    /// (`ClaudeIntegration.learnAccount`), not what was asked for.
    private func accountItem(group: Group) -> NSMenuItem {
        let current = group.defaultAccountKey
        let known = current.flatMap { accounts[$0] }
        let label = current.map { known?.label ?? $0 } ?? "none"
        let item = NSMenuItem(title: "Default account: \(label)", action: nil, keyEquivalent: "")
        item.identifier = ItemID.account
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for key in accounts.keys.sorted() {
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
            submenu.addItem(row)
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
        let none = NSMenuItem(title: "None", action: #selector(selectNoAccountItem), keyEquivalent: "")
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

    /// `claude -w` from the repo root — design.md: a worktree is created *from the main checkout*.
    public func worktreeLaunch(name: String? = nil) -> Launch? {
        guard let group, let repoRoot = group.repoRoot else { return nil }
        let command = name.map { "claude -w \($0)" } ?? "claude -w"
        return Launch(
            kind: .worktree, command: command, cwd: repoRoot,
            accountKey: effectiveAccountKey, groupID: group.id)
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

    public func repoRootLaunch() -> Launch? {
        guard let group, let repoRoot = group.repoRoot else { return nil }
        return Launch(
            kind: .repoRoot, command: "claude", cwd: repoRoot,
            accountKey: effectiveAccountKey, groupID: group.id)
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

    @objc private func newWorktree() {
        guard let launch = worktreeLaunch() else { return }
        perform(launch)
    }

    @objc private func newInRepoRoot() {
        guard let launch = repoRootLaunch() else { return }
        perform(launch)
    }

    @objc private func chooseAnotherRepo() {
        onChooseAnotherRepo?()
    }

    @objc private func selectAccountItem(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let group else { return }
        onSelectAccount?(group.id, key)
    }

    /// "None": clear the group's default, so `CLAUDE_CONFIG_DIR` is left unset again.
    @objc private func selectNoAccountItem() {
        guard let group else { return }
        onSelectAccount?(group.id, nil)
    }
}
