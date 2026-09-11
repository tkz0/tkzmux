// MainToolbarController.swift — the 48 pt unified title bar of the main window.
//
// design.md → App architecture → Toolbar:
//   title “<session> — <group>”; `NSMenuToolbarItem` “＋ New session…” scoped to the selected group;
//   “Search sessions…” (⌘P); the three right-hand buttons (`>_` new terminal, `◫`/`⬓` splits).
//   The design's fourth button, `◍` browser, was dropped in TKZ-57 rather than shipped disabled.
//
// This wave builds the chrome only. The controller owns no application state and holds no
// reference to a window controller or store: every action is a closure the assembler assigns, and
// the “＋ New session…” menu is a stub that M2.4 (TKZ-20) replaces via ``newSessionMenu``.

import AppKit
import TkzCore

public extension NSToolbarItem.Identifier {
    /// `NSMenuToolbarItem` — “＋ New session…”.
    static let tkzNewSession = NSToolbarItem.Identifier("tkzmux.newSession")
    /// Centred label — “<session> — <group>”. Registered in `centeredItemIdentifiers`.
    static let tkzTitle = NSToolbarItem.Identifier("tkzmux.title")
    /// `NSSearchToolbarItem` — “Search sessions…” (⌘P).
    static let tkzSearch = NSToolbarItem.Identifier("tkzmux.search")
    /// The three-button `NSSegmentedControl` cluster: `>_`, `◫`, `⬓`.
    static let tkzViewCluster = NSToolbarItem.Identifier("tkzmux.viewCluster")
}

/// Builds and owns the main window's `NSToolbar`.
///
/// Assign the `on…` closures before handing ``toolbar`` to a window. Call ``setTitle(session:group:)``
/// whenever the selection changes.
@MainActor
public final class MainToolbarController: NSObject, NSToolbarDelegate {
    /// The three right-hand buttons, in order. `rawValue` doubles as the segment index.
    public enum ViewButton: Int, CaseIterable, Sendable {
        case terminal = 0   // >_
        case splitV = 1     // ◫
        case splitH = 2     // ⬓

        var glyph: String {
            switch self {
            case .terminal: ">_"
            case .splitV: "\u{25EB}"    // ◫
            case .splitH: "\u{2B13}"    // ⬓
            }
        }

        var label: String {
            switch self {
            // Deliberately "session": this button makes a whole new row running a bare shell, not
            // another terminal inside this one. ⌘T is the latter (TKZ-36), and the two would
            // otherwise read as the same verb.
            case .terminal: "New shell session"
            case .splitV: "Split vertically"
            case .splitH: "Split horizontally"
            }
        }
    }

    /// Point size of the cluster glyphs. Toolbar chrome, not a theme token: the sidebar's 10 pt
    /// `detail` size read too small for `◫`/`⬓` in the 48 pt bar (TKZ-57).
    static let clusterGlyphSize: Double = 12

    public let toolbar: NSToolbar

    /// Invoked when the `>_` button is clicked: a new bare-shell *session row*.
    public var onNewTerminal: (() -> Void)?
    /// `◫` — split the selected session's focused pane side by side.
    public var onSplitVertically: (() -> Void)?
    /// `⬓` — split it stacked.
    public var onSplitHorizontally: (() -> Void)?
    /// Invoked on every keystroke in the search field, with the current query.
    public var onSearchChanged: ((String) -> Void)?
    /// Invoked when the user presses Return in the search field.
    public var onSearchSubmit: ((String) -> Void)?

    /// The menu shown by “＋ New session…”. Defaults to ``stubNewSessionMenu()``; M2.4 replaces it
    /// with the group-scoped menu from design.md. Setting it updates the live toolbar item.
    public var newSessionMenu: NSMenu {
        didSet { menuItem?.menu = newSessionMenu }
    }

    public var theme: Theme {
        didSet { if theme != oldValue { applyTheme() } }
    }

    private var titleField: NSTextField?
    private var menuItem: NSMenuToolbarItem?
    private var segmented: NSSegmentedControl?
    private var searchItem: NSSearchToolbarItem?

    private var sessionTitle: String = ""
    private var groupTitle: String?

    public init(theme: Theme = .default, identifier: String = "tkzmux.main") {
        self.theme = theme
        self.toolbar = NSToolbar(identifier: identifier)
        self.newSessionMenu = Self.stubNewSessionMenu()
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifiers = [.tkzTitle]
    }

    // MARK: Content

    /// Sets the centred title. `group` is `nil` for a session that is not in a group, in which case
    /// the “ — <group>” half is omitted rather than left dangling.
    public func setTitle(session: String, group: String?) {
        sessionTitle = session
        groupTitle = group
        titleField?.attributedStringValue = titleString()
        titleField?.toolTip = plainTitle
    }

    /// The unstyled centred title, e.g. `"TKZ-18 — tkzmux"`.
    public var plainTitle: String {
        guard let groupTitle, !groupTitle.isEmpty else { return sessionTitle }
        return "\(sessionTitle) \u{2014} \(groupTitle)"   // em dash
    }

