// MainWindowController — the real main window (M2.2 / TKZ-18).
//
// design.md → *App architecture*: an `NSSplitViewController` with the sidebar on the left (300 pt,
// min 240, collapsible), the single terminal surface on the right, the 30 pt status strip along the
// bottom and the unified 48 pt toolbar in the title bar. This file is the **assembler**: every
// piece it puts together (sidebar, toolbar, status bar, palette, new-session menu, terminal host)
// was built by its own ticket and knows nothing about the others.
//
// Three things are load-bearing and easy to get wrong:
//
//  1. **Focus.** `TerminalHost.show(_:)` attaches the renderer, but a terminal that is not the
//     window's first responder receives no key events at all — typing would go nowhere. So every
//     path that shows a session also calls `makeFirstResponder` on the terminal view.
//  2. **Sidebar collapse is store state, in both directions.** ⌘B mutates
//     `AppState.sidebarVisible`; the `chrome` observer applies it to the split item. A *drag* of
//     the divider that collapses the sidebar has to travel the other way, so the split view
//     controller reports resizes back into the store behind a re-entrancy guard — otherwise the
//     window and `state.json` (M5.1) drift apart the first time the user drags.
//  3. **Nothing here may touch the real application-support directory.** The window controller
//     never builds a `TerminalViewHost` itself: the host and the `UserDefaults` are injected, so a
//     test gets a spy host and a throwaway defaults suite (shared agent brief, hard rule 8). The
//     `init(store:renderContext:)` convenience is the only place that builds the real thing, and
//     `AppDelegate` is its only caller.
//
// Window frame and sidebar visibility are persisted through the store's `chrome` change set and
// mirrored into `UserDefaults` — a stand-in until M5.1 writes `state.json`.

import AppKit
import Foundation
import TkzCore
import TkzTerminalCore
import TkzTerminalRender
import TkzTerminalView
import os

// MARK: - Chrome persistence

/// Window frame + sidebar visibility in `UserDefaults`. M5.1 replaces this with `state.json`;
/// until then the two keys below are the whole of the app's persistence.
public enum ChromeDefaults {
    public static let frameKey = "tkzmux.main.windowFrame"
    public static let sidebarVisibleKey = "tkzmux.main.sidebarVisible"

    /// Writes the chrome half of `state`. A `nil` frame removes the key rather than writing a
    /// zero rect, so "never placed" and "placed at the origin" stay distinguishable.
    public static func save(_ state: AppState, to defaults: UserDefaults) {
        if let frame = state.windowFrame {
            defaults.set(NSStringFromRect(frame), forKey: frameKey)
        } else {
            defaults.removeObject(forKey: frameKey)
        }
        defaults.set(state.sidebarVisible, forKey: sidebarVisibleKey)
    }

    /// Applies whatever was stored. Missing or unparsable values leave `state` untouched, so a
    /// corrupt default degrades to the built-in placement instead of a zero-sized window.
    public static func load(into state: inout AppState, from defaults: UserDefaults) {
        if let raw = defaults.string(forKey: frameKey) {
            let rect = NSRectFromString(raw)
            if rect.width > 0, rect.height > 0 { state.windowFrame = rect }
        }
        if defaults.object(forKey: sidebarVisibleKey) != nil {
            state.sidebarVisible = defaults.bool(forKey: sidebarVisibleKey)
        }
    }
}

// MARK: - Split view controller

/// The split view controller, subclassed for one reason: a divider drag that collapses (or
/// re-opens) the sidebar must reach the store. `onSidebarCollapseChanged` fires only when the
/// value actually flips, and the controller sets ``isApplyingStoreState`` while it is applying a
/// store-driven change so the report does not bounce back.
final class MainSplitViewController: NSSplitViewController {
    var onSidebarCollapseChanged: (@MainActor (Bool) -> Void)?
    var isApplyingStoreState = false

    private var lastReportedCollapse: Bool?

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !isApplyingStoreState, let sidebar = splitViewItems.first else { return }
        let collapsed = sidebar.isCollapsed
        guard collapsed != lastReportedCollapse else { return }
        lastReportedCollapse = collapsed
        onSidebarCollapseChanged?(collapsed)
    }

    /// Applies a collapse decision that came from the store without reporting it back.
    func applyCollapsed(_ collapsed: Bool) {
        guard let sidebar = splitViewItems.first else { return }
        lastReportedCollapse = collapsed
        guard sidebar.isCollapsed != collapsed else { return }
        isApplyingStoreState = true
        sidebar.isCollapsed = collapsed
        isApplyingStoreState = false
    }
}

