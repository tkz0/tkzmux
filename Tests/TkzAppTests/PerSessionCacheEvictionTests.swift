// PerSessionCacheEvictionTests — removing a row must drop what was cached under its id.
//
// `ClaudeIntegration.fullMessages` is the one that motivated this: it holds the *complete* last
// Stop message per session (the store only keeps a 4 KiB prefix), which for a reply containing a
// pasted diff or a log dump is arbitrarily large. It had no removal path at all — not on session
// close, not on row removal — so the app accumulated one entry per session id it had ever seen and
// held them until it quit. `pidToSession` had the same shape.
//
// `SessionLauncher.remove(_:)` is the only path a row is ever removed by, so `onRemoved` there is
// the choke point these assertions go through.

import AppKit
import Foundation
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite("Per-session cache eviction", .serialized)
struct PerSessionCacheEvictionTests {

    /// A throwaway directory: `ClaudeIntegration` writes shim files under whatever it is given,
    /// and a test must never touch the real one.
    private static func makeClaude(_ store: AppStore) -> ClaudeIntegration {
        let dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tkzmux-claude-\(UUID().uuidString)", directoryHint: .isDirectory)
        return ClaudeIntegration(store: store, directory: dir)
    }

    @Test("removing a session drops its cached full Stop message")
    func removeDropsFullMessage() throws {
        let store = AppStore(state: .fixture)
        let groupID = try #require(store.state.orderedGroups.first?.id)
        var created: Session?
        store.update { created = $0.createSession(groupID: groupID, cwd: "/tmp") }
        let id = try #require(created?.id)

        let claude = Self.makeClaude(store)
        let long = String(repeating: "x", count: 200_000)
        claude.fullMessages[id] = long
        #expect(claude.lastMessage(for: id) == long)

        claude.forget(id)

        // Falls back to the store's truncated copy — which for a removed row is nothing.
        #expect(claude.lastMessage(for: id) != long)
        #expect(claude.pidToSession.values.contains(id) == false)
    }

    @Test("forget also unbinds the pid, so a reused pid cannot resolve to a dead row")
    func forgetUnbindsPid() throws {
        let store = AppStore(state: .fixture)
        let groupID = try #require(store.state.orderedGroups.first?.id)
        var created: Session?
        store.update { created = $0.createSession(groupID: groupID, cwd: "/tmp") }
        let id = try #require(created?.id)

        let claude = Self.makeClaude(store)
        claude.pidToSession[4242] = id
        #expect(claude.pidToSession[4242] == id)

        claude.forget(id)
        #expect(claude.pidToSession[4242] == nil)
    }

    /// The launcher is the only way a row is removed, so the eviction has to hang off it — a fix
    /// wired anywhere else would be missed by ⌘W, the row's ×, and the context menu alike.
    @Test("the launcher's removal hook is what drives eviction")
    func launcherHookFires() throws {
        let store = AppStore(state: .fixture)
        let groupID = try #require(store.state.orderedGroups.first?.id)
        var created: Session?
        store.update { created = $0.createSession(groupID: groupID, cwd: "/tmp") }
        let id = try #require(created?.id)

        let host = SpyHost()
        let launcher = SessionLauncher(store: store, host: host, home: NSHomeDirectory())
        var removed: [SessionID] = []
        launcher.onRemoved = { removed.append($0) }

        launcher.remove(id)

        #expect(removed == [id])
        #expect(store.state.sessions[id] == nil)
    }

    /// Removing a *group* takes its rows with it, and that is a second way a row leaves — added
    /// after the eviction hook was written. It has to fire the same hook, or every session in a
    /// removed group leaks its cached Stop message.
    @Test("removing a group evicts every member, not just the group")
    func removingAGroupEvictsMembers() throws {
        let store = AppStore(state: .fixture)
        let groupID = try #require(store.state.orderedGroups.first?.id)
        var ids: [SessionID] = []
        store.update { state in
            for _ in 0..<3 { ids.append(state.createSession(groupID: groupID, cwd: "/tmp").id) }
        }

        // The fixture group already has rows of its own; the whole membership must be evicted,
        // not just the three added here.
        let members = Set(store.state.sessions(in: groupID).map(\.id))
        #expect(members.isSuperset(of: ids))

        let launcher = SessionLauncher(store: store, host: SpyHost(), home: NSHomeDirectory())
        var removed: [SessionID] = []
        launcher.onRemoved = { removed.append($0) }

        launcher.removeGroup(groupID)

        #expect(Set(removed) == members, "every member should have been evicted")
        #expect(removed.count == members.count, "and each exactly once")
        #expect(store.state.groups[groupID] == nil)
    }

    /// Minimal host: `remove` only needs `discard`.
    @MainActor
    private final class SpyHost: TerminalHost {
        var discarded: [SessionID] = []
        func open(_ id: SessionID, cwd: String, env: [String: String], size: TerminalSize) throws -> pid_t { 1 }
        func run(_ id: SessionID, command: String) {}
        func show(_ id: SessionID?) {}
        var visibleSessionID: SessionID? { nil }
        func resize(_ id: SessionID, _ size: TerminalSize) {}
        func close(_ id: SessionID, signal: Int32) {}
        func snapshot(_ id: SessionID) throws -> Data { Data() }
        func restore(_ id: SessionID, from: Data, cwd: String, env: [String: String]) throws -> pid_t { 1 }
        func savedSnapshot(_ id: SessionID) -> Data? { nil }
        func discard(_ id: SessionID) { discarded.append(id) }
        var events: AsyncStream<(SessionID, TerminalEvent)> { AsyncStream { $0.finish() } }
    }
}

