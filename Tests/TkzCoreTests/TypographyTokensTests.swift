// TypographyTokensTests — WOR-307 S4. The Linux half of "the Mac draws the same text it drew
// before the typography roles existed", checked from source like `DesignTokensTests`:
//
//   1. `pins` holds every role to the literal font call, `.kern` value or MarkdownRenderer static
//      it replaced (`git show 7f8068b:<file>`), bit for bit, with its face and weight. A mono role
//      is Regular: that is what `Theme.Fonts.mono` draws whatever weight it is asked for.
//   2. `sites` lists every TkzApp line that was migrated: the old expression is gone, the new one
//      reads the pinned role, and a site whose old expression was a plain font call parses back to
//      exactly that role.
//   3. The S4 grep (`\.(ui|mono)\([0-9]|ofSize: [0-9]|\.kern: …[0-9]` over `Sources/TkzApp`)
//      finds nothing outside `// token-exempt: <reason>` lines.
//   4. The measured line metrics are either not generated yet or cover every role.
//
// The macOS half, `ComponentSnapshotTypographyTests` (TkzAppTests), resolves each role to its
// NSFont and measures it.

import Foundation
import Testing

@testable import TkzCore

@Suite struct TypographyTokensTests {
    typealias T = DesignTokens.Typography
    typealias Role = DesignTokens.Typography.Role

    /// A role and the values the Mac's literal calls gave it before WOR-307 S4.
    struct Pin: Sendable, CustomTestStringConvertible {
        let role: Role
        let old: String
        let size: Double
        let face: Role.Face
        let weight: Role.Weight
        let tracking: Double
        let trackingEm: Double
        init(
            _ role: Role, _ old: String, _ size: Double, _ face: Role.Face, _ weight: Role.Weight = .regular,
            tracking: Double = 0, trackingEm: Double = 0
        ) {
            self.role = role
            self.old = old
            self.size = size
            self.face = face
            self.weight = weight
            self.tracking = tracking
            self.trackingEm = trackingEm
        }
        var testDescription: String { role.name }
    }

