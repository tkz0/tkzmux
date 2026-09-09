// SidebarViewControllerTests — M2.3 (TKZ-19), the binding half.
//
// `SidebarRowViewTests` proves the rows *draw* correctly from a literal model. This suite proves the
// controller *drives* them from the store, and it exists almost entirely for one sentence in
// docs/design.md → *Store*: a Claude status flip on one session must cost one
// `reloadData(forRowIndexes:)`, not forty row re-renders.
//
// That claim cannot be checked by looking at the screen, so `SidebarOutlineView` counts every
// `reloadData` / `reloadData(forRowIndexes:)` / `insertItems` / `removeItems` / `moveItem` call, and
// the tests assert the counters. `resetCounters()` after the initial load makes "exactly one row,
// zero full reloads" a literal assertion rather than a hopeful one.
//
// Headless: the controller's view is put in an offscreen borderless `NSWindow` that is never ordered
// front. `numberOfRows`/`rectOfRow` need no window at all; a window is what makes `NSTableView`
// actually build its row views, which the row-content assertions need.
//
// AppKit is `@MainActor`, and these tests share the process-wide font registry and the store's
// main-queue delivery source, so the suite is serialised.

import AppKit
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct SidebarViewControllerTests {

    // MARK: - Harness

    /// Controller + store + an offscreen window, wired the way wave 3 will wire them.
    @MainActor
    struct Harness {
        let store: AppStore
        let controller: SidebarViewController
        let window: NSWindow

        var outline: SidebarOutlineView {
            // swiftlint:disable:next force_cast — the controller owns the concrete subclass.
            controller.outlineView as! SidebarOutlineView
        }

        /// Applies a store mutation and delivers its change set synchronously.
        func mutate(_ body: (inout AppState) -> Void) {
            store.update(body)
            store.flush()
            window.layoutIfNeeded()
        }
    }

    static func makeHarness(_ state: AppState = .fixture) -> Harness {
        _ = NSApplication.shared
        let store = AppStore(state: state)
        let controller = SidebarViewController(store: store, theme: .default)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SidebarMetrics.sidebarWidth, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.frame = window.contentLayoutRect
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return Harness(store: store, controller: controller, window: window)
    }

    static func sessionRow(_ harness: Harness, at row: Int) -> SessionRowView? {
        harness.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionRowView
    }

    // MARK: - Population

    @Test("The fixture populates the outline: 5 group rows + 35 session rows, Playground's 5 absent")
    func fixturePopulatesTheOutline() throws {
        let harness = Self.makeHarness()
        let state = harness.store.state

        #expect(state.sessions.count == 40)
        #expect(state.groups.count == 5)
        // Playground (group 4) is collapsed in the fixture, so its 5 sessions are not rows.
        #expect(harness.outline.numberOfRows == 5 + 35)

        let playground = try #require(state.orderedGroups.last)
        #expect(playground.isCollapsed)
        for session in state.sessions(in: playground.id) {
            #expect(harness.controller.row(forSession: session.id) == -1)
        }
        // …but the data source still reports them: collapse must not be structural.
        #expect(
            harness.controller.outlineView(harness.outline, numberOfChildrenOfItem: harness.controller.item(.group(playground.id))) == 5)

        // Every non-collapsed group's sessions are rows, in sidebar order.
        let visible = SidebarRowAdapter.visibleSessions(in: state)
        #expect(visible.count == 35)
        let rows = visible.map { harness.controller.row(forSession: $0.id) }
        #expect(rows.allSatisfy { $0 >= 0 })
        #expect(rows == rows.sorted())
    }

    @Test("Row heights come from SidebarMetrics, per item type")
    func rowHeightsAreFixedPerItemType() throws {
        let harness = Self.makeHarness()
        var groupRows = 0
        var sessionRows = 0
        for row in 0..<harness.outline.numberOfRows {
            let item = try #require(harness.outline.item(atRow: row) as? SidebarItem)
            let height = harness.outline.rect(ofRow: row).height
            if item.groupID != nil {
                #expect(height == CGFloat(SidebarMetrics.groupRowHeight))
                groupRows += 1
            } else {
                #expect(height == CGFloat(SidebarMetrics.sessionRowHeight))
                sessionRows += 1
            }
        }
        #expect(groupRows == 5)
        #expect(sessionRows == 35)
        // Fixed heights, no intercell spacing: the content is exactly the sum.
        #expect(harness.outline.frame.height == CGFloat(5 * 28 + 35 * 44))
    }

    @Test("The outline draws no system selection — the rows paint Theme.selection themselves")
    func selectionHighlightIsOff() {
        let harness = Self.makeHarness()
        #expect(harness.outline.selectionHighlightStyle == .none)
        #expect(harness.outline.usesAutomaticRowHeights == false)
        #expect(harness.outline.headerView == nil)
        #expect(harness.outline.indentationPerLevel == 0)
    }

    // MARK: - The criterion the design rests on

    @Test("A single session's status flip reloads exactly that row, and nothing else")
    func statusFlipReloadsExactlyOneRow() throws {
        let harness = Self.makeHarness()
        harness.outline.resetCounters()

        // Deliberately not the selected session: selection reloads two rows by design, and that
        // would hide a regression here.
        let target = Fixture.sessionID(3)
        #expect(harness.store.state.selection != target)
        let row = harness.controller.row(forSession: target)
        #expect(row >= 0)

        harness.mutate { $0.setStatus(.working, for: target) }

        #expect(harness.outline.reloadDataCallCount == 0)
        #expect(harness.outline.insertedItemCalls.isEmpty)
        #expect(harness.outline.removedItemCalls.isEmpty)
        #expect(harness.outline.movedItemCalls.isEmpty)
        #expect(harness.outline.reloadedRowIndexSets == [IndexSet(integer: row)])
        #expect(harness.outline.reloadedRowCount == 1)

        // And the row really shows the new status.
        let view = try #require(Self.sessionRow(harness, at: row))
        #expect(view.isPulsing)
    }

    @Test("A batch of status flips reloads only the rows the change set names")
    func aBatchOfFlipsReloadsOnlyThoseRows() {
        let harness = Self.makeHarness()
        harness.outline.resetCounters()
        // 3 is already `.idle` in the fixture, so flipping it would diff to nothing.
        let targets = [0, 1, 2, 5, 6].map { Fixture.sessionID($0) }
        harness.mutate { state in
            for id in targets { state.setStatus(.idle, for: id) }
        }
        #expect(harness.outline.reloadDataCallCount == 0)
        #expect(harness.outline.reloadedRowCount == targets.count)
    }

    @Test("A git refresh (no status change) is still a per-row reload, never structural")
    func gitRefreshIsNotStructural() {
        let harness = Self.makeHarness()
        harness.outline.resetCounters()
        let target = Fixture.sessionID(4)
        harness.mutate { state in
            state.updateLive(target) { $0.git = GitSummary(branch: "renamed-branch") }
        }
        #expect(harness.outline.reloadDataCallCount == 0)
        #expect(harness.outline.reloadedRowCount == 1)
        let row = harness.controller.row(forSession: target)
        let view = Self.sessionRow(harness, at: row)
        #expect((view?.branchTextLayer.string as? String) == "⎇ renamed-branch")
    }

    // MARK: - Structural changes

    @Test("Adding five sessions goes through insertItems, not reloadData")
    func addingSessionsInsertsRows() {
        let harness = Self.makeHarness()
        let before = harness.outline.numberOfRows
        harness.outline.resetCounters()

        let groupID = harness.store.state.orderedGroups[0].id
        harness.mutate { state in
            for n in 0..<5 {
                _ = state.createSession(groupID: groupID, cwd: "~/dev/northwind", title: "added \(n)")
            }
        }

        #expect(harness.outline.reloadDataCallCount == 0)
        #expect(harness.outline.insertedItemCalls.map(\.rows).reduce(0) { $0 + $1.count } == 5)
        #expect(harness.outline.insertedItemCalls.allSatisfy { $0.parent?.groupID == groupID })
        #expect(harness.outline.numberOfRows == before + 5)
        // The group's header shows a count, and the group *value* did not change — so the header
        // row must be reloaded explicitly (GUI pass 2026-09-08: "ACME LEDGER 0" over a live row).
        let header = harness.controller.row(forGroup: groupID)
        #expect(harness.outline.reloadedRowIndexSets.contains { $0.contains(header) })
        // The five new rows are reloaded by the `sessions` half of the change set as before; the
        // header is the one extra row.
        #expect(harness.outline.reloadedRowCount == 6)
    }

    @Test("Removing five sessions goes through removeItems, not reloadData")
    func removingSessionsRemovesRows() {
        let harness = Self.makeHarness()
        let before = harness.outline.numberOfRows
        harness.outline.resetCounters()

        let doomed = (0..<5).map { Fixture.sessionID($0) }
        harness.mutate { state in
            for id in doomed { state.removeSession(id) }
        }

        #expect(harness.outline.reloadDataCallCount == 0)
        #expect(harness.outline.removedItemCalls.map(\.rows).reduce(0) { $0 + $1.count } == 5)
        #expect(harness.outline.numberOfRows == before - 5)
        #expect(doomed.allSatisfy { harness.controller.row(forSession: $0) == -1 })
    }

    @Test("Reordering inside a group goes through moveItem")
    func reorderingMovesRows() {
        let harness = Self.makeHarness()
        harness.outline.resetCounters()
        let moved = Fixture.sessionID(0)

        harness.mutate { $0.reorderSession(moved, to: 4) }

        #expect(harness.outline.reloadDataCallCount == 0)
        #expect(!harness.outline.movedItemCalls.isEmpty)
        #expect(harness.outline.insertedItemCalls.isEmpty)
        #expect(harness.outline.removedItemCalls.isEmpty)
        // The row order now matches the store's order.
        let groupID = harness.store.state.orderedGroups[0].id
        let expected = harness.store.state.sessions(in: groupID).map(\.id)
        let actual = (1...expected.count).map { row -> TkzCore.SessionID in
            ((harness.outline.item(atRow: row) as? SidebarItem)?.sessionID)!
        }
        #expect(actual == expected)
    }

    @Test("Moving a session to another group is a remove plus an insert, still no reloadData")
    func movingBetweenGroupsRemovesAndInserts() {
        let harness = Self.makeHarness()
        harness.outline.resetCounters()
        let moved = Fixture.sessionID(0)
        let destination = harness.store.state.orderedGroups[1].id

        harness.mutate { $0.moveSession(moved, toGroup: destination, at: 0) }

        #expect(harness.outline.reloadDataCallCount == 0)
        #expect(harness.outline.removedItemCalls.count == 1)
        #expect(harness.outline.insertedItemCalls.count == 1)
        #expect(harness.outline.insertedItemCalls[0].parent?.groupID == destination)
        let row = harness.controller.row(forSession: moved)
        #expect(row >= 0)
        #expect((harness.outline.parent(forItem: harness.controller.item(.session(moved))) as? SidebarItem)?.groupID == destination)
    }

    // MARK: - Selection

    @Test("Selecting in the outline updates the store, and does not loop")
    func outlineSelectionWritesToTheStore() {
        let harness = Self.makeHarness()
        let target = Fixture.sessionID(5)
        let row = harness.controller.row(forSession: target)
        let deliveriesBefore = harness.store.deliveryCount

        harness.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        #expect(harness.store.state.selection == target)

        harness.store.flush()
        // Exactly one delivery, and the echo back into the outline armed nothing further.
        #expect(harness.store.deliveryCount == deliveriesBefore + 1)
        #expect(harness.store.hasPendingChanges == false)
        #expect(harness.outline.selectedRow == row)
    }

    @Test("Changing the store updates the outline, and does not loop")
    func storeSelectionWritesToTheOutline() throws {
        let harness = Self.makeHarness()
        let target = Fixture.sessionID(20)
        let deliveriesBefore = harness.store.deliveryCount

        harness.mutate { $0.select(target) }

        #expect(harness.outline.selectedRow == harness.controller.row(forSession: target))
        #expect(harness.store.deliveryCount == deliveriesBefore + 1)
        #expect(harness.store.hasPendingChanges == false)

        // Both the old and the new row repaint their own selection background.
        let view = try #require(Self.sessionRow(harness, at: harness.outline.selectedRow))
        #expect(view.selectionBackgroundLayer.backgroundColor?.alpha ?? 0 > 0)
        let otherRow = harness.controller.row(forSession: Fixture.sessionID(0))
        let other = try #require(Self.sessionRow(harness, at: otherRow))
        #expect(other.selectionBackgroundLayer.backgroundColor?.alpha ?? 1 == 0)
    }

    @Test("Group rows are not selectable")
    func groupRowsAreNotSelectable() throws {
        let harness = Self.makeHarness()
        let item = try #require(harness.outline.item(atRow: 0) as? SidebarItem)
        #expect(item.groupID != nil)
        #expect(harness.controller.outlineView(harness.outline, shouldSelectItem: item) == false)
    }

    // MARK: - Keyboard commands

    @Test("⌘1–⌘9 pick the n-th visible session, top to bottom")
    func commandDigitsPickVisibleSessions() {
        let harness = Self.makeHarness()
        harness.controller.selectSession(atVisibleIndex: 1)
        harness.store.flush()
        #expect(harness.store.state.selection == Fixture.sessionID(0))

        harness.controller.selectSession(atVisibleIndex: 9)
        harness.store.flush()
        #expect(harness.store.state.selection == Fixture.sessionID(8))

        // Out of range is a no-op, not a crash or a cleared selection.
        harness.controller.selectSession(atVisibleIndex: 999)
        harness.store.flush()
        #expect(harness.store.state.selection == Fixture.sessionID(8))
    }

    @Test("⌘1 skips a collapsed group's sessions — they are not visible rows")
    func commandDigitsSkipCollapsedGroups() {
        let harness = Self.makeHarness()
        let firstGroup = harness.store.state.orderedGroups[0].id
        harness.mutate { $0.setGroupCollapsed(firstGroup, true) }

        // Group 0 (ids 0…11) is now hidden, so the first visible session is group 1's first.
        harness.controller.selectSession(atVisibleIndex: 1)
        harness.store.flush()
        #expect(harness.store.state.selection == Fixture.sessionID(12))
        #expect(harness.outline.numberOfRows == 5 + 35 - 12)
    }

    @Test("⇧⌘U jumps to the first session needing attention, expanding its group if collapsed")
    func shiftCommandUJumpsToNeedsYou() throws {
        let harness = Self.makeHarness()
        // sessionID(1) is the fixture's first NEEDS YOU (group 0, doneUnattended).
        let expected = Fixture.sessionID(1)
        #expect(SidebarRowAdapter.firstSessionNeedingAttention(in: harness.store.state) == expected)

        let firstGroup = harness.store.state.orderedGroups[0].id
        harness.mutate { $0.setGroupCollapsed(firstGroup, true) }
        #expect(harness.controller.row(forSession: expected) == -1)

        let picked = harness.controller.selectFirstSessionNeedingAttention()
        harness.store.flush()
        harness.window.layoutIfNeeded()

        #expect(picked == expected)
        #expect(harness.store.state.selection == expected)
        // The group was expanded — in the store *and* in the outline — so the row exists.
        #expect(harness.store.state.groups[firstGroup]?.isCollapsed == false)
        #expect(harness.controller.row(forSession: expected) >= 0)
        #expect(harness.outline.selectedRow == harness.controller.row(forSession: expected))
    }

    @Test("Arrow keys move the selection over visible rows and clamp at both ends")
    func arrowKeysMoveTheSelection() {
        let harness = Self.makeHarness()
        harness.mutate { $0.select(Fixture.sessionID(0)) }

        harness.controller.moveSelection(by: 1)
        harness.store.flush()
        #expect(harness.store.state.selection == Fixture.sessionID(1))

        harness.controller.moveSelection(by: -1)
        harness.store.flush()
        #expect(harness.store.state.selection == Fixture.sessionID(0))

        // Clamped, not wrapped, at the top…
        harness.controller.moveSelection(by: -1)
        harness.store.flush()
        #expect(harness.store.state.selection == Fixture.sessionID(0))

        // …and at the bottom (the last visible session is group 3's last; Playground is collapsed).
        let last = SidebarRowAdapter.visibleSessions(in: harness.store.state).last!.id
        harness.mutate { $0.select(last) }
        harness.controller.moveSelection(by: 1)
        harness.store.flush()
        #expect(harness.store.state.selection == last)
    }

    @Test("A real ↓ key event reaches the selection, not the table's own row walk")
    func arrowKeyEventIsWiredUp() throws {
        let harness = Self.makeHarness()
        harness.mutate { $0.select(Fixture.sessionID(0)) }
        let down = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125))
        harness.outline.keyDown(with: down)
        harness.store.flush()
        #expect(harness.store.state.selection == Fixture.sessionID(1))
    }

    @Test("Arrow keys step over a collapsed group rather than into it")
    func arrowKeysStepOverCollapsedGroups() {
        let harness = Self.makeHarness()
        let secondGroup = harness.store.state.orderedGroups[1].id
        harness.mutate { $0.setGroupCollapsed(secondGroup, true) }
        // Last session of group 0 → first session of group 2, skipping the collapsed group 1.
        harness.mutate { $0.select(Fixture.sessionID(11)) }
        harness.controller.moveSelection(by: 1)
        harness.store.flush()
        #expect(harness.store.state.selection == Fixture.sessionID(22))
    }

    // MARK: - Group colour

    @Test("Setting a group's colour reloads its header and its session rows, and nothing else")
    func groupColourReloadsTheWholeGroup() throws {
        let harness = Self.makeHarness()
        let groupID = harness.store.state.orderedGroups[0].id
        let teal = GroupPalette.swatches[0].rgb

        var expected = IndexSet(integer: harness.controller.row(forGroup: groupID))
        for session in harness.store.state.sessions(in: groupID) {
            expected.insert(harness.controller.row(forSession: session.id))
        }
        #expect(expected.count == 13)  // Northwind: 1 header + 12 sessions

        harness.outline.resetCounters()
        harness.mutate { $0.setGroupColor(groupID, color: teal) }

        #expect(harness.outline.reloadDataCallCount == 0)
        #expect(harness.outline.insertedItemCalls.isEmpty)
        #expect(harness.outline.removedItemCalls.isEmpty)
        #expect(harness.outline.reloadedRowCount == expected.count)
        var reloaded = IndexSet()
        for set in harness.outline.reloadedRowIndexSets { reloaded.formUnion(set) }
        #expect(reloaded == expected)

        // And the rows really carry the colour, header and sessions alike.
        let header = try #require(
            harness.outline.view(atColumn: 0, row: harness.controller.row(forGroup: groupID),
                                 makeIfNecessary: true) as? GroupRowView)
        #expect(header.edgeColor != nil)
        let firstSession = harness.store.state.sessions(in: groupID)[0].id
        let row = try #require(
            Self.sessionRow(harness, at: harness.controller.row(forSession: firstSession)))
        #expect(row.edgeColor != nil)
        #expect(row.colourEdgeLayer.frame.minX == 0)
    }

    @Test("A rename or a collapse still reloads only the header — the colour shadow is precise")
    func otherGroupChangesStillReloadOneRow() {
        let harness = Self.makeHarness()
        let groupID = harness.store.state.orderedGroups[0].id

        harness.outline.resetCounters()
        harness.mutate { $0.renameGroup(groupID, name: "Northwind Trading Co") }
        #expect(harness.outline.reloadedRowCount == 1)

        // Setting the same colour twice is a no-op the second time: the store diffs to nothing.
        let teal = GroupPalette.swatches[0].rgb
        harness.mutate { $0.setGroupColor(groupID, color: teal) }
        harness.outline.resetCounters()
        harness.mutate { $0.setGroupColor(groupID, color: teal) }
        #expect(harness.outline.reloadedRowCount == 0)

        // A collapse of a coloured group is one row, not thirteen — its sessions stop being rows.
        harness.outline.resetCounters()
        harness.mutate { $0.setGroupCollapsed(groupID, true) }
        #expect(harness.outline.reloadedRowCount == 1)
    }

    @Test("Colouring a collapsed group touches only its header; expanding shows the coloured rows")
    func collapsedGroupColourReachesItsRowsOnExpand() throws {
        let harness = Self.makeHarness()
        // Playground is collapsed in the fixture.
        let groupID = harness.store.state.orderedGroups[4].id
        #expect(harness.store.state.groups[groupID]?.isCollapsed == true)

        harness.outline.resetCounters()
        harness.mutate { $0.setGroupColor(groupID, color: GroupPalette.swatches[5].rgb) }
        #expect(harness.outline.reloadedRowCount == 1, "a collapsed group's sessions are not rows")

        harness.mutate { $0.setGroupCollapsed(groupID, false) }
        let session = harness.store.state.sessions(in: groupID)[0].id
        let row = try #require(Self.sessionRow(harness, at: harness.controller.row(forSession: session)))
        #expect(row.edgeColor != nil)
    }

    @Test("Clearing a group's colour repaints the whole group back to no edge")
    func clearingTheColourRepaintsTheGroup() throws {
        let harness = Self.makeHarness()
        let groupID = harness.store.state.orderedGroups[0].id
        harness.mutate { $0.setGroupColor(groupID, color: GroupPalette.swatches[0].rgb) }

        harness.outline.resetCounters()
        harness.mutate { $0.setGroupColor(groupID, color: nil) }
        #expect(harness.outline.reloadedRowCount == 13)

        let session = harness.store.state.sessions(in: groupID)[0].id
        let row = try #require(Self.sessionRow(harness, at: harness.controller.row(forSession: session)))
        #expect(row.edgeColor?.alpha == 0)
    }

    @Test("A session created in a coloured group comes up with the edge already on")
    func newSessionInAColouredGroupGetsTheEdge() throws {
        let harness = Self.makeHarness()
        let groupID = harness.store.state.orderedGroups[0].id
        harness.mutate { $0.setGroupColor(groupID, color: GroupPalette.swatches[0].rgb) }

        var created: SessionID?
        harness.mutate { created = $0.createSession(groupID: groupID, cwd: "~/dev/northwind").id }
        let id = try #require(created)
        let row = try #require(Self.sessionRow(harness, at: harness.controller.row(forSession: id)))
        #expect(row.edgeColor?.alpha == 1)
    }

    // MARK: - Collapse

    @Test("Collapsing through the controller persists into the store and hides the rows")
    func collapsePersistsIntoTheStore() {
        let harness = Self.makeHarness()
        let groupID = harness.store.state.orderedGroups[0].id
        let before = harness.outline.numberOfRows
        harness.outline.resetCounters()

        harness.controller.toggleCollapse(groupID)
        harness.store.flush()
        harness.window.layoutIfNeeded()

        #expect(harness.store.state.groups[groupID]?.isCollapsed == true)
        #expect(harness.outline.numberOfRows == before - 12)
        // Collapse is *not* structural: no insert/remove/move, and no full reload.
        #expect(harness.outline.reloadDataCallCount == 0)
        #expect(harness.outline.insertedItemCalls.isEmpty)
        #expect(harness.outline.removedItemCalls.isEmpty)

        harness.controller.toggleCollapse(groupID)
        harness.store.flush()
        harness.window.layoutIfNeeded()
        #expect(harness.store.state.groups[groupID]?.isCollapsed == false)
        #expect(harness.outline.numberOfRows == before)
    }

    @Test("Expanding the outline directly writes back to the store")
    func outlineExpansionWritesBackToTheStore() {
        let harness = Self.makeHarness()
        let playground = harness.store.state.orderedGroups[4].id
        harness.outline.expandItem(harness.controller.item(.group(playground)))
        #expect(harness.store.state.groups[playground]?.isCollapsed == false)

        harness.outline.collapseItem(harness.controller.item(.group(playground)))
        #expect(harness.store.state.groups[playground]?.isCollapsed == true)
    }

    @Test("A collapsed group's header shows the collapsed chevron and the full session count")
    func groupHeaderReflectsCollapseState() throws {
        let harness = Self.makeHarness()
        let playgroundRow = harness.controller.row(forGroup: harness.store.state.orderedGroups[4].id)
        let view = try #require(
            harness.outline.view(atColumn: 0, row: playgroundRow, makeIfNecessary: true) as? GroupRowView)
        #expect(view.chevronPointsRight)
        #expect((view.nameTextLayer.string as? String) == "PLAYGROUND")
    }

    @Test("A new session expands its group, so the row it creates is actually visible")
    func creatingASessionExpandsACollapsedGroup() throws {
        let harness = Self.makeHarness()
        let playground = harness.store.state.orderedGroups[4].id
        #expect(harness.store.state.groups[playground]?.isCollapsed == true)

        // The shape `SessionLauncher.start` uses: create, give it a shell, select it — one mutation.
        let created = harness.store.updating { state -> SessionID in
            let session = state.createSession(groupID: playground, cwd: "/tmp/new")
            state.select(session.id)
            return session.id
        }
        harness.store.flush()

        #expect(harness.store.state.groups[playground]?.isCollapsed == false)
        #expect(harness.outline.isItemExpanded(harness.controller.item(.group(playground))))
        let row = harness.controller.row(forSession: created)
        #expect(row >= 0)
        #expect(harness.outline.selectedRow == row)

        let view = try #require(
            harness.outline.view(atColumn: 0, row: harness.controller.row(forGroup: playground),
                                 makeIfNecessary: true) as? GroupRowView)
        #expect(view.chevronPointsRight == false)
    }

    @Test("Collapsing and re-expanding hands the selection back to the outline")
    func selectionSurvivesACollapseCycle() {
        let harness = Self.makeHarness()
        let selected = Fixture.sessionID(0)
        #expect(harness.store.state.selection == selected)
        let groupID = harness.store.state.orderedGroups[0].id

        harness.mutate { $0.setGroupCollapsed(groupID, true) }
        // The store keeps the selection even though the row is gone.
        #expect(harness.store.state.selection == selected)
        #expect(harness.outline.selectedRow == -1)

        harness.mutate { $0.setGroupCollapsed(groupID, false) }
        #expect(harness.store.state.selection == selected)
        #expect(harness.outline.selectedRow == harness.controller.row(forSession: selected))
    }

    @Test("The group header's ＋ reaches onNewSession, and survives row reuse")
    func addButtonIsRewiredOnEveryVend() throws {
        let harness = Self.makeHarness()
        var received: [GroupID] = []
        harness.controller.onNewSession = { received.append($0) }
        let groupID = harness.store.state.orderedGroups[0].id

        let row = harness.controller.row(forGroup: groupID)
        let view = try #require(
            harness.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? GroupRowView)
        view.addButton.performClick(nil)
        #expect(received == [groupID])

        // `prepareForReuse()` clears `onAdd`; a reload must put it back.
        harness.mutate { $0.renameGroup(groupID, name: "Northwind Trading") }
        harness.mutate { $0.setGroupColor(groupID, color: RGB(hex: 0x41c6a8)) }
        let reused = try #require(
            harness.outline.view(atColumn: 0, row: harness.controller.row(forGroup: groupID),
                                 makeIfNecessary: true) as? GroupRowView)
        reused.addButton.performClick(nil)
        #expect(received == [groupID, groupID])
    }

    // MARK: - Summary strip

    @Test("The summary strip is at the top, the ＋ New group footer at the bottom, the list between")
    func newGroupFooter() {
        let harness = Self.makeHarness()
        harness.window.layoutIfNeeded()
        harness.controller.view.layoutSubtreeIfNeeded()

        let footer = harness.controller.newGroupFooter
        let strip = harness.controller.summaryStrip
        let container = harness.controller.view
        #expect(footer.superview === container)
        #expect(footer.frame.height == CGFloat(SidebarMetrics.newGroupFooterHeight))
        #expect(footer.frame.minY == 0, "the footer is the bottom-most strip")
        // The strip moved to the top on 2026-09-08 (artboard 2c draws it under the toolbar).
        let topInset = container.safeAreaInsets.top
        #expect(abs(strip.frame.maxY - (container.bounds.height - topInset)) < 0.5, "the strip sits at the top, under the toolbar")
        #expect(abs(harness.controller.scrollView.frame.maxY - strip.frame.minY) < 0.5, "the list starts right under it")
        #expect(abs(harness.controller.scrollView.frame.minY - footer.frame.maxY) < 0.5, "and ends at the footer")
        #expect(strip.summaryText.hasSuffix("need you"))
        #expect(SummaryStripView.displayText(for: SidebarSummaryModel(working: 2, needAttention: 1)) == "2 WORKING · 1 NEED YOU")
        #expect(footer.labelTextLayer.string as? String == NewGroupFooterView.title)
        #expect(footer.dashedBorderLayer.path != nil)
        #expect(footer.buttonFrame.height == NewGroupFooterView.buttonHeight)

        var clicks = 0
        harness.controller.onNewGroup = { clicks += 1 }
        footer.button.performClick(nil)
        #expect(clicks == 1)
    }

    @Test("The summary strip counts NEEDS YOU badges and follows the change set")
    func summaryStripFollowsTheStore() {
        let harness = Self.makeHarness()
        let counts = harness.store.state.summaryCounts
        #expect(harness.controller.summaryStrip.summaryText == "\(counts.working) working · \(counts.needsYou) need you")

        harness.mutate { state in
            state.updateLive(Fixture.sessionID(0)) { $0.attention = true }
        }
        #expect(
            harness.controller.summaryStrip.summaryText
                == "\(counts.working) working · \(counts.needsYou + 1) need you")
    }

    // MARK: - Occlusion

    @Test("Occlusion is forwarded per row and parks the pulse")
    func occlusionParksVisibleRowPulses() throws {
        let harness = Self.makeHarness()
        let workingRow = harness.controller.row(forSession: Fixture.sessionID(0))
        let view = try #require(Self.sessionRow(harness, at: workingRow))
        #expect(view.isPulsing)

        harness.controller.setOccluded(true)
        #expect(view.statusDot.pulseSpeed == 0)

        harness.controller.setOccluded(false)
        #expect(view.statusDot.pulseSpeed == 1)
    }

    // MARK: - The adapter's mapping rules

    @Test("All three waiting reasons collapse to one dot state")
    func waitingReasonsCollapse() {
        for reason in WaitReason.allCases {
            #expect(SidebarRowAdapter.status(.waiting(reason)) == .waiting)
        }
        #expect(SidebarRowAdapter.status(.working) == .working)
        #expect(SidebarRowAdapter.status(.idle) == .idle)
    }

    @Test("needsAttention is the attention flag, not the waiting status")
    func needsAttentionIsTheFlag() {
        let state = AppState.fixture
        // A permission prompt is `.waiting` *and* flagged in the fixture…
        let permission = state.sessions[Fixture.sessionID(2)]!
        #expect(SidebarRowAdapter.sessionModel(permission, in: state).needsAttention)
        // …but a hand-made waiting session with the flag clear shows the dot and no badge.
        var quiet = permission
        quiet.live?.attention = false
        let model = SidebarRowAdapter.sessionModel(quiet, in: state)
        #expect(model.status == .waiting)
        #expect(model.needsAttention == false)
    }

    @Test("Row models carry the bare branch, the resolved title and the original group casing")
    func rowModelsFollowTheContract() {
        let state = AppState.fixture
        let session = state.sessions[Fixture.sessionID(1)]!
        let model = SidebarRowAdapter.sessionModel(session, in: state)
        #expect(model.branch == "feat/pricing-engine")  // no ⎇ — the view adds it
        #expect(model.title == session.displayTitle)
        #expect(model.isWorktree)
        #expect(model.isSelected == false)

        let group = state.orderedGroups[0]
        let groupModel = SidebarRowAdapter.groupModel(group, in: state)
        #expect(groupModel.name == group.name)  // not uppercased here
        #expect(groupModel.sessionCount == 12)
        #expect(groupModel.color == group.color)
    }

    @Test("A group with no colour maps to nil, never to groupEdgeDefault")
    func uncolouredGroupsStayNil() {
        var state = AppState.fixture
        let groupID = state.orderedGroups[0].id
        state.setGroupColor(groupID, color: nil)
        let model = SidebarRowAdapter.groupModel(state.groups[groupID]!, in: state)
        #expect(model.color == nil)
        #expect(model.color != Theme.default.groupEdgeDefault)

        // Same rule on the session rows, which carry the group's colour so the edge spans the group.
        let session = state.sessions(in: groupID)[0]
        #expect(SidebarRowAdapter.sessionModel(session, in: state).groupColor == nil)
    }

    @Test("A session row model carries its group's colour, not its own (TKZ-48)")
    func sessionModelCarriesTheGroupColour() {
        var state = AppState.fixture
        let groupID = state.orderedGroups[0].id
        let other = state.orderedGroups[1].id
        let violet = GroupPalette.swatches[3].rgb
        state.setGroupColor(groupID, color: violet)

        for session in state.sessions(in: groupID) {
            #expect(SidebarRowAdapter.sessionModel(session, in: state).groupColor == violet)
        }
        // Colouring one group leaves its neighbour on its own colour.
        let outsider = state.sessions(in: other)[0]
        #expect(SidebarRowAdapter.sessionModel(outsider, in: state).groupColor == state.groups[other]?.color)
        #expect(SidebarRowAdapter.sessionModel(outsider, in: state).groupColor != violet)

        // Clearing it drops the edge on every row in the group, not just the header.
        state.setGroupColor(groupID, color: nil)
        for session in state.sessions(in: groupID) {
            #expect(SidebarRowAdapter.sessionModel(session, in: state).groupColor == nil)
        }
    }

    @Test("The account chip is hidden on the default account and short-labelled on any other")
    func accountChipDependsOnAccount() {
        let state = AppState.fixture
        let alt = state.sessions[Fixture.sessionID(0)]!
        #expect(SidebarRowAdapter.accountLabel(for: alt, in: state) == "CA")  // "Claude (alt)"
        // `~/.claude` never gets a chip: for the one plan everybody has, it would say nothing.
        let main = state.sessions[Fixture.sessionID(5)]!
        #expect(SidebarRowAdapter.accountLabel(for: main, in: state) == nil)

        // A second account the store has never heard of still gets a chip, derived from its key.
        var unknown = alt
        unknown.accountKey = "claude-review"
        #expect(SidebarRowAdapter.accountLabel(for: unknown, in: state) == "CR")

        // The chip colour is the documented, process-independent derivation.
        #expect(
            SidebarRowAdapter.sessionModel(main, in: state).accountColor
                == SidebarSessionRowModel.accountChipColor(forKey: "claude"))
    }

    @Test("The summary model counts badges, not waiting dots")
    func summaryModelCountsBadges() {
        let state = AppState.fixture
        let model = SidebarRowAdapter.summaryModel(for: state)
        let waitingDots = state.sessions.values.filter(\.status.isWaiting).count
        #expect(model.needAttention == state.summaryCounts.needsYou)
        #expect(model.needAttention <= waitingDots)
        #expect(model.working == state.summaryCounts.working)
    }

    // MARK: - Headless render of the assembled sidebar

    @Test("The assembled sidebar rasterises offscreen")
    func sidebarRendersOffscreen() throws {
        let harness = Self.makeHarness()
        harness.window.displayIfNeeded()
        harness.controller.view.layoutSubtreeIfNeeded()

        let bounds = harness.controller.view.bounds
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let ctx = graphics.cgContext
        ctx.scaleBy(x: scale, y: scale)
        try #require(harness.controller.view.layer).render(in: ctx)

        // Not a blank canvas: the sidebar background plus rows means many distinct colours.
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
                .appendingPathComponent("tkzmux-sidebar-\(UUID().uuidString).png")
            try? png.write(to: url)
            print("sidebar render: \(url.path)")
        }
    }
}

