// DesignTokensTests — WOR-307 S3. The Mac must draw exactly what it drew before the tokens existed,
// and that cannot be checked on Linux by rendering. So these tests pin it from both ends, from
// source alone:
//
//   1. `pins` maps every old constant (`SidebarMetrics.groupRowHeight`, the nested `Metrics` enums,
//      the window geometry, the status-bar hairline) to its token and to the literal it held before
//      the move. A token whose value is not bit-identical to that literal fails.
//   2. A scan of the 13 enum bodies in `Sources/TkzApp` finds no numeric literal, and every member
//      forwards to exactly the token `pins` names for it, or to the `GlassSheetMetrics` member it
//      aliased before. So the Mac reads the pinned literal through the old name.
//   3. The window-geometry and hairline sites read their tokens, and their old literals are gone.
//
// The goldens (`Tests/TkzAppTests/ComponentSnapshots/`) remain the Mac-side check; this is the half
// that runs in the Linux CI job.

import Foundation
import Testing

@testable import TkzCore

@Suite struct DesignTokensTests {
    typealias M = DesignTokens.Metrics

    /// An old constant, the literal it held before WOR-307 S3, its snapping kind, and its token.
    struct Pin: Sendable, CustomTestStringConvertible {
        let old: String
        let literal: Double
        let snap: DesignToken.Snap
        let token: DesignToken
        init(_ old: String, _ literal: Double, _ snap: DesignToken.Snap, _ token: DesignToken) {
            self.old = old
            self.literal = literal
            self.snap = snap
            self.token = token
        }
        var testDescription: String { old }
    }

