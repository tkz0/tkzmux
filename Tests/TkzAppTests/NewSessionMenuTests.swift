import AppKit
import AgentBridge
import Foundation
import Testing
import TkzCore

@testable import TkzApp

/// A minimal `AgentAdapter` for the menu tests — a real adapter needs a shim, an environment, a
/// transcript reader and a hook mapper, none of which the menu ever calls. Only `launchCommand`
/// and `capabilities` matter here; everything else is inert.
fileprivate struct StubAgentAdapter: AgentAdapter {
    let kind: AgentKind
    let displayName: String
    let binaryName: String
    let capabilities: AgentCapabilities
    var newCommand: String?
    var worktreeCommand: String?

    func launchCommand(_ intent: LaunchIntent) -> String? {
        switch intent {
        case .new: newCommand
        case .worktree: worktreeCommand
        case .resume, .prompt: nil
        }
    }
    func environment(configDir: String?) -> [String: String] { [:] }
    func discoverAccounts(home: String, fileManager: FileManager) -> [Account] { [] }
    func accountLabels(home: String, fileManager: FileManager) -> [String: String] { [:] }
    func mapHook(_ payload: HookPayload) -> AgentEvent? { nil }
    func mapTerminalNotification(title: String, body: String) -> AgentEvent? { nil }
    func makeObservationWatcher(
        configDirs: [String], onEvent: @escaping @Sendable (ObservationEvent) -> Void
    ) -> (any AgentObservationWatcher)? { nil }
    var transcript: any TranscriptProvider { StubTranscriptProvider() }
    var hookInstall: HookInstallStrategy { .perInvocation }
    var shimScript: ShimResource { ShimResource(binaryName: binaryName, resourceName: "\(binaryName).sh") }
}

fileprivate struct StubTranscriptProvider: TranscriptProvider {
    func locate(conversationId: String, configDir: String, fileManager: FileManager) -> String? { nil }
    func summary(path: String) throws -> TranscriptSummary { TranscriptSummary() }
    func usage(conversationId: String, path: String, reader: TranscriptUsageReader) async -> SessionUsage? { nil }
    func searchIndex(path: String, existing: TranscriptIndex?) throws -> TranscriptIndex {
        fatalError("not used by NewSessionMenuTests")
    }
}

/// The “＋ New session…” menu and the shortcut table (M2.4).
///
/// The UX rule the ticket exists for is asserted literally: **every entry names its target** — the
/// group in the header, the command in a mono hint, the directory, and the reason a disabled entry
/// is disabled.
@MainActor
struct NewSessionMenuTests {

    static let state = AppState.fixture
    static let northwind = Fixture.groupID(0)   // Northwind Trading, ~/dev/northwind, claude-work
    static let scheduled = Fixture.groupID(2)     // Scheduled — a bucket with no repo, claude
    static let toolbox = Fixture.groupID(3)          // Toolbox, ~/dev/toolbox, claude

    /// An unconfigured menu carrying its default registry (Claude alone), treated as installed.
    ///
    /// Every test builds through this rather than `NewSessionMenu()` directly: the real
    /// `isAdapterInstalled` probes `PATH`, and a suite whose result depends on whether the machine
    /// running it happens to have `claude` installed is a suite that passes here and fails in CI.
    static func unscopedMenu() -> NewSessionMenu {
        let menu = NewSessionMenu()
        menu.isAdapterInstalled = { _ in true }
        return menu
    }

    /// The same menu, scoped to a group — what the app shows when that group is selected.
    static func menu(for groupID: GroupID) -> NewSessionMenu {
        let menu = unscopedMenu()
        menu.configure(state: state, groupID: groupID)
        return menu
    }

    /// The real adapter, so these tests exercise the commands the app will actually run rather
    /// than a stub that agrees with them by construction.
    fileprivate static let claudeStub = ClaudeAdapter()

