// PromptCardTests — ⌥⌘P, the first-prompt / recap card (design 2c.5).
//
// The controller takes its data through two injected closures, so none of this touches a
// transcript on disk or a `ClaudeIntegration`; the panel is built lazily and sized headlessly,
// which is enough to assert what it shows, when it goes away, and that a late read for a row the
// card has since left is dropped.

import AppKit
import ClaudeBridge
import Foundation
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite("Prompt card", .serialized)
struct PromptCardTests {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func summary(prompt: String? = "Fix the build", recap: String? = "Build fixed. Next: ship.") -> TranscriptSummary {
        TranscriptSummary(
            firstPrompt: prompt, firstPromptAt: now.addingTimeInterval(-7200),
            recap: recap, recapAt: now.addingTimeInterval(-180), recapSource: .awaySummary,
            title: "Fixing the build")
    }

    // MARK: Strings

    @Test("Ages read the way the artboard writes them")
    func ages() {
        let now = Self.now
        #expect(PromptCardView.age(from: now.addingTimeInterval(-10), to: now) == "just now")
        #expect(PromptCardView.age(from: now.addingTimeInterval(-240), to: now) == "4 min ago")
        #expect(PromptCardView.age(from: now.addingTimeInterval(-7200), to: now) == "2 h ago")
        #expect(PromptCardView.age(from: now.addingTimeInterval(-100_000), to: now) == "yesterday")
        #expect(PromptCardView.age(from: now.addingTimeInterval(-3 * 86_400), to: now) == "3 d ago")
        #expect(PromptCardView.metaLine(startedAt: nil, now: now) == "")
        #expect(PromptCardView.metaLine(startedAt: now.addingTimeInterval(-7200), now: now).hasSuffix("2 h ago"))
    }

    @Test("The recap's meta line names its source honestly")
    func recapMeta() {
        var summary = Self.summary()
        #expect(PromptCardView.recapMetaLine(summary, now: Self.now) == "Claude\u{2019}s own summary \u{00B7} 3 min ago")
        summary.recapSource = .stopMessage
        #expect(PromptCardView.recapMetaLine(summary, now: Self.now).hasPrefix("Claude\u{2019}s last message"))
        summary.recapSource = .assistantText
        #expect(PromptCardView.recapMetaLine(summary, now: Self.now).hasPrefix("Claude\u{2019}s last reply"))
        summary.recapSource = nil
        #expect(PromptCardView.recapMetaLine(summary, now: Self.now).contains("updates as the session runs"))
    }

    // MARK: View

    @Test("The view renders the prompt in mono, the recap in the UI face, and empty states otherwise")
    func viewRenders() {
        let view = PromptCardView(theme: .default)
        #expect(view.promptTextViewForTesting.string == "Loading\u{2026}")
        #expect(view.copyPromptButtonForTesting.isEnabled == false)

        view.setSummary(Self.summary(), now: Self.now)
        #expect(view.promptTextViewForTesting.string == "Fix the build")
        #expect(view.recapTextViewForTesting.string == "Build fixed. Next: ship.")
        #expect(view.promptText == "Fix the build")
        #expect(view.recapText == "Build fixed. Next: ship.")
        #expect(view.copyPromptButtonForTesting.isEnabled)
        #expect(view.copyRecapButtonForTesting.isEnabled)
        #expect(view.promptMetaForTesting.hasSuffix("2 h ago"))
        let promptFont = view.promptTextViewForTesting.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(promptFont?.isFixedPitch == true)

        view.setSummary(TranscriptSummary(), now: Self.now)
        #expect(view.promptTextViewForTesting.string == "No prompt yet")
        #expect(view.recapTextViewForTesting.string == "No recap yet")
        #expect(view.copyPromptButtonForTesting.isEnabled == false)
        #expect(view.promptText == nil)
    }

