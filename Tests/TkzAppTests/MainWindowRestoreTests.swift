// MainWindowRestoreTests — M5.2 (TKZ-30): the window half of launch/restore. Lazy reopen on
// first show, ⌘W confirmation, ⇧⌘W removal, the context menus, "In another repo…", auto-resume.
//
// Same doubles as `MainWindowLaunchTests`: a spy host, a plain focusable view, real directories.

import AppKit
import Foundation
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct MainWindowRestoreTests {

    typealias Harness = MainWindowControllerTests.Harness

    /// A window over `state.json`-shaped rows: in the store, no live state, no host session.
    static func makeRestoredHarness(rows: Int = 2, cwd: String = NSTemporaryDirectory())
        -> (harness: Harness, ids: [SessionID], group: GroupID)
    {
        var state = AppState()
        let group = state.addGroup(name: "Scratch", repoRoot: cwd)
        var ids: [SessionID] = []
        for n in 0..<rows {
            let session = state.createSession(groupID: group.id, cwd: cwd, accountKey: "claude")
            state.sessions[session.id]?.claudeSessionId = "conv-\(n)"
            ids.append(session.id)
        }
        state.select(ids.first)
        let harness = MainWindowControllerTests.makeHarness(state)
        return (harness, ids, group.id)
    }

    // MARK: - Lazy reopen

    @Test("The selected restored row is reopened from its snapshot the moment the window comes up")
    func selectedRowReopensAtLaunch() throws {
        var state = AppState()
        let group = state.addGroup(name: "Scratch", repoRoot: NSTemporaryDirectory())
        let session = state.createSession(groupID: group.id, cwd: NSTemporaryDirectory(), accountKey: "claude")
        state.select(session.id)
        let store = AppStore(state: state)
        let host = MainWindowControllerTests.SpyTerminalHost()
        host.savedSnapshots[session.id] = Data("screen".utf8)
        let view = MainWindowControllerTests.FakeTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        _ = NSApplication.shared
        let controller = MainWindowController(store: store, host: host, terminalView: view, theme: .default)
        defer { controller.shutdown() }
        store.flush()

        #expect(host.restored.map(\.id) == [session.id])
        #expect(host.restored.first?.snapshot == Data("screen".utf8))
        #expect(host.visibleSessionID == session.id)
        #expect(store.state.sessions[session.id]?.live?.shellPid == 4343)
        #expect(controller.detail.emptyState.isHidden)
        #expect(host.ran.isEmpty, "reopen types nothing; resume is a separate verb")
    }

    @Test("Selecting another restored row reopens it once; re-selecting does not respawn")
    func selectionReopensLazily() throws {
        let (harness, ids, _) = Self.makeRestoredHarness()
        defer { harness.tearDown() }
        #expect(harness.host.opened.map(\.id) == [ids[0]], "only the selected row was reopened")

        harness.mutate { $0.select(ids[1]) }
        #expect(harness.host.opened.map(\.id) == ids)
        #expect(harness.host.visibleSessionID == ids[1])

        harness.mutate { $0.select(ids[0]) }
        #expect(harness.host.opened.count == 2, "a row with a shell is shown, not respawned")
        #expect(harness.host.visibleSessionID == ids[0])
    }

    @Test("A restored row whose directory is gone shows the empty state with the path, non-modally")
    func missingDirectoryIsANotice() throws {
        let missing = NSTemporaryDirectory() + "tkzmux-gone-\(UUID().uuidString)"
        let (harness, ids, _) = Self.makeRestoredHarness(rows: 1, cwd: missing)
        defer { harness.tearDown() }
        #expect(harness.host.opened.isEmpty)
        #expect(harness.store.state.sessions[ids[0]]?.live == nil)
        #expect(harness.controller.detail.emptyState.isHidden == false)
        #expect(harness.controller.detail.emptyStateMessage == EmptyStateView.missingDirectoryMessage(missing))
        #expect(harness.controller.statusBar.model.notice?.contains("missing") == true)
    }

    // MARK: - Close and remove

    @Test("⌘W removes an idle row at once and asks first for a working or waiting one")
    func closeConfirmsOnlyWhenBusy() throws {
        let (harness, ids, _) = Self.makeRestoredHarness()
        defer { harness.tearDown() }
        var asked: [String] = []
        harness.controller.confirmRemove = { session in asked.append(session.status.name); return false }
        harness.host.savedSnapshots[ids[0]] = Data("x".utf8)

        // Idle: gone at once — row, shell, snapshot — and the selection moves on.
        harness.controller.dispatcher.perform(.closeTerminal)
        harness.store.flush()
        #expect(asked.isEmpty)
        #expect(harness.host.discarded == [ids[0]])
        #expect(harness.host.savedSnapshots[ids[0]] == nil)
        #expect(harness.store.state.sessions[ids[0]] == nil)
        #expect(harness.store.state.selection == ids[1])
        // The successor was reopened by the selection change, as any first show is.
        #expect(harness.host.visibleSessionID == ids[1])

        // Working: asked, and "no" leaves it alone.
        harness.mutate { $0.setStatus(.working, for: ids[1]) }
        harness.controller.dispatcher.perform(.closeTerminal)
        harness.store.flush()
        #expect(asked == ["working"])
        #expect(harness.store.state.sessions[ids[1]] != nil)

        // Waiting: asked, and "yes" removes.
        harness.controller.confirmRemove = { session in asked.append(session.status.name); return true }
        harness.mutate { $0.setStatus(.waiting(.permission), for: ids[1]) }
        harness.controller.dispatcher.perform(.closeTerminal)
        harness.store.flush()
        #expect(asked.last == "waiting(permission)")
        #expect(harness.store.state.sessions[ids[1]] == nil)
        #expect(harness.host.discarded == [ids[0], ids[1]])
    }

    @Test("The × on a hovered row removes that row, through the sidebar's callback")
    func closeButtonRemovesTheRow() throws {
        let (harness, ids, _) = Self.makeRestoredHarness()
        defer { harness.tearDown() }
        let sidebar = harness.controller.sidebar
        let row = sidebar.row(forSession: ids[1])
        let view = try #require(sidebar.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionRowView)
        view.setHovered(true)
        #expect(view.closeButtonFrame != nil)
        let onClose = try #require(view.onClose)
        onClose()
        harness.store.flush()
        #expect(harness.store.state.sessions[ids[1]] == nil)
        #expect(harness.host.discarded == [ids[1]])
        #expect(harness.store.state.selection == ids[0], "removing another row leaves the selection alone")
    }

    // MARK: - Context menus

    @Test("A session row's context menu offers Resume / Rename / Remove, enabled honestly")
    func sessionContextMenu() throws {
        let (harness, ids, _) = Self.makeRestoredHarness()
        defer { harness.tearDown() }
        func item(_ menu: NSMenu, _ id: NSUserInterfaceItemIdentifier) -> NSMenuItem? {
            menu.items.first { $0.identifier == id }
        }

        // ids[1]: restored, never shown → resumable.
        let restored = try #require(harness.controller.sidebar.contextMenu(forSession: ids[1]))
        #expect(item(restored, MainWindowController.ContextItemID.resume)?.isEnabled == true)
        #expect(item(restored, MainWindowController.ContextItemID.remove)?.isEnabled == true)
        #expect(item(restored, MainWindowController.ContextItemID.rename) != nil)
        #expect(
            restored.items.count == 7,
            "Resume, Rename, separator, Remove, separator, Group color, Default account")

        // ids[0]: a live shell, still resumable (no Claude bound).
        let live = try #require(harness.controller.sidebar.contextMenu(forSession: ids[0]))
        #expect(item(live, MainWindowController.ContextItemID.resume)?.isEnabled == true)

        // Claude running in ids[0] → Resume is off.
        harness.mutate { state in
            state.applyDescriptor(
                ClaudeSessionInfo(configDir: "/x/.claude", pid: 5, sessionId: "conv-0", status: .busy),
                alive: true, to: ids[0])
        }
        let busy = try #require(harness.controller.sidebar.contextMenu(forSession: ids[0]))
        #expect(item(busy, MainWindowController.ContextItemID.resume)?.isEnabled == false)

        // Acting on the *other* row through its menu, without selecting it.
        #expect(harness.store.state.selection == ids[0])
        let resume = try #require(item(restored, MainWindowController.ContextItemID.resume))
        _ = resume.target?.perform(resume.action, with: resume)
        harness.store.flush()
        #expect(harness.host.ran.last?.command == "claude --resume conv-1")
        #expect(harness.store.state.selection == ids[1], "Resume from the menu does select the row")

        harness.controller.confirmRemove = { _ in true }
        let remove = try #require(item(restored, MainWindowController.ContextItemID.remove))
        _ = remove.target?.perform(remove.action, with: remove)
        harness.store.flush()
        #expect(harness.store.state.sessions[ids[1]] == nil)

        #expect(harness.controller.sidebar.contextMenu(forSession: SessionID.generate()) == nil)
    }

    @Test("A group header's context menu offers New session and Resume all")
    func groupContextMenu() throws {
        let (harness, ids, group) = Self.makeRestoredHarness()
        defer { harness.tearDown() }
        let menu = try #require(harness.controller.sidebar.contextMenu(forGroup: group))
        let resumeAll = try #require(menu.items.first { $0.identifier == MainWindowController.ContextItemID.resumeAll })
        #expect(resumeAll.isEnabled)
        #expect(menu.items.contains { $0.identifier == MainWindowController.ContextItemID.newSession })

        _ = resumeAll.target?.perform(resumeAll.action, with: resumeAll)
        harness.store.flush()
        #expect(Set(harness.host.ran.map(\.command)) == ["claude --resume conv-0", "claude --resume conv-1"])
        #expect(harness.store.state.selection == ids[0], "resume-all leaves the selection alone")
        #expect(harness.controller.statusBar.model.notice?.hasPrefix("Resumed 2") == true)
    }

    @Test("Remove group takes the group and every session in it, once the user has confirmed")
    func removeGroupFromContextMenu() throws {
        let cwd = NSTemporaryDirectory()
        var state = AppState()
        let doomed = state.addGroup(name: "Scratch", repoRoot: cwd)
        let keeper = state.addGroup(name: "Keep", repoRoot: cwd)
        let members = (0..<2).map { _ in state.createSession(groupID: doomed.id, cwd: cwd, accountKey: "claude").id }
        let survivor = state.createSession(groupID: keeper.id, cwd: cwd, accountKey: "claude").id
        state.select(members[0])
        let harness = MainWindowControllerTests.makeHarness(state)
        defer { harness.tearDown() }
        #expect(harness.controller.sidebar.outlineView.numberOfRows == 2 + 3)

        let menu = try #require(harness.controller.sidebar.contextMenu(forGroup: doomed.id))
        let item = try #require(menu.items.first { $0.identifier == MainWindowController.ContextItemID.removeGroup })
        #expect(item.title == "Remove group")

        // Cancelled: nothing moves.
        harness.controller.confirmRemoveGroup = { _, _ in false }
        _ = item.target?.perform(item.action, with: item)
        harness.store.flush()
        #expect(harness.store.state.groups[doomed.id] != nil)
        #expect(harness.store.state.sessions.count == 3)

        // Confirmed: the group, its rows and their shells all go; the other group is untouched.
        var asked: (group: Group, members: [Session])?
        harness.controller.confirmRemoveGroup = { group, members in
            asked = (group, members)
            return true
        }
        _ = item.target?.perform(item.action, with: item)
        harness.store.flush()
        harness.layout()

        #expect(asked?.group.id == doomed.id)
        #expect(Set(asked?.members.map(\.id) ?? []) == Set(members))
        #expect(harness.store.state.groups[doomed.id] == nil)
        #expect(harness.store.state.groups[keeper.id] != nil)
        #expect(Array(harness.store.state.sessions.keys) == [survivor])
        #expect(Set(harness.host.discarded) == Set(members), "every member's shell and snapshot go")
        #expect(harness.store.state.selection == survivor, "selection lands on a surviving row")
        #expect(harness.controller.sidebar.outlineView.numberOfRows == 2, "the header and its rows leave together")
    }

    @Test("An empty group is removed without asking")
    func removeEmptyGroupAsksNothing() throws {
        var state = AppState()
        let empty = state.addGroup(name: "Bucket")
        let harness = MainWindowControllerTests.makeHarness(state)
        defer { harness.tearDown() }
        var asked = false
        harness.controller.confirmRemoveGroup = { _, _ in
            asked = true
            return true
        }
        let menu = try #require(harness.controller.sidebar.contextMenu(forGroup: empty.id))
        let item = try #require(menu.items.first { $0.identifier == MainWindowController.ContextItemID.removeGroup })
        _ = item.target?.perform(item.action, with: item)
        harness.store.flush()

        #expect(asked == false, "nothing was going to be closed, so nothing was asked")
        #expect(harness.store.state.groups.isEmpty, "the last group is removable; the footer is the way back")
        #expect(harness.host.discarded.isEmpty)
    }

    @Test("Set Repo… attaches a folder to a bucket group, and one folder roots one group")
    func setGroupRepo() throws {
        var state = AppState()
        let bucket = state.addGroup(name: "Work")
        let other = state.addGroup(name: "Taken", repoRoot: "/tmp/tkzmux-tests/taken")
        let harness = MainWindowControllerTests.makeHarness(state)
        defer { harness.tearDown() }
        let controller = harness.controller

        func repoItem(_ id: GroupID) throws -> NSMenuItem {
            let menu = try #require(controller.sidebar.contextMenu(forGroup: id))
            return try #require(menu.items.first { $0.identifier == MainWindowController.ContextItemID.groupRepo })
        }

        let item = try repoItem(bucket.id)
        #expect(item.title == "Set Repo\u{2026}", "a bucket has no repo yet")
        #expect(try repoItem(other.id).title == "Change Repo\u{2026}")

        controller.folderPrompt = { _ in URL(fileURLWithPath: "/tmp/tkzmux-tests/work", isDirectory: true) }
        _ = item.target?.perform(item.action, with: item)
        harness.store.flush()
        #expect(harness.store.state.groups[bucket.id]?.repoRoot == "/tmp/tkzmux-tests/work")
        #expect(try repoItem(bucket.id).title == "Change Repo\u{2026}")

        // The folder that already roots "Taken" is refused, with a notice.
        controller.folderPrompt = { _ in URL(fileURLWithPath: "/tmp/tkzmux-tests/taken", isDirectory: true) }
        let again = try repoItem(bucket.id)
        _ = again.target?.perform(again.action, with: again)
        harness.store.flush()
        #expect(harness.store.state.groups[bucket.id]?.repoRoot == "/tmp/tkzmux-tests/work")
        #expect(controller.statusBar.model.notice?.contains("Taken") == true)
    }

    // MARK: Group colour (TKZ-48)

    /// The submenu on a group header row.
    @Test("Group color offers the palette plus None, and writes the colour into the store")
    func groupColorMenu() throws {
        let (harness, _, group) = Self.makeRestoredHarness()
        defer { harness.tearDown() }

        let menu = try #require(harness.controller.sidebar.contextMenu(forGroup: group))
        let parent = try #require(menu.items.first { $0.identifier == MainWindowController.ContextItemID.groupColor })
        let submenu = try #require(parent.submenu)
        #expect(submenu.items.count == GroupPalette.swatches.count + 2, "swatches, a separator, None")

        // Every swatch is there, in palette order, with a visible (non-template) colour chip.
        for (index, swatch) in GroupPalette.swatches.enumerated() {
            let item = submenu.items[index]
            #expect(item.identifier == MainWindowController.ContextItemID.groupColorSwatch(swatch.slug))
            #expect(item.title == swatch.name)
            #expect(item.image != nil)
            #expect(item.image?.isTemplate == false)
        }

        // Nothing is set yet, so None carries the mark and no swatch does.
        let none = try #require(submenu.items.first { $0.identifier == MainWindowController.ContextItemID.groupColorNone })
        #expect(harness.store.state.groups[group]?.color == nil)
        #expect(none.state == .on)
        #expect(submenu.items.allSatisfy { $0.identifier == MainWindowController.ContextItemID.groupColorNone || $0.state == .off })

        // Pick one.
        let violet = try #require(GroupPalette.swatches.first { $0.slug == "violet" })
        let pick = try #require(submenu.items.first {
            $0.identifier == MainWindowController.ContextItemID.groupColorSwatch(violet.slug)
        })
        _ = pick.target?.perform(pick.action, with: pick)
        harness.store.flush()
        #expect(harness.store.state.groups[group]?.color == violet.rgb)

        // Re-opening the menu marks it, and only it.
        let reopened = try #require(harness.controller.sidebar.contextMenu(forGroup: group))
        let reopenedSub = try #require(
            reopened.items.first { $0.identifier == MainWindowController.ContextItemID.groupColor }?.submenu)
        let marked = reopenedSub.items.filter { $0.state == .on }
        #expect(marked.count == 1)
        #expect(marked.first?.identifier == MainWindowController.ContextItemID.groupColorSwatch(violet.slug))

        // None clears it.
        let clear = try #require(reopenedSub.items.first { $0.identifier == MainWindowController.ContextItemID.groupColorNone })
        _ = clear.target?.perform(clear.action, with: clear)
        harness.store.flush()
        #expect(harness.store.state.groups[group]?.color == nil)
    }

    // MARK: Group default account

    /// The submenu that makes the account a property of the group. Its whole point is that it
    /// **persists** and does not leak into another group, so this drives it through the store.
    @Test("Default account lists the accounts, writes the group, and survives a reopen")
    func groupDefaultAccountMenu() throws {
        let (harness, ids, group) = Self.makeRestoredHarness()
        defer { harness.tearDown() }
        harness.mutate {
            $0.setAccount(Account(key: "claude", configDir: "~/.claude", label: "Claude"))
            $0.setAccount(Account(key: "claude-alt", configDir: "~/.claude-alt", label: "claude-alt"))
        }

        func submenu(_ menu: NSMenu) throws -> NSMenu {
            try #require(menu.items.first { $0.identifier == MainWindowController.ContextItemID.groupAccount }?.submenu)
        }

        let opened = try submenu(try #require(harness.controller.sidebar.contextMenu(forGroup: group)))
        #expect(opened.items.count == 4, "two accounts, a separator, None")
        #expect(opened.items[0].identifier == MainWindowController.ContextItemID.groupAccountRow("claude"))
        #expect(opened.items[0].title == "Claude")
        #expect(opened.items[1].identifier == MainWindowController.ContextItemID.groupAccountRow("claude-alt"))
        #expect(opened.items[1].toolTip == "~/.claude-alt", "each row names the config dir it means")

        // Nothing is set yet: None carries the mark and no account does.
        #expect(harness.store.state.groups[group]?.defaultAccountKey == nil)
        let none = try #require(opened.items.first { $0.identifier == MainWindowController.ContextItemID.groupAccountNone })
        #expect(none.state == .on)
        #expect(opened.items.filter { $0.state == .on }.count == 1)

        // Pick one.
        let pick = try #require(opened.items.first {
            $0.identifier == MainWindowController.ContextItemID.groupAccountRow("claude-alt")
        })
        _ = pick.target?.perform(pick.action, with: pick)
        harness.store.flush()
        #expect(harness.store.state.groups[group]?.defaultAccountKey == "claude-alt")
        // The ＋ menu was re-scoped in the same breath, so it does not show the old checkmark.
        #expect(harness.controller.newSessionMenu.effectiveAccountKey == "claude-alt")

        // Re-opening marks it, and only it. New sessions in the group inherit it.
        let reopened = try submenu(try #require(harness.controller.sidebar.contextMenu(forGroup: group)))
        let marked = reopened.items.filter { $0.state == .on }
        #expect(marked.count == 1)
        #expect(marked.first?.identifier == MainWindowController.ContextItemID.groupAccountRow("claude-alt"))
        harness.mutate { _ = $0.createSession(groupID: group, cwd: NSTemporaryDirectory()) }
        #expect(harness.store.state.sessions(in: group).last?.accountKey == "claude-alt")
        // The rows that were already running are left alone — their pty already has its own
        // CLAUDE_CONFIG_DIR, and re-labelling them would be a lie.
        #expect(harness.store.state.sessions[ids[0]]?.accountKey == "claude")

        // The same submenu hangs off a session row, and acts on that row's group.
        let fromRow = try submenu(try #require(harness.controller.sidebar.contextMenu(forSession: ids[0])))
        let clear = try #require(fromRow.items.first { $0.identifier == MainWindowController.ContextItemID.groupAccountNone })
        _ = clear.target?.perform(clear.action, with: clear)
        harness.store.flush()
        #expect(harness.store.state.groups[group]?.defaultAccountKey == nil)
    }

    /// A default naming a config dir that has gone away: the group is still pointing at it, so the
    /// menu says so instead of showing a list with nothing marked.
    @Test("A default account that is no longer configured shows as not found")
    func groupDefaultAccountMissing() throws {
        let (harness, _, group) = Self.makeRestoredHarness()
        defer { harness.tearDown() }
        harness.mutate {
            $0.setAccount(Account(key: "claude", configDir: "~/.claude", label: "Claude"))
            $0.setGroupDefaultAccount(group, accountKey: "claude-gone")
        }

        let menu = try #require(harness.controller.sidebar.contextMenu(forGroup: group))
        let submenu = try #require(
            menu.items.first { $0.identifier == MainWindowController.ContextItemID.groupAccount }?.submenu)
        let missing = try #require(
            submenu.items.first { $0.identifier == MainWindowController.ContextItemID.groupAccountMissing })
        #expect(missing.state == .on)
        #expect(!missing.isEnabled)
        #expect(missing.title.contains("claude-gone"))
        #expect(missing.title.contains("not found"))
        #expect(submenu.items.filter { $0.state == .on }.count == 1)
    }

    /// The same submenu on a session row — it acts on the group the session lives in.
    @Test("A session row's Group color submenu colours that session's group")
    func groupColorMenuOnASessionRow() throws {
        let (harness, ids, group) = Self.makeRestoredHarness()
        defer { harness.tearDown() }

        let menu = try #require(harness.controller.sidebar.contextMenu(forSession: ids[0]))
        let submenu = try #require(
            menu.items.first { $0.identifier == MainWindowController.ContextItemID.groupColor }?.submenu)
        let coral = try #require(GroupPalette.swatches.first { $0.slug == "coral" })
        let pick = try #require(submenu.items.first {
            $0.identifier == MainWindowController.ContextItemID.groupColorSwatch(coral.slug)
        })
        _ = pick.target?.perform(pick.action, with: pick)
        harness.store.flush()

        #expect(harness.store.state.groups[group]?.color == coral.rgb)
        // The row it was invoked from is untouched otherwise — this is not a per-session colour.
        #expect(harness.store.state.selection == ids[0], "the menu does not move the selection")
    }

    /// A colour that is not in the palette (an older build, a hand-edited `state.json`) leaves every
    /// item unmarked rather than silently claiming the nearest swatch.
    @Test("An off-palette group colour marks nothing")
    func offPaletteColourMarksNothing() throws {
        let (harness, _, group) = Self.makeRestoredHarness()
        defer { harness.tearDown() }
        harness.mutate { $0.setGroupColor(group, color: RGB(hex: 0x123456)) }

        let menu = try #require(harness.controller.sidebar.contextMenu(forGroup: group))
        let submenu = try #require(
            menu.items.first { $0.identifier == MainWindowController.ContextItemID.groupColor }?.submenu)
        #expect(submenu.items.allSatisfy { $0.state == .off })
    }

    // MARK: - Another repo, auto-resume

    @Test("In another repo… makes a group for the folder and starts claude in it")
    func anotherRepo() throws {
        let (harness, _, _) = Self.makeRestoredHarness()
        defer { harness.tearDown() }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "tkzmux-another-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        harness.controller.folderPrompt = { _ in folder }
        #expect(harness.controller.newSessionMenu.performItem(NewSessionMenu.ItemID.anotherRepo))
        harness.store.flush()

        let created = try #require(harness.store.state.groups.values.first { $0.repoRoot == folder.standardizedFileURL.path })
        let launched = try #require(harness.host.opened.last)
        #expect(launched.cwd == folder.standardizedFileURL.path)
        #expect(harness.host.ran.last?.command == "claude")
        #expect(harness.store.state.sessions[launched.id]?.groupID == created.id)
        #expect(harness.store.state.selection == launched.id)
    }

    @Test("Auto-resume on launch resumes every restored conversation once the preference is on")
    func autoResume() throws {
        let (harness, ids, _) = Self.makeRestoredHarness()
        defer { harness.tearDown() }
        harness.controller.autoResumeIfEnabled()
        #expect(harness.host.ran.isEmpty, "off by default")

        harness.mutate { $0.setAutoResumeOnLaunch(true) }
        harness.controller.autoResumeIfEnabled()
        harness.store.flush()
        #expect(Set(harness.host.ran.map(\.command)) == ["claude --resume conv-0", "claude --resume conv-1"])
        #expect(harness.host.opened.count == 2)
        #expect(harness.store.state.selection == ids[0])

        harness.controller.dispatcher.perform(.toggleAutoResume)
        harness.store.flush()
        #expect(harness.store.state.autoResumeOnLaunch == false)
    }

    @Test("An exiting shell schedules a worktree refresh for its repo")
    func exitTriggersWorktreeRefresh() async throws {
        let (harness, ids, _) = Self.makeRestoredHarness()
        defer { harness.tearDown() }
        let recorder = SessionLauncherTests.Recorder()
        harness.controller.launcher.worktreeLister = { root in recorder.record(root); return [root] }
        harness.controller.launcher.worktreeRefreshDelay = .milliseconds(10)
        var refreshed = 0
        harness.controller.launcher.onWorktreesRefreshed = { _, _ in refreshed += 1 }

        harness.host.emit(.exited(.exited(code: 0)), for: ids[0])
        let deadline = ContinuousClock.now + .seconds(5)
        while refreshed == 0, ContinuousClock.now < deadline {
            harness.store.flush()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.roots.count == 1)
        #expect(recorder.roots.first.map { ($0 as NSString).standardizingPath }
            == (NSTemporaryDirectory() as NSString).standardizingPath)
        #expect(harness.store.state.sessions[ids[0]]?.live == nil)
    }
}