    /// Copied from the sources before the move. Never edit a literal here to make a test pass: a
    /// different number is a Mac-visible change.
    static let pins: [Pin] = [
        Pin(T.badge, "Theme.Fonts.ui(9, weight: .semibold)", 9, .ui, .semibold),
        Pin(T.closeGlyph, "Theme.Fonts.ui(13, weight: .medium)", 13, .ui, .medium),
        Pin(T.groupAdd, "Theme.Fonts.ui(12)", 12, .ui),
        Pin(T.sidebarHeaderCaption, "ui(theme.fontUI.caption, weight: .semibold), .kern: 0.6", 10.5, .ui, .semibold,
            tracking: 0.6),
        Pin(T.lastMessage, ".systemFont(ofSize: 11)", 11, .ui),
        Pin(T.updateTitle, "Theme.Fonts.ui(12, weight: .semibold)", 12, .ui, .semibold),
        Pin(T.updateGlyph, "Theme.Fonts.ui(12, weight: .semibold)", 12, .ui, .semibold),
        Pin(T.updateClose, "Theme.Fonts.ui(11)", 11, .ui),
        // `mono(theme.fontMono.detail, weight: .semibold)` draws Regular: the effective face.
        Pin(T.statusPill, "0.03 * Theme.Fonts.mono.detail", 10, .mono, trackingEm: 0.03),
        Pin(T.changesTitle, "Theme.Fonts.ui(12, weight: .semibold)", 12, .ui, .semibold),
        Pin(T.fileViewerText, "Theme.Fonts.mono(13)", 13, .mono),
        Pin(T.markdownBody, "static let bodySize: CGFloat = 13.5", 13.5, .ui),
        Pin(T.markdownCode, "static let codeSize: CGFloat = 12.5", 12.5, .mono),
        Pin(T.markdownHeading1, "case 1: 22", 22, .ui, .bold),
        Pin(T.markdownHeading2, "case 2: 18", 18, .ui, .bold),
        Pin(T.markdownHeading3, "case 3: 15.5", 15.5, .ui, .semibold),
        Pin(T.markdownHeading4, "default: 14", 14, .ui, .semibold),
        Pin(T.sheetTitle, "Theme.Fonts.ui(13, weight: .semibold)", 13, .ui, .semibold),
        Pin(T.sheetBody, "Theme.Fonts.mono(11.5)", 11.5, .mono),
        Pin(T.sheetPath, "Theme.Fonts.mono(11)", 11, .mono),
        Pin(T.sheetListStatus, "Theme.Fonts.mono(10.5)", 10.5, .mono),
        Pin(T.sheetButton, "Theme.Fonts.ui(11.5)", 11.5, .ui),
        Pin(T.sheetButtonPrimary, "Theme.Fonts.ui(11.5, weight: .semibold)", 11.5, .ui, .semibold),
        Pin(T.sheetCheckbox, "Theme.Fonts.ui(11.5)", 11.5, .ui),
        Pin(T.shortcutHint, "Theme.Fonts.mono(10)", 10, .mono),
        Pin(T.promptPill, "Theme.Fonts.ui(9, weight: .bold), .kern: font.pointSize * 0.06", 9, .ui, .bold,
            trackingEm: 0.06),
        Pin(T.activityKindPill, "Theme.Fonts.ui(9, weight: .semibold)", 9, .ui, .semibold),
        Pin(T.settingsNavTitle, "Theme.Fonts.ui(12.5, weight: isSelected ? .medium : .regular)", 12.5, .ui),
        Pin(T.settingsNavTitleSelected, "Theme.Fonts.ui(12.5, weight: isSelected ? .medium : .regular)", 12.5, .ui,
            .medium),
        Pin(T.settingsNavGlyph, "Theme.Fonts.ui(12)", 12, .ui),
        Pin(T.settingsSectionCaption, "Theme.Fonts.ui(11, weight: .semibold), .kern: 0.5", 11, .ui, .semibold,
            tracking: 0.5),
        Pin(T.settingsRowTitle, "Theme.Fonts.ui(13)", 13, .ui),
        Pin(T.settingsRowDetail, "Theme.Fonts.ui(11.5)", 11.5, .ui),
        Pin(T.settingsControl, "Theme.Fonts.ui(12)", 12, .ui),
        Pin(T.settingsStatusChip, "Theme.Fonts.mono(11)", 11, .mono),
    ]

    // MARK: 1. Values

    @Test(arguments: pins)
    func everyRoleHoldsTheValuesItReplaced(pin: Pin) {
        let role = pin.role
        // Bit pattern, not `==`: a -0 or a differently rounded decimal would compare equal.
        #expect(role.size.bitPattern == pin.size.bitPattern, "\(role.name): size \(role.size), was \(pin.size)")
        #expect(role.face == pin.face, "\(role.name)")
        #expect(role.weight == pin.weight, "\(role.name): \(role.weight), was \(pin.weight)")
        #expect(role.tracking.bitPattern == pin.tracking.bitPattern, "\(role.name): tracking")
        #expect(role.trackingEm.bitPattern == pin.trackingEm.bitPattern, "\(role.name): trackingEm")
        #expect(role.sizeToken == DesignToken(role.name + ".size", pin.size, .unrounded))
    }

    @Test func everyRoleIsPinnedOnce() {
        let pinned = Self.pins.map(\.role.name)
        #expect(Set(pinned).count == pinned.count, "a role is pinned twice")
        #expect(Set(pinned) == Set(T.roles.map(\.name)), "roles and pins differ")
        #expect(T.roles.count == 35)
        let names = T.roles.map(\.name)
        #expect(Set(names).count == names.count, "duplicate role names")
        for role in T.roles {
            #expect(T.role(named: role.name) == role)
            #expect(role.size > 0 && role.size.isFinite)
        }
        #expect(T.role(named: "Typography.nope") == nil)
    }

