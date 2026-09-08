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
//     window and `state.json` drift apart the first time the user drags.
//  3. **Nothing here may touch the real application-support directory.** The window controller
//     never builds a `TerminalViewHost` itself: the host is injected, so a test gets a spy (shared
//     agent brief, hard rule 8). The `init(store:renderContext:)` convenience is the only place
//     that builds the real thing, and `AppDelegate` is its only caller.
//
// Window frame, sidebar width and sidebar visibility live in the store and are persisted by
// `Persistence.StateAutosaver` (M5.1 / TKZ-29). This class writes no file of its own; it only
// reports what the window is doing back into the store, and applies what the store says.

import AppKit
import Foundation
import TkzCore
import TkzTerminalCore
import TkzTerminalRender
import TkzTerminalView
import os

// MARK: - Split view controller

/// The split view controller, subclassed for one reason: a divider drag that collapses (or
/// re-opens) the sidebar must reach the store. `onSidebarCollapseChanged` fires only when the
/// value actually flips, and the controller sets ``isApplyingStoreState`` while it is applying a
/// store-driven change so the report does not bounce back.
final class MainSplitViewController: NSSplitViewController {
    var onSidebarCollapseChanged: (@MainActor (Bool) -> Void)?
    /// The sidebar's geometry moved. Carries no width on purpose: this fires many times during a
    /// drag and during assembly, always mid-layout. The listener waits for the movement to stop.
    var onSidebarGeometryChanged: (@MainActor () -> Void)?
    var isApplyingStoreState = false

    private var lastReportedCollapse: Bool?

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !isApplyingStoreState, let sidebar = splitViewItems.first else { return }
        let collapsed = sidebar.isCollapsed
        if collapsed != lastReportedCollapse {
            lastReportedCollapse = collapsed
            onSidebarCollapseChanged?(collapsed)
        }
        if !collapsed { onSidebarGeometryChanged?() }
    }

    /// How many times the controller has re-placed the divider. A drag snapping back is exactly
    /// "this went up when nothing about the width changed", so the regression test counts it.
    private(set) var appliedWidthCount = 0

    /// Applies a width decision that came from the store without reporting it back.
    func applyWidth(_ apply: () -> Void) {
        appliedWidthCount += 1
        isApplyingStoreState = true
        apply()
        isApplyingStoreState = false
    }

    /// Applies a collapse decision that came from the store without reporting it back. Returns
    /// whether it actually changed anything — the caller must not re-place the divider otherwise.
    @discardableResult
    func applyCollapsed(_ collapsed: Bool) -> Bool {
        guard let sidebar = splitViewItems.first else { return false }
        lastReportedCollapse = collapsed
        guard sidebar.isCollapsed != collapsed else { return false }
        isApplyingStoreState = true
        sidebar.isCollapsed = collapsed
        isApplyingStoreState = false
        return true
    }
}

// MARK: - Detail view

/// The right-hand half: the terminal surface, the empty state on top of it, and the status strip
/// pinned along the bottom.
///
/// The status bar installs its own 30 pt height constraint (`StatusBarView.init`), so this only
/// pins its three edges — adding a second height constraint here would be a conflict waiting for
/// the first layout pass.
///
/// **The terminal follows the safe area at the top, not the view's edge.** The window is
/// `.fullSizeContentView` with a transparent titlebar (that is what makes the unified toolbar work
/// and what the sidebar's concentric glass needs), so the content view really does extend up
/// behind the toolbar — pinning to `topAnchor` draws the first rows of the grid underneath the
/// toolbar, where the ＋ menu and the search field sit on top of them. The sidebar looks right
/// without this only because macOS insets the glass container it wraps a sidebar item in.
/// `safeAreaLayoutGuide` carries the window's `contentLayoutRect`, so it is the titlebar+toolbar
/// height on screen and zero everywhere else (a headless render is unaffected).
final class DetailViewController: NSViewController {
    let terminalContainer = NSView()
    let terminalView: NSView
    let statusBar: StatusBarView
    let emptyState: NSView

