// MainToolbarController.swift — the 48 pt unified title bar of the main window.
//
// design.md → App architecture → Toolbar:
//   title “<session> — <group>”; `NSMenuToolbarItem` “＋ New session…” scoped to the selected group;
//   “Search sessions…” (⌘P); the four right-hand buttons from the design
//   (`>_` new terminal, `◍` browser, `◫`/`⬓` splits — last three disabled in v1).
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
    /// The four-button `NSSegmentedControl` cluster; only `>_` is enabled in v1.
    static let tkzViewCluster = NSToolbarItem.Identifier("tkzmux.viewCluster")
}

/// Builds and owns the main window's `NSToolbar`.
///
/// Assign the `on…` closures before handing ``toolbar`` to a window. Call ``setTitle(session:group:)``
/// whenever the selection changes.
@MainActor
public final class MainToolbarController: NSObject, NSToolbarDelegate {
    /// The four right-hand buttons, in order. Only ``terminal`` is available in v1.
    public enum ViewButton: Int, CaseIterable, Sendable {
        case terminal = 0   // >_
        case browser = 1    // ◍
        case splitV = 2     // ◫
        case splitH = 3     // ⬓

        var glyph: String {
            switch self {
            case .terminal: ">_"
            case .browser: "\u{25CD}"   // ◍
            case .splitV: "\u{25EB}"    // ◫
            case .splitH: "\u{2B13}"    // ⬓
            }
        }

        var label: String {
            switch self {
            case .terminal: "New terminal"
            case .browser: "Browser"
            case .splitV: "Split vertically"
            case .splitH: "Split horizontally"
            }
        }

        /// v1 ships the terminal only; design.md marks the other three as later work.
        var isAvailableInV1: Bool { self == .terminal }
    }

    /// Tooltip on every button that v1 does not implement.
    public static let unavailableTooltip = "Coming later"

    public let toolbar: NSToolbar

    /// Invoked when the enabled `>_` button is clicked.
    public var onNewTerminal: (() -> Void)?
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
    /// (*New worktree (claude -w)*, *In repo root (claude)*, *In another repo…*, *From preset…*,
    /// Account submenu).
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

    /// Runs the action behind one cluster button, ignoring the three that v1 does not implement.
    /// The `@objc` click handler funnels through here; tests drive it directly because a
    /// `.momentary` `NSSegmentedControl` does not keep `selectedSegment` outside a real click.
    func activate(_ button: ViewButton) {
        guard button.isAvailableInV1 else { return }
        switch button {
        case .terminal: onNewTerminal?()
        case .browser, .splitV, .splitH: break
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
        control.font = Theme.Fonts.mono(theme.fontMono.detail, weight: .medium)
        for button in ViewButton.allCases {
            control.setEnabled(button.isAvailableInV1, forSegment: button.rawValue)
            control.setToolTip(
                button.isAvailableInV1 ? button.label : Self.unavailableTooltip,
                forSegment: button.rawValue
            )
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
