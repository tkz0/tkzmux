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
        #expect(restored.items.count == 4, "Resume, Rename, separator, Remove")

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
