// LayoutTokensTests — WOR-307 S5. The Linux half of "the Mac lays its views out exactly as it did
// before the inline Auto Layout constants became tokens", checked from source like
// `DesignTokensTests` and `TypographyTokensTests`:
//
//   1. `pins` holds every S5 token to the literal it replaced (`git show 8e9c003:<file>`), bit for
//      bit, with its snapping kind.
//   2. `files` lists every migrated line as it read before the move, with the token that replaced
//      its literal. The test rebuilds the new line from it (the literal swapped for
//      `CGFloat(LayoutTokens.<path>.value)`, signed as the literal was) and requires that line in
//      the file exactly `count` times and the old one gone, so each site differs from the old one in
//      the literal alone, and that literal equals the token's value.
//   3. The S5 grep (`constant: -?[0-9]|equalToConstant: [0-9]` over `Sources/TkzApp`) finds
//      nothing outside `// token-exempt: <reason>` lines, and those are the two zero placeholders.
//
// `-CGFloat(v)` is exactly the literal `-v` and `CGFloat(v)` exactly `v` (`CGFloat` is a `Double`),
// so a site that passes 2 hands AppKit the constant it had. The goldens remain the Mac-side check.

import Foundation
import Testing

@testable import TkzCore

@Suite struct LayoutTokensTests {
    typealias M = DesignTokens.Metrics

    /// An S5 token, the literal its sites held before the move, and its snapping kind.
    struct Pin: Sendable, CustomTestStringConvertible {
        let token: DesignToken
        let literal: Double
        let snap: DesignToken.Snap
        init(_ token: DesignToken, _ literal: Double, _ snap: DesignToken.Snap) {
            self.token = token
            self.literal = literal
            self.snap = snap
        }
        var testDescription: String { token.name }
    }

    /// Copied from the sources before the move. Never edit a literal here to make a test pass: a
    /// different number is a Mac-visible change.
    static let pins: [Pin] = [
        Pin(M.HeaderBackdrop.bottomBorder, 1, .stroke),
        Pin(M.ActivityFeed.fieldInset, 14, .points),
        Pin(M.ActivityFeed.fieldToList, 10, .points),
        Pin(M.ActivityFeed.listInset, 6, .points),
        Pin(M.ActivityRow.pillPaddingX, 4.5, .points),
        Pin(M.ActivityRow.pillPaddingY, 1, .points),
        Pin(M.ActivityRow.insetX, 12, .points),
        Pin(M.ActivityRow.gap, 9, .points),
        Pin(M.ActivityRow.dotSize, 10, .mark),
        Pin(M.ActivityRow.threadTop, 6, .points),
        Pin(M.ActivityRow.previewGap, 3, .points),
        Pin(M.ActivityRow.previewBottomInset, 4, .points),
        Pin(M.ActivityRow.olderTrailingInset, 10, .points),
        Pin(M.ActivityRow.olderBottomInset, 5, .points),
        Pin(M.ActivityRow.foldedIndent, 28, .points),
        Pin(M.Palette.fieldInset, 14, .points),
        Pin(M.Palette.fieldToList, 10, .points),
        Pin(M.Palette.fieldToChips, 8, .points),
        Pin(M.Palette.chipsToList, 2, .points),
        Pin(M.Palette.listInset, 6, .points),
        Pin(M.Palette.listBottomInset, 8, .points),
        Pin(M.Palette.labelTrailingInset, 8, .points),
        Pin(M.PaletteRow.insetX, 12, .points),
        Pin(M.PaletteRow.titleTop, 4, .points),
        Pin(M.PaletteRow.subtitleGap, 2, .points),
        Pin(M.PaletteRow.trailingGap, 8, .points),
        Pin(M.SearchRow.insetX, 12, .points),
        Pin(M.SearchRow.gap, 9, .points),
        Pin(M.SearchRow.sessionColumnWidth, 150, .points),
        Pin(M.SearchRow.chipBarMinGap, 8, .points),
        Pin(M.FileViewer.headerInsetX, 12, .points),
        Pin(M.FileViewer.headerGap, 12, .points),
        Pin(M.FileViewer.headerBorder, 1, .stroke),
        Pin(M.RebaseSheet.titleShortcutGap, 10, .points),
        Pin(M.RebaseSheet.titleToBody, 6, .points),
        Pin(M.RebaseSheet.bodyToButtons, 14, .points),
        Pin(M.DeleteWorktreeSheet.titleToBody, 7, .points),
        Pin(M.DeleteWorktreeSheet.bodyToButtons, 14, .points),
        Pin(M.GlassSheet.buttonSpacing, 8, .points),
        Pin(M.DeleteMergedSheet.titleToBody, 6, .points),
        Pin(M.DeleteMergedSheet.bodyToList, 10, .points),
        Pin(M.DeleteMergedSheet.listToButtons, 12, .points),
        Pin(M.PromptCard.pillMetaGap, 8, .points),
        Pin(M.PromptCard.metaHintGap, 8, .points),
        Pin(M.PromptCard.dividerGap, 14, .points),
        Pin(M.PromptCard.dividerThickness, 1, .stroke),
        Pin(M.PromptCard.recapTextGap, 6, .points),
        Pin(M.PromptCard.recapToButtons, 14, .points),
        Pin(M.PromptCard.buttonSpacing, 8, .points),
        Pin(M.Changes.headerInsetX, 14, .points),
        Pin(M.Changes.headerMinGap, 12, .points),
        Pin(M.Changes.viewOnlyWidth, 62, .points),
        Pin(M.Changes.headerBorder, 1, .stroke),
        Pin(M.Settings.navBorder, 1, .stroke),
        Pin(M.Settings.navTop, 12, .points),
        Pin(M.Settings.shortcutTop, 8, .points),
        Pin(M.Settings.shortcutTrailing, 14, .points),
        Pin(M.Settings.navRowInsetX, 10, .points),
        Pin(M.Settings.navGlyphWidth, 16, .mark),
        Pin(M.Settings.navGlyphGap, 9, .points),
        Pin(M.Settings.rowSeparator, 1, .stroke),
        Pin(M.Settings.captionIndent, 2, .points),
        Pin(M.Settings.captionGap, 7, .points),
        Pin(M.Settings.rowDetailGap, 2, .points),
        Pin(M.Settings.statusDot, 7, .mark),
        Pin(M.Settings.statusDotGap, 6, .points),
    ]

