// StartupStateTests — M2.5 (TKZ-43): the state a fresh install comes up in, and tilde expansion.

import Foundation
import Testing

@testable import TkzCore

@Suite struct StartupStateTests {

    @Test("The startup state is one launchable home group and nothing else")
    func startupShape() {
        let state = AppState.startup(homeDirectory: "/Users/someone")

        #expect(state.sessions.isEmpty)
        #expect(state.selection == nil)
        #expect(state.presets.isEmpty)
        #expect(state.groups.count == 1)

        let group = try! #require(state.orderedGroups.first)
        #expect(group.name == "someone")
        // Load-bearing: `NewSessionMenu` disables every launch row when `repoRoot` is nil, so a
        // bucket group would make ⌘N open a menu of dead entries.
        #expect(group.repoRoot == "/Users/someone")
    }

    @Test("A home path with no last component still gets a name")
    func startupNamesTheRootDirectory() {
        #expect(AppState.startup(homeDirectory: "/").orderedGroups.first?.name == "/")
    }

    @Test("The startup state summarises as empty")
    func startupSummary() {
        let counts = AppState.startup(homeDirectory: "/Users/someone").summaryCounts
        #expect(counts == (0, 0, 0, 0))
    }

    @Test("Tilde expansion happens only for a leading ~ and only against the given home")
    func tildeExpansion() {
        let home = "/Users/someone"
        #expect(Paths.expandingTilde("~", home: home) == home)
        #expect(Paths.expandingTilde("~/", home: home) == home)
        #expect(Paths.expandingTilde("~/dev/tkzmux", home: home) == "/Users/someone/dev/tkzmux")
        #expect(Paths.expandingTilde("/absolute/path", home: home) == "/absolute/path")
        #expect(Paths.expandingTilde("relative/path", home: home) == "relative/path")
        #expect(Paths.expandingTilde("", home: home) == "")
        // `~user` is another user's home; resolving it is not ours to guess.
        #expect(Paths.expandingTilde("~other/dev", home: home) == "~other/dev")
        // A trailing slash on home must not double up.
        #expect(Paths.expandingTilde("~/dev", home: "/Users/someone/") == "/Users/someone/dev")
    }
}