    /// A comparable snapshot of a menu's visible rows — identifier, rendered text and enabled
    /// state, top level and one level of submenu — for asserting two menus render identically
    /// without pixel-comparing anything.
    static func snapshot(_ menu: NewSessionMenu) -> [String] {
        var lines: [String] = []
        for item in menu.menu.items {
            lines.append("\(item.identifier?.rawValue ?? "-")|\(text(item))|\(item.isEnabled)")
            for sub in item.submenu?.items ?? [] {
                lines.append("  \(sub.identifier?.rawValue ?? "-")|\(text(sub))|\(sub.isEnabled)")
            }
        }
        return lines
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
        let menu = Self.menu(for: Self.northwind)
        #expect(Self.text(menu.item(NewSessionMenu.ItemID.header)!) == "New session in Northwind Trading")

        let worktree = try #require(Self.item(menu, NewSessionMenu.ItemID.worktree))
        #expect(Self.text(worktree).contains("claude -w"), "the command must be visible")
        #expect(Self.text(worktree).contains("~/dev/northwind"), "the target directory must be visible")
        #expect(worktree.isEnabled)

        let root = try #require(Self.item(menu, NewSessionMenu.ItemID.repoRoot))
        #expect(Self.text(root).contains("claude"))
        #expect(Self.text(root).contains("~/dev/northwind"))

        let another = try #require(Self.item(menu, NewSessionMenu.ItemID.anotherRepo))
        #expect(another.isEnabled)
        #expect(Self.text(another).contains("new group"))

        // The command hints are in the mono face (JetBrains Mono for command text).
        let hintFont = worktree.attributedTitle?.attribute(
            .font, at: Self.text(worktree).distance(
                from: Self.text(worktree).startIndex,
                to: Self.text(worktree).range(of: "claude -w")!.lowerBound),
            effectiveRange: nil) as? NSFont
        #expect(hintFont?.fontName == Theme.Fonts.mono(Theme.default.fontMono.detail).fontName)
    }

    @Test func accountSubmenuIsTheGroupsDefault() throws {
        let menu = Self.menu(for: Self.northwind)
        #expect(menu.effectiveAccountKey == "claude-work")
        let account = try #require(Self.item(menu, NewSessionMenu.ItemID.account))
        #expect(account.title == "Default account: Claude (alt)")
        let rows = try #require(account.submenu?.items)
        #expect(rows.compactMap { $0.representedObject as? String } == ["claude", "claude-work"])
        #expect(Self.text(rows[0]).hasPrefix("Claude   "))
        #expect(Self.text(rows[1]).hasPrefix("Claude (alt)   "))
        #expect(rows.first { $0.representedObject as? String == "claude-work" }?.state == .on)
        #expect(rows.first { $0.representedObject as? String == "claude" }?.state == .off)
        // Each row names the config dir it means. It no longer says "group default" in words —
        // the checkmark *is* the group default now.
        #expect(Self.text(rows[1]).contains("~/.claude-work"))
        #expect(!Self.text(rows[1]).contains("group default"))

        // Picking one reports the group it belongs to. The menu does not move its own checkmark:
        // the store is the source of truth, and the assembler re-configures it.
        var picked: [(GroupID, String?)] = []
        menu.onSelectAccount = { picked.append(($0, $1)) }
        #expect(menu.performItem(NewSessionMenu.ItemID.accountRow("claude")))
        #expect(picked.count == 1)
        #expect(picked.first?.0 == Self.northwind)
        #expect(picked.first?.1 == "claude")
        #expect(menu.effectiveAccountKey == "claude-work")
    }

    /// The regression this ticket exists for: the account picked in one group used to be a sticky
    /// per-menu override that then won in *every* other group.
    @Test func theAccountPickedInOneGroupDoesNotFollowTheUserIntoAnother() throws {
        var state = AppState.fixture
        let menu = Self.unscopedMenu()
        // Stand in for `MainWindowController.setGroupDefaultAccount`: write the group, re-scope.
        menu.onSelectAccount = { groupID, key in
            state.setGroupDefaultAccount(groupID, accountKey: key)
            menu.configure(state: state, groupID: groupID)
        }

        menu.configure(state: state, groupID: Self.toolbox)
        #expect(menu.effectiveAccountKey == "claude")
        #expect(menu.performItem(NewSessionMenu.ItemID.accountRow("claude-work")))
        #expect(state.groups[Self.toolbox]?.defaultAccountKey == "claude-work")
        #expect(menu.worktreeLaunch()?.accountKey == "claude-work")

        // Northwind is untouched, and scoping the same menu object to it says so.
        menu.configure(state: state, groupID: Self.northwind)
        #expect(menu.effectiveAccountKey == "claude-work")
        menu.configure(state: state, groupID: Self.scheduled)
        #expect(menu.effectiveAccountKey == "claude")
    }

