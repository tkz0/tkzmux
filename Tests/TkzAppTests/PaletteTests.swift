import AppKit
import Foundation
import Testing
import TkzCore

@testable import TkzApp

/// ⌘P / ⇧⌘P over the 40-session fixture (TKZ-20, M2.4).
///
/// **On the ticket's two named cases.** The ticket asks for `"wor-12"` (by branch) and
/// `"Track updated"` (by title). Neither string exists in `AppState.fixture`, and `FixtureState.swift`
/// belongs to another module's committed code, so the nearest equivalents are used and the *field*
/// the hit came from is asserted, which is the part that actually matters:
///   * branch — session 9 is `fix/rounding` with no title and no worktree, so `"rounding"` appears in
///     nothing else about that row (its display title is `northwind`);
///   * title  — session "docs sweep" in the Scheduled group.
@MainActor
struct PaletteTests {

    static let state = AppState.fixture

    static func source(_ mode: PaletteDataSource.Mode = .all) -> PaletteDataSource {
        PaletteDataSource(state: state, mode: mode)
    }

    // MARK: The ticket's explicit cases

    @Test func findsASessionByItsBranch() throws {
        let results = Self.source().search("rounding")
        let top = try #require(results.first)
        #expect(top.item.sessionID == Fixture.sessionID(9))
        #expect(top.field == .branch, "the hit must come from the branch, not from a path")
        #expect(top.matchedText == "fix/rounding")
        #expect(top.ranges.map { String(top.matchedText[$0]) } == ["rounding"])
        // …and the row explains itself: the subtitle carries the branch.
        #expect(top.item.subtitle.contains("fix/rounding") == true)
    }

    @Test func findsASessionByItsTitle() throws {
        let results = Self.source().search("docs sweep")
        let top = try #require(results.first)
        #expect(top.item.title == "docs sweep")
        #expect(top.field == .title)
        #expect(top.titleRanges.isEmpty == false, "a title hit must be highlightable")
        // A fuzzy fragment finds it too.
        #expect(Self.source().search("dcswp").first?.item.title == "docs sweep")
    }

    @Test func searchesCwdAndGroupName() throws {
        // The ticket's four session fields: title, branch, cwd, group.
        let fields = Set(PaletteDataSource.item(for: Self.state.sessions[Fixture.sessionID(1)]!, in: Self.state)
            .fields.map(\.field))
        #expect(fields == [.title, .branch, .cwd, .group])

        // A group name that appears in no session title still finds that group's sessions.
        let byGroup = Self.source().search("playground").filter { $0.item.kind == .session }
        #expect(!byGroup.isEmpty)
        #expect(byGroup.allSatisfy { Self.state.group(of: $0.item.sessionID!)?.name == "Playground" })

        // A worktree path fragment is reachable through cwd.
        let byCwd = Self.source().search("worktrees/classifier")
        #expect(byCwd.first?.field == .cwd)
        #expect(byCwd.first?.item.subtitle.contains("classifier") == true)
    }

    // MARK: Items

    @Test func sessionsModeCarriesOnlySessionsAndEverythingElseIsInTheFullMode() throws {
        #expect(Self.source(.sessions).items.allSatisfy { $0.kind == .session })
        #expect(Self.source(.sessions).items.count == Self.state.sessions.count)

        let kinds = Set(Self.source().items.map(\.kind))
        #expect(kinds == Set(PaletteItem.Kind.allCases))
    }

    @Test func emptyQueryListsEverythingInSidebarOrder() throws {
        let source = Self.source(.sessions)
        let results = source.search("")
        #expect(results.count == Self.state.sessions.count, "⌘P must open on the list, not on nothing")
        #expect(results.map(\.item.sessionID) == Self.state.orderedSessions.map { $0.id })
        #expect(results.allSatisfy { $0.score == 0 && $0.ranges.isEmpty })
    }

    @Test func commandRowsUseTheShortcutActionVocabulary() throws {
        let results = Self.source().search("command palette")
        let top = try #require(results.first)
        #expect(top.item.kind == .command)
        // The palette and the main menu dispatch on the same id.
        #expect(top.item.actionID == ShortcutAction.commandPalette.rawValue)
        #expect(top.item.trailing == "\u{21E7}\u{2318}P")
    }

    @Test func presetRowsAreSearchableByNameAndCommand() throws {
        let byName = Self.source().search("plan mode")
        #expect(byName.first?.item.kind == .preset)
        #expect(byName.first?.item.actionID.hasPrefix("preset:") == true)

        let byCommand = Self.source().search("permission-mode")
        #expect(byCommand.first?.item.kind == .preset)
        #expect(byCommand.first?.field == .subtitle)
    }

    @Test func sectionsComeBackGroupedInDisplayOrder() throws {
        let sections = Self.source().sections(for: "e")
        #expect(!sections.isEmpty)
        let order = sections.map(\.kind.sectionOrder)
        #expect(order == order.sorted())
        #expect(sections.allSatisfy { !$0.results.isEmpty })
        // Ranked inside a section.
        for section in sections {
            let scores = section.results.map(\.score)
            #expect(scores == scores.sorted(by: >))
        }
    }

    @Test func aTitleHitOutranksAPathHitForTheSameQuery() throws {
        // "reporting" is a worktree path in group 0 and a title word in group 1's hangfire session.
        let results = Self.source().search("reporting")
        let top = try #require(results.first)
        #expect(top.field == .title || top.field == .branch)
    }

    // MARK: Performance (measured, reported in the ticket)