/// Regression: launching a session creates it and selects it in **one** change set, so the sidebar
/// sees `structure` and `selection` together. Reported from the app (M2.5 / TKZ-43): after `>_` the
/// sidebar painted two rows as selected.
@MainActor
@Suite(.serialized)
struct SidebarSelectionOnInsertTests {

    @Test("Creating and selecting in one change set leaves exactly one row painted selected")
    func oneSelectionAfterInsert() {
        var state = AppState()
        let group = state.addGroup(name: "Scratch", repoRoot: "/tmp")
        let harness = SidebarViewControllerTests.makeHarness(state)
        defer { harness.window.orderOut(nil) }

        var ids: [SessionID] = []
        for _ in 0..<3 {
            harness.mutate { s in
                let created = s.createSession(groupID: group.id, cwd: "/tmp")
                s.setLive(LiveSessionState(shellPid: 1, status: .idle), for: created.id)
                s.select(created.id)
                ids.append(created.id)
            }

            let painted = (0..<harness.outline.numberOfRows).filter { row in
                guard let view = harness.outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                    as? SessionRowView else { return false }
                return (view.selectionBackgroundLayer.backgroundColor?.alpha ?? 0) > 0
            }
            #expect(painted.count == 1, "after \(ids.count) launches, rows painted selected: \(painted)")
            #expect(harness.outline.selectedRowIndexes.count == 1)
        }
    }
}