    @Test func noneClearsTheGroupsDefault() throws {
        let menu = Self.menu(for: Self.northwind)
        var picked: [(GroupID, String?)] = []
        menu.onSelectAccount = { picked.append(($0, $1)) }
        let none = try #require(Self.item(menu, NewSessionMenu.ItemID.accountNone))
        // The row says what clearing it means, rather than leaving the user to guess.
        #expect(Self.text(none).contains("CLAUDE_CONFIG_DIR left unset"))
        #expect(none.state == .off)
        #expect(menu.performItem(NewSessionMenu.ItemID.accountNone))
        #expect(picked.count == 1)
        #expect(picked.first?.0 == Self.northwind)
        #expect(picked.first?.1 == nil)

        // A group with no default checks None and nothing else, and leaves CLAUDE_CONFIG_DIR to
        // the user's shell (`Launch.accountKey == nil`).
        var cleared = AppState.fixture
        cleared.setGroupDefaultAccount(Self.northwind, accountKey: nil)
        menu.configure(state: cleared, groupID: Self.northwind)
        #expect(menu.effectiveAccountKey == nil)
        #expect(menu.worktreeLaunch()?.accountKey == nil)
        let parent = try #require(Self.item(menu, NewSessionMenu.ItemID.account))
        #expect(parent.title == "Default account: none")
        let rows = try #require(parent.submenu?.items)
        #expect(rows.filter { $0.state == .on }.map(\.identifier) == [NewSessionMenu.ItemID.accountNone])
    }

    /// A default pointing at a config dir that has been deleted: the group really is still pointing
    /// at it, so say so rather than showing a list with nothing marked.
    @Test func aDefaultAccountThatNoLongerExistsStaysVisible() throws {
        var state = AppState.fixture
        state.setGroupDefaultAccount(Self.toolbox, accountKey: "claude-gone")
        let menu = Self.unscopedMenu()
        menu.configure(state: state, groupID: Self.toolbox)

        let parent = try #require(Self.item(menu, NewSessionMenu.ItemID.account))
        #expect(parent.title == "Default account: claude-gone")
        let rows = try #require(parent.submenu?.items)
        let missing = try #require(rows.first { $0.identifier == NewSessionMenu.ItemID.accountMissing })
        #expect(missing.state == .on)
        #expect(!missing.isEnabled)
        #expect(Self.text(missing).contains("not found"))
        #expect(rows.filter { $0.state == .on }.count == 1)
        // And the launch still names it — a resume must stay on the account it was started with.
        #expect(menu.worktreeLaunch()?.accountKey == "claude-gone")
    }

    @Test func contentFollowsTheSelectedGroup() throws {
        let menu = Self.unscopedMenu()
        menu.configure(state: Self.state, groupID: Self.northwind)
        #expect(Self.text(menu.item(NewSessionMenu.ItemID.header)!) == "New session in Northwind Trading")
        #expect(menu.worktreeLaunch()?.cwd == "~/dev/northwind")
        #expect(menu.effectiveAccountKey == "claude-work")

        // The sidebar's per-group ＋ scopes the same object to another group.
        menu.configure(state: Self.state, groupID: Self.toolbox)
        #expect(Self.text(menu.item(NewSessionMenu.ItemID.header)!) == "New session in Toolbox")
        #expect(menu.worktreeLaunch()?.cwd == "~/dev/toolbox")
        #expect(menu.effectiveAccountKey == "claude")
        let account = try #require(Self.item(menu, NewSessionMenu.ItemID.account))
        #expect(account.title == "Default account: Claude")

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
        let menu = Self.menu(for: Self.northwind)
        var renamed = Self.state
        renamed.groups[Self.northwind]!.name = "Renamed"
        menu.group = renamed.groups[Self.northwind]
        menu.menuNeedsUpdate(menu.menu)
        #expect(Self.text(menu.item(NewSessionMenu.ItemID.header)!) == "New session in Renamed")
    }