    /// `Theme.Fonts.mono` ignores its weight, so every mono role says Regular and names the bundled
    /// face; the UI roles name none (the system font is resolved at run time).
    @Test func monoRolesRecordTheEffectiveFace() {
        for role in T.roles {
            switch role.face {
            case .mono:
                #expect(role.weight == .regular, "\(role.name)")
                #expect(role.postScriptName == "JetBrainsMono-Regular", "\(role.name)")
            case .ui:
                #expect(role.postScriptName == nil, "\(role.name)")
            }
        }
    }

    /// The two roles whose size the Mac takes from `Theme.Fonts` rather than a literal.
    @Test func rolesSizedFromThemeFontsFollowThem() {
        #expect(T.sidebarHeaderCaption.size == Theme.Fonts.ui.caption)
        #expect(T.statusPill.size == Theme.Fonts.mono.detail)
    }

    /// `kern` is the product the Mac computes: `StatusBarView.pillTracking` was
    /// `0.03 * Theme.Fonts.mono.detail`, the prompt pill `font.pointSize * 0.06` at 9 pt.
    @Test func kernIsTheMacsProduct() {
        #expect(T.statusPill.kern.bitPattern == (0.03 * Theme.Fonts.mono.detail).bitPattern)
        #expect(T.promptPill.kern.bitPattern == (Double(9) * 0.06).bitPattern)
        #expect(T.sidebarHeaderCaption.kern == 0.6)
        #expect(T.settingsSectionCaption.kern == 0.5)
        #expect(T.badge.kern == 0)
    }