// MARK: - Drag and drop

/// Dragging a session row into another group (`moveSession` from the sidebar's own drop handling).
///
/// A real drag cannot be staged headlessly — `NSDraggingInfo` has no public initialiser — so what is
/// asserted here are the two pure functions the drop path is built out of, plus the composition that
/// actually matters: the row the insertion gap promised is the row the store ends up with.
@MainActor
@Suite(.serialized)
struct SidebarDragAndDropTests {

    @Test("The outline is wired to accept its own session drags")
    func theOutlineIsRegisteredForSessionDrags() {
        let harness = SidebarViewControllerTests.makeHarness()
        // The only type it takes: a session row means nothing outside this app, and nothing from
        // outside it means anything here. (`setDraggingSourceOperationMask` has no getter to assert.)
        #expect(harness.outline.registeredDraggedTypes == [.tkzSidebarSession])
        #expect(harness.outline.draggingDestinationFeedbackStyle == .gap)

        // The one failure mode every other test here would sail straight past: the methods are
        // correct Swift but AppKit never finds them, so nothing drags in the real app.
        let controller = harness.controller
        #expect(controller.responds(
            to: #selector(NSOutlineViewDataSource.outlineView(_:pasteboardWriterForItem:))))
        #expect(controller.responds(
            to: #selector(NSOutlineViewDataSource.outlineView(_:validateDrop:proposedItem:proposedChildIndex:))))
        #expect(controller.responds(
            to: #selector(NSOutlineViewDataSource.outlineView(_:acceptDrop:item:childIndex:))))
    }

