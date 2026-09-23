// SessionSwitchResizeTests — switching away from a row and back must not resize its terminals.
//
// Every size a pane's view takes while its terminal is attached reaches the pty (the real
// `TerminalMetalView` forces a resize on attach and applies any later bounds change on the next
// tick), and each one is a SIGWINCH the program inside redraws for. Claude Code redraws its UI in
// place, so a transient size leaves rows of an older frame behind (reported 2026-09-23: garbled
// output after navigating between sessions and back). The pane must come back at exactly the size
// it left with, and hold it.

import AppKit
import Foundation
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct SessionSwitchResizeTests {
    typealias Base = MainWindowControllerTests

    /// Every frame change of every pane view, stamped with how many `show` calls the host had seen.
    final class FrameLog {
        struct Entry { var view: ObjectIdentifier; var size: NSSize; var shows: Int }
        var entries: [Entry] = []
        var shows: () -> Int = { 0 }
    }

    final class RecordingTerminalView: NSView, TerminalPaneSurface {
        let log: FrameLog
        var onGridResize: ((TerminalSize) -> Void)?
        init(frame: NSRect, log: FrameLog) {
            self.log = log
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }
        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize != frame.size
            super.setFrameSize(newSize)
            if changed {
                log.entries.append(.init(view: ObjectIdentifier(self), size: newSize, shows: log.shows()))
            }
        }
        func show(_ session: TerminalSession?) {}
        func setCursorSuppressed(_ suppressed: Bool) {}
        func gridSizeForBounds() -> TerminalSize { TerminalSize(rows: 40, cols: 120) }
    }

    static func makeHarness(log: FrameLog) -> Base.Harness {
        _ = NSApplication.shared
        let store = AppStore(state: .fixture)
        let host = Base.SpyTerminalHost()
        log.shows = { [weak host] in host?.shownTerminals.count ?? 0 }
        let first = RecordingTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), log: log)
        let controller = MainWindowController(
            store: store, host: host, sharedView: first,
            terminalViewFactory: { _ in
                RecordingTerminalView(frame: NSRect(x: 0, y: 0, width: 450, height: 700), log: log)
            },
            theme: .default, home: Base.emptyHome)
        let harness = Base.Harness(
            store: store, controller: controller, host: host,
            terminalView: Base.FakeTerminalView(frame: .zero))
        Base.keepOffScreen(controller)
        harness.layout()
        return harness
    }

    static func giveShell(_ harness: Base.Harness, _ id: SessionID) throws {
        _ = try harness.host.openRow(id)
        harness.mutate { $0.setLive(LiveSessionState(shellPid: 1, status: .idle), for: id) }
    }

    func select(_ harness: Base.Harness, _ id: SessionID) {
        harness.mutate { $0.select(id) }
        harness.layout()
    }

    /// The sizes each of `terminals`' views has now.
    func sizes(_ harness: Base.Harness, _ terminals: [TerminalID]) throws -> [TerminalID: NSSize] {
        var out: [TerminalID: NSSize] = [:]
        for terminal in terminals {
            let chrome = try #require(harness.controller.paneContainer.paneView(for: terminal))
            let surface = try #require(Self.surface(in: chrome))
            out[terminal] = surface.frame.size
        }
        return out
    }

    static func surface(in view: NSView) -> RecordingTerminalView? {
        if let view = view as? RecordingTerminalView { return view }
        for sub in view.subviews { if let found = surface(in: sub) { return found } }
        return nil
    }

    @Test(arguments: [PaneAxis.vertical, .horizontal])
    func switchingAwayAndBackKeepsASplitRowsPaneSizes(axis: PaneAxis) throws {
        let log = FrameLog()
        let harness = Self.makeHarness(log: log)
        defer { harness.tearDown() }
        let rows = harness.store.state.orderedSessions.prefix(2).map(\.id)
        let (a, b) = (rows[0], rows[1])
        try Self.giveShell(harness, a)
        try Self.giveShell(harness, b)

        // Row A, split like the reported one: the agent on top, a dev server below.
        select(harness, a)
        let top = try #require(harness.store.state.sessions[a]?.focusedTerminalID)
        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(top, axis: axis) }
        let bottom = try #require(second)
        _ = try harness.host.open(
            bottom, session: a, cwd: "/tmp", env: [:], size: TerminalSize(rows: 20, cols: 80))
        harness.store.flush()
        harness.layout()
        let before = try sizes(harness, [top, bottom])

        // Away to single-pane row B, and back.
        select(harness, b)
        let showsBeforeReturn = harness.host.shownTerminals.count
        select(harness, a)
        #expect(harness.host.visibleTerminalIDs == [top, bottom])

        let after = try sizes(harness, [top, bottom])
        #expect(after == before, "row A's panes came back at a different size")

        // Nothing may move once A's terminals are attached again: each such change is a resize the
        // shell inside is told about.
        let attachIndex = try #require(
            harness.host.shownTerminals.indices.first {
                $0 >= showsBeforeReturn && harness.host.shownTerminals[$0] == [top, bottom]
            })
        let paneViews = [top, bottom].compactMap { terminal in
            harness.controller.paneContainer.paneView(for: terminal).flatMap(Self.surface(in:)).map(ObjectIdentifier.init)
        }
        #expect(paneViews.count == 2)
        let movedWhileAttached = log.entries.filter { $0.shows > attachIndex && paneViews.contains($0.view) }
        #expect(movedWhileAttached.isEmpty, "resized after attach: \(movedWhileAttached.map(\.size))")
    }
}