    /// Copied from the sources as they were before the move (`git show eb61b60:<file>`). Never edit a
    /// literal here to make a test pass: a different number is a Mac-visible change.
    static let pins: [Pin] = [
        // Sources/TkzApp/Sidebar/SidebarRowModels.swift
        Pin("SidebarMetrics.groupRowHeight", 28, .points, M.Sidebar.groupRowHeight),
        Pin("SidebarMetrics.sessionRowHeight", 44, .points, M.Sidebar.sessionRowHeight),
        Pin("SidebarMetrics.sessionRowWrappedHeight", 59, .points, M.Sidebar.sessionRowWrappedHeight),
        Pin("SidebarMetrics.sidebarHeaderHeight", 28, .points, M.Sidebar.headerHeight),
        Pin("SidebarMetrics.updateNoticeHeight", 48, .points, M.Sidebar.updateNoticeHeight),
        Pin("SidebarMetrics.sessionIndent", 16, .points, M.Sidebar.sessionIndent),
        Pin("SidebarMetrics.groupEdgeWidth", 2.5, .stroke, M.Sidebar.groupEdgeWidth),
        Pin("SidebarMetrics.sidebarWidth", 300, .points, M.Window.sidebarWidth),
        Pin("SidebarMetrics.sidebarMinWidth", 240, .points, M.Window.sidebarMinWidth),
        // Sources/TkzApp/Tabs/TabStripModels.swift
        Pin("TabStripMetrics.stripHeight", 28, .points, M.TabStrip.stripHeight),
        Pin("TabStripMetrics.tabMinWidth", 90, .points, M.TabStrip.tabMinWidth),
        Pin("TabStripMetrics.tabMaxWidth", 180, .points, M.TabStrip.tabMaxWidth),
        Pin("TabStripMetrics.tabGap", 1, .points, M.TabStrip.tabGap),
        Pin("TabStripMetrics.horizontalInset", 8, .points, M.TabStrip.horizontalInset),
        Pin("TabStripMetrics.cornerRadius", 6, .unrounded, DesignTokens.Radii.tab),
        Pin("TabStripMetrics.badgeGap", 6, .points, M.TabStrip.badgeGap),
        Pin("TabStripMetrics.closeSize", 14, .mark, M.TabStrip.closeSize),
        // Sources/TkzApp/Panes/PaneModels.swift
        Pin("SplitMetrics.dividerThickness", 7, .points, M.Split.dividerThickness),
        Pin("SplitMetrics.gripLength", 44, .mark, M.Split.gripLength),
        Pin("SplitMetrics.gripThickness", 3, .mark, M.Split.gripThickness),
        Pin("SplitMetrics.minPaneSide", 120, .points, M.Split.minPaneSide),
        Pin("SplitMetrics.ratioEpsilon", 0.005, .scalar, M.Split.ratioEpsilon),
        // Sources/TkzApp/Panes/PaneHeaderModels.swift
        Pin("PaneHeaderMetrics.height", 28, .points, M.PaneHeader.height),
        Pin("PaneHeaderMetrics.insetX", 12, .points, M.PaneHeader.insetX),
        Pin("PaneHeaderMetrics.gap", 8, .points, M.PaneHeader.gap),
        Pin("PaneHeaderMetrics.dotDiameter", 6, .mark, M.PaneHeader.dotDiameter),
        Pin("PaneHeaderMetrics.closeSize", 16, .mark, M.PaneHeader.closeSize),
        Pin("PaneHeaderMetrics.focusRingWidth", 1.5, .stroke, M.PaneHeader.focusRingWidth),
        Pin("PaneHeaderMetrics.inactiveContentAlpha", 0.85, .scalar, M.PaneHeader.inactiveContentAlpha),
        // Sources/TkzApp/Changes/ChangesViewerView.swift
        Pin("ChangesMetrics.headerHeight", 38, .points, M.Changes.headerHeight),
        Pin("ChangesMetrics.fileListWidth", 264, .points, M.Changes.fileListWidth),
        Pin("ChangesMetrics.fileRowHeight", 28, .points, M.Changes.fileRowHeight),
        Pin("ChangesMetrics.fileListInset", 6, .points, M.Changes.fileListInset),
        Pin("ChangesMetrics.pathHeaderHeight", 32, .points, M.Changes.pathHeaderHeight),
        Pin("ChangesMetrics.diffRowHeight", 20, .points, M.Changes.diffRowHeight),
        Pin("ChangesMetrics.numberWidth", 44, .points, M.Changes.numberWidth),
        Pin("ChangesMetrics.numberGap", 8, .points, M.Changes.numberGap),
        Pin("ChangesMetrics.textInset", 14, .points, M.Changes.textInset),
        Pin("ChangesMetrics.fontSize", 11.5, .unrounded, DesignTokens.Typography.changesDiffSize),
        Pin("ChangesMetrics.fileFontSize", 10.5, .unrounded, DesignTokens.Typography.changesFileSize),
        Pin("ChangesMetrics.tabWidth", 4, .scalar, M.Changes.tabWidth),
        // Sources/TkzApp/Sheets/GlassSheet.swift
        Pin("GlassSheetMetrics.width", 318, .points, M.GlassSheet.width),
        Pin("GlassSheetMetrics.padding", 14, .points, M.GlassSheet.padding),
        Pin("GlassSheetMetrics.topPadding", 13, .points, M.GlassSheet.topPadding),
        Pin("GlassSheetMetrics.bottomPadding", 12, .points, M.GlassSheet.bottomPadding),
        Pin("GlassSheetMetrics.cornerRadius", 11, .unrounded, DesignTokens.Radii.glassSheet),
        Pin("GlassSheetMetrics.buttonHeight", 27, .points, M.GlassSheet.buttonHeight),
        Pin("GlassSheetMetrics.inset", 14, .points, M.GlassSheet.inset),
        // Sources/TkzApp/Rebase/RebaseSheetView.swift (aliases of the family)
        Pin("RebaseSheetView.Metrics.width", 318, .points, M.GlassSheet.width),
        Pin("RebaseSheetView.Metrics.padding", 14, .points, M.GlassSheet.padding),
        Pin("RebaseSheetView.Metrics.topPadding", 13, .points, M.GlassSheet.topPadding),
        Pin("RebaseSheetView.Metrics.bottomPadding", 12, .points, M.GlassSheet.bottomPadding),
        Pin("RebaseSheetView.Metrics.cornerRadius", 11, .unrounded, DesignTokens.Radii.glassSheet),
        Pin("RebaseSheetView.Metrics.buttonHeight", 27, .points, M.GlassSheet.buttonHeight),
        // Sources/TkzApp/Worktree/DeleteWorktreeSheetView.swift (aliases of the family)
        Pin("DeleteWorktreeSheetView.Metrics.width", 318, .points, M.GlassSheet.width),
        Pin("DeleteWorktreeSheetView.Metrics.padding", 14, .points, M.GlassSheet.padding),
        Pin("DeleteWorktreeSheetView.Metrics.topPadding", 13, .points, M.GlassSheet.topPadding),
        Pin("DeleteWorktreeSheetView.Metrics.bottomPadding", 12, .points, M.GlassSheet.bottomPadding),
        Pin("DeleteWorktreeSheetView.Metrics.buttonHeight", 27, .points, M.GlassSheet.buttonHeight),
        // Sources/TkzApp/Worktree/DeleteMergedWorktreesSheetView.swift
        Pin("DeleteMergedWorktreesSheetView.Metrics.width", 380, .points, M.DeleteMergedSheet.width),
        Pin("DeleteMergedWorktreesSheetView.Metrics.padding", 14, .points, M.GlassSheet.padding),
        Pin("DeleteMergedWorktreesSheetView.Metrics.topPadding", 13, .points, M.GlassSheet.topPadding),
        Pin("DeleteMergedWorktreesSheetView.Metrics.bottomPadding", 12, .points, M.GlassSheet.bottomPadding),
        Pin("DeleteMergedWorktreesSheetView.Metrics.buttonHeight", 27, .points, M.GlassSheet.buttonHeight),
        Pin("DeleteMergedWorktreesSheetView.Metrics.maxListHeight", 180, .points,
            M.DeleteMergedSheet.maxListHeight),
        // Sources/TkzApp/Prompt/PromptCardView.swift
        Pin("PromptCardView.Metrics.width", 640, .points, M.PromptCard.width),
        Pin("PromptCardView.Metrics.padding", 20, .points, M.PromptCard.padding),
        Pin("PromptCardView.Metrics.verticalPadding", 18, .points, M.PromptCard.verticalPadding),
        Pin("PromptCardView.Metrics.rowSpacing", 10, .points, M.PromptCard.rowSpacing),
        Pin("PromptCardView.Metrics.cornerRadius", 12, .unrounded, DesignTokens.Radii.promptCard),
        Pin("PromptCardView.Metrics.defaultMaxTextHeight", 220, .points, M.PromptCard.defaultMaxTextHeight),
        Pin("PromptCardView.Metrics.minTextHeight", 22, .points, M.PromptCard.minTextHeight),
        // Sources/TkzApp/Settings/ThemedSwitch.swift
        Pin("ThemedSwitch.Metrics.width", 30, .points, M.ThemedSwitch.width),
        Pin("ThemedSwitch.Metrics.height", 18, .points, M.ThemedSwitch.height),
        Pin("ThemedSwitch.Metrics.knob", 14, .mark, M.ThemedSwitch.knob),
        Pin("ThemedSwitch.Metrics.inset", 2, .points, M.ThemedSwitch.inset),
        // Sources/TkzApp/Settings/SettingsView.swift
        Pin("SettingsView.Metrics.width", 720, .points, M.Settings.width),
        Pin("SettingsView.Metrics.height", 600, .points, M.Settings.height),
        Pin("SettingsView.Metrics.navWidth", 176, .points, M.Settings.navWidth),
        Pin("SettingsView.Metrics.navRowHeight", 28, .points, M.Settings.navRowHeight),
        Pin("SettingsView.Metrics.navInset", 10, .points, M.Settings.navInset),
        Pin("SettingsView.Metrics.cardRadius", 9, .unrounded, DesignTokens.Radii.settingsCard),
        Pin("SettingsView.Metrics.contentTop", 20, .points, M.Settings.contentTop),
        Pin("SettingsView.Metrics.contentSide", 22, .points, M.Settings.contentSide),
        Pin("SettingsView.Metrics.sectionSpacing", 20, .points, M.Settings.sectionSpacing),
        Pin("SettingsView.Metrics.rowPaddingV", 12, .points, M.Settings.rowPaddingV),
        Pin("SettingsView.Metrics.rowPaddingH", 14, .points, M.Settings.rowPaddingH),
        Pin("SettingsView.Metrics.controlGap", 16, .points, M.Settings.controlGap),
        // Sources/TkzApp/CheatSheet/CheatSheetOverlayView.swift
        Pin("CheatSheetOverlayView.Metrics.cardPadding", 24, .points, M.CheatSheet.cardPadding),
        Pin("CheatSheetOverlayView.Metrics.columnSpacing", 36, .points, M.CheatSheet.columnSpacing),
        Pin("CheatSheetOverlayView.Metrics.sectionSpacing", 18, .points, M.CheatSheet.sectionSpacing),
        Pin("CheatSheetOverlayView.Metrics.rowSpacing", 5, .points, M.CheatSheet.rowSpacing),
        Pin("CheatSheetOverlayView.Metrics.keyTitleSpacing", 14, .points, M.CheatSheet.keyTitleSpacing),
        Pin("CheatSheetOverlayView.Metrics.cornerRadius", 12, .unrounded, DesignTokens.Radii.cheatSheet),
        Pin("CheatSheetOverlayView.Metrics.columnCount", 2, .scalar, M.CheatSheet.columnCount),
        // Sources/TkzApp/MainWindowController.swift (inline literals before the move)
        Pin("MainWindowController.defaultWindowSize.width", 1240, .points, M.Window.width),
        Pin("MainWindowController.defaultWindowSize.height", 820, .points, M.Window.height),
        Pin("MainWindowController.minimumContentSize.width", 720, .points, M.Window.minWidth),
        Pin("MainWindowController.minimumContentSize.height", 420, .points, M.Window.minHeight),
        Pin("MainWindowController.sidebarMaxWidth", 520, .points, M.Window.sidebarMaxWidth),
        Pin("MainWindowController.detailMinWidth", 400, .points, M.Window.detailMinWidth),
        // Sources/TkzApp/StatusBar/StatusBarView.swift: `1 / backingScaleFactor`
        Pin("StatusBarView.draw.hairline", 1, .hairline, M.StatusBar.topLine),
        // WOR-307 S4 (`git show 7f8068b:<file>`): line spacing and the Markdown indent. The roles
        // are pinned in TypographyTokensTests.
        // Sources/TkzApp/FileViewer/FileViewerView.swift
        Pin("FileViewerView.text.lineHeightMultiple", 1.1, .scalar,
            DesignTokens.Typography.fileViewerLineHeightMultiple),
        // Sources/TkzApp/FileViewer/MarkdownRenderer.swift
        Pin("MarkdownRenderer.paragraphStyle.lineHeightMultiple", 1.15, .scalar,
            DesignTokens.Typography.markdownLineHeightMultiple),
        Pin("MarkdownRenderer.paragraphStyle.codeLineHeightMultiple", 1.05, .scalar,
            DesignTokens.Typography.markdownCodeLineHeightMultiple),
        Pin("MarkdownRenderer.indentStep", 22, .points, DesignTokens.Typography.markdownIndentStep),
        // Sources/TkzApp/Prompt/PromptCardView.swift
        Pin("PromptCardView.set.lineHeightMultiple", 1.25, .scalar,
            DesignTokens.Typography.promptCardLineHeightMultiple),
    ]