    @Test("A collapsed group can only be appended to — no child index points into it")
    func collapsedGroupsOnlyAppend() {
        let harness = SidebarViewControllerTests.makeHarness()
        let controller = harness.controller
        // The fixture collapses the last group (Playground).
        let collapsed = harness.store.state.orderedGroups[4]
        #expect(collapsed.isCollapsed)

        let onHeader = controller.dropTarget(
            for: controller.item(.group(collapsed.id)), childIndex: NSOutlineViewDropOnItemIndex)
        #expect(onHeader?.group == collapsed.id)
        #expect(onHeader?.displayed == nil)

        // Even asked for a slot inside it, the answer is "append".
        let inside = controller.dropTarget(for: controller.item(.group(collapsed.id)), childIndex: 2)
        #expect(inside?.group == collapsed.id)
        #expect(inside?.displayed == nil)
    }

    @Test("Only session rows are draggable; a group header returns no pasteboard writer")
    func groupHeadersDoNotDrag() {
        let harness = SidebarViewControllerTests.makeHarness()
        let controller = harness.controller
        let group = harness.store.state.orderedGroups[0].id
        let session = harness.store.state.sessions(in: group)[0].id

        let forGroup = controller.outlineView(
            harness.outline, pasteboardWriterForItem: controller.item(.group(group)))
        #expect(forGroup == nil)

        let forSession = controller.outlineView(
            harness.outline, pasteboardWriterForItem: controller.item(.session(session)))
        let item = try? #require(forSession as? NSPasteboardItem)
        #expect(item?.string(forType: .tkzSidebarSession) == session.rawValue)
    }

