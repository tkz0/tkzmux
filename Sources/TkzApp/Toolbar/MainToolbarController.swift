// MainToolbarController.swift — the 48 pt unified title bar of the main window.
//
// Layout: the centred title “<session> — <group>”, the ▶ Run split button, and the four
// right-hand buttons (`>_` new terminal, `◫`/`⬓` splits, `☾`/`☀` theme). The design's fifth
// button, `◍` browser, was dropped rather than shipped disabled.
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
    /// `▶ pnpm dev | ▾` — run the selected row's dev server, or pick another task.
    static let tkzRun = NSToolbarItem.Identifier("tkzmux.run")
}

/// What the ▶ Run button shows for the selected row. Built by the window controller from the
/// store and `RunTaskDetector`; the toolbar only draws it.
public struct RunButtonModel: Equatable, Sendable {
    /// What ▶ runs: the group's remembered command, else the best guess. `nil` = nothing to guess,
    /// so the button reads `▶ Run…` and its click opens the menu.
    public var command: String?
    /// The command the row's run pane is running right now, if it is — the button reads `■` then.
    public var running: String?
    /// The group's remembered command, if any: what "Reset to Detected" would clear.
    public var remembered: String?
    public var tasks: [RunTask]

    public var isRunning: Bool { running != nil }

    /// Longer commands are cut to this many characters on the button; the tooltip has them whole.
    public static let maxLabelLength = 28

    public init(command: String?, running: String? = nil, remembered: String? = nil, tasks: [RunTask]) {
        self.command = command
        self.running = running
        self.remembered = remembered
        self.tasks = tasks
    }

    var label: String {
        if let running { return "\u{25A0} " + Self.shortened(running) }       // ■
        if let command { return "\u{25B6} " + Self.shortened(command) }       // ▶
        return "\u{25B6} Run\u{2026}"
    }

    var toolTip: String {
        if let running { return "Stop \(running)" }
        if let command { return "Run \(command)" }
        return "Choose what to run"
    }

    static func shortened(_ command: String) -> String {
        guard command.count > maxLabelLength else { return command }
        return String(command.prefix(maxLabelLength - 1)) + "\u{2026}"
    }
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

    /// ▶ / ■ — run what the button names, or stop the running one. The window controller decides
    /// which from the store, so the toolbar never acts on a stale model.
    public var onRunPrimary: (() -> Void)?
    /// A task picked from the ▾ menu, by command. Picking one also remembers it for the group.
    public var onRunTask: ((String) -> Void)?
    /// ▾ → Custom Command…
    public var onCustomRunCommand: (() -> Void)?
    /// ▾ → Reset to Detected.
    public var onResetRunCommand: (() -> Void)?
    /// Called just before the ▾ menu is built, so the caller can re-read the project's manifests
    /// and hand over a fresh model — a script added a minute ago should be in the list.
    public var onRunMenuWillOpen: (() -> Void)?
    /// Pops the menu up under the control. Replaceable because `NSMenu.popUp` runs a modal tracking
    /// loop: tests swap it out, and it does nothing for a control that is not in a window.
    public var presentRunMenu: (NSMenu, NSView) -> Void = { menu, view in
        guard view.window != nil else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    public var theme: Theme {
        didSet { if theme != oldValue { applyTheme() } }
    }

    private var titleField: NSTextField?
    private var segmented: NSSegmentedControl?
    private var runControl: NSSegmentedControl?
    private var runItem: NSToolbarItem?
    private var runModel: RunButtonModel?

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

    // MARK: Run

    /// The two halves of the Run control. `rawValue` is the segment index.
    public enum RunPart: Int, Sendable {
        case primary = 0    // ▶ pnpm dev / ■ pnpm dev
        case menu = 1       // ▾
    }

    /// What a click on the Run control did.
    public enum RunActivation: Equatable, Sendable {
        case ran
        case openedMenu
    }

    /// Shows the selected row's Run state; `nil` hides the item (a row with nowhere to run).
    public func setRun(_ model: RunButtonModel?) {
        runModel = model
        applyRun()
    }

    private func applyRun() {
        runItem?.isHidden = runModel == nil
        guard let control = runControl, let model = runModel else { return }
        control.setLabel(model.label, forSegment: RunPart.primary.rawValue)
        control.setToolTip(model.toolTip, forSegment: RunPart.primary.rawValue)
    }

    /// A click on one half of the Run control. The `@objc` handler funnels through here; tests
    /// drive it directly.
    @discardableResult
    func activateRun(_ part: RunPart) -> RunActivation {
        if part == .primary, let model = runModel, model.isRunning || model.command != nil {
            onRunPrimary?()
            return .ran
        }
        onRunMenuWillOpen?()
        if let view = runControl { presentRunMenu(makeRunMenu(), view) }
        return .openedMenu
    }

    /// The ▾ menu: the remembered command when detection cannot see it, every detected task (the
    /// one ▶ runs checked), then Custom Command… and Reset to Detected.
    func makeRunMenu() -> NSMenu {
        let menu = NSMenu(title: "Run")
        menu.autoenablesItems = false
        let model = runModel ?? RunButtonModel(command: nil, tasks: [])
        var commands = model.tasks.map(\.command)
        if let remembered = model.remembered, !commands.contains(remembered) {
            commands.insert(remembered, at: 0)
        }
        if commands.isEmpty {
            let empty = NSMenuItem(title: "No tasks found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for command in commands {
            let item = NSMenuItem(title: command, action: #selector(runTaskChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            item.state = command == model.command ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(
            title: "Custom Command\u{2026}", action: #selector(customRunCommandChosen(_:)), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        let reset = NSMenuItem(
            title: "Reset to Detected", action: #selector(resetRunCommandChosen(_:)), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = model.remembered != nil
        menu.addItem(reset)
        return menu
    }

    @objc private func runTaskChosen(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        onRunTask?(command)
    }

    @objc private func customRunCommandChosen(_ sender: NSMenuItem) { onCustomRunCommand?() }
    @objc private func resetRunCommandChosen(_ sender: NSMenuItem) { onResetRunCommand?() }

    @objc private func runSegmentClicked(_ sender: NSSegmentedControl) {
        guard let part = RunPart(rawValue: sender.selectedSegment) else { return }
        activateRun(part)
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
        [.flexibleSpace, .tkzTitle, .flexibleSpace, .tkzRun, .tkzViewCluster]
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
        case .tkzRun: makeRunItem()
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

    private func makeRunItem() -> NSToolbarItem {
        let control = NSSegmentedControl(
            labels: ["\u{25B6} Run\u{2026}", "\u{25BE}"],   // ▶ Run…  ▾
            trackingMode: .momentary,
            target: self,
            action: #selector(runSegmentClicked(_:))
        )
        control.segmentStyle = .texturedRounded
        control.font = Theme.Fonts.mono(Self.clusterGlyphSize, weight: .medium)
        control.setToolTip("More tasks", forSegment: RunPart.menu.rawValue)
        runControl = control

        let item = NSToolbarItem(itemIdentifier: .tkzRun)
        item.view = control
        item.label = "Run"
        item.paletteLabel = "Run"
        item.visibilityPriority = .high
        runItem = item
        applyRun()
        return item
    }

    // MARK: Test / assembly access

    /// The live centred title label, once the toolbar has vended the title item.
    var titleLabel: NSTextField? { titleField }
}
