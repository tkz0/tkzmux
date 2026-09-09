// MainWindowCompressionTests — the shipping window actually compresses.
//
// This exists because it did not, silently, for a long time. `TerminalViewHost.init` takes
// `compressor:` with a `nil` default, and `MainWindowController`'s convenience initialiser — the
// one `AppDelegate` calls — never passed one. Only `DevWindowController` (behind
// `TKZMUX_DEV_WINDOW=1`) built a compressor, so the real app ran every session with its full
// `SCROLLBACK_MAX_BYTES` retained: the 577 MiB side of the 577 → 26 MiB measurement in
// docs/perf.md, not the 26 MiB side. Nothing failed, because nothing asserted it.
//
// Three ways for that bug to come back, one test each: no compressor, a compressor that was never
// started, and a compressor whose snapshot hook writes somewhere other than the host's own store.
//
// The window is created but never ordered front. `snapshots:` is injected so this touches a temp
// directory and never `~/Library/Application Support/tkzmux`.

import AppKit
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
@Suite(.serialized)
struct MainWindowCompressionTests {

    private final class TempDirectory {
        let url: URL
        init() throws {
            url = URL(filePath: NSTemporaryDirectory())
                .appending(path: "tkzmux-compress-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var snapshotDirectory: URL { url.appending(path: "sessions", directoryHint: .isDirectory) }
        var snapshots: SnapshotStore { SnapshotStore(directory: snapshotDirectory) }
        /// The application-support directory the host is pointed at, so `createShellDirectory`
        /// mkdirs here and not in the user's real one.
        var support: URL { url.appending(path: "tkzmux", directoryHint: .isDirectory) }
    }

    /// `nil` on a machine with no Metal device — the render context cannot be built there.
    private static func makeWindow(_ temp: TempDirectory) throws -> MainWindowController? {
        guard MTLCreateSystemDefaultDevice() != nil else { return nil }
        _ = NSApplication.shared
        let context = try TerminalRenderContext(scale: 2)
        return MainWindowController(
            store: AppStore(state: .fixture), renderContext: context, theme: .default,
            snapshots: temp.snapshots, tkzmuxDirectory: temp.support)
    }

    @Test("the shipping window's host has an idle compressor, and it is running")
    func shippingWindowCompresses() throws {
        let temp = try TempDirectory()
        guard let controller = try Self.makeWindow(temp) else { return }
        defer { controller.shutdown() }

        let host = try #require(controller.host as? TerminalViewHost)
        let compressor = try #require(
            host.compressor, "the real window must build a compressor, not default it to nil")
        // A compressor nobody started is the same bug wearing a different hat.
        #expect(compressor.isRunning)
    }

    @Test("a pass writes its snapshot into the host's own store, not the user's support directory")
    func snapshotHookUsesTheInjectedStore() throws {
        let temp = try TempDirectory()
        guard let controller = try Self.makeWindow(temp) else { return }
        defer { controller.shutdown() }

        let host = try #require(controller.host as? TerminalViewHost)
        let compressor = try #require(host.compressor)

        // A session with enough history to be worth compressing. Registered straight on the
        // compressor so this test needs no pty and no shell.
        let session = try TerminalSession(options: TerminalSessionOptions(cols: 80, rows: 24))
        session.write(ptyText: String(repeating: "scrollback line\r\n", count: 2000))
        compressor.register("compress-target", session: session, isVisible: false)

        // The production policy waits 60 s. `tick` takes the instant it should reason about, so
        // the wait is expressed rather than slept through.
        compressor.tick(now: .now.advanced(by: .seconds(61)))

        let stats = compressor.stats
        #expect(stats.passes > 0, "a long-idle, non-visible session should have been compressed")
        #expect(stats.snapshotsWritten > 0, "the snapshot-before-compress hook should have run")

        // The hook must save through the *same* store the host was given.
        let written = (try? FileManager.default.contentsOfDirectory(
            at: temp.snapshotDirectory, includingPropertiesForKeys: nil)) ?? []
        #expect(written.contains { $0.lastPathComponent.hasPrefix("compress-target") })
    }
}
