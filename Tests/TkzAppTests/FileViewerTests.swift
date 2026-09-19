// ⌘-click file tabs: resolving a printed path, the tab bookkeeping, loading and Markdown rendering.

import AppKit
import Foundation
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct FileViewerTests {

    private static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkz-fileviewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("docs"), withIntermediateDirectories: true)
        return url
    }

    // MARK: Resolving

    @Test func resolvesAgainstTheFirstBaseThatHasTheFile() throws {
        let root = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("docs/design.md")
        try Data("# Hi".utf8).write(to: file)

        let resolved = FilePathResolver.resolve(
            "docs/design.md", bases: ["/nonexistent-base", root.path], home: "/Users/nobody")
        #expect(resolved?.standardizedFileURL.path == file.standardizedFileURL.path)
    }

    @Test func triesGitDiffPrefixesAndRefusesDirectories() throws {
        let root = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("docs/a.txt"))

        #expect(FilePathResolver.resolve("b/docs/a.txt", bases: [root.path], home: "/") != nil)
        #expect(FilePathResolver.resolve("docs", bases: [root.path], home: "/") == nil)
        #expect(FilePathResolver.resolve("docs/missing.md", bases: [root.path], home: "/") == nil)
    }

    @Test func basesPutThePaneDirectoryFirstAndHaveNoDuplicates() {
        let session = Session(
            groupID: GroupID.generate(), cwd: "/repo", repoRoot: "/repo",
            worktreePath: "/repo/.claude/worktrees/w", isWorktree: true, accountKey: "k")
        let bases = FilePathResolver.bases(for: session.focusedTerminalID, in: session)
        #expect(bases.first == "/repo")
        #expect(bases.contains("/repo/.claude/worktrees/w"))
        #expect(Set(bases).count == bases.count)
    }

    // TKZ-79: `Session.worktreeRoot(ofPath:)` now delegates to `agent.worktreeMarker`, which is
    // `nil` for every agent but Claude. `bases(for:in:)` calls it on the pane's own directory, so
    // a Codex row whose pane happens to sit under a path that looks like `/.claude/worktrees/…`
    // (e.g. a Claude worktree Codex was pointed at by hand) must not have that path added as an
    // extra base — Codex has no worktree convention of its own to detect.
    @Test func paneDirectoryWorktreeDetectionOnlyAppliesToAgentsWithAMarker() {
        let claudeSession = Session(
            groupID: GroupID.generate(), cwd: "/repo/.claude/worktrees/w/sub", repoRoot: "/repo",
            agent: .claude, accountKey: "claude")
        let claudeBases = FilePathResolver.bases(for: claudeSession.focusedTerminalID, in: claudeSession)
        #expect(claudeBases.contains("/repo/.claude/worktrees/w"))

        let codexSession = Session(
            groupID: GroupID.generate(), cwd: "/repo/.claude/worktrees/w/sub", repoRoot: "/repo",
            agent: .codex, accountKey: "codex")
        let codexBases = FilePathResolver.bases(for: codexSession.focusedTerminalID, in: codexSession)
        #expect(!codexBases.contains("/repo/.claude/worktrees/w"))
    }

    // MARK: Tabs

    @Test func openingTheSameFileTwiceSelectsItsTab() {
        var tabs = FileTabs()
        tabs.open(URL(fileURLWithPath: "/a.md"))
        tabs.open(URL(fileURLWithPath: "/b.md"))
        tabs.open(URL(fileURLWithPath: "/a.md"))
        #expect(tabs.files.count == 2)
        #expect(tabs.activeIndex == 0)
    }

    @Test func closingTheActiveTabShowsItsNeighbourThenTheTerminal() {
        var tabs = FileTabs()
        tabs.open(URL(fileURLWithPath: "/a.md"))
        tabs.open(URL(fileURLWithPath: "/b.md"))
        tabs.close(1)
        #expect(tabs.activeFile?.path == "/a.md")
        tabs.close(0)
        #expect(tabs.activeIndex == nil)
        #expect(tabs.isEmpty)
    }

    @Test func closingAnEarlierTabKeepsTheActiveFile() {
        var tabs = FileTabs()
        tabs.open(URL(fileURLWithPath: "/a.md"))
        tabs.open(URL(fileURLWithPath: "/b.md"))
        tabs.close(0)
        #expect(tabs.activeFile?.path == "/b.md")
    }

    @Test func closeActiveOnlyActsWhileAFileIsOnScreen() {
        var tabs = FileTabs()
        #expect(tabs.closeActive() == false)

        tabs.open(URL(fileURLWithPath: "/a.md"))
        tabs.open(URL(fileURLWithPath: "/b.md"))
        #expect(tabs.closeActive() == true)
        #expect(tabs.activeFile?.path == "/a.md")

        // A terminal tab is showing: ⌘W is the row's business again, not the strip's.
        tabs.deselect()
        #expect(tabs.closeActive() == false)
        #expect(tabs.files.count == 1)
    }

    @Test func theStripListsFileTabsAfterTerminalTabs() {
        let session = Session(groupID: GroupID.generate(), cwd: "/repo", accountKey: "k")
        var tabs = FileTabs()
        #expect(tabs.stripModel(for: session).isVisible == false)

        tabs.open(URL(fileURLWithPath: "/repo/README.md"))
        let model = tabs.stripModel(for: session)
        #expect(model.items.map(\.title) == ["Terminal 1", "README.md"])
        #expect(model.selectedIndex == 1)
        #expect(TabStripTarget.at(1, terminalTabCount: 1) == .file(0))
        #expect(TabStripTarget.at(0, terminalTabCount: 1) == .terminal(0))

        tabs.deselect()
        #expect(tabs.stripModel(for: session).selectedIndex == 0)
    }

    // MARK: Loading

    @Test func markdownIsRecognisedAndBinaryIsDeclined() throws {
        let root = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("notes.MD")
        let code = root.appendingPathComponent("main.swift")
        let binary = root.appendingPathComponent("blob.bin")
        try Data("# Title".utf8).write(to: markdown)
        try Data("let x = 1".utf8).write(to: code)
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: binary)

        #expect(FileViewerLoader.load(markdown) == .markdown("# Title"))
        #expect(FileViewerLoader.load(code) == .text("let x = 1"))
        guard case .notice = FileViewerLoader.load(binary) else {
            Issue.record("a binary file must not be shown as text")
            return
        }
    }

    // MARK: Markdown

    private static func font(at substring: String, in rendered: NSAttributedString) -> NSFont? {
        let range = (rendered.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }

    @Test func headingsAreLargerAndBlocksAreOnTheirOwnLines() {
        let rendered = MarkdownRenderer.render(
            "# Title\n\nFirst paragraph.\n\nSecond paragraph.", theme: .default)
        #expect(rendered.string == "Title\nFirst paragraph.\nSecond paragraph.")
        let title = Self.font(at: "Title", in: rendered)
        let body = Self.font(at: "First", in: rendered)
        #expect((title?.pointSize ?? 0) > (body?.pointSize ?? 0))
    }

    @Test func listsGetMarkersAndInlineStylesApply() {
        let rendered = MarkdownRenderer.render(
            "- one **bold**\n- two `code`\n\n1. first\n2. second", theme: .default)
        let text = rendered.string
        #expect(text.contains("\u{2022}\tone bold"))
        #expect(text.contains("\u{2022}\ttwo code"))
        #expect(text.contains("1.\tfirst"))
        #expect(text.contains("2.\tsecond"))

        let bold = Self.font(at: "bold", in: rendered)
        #expect(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let code = Self.font(at: "code", in: rendered)
        #expect(code?.isFixedPitch == true)
    }

    @Test func codeBlocksKeepTheirLinesInAMonospacedFace() {
        let rendered = MarkdownRenderer.render(
            "Before\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nAfter", theme: .default)
        #expect(rendered.string == "Before\nlet a = 1\nlet b = 2\nAfter")
        #expect(Self.font(at: "let b", in: rendered)?.isFixedPitch == true)
    }
}