    // MARK: 1. Values

    @Test(arguments: pins)
    func everyTokenHoldsTheLiteralItReplaced(pin: Pin) {
        // Bit pattern, not `==`: a -0 or a differently rounded decimal would compare equal.
        #expect(pin.token.value.bitPattern == pin.literal.bitPattern,
                "\(pin.old) was \(pin.literal), \(pin.token.name) is \(pin.token.value)")
        #expect(pin.token.snap == pin.snap, "\(pin.token.name) is \(pin.token.snap), expected \(pin.snap)")
    }

    @Test func everyTokenIsPinned() {
        // The S5 Auto Layout constants are pinned, with their sites, in `LayoutTokensTests`.
        let pinned = Set(Self.pins.map(\.token.name) + LayoutTokensTests.pins.map(\.token.name))
        let unpinned = DesignTokens.all.map(\.name).filter { !pinned.contains($0) }
        #expect(unpinned.isEmpty, "tokens with no old constant pinned to them: \(unpinned)")
    }

    @Test func pinsNameEachOldConstantOnce() {
        let olds = Self.pins.map(\.old)
        #expect(Set(olds).count == olds.count)
    }

    // MARK: Registry

    @Test func namesAreUniqueAndResolve() {
        let names = DesignTokens.all.map(\.name)
        #expect(Set(names).count == names.count, "duplicate token names")
        #expect(names.count == 158)
        for token in DesignTokens.all {
            #expect(DesignTokens.token(named: token.name) == token)
            #expect(token.value.isFinite && token.value >= 0, "\(token.name)")
        }
        #expect(DesignTokens.token(named: "Metrics.Sidebar.nope") == nil)
    }

    /// `name` is the token's Swift path under `DesignTokens`: each declaration's string names the
    /// property it is assigned to, inside the enum it is declared in.
    @Test func namesSpellTheSwiftPath() throws {
        var declared: [String] = []
        for url in try Self.designTokenSources() {
            var enums: [(name: String, depth: Int)] = []
            var depth = 0
            // A declaration wrapped after `DesignToken(`: its path, waiting for the name string.
            var pending: String?
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let code = Self.stripComment(String(line))
                func path(_ property: String) -> String {
                    (enums.map(\.name).filter { $0 != "DesignTokens" } + [property]).joined(separator: ".")
                }
                if let expected = pending {
                    let name = Self.firstMatch(#"^\s*"([\w.]+)""#, in: code)?[1]
                    #expect(name == expected, "\(url.lastPathComponent): \(name ?? "?") is declared at \(expected)")
                    declared.append(expected)
                    pending = nil
                }
                if let match = Self.firstMatch(
                    #"^\s*(?:extension\s+DesignTokens\.([\w.]+)|(?:public\s+)?enum\s+(\w+))\s*\{"#, in: code) {
                    enums.append((match[1] ?? match[2]!, depth))
                }
                if let match = Self.firstMatch(#"static let (\w+) = DesignToken\(\s*"([\w.]+)""#, in: code) {
                    #expect(match[2] == path(match[1]!),
                            "\(url.lastPathComponent): \(match[2]!) is declared at \(path(match[1]!))")
                    declared.append(path(match[1]!))
                } else if let match = Self.firstMatch(#"static let (\w+) = DesignToken\(\s*$"#, in: code) {
                    pending = path(match[1]!)
                }
                depth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
                while let last = enums.last, depth <= last.depth { enums.removeLast() }
            }
        }
        let mismatched = Set(declared).symmetricDifference(DesignTokens.all.map(\.name))
        #expect(mismatched.isEmpty, "declared and `all` differ: \(mismatched.sorted())")
        #expect(declared.count == DesignTokens.all.count)
    }

    @Test func hairlinesAreOneDevicePixel() {
        let hairlines = DesignTokens.all.filter { $0.snap == .hairline }
        #expect(hairlines.map(\.name) == ["Metrics.StatusBar.topLine"])
        #expect(hairlines.allSatisfy { $0.value == 1 })
    }

    // MARK: 2. The 13 enum bodies

    /// The enums WOR-307 S3 folds into tokens, their files and their declarations.
    static let enums: [(name: String, file: String, declaration: String)] = [
        ("SidebarMetrics", "Sidebar/SidebarRowModels.swift", "public enum SidebarMetrics {"),
        ("TabStripMetrics", "Tabs/TabStripModels.swift", "public enum TabStripMetrics {"),
        ("SplitMetrics", "Panes/PaneModels.swift", "public enum SplitMetrics {"),
        ("PaneHeaderMetrics", "Panes/PaneHeaderModels.swift", "public enum PaneHeaderMetrics {"),
        ("ChangesMetrics", "Changes/ChangesViewerView.swift", "enum ChangesMetrics {"),
        ("GlassSheetMetrics", "Sheets/GlassSheet.swift", "enum GlassSheetMetrics {"),
        ("RebaseSheetView.Metrics", "Rebase/RebaseSheetView.swift", "enum Metrics {"),
        ("DeleteWorktreeSheetView.Metrics", "Worktree/DeleteWorktreeSheetView.swift", "enum Metrics {"),
        ("DeleteMergedWorktreesSheetView.Metrics", "Worktree/DeleteMergedWorktreesSheetView.swift", "enum Metrics {"),
        ("ThemedSwitch.Metrics", "Settings/ThemedSwitch.swift", "enum Metrics {"),
        ("SettingsView.Metrics", "Settings/SettingsView.swift", "enum Metrics {"),
        ("CheatSheetOverlayView.Metrics", "CheatSheet/CheatSheetOverlayView.swift", "private enum Metrics {"),
        ("PromptCardView.Metrics", "Prompt/PromptCardView.swift", "enum Metrics {"),
    ]

    /// The code lines of an enum body (comments stripped), from its declaration to its closing brace.
    static func body(of entry: (name: String, file: String, declaration: String)) throws -> [String] {
        let url = SourceHygieneTests.repoRoot.appendingPathComponent("Sources/TkzApp/" + entry.file)
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let starts = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces) == entry.declaration
        }
        try #require(starts.count == 1, "\(entry.file): \(starts.count) lines read `\(entry.declaration)`")
        var body: [String] = []
        var depth = 0
        for line in lines[starts[0]...] {
            let code = stripComment(line)
            depth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
            body.append(code)
            if depth == 0 { break }
        }
        return body
    }

    @Test(arguments: enums.map(\.name))
    func noNumericLiteralsInTheEnumBody(name: String) throws {
        let entry = try #require(Self.enums.first { $0.name == name })
        let body = try Self.body(of: entry)
        #expect(body.count > 2)
        let literals = body.filter { Self.firstMatch(#"(?<![A-Za-z0-9_])[0-9]"#, in: $0) != nil }
        #expect(literals.isEmpty, "\(name) still holds literals: \(literals)")
    }

    /// Every member forwards to the token `pins` names for it, through one of the three shapes the
    /// migration uses, or aliases the `GlassSheetMetrics` member it aliased before.
    @Test(arguments: enums.map(\.name))
    func everyMemberForwardsToItsPinnedToken(name: String) throws {
        let entry = try #require(Self.enums.first { $0.name == name })
        let code = try Self.body(of: entry).joined(separator: " ")
        let members = Self.allMatches(
            #"static let (\w+)\s*(?::\s*(\w+))?\s*=\s*([\w.()]+)"#, in: code)
        #expect(members.count == code.components(separatedBy: "static let ").count - 1,
                "\(name): a member did not parse")
        var seen: [String] = []
        for member in members {
            let old = "\(name).\(member[1]!)"
            seen.append(old)
            let pin = try #require(Self.pins.first { $0.old == old }, "\(old) is not pinned")
            let rhs = member[3]!
            if let alias = Self.firstMatch(#"^GlassSheetMetrics\.(\w+)$"#, in: rhs) {
                let target = try #require(Self.pins.first { $0.old == "GlassSheetMetrics.\(alias[1]!)" })
                #expect(target.token == pin.token, "\(old) aliases \(rhs), pinned to \(pin.token.name)")
                continue
            }
            let forward = try #require(
                Self.firstMatch(#"^(?:(CGFloat|Int)\()?DesignTokens\.([\w.]+)\.value\)?$"#, in: rhs),
                "\(old) = \(rhs) is not a token forward")
            #expect(forward[2] == pin.token.name, "\(old) forwards to \(forward[2]!), pinned to \(pin.token.name)")
            // `Double` members keep their annotation; `CGFloat`/`Int` ones are converted, not annotated.
            if let wrapper = forward[1] {
                #expect(member[2] == nil, "\(old) is annotated and wrapped")
                #expect(wrapper == "CGFloat" || pin.snap == .scalar, "\(old) truncates a length to Int")
            } else {
                #expect(member[2] == "Double", "\(old) forwards a Double into \(member[2] ?? "an inferred type")")
            }
        }
        let expected = Self.pins.map(\.old).filter { $0.hasPrefix(name + ".") }
        #expect(seen.sorted() == expected.sorted(), "\(name): members and pins differ")
    }

    // MARK: 3. Window geometry and the hairline

    @Test func windowGeometryAndHairlineSitesReadTheirTokens() throws {
        func source(_ file: String) throws -> String {
            try String(contentsOf: SourceHygieneTests.repoRoot.appendingPathComponent("Sources/TkzApp/" + file),
                       encoding: .utf8)
        }
        let window = try source("MainWindowController.swift")
        for path in ["width", "height", "minWidth", "minHeight", "sidebarMaxWidth", "detailMinWidth"] {
            #expect(window.contains("CGFloat(DesignTokens.Metrics.Window.\(path).value)"), "\(path)")
        }
        for gone in ["NSSize(width: 1240, height: 820)", "NSSize(width: 720, height: 420)",
                     "maximumThickness = 520", "minimumThickness = 400", "min(width, 520)"] {
            #expect(!window.contains(gone), "MainWindowController still has `\(gone)`")
        }
        #expect(window.contains("maximumThickness = Self.sidebarMaxWidth"))
        #expect(window.contains("detailItem.minimumThickness = Self.detailMinWidth"))
        #expect(window.contains("return min(width, Self.sidebarMaxWidth)"))

        let statusBar = try source("StatusBar/StatusBarView.swift")
        #expect(statusBar.contains(
            "let hairline = CGFloat(DesignTokens.Metrics.StatusBar.topLine.value)\n"
            + "            / max(window?.backingScaleFactor ?? 2, 1)"))
        #expect(!statusBar.contains("let hairline = 1 /"))
    }

    /// WOR-307 S4: the line spacing and the Markdown indent read their tokens, through the type the
    /// property always had.
    @Test func lineSpacingSitesReadTheirTokens() throws {
        func source(_ file: String) throws -> String {
            try String(contentsOf: SourceHygieneTests.repoRoot.appendingPathComponent("Sources/TkzApp/" + file),
                       encoding: .utf8)
        }
        let viewer = try source("FileViewer/FileViewerView.swift")
        #expect(viewer.contains(
            "style.lineHeightMultiple = CGFloat(DesignTokens.Typography.fileViewerLineHeightMultiple.value)\n"))
        #expect(!viewer.contains("lineHeightMultiple = 1"))
        let markdown = try source("FileViewer/MarkdownRenderer.swift")
        for line in [
            "static let indentStep = CGFloat(DesignTokens.Typography.markdownIndentStep.value)\n",
            "style.lineHeightMultiple = CGFloat(DesignTokens.Typography.markdownLineHeightMultiple.value)\n",
            "style.lineHeightMultiple = CGFloat(DesignTokens.Typography.markdownCodeLineHeightMultiple.value)\n",
        ] {
            #expect(markdown.components(separatedBy: line).count == 2, "\(line)")
        }
        for gone in ["indentStep: CGFloat = 22", "lineHeightMultiple = 1"] {
            #expect(!markdown.contains(gone), "MarkdownRenderer still has `\(gone)`")
        }
        let prompt = try source("Prompt/PromptCardView.swift")
        #expect(prompt.contains(
            "paragraph.lineHeightMultiple = CGFloat(DesignTokens.Typography.promptCardLineHeightMultiple.value)\n"))
        #expect(!prompt.contains("lineHeightMultiple = 1"))
    }

    // MARK: Helpers

    static func designTokenSources() throws -> [URL] {
        let urls = try SourceHygieneTests.swiftSources().filter { $0.lastPathComponent.hasPrefix("DesignTokens") }
        try #require(urls.count >= 2)
        return urls
    }

    /// The line without a trailing `//` comment. None of the scanned lines has `//` inside a string.
    static func stripComment(_ line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[..<range.lowerBound])
    }

    /// The capture groups of the first match (index 0 is the whole match); nil where a group did
    /// not take part.
    static func firstMatch(_ pattern: String, in text: String) -> [String?]? {
        allMatches(pattern, in: text).first
    }

    static func allMatches(_ pattern: String, in text: String) -> [[String?]] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }
}