    /// One migrated line, trimmed, as it read before the move; the token that replaced its literal;
    /// how many identical lines the file had.
    struct Site: Sendable {
        let old: String
        let token: DesignToken
        let count: Int
        init(_ old: String, _ token: DesignToken, count: Int = 1) {
            self.old = old
            self.token = token
            self.count = count
        }
    }

    /// The migrated lines of one file under `Sources/TkzApp`.
    struct File: Sendable, CustomTestStringConvertible {
        let path: String
        let sites: [Site]
        init(_ path: String, _ sites: [Site]) {
            self.path = path
            self.sites = sites
        }
        var testDescription: String { path }
    }

    static let files: [File] = [
        File("Activity/ActivityFeedController.swift", [
            Site("field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),", M.ActivityFeed.fieldInset),
            Site("field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),", M.ActivityFeed.fieldInset),
            Site("field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),", M.ActivityFeed.fieldInset),
            Site("scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),", M.ActivityFeed.fieldToList),
            Site("scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),", M.ActivityFeed.listInset),
            Site("scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),", M.ActivityFeed.listInset),
        ]),
        File("Activity/ActivityRowViews.swift", [
            Site("label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4.5),", M.ActivityRow.pillPaddingX),
            Site("label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4.5),", M.ActivityRow.pillPaddingX),
            Site("label.topAnchor.constraint(equalTo: topAnchor, constant: 1),", M.ActivityRow.pillPaddingY),
            Site("label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),", M.ActivityRow.pillPaddingY),
            Site("dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),", M.ActivityRow.insetX),
            Site("dot.widthAnchor.constraint(equalToConstant: 10),", M.ActivityRow.dotSize),
            Site("dot.heightAnchor.constraint(equalToConstant: 10),", M.ActivityRow.dotSize),
            Site("title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),", M.ActivityRow.gap),
            Site("group.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 9),", M.ActivityRow.gap),
            Site("group.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -9),", M.ActivityRow.gap),
            Site("trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),", M.ActivityRow.insetX, count: 2),
            Site("title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),", M.ActivityRow.insetX),
            Site("title.topAnchor.constraint(equalTo: topAnchor, constant: 6),", M.ActivityRow.threadTop),
            Site("meta.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 9),", M.ActivityRow.gap),
            Site("meta.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -9),", M.ActivityRow.gap),
            Site("pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),", M.ActivityRow.insetX),
            Site("preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),", M.ActivityRow.insetX),
            Site("preview.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),", M.ActivityRow.previewGap),
            Site("preview.trailingAnchor.constraint(lessThanOrEqualTo: olderButton.leadingAnchor, constant: -9),", M.ActivityRow.gap),
            Site("preview.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),", M.ActivityRow.previewBottomInset),
            Site("olderButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),", M.ActivityRow.olderTrailingInset),
            Site("olderButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),", M.ActivityRow.olderBottomInset),
            Site("pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),", M.ActivityRow.foldedIndent),
            Site("preview.leadingAnchor.constraint(equalTo: pill.trailingAnchor, constant: 9),", M.ActivityRow.gap),
            Site("preview.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -9),", M.ActivityRow.gap),
            Site("label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),", M.ActivityRow.insetX, count: 2),
        ]),
        File("Changes/ChangesViewerView.swift", [
            Site("leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),", M.Changes.headerInsetX),
            Site("trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),", M.Changes.headerInsetX),
            Site("trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12),",
                 M.Changes.headerMinGap),
            Site("viewOnly.widthAnchor.constraint(equalToConstant: 62),", M.Changes.viewOnlyWidth),
            Site("bottomBorder.heightAnchor.constraint(equalToConstant: 1),", M.Changes.headerBorder),
        ]),
        File("ChromeViewController.swift", [
            Site("border.heightAnchor.constraint(equalToConstant: 1),", M.HeaderBackdrop.bottomBorder),
        ]),
        File("FileViewer/FileViewerView.swift", [
            Site("pathLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),", M.FileViewer.headerInsetX),
            Site("pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: readOnlyLabel.leadingAnchor, constant: -12),",
                 M.FileViewer.headerGap),
            Site("readOnlyLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),", M.FileViewer.headerInsetX),
            Site("headerBorder.heightAnchor.constraint(equalToConstant: 1),", M.FileViewer.headerBorder),
        ]),
        File("Palette/CommandPaletteController.swift", [
            Site("let scrollTopToField = scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10)",
                 M.Palette.fieldToList),
            Site("let scrollTopToChips = scroll.topAnchor.constraint(equalTo: chips.bottomAnchor, constant: 2)",
                 M.Palette.chipsToList),
            Site("let scrollBottomToEffect = scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8)",
                 M.Palette.listBottomInset),
            Site("let chipsTopToField = chips.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8)", M.Palette.fieldToChips),
            Site("field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),", M.Palette.fieldInset),
            Site("field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),", M.Palette.fieldInset),
            Site("field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),", M.Palette.fieldInset),
            Site("scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),", M.Palette.listInset),
            Site("scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),", M.Palette.listInset),
            Site("view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),",
                 M.Palette.labelTrailingInset),
            Site("title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),", M.PaletteRow.insetX),
            Site("title.topAnchor.constraint(equalTo: topAnchor, constant: 4),", M.PaletteRow.titleTop),
            Site("title.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),",
                 M.PaletteRow.trailingGap),
            Site("subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),", M.PaletteRow.subtitleGap),
            Site("subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),",
                 M.PaletteRow.trailingGap),
            Site("trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),", M.PaletteRow.insetX),
        ]),
        File("Palette/SearchRowViews.swift", [
            Site("view.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 9).isActive = true", M.SearchRow.gap),
            Site("trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12).isActive = true", M.SearchRow.insetX),
            Site("session.widthAnchor.constraint(equalToConstant: 150).isActive = true", M.SearchRow.sessionColumnWidth, count: 2),
            Site("stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),", M.SearchRow.insetX),
            Site("filterLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),", M.SearchRow.insetX),
            Site("greaterThanOrEqualTo: stack.trailingAnchor, constant: 8),", M.SearchRow.chipBarMinGap),
            Site("label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),", M.SearchRow.insetX),
        ]),
        File("Prompt/PromptCardView.swift", [
            Site("promptMeta.leadingAnchor.constraint(equalTo: promptPill.trailingAnchor, constant: 8),", M.PromptCard.pillMetaGap),
            Site("promptMeta.trailingAnchor.constraint(lessThanOrEqualTo: closeHint.leadingAnchor, constant: -8),",
                 M.PromptCard.metaHintGap),
            Site("divider.topAnchor.constraint(equalTo: promptScroll.bottomAnchor, constant: 14),", M.PromptCard.dividerGap),
            Site("divider.heightAnchor.constraint(equalToConstant: 1),", M.PromptCard.dividerThickness),
            Site("recapMeta.leadingAnchor.constraint(equalTo: recapPill.trailingAnchor, constant: 8),", M.PromptCard.pillMetaGap),
            Site("recapScroll.topAnchor.constraint(equalTo: recapPill.bottomAnchor, constant: 6),", M.PromptCard.recapTextGap),
            Site("copyPromptButton.topAnchor.constraint(equalTo: recapScroll.bottomAnchor, constant: 14),",
                 M.PromptCard.recapToButtons),
            Site("copyRecapButton.leadingAnchor.constraint(equalTo: copyPromptButton.trailingAnchor, constant: 8),",
                 M.PromptCard.buttonSpacing),
        ]),
        File("Rebase/RebaseSheetView.swift", [
            Site("shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),",
                 M.RebaseSheet.titleShortcutGap),
            Site("bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),", M.RebaseSheet.titleToBody),
            Site("rebaseButton.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 14),", M.RebaseSheet.bodyToButtons),
            Site("cancelButton.trailingAnchor.constraint(equalTo: rebaseButton.leadingAnchor, constant: -8),",
                 M.GlassSheet.buttonSpacing),
        ]),
        File("Settings/SettingsView.swift", [
            Site("navBorder.widthAnchor.constraint(equalToConstant: 1),", M.Settings.navBorder),
            Site("navStack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),", M.Settings.navTop),
            Site("shortcutLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),", M.Settings.shortcutTop),
            Site("shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),", M.Settings.shortcutTrailing),
            Site("glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),", M.Settings.navRowInsetX),
            Site("glyph.widthAnchor.constraint(equalToConstant: 16),", M.Settings.navGlyphWidth),
            Site("title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 9),", M.Settings.navGlyphGap),
            Site("title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),", M.Settings.navRowInsetX),
            Site("line.heightAnchor.constraint(equalToConstant: 1).isActive = true", M.Settings.rowSeparator),
            Site("caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),", M.Settings.captionIndent),
            Site("card.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 7),", M.Settings.captionGap),
            Site("detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),", M.Settings.rowDetailGap),
            Site("dot.widthAnchor.constraint(equalToConstant: 7),", M.Settings.statusDot),
            Site("dot.heightAnchor.constraint(equalToConstant: 7),", M.Settings.statusDot),
            Site("label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),", M.Settings.statusDotGap),
        ]),
        File("Worktree/DeleteMergedWorktreesSheetView.swift", [
            Site("bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),", M.DeleteMergedSheet.titleToBody),
            Site("scroll.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 10),", M.DeleteMergedSheet.bodyToList),
            Site("deleteButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),", M.DeleteMergedSheet.listToButtons),
            Site("cancelButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),",
                 M.GlassSheet.buttonSpacing),
        ]),
        File("Worktree/DeleteWorktreeSheetView.swift", [
            Site("body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),", M.DeleteWorktreeSheet.titleToBody),
            Site("deleteButton.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 14),", M.DeleteWorktreeSheet.bodyToButtons),
            Site("deleteBranchButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),",
                 M.GlassSheet.buttonSpacing),
            Site("equalTo: deleteBranchButton.leadingAnchor, constant: -8)", M.GlassSheet.buttonSpacing),
            Site("equalTo: deleteButton.leadingAnchor, constant: -8)", M.GlassSheet.buttonSpacing),
        ]),
    ]

