import AppKit
import Foundation
import Testing
import TkzCore

@testable import TkzApp

/// The “＋ New session…” menu and the shortcut table (TKZ-20, M2.4).
///
/// The UX rule the ticket exists for is asserted literally: **every entry names its target** — the
/// group in the header, the command in a mono hint, the directory, and the reason a disabled entry
/// is disabled.
@MainActor
struct NewSessionMenuTests {

    static let state = AppState.fixture
    static let frontinvest = Fixture.groupID(0)   // Almi FrontInvest, ~/dev/frontinvest, claude-alt
    static let scheduled = Fixture.groupID(2)     // Scheduled — a bucket with no repo, claude
    static let aira = Fixture.groupID(3)          // Aira, ~/dev/aira, claude

    static func menu(for groupID: GroupID) -> NewSessionMenu {
        let menu = NewSessionMenu()
        menu.configure(state: state, groupID: groupID)
        return menu
    }

    static func titles(_ menu: NewSessionMenu) -> [String] {
        menu.menu.items.map(\.title)
    }

    /// The full visible text of an item — plain title plus the attributed hint and detail.
    static func text(_ item: NSMenuItem) -> String {
        item.attributedTitle?.string ?? item.title
    }

    /// Rows are addressed by identifier, never by title: an `attributedTitle` (which every named
    /// row has, to carry its command hint) overwrites `NSMenuItem.title` with the rendered text.
    static func item(_ menu: NewSessionMenu, _ id: NSUserInterfaceItemIdentifier) -> NSMenuItem? {
        menu.item(id)
    }

    // MARK: Content

    @Test func namesTheGroupAndEveryTarget() throws {
        let menu = Self.menu(for: Self.frontinvest)
        #expect(Self.text(menu.item(NewSessionMenu.ItemID.header)!) == "New session in Almi FrontInvest")

        let worktree = try #require(Self.item(menu, NewSessionMenu.ItemID.worktree))
        #expect(Self.text(worktree).contains("claude -w"), "the command must be visible")
        #expect(Self.text(worktree).contains("~/dev/frontinvest"), "the target directory must be visible")
        #expect(worktree.isEnabled)

        let root = try #require(Self.item(menu, NewSessionMenu.ItemID.repoRoot))
        #expect(Self.text(root).contains("claude"))
        #expect(Self.text(root).contains("~/dev/frontinvest"))

        let another = try #require(Self.item(menu, NewSessionMenu.ItemID.anotherRepo))
        #expect(another.isEnabled)
        #expect(Self.text(another).contains("new group"))

        // The command hints are in the mono face (design.md: JetBrains Mono for command text).
        let hintFont = worktree.attributedTitle?.attribute(
            .font, at: Self.text(worktree).distance(
                from: Self.text(worktree).startIndex,
                to: Self.text(worktree).range(of: "claude -w")!.lowerBound),
            effectiveRange: nil) as? NSFont
        #expect(hintFont?.fontName == Theme.Fonts.mono(Theme.default.fontMono.detail).fontName)
    }

    @Test func presetsSubmenuCountsAndNamesEachPreset() throws {
        let menu = Self.menu(for: Self.frontinvest)
        let presets = try #require(Self.item(menu, NewSessionMenu.ItemID.presets))
        #expect(presets.title == "From preset\u{2026} (3 saved)")
        // Three presets, a separator, and "Manage presets…" (M5.2).
        #expect(presets.submenu?.items.count == 5)
        #expect(presets.submenu?.items.filter { $0.identifier == NewSessionMenu.ItemID.presetRow }.count == 3)
        let first = try #require(presets.submenu?.items.first)
        #expect(Self.text(first).hasPrefix("Worktree from ticket"))
        #expect(Self.text(first).contains("claude -w"))
        #expect(Self.text(first).contains("~/dev/frontinvest"))
        let manage = try #require(presets.submenu?.items.last)
        #expect(manage.identifier == NewSessionMenu.ItemID.managePresets)
        var asked = 0
        menu.onManagePresets = { asked += 1 }
        #expect(menu.performItem(NewSessionMenu.ItemID.managePresets))
        #expect(asked == 1)

        // Nothing saved → the entry says so, and the submenu still offers "Manage presets…" so the
        // first preset can be made from here.
        let empty = NewSessionMenu()
        var bare = Self.state
        bare.presets = []
        empty.configure(state: bare, groupID: Self.frontinvest)
        let none = try #require(Self.item(empty, NewSessionMenu.ItemID.presets))
        #expect(none.title == "From preset\u{2026} (none saved)")
        #expect(none.isEnabled)
        #expect(none.submenu?.items.count == 1)
        #expect(none.submenu?.items.first?.identifier == NewSessionMenu.ItemID.managePresets)
    }