    @Test("A drop on a group header appends; a drop between its rows takes that slot")
    func dropTargetResolvesGroupProposals() {
        let harness = SidebarViewControllerTests.makeHarness()
        let group = harness.store.state.orderedGroups[1].id

        let onHeader = harness.controller.dropTarget(
            for: harness.controller.item(.group(group)), childIndex: NSOutlineViewDropOnItemIndex)
        #expect(onHeader?.group == group)
        #expect(onHeader?.displayed == nil)  // nil = append

        let betweenRows = harness.controller.dropTarget(
            for: harness.controller.item(.group(group)), childIndex: 2)
        #expect(betweenRows?.group == group)
        #expect(betweenRows?.displayed == 2)
    }

    @Test("A drop on a session row resolves to that row's place in its own group")
    func dropTargetRetargetsSessionsOntoTheirGroup() {
        let harness = SidebarViewControllerTests.makeHarness()
        let group = harness.store.state.orderedGroups[1].id
        let third = harness.store.state.sessions(in: group)[2].id

        let target = harness.controller.dropTarget(
            for: harness.controller.item(.session(third)), childIndex: NSOutlineViewDropOnItemIndex)

        #expect(target?.group == group)
        #expect(target?.displayed == 2)
    }

    @Test("A drop in the root list lands in the group above it; on the bare background, nowhere")
    func dropTargetResolvesRootProposals() {
        let harness = SidebarViewControllerTests.makeHarness()
        let groups = harness.store.state.orderedGroups.map(\.id)

        // Above every header: the top of the first group.
        let top = harness.controller.dropTarget(for: nil, childIndex: 0)
        #expect(top?.group == groups[0])
        #expect(top?.displayed == 0)

        // Between headers 1 and 2: the end of the group above.
        let between = harness.controller.dropTarget(for: nil, childIndex: 2)
        #expect(between?.group == groups[1])
        #expect(between?.displayed == nil)

        // "On" the root itself is not a place.
        #expect(harness.controller.dropTarget(for: nil, childIndex: NSOutlineViewDropOnItemIndex) == nil)
    }

