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
    /// ⌘↵ — 2c.6 prints it next to the Actions row, so it skips the selection and runs that.
    public var onSearchCommandSubmit: ((String) -> Void)?
    /// ↓ = `+1`, ↑ = `-1`. The results overlay (design 2c.6) is a separate window that never takes
    /// key, so the list keys have to be relayed from this field's editor.
    public var onSearchMove: ((Int) -> Void)?
    /// Tab / → = `+1`, ⇧Tab / ← = `-1` — cycles the overlay's scope chips.
    ///
    /// Returns whether it was handled, because ← and → mean something else when there is no
    /// overlay: they move the caret. Consuming them unconditionally would break editing a query
    /// in a field that is not searching anything.
    public var onSearchCycleScope: ((Int) -> Bool)?
    /// Escape in the search field.
    public var onSearchCancel: (() -> Void)?
    /// The field stopped editing — focus went somewhere else, so nothing should be left floating.
    public var onSearchEndEditing: (() -> Void)?

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

// MARK: - Search keys

extension MainToolbarController: NSSearchFieldDelegate {
    /// The search field keeps first responder for the whole life of the results overlay, so every
    /// key the overlay needs arrives here as an editor command and is relayed to the window
    /// controller. Returning `true` consumes the key — that is what stops ↑/↓ moving the caret and
    /// tab walking the responder chain out of the field.
    ///
    /// Plain keystrokes are *not* handled here: they come through the field's target/action
    /// (``searchChanged(_:)``) already, and adding `controlTextDidChange` as well would rebuild the
    /// list twice per character.
    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard let field = control as? NSSearchField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // Cocoa sends the same editor command for ↵ and ⌘↵; the live event is what tells them
            // apart, and 2c.6 gives them different jobs.
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                onSearchCommandSubmit?(field.stringValue)
            } else {
                onSearchSubmit?(field.stringValue)
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            onSearchMove?(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            onSearchMove?(-1)
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab is consumed either way: letting it through walks the responder chain out of the
            // field, which is never what a half-typed query wants.
            _ = onSearchCycleScope?(1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            _ = onSearchCycleScope?(-1)
            return true
        case #selector(NSResponder.moveRight(_:)):
            // ← / → cycle the chips while the overlay is up, and move the caret when it is not.
            // Word-wise movement (⌥← / ⌥→) and Home/End are untouched either way.
            return onSearchCycleScope?(1) ?? false
        case #selector(NSResponder.moveLeft(_:)):
            return onSearchCycleScope?(-1) ?? false
        case #selector(NSResponder.cancelOperation(_:)):
            onSearchCancel?()
            return true
        default:
            return false
        }
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchItem?.searchField else { return }
        onSearchEndEditing?()
    }
}