    @Test func accountSubmenuDefaultsToTheGroupsAccount() throws {
        let menu = Self.menu(for: Self.frontinvest)
        #expect(menu.effectiveAccountKey == "claude-alt")
        let account = try #require(Self.item(menu, NewSessionMenu.ItemID.account))
        #expect(account.title == "Account: Claude (alt)")
        let rows = try #require(account.submenu?.items)
        #expect(rows.map { $0.representedObject as? String } == ["claude", "claude-alt"])
        #expect(Self.text(rows[0]).hasPrefix("Claude   "))
        #expect(Self.text(rows[1]).hasPrefix("Claude (alt)   "))
        #expect(rows.first { $0.representedObject as? String == "claude-alt" }?.state == .on)
        #expect(rows.first { $0.representedObject as? String == "claude" }?.state == .off)
        // Each row names the config dir it means, and which one is the group's default.
        #expect(Self.text(rows[1]).contains("~/.claude-alt"))
        #expect(Self.text(rows[1]).contains("group default"))

        // Picking one overrides the group default until the menu is re-scoped.
        var picked: String?
        menu.onSelectAccount = { picked = $0 }
        menu.selectAccount("claude")
        #expect(picked == "claude")
        #expect(menu.effectiveAccountKey == "claude")
        #expect(menu.worktreeLaunch()?.accountKey == "claude")
    }

    @Test func contentFollowsTheSelectedGroup() throws {
        let menu = NewSessionMenu()
        menu.configure(state: Self.state, groupID: Self.frontinvest)
        #expect(Self.text(menu.item(NewSessionMenu.ItemID.header)!) == "New session in Almi FrontInvest")
        #expect(menu.worktreeLaunch()?.cwd == "~/dev/frontinvest")
        #expect(menu.effectiveAccountKey == "claude-alt")

        // The sidebar's per-group ＋ scopes the same object to another group.
        menu.configure(state: Self.state, groupID: Self.aira)
        #expect(Self.text(menu.item(NewSessionMenu.ItemID.header)!) == "New session in Aira")
        #expect(menu.worktreeLaunch()?.cwd == "~/dev/aira")
        #expect(menu.effectiveAccountKey == "claude")
        let account = try #require(Self.item(menu, NewSessionMenu.ItemID.account))
        #expect(account.title == "Account: Claude")

        // No group at all is still an explanation, not an empty menu.
        menu.configure(state: Self.state, groupID: nil)
        #expect(Self.titles(menu) == ["No group selected"])
    }

    @Test func aGroupWithNoRepoDisablesButStillNamesTheEntries() throws {
        let menu = Self.menu(for: Self.scheduled)
        #expect(Self.text(menu.item(NewSessionMenu.ItemID.header)!) == "New session in Scheduled")
        for (name, id) in [("New worktree", NewSessionMenu.ItemID.worktree), ("In repo root", NewSessionMenu.ItemID.repoRoot)] {
            let item = try #require(menu.item(id))
            #expect(item.isEnabled == false)
            #expect(Self.text(item).contains("no repo"), "\(name) must say why it is disabled")
        }
        #expect(menu.worktreeLaunch() == nil)
        #expect(menu.repoRootLaunch() == nil)
        // "In another repo…" is exactly the way out, so it stays enabled.
        #expect(menu.item(NewSessionMenu.ItemID.anotherRepo)!.isEnabled)
    }

    @Test func rebuildsWhenTheMenuOpens() throws {
        let menu = Self.menu(for: Self.frontinvest)
        var renamed = Self.state
        renamed.groups[Self.frontinvest]!.name = "Renamed"
        menu.group = renamed.groups[Self.frontinvest]
        menu.menuNeedsUpdate(menu.menu)
        #expect(Self.text(menu.item(NewSessionMenu.ItemID.header)!) == "New session in Renamed")
    }

    // MARK: The launcher stub