    /// `name` is the role's Swift path: each declaration's string names the property it is
    /// assigned to.
    @Test func roleNamesSpellTheSwiftPath() throws {
        let url = SourceHygieneTests.moduleDirectory.appendingPathComponent("DesignTokens+Typography.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let declarations = DesignTokensTests.allMatches(
            #"static let (\w+) = Role\.(?:ui|mono)\(\s*"([\w.]+)""#, in: text)
        #expect(declarations.count == T.roles.count, "declared roles and `roles` differ in count")
        for declaration in declarations {
            #expect(declaration[2] == "Typography.\(declaration[1]!)", "\(declaration[2]!)")
        }
        #expect(Set(declarations.map { $0[2]! }) == Set(T.roles.map(\.name)))
    }

    // MARK: 2. The migrated sites

    /// One migrated line: the old expression (gone) and the new one (present `count` times).
    struct Site: Sendable, CustomTestStringConvertible {
        let file: String
        let old: String
        let new: String
        let count: Int
        let roles: [Role]
        init(_ file: String, _ old: String, _ new: String, _ roles: [Role], count: Int = 1) {
            self.file = file
            self.old = old
            self.new = new
            self.count = count
            self.roles = roles
        }
        var testDescription: String { "\(file): \(new)" }
    }

    static func font(_ role: String) -> String { "Theme.Fonts.font(DesignTokens.Typography.\(role))" }

    static let sites: [Site] = [
        Site("Activity/ActivityRowViews.swift", "label.font = Theme.Fonts.ui(9, weight: .semibold)",
             "label.font = " + font("activityKindPill"), [T.activityKindPill]),
        Site("Changes/ChangesViewerView.swift", "title.font = Theme.Fonts.ui(12, weight: .semibold)",
             "title.font = " + font("changesTitle"), [T.changesTitle]),
        Site("Changes/ChangesViewerView.swift", ".font: Theme.Fonts.ui(13, weight: .medium),",
             ".font: " + font("closeGlyph") + ",", [T.closeGlyph]),
        Site("FileViewer/FileViewerView.swift", ".font: Theme.Fonts.mono(13),",
             ".font: " + font("fileViewerText") + ",", [T.fileViewerText]),
        Site("Panes/PaneHeaderView.swift", "private let badgeFont = Theme.Fonts.ui(9, weight: .semibold)",
             "private let badgeFont = " + font("badge"), [T.badge]),
        Site("Tabs/TabStripView.swift", "private let badgeFont = Theme.Fonts.ui(9, weight: .semibold)",
             "private let badgeFont = " + font("badge"), [T.badge]),
        Site("Sidebar/SessionRowView.swift", "private static let badgeFont = Theme.Fonts.ui(9, weight: .semibold)",
             "private static let badgeFont = " + font("badge"), [T.badge]),
        Site("Sidebar/SessionRowView.swift", "private let closeFont = Theme.Fonts.ui(13, weight: .medium)",
             "private let closeFont = " + font("closeGlyph"), [T.closeGlyph]),
        Site("Sidebar/StatusDotView.swift", "NSFont.systemFont(ofSize: 9, weight: .semibold)",
             "NSFont.systemFont(\n            ofSize: CGFloat(DesignTokens.Typography.badge.size),\n"
                + "            weight: DesignTokens.Typography.badge.weight.nsWeight)", [T.badge]),
        Site("Prompt/PromptCardView.swift", "font: Theme.Fonts.ui(9, weight: .bold),",
             "font: " + font("promptPill") + ",", [T.promptPill], count: 2),
        Site("Prompt/PromptCardView.swift", ".kern: font.pointSize * 0.06",
             ".kern: font.pointSize * CGFloat(DesignTokens.Typography.promptPill.trackingEm)", [T.promptPill]),
        Site("Rebase/RebaseSheetView.swift", "titleLabel.font = Theme.Fonts.ui(13, weight: .semibold)",
             "titleLabel.font = " + font("sheetTitle"), [T.sheetTitle]),
        Site("Rebase/RebaseSheetView.swift", "shortcutLabel.font = Theme.Fonts.mono(10)",
             "shortcutLabel.font = " + font("shortcutHint"), [T.shortcutHint]),
        Site("Rebase/RebaseSheetView.swift", "bodyLabel.font = Theme.Fonts.mono(11.5)",
             "bodyLabel.font = " + font("sheetBody"), [T.sheetBody]),
        Site("Rebase/RebaseSheetView.swift",
             "Theme.Fonts.ui(11.5, weight: button === rebaseButton ? .semibold : .regular)",
             "button.font = Theme.Fonts.font(\n                button === rebaseButton\n"
                + "                    ? DesignTokens.Typography.sheetButtonPrimary : DesignTokens.Typography.sheetButton)",
             [T.sheetButtonPrimary, T.sheetButton]),
        Site("Rebase/RebaseSheetView.swift", ".font: Theme.Fonts.mono(11.5),",
             ".font: " + font("sheetBody") + ",", [T.sheetBody], count: 2),
        Site("Settings/SettingsView.swift", "shortcutLabel.font = Theme.Fonts.mono(10)",
             "shortcutLabel.font = " + font("shortcutHint"), [T.shortcutHint]),
        Site("Settings/SettingsView.swift", "Theme.Fonts.ui(12.5, weight: isSelected ? .medium : .regular)",
             "title.font = Theme.Fonts.font(\n            isSelected ? DesignTokens.Typography.settingsNavTitleSelected"
                + " : DesignTokens.Typography.settingsNavTitle)",
             [T.settingsNavTitleSelected, T.settingsNavTitle]),
        Site("Settings/SettingsView.swift", "glyph.font = Theme.Fonts.ui(12)",
             "glyph.font = " + font("settingsNavGlyph"), [T.settingsNavGlyph]),
        Site("Settings/SettingsView.swift", ".font: Theme.Fonts.ui(11, weight: .semibold),",
             ".font: " + font("settingsSectionCaption") + ",", [T.settingsSectionCaption]),
        Site("Settings/SettingsView.swift", ".kern: 0.5,",
             ".kern: DesignTokens.Typography.settingsSectionCaption.tracking,", [T.settingsSectionCaption]),
        Site("Settings/SettingsView.swift", "title.font = Theme.Fonts.ui(13)",
             "title.font = " + font("settingsRowTitle"), [T.settingsRowTitle]),
        Site("Settings/SettingsView.swift", "detail.font = Theme.Fonts.ui(11.5)",
             "detail.font = " + font("settingsRowDetail"), [T.settingsRowDetail]),
        Site("Settings/SettingsView.swift", "popup.font = Theme.Fonts.ui(12)",
             "popup.font = " + font("settingsControl"), [T.settingsControl]),
        Site("Settings/SettingsView.swift", "button.font = Theme.Fonts.ui(12)",
             "button.font = " + font("settingsControl"), [T.settingsControl]),
        Site("Settings/SettingsView.swift", "label.font = Theme.Fonts.mono(11)",
             "label.font = " + font("settingsStatusChip"), [T.settingsStatusChip]),
        Site("Sidebar/GroupRowView.swift", "private let addFont = Theme.Fonts.ui(12)",
             "private let addFont = " + font("groupAdd"), [T.groupAdd]),
        Site("Sidebar/LastMessagePopover.swift", ".systemFont(ofSize: 11)",
             "?? .systemFont(ofSize: CGFloat(DesignTokens.Typography.lastMessage.size))", [T.lastMessage]),
        Site("Sidebar/SidebarHeaderView.swift", ".kern: 0.6,",
             ".kern: DesignTokens.Typography.sidebarHeaderCaption.tracking,", [T.sidebarHeaderCaption]),
        Site("Sidebar/UpdateNoticeView.swift", "private let titleFont = Theme.Fonts.ui(12, weight: .semibold)",
             "private let titleFont = " + font("updateTitle"), [T.updateTitle]),
        Site("Sidebar/UpdateNoticeView.swift", "private let glyphFont = Theme.Fonts.ui(12, weight: .semibold)",
             "private let glyphFont = " + font("updateGlyph"), [T.updateGlyph]),
        Site("Sidebar/UpdateNoticeView.swift", "private let closeFont = Theme.Fonts.ui(11)",
             "private let closeFont = " + font("updateClose"), [T.updateClose]),
        Site("StatusBar/StatusBarView.swift", "static let pillTracking: Double = 0.03 * Theme.Fonts.mono.detail",
             "static let pillTracking: Double = DesignTokens.Typography.statusPill.trackingEm * Theme.Fonts.mono.detail",
             [T.statusPill]),
        Site("Worktree/DeleteMergedWorktreesSheetView.swift", "titleLabel.font = Theme.Fonts.ui(13, weight: .semibold)",
             "titleLabel.font = " + font("sheetTitle"), [T.sheetTitle]),
        Site("Worktree/DeleteMergedWorktreesSheetView.swift", "bodyLabel.font = Theme.Fonts.mono(11.5)",
             "bodyLabel.font = " + font("sheetBody"), [T.sheetBody]),
        Site("Worktree/DeleteMergedWorktreesSheetView.swift", "cancelButton.font = Theme.Fonts.ui(11.5)",
             "cancelButton.font = " + font("sheetButton"), [T.sheetButton]),
        Site("Worktree/DeleteMergedWorktreesSheetView.swift",
             "deleteButton.font = Theme.Fonts.ui(11.5, weight: .semibold)",
             "deleteButton.font = " + font("sheetButtonPrimary"), [T.sheetButtonPrimary]),
        Site("Worktree/DeleteMergedWorktreesSheetView.swift", ".font: Theme.Fonts.ui(11.5),",
             ".font: " + font("sheetCheckbox") + ",", [T.sheetCheckbox]),
        Site("Worktree/DeleteMergedWorktreesSheetView.swift", "views.status.font = Theme.Fonts.mono(10.5)",
             "views.status.font = " + font("sheetListStatus"), [T.sheetListStatus]),
        Site("Worktree/DeleteWorktreeSheetView.swift", "titleLabel.font = Theme.Fonts.ui(13, weight: .semibold)",
             "titleLabel.font = " + font("sheetTitle"), [T.sheetTitle]),
        Site("Worktree/DeleteWorktreeSheetView.swift", "pathLabel.font = Theme.Fonts.mono(11)",
             "pathLabel.font = " + font("sheetPath"), [T.sheetPath]),
        Site("Worktree/DeleteWorktreeSheetView.swift", "branchLabel.font = Theme.Fonts.mono(11.5)",
             "branchLabel.font = " + font("sheetBody"), [T.sheetBody]),
        Site("Worktree/DeleteWorktreeSheetView.swift", "statusLabel.font = Theme.Fonts.mono(11.5)",
             "statusLabel.font = " + font("sheetBody"), [T.sheetBody]),
        Site("Worktree/DeleteWorktreeSheetView.swift", "dirtyLabel.font = Theme.Fonts.mono(11.5)",
             "dirtyLabel.font = " + font("sheetBody"), [T.sheetBody]),
        Site("Worktree/DeleteWorktreeSheetView.swift", ".font: Theme.Fonts.ui(11.5),",
             ".font: " + font("sheetCheckbox") + ",", [T.sheetCheckbox]),
        Site("Worktree/DeleteWorktreeSheetView.swift", "cancelButton.font = Theme.Fonts.ui(11.5)",
             "cancelButton.font = " + font("sheetButton"), [T.sheetButton]),
        Site("Worktree/DeleteWorktreeSheetView.swift", "deleteButton.font = Theme.Fonts.ui(11.5, weight: .semibold)",
             "deleteButton.font = " + font("sheetButtonPrimary"), [T.sheetButtonPrimary]),
        Site("Worktree/DeleteWorktreeSheetView.swift",
             "deleteBranchButton.font = Theme.Fonts.ui(11.5, weight: .semibold)",
             "deleteBranchButton.font = " + font("sheetButtonPrimary"), [T.sheetButtonPrimary]),
        Site("FileViewer/MarkdownRenderer.swift", "static let bodySize: CGFloat = 13.5",
             "static let bodySize = CGFloat(DesignTokens.Typography.markdownBody.size)", [T.markdownBody]),
        Site("FileViewer/MarkdownRenderer.swift", "static let codeSize: CGFloat = 12.5",
             "static let codeSize = CGFloat(DesignTokens.Typography.markdownCode.size)", [T.markdownCode]),
        Site("FileViewer/MarkdownRenderer.swift", "case 1: 22",
             "case 1: CGFloat(DesignTokens.Typography.markdownHeading1.size)", [T.markdownHeading1]),
        Site("FileViewer/MarkdownRenderer.swift", "case 2: 18",
             "case 2: CGFloat(DesignTokens.Typography.markdownHeading2.size)", [T.markdownHeading2]),
        Site("FileViewer/MarkdownRenderer.swift", "case 3: 15.5",
             "case 3: CGFloat(DesignTokens.Typography.markdownHeading3.size)", [T.markdownHeading3]),
        Site("FileViewer/MarkdownRenderer.swift", "default: 14",
             "default: CGFloat(DesignTokens.Typography.markdownHeading4.size)", [T.markdownHeading4]),
    ]

    static func source(_ file: String) throws -> String {
        try String(contentsOf: SourceHygieneTests.repoRoot.appendingPathComponent("Sources/TkzApp/" + file),
                   encoding: .utf8)
    }

    @Test(arguments: sites)
    func everySiteReadsItsRole(site: Site) throws {
        let text = try Self.source(site.file)
        #expect(!text.contains(site.old), "\(site.file) still has `\(site.old)`")
        let found = text.components(separatedBy: site.new).count - 1
        #expect(found == site.count, "\(site.file): `\(site.new)` \(found) times, expected \(site.count)")
        for role in site.roles {
            let property = String(role.name.dropFirst("Typography.".count))
            #expect(site.new.contains("DesignTokens.Typography.\(property)"), "\(site.new) does not read \(role.name)")
        }
        // An old plain font call parses back to exactly the role that replaced it.
        if let call = Self.firstMatch(
            #"(?:Theme\.Fonts\.(ui|mono)|systemFont)\((?:ofSize: )?([0-9.]+)(?:, weight: \.(\w+))?\)"#, in: site.old) {
            let role = try #require(site.roles.count == 1 ? site.roles[0] : nil)
            #expect(role.face == (call[1] == "mono" ? .mono : .ui), "\(role.name)")
            #expect(role.size == Double(call[2]!), "\(role.name): \(role.size), was \(call[2]!)")
            #expect(role.weight.rawValue == (call[3] ?? "regular"), "\(role.name): \(role.weight), was \(call[3] ?? "regular")")
        }
    }

    @Test func everyRoleIsReadOnTheMac() {
        let read = Set(Self.sites.flatMap { $0.roles.map(\.name) })
        let unread = T.roles.map(\.name).filter { !read.contains($0) }
        #expect(unread.isEmpty, "roles no Mac site reads: \(unread)")
    }

    /// `Theme.Fonts.font(_:)` hands a mono role to `mono(size)` with no weight, as every migrated
    /// mono call did, and a UI role to `ui(size, weight:)`.
    @Test func theAppKitResolverPassesWhatTheLiteralCallsPassed() throws {
        let text = try Self.source("ThemeAppKit.swift")
        #expect(text.contains("case .ui: ui(role.size, weight: role.weight.nsWeight)"))
        #expect(text.contains("case .mono: mono(role.size)\n"))
        for weight in Role.Weight.allCases {
            #expect(text.contains("case .\(weight.rawValue): .\(weight.rawValue)\n"), "\(weight)")
        }
    }

    // MARK: 3. The S4 grep

    /// WOR-307 S4's done-when, as a test: no literal-size font call and no numeric `.kern` in TkzApp
    /// outside a `// token-exempt: <reason>` line.
    @Test func theLiteralFontGrepIsEmpty() throws {
        let files = try SourceHygieneTests.swiftSources(under: "Sources/TkzApp")
        #expect(files.count > 50)
        let regex = try NSRegularExpression(pattern: Self.literalFontPattern)
        var hits: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(line)
                if line.contains("// token-exempt:") { continue }
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    hits.append("\(url.lastPathComponent):\(number + 1): \(line)")
                }
            }
        }
        #expect(hits.isEmpty, "literal font sizes or kerning outside DesignTokens: \(hits)")
    }

    /// The issue's grep, `grep -rnE '\.(ui|mono)\([0-9]|ofSize: [0-9]|\.kern: [^,\]]*[0-9]'`.
    static let literalFontPattern = #"\.(ui|mono)\([0-9]|ofSize: [0-9]|\.kern: [^,\]]*[0-9]"#

    @Test func theGrepWouldCatchTheOldCalls() throws {
        let regex = try NSRegularExpression(pattern: Self.literalFontPattern)
        for line in [
            "label.font = Theme.Fonts.ui(9, weight: .semibold)", "x.font = Theme.Fonts.mono(11.5)",
            "NSFont.systemFont(ofSize: 9, weight: .semibold)", ".kern: 0.6,",
            "attributes: [.font: font, .kern: font.pointSize * 0.06])",
        ] {
            #expect(regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil, "\(line)")
        }
        for site in Self.sites {
            for line in site.new.split(separator: "\n").map(String.init) {
                #expect(regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil, "\(line)")
            }
        }
    }

    // MARK: 4. Measured line metrics

    /// Generated on the reference runner (`ComponentSnapshotTypographyTests`): until then empty;
    /// after, one entry per role, mono roles in the bundled face.
    @Test func measuredLineMetricsAreAbsentOrComplete() {
        if T.measured.isEmpty {
            #expect(T.measuredOn.isEmpty)
            #expect(T.roles.allSatisfy { $0.lineHeight == nil && $0.baseline == nil })
            return
        }
        #expect(!T.measuredOn.isEmpty)
        #expect(Set(T.measured.keys) == Set(T.roles.map(\.name)), "measured roles and `roles` differ")
        for role in T.roles {
            guard let metrics = role.lineMetrics else { continue }
            #expect(metrics.lineHeight > 0 && metrics.baseline > 0, "\(role.name)")
            #expect(metrics.ascender > 0 && metrics.descender <= 0, "\(role.name)")
            if let face = role.postScriptName { #expect(metrics.fontName == face, "\(role.name)") }
        }
    }

    static func firstMatch(_ pattern: String, in text: String) -> [String?]? {
        DesignTokensTests.firstMatch(pattern, in: text)
    }
}
