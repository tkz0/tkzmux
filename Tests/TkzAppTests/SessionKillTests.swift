// SessionKillTests — the "kill this session's processes" action on the sidebar row.
//
// This is the escape hatch for the incident that motivated `SessionMemory`: a build or test under
// a session runs away, and nothing in the system takes the memory back. Jetsam does not kill a
// stalled user process, so it sits there until someone kills it by hand. That "by hand" is what
// this action replaces.
//
// The host here is a real `TerminalViewHost` over a real login zsh, because the whole point is
// signalling a real process subtree; the environment and snapshot store are both redirected at
// temp directories (shared agent brief, hard rule 8).

import AppKit
import ClaudeBridge
import Darwin
import Foundation
import Metal
import Persistence
import Testing
import TkzCore
import TkzTerminalCore
import TkzTerminalRender
import TkzTerminalView

@testable import TkzApp

@MainActor
@Suite("Session process kill", .serialized)
struct SessionKillTests {

    private final class Temp {
        let url: URL
        init() throws {
            url = URL(filePath: NSTemporaryDirectory())
                .appending(path: "tkzmux-kill-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var snapshots: SnapshotStore { SnapshotStore(directory: url.appending(path: "sessions")) }
        var support: URL { url.appending(path: "tkzmux", directoryHint: .isDirectory) }
    }

    /// A minimal environment: never the developer's own.
    private static func testEnvironment() -> [String: String] {
        [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": "/bin/zsh",
            "USER": ProcessInfo.processInfo.userName,
            "LANG": "en_US.UTF-8",
        ]
    }

    private struct Harness {
        let controller: MainWindowController
        let host: TerminalViewHost
        let sessionID: SessionID
        let terminalID: TerminalID
        let pid: pid_t
    }

    /// `nil` when there is no Metal device (the render context cannot be built).
    private static func makeHarness(_ temp: Temp) throws -> Harness? {
        guard MTLCreateSystemDefaultDevice() != nil else { return nil }
        _ = NSApplication.shared
        let context = try TerminalRenderContext(scale: 2)
        let view = TerminalMetalView(
            renderContext: context, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let host = TerminalViewHost(
            renderContext: context, snapshots: temp.snapshots, tkzmuxDirectory: temp.support,
            baseEnvironment: testEnvironment())

        // The store must carry the same id the host opened, because the context menu is built from
        // the store's session and keyed by that id.
        let store = AppStore(state: .fixture)
        let groupID = try #require(store.state.orderedGroups.first?.id)
        var created: Session?
        store.update { created = $0.createSession(groupID: groupID, cwd: NSHomeDirectory()) }
        let id = try #require(created?.id)
        // `Session.init` seeds its first leaf with the row's own uuid (TKZ-36).
        let terminal = TerminalID(uuid: id.uuid)

        let pid = try host.open(
            terminal, session: id, cwd: NSHomeDirectory(), env: [:], size: view.gridSizeForBounds())
        host.show([terminal: view])
        let controller = MainWindowController(
            store: store, host: host, terminalView: view, theme: .default)
        return Harness(controller: controller, host: host, sessionID: id, terminalID: terminal, pid: pid)
    }

    private static func waitFor(seconds: Double = 15, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @Test("the item appears only once the session has child processes, and names the biggest")
    func menuItemAppearsWithChildren() throws {
        let temp = try Temp()
        guard let harness = try Self.makeHarness(temp) else { return }
        defer { harness.controller.shutdown() }

        // A bare shell is one process: nothing to kill, so nothing offered.
        let bare = try #require(harness.controller.sessionContextMenu(for: harness.sessionID))
        #expect(bare.items.allSatisfy { $0.identifier != MainWindowController.ContextItemID.killProcessTree })

        harness.host.run(harness.terminalID, command: "sleep 45")
        #expect(
            Self.waitFor { SessionMemory.sample(rootPid: harness.pid).processCount > 1 },
            "the shell should have forked a child")

        let menu = try #require(harness.controller.sessionContextMenu(for: harness.sessionID))
        let item = try #require(
            menu.items.first { $0.identifier == MainWindowController.ContextItemID.killProcessTree })
        #expect(item.title.hasPrefix("Kill Processes ("))
        // It names what it would kill, so the user is not guessing.
        #expect(item.title.contains("sleep"), "got \(item.title)")
    }

    /// A split row is two idle shells, not one process with a phantom descendant: summing
    /// `processCount` across panes without collapsing each pane's own root would have counted
    /// every sibling shell as something to kill.
    @Test("a split row of two bare shells offers nothing to kill")
    func splitRowOfBareShellsOffersNothing() throws {
        let temp = try Temp()
        guard let harness = try Self.makeHarness(temp) else { return }
        defer { harness.controller.shutdown() }

        let second = try #require(
            harness.controller.store.updating { $0.splitPane(harness.terminalID, axis: .vertical) })
        _ = try harness.host.open(
            second, session: harness.sessionID, cwd: NSHomeDirectory(), env: [:],
            size: TerminalSize(rows: 24, cols: 80))

        let menu = try #require(harness.controller.sessionContextMenu(for: harness.sessionID))
        #expect(menu.items.allSatisfy { $0.identifier != MainWindowController.ContextItemID.killProcessTree })
    }