    @Test func launcherStubReportsTheExactCommandAndCwd() throws {
        let menu = Self.menu(for: Self.frontinvest)
        var launches: [NewSessionMenu.Launch] = []
        menu.onLaunch = { launches.append($0) }

        // Driven through the menu item, i.e. what a click does.
        #expect(menu.performItem(NewSessionMenu.ItemID.worktree))
        #expect(menu.performItem(NewSessionMenu.ItemID.repoRoot))

        #expect(launches.count == 2)
        #expect(launches.first?.kind == .worktree)
        #expect(launches.first?.command == "claude -w")
        #expect(launches.first?.cwd == "~/dev/frontinvest", "the path is passed through verbatim")
        #expect(launches.first?.accountKey == "claude-alt")
        #expect(launches.first?.groupID == Self.frontinvest)
        #expect(launches.first?.logLine == "cd ~/dev/frontinvest && CLAUDE_CONFIG_DIR=claude-alt claude -w")

        #expect(launches.last?.kind == .repoRoot)
        #expect(launches.last?.command == "claude")
        #expect(launches.last?.logLine == "cd ~/dev/frontinvest && CLAUDE_CONFIG_DIR=claude-alt claude")

        // The menu also records the last resolved launch, which is what the no-closure stub logs.
        #expect(menu.lastLaunch == launches.last)
    }

    @Test func presetLaunchesResolveCommandCwdAndAccount() throws {
        let menu = Self.menu(for: Self.frontinvest)
        var launches: [NewSessionMenu.Launch] = []
        menu.onLaunch = { launches.append($0) }

        let presets = try #require(Self.item(menu, NewSessionMenu.ItemID.presets))
        presets.submenu!.performActionForItem(at: 2)   // "Plan mode": claude --permission-mode plan
        #expect(launches.first?.command == "claude --permission-mode plan")
        #expect(launches.first?.cwd == "~/dev/frontinvest")
        #expect(launches.first?.accountKey == "claude", "the preset's own account wins over the group's")
        #expect(launches.first?.presetID == Self.state.presets[2].id)

        // A named worktree preset passes the name to -w; a fixed cwd is used verbatim.
        let named = Preset(name: "Ticket", command: "claude -w", cwdMode: .worktree(name: "tkz-20"))
        #expect(menu.launch(for: named)?.command == "claude -w tkz-20")
        #expect(menu.launch(for: named)?.cwd == "~/dev/frontinvest", "a worktree starts from the main checkout")
        let fixed = Preset(name: "Elsewhere", command: "claude", cwdMode: .fixed(path: "~/dev/other"))
        #expect(menu.launch(for: fixed)?.cwd == "~/dev/other")
        #expect(menu.launch(for: fixed)?.accountKey == "claude-alt", "no preset account → the group's")
    }

    @Test func anotherRepoIsHandedToTheAssembler() throws {
        let menu = Self.menu(for: Self.frontinvest)
        var asked = 0
        menu.onChooseAnotherRepo = { asked += 1 }
        #expect(menu.performItem(NewSessionMenu.ItemID.anotherRepo))
        #expect(asked == 1)
    }

    // MARK: - The shell launch (M2.5 / TKZ-43)

    @Test("A shell launch carries no command and works for a bucket group too")
    func shellLaunchNeedsNoRepo() throws {
        // A repo group starts in its root.
        let repo = try #require(Self.menu(for: Self.frontinvest).shellLaunch())
        #expect(repo.kind == .shell)
        #expect(repo.command.isEmpty)
        #expect(repo.cwd == "~/dev/frontinvest")
        // ...and the log line says so without a dangling `&&`.
        #expect(repo.logLine == "cd ~/dev/frontinvest")

        // A bucket has no repo root, so the two `claude` rows are dead — but a shell is not.
        let bucketMenu = Self.menu(for: Self.scheduled)
        #expect(bucketMenu.repoRootLaunch() == nil)
        let bucket = try #require(bucketMenu.shellLaunch(fallbackDirectory: "/tmp"))
        #expect(bucket.cwd == "/tmp")

        #expect(NewSessionMenu().shellLaunch() == nil, "no group selected, no launch")
    }
}

/// design.md → Decisions → Shortcuts. The table is data; wave 3 builds the menu from it.
@MainActor
struct ShortcutsTableTests {