    @Test("A long prompt scrolls: its block is capped, and the cap follows the window")
    func longPromptIsCapped() {
        let view = PromptCardView(theme: .default)
        let long = Array(repeating: "A line of a very long pasted specification.", count: 80).joined(separator: "\n")
        view.setSummary(TranscriptSummary(firstPrompt: long), now: Self.now)
        view.layoutSubtreeIfNeeded()
        let tall = view.fittingSize.height
        #expect(tall < PromptCardView.Metrics.defaultMaxTextHeight * 2 + 200)

        view.maxTextHeight = 88
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.height < tall)
        #expect(PromptCardController.maxTextHeight(for: NSRect(x: 0, y: 0, width: 900, height: 300)) == 90)
        #expect(PromptCardController.maxTextHeight(for: nil) == PromptCardView.Metrics.defaultMaxTextHeight)
    }

    // MARK: Controller

    @Test("Presenting builds the panel lazily, glass and floating, and renders the provider's summary")
    func presentBuildsThePanel() throws {
        let controller = PromptCardController(theme: .default)
        #expect(controller.panelForTesting == nil)
        let id = SessionID.generate()
        var asked: [SessionID] = []
        controller.summaryProvider = { id, done in
            asked.append(id)
            done(Self.summary())
        }

        controller.present(for: id, over: NSRect(x: 100, y: 100, width: 900, height: 600))
        let panel = try #require(controller.panelForTesting)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.isFloatingPanel)
        #expect(panel.contentView is NSVisualEffectView)
        #expect((panel.contentView as? NSVisualEffectView)?.blendingMode == .behindWindow)
        #expect(controller.isShown)
        #expect(controller.sessionID == id)
        #expect(asked == [id])
        #expect(controller.cardViewForTesting?.promptText == "Fix the build")
        // Top-centred over the anchor, 40 pt down.
        #expect(panel.frame.midX == 550)
        #expect(panel.frame.maxY == 660)
        #expect(panel.frame.width == PromptCardView.Metrics.width)
        #expect(panel.frame.height > 120, "a zero-height panel is an invisible one: \(panel.frame)")
        #expect(panel.isVisible)

        controller.dismiss()
        #expect(!controller.isShown)
        #expect(controller.sessionID == nil)
    }

    @Test("The chord toggles for the same row and re-targets for another")
    func toggleAndRetarget() throws {
        let controller = PromptCardController(theme: .default)
        controller.summaryProvider = { _, done in done(Self.summary()) }
        var dismissed = 0
        controller.onDismiss = { dismissed += 1 }
        let a = SessionID.generate(), b = SessionID.generate()

        controller.toggle(for: a, over: nil)
        #expect(controller.isShown && controller.sessionID == a)
        controller.toggle(for: b, over: nil)
        #expect(controller.isShown && controller.sessionID == b)
        #expect(dismissed == 0)
        controller.toggle(for: b, over: nil)
        #expect(!controller.isShown)
        #expect(dismissed == 1)
        // Dismissing twice is not two dismissals.
        controller.dismiss()
        #expect(dismissed == 1)
    }

    @Test("A read that lands after the card moved on is dropped")
    func staleReadIsDropped() throws {
        let controller = PromptCardController(theme: .default)
        var pending: [(SessionID, @MainActor @Sendable (TranscriptSummary) -> Void)] = []
        controller.summaryProvider = { id, done in pending.append((id, done)) }
        let a = SessionID.generate(), b = SessionID.generate()

        controller.present(for: a, over: nil)
        controller.present(for: b, over: nil)
        #expect(pending.count == 2)
        // A's read completes late, after B took over the card.
        pending[0].1(Self.summary(prompt: "A's prompt"))
        #expect(controller.cardViewForTesting?.promptText == nil, "A's late result must not be shown for B")
        pending[1].1(Self.summary(prompt: "B's prompt"))
        #expect(controller.cardViewForTesting?.promptText == "B's prompt")
        controller.dismiss()
    }

    @Test("Without a provider the card shows its empty states rather than loading forever")
    func noProvider() throws {
        let controller = PromptCardController(theme: .default)
        controller.present(for: .generate(), over: nil)
        #expect(controller.cardViewForTesting?.promptTextViewForTesting.string == "No prompt yet")
        controller.dismiss()
    }

    @Test("Escape on the panel dismisses; the transcript is watched only while the card is up")
    func escapeAndWatch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tkzmux-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let controller = PromptCardController(theme: .default)
        controller.summaryProvider = { _, done in done(Self.summary()) }
        controller.transcriptPathProvider = { _ in transcript.path }
        controller.present(for: .generate(), over: nil)
        #expect(controller.isWatchingForTesting)

        let panel = try #require(controller.panelForTesting as? PromptCardPanel)
        panel.cancelOperation(nil)
        #expect(!controller.isShown)
        #expect(!controller.isWatchingForTesting)
    }

    @Test("A write to the transcript re-reads it while the card is up")
    func transcriptChangeRefreshes() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tkzmux-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let controller = PromptCardController(theme: .default)
        var reads = 0
        controller.summaryProvider = { _, done in
            reads += 1
            done(Self.summary(recap: "recap \(reads)"))
        }
        controller.transcriptPathProvider = { _ in transcript.path }
        controller.present(for: .generate(), over: nil)
        #expect(reads == 1)

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"system\"}\n".utf8))
        try handle.close()

        let deadline = ContinuousClock.now + .seconds(2)
        while reads < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reads == 2)
        #expect(controller.cardViewForTesting?.recapText == "recap 2")
        controller.dismiss()
    }

    // MARK: Window controller

    @Test("Selecting another row closes the card, and the chord is wired to the dispatcher")
    func windowControllerClosesOnSelection() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let ids = harness.store.state.orderedGroups.flatMap { harness.store.state.sessions(in: $0.id) }.map(\.id)
        try #require(ids.count >= 2)
        harness.mutate { $0.select(ids[0]) }

        #expect(controller.dispatcher.canPerform(.showFirstPrompt))
        controller.toggleFirstPromptCard()
        #expect(controller.promptCard.isShown)
        #expect(controller.promptCard.sessionID == ids[0])

        harness.mutate { $0.select(ids[1]) }
        #expect(!controller.promptCard.isShown)
    }
}