    /// The empty state's caption. A no-op when the view is the plain `NSView` a test injected.
    var emptyStateMessage: String {
        get { (emptyState as? EmptyStateView)?.message ?? "" }
        set { (emptyState as? EmptyStateView)?.message = newValue }
    }
    /// Dims the last screen of a session whose shell has exited. See ``ExitedScrimView``.
    let exitedScrim = ExitedScrimView()

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
        exitedScrim.translatesAutoresizingMaskIntoConstraints = false
        exitedScrim.isHidden = true
        // Without this the scrim's layer has no background colour and no caption: present,
        // constrained, unhidden on ⌘W — and completely invisible.
        exitedScrim.apply(theme: theme)
        // Subview order alone is not a strong enough guarantee over a `CAMetalLayer`; pin the
        // z-order explicitly so the scrim cannot end up composited underneath the terminal.
        exitedScrim.layer?.zPosition = 1
        terminalContainer.addSubview(exitedScrim)
        terminalContainer.addSubview(emptyState)
        emptyState.layer?.zPosition = 2

        root.addSubview(terminalContainer)
        root.addSubview(statusBar)
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            terminalContainer.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            terminalView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),

            exitedScrim.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            exitedScrim.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            exitedScrim.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            exitedScrim.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),

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
        exitedScrim.apply(theme: theme)
    }

    static func makeEmptyState(theme: Theme) -> NSView {
        let view = EmptyStateView()
        view.apply(theme: theme)
        return view
    }
}

/// The dim over a closed session's last screen.
///
/// ⌘W hangs the shell up but **keeps the row resumable** (design.md → *Session flows*: Close is not
/// Remove), so the grid stays exactly as the shell left it. Without this the only feedback was the
/// status dot changing from a filled disc to a 7 pt hollow ring, and ⌘W read as doing nothing.
///
/// Layers, not subviews — design.md → *Testing without UI*: a windowless `NSView` subtree does not
/// render, so a headless assertion would silently see nothing.
final class ExitedScrimView: NSView {
    /// The caption over the dimmed screen. A constant so a test asserts the string.
    static let message = "Session exited \u{00B7} \u{2318}N for a new one"

    /// How much of the dead screen is covered. Enough to read as inert, little enough that the
    /// last output stays legible — that is the point of keeping it.
    static let dimOpacity: Float = 0.55

    private let textLayer = CATextLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.opacity = 1
        layer?.addSublayer(textLayer)
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .end
        textLayer.contentsScale = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ExitedScrimView is code-only") }

    override var isFlipped: Bool { false }

    /// The scrim never takes clicks: the terminal underneath still owns selection and scrollback.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(theme: Theme) {
        var dim = theme.terminalBackground
        dim.a = Double(Self.dimOpacity)
        layer?.backgroundColor = dim.cgColor
        let font = Theme.Fonts.ui(theme.fontUI.body)
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
        let height: CGFloat = 20
        textLayer.frame = CGRect(
            x: 0, y: bounds.height - height - 12, width: bounds.width, height: height)
    }
}

/// "No session selected · ⌘N". Drawn rather than stacked so it rasterises headlessly (design.md →
/// *Testing without UI*: a windowless `NSView` subtree does not render, a layer does).
final class EmptyStateView: NSView {
    /// Nothing is selected at all.
    static let noSelectionMessage = "No session selected \u{00B7} \u{2318}N"
    /// A row *is* selected but has no terminal behind it — the shape of every row restored from
    /// `state.json` until M5.2 wires Resume. Saying "no session selected" under a highlighted
    /// sidebar row would simply be untrue.
    static let notRunningMessage = "Session not running \u{00B7} resume arrives in M5.2"

    /// What the label says.
    var message: String = EmptyStateView.noSelectionMessage {
        didSet { if message != oldValue, let theme = lastTheme { apply(theme: theme) } }
    }

