// Where `StateFile.standard()` and `SnapshotStore.standard()` point (WOR-304 S3). Both now go
// through `AppPaths.support`; on the Mac the result must be exactly what the pre-AppPaths code
// produced, which is spelled out verbatim below. Nothing here reads or writes those locations.

import Foundation
import Testing
import TkzPlatform

@testable import Persistence

@Suite struct StandardLocationTests {
    @Test func standardLocationsLiveInAppPathsSupport() {
        #expect(StateFile.standard().url.path == AppPaths.support.path + "/state.json")
        #expect(SnapshotStore.standard().directory.path == AppPaths.support.path + "/sessions")
    }

    /// The injected base still gets `tkzmux/` appended, as before.
    @Test func anInjectedBaseIsHonoured() {
        let base = URL(fileURLWithPath: "/tmp/base", isDirectory: true)
        #expect(StateFile.standard(applicationSupport: base).url.path == "/tmp/base/tkzmux/state.json")
        #expect(SnapshotStore.standard(applicationSupport: base).directory.path == "/tmp/base/tkzmux/sessions")
    }

    #if os(macOS)
    /// The pre-WOR-304 body of both `standard()` functions, kept here as the reference.
    private static func preAppPathsBase(_ fileManager: FileManager = .default) -> URL {
        (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
    }

    @Test func macLocationsAreUnchanged() {
        let base = Self.preAppPathsBase()
        #expect(StateFile.standard().url == base
            .appending(path: "tkzmux", directoryHint: .isDirectory)
            .appending(path: "state.json", directoryHint: .notDirectory))
        #expect(SnapshotStore.standard().directory == base
            .appending(path: "tkzmux", directoryHint: .isDirectory)
            .appending(path: "sessions", directoryHint: .isDirectory))
        #expect(AppPaths.support == base.appending(path: "tkzmux", directoryHint: .isDirectory))
        #expect(AppPaths.runtime == AppPaths.support)
        #expect(AppPaths.support.path.hasSuffix("/Library/Application Support/tkzmux"))
    }
    #endif

    #if os(Linux)
    /// Linux user data is `$XDG_DATA_HOME/tkzmux` (default `~/.local/share/tkzmux`), never under
    /// `Library/`.
    @Test func linuxLocationsFollowXDG() {
        let environment = ProcessInfo.processInfo.environment
        let data = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? AppPaths.home.appending(path: ".local/share").path
        #expect(StateFile.standard().url.path == data + "/tkzmux/state.json")
        #expect(SnapshotStore.standard().directory.path == data + "/tkzmux/sessions")
        #expect(!StateFile.standard().url.path.contains("Library/Application Support"))
    }
    #endif
}