    /// Session name in the design's title style, group in the muted subtitle style.
    private func titleString() -> NSAttributedString {
        let out = NSMutableAttributedString(string: sessionTitle, attributes: [
            .font: Theme.Fonts.ui(theme.fontUI.title, weight: .medium),
            .foregroundColor: theme.foreground.nsColor,
        ])
        if let groupTitle, !groupTitle.isEmpty {
            out.append(NSAttributedString(string: " \u{2014} \(groupTitle)", attributes: [
                .font: Theme.Fonts.ui(theme.fontUI.body),
                .foregroundColor: theme.foregroundMuted.nsColor,
            ]))
        }
        return out
    }

    /// The stub menu for this wave. M2.4 (TKZ-20) replaces it with the real, group-scoped menu
    /// (*New worktree (claude -w)*, *In repo root (claude)*, *In another repo…*, Account
    /// submenu).
    public static func stubNewSessionMenu() -> NSMenu {
        let menu = NSMenu()
        let placeholder = NSMenuItem(title: "New session\u{2026}", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        menu.addItem(placeholder)
        menu.autoenablesItems = false
        return menu
    }

    private func applyTheme() {
        titleField?.attributedStringValue = titleString()
    }

    // MARK: Actions

    /// Runs the action behind one cluster button. The `@objc` click handler funnels through here;
    /// tests drive it directly because a `.momentary` `NSSegmentedControl` does not keep
    /// `selectedSegment` outside a real click.
    func activate(_ button: ViewButton) {
        switch button {
        case .terminal: onNewTerminal?()
        case .splitV: onSplitVertically?()
        case .splitH: onSplitHorizontally?()
        }
    }

    @objc private func segmentClicked(_ sender: NSSegmentedControl) {
        guard let button = ViewButton(rawValue: sender.selectedSegment) else { return }
        activate(button)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        onSearchChanged?(sender.stringValue)
    }

    // MARK: NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.tkzNewSession, .flexibleSpace, .tkzTitle, .flexibleSpace, .tkzSearch, .tkzViewCluster]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .tkzNewSession: makeNewSessionItem()
        case .tkzTitle: makeTitleItem()
        case .tkzSearch: makeSearchItem()
        case .tkzViewCluster: makeViewClusterItem()
        default: nil
        }
    }

    // MARK: Item construction

    private func makeNewSessionItem() -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .tkzNewSession)
        item.title = "\u{FF0B} New session\u{2026}"   // ＋ New session…
        item.label = "New session"
        item.paletteLabel = "New session"
        item.toolTip = "Start a Claude Code session in the selected group"
        item.showsIndicator = true
        item.menu = newSessionMenu
        item.isBordered = true
        menuItem = item
        return item
    }

    private func makeTitleItem() -> NSToolbarItem {
        let field = NSTextField(labelWithAttributedString: titleString())
        field.lineBreakMode = .byTruncatingTail
        field.alignment = .center
        field.toolTip = plainTitle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField = field

        let item = NSToolbarItem(itemIdentifier: .tkzTitle)
        item.view = field
        item.label = "Title"
        item.paletteLabel = "Title"
        item.visibilityPriority = .high
        return item
    }

    private func makeSearchItem() -> NSSearchToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: .tkzSearch)
        item.label = "Search"
        item.paletteLabel = "Search sessions"
        item.toolTip = "Search sessions (\u{2318}P)"
        item.searchField.placeholderString = "Search sessions\u{2026}"
        item.searchField.font = Theme.Fonts.ui(theme.fontUI.body)
        item.searchField.sendsWholeSearchString = false
        item.searchField.sendsSearchStringImmediately = true
        item.searchField.target = self
        item.searchField.action = #selector(searchChanged(_:))
        item.searchField.delegate = self
        searchItem = item
        return item
    }

    private func makeViewClusterItem() -> NSToolbarItem {
        let control = NSSegmentedControl(
            labels: ViewButton.allCases.map(\.glyph),
            trackingMode: .momentary,
            target: self,
            action: #selector(segmentClicked(_:))
        )
        control.segmentStyle = .texturedRounded
        control.font = Theme.Fonts.mono(Self.clusterGlyphSize, weight: .medium)
        for button in ViewButton.allCases {
            control.setToolTip(button.label, forSegment: button.rawValue)
        }
        segmented = control

        let item = NSToolbarItem(itemIdentifier: .tkzViewCluster)
        item.view = control
        item.label = "View"
        item.paletteLabel = "View"
        item.visibilityPriority = .high
        return item
    }

    // MARK: Test / assembly access

    /// The live segmented control, once the toolbar has vended the cluster item.
    var viewClusterControl: NSSegmentedControl? { segmented }
    /// The live search field, once the toolbar has vended the search item.
    var searchField: NSSearchField? { searchItem?.searchField }
    /// The live centred title label, once the toolbar has vended the title item.
    var titleLabel: NSTextField? { titleField }
}

// MARK: - Search submit

extension MainToolbarController: NSSearchFieldDelegate {
    /// Return in the search field means "commit this query" (⌘P's jump-to-session). Keystrokes
    /// already arrive through ``onSearchChanged``; this only adds the explicit submit.
    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),
              let field = control as? NSSearchField else { return false }
        onSearchSubmit?(field.stringValue)
        return true
    }
}