// MARK: - Detail view

/// The right-hand half: the terminal surface, the empty state on top of it, and the status strip
/// pinned along the bottom.
///
/// The status bar installs its own 30 pt height constraint (`StatusBarView.init`), so this only
/// pins its three edges — adding a second height constraint here would be a conflict waiting for
/// the first layout pass.
final class DetailViewController: NSViewController {
    let terminalContainer = NSView()
    let terminalView: NSView
    let statusBar: StatusBarView
    let emptyState: NSView

    private var theme: Theme

    init(terminalView: NSView, statusBar: StatusBarView, theme: Theme) {
        self.terminalView = terminalView
        self.statusBar = statusBar
        self.theme = theme
        self.emptyState = DetailViewController.makeEmptyState(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 820))
        root.wantsLayer = true
        root.layer?.backgroundColor = theme.terminalBackground.cgColor

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = theme.terminalBackground.cgColor

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(terminalView)
        terminalContainer.addSubview(emptyState)

        root.addSubview(terminalContainer)
        root.addSubview(statusBar)
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            terminalContainer.topAnchor.constraint(equalTo: root.topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            terminalView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),

            emptyState.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    func setTheme(_ theme: Theme) {
        self.theme = theme
        view.layer?.backgroundColor = theme.terminalBackground.cgColor
        terminalContainer.layer?.backgroundColor = theme.terminalBackground.cgColor
        statusBar.theme = theme
        (emptyState as? EmptyStateView)?.apply(theme: theme)
    }

    static func makeEmptyState(theme: Theme) -> NSView {
        let view = EmptyStateView()
        view.apply(theme: theme)
        return view
    }
}

/// "No session selected · ⌘N". Drawn rather than stacked so it rasterises headlessly (design.md →
/// *Testing without UI*: a windowless `NSView` subtree does not render, a layer does).
final class EmptyStateView: NSView {
    /// What the label says. Public-in-module so the test asserts the string, not a screenshot.
    static let message = "No session selected \u{00B7} \u{2318}N"

    private let textLayer = CATextLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(textLayer)
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .end
        textLayer.contentsScale = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("EmptyStateView is code-only") }

    override var isFlipped: Bool { false }

    func apply(theme: Theme) {
        layer?.backgroundColor = theme.terminalBackground.cgColor
        let font = Theme.Fonts.ui(theme.fontUI.title)
        textLayer.string = NSAttributedString(string: Self.message, attributes: [
            .font: font,
            .foregroundColor: theme.foregroundMuted.nsColor,
        ])
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 24
        textLayer.frame = CGRect(
            x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }
}

// MARK: - Main window

