// MainWindowControllerTests — M2.2 (TKZ-18), the assembled window.
//
// Everything here runs in a real `NSWindow` that is **never ordered front**: the window is created
// by the controller, laid out, and asserted on. That is the only way to check the split view's
// geometry — `minimumThickness` alone tells you nothing about the width the sidebar actually got.
//
// The terminal half is a spy: `SpyTerminalHost` records `show(_:)` calls, and the surface is a
// plain focusable `NSView` instead of a `TerminalMetalView`. Two reasons: a real
// `TerminalViewHost` writes `.ghsnap` files into `~/Library/Application Support/tkzmux` (shared
// agent brief, hard rule 8), and "show was called with this id" is not observable on the real host
// when no session has been opened. `UserDefaults` is likewise a throwaway suite.
//
// AppKit is `@MainActor` and the store delivers on the main queue, so the suite is serialised.

import AppKit
import Foundation
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct MainWindowControllerTests {

    // MARK: - Doubles

    /// Records what the window asked of the terminal half.
    ///
    /// The host is keyed by `TerminalID` since TKZ-36, but almost every assertion in these suites
    /// is about a *row*. Both are recorded, and the `SessionID`-shaped accessors are the ones the
    /// tests read: a row created by these harnesses has exactly one pane, whose uuid **is** the
    /// row's (`Session.init`, and `Migrations.liftV1ToV2` for anything restored), so the mapping
    /// is the real invariant rather than a convenience. A test that genuinely cares about panes
    /// reads `openedTerminals` / `shownTerminals`.
    @MainActor
    final class SpyTerminalHost: TerminalHost {
        struct Opened: Equatable {
            var id: SessionID
            var terminal: TerminalID
            var cwd: String
            var env: [String: String]
        }

        struct Restored: Equatable {
            var id: SessionID
            var terminal: TerminalID
            var cwd: String
            var env: [String: String]
            var snapshot: Data
        }

        private(set) var shownTerminals: [Set<TerminalID>] = []
        private(set) var closed: [(id: SessionID, signal: Int32)] = []
        private(set) var opened: [Opened] = []
        private(set) var restored: [Restored] = []
        private(set) var discardedTerminals: [TerminalID] = []
        private(set) var ranTerminals: [(id: TerminalID, command: String)] = []
        /// Set to make the next `open` throw, so the failure path can be asserted.
        var openError: (any Error)?
        /// Set to make the next `restore` throw (a snapshot that no longer decodes).
        var restoreError: (any Error)?
        /// `.ghsnap` files "on disk", by row — what `savedSnapshot` answers from.
        var savedSnapshots: [SessionID: Data] = [:]
        /// The live grids: every terminal opened or restored on this host. `snapshot` answers for
        /// these; `discard` and the eviction inside a reopen remove them.
        private(set) var heldTerminals: Set<TerminalID> = []
        private(set) var visibleTerminalIDs: Set<TerminalID> = []
        let events: AsyncStream<(TerminalID, TerminalEvent)>
        private let continuation: AsyncStream<(TerminalID, TerminalEvent)>.Continuation

        init() {
            var escapee: AsyncStream<(TerminalID, TerminalEvent)>.Continuation!
            events = AsyncStream { escapee = $0 }
            continuation = escapee
        }

        func open(
            _ id: TerminalID, session: SessionID, cwd: String, env: [String: String],
            size: TerminalSize
        ) throws -> pid_t {
            if let openError { throw openError }
            opened.append(Opened(id: session, terminal: id, cwd: cwd, env: env))
            evict(id)
            heldTerminals.insert(id)
            return 4242
        }

        /// The real host drops a terminal it already holds under `id` before adopting the new one,
        /// and that detaches its surface. Modelled here so a reopen of the selected row that
        /// forgets to re-show it fails a test rather than a user.
        private func evict(_ id: TerminalID) {
            heldTerminals.remove(id)
            visibleTerminalIDs.remove(id)
        }
        func run(_ id: TerminalID, command: String) { ranTerminals.append((id, command)) }
        func writeInput(_ id: TerminalID, _ data: Data) { wrote.append((id, data)) }
        private(set) var wrote: [(id: TerminalID, data: Data)] = []
        func contains(_ id: TerminalID) -> Bool { heldTerminals.contains(id) }
        func show(_ attachments: [TerminalID: any TerminalPaneSurface]) {
            // The real host attaches nothing for a terminal it has never opened, which is what a
            // row restored from `state.json` looks like. The spy has to model that, or the
            // window's empty-state logic would be tested against a host that can show anything.
            visibleTerminalIDs = Set(attachments.keys.filter(heldTerminals.contains))
            shownTerminals.append(visibleTerminalIDs)
        }
        /// Every command handed to a shell this host spawned, as `TKZMUX_BOOT_COMMAND` in the
        /// spawn environment. Both `open` and `restore` are read: whether a resume goes through
        /// one or the other depends on whether the row had a snapshot, so a test that watched only
        /// `opened` would pass while the path the app actually takes was broken.
        var bootCommands: [String] {
            (opened.map(\.env) + restored.map(\.env)).compactMap { $0["TKZMUX_BOOT_COMMAND"] }
        }
        /// Every command this host was asked to run, by either route. A resume takes the boot
        /// command when it spawns the shell and the typed path when the row's shell was already
        /// up, so a mixed set of rows legitimately produces some of each.
        var commandsIssued: [String] { bootCommands + ran.map(\.command) }
        func resize(_ id: TerminalID, _ size: TerminalSize) { resized.append((id, size)) }
        private(set) var resized: [(id: TerminalID, size: TerminalSize)] = []
        func close(_ id: TerminalID, signal: Int32) {
            closed.append((SessionID(uuid: id.uuid), signal))
        }
        /// The live grid, for a held terminal; the real host throws `unknownSession` otherwise.
        func snapshot(_ id: TerminalID) throws -> Data {
            guard heldTerminals.contains(id) else {
                throw TerminalHostError.unknownSession(id.rawValue)
            }
            return Data("live:\(id.rawValue)".utf8)
        }
        func restore(
            _ id: TerminalID, session: SessionID, from data: Data, cwd: String,
            env: [String: String]
        ) throws -> pid_t {
            if let restoreError { throw restoreError }
            restored.append(
                Restored(id: session, terminal: id, cwd: cwd, env: env, snapshot: data))
            evict(id)
            heldTerminals.insert(id)
            return 4343
        }
        func savedSnapshot(_ id: TerminalID) -> Data? { savedSnapshots[SessionID(uuid: id.uuid)] }
        func discard(_ id: TerminalID) {
            discardedTerminals.append(id)
            heldTerminals.remove(id)
            savedSnapshots[SessionID(uuid: id.uuid)] = nil
            visibleTerminalIDs.remove(id)
        }

        /// Gives a *row* a terminal, the way the launcher does: its first leaf carries the row's
        /// own uuid. Almost every test here means "make this row have a shell", not "open this
        /// particular pane".
        @discardableResult
        func openRow(_ id: SessionID, cwd: String = "/tmp") throws -> pid_t {
            try open(
                TerminalID(uuid: id.uuid), session: id, cwd: cwd, env: [:],
                size: TerminalSize(rows: 24, cols: 80))
        }

        /// Pushes an event as if a child had produced it.
        func emit(_ event: TerminalEvent, for id: SessionID) {
            continuation.yield((TerminalID(uuid: id.uuid), event))
        }
        func emit(_ event: TerminalEvent, forTerminal id: TerminalID) {
            continuation.yield((id, event))
        }

        // MARK: Row-shaped views, for the assertions

        var shown: [SessionID?] {
            shownTerminals.map { $0.first.map { SessionID(uuid: $0.uuid) } }
        }
        var visibleSessionID: SessionID? { visibleTerminalIDs.first.map { SessionID(uuid: $0.uuid) } }
        var held: Set<SessionID> { Set(heldTerminals.map { SessionID(uuid: $0.uuid) }) }
        var discarded: [SessionID] { discardedTerminals.map { SessionID(uuid: $0.uuid) } }
        var ran: [(id: SessionID, command: String)] {
            ranTerminals.map { (SessionID(uuid: $0.id.uuid), $0.command) }
        }
        var lastShown: SessionID?? { shown.last }
        var closedIDs: [SessionID] { closed.map(\.id) }
    }

    /// Stands in for `TerminalMetalView`: focusable, and a `TerminalPaneSurface` that records
    /// what was attached to it. Everything the host asks of a surface is answered here, so the
    /// whole suite still runs with no GPU.
    final class FakeTerminalView: NSView, TerminalPaneSurface {
        override var acceptsFirstResponder: Bool { true }

        private(set) var attached: TerminalSession?
        private(set) var cursorSuppressed = false
        var onGridResize: ((TerminalSize) -> Void)?
        var grid = TerminalSize(rows: 40, cols: 120)

        func show(_ session: TerminalSession?) { attached = session }
        func setCursorSuppressed(_ suppressed: Bool) { cursorSuppressed = suppressed }
        func gridSizeForBounds() -> TerminalSize { grid }
    }

    // MARK: - Harness

    @MainActor
    struct Harness {
        let store: AppStore
        let controller: MainWindowController
        let host: SpyTerminalHost
        let terminalView: FakeTerminalView

        var window: NSWindow { controller.window }
        var sidebarItem: NSSplitViewItem { controller.splitViewController.splitViewItems[0] }

        /// Applies a store mutation and delivers its change set synchronously.
        func mutate(_ body: (inout AppState) -> Void) {
            store.update(body)
            store.flush()
            layout()
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func tearDown() {
            controller.shutdown()
            window.orderOut(nil)
        }
    }

    /// A harness whose panes each get their own `FakeTerminalView`, so a split has two real
    /// (GPU-free) surfaces rather than one view and a stand-in.
    static func makeSplitHarness(_ state: AppState = .fixture) -> Harness {
        _ = NSApplication.shared
        let store = AppStore(state: state)
        let host = SpyTerminalHost()
        let first = FakeTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let controller = MainWindowController(
            store: store, host: host, sharedView: first,
            terminalViewFactory: { _ in
                FakeTerminalView(frame: NSRect(x: 0, y: 0, width: 450, height: 700))
            },
            theme: .default)
        let harness = Harness(store: store, controller: controller, host: host, terminalView: first)
        harness.layout()
        return harness
    }

    static func makeHarness(_ state: AppState = .fixture) -> Harness {
        _ = NSApplication.shared
        let store = AppStore(state: state)
        let host = SpyTerminalHost()
        let view = FakeTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let controller = MainWindowController(
            store: store, host: host, terminalView: view, theme: .default)
        let harness = Harness(
            store: store, controller: controller, host: host, terminalView: view)
        harness.layout()
        return harness
    }

    // MARK: - Panes (TKZ-36)

    /// Polls a condition, flushing the store each turn, for up to two seconds.
    @MainActor
    private static func settle(
        _ harness: Harness, until predicate: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            harness.store.flush()
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        harness.store.flush()
        return predicate()
    }

    /// Gives a row a terminal and selects it, which is the precondition for every split test.
    @MainActor
    private static func selectedRowWithAShell(_ harness: Harness) throws -> (SessionID, TerminalID) {
        let id = try #require(harness.store.state.orderedSessions.first?.id)
        let terminal = try #require(harness.store.state.sessions[id]?.focusedTerminalID)
        _ = try harness.host.openRow(id)
        harness.mutate {
            // A row with a shell has live state; `setPanePid` below writes into it, and without it
            // that mutation is a no-op that delivers nothing.
            $0.setLive(LiveSessionState(shellPid: 1, status: .idle), for: id)
            $0.select(id)
        }
        return (id, terminal)
    }

    @Test("A split builds an NSSplitView with both panes, on the right axis")
    func splitBuildsASplitView() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (_, first) = try Self.selectedRowWithAShell(harness)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        harness.layout()
        let other = try #require(second)

        let container = harness.controller.paneContainer
        #expect(Set(container.terminalIDs) == [first, other])
        let firstView = try #require(container.paneView(for: first))
        let split = try #require(firstView.superview as? NSSplitView)
        #expect(split.isVertical, "a horizontal PaneAxis is side-by-side, i.e. a vertical divider")
        #expect(split.arrangedSubviews.count == 2)

        // ⇧⌘D stacks instead.
        var third: TerminalID?
        harness.store.updating { third = $0.splitPane(other, axis: .vertical) }
        harness.store.flush()
        harness.layout()
        let stacked = try #require(third)
        let stackedView = try #require(container.paneView(for: stacked))
        #expect((stackedView.superview as? NSSplitView)?.isVertical == false)
    }

    /// The anti-flash guard: splitting must not re-create the view of the pane that was already
    /// there. A new view means a detached and re-attached surface, i.e. a full rebuild of a grid
    /// the user did not touch.
    @Test("Splitting reuses the existing pane's view rather than rebuilding it")
    func splittingReusesTheExistingPaneView() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (_, first) = try Self.selectedRowWithAShell(harness)

        let before = try #require(harness.controller.paneContainer.paneView(for: first))
        harness.store.updating { _ = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        harness.layout()

        let after = try #require(harness.controller.paneContainer.paneView(for: first))
        #expect(before === after)
    }

    /// The regression this guards: `launchSize(for:)` used to measure the *first* pane's view for
    /// every terminal, so every ⌘D opened a full-width shell that reflowed on its first frame.
    ///
    /// Asserted through the projection rather than a laid-out view on purpose — that is the order
    /// `SessionLauncher.addTerminal` runs in. The store delivers change sets on the next turn of
    /// the run loop, so the tree has the new leaf and the container has not rebuilt yet.
    @Test("A split pane opens at its own grid, not the window's")
    func aSplitPaneOpensAtItsOwnGrid() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        // A test has no renderer, so it supplies the cell metrics the render context would.
        harness.controller.launchCellMetrics = { (width: 8, height: 16) }
        let (_, first) = try Self.selectedRowWithAShell(harness)

        let whole = try #require(harness.controller.projectedLaunchSize(for: first))
        #expect(whole.cols > 2 && whole.rows > 2, "the container must have real bounds")

        // The same arithmetic the projection does, on a height: points → pixels → whole cells.
        let scale = harness.window.backingScaleFactor
        let area = harness.controller.paneContainer.bounds
        func rows(_ points: CGFloat) -> Int { Int((points * scale).rounded(.down)) / 16 }
        #expect(Int(whole.rows) == rows(area.height))

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        let other = try #require(second)

        // A side-by-side split keeps the height, less the 28 pt header every split pane now wears.
        let sideBySide = try #require(harness.controller.projectedLaunchSize(for: other))
        #expect(Int(sideBySide.rows) == rows(area.height - PaneHeaderMetrics.height))
        #expect(abs(Int(sideBySide.cols) - Int(whole.cols) / 2) <= 1)
        #expect(sideBySide.cellWidthPx == 8 && sideBySide.cellHeightPx == 16)

        // ⇧⌘D halves the rows instead — the divider and its own header off its half — and only
        // within the pane it split.
        harness.store.flush()
        harness.layout()
        var third: TerminalID?
        harness.store.updating { third = $0.splitPane(other, axis: .vertical) }
        let stacked = try #require(third)
        let below = try #require(harness.controller.projectedLaunchSize(for: stacked))
        let half = (area.height - SplitMetrics.dividerThickness) / 2
        #expect(Int(below.rows) == rows(half - PaneHeaderMetrics.height))
        #expect(below.cols == sideBySide.cols)
    }

    @Test("Both panes of a split are attached, and closing one detaches only that one")
    func bothPanesAreAttached() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (_, first) = try Self.selectedRowWithAShell(harness)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        let other = try #require(second)
        // The launcher spawns a split pane's shell; the store-only mutation above did not, so
        // stand in for it before asserting on what is attached.
        _ = try harness.host.open(
            other, session: try #require(harness.store.state.sessionID(owning: other)),
            cwd: "/tmp", env: [:], size: TerminalSize(rows: 24, cols: 80))
        harness.mutate { $0.setPanePid(other, pid: 99) }   // what the launcher does after opening

        #expect(harness.host.visibleTerminalIDs == [first, other])

        harness.mutate { _ = $0.closePane(other) }
        #expect(harness.host.visibleTerminalIDs == [first])
        #expect(harness.controller.paneContainer.paneView(for: other) == nil)
    }

    /// A zoomed tab shows one pane; its siblings are detached and cost only IO.
    @Test("Zooming shows one pane and detaches the rest")
    func zoomShowsOnePane() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (id, first) = try Self.selectedRowWithAShell(harness)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        let other = try #require(second)
        _ = try harness.host.open(
            other, session: id, cwd: "/tmp", env: [:], size: TerminalSize(rows: 24, cols: 80))
        harness.mutate { $0.setPanePid(other, pid: 99) }
        #expect(harness.host.visibleTerminalIDs.count == 2)

        harness.mutate { $0.zoomPane(other, in: id) }
        #expect(harness.host.visibleTerminalIDs == [other])
        #expect(harness.controller.paneContainer.terminalIDs == [other])

        harness.mutate { $0.zoomPane(other, in: id) }
        #expect(harness.host.visibleTerminalIDs.count == 2)
    }

    /// The view→store half of focus: clicking a pane has to come back as `focusedTerminal`.
    /// This is the assertion `TerminalMetalViewTests` deliberately does not make.
    @Test("Making a pane first responder records it as the focused terminal")
    func clickingAPaneRecordsFocus() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (id, first) = try Self.selectedRowWithAShell(harness)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        let other = try #require(second)
        _ = try harness.host.open(
            other, session: id, cwd: "/tmp", env: [:], size: TerminalSize(rows: 24, cols: 80))
        harness.mutate { $0.focusPane(first) }
        #expect(harness.store.state.sessions[id]?.focusedTerminalID == first)

        let otherView = try #require(harness.controller.paneContainer.contentView(for: other))
        _ = harness.window.makeFirstResponder(otherView)
        harness.store.flush()
        harness.layout()
        #expect(harness.store.state.sessions[id]?.focusedTerminalID == other)
        // And the click must *keep* the keyboard: the delivery it caused used to rebuild the view
        // tree, and a view that leaves the window takes the first responder with it.
        #expect(harness.window.firstResponder === otherView)
    }

    /// The view factory used to treat `superview == nil` as "free", but the container unparents
    /// the old root before it builds the new tree — and for a one-pane tab that root *is* the
    /// shared view. So the new pane was handed the view the first pane already held: one `NSView`
    /// in both halves of the split, one input delegate for two shells, both sessions attached to
    /// one surface in turn. The single-view initialiser is the app's own shape of the problem.
    @Test("A split gives the new pane its own view")
    func aSplitPaneGetsItsOwnView() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let (_, first) = try Self.selectedRowWithAShell(harness)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        harness.layout()
        let other = try #require(second)

        let container = harness.controller.paneContainer
        let firstView = try #require(container.paneView(for: first))
        let otherView = try #require(container.paneView(for: other))
        // The split arranges each pane's *chrome*; the injected terminal sits inside the first.
        #expect(container.contentView(for: first) === harness.terminalView)
        #expect(firstView !== otherView)
        #expect(container.contentView(for: first) !== container.contentView(for: other))
        let split = try #require(firstView.superview as? NSSplitView)
        #expect(split.arrangedSubviews.count == 2)
        #expect(otherView.superview === split)
    }

    /// Focus and divider ratios are not shape. Rebuilding the tree for either detaches every
    /// surface and drops the first responder, so the container must leave the views where they are.
    @Test("A focus change or a divider drag does not rebuild the view tree")
    func focusChangeDoesNotRebuildTheTree() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (id, first) = try Self.selectedRowWithAShell(harness)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        harness.layout()
        _ = try #require(second)

        let container = harness.controller.paneContainer
        let firstView = try #require(container.paneView(for: first))
        let split = try #require(firstView.superview)

        harness.mutate { $0.focusPane(first) }
        #expect(harness.store.state.sessions[id]?.focusedTerminalID == first)
        #expect(container.paneView(for: first) === firstView)
        #expect(firstView.superview === split)

        harness.mutate { $0.setRatio(above: first, levels: 0, to: 0.3) }
        #expect(firstView.superview === split)
    }

    /// ⌘D focuses the new pane, but the pane's view does not exist until the store delivers on the
    /// next turn — so the command's own `focusPane` finds nothing, and the rebuild that follows
    /// leaves the keyboard with the window. The delivery has to finish the job.
    @Test("Splitting moves the keyboard to the new pane")
    func splittingMovesTheKeyboardToTheNewPane() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (_, first) = try Self.selectedRowWithAShell(harness)
        harness.controller.focusPane(first)
        #expect(
            harness.window.firstResponder === harness.controller.paneContainer.contentView(for: first))

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        harness.layout()
        let other = try #require(second)

        let otherView = try #require(harness.controller.paneContainer.contentView(for: other))
        #expect(harness.window.firstResponder === otherView)
    }

    /// A store-driven focus change must move the keyboard too — the `layout` branch passes
    /// `focusTerminal: false` so a click is not fought, which means a *command* has to say so.
    @Test("focusPane moves the first responder")
    func focusPaneMovesTheKeyboard() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (id, first) = try Self.selectedRowWithAShell(harness)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        let other = try #require(second)
        _ = try harness.host.open(
            other, session: id, cwd: "/tmp", env: [:], size: TerminalSize(rows: 24, cols: 80))
        harness.mutate { $0.focusPane(first) }

        harness.controller.focusPane(other)
        let otherView = try #require(harness.controller.paneContainer.contentView(for: other))
        #expect(harness.window.firstResponder === otherView)
    }

    /// A pane whose shell exits closes that leaf; the row survives on the rest.
    @Test("An exiting pane closes its leaf, and only the last one takes the row with it")
    func exitClosesOneLeaf() async throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (id, first) = try Self.selectedRowWithAShell(harness)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        let other = try #require(second)
        _ = try harness.host.open(
            other, session: id, cwd: "/tmp", env: [:], size: TerminalSize(rows: 24, cols: 80))
        harness.layout()

        // The event pump is a Task; wait for the effect rather than for a fixed interval, or the
        // test is a race that usually wins.
        harness.host.emit(.exited(.exited(code: 0)), forTerminal: other)
        var closed = await Self.settle(harness) {
            harness.store.state.sessions[id]?.terminalIDs == [first]
        }
        #expect(closed, "the exiting pane's leaf was not closed")
        #expect(harness.store.state.sessions[id] != nil, "the row must survive its second pane")

        harness.host.emit(.exited(.exited(code: 0)), forTerminal: first)
        closed = await Self.settle(harness) { harness.store.state.sessions[id] == nil }
        #expect(closed, "the last pane must take the row with it")
    }

    /// Store→view: the dividers follow the model's ratios, and an unrelated delivery does not
    /// re-place one the user has since dragged. That is the snap-back bug `MainSplitViewController`
    /// documents, in its pane-shaped form.
    @Test("Ratios are applied once, and an unrelated change does not re-place a divider")
    func ratiosAreAppliedOnce() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (id, first) = try Self.selectedRowWithAShell(harness)

        harness.store.updating { _ = $0.splitPane(first, axis: .horizontal, ratio: 0.25) }
        harness.store.flush()
        harness.layout()
        let placed = harness.controller.paneContainer.appliedRatioCount
        #expect(placed > 0)

        // Something else about the row changes: a status flip, not a layout change.
        harness.mutate { $0.setStatus(.working, for: id) }
        #expect(harness.controller.paneContainer.appliedRatioCount == placed)

        // A real ratio change does place it again.
        harness.mutate { $0.setRatio(above: first, to: 0.6) }
        #expect(harness.controller.paneContainer.appliedRatioCount > placed)
    }

    // MARK: - Pane chrome (design 2c.3 / 2c.4)

    /// A lone pane is 2c.1: no header, no ring. Splitting puts a header on both panes and the
    /// ring on the one with the keyboard.
    @Test("Headers appear on a split, and only the focused pane is ringed")
    func headersAppearOnASplitAndTheFocusedPaneIsRinged() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (id, first) = try Self.selectedRowWithAShell(harness)
        let container = harness.controller.paneContainer

        let lone = try #require(container.chrome(for: first))
        #expect(!lone.isHeaderVisible)
        #expect(lone.header.isHidden)
        #expect(lone.content.frame.height == lone.frame.height, "a lone pane loses no height")
        #expect(lone.ringWidth == 0, "2c.1: a lone pane is not ringed")
        #expect(lone.content.alphaValue == 1)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        harness.layout()
        let other = try #require(second)

        let a = try #require(container.chrome(for: first))
        let b = try #require(container.chrome(for: other))
        #expect(a === lone, "the existing pane keeps its chrome")
        #expect(a.isHeaderVisible && b.isHeaderVisible)
        #expect(a.header.frame.height == PaneHeaderMetrics.height)
        #expect(a.content.frame.minY == PaneHeaderMetrics.height)
        #expect(harness.store.state.sessions[id]?.focusedTerminalID == other)
        #expect(b.isFocused && !a.isFocused)
        #expect(b.ringWidth == PaneHeaderMetrics.focusRingWidth)
        #expect(a.ringWidth == 0)
        #expect(a.content.alphaValue < 1 && b.content.alphaValue == 1)

        // The split view between them is the 7 pt grip bar.
        let split = try #require(a.superview as? NSSplitView)
        #expect(split.dividerThickness == SplitMetrics.dividerThickness)

        // Focus moves the ring without rebuilding anything.
        harness.mutate { $0.focusPane(first) }
        #expect(container.chrome(for: first) === a)
        #expect(a.isFocused && !b.isFocused)
        #expect(a.ringWidth == PaneHeaderMetrics.focusRingWidth && b.ringWidth == 0)

        // Zoom shows one pane again, and a lone pane has neither header nor ring.
        harness.mutate { $0.zoomPane(first, in: id) }
        #expect(!(container.chrome(for: first)?.isHeaderVisible ?? true))
        #expect(container.chrome(for: first)?.ringWidth == 0)
    }

    /// Each header names its own pane's directory. A `cd` in the background pane retitles that
    /// header alone — and it rides the `sessions` bucket, so the tree is not rebuilt for it.
    @Test("A pane's header follows that pane's cwd, not the row's")
    func aHeaderFollowsItsOwnPanesCwd() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (_, first) = try Self.selectedRowWithAShell(harness)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .vertical) }
        harness.store.flush()
        harness.layout()
        let other = try #require(second)
        let container = harness.controller.paneContainer
        let a = try #require(container.chrome(for: first))
        let b = try #require(container.chrome(for: other))
        let split = try #require(a.superview)

        harness.mutate { $0.focusPane(other) }
        harness.mutate { $0.setPaneCwd(first, path: "/tmp/elsewhere/toolbox") }
        #expect(a.header.model.title == "toolbox")
        #expect(a.header.model.path == "/tmp/elsewhere/toolbox")
        #expect(b.header.model.title != "toolbox")
        #expect(a.superview === split, "a cwd change must not rebuild the tree")
        #expect(container.chrome(for: first) === a)

        // The strip's git target followed the *focused* pane, which is still `other`.
        harness.mutate { $0.setPaneCwd(other, path: "/tmp/other-repo") }
        #expect(GitIntegration.trackingTargets(in: harness.store.state).values.contains("/tmp/other-repo"))
        #expect(!GitIntegration.trackingTargets(in: harness.store.state).values.contains("/tmp/elsewhere/toolbox"))
    }

    /// A click on a header is a click into its pane.
    @Test("Clicking a pane header focuses that pane")
    func clickingAHeaderFocusesThePane() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (id, first) = try Self.selectedRowWithAShell(harness)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        harness.layout()
        let other = try #require(second)
        _ = try harness.host.open(
            other, session: id, cwd: "/tmp", env: [:], size: TerminalSize(rows: 24, cols: 80))
        harness.mutate { $0.focusPane(other) }

        let a = try #require(harness.controller.paneContainer.chrome(for: first))
        a.header.mouseDown(with: NSEvent())
        harness.store.flush()
        harness.layout()
        #expect(harness.store.state.sessions[id]?.focusedTerminalID == first)
        #expect(harness.window.firstResponder === a.content)
        #expect(a.isFocused)
    }

    /// The header's `×` closes that pane — any pane, not only the focused one — and the keyboard
    /// lands on the survivor. It never reaches the row: a header exists only alongside another pane.
    @Test("The header's × closes its pane and the survivor takes the keyboard")
    func theHeaderCloseButtonClosesItsPane() throws {
        let harness = Self.makeSplitHarness()
        defer { harness.tearDown() }
        let (id, first) = try Self.selectedRowWithAShell(harness)

        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        harness.layout()
        let other = try #require(second)
        _ = try harness.host.open(
            other, session: id, cwd: "/tmp", env: [:], size: TerminalSize(rows: 24, cols: 80))
        harness.mutate { $0.setPanePid(other, pid: 99) }
        harness.mutate { $0.focusPane(other) }

        let a = try #require(harness.controller.paneContainer.chrome(for: first))
        harness.controller.closeTerminal(first)   // what `a.header.onClose` calls
        harness.store.flush()
        harness.layout()
        #expect(harness.store.state.sessions[id]?.terminalCount == 1)
        #expect(harness.store.state.sessions[id]?.focusedTerminalID == other)
        #expect(harness.controller.paneContainer.chrome(for: first) == nil)
        #expect(a.superview == nil)
        let survivor = try #require(harness.controller.paneContainer.chrome(for: other))
        #expect(!survivor.isHeaderVisible, "back to one pane: no header")
        #expect(harness.window.firstResponder === survivor.content)

        // The row's last terminal is not this path's to close.
        harness.controller.closeTerminal(other)
        harness.store.flush()
        #expect(harness.store.state.sessions[id] != nil)
    }

    // MARK: - Structure

    @Test("The window is a split view: sidebar 300 pt, min 240, collapsible")
    func splitGeometry() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        #expect(harness.controller.splitViewController.splitViewItems.count == 2)
        let sidebar = harness.sidebarItem
        #expect(sidebar.canCollapse)
        #expect(sidebar.minimumThickness == 240)
        #expect(sidebar.viewController === harness.controller.sidebar)
        // The real, laid-out **divider position** — not the constant it was asked for. With a
        // plain split item the sidebar view *is* the column, so the two agree at 300; the old
        // `sidebarWithViewController:` flavour put a glass container with an 8 pt inset between
        // them, which is exactly the rounded, inset sidebar artboard 2c does not draw.
        #expect(abs(harness.controller.sidebarWidthForRestore - 300) < 1)
        #expect(abs(sidebar.viewController.view.frame.width - 300) < 1)
        // AppKit still puts a plain `_NSSplitViewItemViewWrapper` between them; what must be gone
        // is the visual-effect container.
        var ancestor = sidebar.viewController.view.superview
        while let view = ancestor, view !== harness.controller.splitViewController.splitView {
            #expect(!(view is NSVisualEffectView), "no glass container between the split view and the sidebar")
            ancestor = view.superview
        }
        #expect(harness.controller.splitViewController.splitViewItems[1].canCollapse == false)
    }

    @Test("The terminal starts below the titlebar, not underneath it")
    func terminalRespectsTheSafeArea() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        harness.layout()
        let detail = harness.controller.detail

        // The window is `.fullSizeContentView` with a transparent titlebar and a unified toolbar,
        // so its content view really does extend up behind them — that is what the safe area
        // reports. Pinned to `topAnchor` instead, the first rows of the grid render *underneath*
        // the toolbar, with the ＋ menu and the search field sitting on top of them.
        let inset = detail.view.safeAreaInsets.top
        #expect(inset > 0, "this window is supposed to have a titlebar to sit below")
        #expect(abs(detail.terminalContainer.frame.maxY - (detail.view.bounds.height - inset)) < 1)
        // The empty state rides inside the container, so it is inset by construction.
        #expect(detail.emptyState.frame.height == detail.terminalContainer.frame.height)
        // The sidebar's column stops there too: the summary strip is its top-most piece (since
        // 2026-09-08) and the list starts under the strip.
        let sidebar = harness.controller.sidebar
        #expect(abs(sidebar.summaryStrip.frame.maxY - (sidebar.view.bounds.height - inset)) < 1)
        #expect(abs(sidebar.scrollView.frame.maxY - sidebar.summaryStrip.frame.minY) < 1)
        // And the header backdrop is exactly that strip, above both columns.
        let backdrop = harness.controller.chrome.headerBackdrop
        #expect(abs(backdrop.frame.height - inset) < 1)
        #expect(abs(backdrop.frame.width - (harness.window.contentView?.frame.width ?? 0)) < 1)
        #expect(backdrop.superview === harness.window.contentView)
        let chromeSubviews = harness.window.contentView?.subviews ?? []
        #expect(
            (chromeSubviews.firstIndex(of: backdrop) ?? -1)
                > (chromeSubviews.firstIndex(of: harness.controller.splitViewController.view) ?? -1),
            "the backdrop is above the split view")
        // Only the ⌘-hold cheat sheet is above the backdrop, and it is hidden until ⌘ is held.
        #expect(chromeSubviews.last === harness.controller.cheatSheet.view)
        #expect(backdrop.effectView.blendingMode == .behindWindow)
        #expect(backdrop.effectView.material == HeaderBackdropView.material)
        #expect(backdrop.borderView.frame.height == 1)
        #expect(backdrop.mouseDownCanMoveWindow)
    }

    @Test("The status bar is pinned along the bottom at exactly 30 pt")
    func statusBarHeight() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        let bar = harness.controller.statusBar
        #expect(bar.frame.height == 30)
        #expect(StatusBarView.height == 30)
        // Bottom of the detail half, full width.
        let detail = harness.controller.detail.view
        #expect(bar.superview === detail)
        #expect(abs(bar.frame.minY - 0) < 0.5)
        #expect(abs(bar.frame.width - detail.frame.width) < 0.5)
        // And the terminal sits directly on top of it.
        #expect(abs(harness.controller.detail.terminalContainer.frame.minY - bar.frame.maxY) < 0.5)
    }

    @Test("The window wears the unified toolbar with no title")
    func toolbarAttached() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        #expect(harness.window.toolbar === harness.controller.toolbarController.toolbar)
        #expect(harness.window.toolbarStyle == .unified)
        #expect(harness.window.titleVisibility == .hidden)
        // Transparent titlebar over full-size content: the glass behind the toolbar items is
        // `ChromeViewController`'s own backdrop (see `terminalRespectsTheSafeArea`), which also
        // draws the design's 1 pt border, so AppKit's separator stays off.
        #expect(harness.window.titlebarAppearsTransparent)
        #expect(harness.window.styleMask.contains(.fullSizeContentView))
        #expect(harness.window.titlebarSeparatorStyle == .none)
        #expect(harness.window.contentViewController === harness.controller.chrome)
        // A dark preset must put the window in `.darkAqua`, or the vibrancy and the toolbar come
        // up light over dark content.
        #expect(harness.window.appearance?.name == .darkAqua)
    }

    @Test("The toolbar title follows the selection")
    func toolbarTitle() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        let session = harness.store.state.selectedSession
        let group = session.flatMap { harness.store.state.groups[$0.groupID] }
        #expect(harness.controller.toolbarController.plainTitle
            == "\(session?.displayTitle ?? "") \u{2014} \(group?.name ?? "")")

        harness.mutate { $0.select(nil) }
        #expect(harness.controller.toolbarController.plainTitle == "No session")
    }

    @Test("The sidebar is a flat themed column, not a glass wrapper")
    func sidebarAppearance() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        // Artboard 2c draws the sidebar as a flat column on `sidebarBackground` with a 1 pt border
        // against the terminal. A `sidebarWithViewController:` item on macOS 26 wrapped it in an
        // `NSContainerConcentricGlassEffectView` — rounded corners, an 8 pt inset and a vibrancy
        // backdrop (reported 2026-09-08). With a plain item the view inherits the window's dark
        // appearance directly and paints its own themed background.
        let container = harness.controller.sidebar.view
        #expect(container.effectiveAppearance.name == .darkAqua)
        #expect(!(container.superview is NSVisualEffectView))
        let background = try #require(container.layer?.backgroundColor)
        let expected = Theme.default.sidebarBackground
        let components = try #require(background.components)
        #expect(abs(components[0] - expected.r) < 0.01)
        #expect(abs(components[1] - expected.g) < 0.01)
        #expect(abs(components[2] - expected.b) < 0.01)
    }

    // MARK: - Sidebar collapse (⌘B)

    @Test("Toggling the sidebar collapses it and round-trips through the store")
    func toggleSidebar() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        #expect(harness.store.state.sidebarVisible)
        #expect(harness.sidebarItem.isCollapsed == false)

        harness.controller.toggleSidebar()
        harness.store.flush()
        harness.layout()
        #expect(harness.store.state.sidebarVisible == false)
        #expect(harness.sidebarItem.isCollapsed)

        harness.controller.toggleSidebar()
        harness.store.flush()
        harness.layout()
        #expect(harness.store.state.sidebarVisible)
        #expect(harness.sidebarItem.isCollapsed == false)
        #expect(abs(harness.controller.sidebarWidthForRestore - 300) < 1)
    }

    @Test("A store-driven visibility change reaches the split item")
    func storeDrivesCollapse() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.mutate { $0.setSidebarVisible(false) }
        #expect(harness.sidebarItem.isCollapsed)
        harness.mutate { $0.setSidebarVisible(true) }
        #expect(harness.sidebarItem.isCollapsed == false)
    }

    @Test("A divider drag that collapses the sidebar is reported back to the store")
    func dragCollapseReachesStore() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        // Collapse the item directly, as a drag would, and let the split view report.
        harness.sidebarItem.isCollapsed = true
        harness.controller.splitViewController.splitViewDidResizeSubviews(
            Notification(name: NSSplitView.didResizeSubviewsNotification,
                         object: harness.controller.splitViewController.splitView))
        harness.store.flush()
        #expect(harness.store.state.sidebarVisible == false)
    }

    // MARK: - Selection drives the terminal

    @Test("Selecting a session shows it and gives the terminal the keyboard")
    func selectionShowsAndFocuses() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        let target = try #require(harness.store.state.orderedSessions.last?.id)
        // The row has to have a terminal behind it: from M5.1 a row can exist in the store with no
        // surface (that is what a restored `state.json` row is), and the window shows the empty
        // state for those rather than focusing a grid that is not there.
        _ = try harness.host.openRow(target)
        harness.mutate { $0.select(target) }

        #expect(harness.host.lastShown == .some(target))
        #expect(harness.window.firstResponder === harness.terminalView)
        #expect(harness.controller.paneContainer.isHidden == false)
    }

    @Test("Sidebar selection is the same path: it goes through the store to show()")
    func sidebarSelectionShows() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        // Start from nothing selected, so the ⌘1 below is a real change and not a no-op.
        harness.mutate { $0.select(nil) }
        let expected = try #require(SidebarRowAdapter.session(atVisibleIndex: 1, in: harness.store.state))
        _ = try harness.host.openRow(expected)

        // ⌘1 — the sidebar's own command, exactly what the menu dispatches.
        harness.controller.dispatcher.perform(.selectSession(1))
        harness.store.flush()
        harness.layout()

        #expect(harness.store.state.selection == expected)
        #expect(harness.host.lastShown == .some(expected))
        #expect(harness.window.firstResponder === harness.terminalView)
    }

    @Test("The empty state follows the host's surface, not the selection")
    func emptyState() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        // Every fixture row is selectable but has never been opened on the host — exactly the shape
        // of a row restored from `state.json` (M5.1). The detail half must say so rather than show
        // a blank grid.
        #expect(harness.controller.detail.emptyState.isHidden == false)
        #expect(harness.controller.paneContainer.isHidden)
        #expect(harness.controller.detail.emptyStateMessage == EmptyStateView.notRunningMessage)

        harness.mutate { $0.select(nil) }
        #expect(harness.controller.detail.emptyState.isHidden == false)
        #expect(harness.controller.paneContainer.isHidden)
        #expect(harness.host.lastShown == .some(nil))
        #expect(harness.controller.detail.emptyStateMessage == EmptyStateView.noSelectionMessage)
        #expect(EmptyStateView.noSelectionMessage == "No session selected \u{00B7} \u{2318}N")

        // A row the host has actually opened shows the terminal.
        let target = try #require(harness.store.state.orderedSessions.first?.id)
        _ = try harness.host.openRow(target)
        harness.mutate { $0.select(target) }
        #expect(harness.controller.detail.emptyState.isHidden)
        #expect(harness.controller.paneContainer.isHidden == false)
    }

    // MARK: - Status bar contents

    @Test("The status bar is derived from the selected session")
    func statusModel() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        let session = try #require(harness.store.state.selectedSession)
        let model = harness.controller.statusBar.model
        #expect(model.branch == session.live?.git?.branch)
        #expect(model.diffAdded == session.live?.git?.insertions)
        #expect(model.diffFiles == session.live?.git?.changedFiles)

        harness.mutate { $0.select(nil) }
        #expect(harness.controller.statusBar.model == .empty)
    }

    @Test("A git refresh on the selected session re-renders the strip")
    func statusFollowsSessionChange() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        let id = try #require(harness.store.state.selection)
        harness.mutate { state in
            state.updateLive(id) { $0.git = GitSummary(branch: "tkz-18", insertions: 5, deletions: 1) }
        }
        #expect(harness.controller.statusBar.model.branch == "tkz-18")
        #expect(harness.controller.statusBar.model.diffAdded == 5)
    }

    // MARK: - New group

    @Test("A chosen folder becomes a group named after it, rooted there, exactly once")
    func createGroupFromFolder() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let before = harness.store.state.groups.count

        let folder = URL(fileURLWithPath: "/tmp/tkzmux-tests/Some Repo", isDirectory: true)
        let id = try #require(harness.controller.createGroup(from: folder))
        let group = try #require(harness.store.state.groups[id])
        #expect(group.name == "Some Repo")
        #expect(group.repoRoot == "/tmp/tkzmux-tests/Some Repo")
        #expect(harness.store.state.groups.count == before + 1)

        // The same folder again is the same group, not a duplicate.
        #expect(harness.controller.createGroup(from: folder) == id)
        #expect(harness.store.state.groups.count == before + 1)
    }

    @Test("A name makes a bucket group; an empty one makes nothing")
    func createGroupFromName() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let before = harness.store.state.groups.count

        let id = try #require(harness.controller.createGroup(named: "  Work  "))
        let group = try #require(harness.store.state.groups[id])
        #expect(group.name == "Work")
        #expect(group.repoRoot == nil, "a group made by name is a bucket")
        #expect(harness.store.state.groups.count == before + 1)

        #expect(harness.controller.createGroup(named: "   ") == nil)
        #expect(harness.store.state.groups.count == before + 1)

        // Names are not deduped — unlike repoRoot, a name is not an identity.
        #expect(harness.controller.createGroup(named: "Work") != id)
        #expect(harness.store.state.groups.count == before + 2)
    }

    @Test("＋ New group asks for a name; cancelling creates nothing")
    func newGroupPromptsForAName() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let before = harness.store.state.groups.count

        harness.controller.groupNamePrompt = { "Scratch" }
        harness.controller.presentNewGroupPanel()
        #expect(harness.store.state.groups.count == before + 1)
        let group = try #require(harness.store.state.orderedGroups.last)
        #expect(group.name == "Scratch")
        #expect(group.repoRoot == nil)

        harness.controller.groupNamePrompt = { nil }
        harness.controller.presentNewGroupPanel()
        #expect(harness.store.state.groups.count == before + 1, "cancel creates nothing")

        harness.controller.groupNamePrompt = { "" }
        harness.controller.presentNewGroupPanel()
        #expect(harness.store.state.groups.count == before + 1, "an empty name creates nothing")
    }

    @Test("The sidebar's ＋ New group footer reaches the window controller")
    func newGroupFooterIsWired() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        #expect(harness.controller.sidebar.onNewGroup != nil)
        #expect(harness.controller.sidebar.newGroupFooter.onNewGroup != nil)
    }

    // MARK: - Chrome persistence

    @Test("A stored frame places the window at launch")
    func frameAppliedAtLaunch() {
        var state = AppState.fixture
        state.windowFrame = NSRect(x: 60, y: 40, width: 1000, height: 700)
        let harness = Self.makeHarness(state)
        defer { harness.tearDown() }

        #expect(harness.window.frame.size == NSSize(width: 1000, height: 700))
    }

    @Test("A stored sidebar width is applied at launch and reading it back is a fixed point")
    func sidebarWidthRestored() {
        var state = AppState.fixture
        state.sidebarWidth = 380
        let harness = Self.makeHarness(state)
        defer { harness.tearDown() }

        #expect(harness.controller.restoredSidebarWidth == 380)
        #expect(harness.controller.sidebarWidthForRestore == 380)

        // The loop that must not oscillate: the store places the divider, layout is read back, and
        // the store places it again on the next launch. Reading the settled width must therefore
        // change nothing at all — any discrepancy moves the sidebar a little on every launch until
        // it hits a limit, which is what recording the 8 pt-narrower inner view did.
        harness.controller.recordSidebarWidth()
        harness.store.flush()
        #expect(harness.store.state.sidebarWidth == 380)
        #expect(harness.controller.sidebarWidthForRestore == 380)

        // A store-driven change (what a restore from `state.json` is) reaches the split view.
        harness.mutate { $0.sidebarWidth = 420 }
        #expect(harness.controller.sidebarWidthForRestore == 420)
    }

    @Test("An unrelated store change never re-places the sidebar divider")
    func unrelatedChromeChangeLeavesTheDividerAlone() {
        // The reported bug: drag the sidebar wider, release, and it snaps back. Both
        // `applySidebarVisible` and `applySidebarWidth` used to re-issue `setPosition` on *every*
        // `chrome` delivery, so any unrelated mutation — a preset edit, a window move — threw away
        // the width the user had just dragged to.
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let before = harness.controller.splitViewController.appliedWidthCount

        harness.mutate { $0.windowFrame = NSRect(x: 30, y: 40, width: 1100, height: 720) }
        harness.mutate { _ = $0.addPreset(Preset(name: "p", command: "claude")) }
        harness.mutate { $0.shortcuts["x"] = "cmd+x" }

        #expect(harness.controller.splitViewController.appliedWidthCount == before)
    }

    @Test("A width that came from the store is applied exactly once")
    func storeDrivenWidthIsAppliedOnce() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let before = harness.controller.splitViewController.appliedWidthCount

        harness.mutate { $0.sidebarWidth = 420 }
        #expect(harness.controller.sidebarWidthForRestore == 420)
        #expect(harness.controller.splitViewController.appliedWidthCount == before + 1)

        // Re-delivering the same value must not touch the divider again.
        harness.mutate { $0.shortcuts["y"] = "cmd+y" }
        #expect(harness.controller.splitViewController.appliedWidthCount == before + 1)
    }

    @Test("A nonsense stored width degrades to the design default")
    func sidebarWidthGarbage() {
        var state = AppState.fixture
        state.sidebarWidth = 4
        let harness = Self.makeHarness(state)
        defer { harness.tearDown() }
        #expect(harness.controller.restoredSidebarWidth == MainWindowController.sidebarWidth)
        #expect(harness.controller.sidebarWidthForRestore == MainWindowController.sidebarWidth)
    }

    @Test("A dragged width survives layout — the seeding constraint must not re-assert itself")
    func draggedWidthSurvivesLayout() {
        // The reported bug, as close as a headless test gets to a mouse: place the divider the way
        // a drag does and lay out again. With the width constraint still active this read 300 no
        // matter what was asked for, which on screen is "drag it, let go, it snaps back".
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.controller.splitViewController.splitView.setPosition(380, ofDividerAt: 0)
        harness.layout()
        #expect(harness.controller.sidebarWidthForRestore == 380)
        harness.layout()
        #expect(harness.controller.sidebarWidthForRestore == 380)

        // …and the settled value is what gets recorded, so the next launch comes back to it.
        harness.controller.recordSidebarWidth()
        harness.store.flush()
        #expect(harness.store.state.sidebarWidth == 380)
    }

    @Test("A notice takes over the status strip and then gives it back")
    func statusNotice() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.controller.showNotice("Restored sidebar from backup", for: .seconds(60))
        #expect(harness.controller.statusBar.model.notice == "Restored sidebar from backup")
        #expect(harness.controller.statusBar.currentSegments.count == 1)
        #expect(harness.controller.statusBar.currentSegments.first?.plainText
            == "Restored sidebar from backup")
    }

    // MARK: - Rendering

    @Test("The assembled window rasterises offscreen")
    func rendersOffscreen() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        harness.layout()

        let root = try #require(harness.window.contentView)
        root.wantsLayer = true
        let bounds = root.bounds
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let ctx = graphics.cgContext
        ctx.scaleBy(x: scale, y: scale)
        try #require(root.layer).render(in: ctx)

        // What the picture shows: the status strip, the window/terminal grounds, and — since the
        // sidebar became a plain split item — the sidebar column itself, rows, summary strip and
        // the ＋ New group footer included. (The old `sidebarWithViewController:` flavour wrapped
        // it in an `NSVisualEffectView`, which has no offscreen content and painted a flat
        // fallback.) The titlebar and its material are not part of the content view, so they are
        // never in this picture; the user is the verifier for those.

        let data = try #require(rep.bitmapData)
        var distinct = Set<UInt32>()
        let pixels = rep.pixelsWide * rep.pixelsHigh
        for index in stride(from: 0, to: pixels * 4, by: 4 * 37) {
            let value = UInt32(data[index]) << 16 | UInt32(data[index + 1]) << 8 | UInt32(data[index + 2])
            distinct.insert(value)
        }
        #expect(distinct.count > 4)

        if let png = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tkzmux-mainwindow-\(UUID().uuidString).png")
            try? png.write(to: url)
            print("main window render: \(url.path)")
        }
    }

    @Test("The diagnostics line names the frame, the sidebar and the selection")
    func diagnostics() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let line = harness.controller.diagnosticsLine()
        #expect(line.hasPrefix("main window: frame="))
        #expect(line.contains("sidebar=visible"))
        #expect(line.contains("sessions=\(harness.store.state.sessions.count)"))
    }

}
