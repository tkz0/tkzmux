// SessionMemoryBadgeTests — the sidebar badge for a session whose processes are eating memory.
//
// This is the in-app answer to the question that started all of this: "why is tkzmux using 30 GB?"
// It was not — a `swift test` under one session was, and nothing in the app said so. The badge puts
// the number on the row that owns the processes.
//
// Two properties matter and are easy to get wrong in opposite directions: it must be *absent* for a
// normal session (a badge on every row is a badge nobody reads — the same rule the account chip
// follows), and the sampling must not redraw a row every minute just because a steady session's
// footprint drifted by a few MB.

import Foundation
import Testing
import TkzCore

@testable import TkzApp

// `memoryBucket` lives on the (main-actor) window controller.
@MainActor
@Suite("Session memory badge")
struct SessionMemoryBadgeTests {

    /// A session carrying one sampled footprint, built through the reducer so the shape is real.
    private static func session(footprint: UInt64?) -> Session {
        var state = AppState()
        let group = state.addGroup(name: "G", repoRoot: "/tmp")
        var session = state.createSession(groupID: group.id, cwd: "/tmp")
        var live = LiveSessionState()
        live.subtreeFootprintBytes = footprint
        session.live = live
        return session
    }

    @Test("a normal session carries no badge")
    func normalSessionHasNoBadge() {
        // Six Claude Code processes at ~350 MB is the measured normal baseline; nowhere near it.
        #expect(SidebarRowAdapter.memoryBadge(for: Self.session(footprint: 2 * 1024 * 1024 * 1024)) == nil)
        #expect(SidebarRowAdapter.memoryBadge(for: Self.session(footprint: 300 * 1024 * 1024)) == nil)
        // Never sampled, and no live state at all.
        #expect(SidebarRowAdapter.memoryBadge(for: Self.session(footprint: nil)) == nil)
        var bare = Self.session(footprint: nil)
        bare.live = nil
        #expect(SidebarRowAdapter.memoryBadge(for: bare) == nil)
    }

    @Test("a runaway session is badged with its size in GB")
    func runawaySessionIsBadged() {
        let badge = SidebarRowAdapter.memoryBadge(for: Self.session(footprint: 6_500_000_000))
        #expect(badge == "6.1 GB")
        // Exactly at the threshold counts as over.
        #expect(
            SidebarRowAdapter.memoryBadge(
                for: Self.session(footprint: SidebarRowAdapter.memoryBadgeThreshold)) == "4.0 GB")
        // And a hair under does not.
        #expect(
            SidebarRowAdapter.memoryBadge(
                for: Self.session(footprint: SidebarRowAdapter.memoryBadgeThreshold - 1)) == nil)
    }

    @Test("the badge reaches the row model")
    func badgeReachesRowModel() {
        var state = AppState()
        let group = state.addGroup(name: "G", repoRoot: "/tmp")
        var session = state.createSession(groupID: group.id, cwd: "/tmp")
        var live = LiveSessionState()
        live.subtreeFootprintBytes = 9_000_000_000
        session.live = live
        state.sessions[session.id] = session

        let model = SidebarRowAdapter.sessionModel(session, in: state)
        #expect(model.memoryBadge == "8.4 GB")
    }

    /// Every store write is a `ChangeSet.sessions` entry, which reloads that row — the one thing
    /// the sidebar's design exists to avoid. So a steady session must not produce a write a minute.
    @Test("small drift does not change the bucket, so a steady session never redraws")
    func driftDoesNotRedraw() {
        let base: UInt64 = 1_200_000_000
        #expect(MainWindowController.memoryBucket(base) == MainWindowController.memoryBucket(base + 1_000_000))
        #expect(MainWindowController.memoryBucket(base) == MainWindowController.memoryBucket(base + 50_000_000))
        // A jump worth showing does change it.
        #expect(MainWindowController.memoryBucket(base) != MainWindowController.memoryBucket(base + 600_000_000))
        // First sample ever is always a change.
        #expect(MainWindowController.memoryBucket(nil) != MainWindowController.memoryBucket(base))
        #expect(MainWindowController.memoryBucket(nil) == nil)
    }

    /// Above the threshold the number is on screen at 0.1 GB resolution, so the bucket has to be
    /// finer there — otherwise a runaway climbing from 4 GB to 6 GB would show a stale figure.
    @Test("above the threshold the bucket tracks the tenth of a GB the badge shows")
    func fineBucketsAboveThreshold() {
        let four = SidebarRowAdapter.memoryBadgeThreshold
        #expect(MainWindowController.memoryBucket(four) != MainWindowController.memoryBucket(four + 200_000_000))
        // And crossing the threshold is always a change.
        #expect(MainWindowController.memoryBucket(four - 1) != MainWindowController.memoryBucket(four))
    }
}