/// The application's main window: sidebar, terminal, status bar, toolbar, palette and menus.
@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {

    // MARK: Geometry (design.md → App architecture; artboard 2c is 1240×820)

    public static let defaultContentSize = NSSize(width: 1240, height: 820)
    public static let minimumContentSize = NSSize(width: 720, height: 420)
    /// Sidebar width and minimum, shared with the sidebar's own metrics so there is one number.
    public static let sidebarWidth = CGFloat(SidebarMetrics.sidebarWidth)
    public static let sidebarMinWidth = CGFloat(SidebarMetrics.sidebarMinWidth)

    // MARK: Pieces

    public let window: NSWindow
    public let store: AppStore
    public let host: any TerminalHost
    public let sidebar: SidebarViewController
    public let toolbarController: MainToolbarController
    public let statusBar: StatusBarView
    public let palette: CommandPaletteController
    public let newSessionMenu: NewSessionMenu
    public let dispatcher: MenuDispatcher

    let splitViewController: MainSplitViewController
    let detail: DetailViewController
    /// The right-hand surface. `NSView` rather than `TerminalMetalView` so a test can drive the
    /// window with a plain focusable view and no GPU.
    public let terminalView: NSView

    /// The real Metal view, when there is one (`init(store:renderContext:)`). `nil` in tests.
    public private(set) var metalView: TerminalMetalView?
    /// Keyboard/IME (TKZ-13). Held strongly — the view's `inputDelegate` is weak.
    public let inputController = TerminalInputController()
    /// Mouse reporting, selection and the clipboard (TKZ-14). Held strongly for the same reason.
    public let mouseController = MouseController()
    private var commandKeyMonitor: Any?

    private let defaults: UserDefaults
    private var theme: Theme
    private var storeToken: AppStore.ObserverToken?
    private var isApplyingStoreFrame = false
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "mainwindow")

    // MARK: Init

    /// The assembling initialiser. Everything with a filesystem or a GPU behind it is injected.
    public init(
        store: AppStore,
        host: any TerminalHost,
        terminalView: NSView,
        theme: Theme = .default,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.host = host
        self.terminalView = terminalView
        self.theme = theme
        self.defaults = defaults

        self.sidebar = SidebarViewController(store: store, theme: theme)
        self.toolbarController = MainToolbarController(theme: theme)
        self.statusBar = StatusBarView(theme: theme, model: .empty)
        self.palette = CommandPaletteController(state: store.state, mode: .all, theme: theme)
        self.newSessionMenu = NewSessionMenu(theme: theme)
        self.dispatcher = MenuDispatcher()
        self.detail = DetailViewController(
            terminalView: terminalView, statusBar: statusBar, theme: theme)
        self.splitViewController = MainSplitViewController()

        let frame = store.state.windowFrame
            ?? NSRect(origin: .zero, size: MainWindowController.defaultContentSize)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        self.window = window

        super.init()

        buildSplitView()
        configureWindow()
        wireSidebar()
        wireToolbar()
        wirePalette()
        registerMenuHandlers()
        observeStore()

        applySidebarVisible(store.state.sidebarVisible)
        applySelection(focusTerminal: false)
        updateStatusBar()
        updateToolbarTitle()
    }

    /// The real window: builds the `TerminalMetalView`, the `TerminalViewHost` behind it, and
    /// wires keyboard, mouse and ⌘C/⌘V. `AppDelegate` is the only caller.
    public convenience init(
        store: AppStore,
        renderContext: TerminalRenderContext,
        theme: Theme = .default,
        defaults: UserDefaults = .standard
    ) {
        let view = TerminalMetalView(
            renderContext: renderContext,
            frame: NSRect(x: 0, y: 0, width: 940, height: 760))
        let host = TerminalViewHost(view: view)
        self.init(store: store, host: host, terminalView: view, theme: theme, defaults: defaults)
        self.metalView = view
        wireInput(view: view, host: host)
    }

    // No `deinit`: the ⌘C/⌘V monitor is removed in ``shutdown()``. A `deinit` cannot touch it —
    // `NSEvent`'s monitor token is `Any`, which a nonisolated deinit may not read under Swift 6.

    // MARK: Assembly

    private func buildSplitView() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // The initial width is a *constraint*, not a divider position: an autolayout split view
        // ignores `setPosition` until it has been laid out in a real window, and a headless
        // assembly would otherwise come up with an 8 pt sidebar. The priority sits just above the
        // item's holding priority so the constraint wins the initial layout, and a divider drag —
        // which the split view expresses at a far higher priority — still wins over it.
        sidebarWidthConstraint = sidebar.view.widthAnchor.constraint(equalToConstant: Self.sidebarWidth)
        sidebarWidthConstraint?.priority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultLow.rawValue + 1)
        sidebarWidthConstraint?.isActive = true
        sidebarItem.minimumThickness = Self.sidebarMinWidth
        sidebarItem.maximumThickness = 520
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultLow
        // `.automatic` would let AppKit collapse the sidebar behind our back on a narrow window,
        // and the store would never learn about it.
        sidebarItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings

        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 400
        detailItem.canCollapse = false

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.onSidebarCollapseChanged = { [weak self] collapsed in
            guard let self, self.store.state.sidebarVisible == collapsed else { return }
            self.store.update { $0.setSidebarVisible(!collapsed) }
        }
    }

    private func configureWindow() {
        window.title = "tkzmux"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumContentSize
        window.backgroundColor = theme.windowBackground.nsColor
        // The sidebar's `NSVisualEffectView`, the toolbar and every system control take their
        // colours from the window's appearance, not from our tokens. A dark preset in an `.aqua`
        // window gives a white sidebar behind dark rows — visible in the offscreen render of the
        // first assembly. Derive it from the theme rather than from the system setting.
        window.appearance = NSAppearance(
            named: theme.windowBackground.relativeLuminance < 0.5 ? .darkAqua : .aqua)
        window.contentViewController = splitViewController
        window.toolbar = toolbarController.toolbar
        window.delegate = self
        window.setContentSize(store.state.windowFrame?.size ?? Self.defaultContentSize)
        if let frame = store.state.windowFrame { window.setFrame(frame, display: false) }
        // The divider position is a *layout* decision, so it only sticks after the window has a
        // size; `minimumThickness` alone would leave the sidebar at whatever AppKit picked.
        window.contentView?.layoutSubtreeIfNeeded()
        splitViewController.splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
    }

    private func wireSidebar() {
        sidebar.onNewSession = { [weak self] groupID in
            self?.presentNewSessionMenu(for: groupID)
        }
    }

    private func wireToolbar() {
        newSessionMenu.configureForSelection(state: store.state)
        newSessionMenu.onLaunch = { [weak self] launch in
            // M2.5 turns this into a real `TerminalHost.open`; the stub logs what it would run.
            self?.logger.info("new session: \(launch.logLine, privacy: .public)")
        }
        toolbarController.newSessionMenu = newSessionMenu.menu
        toolbarController.onNewTerminal = { [weak self] in
            self?.dispatcher.perform(.newSession)
        }
        toolbarController.onSearchChanged = { [weak self] query in
            guard let self, !query.isEmpty else { return }
            self.palette.update(state: self.store.state, mode: .sessions)
            self.palette.updateQuery(query)
        }
        toolbarController.onSearchSubmit = { [weak self] query in
            guard let self else { return }
            self.palette.update(state: self.store.state, mode: .sessions)
            self.palette.updateQuery(query)
            self.palette.activateSelection()
        }
    }

    private func wirePalette() {
        palette.onActivate = { [weak self] result in
            self?.activate(result)
            self?.palette.dismiss()
        }
    }

    private func observeStore() {
        storeToken = store.addObserver { [weak self] change in self?.apply(change) }
    }

    /// Keyboard, mouse and clipboard for the real Metal view. Mirrors `DevWindowController`'s
    /// wiring: only the *transport* is set, the encoders stay inside `TerminalSession`.
    private func wireInput(view: TerminalMetalView, host: TerminalViewHost) {
        view.inputDelegate = inputController
        inputController.writeInput = { [weak host] data in host?.writeInput(data) }
        inputController.isFocusReportingEnabled = { [weak host] in
            guard let host, let id = host.visibleID else { return false }
            return host.session(for: id)?.mode(1004) ?? false
        }
        inputController.mouseHandler = mouseController
        mouseController.attach(to: view)
        mouseController.sendBytes = { [weak host] bytes in host?.writeInput(Data(bytes)) }
        view.onGridResize = { [weak host] size in host?.resizeVisible(size) }
        host.onDidShow = { [weak self] _ in self?.updateToolbarTitle() }

        // ⌘C / ⌘V. `TerminalInputController` declines anything with ⌘ held so the menu bar keeps
        // working, and there is deliberately **no Edit menu**: an Edit menu would win the key
        // match and route `copy:`/`paste:` at a first responder that does not implement them.
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleCommandKey(event) else { return event }
            return nil
        }
    }

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        guard let view = metalView, event.window === window, window.firstResponder === view else {
            return false
        }
        // Caps Lock is a lock, not a chord.
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": return mouseController.copySelection(in: view)
        case "v": return mouseController.pasteFromPasteboard(in: view)
        default: return false
        }
    }

    // MARK: Window lifecycle

    public func showWindow() {
        if store.state.windowFrame == nil { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusTerminalIfSessionShown()
    }

    /// Saves the chrome and hangs up every session. `AppDelegate` calls this on terminate.
    public func shutdown() {
        saveChrome()
        if let host = host as? TerminalViewHost {
            _ = host.snapshotAll()
            host.closeAll(signal: SIGHUP)
        }
        if let commandKeyMonitor {
            NSEvent.removeMonitor(commandKeyMonitor)
            self.commandKeyMonitor = nil
        }
    }

    /// Mirrors the store's chrome into `UserDefaults` (M5.1 replaces this with `state.json`).
    public func saveChrome() {
        ChromeDefaults.save(store.state, to: defaults)
    }

    /// Reads the persisted chrome back into a state value. The inverse of ``saveChrome()``.
    public static func restoreChrome(into state: inout AppState, from defaults: UserDefaults) {
        ChromeDefaults.load(into: &state, from: defaults)
    }

    public func windowDidResize(_ notification: Notification) { recordWindowFrame() }
    public func windowDidMove(_ notification: Notification) { recordWindowFrame() }

    private func recordWindowFrame() {
        guard !isApplyingStoreFrame else { return }
        let frame = window.frame
        guard store.state.windowFrame != frame else { return }
        store.update { $0.windowFrame = frame }
    }

    // MARK: Change-set dispatch

    private func apply(_ change: ChangeSet) {
        if change.selection {
            applySelection(focusTerminal: true)
            updateToolbarTitle()
        }
        if change.chrome {
            applySidebarVisible(store.state.sidebarVisible)
            applyWindowFrame()
            newSessionMenu.presets = store.state.presets
            saveChrome()
        }
        if change.structure || change.selection {
            newSessionMenu.configureForSelection(state: store.state)
        }
        let selected = store.state.selection
        if change.selection || change.usage || (selected.map(change.touches) ?? false) {
            updateStatusBar()
            updateToolbarTitle()
        }
    }

    private func applyWindowFrame() {
        guard let frame = store.state.windowFrame, window.frame != frame else { return }
        isApplyingStoreFrame = true
        window.setFrame(frame, display: true)
        isApplyingStoreFrame = false
    }

    // MARK: Selection

    /// Attaches the renderer to the selection and moves the focus with it.
    ///
    /// The empty state is a sibling of the terminal view rather than a replacement for it, so
    /// showing and hiding it costs a `hidden` flip and never rebuilds the surface.
    func applySelection(focusTerminal: Bool) {
        let id = store.state.selection
        host.show(id)
        detail.emptyState.isHidden = id != nil
        terminalView.isHidden = id == nil
        if id != nil, focusTerminal { focusTerminalIfSessionShown() }
    }

    /// The one place that decides the terminal has the keyboard. Without it a selected session
    /// renders and swallows nothing.
    func focusTerminalIfSessionShown() {
        guard store.state.selection != nil else { return }
        window.makeFirstResponder(terminalView)
    }

    // MARK: Derived chrome

    func updateToolbarTitle() {
        guard let session = store.state.selectedSession else {
            toolbarController.setTitle(session: "No session", group: nil)
            return
        }
        toolbarController.setTitle(
            session: session.displayTitle,
            group: store.state.groups[session.groupID]?.name)
    }

    func updateStatusBar() {
        statusBar.model = Self.statusModel(for: store.state)
    }

    /// `Session` → `StatusBarModel`. Pure, so the mapping is a test rather than a screenshot.
    /// Every field is `nil` when it is unknown; the strip drops a `nil` segment *and* its
    /// separator (see `StatusBarView.segments`).
    static func statusModel(for state: AppState, now: Date = Date()) -> StatusBarModel {
        guard let session = state.selectedSession else { return .empty }
        let git = session.live?.git
        let sidecar = session.live?.context
        let usage = state.usage(for: session)?.sevenDay

        var model = StatusBarModel()
        model.branch = git?.branch
        model.isWorktree = (session.isWorktree || git?.isWorktree == true) ? true : nil
        model.modelName = sidecar?.model?.displayName
        model.diffAdded = git.map(\.insertions)
        model.diffRemoved = git.map(\.deletions)
        model.diffFiles = git.map(\.changedFiles)
        model.ahead = git.map(\.ahead)
        model.behind = git.map(\.behind)
        let ports = session.live?.ports ?? []
        model.ports = ports.isEmpty ? nil : ports
        model.contextPercent = sidecar?.contextUsedPercentage.map { Int($0.rounded()) }
        model.usagePercent = usage.map { Int($0.usedPercentage.rounded()) }
        if let resetsAt = usage?.resetsAt, resetsAt > now {
            model.usageResetsIn = .seconds(Int(resetsAt.timeIntervalSince(now)))
        }
        return model
    }

    // MARK: Sidebar visibility

    func applySidebarVisible(_ visible: Bool) {
        splitViewController.applyCollapsed(!visible)
        if visible {
            splitViewController.splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
        }
    }

    /// ⌘B.
    public func toggleSidebar() {
        store.update { $0.setSidebarVisible(!$0.sidebarVisible) }
    }

    // MARK: Commands

    /// ⌘N — the group-scoped new-session menu, at the toolbar item if the toolbar has vended one
    /// and under the title bar otherwise.
    public func presentNewSessionMenu(for groupID: GroupID? = nil) {
        let group = groupID ?? store.state.selectedSession?.groupID
        newSessionMenu.configure(state: store.state, groupID: group)
        guard let contentView = window.contentView else { return }
        let point = NSPoint(x: 16, y: contentView.bounds.height - 8)
        newSessionMenu.menu.popUp(positioning: nil, at: point, in: contentView)
    }

    /// ⌘P — the toolbar's search field if it is on screen, else the palette in session mode.
    public func beginSearch() {
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == .tkzSearch })
            as? NSSearchToolbarItem
        {
            item.beginSearchInteraction()
            return
        }
        presentPalette(mode: .sessions)
    }

    /// ⇧⌘P (and ⌘P's fallback).
    public func presentPalette(mode: PaletteDataSource.Mode = .all) {
        palette.present(state: store.state, mode: mode, over: window)
    }

    /// Routes a palette hit. Sessions and groups select; a command row carries a bare
    /// `ShortcutAction` id (see `PaletteDataSource.item(for:shortcut:)`), which is exactly what the
    /// menu dispatches on — one vocabulary for both.
    func activate(_ result: PaletteResult) {
        let item = result.item
        switch item.kind {
        case .session:
            if let id = item.sessionID { store.update { $0.select(id) } }
        case .group:
            if let id = item.groupID { presentNewSessionMenu(for: id) }
        case .command:
            dispatcher.perform(ShortcutAction(item.actionID))
        case .preset:
            newSessionMenu.configureForSelection(state: store.state)
            if let uuid = UUID(uuidString: String(item.actionID.dropFirst("preset:".count))),
               let preset = store.state.preset(uuid),
               let launch = newSessionMenu.launch(for: preset)
            {
                newSessionMenu.perform(launch)
            }
        }
    }

    // MARK: Menu handlers

    /// Everything the main menu can dispatch. Actions with no implementation yet are deliberately
    /// **absent**: `MenuDispatcher.validateMenuItem` then disables their menu items, so the menu
    /// shows the whole vocabulary and lies about none of it.
    private func registerMenuHandlers() {
        dispatcher.setHandler(.newSession) { [weak self] in self?.presentNewSessionMenu() }
        dispatcher.setHandler(.searchSessions) { [weak self] in self?.beginSearch() }
        dispatcher.setHandler(.commandPalette) { [weak self] in self?.presentPalette(mode: .all) }
        dispatcher.setHandler(.toggleSidebar) { [weak self] in self?.toggleSidebar() }
        dispatcher.setHandler(.jumpToNeedsYou) { [weak self] in
            _ = self?.sidebar.selectFirstSessionNeedingAttention()
        }
        dispatcher.setHandler(.nextSession) { [weak self] in
            self?.store.update { $0.selectAdjacentSession(offset: 1) }
        }
        dispatcher.setHandler(.previousSession) { [weak self] in
            self?.store.update { $0.selectAdjacentSession(offset: -1) }
        }
        for n in 1...9 {
            dispatcher.setHandler(.selectSession(n)) { [weak self] in
                self?.sidebar.selectSession(atVisibleIndex: n)
            }
        }
    }

    /// Builds the menu bar for the current bindings and installs it. Called by `AppDelegate` once
    /// the window exists, because the handlers capture it.
    public func installMainMenu(appName: String = "tkzmux") {
        MainMenu.install(
            MainMenu.build(
                appName: appName,
                shortcuts: ShortcutsTable.resolved(state: store.state),
                dispatcher: dispatcher))
    }

    // MARK: Diagnostics

    /// One line for `TKZMUX_DEV_AUTOQUIT_MS`, so the default window can be smoke-tested headlessly.
    public func diagnosticsLine() -> String {
        let frame = window.frame
        let sidebarWidth = splitViewController.splitViewItems.first?.viewController.view.frame.width ?? 0
        return String(
            format: "main window: frame=%.0fx%.0f sidebar=%@ (%.0f pt) sessions=%d selection=%@",
            frame.width, frame.height,
            store.state.sidebarVisible ? "visible" : "collapsed",
            sidebarWidth,
            store.state.sessions.count,
            store.state.selection?.rawValue ?? "none")
    }
}