    @Test("Into another group the index passes through; within one, slots below the row shift up")
    func storeIndexRebasesOnlyWithinTheSourceGroup() {
        let harness = SidebarViewControllerTests.makeHarness()
        let controller = harness.controller
        let source = harness.store.state.orderedGroups[0].id
        let other = harness.store.state.orderedGroups[1].id
        let first = harness.store.state.sessions(in: source)[0].id

        // A different group loses no row, so displayed and store indices agree.
        #expect(controller.storeIndex(forDisplayed: 3, in: other, dragging: first) == 3)
        // Its own group: dropping below the dragged row shifts up by one...
        #expect(controller.storeIndex(forDisplayed: 4, in: source, dragging: first) == 3)
        // ...while dropping at or above it does not.
        #expect(controller.storeIndex(forDisplayed: 0, in: source, dragging: first) == 0)
        // Append stays append.
        #expect(controller.storeIndex(forDisplayed: nil, in: source, dragging: first) == nil)
    }

    @Test("A within-group drag lands exactly in the gap the user was shown")
    func withinGroupDropLandsWhereTheGapWas() throws {
        let harness = SidebarViewControllerTests.makeHarness()
        let controller = harness.controller
        let group = harness.store.state.orderedGroups[0].id
        let before = harness.store.state.sessions(in: group).map(\.id)
        let dragged = before[0]

        // The gap at displayed index 4 sits immediately above the row that is there now.
        let target = controller.dropTarget(for: controller.item(.group(group)), childIndex: 4)
        let destination = try #require(target?.group)
        let at = controller.storeIndex(
            forDisplayed: target?.displayed, in: destination, dragging: dragged)
        harness.mutate { $0.moveSession(dragged, toGroup: destination, at: at) }

        let after = harness.store.state.sessions(in: group).map(\.id)
        #expect(after == [before[1], before[2], before[3], dragged] + before.dropFirst(4))
        // Which is to say: still directly above the row the gap was drawn above.
        #expect(after.firstIndex(of: dragged) == after.firstIndex(of: before[4]).map { $0 - 1 })
    }