    @Test("killing the tree signals the children and leaves the session's shell alive")
    func killSparesTheShell() throws {
        let temp = try Temp()
        guard let harness = try Self.makeHarness(temp) else { return }
        defer { harness.controller.shutdown() }

        harness.host.run(harness.terminalID, command: "sleep 45")
        #expect(Self.waitFor { SessionMemory.sample(rootPid: harness.pid).processCount > 1 })

        var asked: SessionMemorySample?
        harness.controller.killProcessTreeConfirm = { sample in
            asked = sample
            return true
        }
        harness.controller.killProcessTree(for: harness.sessionID)

        #expect(asked != nil, "the action must confirm before killing")
        #expect((asked?.processCount ?? 0) > 1)
        // The `sleep` is gone…
        #expect(Self.waitFor { !ProcessTree.descendants(of: harness.pid).contains { SessionMemory.name(of: $0) == "sleep" } })
        // …and the shell that owns the row is not.
        #expect(kill(harness.pid, 0) == 0)
    }

    /// The sampling wiring, end to end: a real session's real processes, through
    /// `sampleSessionMemory()`, into the store, out via the row model. Every piece of this is unit
    /// tested separately; this is the one that would catch the pieces not being connected.
    @Test("sampleSessionMemory puts a real reading into the store")
    func samplingReachesTheStore() throws {
        let temp = try Temp()
        guard let harness = try Self.makeHarness(temp) else { return }
        defer { harness.controller.shutdown() }

        // Nothing sampled yet.
        #expect(harness.controller.store.state.sessions[harness.sessionID]?.live?.subtreeFootprintBytes == nil)

        harness.controller.sampleSessionMemory()

        let bytes = try #require(
            harness.controller.store.state.sessions[harness.sessionID]?.live?.subtreeFootprintBytes,
            "the tick should have written a footprint for the live session")
        // A login zsh is megabytes, not zero and not gigabytes.
        #expect(bytes > 512 * 1024)
        #expect(bytes < 1024 * 1024 * 1024)

        // Well under the threshold, so the row stays badge-free — the normal case.
        let session = try #require(harness.controller.store.state.sessions[harness.sessionID])
        #expect(SidebarRowAdapter.memoryBadge(for: session) == nil)
    }

    @Test("declining the confirmation kills nothing")
    func declineKillsNothing() throws {
        let temp = try Temp()
        guard let harness = try Self.makeHarness(temp) else { return }
        defer { harness.controller.shutdown() }

        harness.host.run(harness.terminalID, command: "sleep 45")
        #expect(Self.waitFor { SessionMemory.sample(rootPid: harness.pid).processCount > 1 })

        harness.controller.killProcessTreeConfirm = { _ in false }
        harness.controller.killProcessTree(for: harness.sessionID)

        // Still there.
        #expect(SessionMemory.sample(rootPid: harness.pid).processCount > 1)
        #expect(kill(harness.pid, 0) == 0)
    }
}