    /// Files that spell the namespace out instead of declaring the `LayoutTokens` alias (one site).
    static let unaliased: Set<String> = ["ChromeViewController.swift"]

    static let alias = "private typealias LayoutTokens = DesignTokens.Metrics"

    /// The issue's per-file counts of `constant: -?[0-9]|equalToConstant: [0-9]` before the move,
    /// exemptions included.
    static let issueCounts: [String: Int] = [
        "Activity/ActivityRowViews.swift": 28, "Palette/CommandPaletteController.swift": 16,
        "Settings/SettingsView.swift": 15, "Prompt/PromptCardView.swift": 8, "Palette/SearchRowViews.swift": 8,
        "Activity/ActivityFeedController.swift": 6, "Worktree/DeleteWorktreeSheetView.swift": 5,
        "Worktree/DeleteMergedWorktreesSheetView.swift": 5, "Changes/ChangesViewerView.swift": 5,
        "Rebase/RebaseSheetView.swift": 4, "FileViewer/FileViewerView.swift": 4,
        "MainWindowController.swift": 1, "ChromeViewController.swift": 1,
    ]

    /// The two literals left in place, each a zero the code overwrites before it is shown.
    static let exemptions: [(file: String, line: String)] = [
        ("MainWindowController.swift",
         "tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 0)"
            + "  // token-exempt: starts hidden; setTabStripVisible sets it"),
        ("Worktree/DeleteMergedWorktreesSheetView.swift",
         "let height = scroll.heightAnchor.constraint(equalToConstant: 0)"
            + "  // token-exempt: placeholder; render() sizes it"),
    ]

