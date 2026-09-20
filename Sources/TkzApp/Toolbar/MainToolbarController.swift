// MainToolbarController.swift — the 48 pt unified title bar of the main window.
//
// Layout: the centred title “<session> — <group>” and the four right-hand buttons (`>_` new
// terminal, `◫`/`⬓` splits, `☾`/`☀` theme). The design's fifth button, `◍` browser, was dropped
// rather than shipped disabled.
//
// The bar used to carry “＋ New session…” and a “Search sessions…” field as well. Both were taken
// out in the 2026-09-20 GUI pass: the field was a wide, permanently-empty box that cost the title
// its room, and neither command lost a way in — ⌘N and ⌘F still run them, ⇧⌘P lists them, and new
// sessions keep the sidebar's per-group ＋. See docs/shortcuts.md.
//
// The controller owns no application state and holds no reference to a window controller or store:
// every action is a closure the assembler assigns.

import AppKit
import TkzCore

public extension NSToolbarItem.Identifier {
    /// Centred label — “<session> — <group>”. Registered in `centeredItemIdentifiers`.
    static let tkzTitle = NSToolbarItem.Identifier("tkzmux.title")
    /// The four-button `NSSegmentedControl` cluster: `>_`, `◫`, `⬓`, `☾`/`☀`.
    static let tkzViewCluster = NSToolbarItem.Identifier("tkzmux.viewCluster")
}

/// Builds and owns the main window's `NSToolbar`.
///
/// Assign the `on…` closures before handing ``toolbar`` to a window. Call ``setTitle(session:group:)``
/// whenever the selection changes.
@MainActor
public final class MainToolbarController: NSObject, NSToolbarDelegate {
    /// The four right-hand buttons, in order. `rawValue` doubles as the segment index.
    public enum ViewButton: Int, CaseIterable, Sendable {
        case terminal = 0   // >_
        case splitV = 1     // ◫
        case splitH = 2     // ⬓
        case theme = 3      // ☾ / ☀

        /// The glyph reflects the theme that is *on*, which is what the artboards draw: 2c shows ☾,
        /// its light twin shows ☀. Only `.theme` varies, hence the parameter.
        func glyph(isDark: Bool) -> String {
            switch self {
            case .terminal: ">_"
            case .splitV: "\u{25EB}"    // ◫
            case .splitH: "\u{2B13}"    // ⬓
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
            case .splitV: "Split vertically"
            case .splitH: "Split horizontally"
            case .theme: isDark ? "Switch to the light theme" : "Switch to the dark theme"
            }
        }
    }

    /// Point size of the cluster glyphs. Toolbar chrome, not a theme token: the sidebar's 10 pt
    /// `detail` size read too small for `◫`/`⬓` in the 48 pt bar.
    static let clusterGlyphSize: Double = 12

    public let toolbar: NSToolbar

    /// Invoked when the `>_` button is clicked: a new bare-shell *session row*.
    public var onNewTerminal: (() -> Void)?
    /// `◫` — split the selected session's focused pane side by side.
    public var onSplitVertically: (() -> Void)?
    /// `⬓` — split it stacked.
    public var onSplitHorizontally: (() -> Void)?
    /// `☾`/`☀` — flip between the dark preset and its light twin.
    public var onToggleTheme: (() -> Void)?

    public var theme: Theme {
        didSet { if theme != oldValue { applyTheme() } }
    }

    private var titleField: NSTextField?
    private var segmented: NSSegmentedControl?

    private var sessionTitle: String = ""
    private var groupTitle: String?

    public init(theme: Theme = .default, identifier: String = "tkzmux.main") {
        self.theme = theme
        self.toolbar = NSToolbar(identifier: identifier)
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
        case .splitV: onSplitVertically?()
        case .splitH: onSplitHorizontally?()
        case .theme: onToggleTheme?()
        }
    }

    @objc private func segmentClicked(_ sender: NSSegmentedControl) {
        guard let button = ViewButton(rawValue: sender.selectedSegment) else { return }
        activate(button)
    }

    // MARK: NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .tkzTitle, .flexibleSpace, .tkzViewCluster]
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
        case .tkzTitle: makeTitleItem()
        case .tkzViewCluster: makeViewClusterItem()
        default: nil
        }
    }

    // MARK: Item construction

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
    /// The live centred title label, once the toolbar has vended the title item.
    var titleLabel: NSTextField? { titleField }
}