    @Test("A cross-group drag moves the row and keeps it selected")
    func crossGroupDropMovesTheRowAndKeepsSelection() {
        let harness = SidebarViewControllerTests.makeHarness()
        let controller = harness.controller
        let source = harness.store.state.orderedGroups[0].id
        let destination = harness.store.state.orderedGroups[1].id
        let dragged = harness.store.state.sessions(in: source)[0].id
        let sourceCount = harness.store.state.sessions(in: source).count
        harness.mutate { $0.select(dragged) }

        let target = controller.dropTarget(for: controller.item(.group(destination)), childIndex: 0)
        #expect(target?.group == destination)
        let at = controller.storeIndex(
            forDisplayed: target?.displayed, in: destination, dragging: dragged)
        harness.mutate { $0.moveSession(dragged, toGroup: destination, at: at) }

        #expect(harness.store.state.sessions[dragged]?.groupID == destination)
        #expect(harness.store.state.sessions(in: destination).first?.id == dragged)
        #expect(harness.store.state.sessions(in: source).count == sourceCount - 1)
        // The row moved under the new parent, and the move did not disturb the selection.
        #expect(harness.store.state.selection == dragged)
        #expect(
            (harness.outline.parent(forItem: controller.item(.session(dragged))) as? SidebarItem)?
                .groupID == destination)
    }

    @Test("A session that is not in the destination group is incoming: its index passes through")
    func storeIndexPassesThroughForANonMember() {
        let harness = SidebarViewControllerTests.makeHarness()
        let group = harness.store.state.orderedGroups[0].id
        let gone = SessionID.generate()

        // Not a member of the group, so it is treated as an incoming row: index passes through.
        #expect(harness.controller.storeIndex(forDisplayed: 1, in: group, dragging: gone) == 1)
    }
}