    @Test func cmuxDefaults() throws {
        let expected: [(ShortcutAction, String, ShortcutModifiers)] = [
            (.newSession, "n", .command),
            (.searchSessions, "p", .command),
            (.commandPalette, "p", [.shift, .command]),
            (.toggleSidebar, "b", .command),
            (.renameSession, "r", [.shift, .command]),
            (.closeTerminal, "w", .command),
            (.closeSession, "w", [.shift, .command]),
            (.jumpToNeedsYou, "u", [.shift, .command]),
            (.notifications, "i", .command),
            (.settings, ",", .command),
            (.openFolder, "o", .command),
            (.reloadConfig, ",", [.shift, .command]),
        ]
        for (action, key, modifiers) in expected {
            let shortcut = ShortcutsTable.defaults[action]
            #expect(shortcut?.keyEquivalent == key, "\(action) key")
            #expect(shortcut?.modifiers == modifiers, "\(action) modifiers")
        }
        for n in 1...9 {
            #expect(ShortcutsTable.defaults[.selectSession(n)] == Shortcut("\(n)", .command))
        }
        // ⌘T / ⌘D are reserved and next/previous have no cmux default — override-only.
        #expect(ShortcutsTable.defaults[.nextSession] == nil)
        #expect(ShortcutsTable.defaults[.previousSession] == nil)
        #expect(!ShortcutsTable.defaults.values.contains { $0 == Shortcut("t", .command) })
        #expect(!ShortcutsTable.defaults.values.contains { $0 == Shortcut("d", .command) })
    }

    @Test func keyEquivalentsAreLowercaseWithAnExplicitShiftBit() throws {
        // AppKit accepts "P" too, but mixing the two spellings is how duplicate menu keys happen.
        for shortcut in ShortcutsTable.defaults.values {
            #expect(shortcut.keyEquivalent == shortcut.keyEquivalent.lowercased())
        }
        #expect(ShortcutsTable.defaults[.commandPalette]?.modifierMask == [.shift, .command])
        #expect(ShortcutsTable.defaults[.searchSessions]?.modifierMask == [.command])
    }

    @Test func appStateOverridesWin() throws {
        // The fixture rebinds ⌘N → ⌘T and ⌘B → ⌃⌘S, and adds next/previous.
        let table = ShortcutsTable.resolved(state: AppState.fixture)
        #expect(table[.newSession] == Shortcut("t", .command))
        #expect(table[.toggleSidebar] == Shortcut("s", [.control, .command]))
        #expect(table[.nextSession]?.modifiers == [.option, .command])
        #expect(table[.nextSession]?.keyEquivalent == String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
        #expect(table[.previousSession]?.keyEquivalent == String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!))
        // Everything not overridden keeps its cmux default.
        #expect(table[.commandPalette] == ShortcutsTable.defaults[.commandPalette])
        #expect(table[.selectSession(3)] == Shortcut("3", .command))
    }

    @Test func parsingHandlesTheConfigSpellingsAndRejectsNonsense() throws {
        #expect(ShortcutsTable.parse("shift+cmd+p") == Shortcut("p", [.shift, .command]))
        #expect(ShortcutsTable.parse("Ctrl+Alt+K") == Shortcut("k", [.control, .option]))
        #expect(ShortcutsTable.parse("cmd+,") == Shortcut(",", .command))
        #expect(ShortcutsTable.parse("cmd+return") == Shortcut("\r", .command))
        #expect(ShortcutsTable.parse("cmd+f5")?.modifiers == [.command])
        #expect(ShortcutsTable.parse("cmd+banana") == nil)
        #expect(ShortcutsTable.parse("") == nil)
        // An unparseable override leaves the default standing.
        #expect(ShortcutsTable.shortcut(for: .newSession, overrides: ["newSession": "cmd+banana"])
            == Shortcut("n", .command))
    }

    @Test func displayStringsMatchTheMenuBar() throws {
        #expect(ShortcutsTable.defaults[.commandPalette]?.displayString == "\u{21E7}\u{2318}P")
        #expect(ShortcutsTable.defaults[.settings]?.displayString == "\u{2318},")
        #expect(ShortcutsTable.parse("alt+cmd+down")?.displayString == "\u{2325}\u{2318}\u{2193}")
    }

    @Test func everyActionHasATitleAndTheVocabularyMatchesAppState() throws {
        for action in ShortcutsTable.allActions {
            #expect(!ShortcutsTable.title(for: action).isEmpty)
        }
        #expect(ShortcutsTable.title(for: .selectSession(4)) == "Select Session 4")
        // AppState.shortcuts keys must all be actions this table knows (M2.4 owns the vocabulary).
        let known = Set(ShortcutsTable.allActions.map(\.rawValue))
        for key in AppState.fixture.shortcuts.keys {
            #expect(known.contains(key), "unknown action id in AppState.shortcuts: \(key)")
        }
    }
}
