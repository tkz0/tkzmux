import AppKit
import Foundation
import Testing
import TkzCore

@testable import TkzApp

/// The results overlay's sections, chips and highlighting (TKZ-52, design 2c.6).
///
/// Everything here drives the controller through its plain methods — the transcript and
/// changed-file sections are injected as values, so none of it touches a transcript or a repo.
@MainActor
@Suite(.serialized)
struct SearchOverlayTests {

    static let state = AppState.fixture

    /// A controller already in the overlay's presentation, with a query typed.
    static func overlay(_ query: String = "m") -> CommandPaletteController {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.borderless], backing: .buffered, defer: true)
        let controller = CommandPaletteController(state: state, mode: .sessions)
        controller.present(anchoredTo: window, state: state)
        controller.updateQuery(query)
        return controller
    }

    static func transcriptRow(_ sessionID: SessionID, turn: Int, excerpt: String) -> TranscriptRow {
        let range = excerpt.range(of: "websocket") ?? excerpt.startIndex..<excerpt.startIndex
        return TranscriptRow(
            sessionID: sessionID, sessionTitle: "Fix websocket reconnect", turn: turn,
            kind: .assistant, excerpt: excerpt, matchRanges: [range], at: nil)
    }

    // MARK: Sections

    @Test func theOverlayHeadsEverySectionItShows() throws {
        let controller = Self.overlay()
        let headers = controller.rows.compactMap { row -> String? in
            if case .header(let title, _) = row { return title }
            return nil
        }
        // Unlike ⇧⌘P, a single section still gets its header — 2c.6 draws it.
        #expect(headers.contains("Sessions"))
    }

    @Test func lateTranscriptHitsJoinTheListUnderTheirOwnHeader() throws {
        let controller = Self.overlay()
        let session = try #require(controller.results.first?.item.sessionID)
        controller.setTranscriptRows([
            Self.transcriptRow(session, turn: 9, excerpt: "the websocket client drops the token")
        ])

        let header = try #require(
            controller.rows.compactMap { row -> (String, String?)? in
                if case .header(let title, let detail) = row, title == "Transcripts" {
                    return (title, detail)
                }
                return nil
            }.first)
        #expect(header.1 == "1 hit")
        #expect(controller.rows.contains { if case .transcript = $0 { return true }; return false })
    }

    @Test func aLateSectionDoesNotMoveTheSelection() throws {
        let controller = Self.overlay()
        let session = try #require(controller.results.first?.item.sessionID)
        controller.moveSelection(by: 1)
        let selected = try #require(controller.selectedResult?.item.sessionID)

        controller.setTranscriptRows([Self.transcriptRow(session, turn: 1, excerpt: "websocket")])
        #expect(
            controller.selectedResult?.item.sessionID == selected,
            "results that arrive while the user is arrowing must not yank the selection")
    }

    @Test func aNewQueryDropsTheSectionsTheOldOneProduced() throws {
        let controller = Self.overlay()
        let session = try #require(controller.results.first?.item.sessionID)
        controller.setTranscriptRows([Self.transcriptRow(session, turn: 1, excerpt: "websocket")])
        #expect(!controller.transcriptRows.isEmpty)

        controller.updateQuery("ma")
        #expect(controller.transcriptRows.isEmpty, "stale hits must not survive a keystroke")
    }

    // MARK: Truncation

    @Test func aLongSectionTruncatesWithAShowMoreRow() throws {
        let controller = Self.overlay()
        let session = try #require(controller.results.first?.item.sessionID)
        controller.setTranscriptRows(
            (1...7).map { Self.transcriptRow(session, turn: $0, excerpt: "websocket \($0)") })

        let shown = controller.rows.filter { if case .transcript = $0 { return true }; return false }
        #expect(shown.count == CommandPaletteController.sectionPreviewLimit)
        let more = try #require(
            controller.rows.compactMap { row -> Int? in
                if case .more(.transcripts, let remaining) = row { return remaining }
                return nil
            }.first)
        #expect(more == 4, "2c.6's 'Show 4 more…' — seven hits, three shown")
    }

    @Test func showMoreExpandsInPlaceRatherThanNavigating() throws {
        let controller = Self.overlay()
        let session = try #require(controller.results.first?.item.sessionID)
        controller.setTranscriptRows(
            (1...7).map { Self.transcriptRow(session, turn: $0, excerpt: "websocket \($0)") })
        var activated = 0
        var dismissed = 0
        controller.onActivate = { _ in activated += 1 }
        controller.onDismiss = { dismissed += 1 }

        // Arrow down until the "Show 4 more…" row is the selection — headers are skipped, so the
        // raw index is not the number of key presses.
        var reached = false
        for _ in 0..<controller.rows.count {
            if case .showMore(.transcripts) = controller.selectedActivation {
                reached = true
                break
            }
            controller.moveSelection(by: 1)
        }
        #expect(reached, "↓ must reach the transcripts' Show-more row")
        controller.activateSelection()

        #expect(activated == 0, "expanding is not a destination")
        #expect(dismissed == 0, "and it must not close the overlay")
        let shown = controller.rows.filter { if case .transcript = $0 { return true }; return false }
        #expect(shown.count == 7)
    }

    // MARK: Chips

    @Test func tabCyclesTheChipsAndWrapsAround() {
        let controller = Self.overlay()
        #expect(controller.scope == .all)
        controller.cycleScope(by: 1)
        #expect(controller.scope == .sessions)
        controller.cycleScope(by: 1)
        #expect(controller.scope == .transcripts)
        controller.cycleScope(by: 1)
        #expect(controller.scope == .filesChanged)
        controller.cycleScope(by: 1)
        #expect(controller.scope == .all, "four chips read as a ring")
        controller.cycleScope(by: -1)
        #expect(controller.scope == .filesChanged)
    }

    @Test func narrowingTheScopeDropsTheOtherSections() throws {
        let controller = Self.overlay()
        let session = try #require(controller.results.first?.item.sessionID)
        controller.setTranscriptRows([Self.transcriptRow(session, turn: 1, excerpt: "websocket")])

        controller.setScope(.transcripts)
        #expect(!controller.rows.contains { $0.result != nil }, "no session rows under Transcripts")
        #expect(controller.rows.contains { if case .transcript = $0 { return true }; return false })

        controller.setScope(.sessions)
        #expect(!controller.rows.contains { if case .transcript = $0 { return true }; return false })
        #expect(controller.rows.contains { $0.result != nil })
    }

    @Test func narrowingToOneChipShowsThatSectionInFull() throws {
        let controller = Self.overlay()
        let session = try #require(controller.results.first?.item.sessionID)
        controller.setTranscriptRows(
            (1...7).map { Self.transcriptRow(session, turn: $0, excerpt: "websocket \($0)") })
        controller.setScope(.transcripts)

        let shown = controller.rows.filter { if case .transcript = $0 { return true }; return false }
        #expect(shown.count == 7)
        #expect(!controller.rows.contains { if case .more = $0 { return true }; return false })
    }

    @Test func theGroupFilterKeepsOnlyThatGroupsSessions() throws {
        let controller = Self.overlay("")
        controller.setScope(.sessions)
        let groupID = try #require(Self.state.orderedGroups.first?.id)
        controller.setGroupFilter(.group(groupID))

        let sessions = controller.rows.compactMap(\.result)
        #expect(!sessions.isEmpty)
        #expect(sessions.allSatisfy { $0.item.groupID == groupID })
    }

    // MARK: Actions

    @Test func theActionsRowOffersANewSessionWithWhatWasTyped() throws {
        let controller = Self.overlay("websocket")
        let action = try #require(
            controller.rows.compactMap { row -> SearchAction? in
                if case .action(let a) = row { return a }
                return nil
            }.first)

        #expect(action.prompt == "websocket")
        #expect(action.title.hasPrefix("\u{FF0B} New session in "))
        #expect(action.title.contains("with prompt \u{201C}websocket\u{201D}"))
        #expect(action.trailing == "\u{2318}\u{21A9}")
    }

    @Test func aLongPromptIsElidedInTheActionsRow() throws {
        let query = String(repeating: "websocket ", count: 6)
        let controller = Self.overlay(query)
        let action = try #require(
            controller.rows.compactMap { row -> SearchAction? in
                if case .action(let a) = row { return a }
                return nil
            }.first)
        #expect(action.title.contains("\u{2026}\u{201D}"))
        #expect(action.prompt == query.trimmingCharacters(in: .whitespaces), "the launch keeps it all")
    }

    @Test func commandReturnRunsTheActionWhateverIsSelected() throws {
        let controller = Self.overlay("websocket")
        var activated: PaletteActivation?
        controller.onActivate = { activated = $0 }

        #expect(controller.activateActionRow())
        guard case .action(let action) = activated else {
            Issue.record("⌘↵ must activate the Actions row")
            return
        }
        #expect(action.prompt == "websocket")
    }

    @Test func anEmptyQueryHasNoActionsRow() {
        let controller = Self.overlay("")
        #expect(!controller.rows.contains { if case .action = $0 { return true }; return false })
    }

    // MARK: Highlighting

    @Test func theMatchedCharactersAreMarkedInTheThemesAmber() throws {
        let controller = Self.overlay("docs")
        controller.setScope(.sessions)
        let result = try #require(controller.results.first { $0.item.title.contains("docs") })
        let title = SearchSessionRowView.titleString(result, theme: .default)

        var marked = ""
        title.enumerateAttribute(
            .backgroundColor, in: NSRange(location: 0, length: title.length)
        ) { value, range, _ in
            if let color = value as? NSColor, color == Theme.default.searchMatchBackground.nsColor {
                marked += (title.string as NSString).substring(with: range)
            }
        }
        #expect(marked.lowercased() == "docs")
    }

    @Test func aTranscriptExcerptCarriesItsKindGlyphAndKeepsTheMatchAligned() throws {
        let excerpt = "the websocket client drops the token"
        let range = try #require(excerpt.range(of: "websocket"))
        let hit = TranscriptRow(
            sessionID: SessionID(uuid: UUID()), sessionTitle: "Fix reconnect", turn: 9,
            kind: .assistant, excerpt: excerpt, matchRanges: [range], at: nil)

        let string = SearchTranscriptRowView.excerptString(hit, theme: .default)
        #expect(string.string.hasPrefix("\u{2733} "), "✳ marks an assistant line")

        var marked = ""
        string.enumerateAttribute(
            .backgroundColor, in: NSRange(location: 0, length: string.length)
        ) { value, range, _ in
            if let color = value as? NSColor, color == Theme.default.searchMatchBackground.nsColor {
                marked += (string.string as NSString).substring(with: range)
            }
        }
        #expect(marked == "websocket", "the glyph prefix must shift the highlight, not break it")
    }

    @Test func theTrailerReadsAsTurnAndAge() {
        let now = Date()
        let hit = TranscriptRow(
            sessionID: SessionID(uuid: UUID()), sessionTitle: "s", turn: 9, kind: .user,
            excerpt: "x", matchRanges: [], at: now.addingTimeInterval(-3600))
        #expect(SearchTranscriptRowView.trailingText(hit, now: now) == "turn 9 \u{00B7} 1h")

        let undated = TranscriptRow(
            sessionID: SessionID(uuid: UUID()), sessionTitle: "s", turn: 2, kind: .tool,
            excerpt: "x", matchRanges: [], at: nil)
        #expect(SearchTranscriptRowView.trailingText(undated, now: now) == "turn 2")
    }

    @Test func theKindGlyphsAreTheDesignsThree() {
        #expect(TranscriptRow.Kind.user.glyph == ">")
        #expect(TranscriptRow.Kind.assistant.glyph == "\u{2733}")
        #expect(TranscriptRow.Kind.tool.glyph == "\u{25CF}")
    }

    // MARK: Row layout (GUI pass 2026-09-11)

    /// A wrapping label inside a 28 pt row draws over the row below it. Every label in every row
    /// view has to be single-line, and an attributed string carries no paragraph style to make it
    /// so — hence the explicit `usesSingleLineMode`.
    @Test func everyRowIsOneLineHoweverLongItsTextIs() throws {
        let long = String(repeating: "LatestUnitPrice, FundManager, InvestmentManager, ", count: 6)
        let session = SessionID(uuid: UUID())

        let transcript = SearchTranscriptRowView(
            hit: TranscriptRow(
                sessionID: session, sessionTitle: String(repeating: "a very long title ", count: 5),
                turn: 5, kind: .assistant, excerpt: long, matchRanges: [], at: Date()),
            theme: .default)
        let file = SearchFileRowView(
            hit: FileRow(
                sessionID: session, sessionTitle: "workamo-app",
                path: "workamo-web/src/pages/Dashboard/pages/AdminCloseInvoices/MatchingSettings/x.tsx",
                status: "?", matchRanges: []),
            theme: .default)
        let action = SearchActionRowView(
            action: SearchAction(
                kind: .newSessionWithPrompt, title: long, trailing: "\u{2318}\u{21A9}",
                groupID: nil, prompt: "x"),
            theme: .default)

        for row in [transcript, file, action] {
            let labels = row.subviews.compactMap { $0 as? NSTextField }
            #expect(!labels.isEmpty)
            for label in labels {
                #expect(label.maximumNumberOfLines == 1, "\(type(of: row)) has a wrapping label")
                #expect(label.cell?.wraps == false)
            }
        }
    }

    @Test func aRowIsNoTallerThanTheHeightTheTableGivesIt() {
        let session = SessionID(uuid: UUID())
        let hit = TranscriptRow(
            sessionID: session, sessionTitle: "s", turn: 1, kind: .user,
            excerpt: String(repeating: "x ", count: 400), matchRanges: [], at: nil)
        let row = SearchTranscriptRowView(hit: hit, theme: .default)
        row.frame = NSRect(x: 0, y: 0, width: 560, height: 28)
        row.layoutSubtreeIfNeeded()

        let allotted = CommandPaletteController.height(
            of: .transcript(hit), presentation: .anchored)
        for label in row.subviews.compactMap({ $0 as? NSTextField }) {
            #expect(label.frame.height <= allotted, "a label taller than its row overdraws the next")
        }
    }
}