    /// The issue's grep, `grep -rnE 'constant: -?[0-9]|equalToConstant: [0-9]'`.
    static let autoLayoutLiteralPattern = #"constant: -?[0-9]|equalToConstant: [0-9]"#

    // MARK: 1. Values

    @Test(arguments: pins)
    func everyTokenHoldsTheLiteralItReplaced(pin: Pin) {
        // Bit pattern, not `==`: a -0 or a differently rounded decimal would compare equal.
        #expect(pin.token.value.bitPattern == pin.literal.bitPattern,
                "\(pin.token.name) is \(pin.token.value), the sites held \(pin.literal)")
        #expect(pin.token.snap == pin.snap, "\(pin.token.name) is \(pin.token.snap), expected \(pin.snap)")
        #expect(pin.literal > 0, "\(pin.token.name): a site keeps its sign, a token holds the magnitude")
    }

    @Test func pinsCoverExactlyTheLayoutTokens() {
        let pinned = Self.pins.map(\.token.name)
        #expect(Set(pinned).count == pinned.count, "a token is pinned twice")
        #expect(pinned == M.layout.map(\.name), "pins and `Metrics.layout` differ")
        #expect(M.layout.count == 66)
        let all = Set(DesignTokens.all.map(\.name))
        #expect(M.layout.allSatisfy { all.contains($0.name) }, "an S5 token is missing from `DesignTokens.all`")
    }

    // MARK: 2. The migrated sites

    static func source(_ file: String) throws -> String {
        try String(contentsOf: SourceHygieneTests.repoRoot.appendingPathComponent("Sources/TkzApp/" + file),
                   encoding: .utf8)
    }

    /// The old line with its one literal replaced by the token, as the migration writes it, and the
    /// literal itself.
    static func migrated(_ site: Site, in file: String) throws -> (line: String, literal: Double) {
        let regex = try NSRegularExpression(pattern: #"(constant: |equalToConstant: )(-?)([0-9][0-9.]*)"#)
        let old = site.old
        let matches = regex.matches(in: old, range: NSRange(old.startIndex..., in: old))
        try #require(matches.count == 1, "\(file): `\(old)` has \(matches.count) literal constants")
        let match = matches[0]
        let text = { (index: Int) in String(old[Range(match.range(at: index), in: old)!]) }
        let literal = try #require(Double(text(3)), "\(old)")
        let namespace = unaliased.contains(file) ? "DesignTokens.Metrics." : "LayoutTokens."
        let path = String(site.token.name.dropFirst("Metrics.".count))
        let expression = "\(text(1))\(text(2))CGFloat(\(namespace)\(path).value)"
        let line = old.replacingCharacters(in: Range(match.range, in: old)!, with: expression)
        return (line, text(2) == "-" ? -literal : literal)
    }

    @Test(arguments: files)
    func everySiteReadsItsToken(file: File) throws {
        let text = try Self.source(file.path)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for site in file.sites {
            #expect(site.token.name.hasPrefix("Metrics."), "\(site.token.name)")
            let (new, literal) = try Self.migrated(site, in: file.path)
            // The token is the literal's magnitude, bit for bit, and the site restores its sign.
            #expect(site.token.value.bitPattern == literal.magnitude.bitPattern,
                    "\(file.path): `\(site.old)` held \(literal), \(site.token.name) is \(site.token.value)")
            #expect(lines.filter { $0 == site.old }.count == 0, "\(file.path) still has `\(site.old)`")
            let found = lines.filter { $0 == new }.count
            #expect(found == site.count, "\(file.path): `\(new)` \(found) times, expected \(site.count)")
        }
        let aliases = lines.filter { $0 == Self.alias }.count
        #expect(aliases == (Self.unaliased.contains(file.path) ? 0 : 1), "\(file.path): \(aliases) aliases")
        // Every token the file reads at a site is one of its sites'. (The S3 forwards in the nested
        // `Metrics` enums spell `CGFloat(DesignTokens.Metrics…` too, but never after `constant: `.)
        let read = Set(DesignTokensTests.allMatches(
            #"[cC]onstant: -?CGFloat\((?:LayoutTokens|DesignTokens\.Metrics)\.(\w+\.\w+)\.value\)"#, in: text)
            .map { "Metrics." + $0[1]! })
        #expect(read == Set(file.sites.map(\.token.name)), "\(file.path) reads \(read.sorted())")
    }

    @Test func theSitesAreTheIssuesSitesLessTheExemptions() {
        var counts: [String: Int] = [:]
        for file in Self.files { counts[file.path, default: 0] += file.sites.reduce(0) { $0 + $1.count } }
        for exemption in Self.exemptions { counts[exemption.file, default: 0] += 1 }
        #expect(counts == Self.issueCounts)
        #expect(counts.values.reduce(0, +) == 106)
        #expect(Set(Self.files.map(\.path)).count == Self.files.count, "a file is listed twice")
    }

    @Test func everyLayoutTokenIsReadOnTheMac() {
        let read = Set(Self.files.flatMap { $0.sites.map(\.token.name) })
        let unread = M.layout.map(\.name).filter { !read.contains($0) }
        #expect(unread.isEmpty, "S5 tokens no Mac site reads: \(unread)")
    }

    // MARK: 3. The S5 grep

    /// WOR-307 S5's done-when, as a test: no literal Auto Layout constant in TkzApp outside a
    /// `// token-exempt: <reason>` line, and the exempt ones are the two placeholders.
    @Test func theAutoLayoutLiteralGrepIsEmpty() throws {
        let files = try SourceHygieneTests.swiftSources(under: "Sources/TkzApp")
        #expect(files.count > 50)
        let regex = try NSRegularExpression(pattern: Self.autoLayoutLiteralPattern)
        var hits: [String] = []
        var exempt: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(line)
                guard regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                if line.contains("// token-exempt:") {
                    exempt.append(line.trimmingCharacters(in: .whitespaces))
                } else {
                    hits.append("\(url.lastPathComponent):\(number + 1): \(line)")
                }
            }
        }
        #expect(hits.isEmpty, "literal Auto Layout constants outside DesignTokens: \(hits)")
        #expect(exempt.sorted() == Self.exemptions.map(\.line).sorted())
        for exemption in Self.exemptions {
            #expect(try Self.source(exemption.file).contains(exemption.line), "\(exemption.file)")
        }
    }

    @Test func theGrepWouldCatchTheOldLines() throws {
        let regex = try NSRegularExpression(pattern: Self.autoLayoutLiteralPattern)
        func matches(_ line: String) -> Bool {
            regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        for file in Self.files {
            for site in file.sites {
                #expect(matches(site.old), "\(site.old)")
                #expect(!matches(try Self.migrated(site, in: file.path).line), "\(site.old)")
            }
        }
    }
}
