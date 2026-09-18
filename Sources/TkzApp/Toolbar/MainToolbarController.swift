// MainToolbarController.swift — the 48 pt unified title bar of the main window.
//
// design.md → App architecture → Toolbar:
//   title “<session> — <group>”; `NSMenuToolbarItem` “＋ New session…” scoped to the selected group;
//   “Search sessions…” (⌘F, printed in the field); the three right-hand buttons (`>_` new terminal, `◫`/`⬓` splits).
//   The Kanban board, a calendar symbol, sits right after `>_` (2026-09-18) — not in the design, which predates the board.
//   The design's fourth button, `◍` browser, was dropped rather than shipped disabled.
//
// This wave builds the chrome only. The controller owns no application state and holds no
// reference to a window controller or store: every action is a closure the assembler assigns, and
// the “＋ New session…” menu is a stub that M2.4 replaces via ``newSessionMenu``.

import AppKit
import TkzCore

public extension NSToolbarItem.Identifier {
    /// `NSMenuToolbarItem` — “＋ New session…”.
    static let tkzNewSession = NSToolbarItem.Identifier("tkzmux.newSession")
    /// Centred label — “<session> — <group>”. Registered in `centeredItemIdentifiers`.
    static let tkzTitle = NSToolbarItem.Identifier("tkzmux.title")
    /// `NSSearchToolbarItem` — “Search sessions…” (⌘F).
    static let tkzSearch = NSToolbarItem.Identifier("tkzmux.search")
    /// The `NSSegmentedControl` cluster: `>_`, the calendar symbol, `◫`, `⬓`, `☾`.
    static let tkzViewCluster = NSToolbarItem.Identifier("tkzmux.viewCluster")
}

/// Builds and owns the main window's `NSToolbar`.
///
/// Assign the `on…` closures before handing ``toolbar`` to a window. Call ``setTitle(session:group:)``
/// whenever the selection changes.
@MainActor
public final class MainToolbarController: NSObject, NSToolbarDelegate {
    /// The right-hand buttons, in order. `rawValue` doubles as the segment index.
    public enum ViewButton: Int, CaseIterable, Sendable {
        case terminal = 0   // >_
        case board = 1      // a calendar symbol — see `symbolName`
        case splitV = 2     // ◫ in the design; drawn as a symbol — see `symbolName`
        case splitH = 3     // ⬓ in the design; drawn as a symbol
        case theme = 4      // ☾ / ☀

        /// The glyph reflects the theme that is *on*, which is what the artboards draw: 2c shows ☾,
        /// its light twin shows ☀. Only `.theme` varies, hence the parameter.
        ///
        /// Empty for a button that draws a symbol instead (`symbolName`): a segment with both would
        /// show both.
        func glyph(isDark: Bool) -> String {
            switch self {
            case .terminal: ">_"
            case .board, .splitV, .splitH: ""
            case .theme: isDark ? "\u{263E}" : "\u{2600}"   // ☾ / ☀
            }
        }

        /// Tooltip, and the closest thing the cluster has to an accessibility label. `.theme` names
        /// the *action*, not the glyph: "☾" alone reads as "last quarter moon" to VoiceOver, and the
        /// menu item and palette row are the properly labelled path to the same command.
        func label(isDark: Bool) -> String {
            switch self {
            // Deliberately "session": this button makes a whole new row running a bare shell, not
            // another terminal inside this one. ⌘T is the latter, and the two would
            // otherwise read as the same verb.
            case .terminal: "New shell session"
            case .board: "Show the board"
            case .splitV: "Split vertically"
            case .splitH: "Split horizontally"
            case .theme: isDark ? "Switch to the light theme" : "Switch to the dark theme"
            }
        }

        /// The SF Symbol a button draws instead of a text glyph.
        ///
        /// The board came first: Unicode has no calendar that reads at 12 pt (📅 is an emoji and
        /// ignores the control's tint). The two splits followed it (2026-09-18): as text, `◫`/`⬓`
        /// are ~7.5 pt squares at `clusterGlyphSize` and looked small beside the calendar, and the
        /// control has one font for every segment, so they could not be enlarged without `>_` and
        /// `☾` growing too. Symbols at one point size share a height by design, and a template
        /// image takes the segment's colour in both themes for free.
        var symbolName: String? {
            switch self {
            case .board: "calendar"
            case .splitV: "rectangle.split.2x1"   // side by side — the design's ◫
            case .splitH: "rectangle.split.1x2"   // stacked — the design's ⬓
            case .terminal, .theme: nil
            }
        }
    }

    /// Point size of the cluster's symbols — one size for all three, which is what makes the
    /// calendar and the splits the same height. Chosen by eye against a 4× render: 15 pt dwarfed
    /// the text glyphs either side, and much under 10 pt the calendar's date dots smear.
    static let clusterSymbolSize: Double = 10.5