    // MARK: The launcher stub

    @Test func launcherStubReportsTheExactCommandAndCwd() throws {
        let menu = Self.menu(for: Self.northwind)
        var launches: [NewSessionMenu.Launch] = []
        menu.onLaunch = { launches.append($0) }

        // Driven through the menu item, i.e. what a click does.
        #expect(menu.performItem(NewSessionMenu.ItemID.worktree))
        #expect(menu.performItem(NewSessionMenu.ItemID.repoRoot))

        #expect(launches.count == 2)
        #expect(launches.first?.kind == .worktree)
        #expect(launches.first?.command == "claude -w")
        #expect(launches.first?.cwd == "~/dev/northwind", "the path is passed through verbatim")
        #expect(launches.first?.accountKey == "claude-work")
        #expect(launches.first?.groupID == Self.northwind)
        #expect(launches.first?.logLine == "cd ~/dev/northwind && CLAUDE_CONFIG_DIR=claude-work claude -w")

        #expect(launches.last?.kind == .repoRoot)
        #expect(launches.last?.command == "claude")
        #expect(launches.last?.logLine == "cd ~/dev/northwind && CLAUDE_CONFIG_DIR=claude-work claude")

        // The menu also records the last resolved launch, which is what the no-closure stub logs.
        #expect(menu.lastLaunch == launches.last)
    }

    @Test func anotherRepoIsHandedToTheAssembler() throws {
        let menu = Self.menu(for: Self.northwind)
        var asked = 0
        menu.onChooseAnotherRepo = { asked += 1 }
        #expect(menu.performItem(NewSessionMenu.ItemID.anotherRepo))
        #expect(asked == 1)
    }

    // MARK: - The shell launch (M2.5)

    @Test("A shell launch carries no command and works for a bucket group too")
    func shellLaunchNeedsNoRepo() throws {
        // A repo group starts in its root.
        let repo = try #require(Self.menu(for: Self.northwind).shellLaunch())
        #expect(repo.kind == .shell)
        #expect(repo.command.isEmpty)
        #expect(repo.cwd == "~/dev/northwind")
        // ...and the log line says so without a dangling `&&`.
        #expect(repo.logLine == "cd ~/dev/northwind")

        // A bucket has no repo root, so the two `claude` rows are dead — but a shell is not.
        let bucketMenu = Self.menu(for: Self.scheduled)
        #expect(bucketMenu.repoRootLaunch() == nil)
        let bucket = try #require(bucketMenu.shellLaunch(fallbackDirectory: "/tmp"))
        #expect(bucket.cwd == "/tmp")

        #expect(NewSessionMenu().shellLaunch() == nil, "no group selected, no launch")
    }

    // MARK: - Built from adapters (TKZ-82)

    /// The acceptance criterion this ticket exists for: with one agent installed the menu must be
    /// what tkzmux has always drawn.
    ///
    /// The expectation is spelled out here rather than compared against a second run of the same
    /// code. An earlier draft of this test built the menu twice and asserted the two matched, which
    /// passes no matter what the rows say — the only thing it can catch is nondeterminism. Pinning
    /// the literal rows means a hint, a title, an identifier or the order changing has to be
    /// changed here too, deliberately.
    @Test("With only Claude installed, the menu is the one it has always been")
    func singleAdapterMenuIsTheMenuItHasAlwaysBeen() throws {
        let menu = Self.menu(for: Self.northwind)

        let s = "   "  // the three spaces `attributed(title:hint:detail:)` puts before each part
        #expect(
            Self.snapshot(menu) == [
                "tkzmux.newSession.header|New session in Northwind Trading|false",
                "tkzmux.newSession.worktree|New worktree\(s)claude -w\(s)~/dev/northwind|true",
                "tkzmux.newSession.repoRoot|In repo root\(s)claude\(s)~/dev/northwind|true",
                "tkzmux.newSession.anotherRepo|In another repo\u{2026}\(s)choose a folder \u{2014} it becomes a new group|true",
                "-||false",
                "tkzmux.newSession.agent|Agent: Claude|true",
                "  tkzmux.newSession.agentRow.claude|Claude\(s)claude|true",
                "tkzmux.newSession.account|Default account: Claude (alt)|true",
                "  tkzmux.newSession.accountRow.claude|Claude\(s)~/.claude|true",
                "  tkzmux.newSession.accountRow.claude-work|Claude (alt)\(s)~/.claude-work|true",
                "  -||false",
                "  tkzmux.newSession.accountNone|None\(s)inherit \u{2014} CLAUDE_CONFIG_DIR left unset|true",
            ])