    private var lastTheme: Theme?
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
        lastTheme = theme
        layer?.backgroundColor = theme.terminalBackground.cgColor
        let font = Theme.Fonts.ui(theme.fontUI.title)
        textLayer.string = NSAttributedString(string: message, attributes: [
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

    private var theme: Theme
    private var storeToken: AppStore.ObserverToken?
    /// Drains `host.events` for the lifetime of the window.
    private var eventPump: Task<Void, Never>?
    private var isApplyingStoreFrame = false

    /// Debounces `recordSidebarWidth()` until the sidebar has stopped moving.
    private var sidebarSettleTask: Task<Void, Never>?
    /// The width this controller last pushed onto the split view, so a chrome delivery that changed
    /// something else cannot re-place a divider the user has since dragged.
    private var lastAppliedSidebarWidth: CGFloat?

    /// A launch-time message shown in the status strip; see ``showNotice(_:)``.
    private var transientNotice: String?
    private var noticeTimer: DispatchSourceTimer?
    /// Internal rather than private so the width tests can read what layout actually got.
    var sidebarWidthConstraint: NSLayoutConstraint?
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "mainwindow")

    // MARK: Init

    /// The assembling initialiser. Everything with a filesystem or a GPU behind it is injected.
    public init(
        store: AppStore,
        host: any TerminalHost,
        terminalView: NSView,
        theme: Theme = .default
    ) {
        self.store = store
        self.host = host
        self.terminalView = terminalView
        self.theme = theme

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
        startEventPump()

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
        theme: Theme = .default
    ) {
        let view = TerminalMetalView(
            renderContext: renderContext,
            frame: NSRect(x: 0, y: 0, width: 940, height: 760))
        let host = TerminalViewHost(view: view)
        self.init(store: store, host: host, terminalView: view, theme: theme)
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
        sidebarWidthConstraint = sidebar.view.widthAnchor.constraint(
            equalToConstant: restoredSidebarWidth)
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
        splitViewController.onSidebarGeometryChanged = { [weak self] in
            self?.recordSidebarWidthWhenSettled()
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
        // …and now the seeding constraint has to go, or it wins every subsequent layout pass and
        // the sidebar can never be anything but its constant. Reproduced headlessly: with the
        // constraint active, `setPosition(380)` left the sidebar at 300, which is exactly the
        // reported "drag it, let go, it snaps back" — the drag wins while the mouse is down and
        // autolayout re-asserts the constant on mouse-up. From here on `setPosition` is the
        // mechanism, and it works because the split view has now been laid out.
        deactivateSidebarWidthSeed()
        applySidebarWidth(force: true)
    }

    /// Retires the width constraint after it has done its one job. Idempotent.
    private func deactivateSidebarWidthSeed() {
        sidebarWidthConstraint?.isActive = false
    }

    /// The divider position the sidebar comes up at: what the user last left it at, clamped to what
    /// the split view will actually allow, else the design's 300 pt.
    var restoredSidebarWidth: CGFloat {
        guard let width = store.state.sidebarWidth, width >= Self.sidebarMinWidth else {
            return Self.sidebarWidth
        }
        return min(width, 520)
    }

    private func wireSidebar() {
        sidebar.onNewSession = { [weak self] groupID in
            self?.presentNewSessionMenu(for: groupID)
        }
    }

    private func wireToolbar() {
        newSessionMenu.configureForSelection(state: store.state)
        newSessionMenu.onLaunch = { [weak self] launch in self?.launch(launch) }
        toolbarController.newSessionMenu = newSessionMenu.menu
        // `>_` is "new terminal" in the design: a bare shell in the selected group's directory,
        // not another way to open the `＋` menu.
        toolbarController.onNewTerminal = { [weak self] in
            guard let self else { return }
            newSessionMenu.configureForSelection(state: store.state)
            guard let launch = newSessionMenu.shellLaunch(fallbackDirectory: NSHomeDirectory())
            else { return }
            newSessionMenu.perform(launch)
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

    /// Hangs up every session. `AppDelegate` calls this on terminate, and flushes the state file
    /// afterwards — `StateAutosaver` owns persistence now, not this class.
    public func shutdown() {
        sidebarSettleTask?.cancel()
        sidebarSettleTask = nil
        recordSidebarWidth()
        noticeTimer?.cancel()
        noticeTimer = nil
        eventPump?.cancel()
        eventPump = nil
        if let host = host as? TerminalViewHost {
            _ = host.snapshotAll()
            host.closeAll(signal: SIGHUP)
        }
        if let commandKeyMonitor {
            NSEvent.removeMonitor(commandKeyMonitor)
            self.commandKeyMonitor = nil
        }
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
            applySidebarWidth()
            applyWindowFrame()
            newSessionMenu.presets = store.state.presets
        }
        if change.structure || change.selection {
            newSessionMenu.configureForSelection(state: store.state)
        }
        let selected = store.state.selection
        if change.selection || change.usage || (selected.map(change.touches) ?? false) {
            updateStatusBar()
            // ⌘W and an `.exited` event both arrive as a status change on the selected row, not as a
            // selection change, so the scrim has to follow this branch too.
            updateExitedScrim()
            updateToolbarTitle()
        }
    }

    /// The divider position — the width of whichever child of the split view contains the sidebar.
    ///
    /// This is the quantity `setPosition` takes, and once the seeding constraint is retired
    /// `setPosition` is the only thing that places the sidebar, so recording and restoring it is a
    /// fixed point. Measured, because the near-misses all drift: `sidebar.view.frame.width` is
    /// 8 pt smaller (the macOS 26 glass-container inset), so mixing the two loses or gains 8 pt on
    /// every launch, and neither `subviews.first` nor `arrangedSubviews.first` is the sidebar at
    /// all — the split view's children are not in visual order and the *detail* wrapper comes
    /// first, which recorded 852 pt.
    var sidebarWidthForRestore: CGFloat {
        let splitView = splitViewController.splitView
        var view: NSView? = sidebar.view
        while let current = view, current.superview !== splitView { view = current.superview }
        return view?.frame.width ?? sidebar.view.frame.width
    }

    /// Records the sidebar's width once it has stopped moving.
    ///
    /// The quiet period is the whole trick. `splitViewDidResizeSubviews` fires continuously during
    /// a drag and repeatedly during assembly, always mid-layout, and the sidebar measurably passes
    /// through its 240 pt minimum on the way to 300 — so reading on the notification, or one
    /// run-loop turn later, records a number nobody chose. Because the store then drives the width,
    /// one such transient pinned the sidebar at its minimum on every launch. Waiting for the
    /// movement to *stop* reads the settled value in both cases: 300 at launch, and whatever the
    /// user let go of at the end of a drag.
    private func recordSidebarWidthWhenSettled() {
        sidebarSettleTask?.cancel()
        sidebarSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.sidebarSettleTask = nil
            self.recordSidebarWidth()
        }
    }

    /// Reads the sidebar's width into the store. Debounced by `recordSidebarWidthWhenSettled()`,
    /// and called directly from ``shutdown()`` so a quit never races the settle.
    func recordSidebarWidth() {
        let width = sidebarWidthForRestore
        guard width > 0, abs((store.state.sidebarWidth ?? -1) - width) > 0.5 else { return }
        store.update { $0.sidebarWidth = width }
    }

    /// Applies a width that came from the *store* — a restore from `state.json`, or the settled
    /// read after a drag.
    ///
    /// It fires only when that value actually changed since the last time this controller placed
    /// the divider. Re-placing it on every `chrome` delivery is what made a drag snap back the
    /// moment anything else in the store moved: the user had dragged to 380, the store still said
    /// 300, and the next unrelated delivery pushed the divider back. `lastAppliedSidebarWidth` is
    /// the guard, and it is why the store must learn about a drag promptly rather than at quit.
    private func applySidebarWidth(force: Bool = false) {
        // Never while collapsed: `setPosition` re-expands the sidebar, the split view reports the
        // re-expansion back, and ⌘B would immediately undo itself.
        guard store.state.sidebarVisible else { return }
        let width = restoredSidebarWidth
        guard force || lastAppliedSidebarWidth != width else { return }
        lastAppliedSidebarWidth = width
        splitViewController.applyWidth {
            splitViewController.splitView.setPosition(width, ofDividerAt: 0)
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
        // Visibility follows the *host*, not the selection. From M5.1 a restored row exists in the
        // store with no terminal behind it, and showing the surface for one draws an empty black
        // rectangle where the empty state belongs.
        let hasSurface = host.visibleSessionID != nil
        detail.emptyState.isHidden = hasSurface
        detail.emptyStateMessage = id == nil
            ? EmptyStateView.noSelectionMessage
            : EmptyStateView.notRunningMessage
        terminalView.isHidden = !hasSurface
        updateExitedScrim()
        if hasSurface, focusTerminal { focusTerminalIfSessionShown() }
    }

    /// Shows the dim over a selected session whose shell has exited. A row with no surface at all
    /// shows the empty state instead, so there is nothing to scrim.
    func updateExitedScrim() {
        let isExited = store.state.selectedSession.map { $0.status == .exited } ?? false
        detail.exitedScrim.isHidden = !(isExited && host.visibleSessionID != nil)
    }

    /// The one place that decides the terminal has the keyboard. Without it a selected session
    /// renders and swallows nothing.
    func focusTerminalIfSessionShown() {
        guard host.visibleSessionID != nil else { return }
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
        var model = Self.statusModel(for: store.state)
        model.notice = transientNotice
        statusBar.model = model
    }

    /// Shows a message in the status strip for a while, then puts the session's data back.
    /// `AppDelegate` uses it for the `state.json` recovery notices (M5.1); design.md asks for a
    /// non-modal notice and the 30 pt strip is the only one the app has.
    public func showNotice(_ message: String, for duration: Duration = .seconds(10)) {
        transientNotice = message
        updateStatusBar()
        noticeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.transientNotice = nil
                self.noticeTimer = nil
                self.updateStatusBar()
            }
        }
        noticeTimer = timer
        timer.resume()
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
        let changed = splitViewController.applyCollapsed(!visible)
        // Only when the sidebar actually re-expanded. Unconditionally re-placing the divider on
        // every `chrome` delivery threw away whatever width the user had dragged to, because this
        // runs for a preset edit or a window move just as much as for ⌘B.
        if visible, changed {
            splitViewController.applyWidth {
                splitViewController.splitView.setPosition(restoredSidebarWidth, ofDividerAt: 0)
            }
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

    // MARK: - Launching

    /// Starts a session for a resolved `Launch`: spawn the pty, put the row in the store, select it.
    ///
    /// Selection is what makes the terminal visible — the store observer calls
    /// ``applySelection(focusTerminal:)``, which calls `host.show`. Nothing here calls `show`.
    public func launch(_ launch: NewSessionMenu.Launch) {
        let home = NSHomeDirectory()
        let cwd = Paths.expandingTilde(launch.cwd, home: home)

        // The pty shim ignores `chdir`'s return value (`tkz_pty_spawn` is post-`fork()`, where
        // there is nothing safe to report through), so a bad directory does **not** fail the
        // spawn — it silently starts the shell somewhere else. Validating here is the only way a
        // launch into a missing directory fails visibly.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            presentLaunchFailure("\(cwd) is not a directory.")
            return
        }

        let id = SessionID.generate()
        let pid: pid_t
        do {
            pid = try host.open(
                id, cwd: cwd, env: launchEnvironment(for: launch), size: launchSize())
        } catch {
            logger.error("spawn failed: \(String(describing: error), privacy: .public)")
            presentLaunchFailure(String(describing: error))
            return
        }

        store.update {
            // `cwd` goes in **unexpanded**: the models keep paths as written (`state.json` persists
            // them), and expansion belongs at the `chdir` boundary above.
            $0.createSession(
                id: id, groupID: launch.groupID, cwd: launch.cwd,
                accountKey: launch.accountKey, presetID: launch.presetID)
            // Without live state `Session.status` is `live?.status ?? .exited` and a brand-new row
            // would draw as a dead one.
            $0.setLive(LiveSessionState(shellPid: pid, status: .idle), for: id)
            $0.select(id)
        }

        // `.shell` types nothing. Everything else waits for the shell to be ready first — a write
        // in the same turn as the spawn is discarded by zsh's `tcsetattr(TCSAFLUSH)` (M1.10).
        if !launch.command.isEmpty {
            host.runWhenReady(id, command: launch.command)
        }
        logger.info("launched \(launch.kind.rawValue, privacy: .public): \(launch.logLine, privacy: .public)")
    }

    /// `CLAUDE_CONFIG_DIR` for a non-primary account, nothing otherwise.
    ///
    /// `Launch.accountKey` is an `Account.key` (a basename); the child needs `Account.configDir`.
    /// The primary account is left alone so the shell uses `~/.claude`.
    private func launchEnvironment(for launch: NewSessionMenu.Launch) -> [String: String] {
        guard let key = launch.accountKey, key != Account.defaultKey,
              let account = store.state.accounts[key]
        else { return [:] }
        return ["CLAUDE_CONFIG_DIR": account.configDir]
    }

    /// The grid a new session opens at. `metalView` is nil only on the injected-host path (tests).
    private func launchSize() -> TerminalSize {
        metalView?.gridSizeForBounds() ?? TerminalSize(rows: 40, cols: 120)
    }

    /// Overrides the modal alert a failed launch shows. Tests set it — `NSAlert.runModal()` in a
    /// test process blocks the run forever.
    public var onLaunchFailure: ((String) -> Void)?

    private func presentLaunchFailure(_ message: String) {
        logger.error("launch failed: \(message, privacy: .public)")
        if let onLaunchFailure {
            onLaunchFailure(message)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Could not start a session"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// ⌘W. Hangs the child up; the row stays and keeps its screen, so it is resumable (M5.2).
    /// Removing a row is a different verb (`closeSession`) and is not wired yet.
    private func closeSelectedTerminal() {
        guard let id = store.state.selection else { return }
        host.close(id, signal: SIGHUP)
        // Do not wait for `.exited`: the row must read as closed the moment the user asks. The
        // event arrives afterwards and `closeSession` is idempotent.
        store.update { $0.closeSession(id) }
    }

    // MARK: - Terminal events

    /// Drains `host.events`. Nothing else consumes the stream — and an `AsyncStream` with no
    /// consumer buffers forever — so this is also what keeps it from growing.
    private func startEventPump() {
        let stream = host.events
        eventPump = Task { [weak self] in
            for await (id, event) in stream {
                guard let self else { return }
                handle(event, for: id)
            }
        }
    }

    private func handle(_ event: TerminalEvent, for id: SessionID) {
        switch event {
        case .exited:
            // The row stays, with its last screen: closed is resumable, removed is not.
            // `host.discard` (which the dev window uses) would throw the grid away.
            store.update { $0.closeSession(id) }
        default:
            // `.title`/`.pwd` deliberately do not land in the store: `Session.title` is the rename
            // slot (design.md → Session flows) and a shell-set title is not a rename. M3.4 gives
            // them a home.
            break
        }
    }

    // MARK: Menu handlers

    /// Everything the main menu can dispatch. Actions with no implementation yet are deliberately
    /// **absent**: `MenuDispatcher.validateMenuItem` then disables their menu items, so the menu
    /// shows the whole vocabulary and lies about none of it.
    private func registerMenuHandlers() {
        dispatcher.setHandler(.newSession) { [weak self] in self?.presentNewSessionMenu() }
        dispatcher.setHandler(.closeTerminal) { [weak self] in self?.closeSelectedTerminal() }
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
        // The same quantity `state.json` records — see `sidebarWidthForRestore`.
        let sidebarWidth = sidebarWidthForRestore
        return String(
            format: "main window: frame=%.0fx%.0f sidebar=%@ (%.0f pt) sessions=%d selection=%@",
            frame.width, frame.height,
            store.state.sidebarVisible ? "visible" : "collapsed",
            sidebarWidth,
            store.state.sessions.count,
            store.state.selection?.rawValue ?? "none")
    }
}