    /// The image for a symbol button, or `nil` for a text one.
    static func symbolImage(for button: ViewButton, isDark: Bool) -> NSImage? {
        guard let name = button.symbolName else { return nil }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: button.label(isDark: isDark))
        let sized = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: clusterSymbolSize, weight: .medium))
        sized?.isTemplate = true
        return sized
    }

    /// Point size of the cluster glyphs. Toolbar chrome, not a theme token: the sidebar's 10 pt
    /// `detail` size read too small for `◫`/`⬓` in the 48 pt bar.
    static let clusterGlyphSize: Double = 12

    public let toolbar: NSToolbar

    /// Invoked when the `>_` button is clicked: a new bare-shell *session row*.
    public var onNewTerminal: (() -> Void)?
    /// The calendar button — toggle the Kanban board over the terminal.
    public var onToggleBoard: (() -> Void)?
    /// `◫` — split the selected session's focused pane side by side.
    public var onSplitVertically: (() -> Void)?
    /// `⬓` — split it stacked.
    public var onSplitHorizontally: (() -> Void)?
    /// `☾`/`☀` — flip between the dark preset and its light twin.
    public var onToggleTheme: (() -> Void)?
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

    /// The chord bound to `searchSessions`, printed in the search field's placeholder and tooltip
    /// so the key is discoverable. The window controller assigns the resolved binding, so a user
    /// override shows its own chord; `nil` (unbound) drops the hint rather than printing a lie.
    public var searchShortcut: Shortcut? = ShortcutsTable.defaults[.searchSessions] {
        didSet { if searchShortcut != oldValue { applySearchShortcut() } }
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

    /// The unstyled centred title, e.g. `"feature-x — tkzmux"`.
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

    /// The stub menu for this wave. M2.4 replaces it with the real, group-scoped menu
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

    /// `"Search sessions…  ⌘F"` — two spaces so the chord reads as a hint, not part of the phrase.
    var searchPlaceholder: String {
        guard let searchShortcut else { return "Search sessions\u{2026}" }
        return "Search sessions\u{2026}  \(searchShortcut.displayString)"
    }

    private func applySearchShortcut() {
        guard let searchItem else { return }
        searchItem.searchField.placeholderString = searchPlaceholder
        searchItem.toolTip = searchShortcut.map { "Search sessions (\($0.displayString))" } ?? "Search sessions"
    }

    private func applyTheme() {
        titleField?.attributedStringValue = titleString()
        // The ☾/☀ segment shows the theme that is on, so it has to be relabelled here rather than
        // only at build time.
        if let control = segmented {
            for button in ViewButton.allCases {
                control.setLabel(button.glyph(isDark: theme.isDark), forSegment: button.rawValue)
                control.setToolTip(button.label(isDark: theme.isDark), forSegment: button.rawValue)
            }
        }
    }

    // MARK: Actions

    /// Runs the action behind one cluster button. The `@objc` click handler funnels through here;
    /// tests drive it directly because a `.momentary` `NSSegmentedControl` does not keep
    /// `selectedSegment` outside a real click.
    func activate(_ button: ViewButton) {
        switch button {
        case .terminal: onNewTerminal?()
        case .board: onToggleBoard?()
        case .splitV: onSplitVertically?()
        case .splitH: onSplitHorizontally?()
        case .theme: onToggleTheme?()
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
        item.searchField.font = Theme.Fonts.ui(theme.fontUI.body)
        item.searchField.sendsWholeSearchString = false
        item.searchField.sendsSearchStringImmediately = true
        item.searchField.target = self
        item.searchField.action = #selector(searchChanged(_:))
        item.searchField.delegate = self
        searchItem = item
        applySearchShortcut()
        return item
    }

    private func makeViewClusterItem() -> NSToolbarItem {
        let control = NSSegmentedControl(
            labels: ViewButton.allCases.map { $0.glyph(isDark: theme.isDark) },
            trackingMode: .momentary,
            target: self,
            action: #selector(segmentClicked(_:))
        )
        control.segmentStyle = .texturedRounded
        control.font = Theme.Fonts.mono(Self.clusterGlyphSize, weight: .medium)
        for button in ViewButton.allCases {
            control.setToolTip(button.label(isDark: theme.isDark), forSegment: button.rawValue)
            if let image = Self.symbolImage(for: button, isDark: theme.isDark) {
                control.setImage(image, forSegment: button.rawValue)
                // Drawn at the size it was configured at, not squeezed to the text's line height.
                control.setImageScaling(.scaleNone, forSegment: button.rawValue)
            }
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