        // No agent section header and no "Other agent" submenu with one installed adapter: both
        // are what a *second* adapter earns.
        #expect(menu.item(NewSessionMenu.ItemID.agentHeader(.claude)) == nil)
        #expect(menu.item(NewSessionMenu.ItemID.otherAgent) == nil)
        // Nothing was substituted, so nothing says it was.
        #expect(menu.item(NewSessionMenu.ItemID.agentMissing) == nil)
        #expect(menu.item(NewSessionMenu.ItemID.noAgent) == nil)

        // Launching resolves through the adapter rather than a re-typed literal.
        #expect(menu.worktreeLaunch()?.command == "claude -w")
        #expect(menu.worktreeLaunch(name: "review")?.command == "claude -w review")
        #expect(menu.repoRootLaunch()?.command == "claude")
        #expect(menu.worktreeLaunch()?.agent == .claude)
    }

    /// An agent with no adapter registered gets no command invented for it. Guessing a command
    /// line for an unknown agent is how you run the wrong binary with the wrong flags, so both
    /// builders return `nil` instead.
    @Test("An unregistered agent yields no launch rather than a guessed command")
    func anUnregisteredAgentYieldsNoLaunch() {
        let menu = Self.menu(for: Self.northwind)
        let stranger = AgentKind(rawValue: "aider")
        #expect(menu.worktreeLaunch(agent: stranger) == nil)
        #expect(menu.repoRootLaunch(agent: stranger) == nil)
    }

    /// The group decides what the top-level rows run. This is the whole point of the change: the
    /// menu used to emit a block of rows per installed adapter, so it grew with the agent count.
    @Test("The group's own agent leads the menu, whatever else is installed")
    func theGroupsAgentLeadsTheMenu() throws {
        let stubKind = AgentKind(rawValue: "stub")
        let stub = StubAgentAdapter(
            kind: stubKind, displayName: "Stub Agent", binaryName: "stub",
            capabilities: [], newCommand: "stub", worktreeCommand: nil)

        var state = Self.state
        state.setGroupAgent(Self.northwind, agent: stubKind)

        let menu = Self.unscopedMenu()
        menu.adapters = [Self.claudeStub, stub]
        menu.isAdapterInstalled = { _ in true }
        menu.configure(state: state, groupID: Self.northwind)

        #expect(menu.effectiveAgent == stubKind)
        // The plain identifiers are the top-level rows, and they are the group's agent's — not
        // Claude's, which is what they used to mean.
        let root = try #require(menu.item(NewSessionMenu.ItemID.repoRoot))
        #expect(Self.text(root).contains("stub"))
        #expect(root.representedObject as? AgentKind == stubKind)
        // The stub has no worktree capability, so there is no worktree row at all — not a disabled
        // one. tkzmux does not create worktrees itself, so the entry could never do anything.
        #expect(menu.item(NewSessionMenu.ItemID.worktree) == nil)

        // Clicking the row launches the group's agent, without the row having to say so.
        #expect(menu.repoRootLaunch()?.agent == stubKind)
        #expect(menu.repoRootLaunch()?.command == "stub")
        // And an agent with no worktree flag yields no worktree launch, rather than a guessed one.
        #expect(menu.worktreeLaunch() == nil)

        // The picker names the group's agent and checks it.
        let picker = try #require(menu.item(NewSessionMenu.ItemID.agent))
        #expect(picker.title == "Agent: Stub Agent")
        #expect(menu.item(NewSessionMenu.ItemID.agentRow(stubKind))?.state == .on)
        #expect(menu.item(NewSessionMenu.ItemID.agentRow(.claude))?.state == .off)
    }

    /// Every other installed agent keeps its rows, one level down, under its own header — the
    /// one-off escape hatch. The headers are unconditional there, unlike the old top-level rule:
    /// two rows reading "New worktree" and "In repo root" are otherwise indistinguishable from the
    /// ones above them.
    @Test("Other installed agents live under Other agent, with their own headers and namespaced ids")
    func otherInstalledAgentsLiveUnderOtherAgent() throws {
        let stubKind = AgentKind(rawValue: "stub")
        let stub = StubAgentAdapter(
            kind: stubKind, displayName: "Stub Agent", binaryName: "stub",
            capabilities: [], newCommand: "stub", worktreeCommand: nil)

        let menu = Self.unscopedMenu()
        menu.adapters = [Self.claudeStub, stub]
        menu.isAdapterInstalled = { _ in true }
        menu.configure(state: Self.state, groupID: Self.northwind)

        // The group has chosen nothing, so Claude leads and the stub is the "other".
        #expect(menu.effectiveAgent == .claude)
        #expect(Self.text(try #require(menu.item(NewSessionMenu.ItemID.repoRoot))).contains("claude"))

        #expect(menu.item(NewSessionMenu.ItemID.otherAgent) != nil)
        // The header names the agent whose rows follow; the top-level agent gets none.
        #expect(menu.item(NewSessionMenu.ItemID.agentHeader(stubKind)) != nil)
        #expect(menu.item(NewSessionMenu.ItemID.agentHeader(.claude)) == nil)

        // The stub's own row is namespaced and carries its kind, so clicking it launches the stub
        // even though the group runs Claude.
        let stubRoot = try #require(menu.item(NewSessionMenu.ItemID.repoRoot(for: stubKind)))
        #expect(Self.text(stubRoot).contains("stub"))
        #expect(stubRoot.representedObject as? AgentKind == stubKind)
        #expect(menu.repoRootLaunch(agent: stubKind)?.agent == stubKind)
        // Still no worktree row for a capability it does not have, submenu or not.
        #expect(menu.item(NewSessionMenu.ItemID.worktree(for: stubKind)) == nil)
    }

    /// A group can name an agent nobody has installed — a state file from another machine, or an
    /// uninstalled CLI. The rows must run something that exists, and must not pretend that is what
    /// was asked for.
    @Test("A configured agent that is not installed falls back, and says so")
    func aConfiguredAgentThatIsNotInstalledSaysSo() throws {
        let stubKind = AgentKind(rawValue: "stub")
        let stub = StubAgentAdapter(
            kind: stubKind, displayName: "Stub Agent", binaryName: "stub",
            capabilities: [], newCommand: "stub", worktreeCommand: nil)

        var state = Self.state
        state.setGroupAgent(Self.northwind, agent: stubKind)

        let menu = Self.unscopedMenu()
        menu.adapters = [Self.claudeStub, stub]
        // The stub is configured but *not* installed.
        menu.isAdapterInstalled = { $0.kind == .claude }
        menu.configure(state: state, groupID: Self.northwind)

        #expect(menu.effectiveAgent == .claude)
        #expect(menu.configuredAgentMissing == stubKind)
        let notice = try #require(menu.item(NewSessionMenu.ItemID.agentMissing))
        #expect(notice.isEnabled == false)
        #expect(Self.text(notice).contains("Stub Agent"))
        #expect(Self.text(notice).contains("not installed"))
        // The hint shows what will really run, so the row and the notice cannot disagree.
        #expect(Self.text(try #require(menu.item(NewSessionMenu.ItemID.repoRoot))).contains("claude"))
        // The picker keeps the group's real choice visible and checked, like `accountMissing` does.
        #expect(menu.item(NewSessionMenu.ItemID.agentRow(stubKind))?.state == .on)
    }

    /// Nothing installed at all must not leave a menu that is silently two rows long.
    @Test("With no installed adapter the menu says there is nothing to run")
    func noInstalledAdapterSaysSo() throws {
        let menu = Self.unscopedMenu()
        menu.adapters = [Self.claudeStub]
        menu.isAdapterInstalled = { _ in false }
        menu.configure(state: Self.state, groupID: Self.northwind)

        let none = try #require(menu.item(NewSessionMenu.ItemID.noAgent))
        #expect(none.isEnabled == false)
        #expect(menu.item(NewSessionMenu.ItemID.repoRoot) == nil)
        #expect(menu.item(NewSessionMenu.ItemID.worktree) == nil)
        #expect(menu.item(NewSessionMenu.ItemID.otherAgent) == nil)
    }

    /// Picking an agent reports the group and the kind; the store update is the assembler's job,
    /// exactly like the account picker's.
    @Test("The agent picker writes the group's agent")
    func theAgentPickerWritesTheGroupsAgent() throws {
        let stubKind = AgentKind(rawValue: "stub")
        let stub = StubAgentAdapter(
            kind: stubKind, displayName: "Stub Agent", binaryName: "stub",
            capabilities: [], newCommand: "stub", worktreeCommand: nil)

        let menu = Self.unscopedMenu()
        menu.adapters = [Self.claudeStub, stub]
        menu.isAdapterInstalled = { _ in true }
        menu.configure(state: Self.state, groupID: Self.northwind)

        var chosen: [(GroupID, AgentKind?)] = []
        menu.onSelectAgent = { chosen.append(($0, $1)) }
        #expect(menu.performItem(NewSessionMenu.ItemID.agentRow(stubKind)))
        #expect(chosen.count == 1)
        #expect(chosen.first?.0 == Self.northwind)
        #expect(chosen.first?.1 == stubKind)
    }

    /// A group default naming another agent's account is not handed to this agent's launch. The
    /// rule lives in `AppState.createSession`, but `SessionLauncher.start` passes the menu's key
    /// explicitly and so bypasses it — which makes this the load-bearing copy.
    @Test("A default account belonging to another agent is not carried into the launch")
    func anotherAgentsDefaultAccountIsNotCarried() throws {
        let stubKind = AgentKind(rawValue: "stub")
        let stub = StubAgentAdapter(
            kind: stubKind, displayName: "Stub Agent", binaryName: "stub",
            capabilities: [], newCommand: "stub", worktreeCommand: nil)

        var state = Self.state
        state.setGroupAgent(Self.northwind, agent: stubKind)

        let menu = Self.unscopedMenu()
        menu.adapters = [Self.claudeStub, stub]
        menu.isAdapterInstalled = { _ in true }
        menu.configure(state: state, groupID: Self.northwind)

        // The group's default is `claude-work`, a Claude account (see `Self.state`).
        #expect(menu.accountKey(for: .claude) == "claude-work")
        #expect(menu.accountKey(for: stubKind) == nil)
        #expect(menu.effectiveAccountKey == nil)
        #expect(menu.repoRootLaunch()?.accountKey == nil)
        // The escape hatch still gets it, because that row really is a Claude launch.
        #expect(menu.repoRootLaunch(agent: .claude)?.accountKey == "claude-work")
    }

    @Test("The account submenu groups by agent once there is more than one installed adapter")
    func accountSubmenuGroupsByAgentWithTwoAdapters() throws {
        let stubKind = AgentKind(rawValue: "stub")
        var state = AppState.fixture
        state.setAccount(Account(key: "stub-default", configDir: "/h/.stub", label: "Stub", agent: stubKind))
        let stub = StubAgentAdapter(
            kind: stubKind, displayName: "Stub Agent", binaryName: "stub",
            capabilities: [], newCommand: "stub")

        let menu = Self.unscopedMenu()
        menu.adapters = [Self.claudeStub, stub]
        menu.isAdapterInstalled = { _ in true }
        menu.configure(state: state, groupID: Self.northwind)

        let account = try #require(menu.item(NewSessionMenu.ItemID.account))
        let rows = try #require(account.submenu?.items)
        #expect(rows.contains { $0.identifier == NewSessionMenu.ItemID.accountSectionHeader(.claude) })
        #expect(rows.contains { $0.identifier == NewSessionMenu.ItemID.accountSectionHeader(stubKind) })
        #expect(rows.contains { $0.representedObject as? String == "stub-default" })

        // One adapter, and the submenu is exactly the flat list it always was — no headers.
        let single = Self.unscopedMenu()
        single.adapters = [Self.claudeStub]
        single.isAdapterInstalled = { _ in true }
        single.configure(state: Self.state, groupID: Self.northwind)
        let singleRows = try #require(single.item(NewSessionMenu.ItemID.account)?.submenu?.items)
        #expect(!singleRows.contains { $0.identifier?.rawValue.contains("accountSectionHeader") == true })
    }
}