    @Test func ranksTheFortySessionFixtureWellUnderFiftyMilliseconds() throws {
        let queries = ["r", "ro", "rou", "round", "rounding", "docs sweep", "feat/", "claude"]
        let clock = ContinuousClock()

        let build = clock.measure { _ = PaletteDataSource(state: Self.state, mode: .all) }
        let source = PaletteDataSource(state: Self.state, mode: .all)

        var worst = Duration.zero
        var total = Duration.zero
        for query in queries {
            let elapsed = clock.measure { _ = source.search(query) }
            total += elapsed
            if elapsed > worst { worst = elapsed }
        }
        let ms = { (d: Duration) in Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        print(
            """
            palette perf (40-session fixture, \(source.items.count) items):
              build (folds every field): \(String(format: "%.2f", ms(build))) ms
              worst keystroke:           \(String(format: "%.2f", ms(worst))) ms
              mean keystroke:            \(String(format: "%.2f", ms(total) / Double(queries.count))) ms
            """)
        #expect(worst < .milliseconds(50), "a keystroke took \(ms(worst)) ms")
        #expect(build < .milliseconds(50), "building the item list took \(ms(build)) ms")
    }

    // MARK: Controller behaviour (headless — no panel is created)

    @Test func controllerSelectsTheFirstHitAndMovesWithArrowKeys() throws {
        let controller = CommandPaletteController(state: Self.state, mode: .sessions)
        controller.updateQuery("main")
        #expect(!controller.results.isEmpty)
        #expect(controller.selectedIndex == 0)

        controller.moveSelection(by: 1)
        #expect(controller.selectedIndex == 1)
        controller.moveSelection(by: -1)
        #expect(controller.selectedIndex == 0)
        // No wraparound at either end.
        controller.moveSelection(by: -1)
        #expect(controller.selectedIndex == 0)
        controller.moveSelection(by: controller.rows.count + 5)
        #expect(controller.selectedIndex == controller.rows.count - 1)
    }

    @Test func controllerSkipsSectionHeadersWhenMoving() throws {
        let controller = CommandPaletteController(state: Self.state, mode: .all)
        controller.updateQuery("s")
        #expect(controller.rows.contains { if case .header = $0 { return true }; return false })
        #expect(controller.rows[controller.selectedIndex!].isSelectable)
        for _ in 0..<12 {
            controller.moveSelection(by: 1)
            #expect(controller.rows[controller.selectedIndex!].isSelectable)
        }
    }

    @Test func controllerActivatesTheSelectionAndDismisses() throws {
        let controller = CommandPaletteController(state: Self.state, mode: .sessions)
        var activated: PaletteResult?
        var dismissed = 0
        controller.onActivate = { activated = $0 }
        controller.onDismiss = { dismissed += 1 }

        controller.updateQuery("rounding")
        controller.activateSelection()
        #expect(activated?.item.sessionID == Fixture.sessionID(9))
        #expect(dismissed == 1, "activating closes the palette")

        controller.updateQuery("zzzzzznothing")
        #expect(controller.results.isEmpty)
        #expect(controller.selectedIndex == nil)
        controller.activateSelection()
        #expect(dismissed == 1, "Return with no hits must do nothing")
    }

    @Test func controllerSingleSectionOmitsTheHeader() throws {
        let controller = CommandPaletteController(state: Self.state, mode: .sessions)
        controller.updateQuery("rounding")
        #expect(controller.rows.allSatisfy { $0.isSelectable }, "⌘P shows no 'Sessions' header")
    }

    @Test func rowHighlightingUsesTheMatchedRanges() throws {
        let controller = CommandPaletteController(state: Self.state, mode: .all)
        controller.updateQuery("docs sweep")
        let result = try #require(controller.selectedResult)
        let title = PaletteRowView.titleString(result, theme: .default)
        // The highlight is a real attribute run over the matched characters, not a repainted string.
        var highlighted = ""
        title.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: title.length)) {
            value, range, _ in
            if let color = value as? NSColor, color == Theme.default.accent.nsColor {
                highlighted += (title.string as NSString).substring(with: range)
            }
        }
        #expect(highlighted.replacingOccurrences(of: " ", with: "") == "docssweep")

        // A branch hit labels itself in the subtitle instead.
        controller.updateQuery("rounding")
        let branchHit = try #require(controller.selectedResult)
        let subtitle = PaletteRowView.subtitleString(branchHit, theme: .default)
        #expect(subtitle.string.hasPrefix("branch: "))
    }

    @Test func panelIsBuiltLazilyAndCarriesTheDesignsChrome() throws {
        let controller = CommandPaletteController(state: Self.state, mode: .all)
        #expect(controller.panelForTesting == nil, "no window until it is presented")

        controller.present(state: Self.state, mode: .all, over: nil)
        let panel = try #require(controller.panelForTesting)
        #expect(panel.styleMask.contains(.nonactivatingPanel) == true)
        #expect(panel.isFloatingPanel == true)
        #expect(panel.contentView is NSVisualEffectView)
        #expect(controller.searchFieldForTesting != nil)
        #expect(controller.tableViewForTesting?.numberOfRows == controller.rows.count)
        controller.dismiss()
        #expect(panel.isVisible == false)
    }

    @Test func searchFieldKeysDriveTheList() throws {
        let controller = CommandPaletteController(state: Self.state, mode: .sessions)
        controller.present(state: Self.state, over: nil)
        let field = try #require(controller.searchFieldForTesting)
        let editor = NSTextView()

        controller.updateQuery("main")
        let handled = controller.control(
            field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        #expect(handled)
        #expect(controller.selectedIndex == 1)

        var dismissed = false
        controller.onDismiss = { dismissed = true }
        #expect(controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(dismissed)
        // Anything else falls through to the field editor.
        #expect(!controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
    }
}
