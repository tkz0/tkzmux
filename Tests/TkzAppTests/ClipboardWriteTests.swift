// ClipboardWriteTests — an OSC 52 clipboard write arriving through our pty reaches the pasteboard.
//
// Over ssh, OSC 52 is the *only* way a program can reach the Mac clipboard: Claude Code under
// herdr on a remote host has no `pbcopy`. `TerminalSession` already decodes the sequence into
// `.clipboardWrite`; these tests pin that `MainWindowController.handle(_:for:)` hands it on rather
// than dropping it in `default:`, which it did until this suite existed.
//
// The pasteboard is a fake, so no test touches the user's real clipboard. The window is built by
// `MainWindowControllerTests.makeSplitHarness` and never ordered front.

import AppKit
import Foundation
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct ClipboardWriteTests {

    @MainActor
    private final class FakePasteboard: PasteboardWriting {
        var written: [String] = []
        func writeString(_ string: String) { written.append(string) }
    }

    private struct Rig {
        let harness: MainWindowControllerTests.Harness
        let pasteboard: FakePasteboard
        let focusedPane: TerminalID
        let otherPane: TerminalID
    }

    /// A selected row split into two panes, the first one focused.
    private static func makeRig() -> Rig {
        let harness = MainWindowControllerTests.makeSplitHarness()
        let pasteboard = FakePasteboard()
        harness.controller.pasteboardWriter = pasteboard
        let id = harness.store.state.orderedSessions[0].id
        let first = TerminalID(uuid: id.uuid)
        _ = try! harness.host.openRow(id)
        harness.mutate {
            $0.setLive(LiveSessionState(shellPid: 1, status: .idle), for: id)
            $0.select(id)
        }
        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        harness.layout()
        return Rig(harness: harness, pasteboard: pasteboard, focusedPane: first, otherPane: second!)
    }

    /// The event crosses `SpyTerminalHost`'s `AsyncStream` and a main-actor `Task`, so it never
    /// lands in the same turn as `emit`. Generous for the same contention reason as
    /// `TerminalNotificationTests.settleTimeout`; it returns the moment the predicate holds.
    private static func settle(timeout: Duration = .seconds(15), until predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test("an OSC 52 write from the focused pane reaches the pasteboard")
    func writeFromFocusedPane() async {
        let rig = Self.makeRig()
        defer { rig.harness.tearDown() }

        rig.harness.host.emit(.clipboardWrite("from ssh"), forTerminal: rig.focusedPane)
        #expect(await Self.settle { !rig.pasteboard.written.isEmpty })
        #expect(rig.pasteboard.written == ["from ssh"])
    }

    @Test("an OSC 52 write from a pane that is not focused is honoured too")
    func writeFromOtherPane() async {
        let rig = Self.makeRig()
        defer { rig.harness.tearDown() }

        rig.harness.host.emit(.clipboardWrite("background copy"), forTerminal: rig.otherPane)
        #expect(await Self.settle { !rig.pasteboard.written.isEmpty })
        #expect(rig.pasteboard.written == ["background copy"])
    }

    @Test("an empty OSC 52 write (a clear request) leaves the clipboard alone")
    func emptyWriteIsIgnored() async {
        let rig = Self.makeRig()
        defer { rig.harness.tearDown() }

        // The non-empty write behind it is the fence: once it has landed, the empty one before it
        // has been through the same stream and handler.
        rig.harness.host.emit(.clipboardWrite(""), forTerminal: rig.focusedPane)
        rig.harness.host.emit(.clipboardWrite("fence"), forTerminal: rig.focusedPane)
        #expect(await Self.settle { !rig.pasteboard.written.isEmpty })
        #expect(rig.pasteboard.written == ["fence"])
    }
}