/// The table is data; wave 3 builds the menu from it.
@MainActor
struct ShortcutsTableTests {

    @Test func cmuxDefaults() throws {
        let expected: [(ShortcutAction, String, ShortcutModifiers)] = [
            (.newSession, "n", .command),
            (.searchSessions, "f", .command),
            (.commandPalette, "p", [.shift, .command]),
            (.toggleSidebar, "b", .command),
            (.renameSession, "r", [.shift, .command]),
            (.closeTerminal, "w", .command),
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
        // next/previous still have no cmux default — override-only.
        #expect(ShortcutsTable.defaults[.nextSession] == nil)
        #expect(ShortcutsTable.defaults[.previousSession] == nil)
        // ⌘T and ⌘D were held for the terminal from M2.4; the pane split is where they were spent.
        #expect(ShortcutsTable.defaults[.newTerminal] == Shortcut("t", .command))
        #expect(ShortcutsTable.defaults[.splitVertically] == Shortcut("d", .command))
        #expect(ShortcutsTable.defaults[.splitHorizontally] == Shortcut("d", [.shift, .command]))
        #expect(ShortcutsTable.defaults[.closeSession] == Shortcut("w", [.shift, .command]))
        #expect(ShortcutsTable.defaults[.zoomPane] == Shortcut("\r", [.shift, .command]))
        #expect(ShortcutsTable.defaults[.equalizeSplits] == Shortcut("=", [.control, .command]))
        #expect(ShortcutsTable.defaults[.focusPaneLeft]?.modifiers == [.option, .command])
        #expect(ShortcutsTable.defaults[.nextTab] == Shortcut("]", [.shift, .command]))
        #expect(ShortcutsTable.defaults[.previousTab] == Shortcut("[", [.shift, .command]))
    }

    /// No two actions may share a chord, in the defaults *or* under the fixture's overrides.
    ///
    /// `MainMenuTests` guards the defaults through the menu, but the fixture is the one place a
    /// collision can be introduced without any menu being built — and a shadowed binding under
    /// `TKZMUX_FIXTURE` is exactly the kind of thing nobody notices. ⌥⌘↓ used to be the fixture's
    /// example override for `nextSession`; it is `focusPaneDown` now.
    @Test func noTwoActionsShareAChord() throws {
        for (label, table) in [
            ("defaults", ShortcutsTable.defaults),
            ("fixture", ShortcutsTable.resolved(state: AppState.fixture)),
        ] {
            var seen: [Shortcut: ShortcutAction] = [:]
            for (action, shortcut) in table.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                if let other = seen[shortcut] {
                    Issue.record("\(label): \(action) and \(other) both use \(shortcut.displayString)")
                }
                seen[shortcut] = action
            }
        }
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
        // The fixture rebinds ⌘N → ⌃⌘N and ⌘B → ⌃⌘S, and adds next/previous. (It used ⌘T and
        // ⌥⌘↓ until the pane split spent both on the terminal.)
        let table = ShortcutsTable.resolved(state: AppState.fixture)
        #expect(table[.newSession] == Shortcut("n", [.control, .command]))
        #expect(table[.toggleSidebar] == Shortcut("s", [.control, .command]))
        #expect(table[.nextSession]?.modifiers == [.control, .command])
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
