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
import ClaudeBridge
import Foundation
import Persistence
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
/// `.fullSizeContentView` with a transparent titlebar, so the content view really does extend up
/// behind the toolbar — pinning to `topAnchor` draws the first rows of the grid underneath the
/// toolbar, where the ＋ menu and the search field sit on top of them (M2.5). What sits there
/// instead is `ChromeViewController`'s header backdrop. `safeAreaLayoutGuide` carries the window's
/// `contentLayoutRect`, so it is the titlebar+toolbar height on screen and zero everywhere else (a
/// headless render is unaffected).
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
    /// Nothing is selected at all.
    static let noSelectionMessage = "No session selected \u{00B7} \u{2318}N"
    /// A row *is* selected but has no terminal behind it. Since M5.2 a restored row is reopened
    /// the moment it is shown, so this is only ever seen when that reopen could not spawn a shell
    /// (see ``missingDirectoryMessage(_:)`` for the usual reason). Saying "no session selected"
    /// under a highlighted sidebar row would simply be untrue.
    static let notRunningMessage = "Session not running \u{00B7} \u{2318}R to resume"

    /// The reopen found none of the session's directories on disk.
    static func missingDirectoryMessage(_ path: String) -> String {
        "Directory missing \u{00B7} \(path)"
    }

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

    /// The whole window, titlebar included — the artboard is drawn at this size.
    public static let defaultWindowSize = NSSize(width: 1240, height: 820)
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
    /// Every way a shell gets behind a row (M5.2): start, reopen, resume, close, remove.
    public let launcher: SessionLauncher

    let splitViewController: MainSplitViewController
    /// The window's content view controller: the split view plus the header backdrop.
    let chrome: ChromeViewController
    /// Hold ⌘ alone for two seconds and this lists the shortcuts.
    let cheatSheet: CheatSheetOverlayController
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
    /// Snapshots every live session periodically (M5.2), so a crash loses at most this much screen.
    private var snapshotTimer: DispatchSourceTimer?
    /// Re-renders the status strip once a minute so `resets 4d 12h` counts down (M4.2). Nothing
    /// else in the app is time-dependent enough to need a clock, and `StatusBarView` only redraws
    /// when the model actually differs, so a minute in which nothing changed costs one comparison.
    private var statusTickTimer: DispatchSourceTimer?
    public static let statusTickInterval: TimeInterval = 60
    /// design.md → *Session flows*: "on a 5-min timer for live sessions".
    public static let snapshotInterval: TimeInterval = 300
    /// What the last lazy reopen of the selected row said, for the empty-state caption.
    private var lastReopenFailure: SessionLauncher.Failure?
    /// Internal rather than private so the width tests can read what layout actually got.
    var sidebarWidthConstraint: NSLayoutConstraint?
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "mainwindow")

    // MARK: Init

    /// The assembling initialiser. Everything with a filesystem or a GPU behind it is injected.
    public init(
        store: AppStore,
        host: any TerminalHost,
        terminalView: NSView,
        theme: Theme = .default,
        home: String = NSHomeDirectory()
    ) {
        self.store = store
        self.host = host
        self.terminalView = terminalView
        self.theme = theme
        self.launcher = SessionLauncher(store: store, host: host, home: home)

        self.sidebar = SidebarViewController(store: store, theme: theme)
        self.toolbarController = MainToolbarController(theme: theme)
        self.statusBar = StatusBarView(theme: theme, model: .empty)
        self.palette = CommandPaletteController(state: store.state, mode: .all, theme: theme)
        self.newSessionMenu = NewSessionMenu(theme: theme)
        self.dispatcher = MenuDispatcher()
        self.detail = DetailViewController(
            terminalView: terminalView, statusBar: statusBar, theme: theme)
        let splitViewController = MainSplitViewController()
        self.splitViewController = splitViewController
        let cheatSheet = CheatSheetOverlayController(theme: theme)
        self.cheatSheet = cheatSheet
        self.chrome = ChromeViewController(
            splitViewController: splitViewController, overlay: cheatSheet.view, theme: theme)

        let frame = store.state.windowFrame
            ?? NSRect(origin: .zero, size: MainWindowController.defaultWindowSize)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        self.window = window

        super.init()

        launcher.gridSize = { [weak self] terminal in
            self?.launchSize(for: terminal) ?? TerminalSize(rows: 40, cols: 120)
        }
        // Removing a row must drop its per-session caches too. `fullMessages` in particular holds
        // a whole Stop message — arbitrarily long — and without this the app kept one per session
        // id it had *ever* seen, for as long as it ran. Wired here rather than in the `claude`/`git`
        // observers so it survives either of them being set, unset, or replaced.
        launcher.onRemoved = { [weak self] id in
            self?.claude?.forget(id)
            self?.git?.forget(id)
        }
        buildSplitView()
        configureWindow()
        wireSidebar()
        wireToolbar()
        wirePalette()
        wireCheatSheet()
        registerMenuHandlers()
        observeStore()
        startEventPump()
        startSnapshotTimer()
        startStatusTickTimer()

        applySidebarVisible(store.state.sidebarVisible)
        applySelection(focusTerminal: false)
        updateStatusBar()
        updateToolbarTitle()
    }

    /// The real window: builds the `TerminalMetalView`, the `TerminalViewHost` behind it, and
    /// wires keyboard, mouse and ⌘C/⌘V. `AppDelegate` is the only caller.
    /// - Parameters:
    ///   - snapshots: where `.ghsnap` files go, for the host *and* the compressor's snapshot hook.
    ///   - tkzmuxDirectory: the application-support directory (`ZDOTDIR`, `TKZMUX_BIN`, the socket);
    ///     `nil` means the real one.
    ///
    /// Both are injected for the same reason the designated initialiser injects everything with a
    /// filesystem behind it: a test must never write to `~/Library/Application Support/tkzmux`
    /// (shared agent brief, hard rule 8), and `TerminalViewHost.init` creates its `zsh` directory
    /// eagerly. The app passes neither.
    public convenience init(
        store: AppStore,
        renderContext: TerminalRenderContext,
        theme: Theme = .default,
        snapshots: SnapshotStore = .standard(),
        tkzmuxDirectory: URL? = nil
    ) {
        let view = TerminalMetalView(
            renderContext: renderContext,
            frame: NSRect(x: 0, y: 0, width: 940, height: 760))
        // Idle compression is what keeps N idle sessions from each sitting on their full
        // `SCROLLBACK_MAX_BYTES`. docs/perf.md measures it taking 30 filled sessions from 577 MiB
        // of footprint to 26 MiB for 113 ms of work; without it the app stays on the 577 MiB side.
        // `TerminalIdleCompressor`'s defaults *are* the production values (60 s idle, 5 s tick),
        // so only the snapshot hook is supplied here — the dev window overrides them from env
        // instead, which is the only reason it spells them out.
        //
        // The id the hook is handed is a `TerminalID` since stage 2, so each *pane* snapshots to
        // its own `.ghsnap` — which is what the per-pane snapshot restore already expects.
        let compressor = TerminalIdleCompressor(
            saveSnapshot: { id, session in
                // Snapshot *before* compressing (docs/perf.md → *rehydration is real*): reading a
                // compressed session's history back rehydrates the pages compression just released.
                // Runs on the compressor's own `.utility` queue; `SnapshotStore` is a value type.
                guard let data = try? session.snapshot(),
                      let report = try? snapshots.save(data, for: id) else { return 0 }
                return report.byteCount
            })
        let host = TerminalViewHost(
            renderContext: renderContext,
            defaultGrid: { [weak view] in
                view?.gridSizeForBounds() ?? TerminalSize(rows: 40, cols: 120)
            },
            snapshots: snapshots,
            tkzmuxDirectory: tkzmuxDirectory,
            compressor: compressor)
        self.init(store: store, host: host, terminalView: view, theme: theme)
        self.metalView = view
        wireInput(view: view, host: host)
        // The timer source comes back suspended; nothing compresses until this runs.
        compressor.start()
    }

    // No `deinit`: the ⌘C/⌘V monitor is removed in ``shutdown()``. A `deinit` cannot touch it —
    // `NSEvent`'s monitor token is `Any`, which a nonisolated deinit may not read under Swift 6.

    // MARK: Assembly

    private func buildSplitView() {
        // A *plain* item, not `sidebarWithViewController:`. On macOS 26 the sidebar flavour wraps
        // its view in a concentric glass container — rounded corners, an 8 pt inset and a vibrancy
        // backdrop — which is not what artboard 2c draws: a flat column on `sidebarBackground`
        // with a 1 pt border against the terminal. A plain item gives the view the whole column
        // and the thin divider is the border. Collapsing, thickness and holding priority are all
        // set by hand below, so nothing the sidebar flavour configured is lost.
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
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
        // The titlebar is transparent and the content extends under it; `ChromeViewController`
        // paints its own behind-window vibrancy there (the glass behind the ＋ menu and the search
        // field) with the design's 1 pt bottom border. AppKit's own titlebar material was tried on
        // 2026-09-08 and came out nearly opaque with no transparency knob; the M2.2–M2.5 setup had
        // the transparent titlebar but nothing translucent behind it, so it read as a flat strip.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumContentSize
        window.backgroundColor = theme.windowBackground.nsColor
        // The titlebar material, the toolbar and every system control take their colours from
        // the window's appearance, not from our tokens. A dark preset in an `.aqua` window gives
        // a white titlebar over dark content. Derive it from the theme rather than from the
        // system setting.
        window.appearance = NSAppearance(
            named: theme.windowBackground.relativeLuminance < 0.5 ? .darkAqua : .aqua)
        window.contentViewController = chrome
        window.toolbar = toolbarController.toolbar
        window.delegate = self
        // Realise the titlebar and the toolbar *before* placing the window: AppKit lays a toolbar
        // out lazily and, when it does, re-derives the frame from the content size — with a
        // non-full-size content view a frame applied before that point came back 52 pt taller (a
        // stored 700 pt window relaunched at 752 pt; reproduced 2026-09-08). Harmless with
        // `.fullSizeContentView`, where content and frame coincide, and kept so the placement does
        // not depend on that style bit.
        window.layoutIfNeeded()
        window.setFrame(
            store.state.windowFrame ?? NSRect(origin: .zero, size: Self.defaultWindowSize),
            display: false)
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
        sidebar.onNewGroup = { [weak self] in self?.presentNewGroupPanel() }
        // The × on a hovered row: the same verb as ⌘W, confirmation included.
        sidebar.onRemoveSession = { [weak self] id in self?.removeSession(id) }
        sidebar.onSessionContextMenu = { [weak self] id in self?.sessionContextMenu(for: id) }
        sidebar.onGroupContextMenu = { [weak self] id in self?.groupContextMenu(for: id) }
    }

    // MARK: New group

    /// Overrides the new-group name sheet: returns the name, or nil for cancel. Tests set it —
    /// a sheet needs a key window and a run loop.
    public var groupNamePrompt: (() -> String?)?

    /// "＋ New group": asks for a name (see ``createGroup(named:)``). The group starts as a
    /// bucket; *Set Repo…* on its context menu attaches a repo afterwards.
    public func presentNewGroupPanel() {
        if let groupNamePrompt {
            guard let answer = groupNamePrompt() else { return }
            createGroup(named: answer)
            return
        }
        let alert = NSAlert()
        alert.messageText = "New Group"
        alert.informativeText = "Name it. To give it a repo, right-click the group and pick Set Repo\u{2026}"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Group name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.createGroup(named: field.stringValue)
            self.focusTerminalIfSessionShown()
        }
    }

    /// "In another repo…" (M5.2): a folder picker, and the new group's first session starts at
    /// once — `claude` in the chosen folder. Choosing a folder that already roots a group launches
    /// into that group.
    public func presentAnotherRepoPanel() {
        presentFolderPanel(prompt: "Start here",
                           message: "Choose a repo. It becomes a group, and claude starts in it.") { [weak self] url in
            guard let self, let groupID = self.createGroup(from: url) else { return }
            self.store.flush()
            self.newSessionMenu.configure(state: self.store.state, groupID: groupID)
            guard let launch = self.newSessionMenu.repoRootLaunch() else { return }
            self.newSessionMenu.perform(launch)
        }
    }

    /// Overrides the folder picker: returns the folder, or nil for cancel. Tests set it — an
    /// `NSOpenPanel` sheet needs a key window and a run loop.
    public var folderPrompt: ((String) -> URL?)?

    private func presentFolderPanel(prompt: String, message: String, completion: @escaping (URL) -> Void) {
        if let folderPrompt {
            if let url = folderPrompt(prompt) { completion(url) }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    /// Adds a group rooted at `folder` (it comes up expanded, as every new group does). The group
    /// is named after the folder; the folder is its `repoRoot`, so the new-session menu can launch
    /// into it straight away.
    /// Choosing a folder that is already a group's root just selects nothing new — no duplicate.
    @discardableResult
    public func createGroup(from folder: URL) -> GroupID? {
        let path = folder.standardizedFileURL.path
        if let existing = group(rootedAt: path) { return existing.id }
        let name = folder.lastPathComponent.isEmpty ? path : folder.lastPathComponent
        var created: GroupID?
        store.update { state in
            created = state.addGroup(name: name, repoRoot: path).id
        }
        return created
    }

    /// The group rooted at `path`, if any. One folder roots at most one group — the rule
    /// ``createGroup(from:)`` and *Set Repo…* both keep. Paths are stored as written, so the
    /// stored root is tilde-expanded before the comparison.
    func group(rootedAt path: String) -> Group? {
        // `orderedGroups`, not `groups.values`: a dictionary's first match is not stable, and this
        // decides which group "In another repo…" lands in.
        store.state.orderedGroups.first {
            $0.repoRoot.map { ($0 as NSString).expandingTildeInPath } == path
        }
    }

    /// Adds a bucket group with `name` (it comes up expanded, as every new group does). An empty
    /// or whitespace-only name creates nothing, the same as cancelling. Names are not deduped —
    /// unlike `repoRoot`, a name is not an identity.
    @discardableResult
    public func createGroup(named name: String) -> GroupID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var created: GroupID?
        store.update { state in
            created = state.addGroup(name: trimmed).id
        }
        return created
    }

    private func wireToolbar() {
        newSessionMenu.configureForSelection(state: store.state)
        newSessionMenu.onLaunch = { [weak self] launch in self?.launch(launch) }
        newSessionMenu.onChooseAnotherRepo = { [weak self] in self?.presentAnotherRepoPanel() }
        newSessionMenu.onManagePresets = { [weak self] in self?.presentPresetsSheet() }
        newSessionMenu.onSelectAccount = { [weak self] groupID, key in
            self?.setGroupDefaultAccount(groupID, key: key)
        }
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
        // Both transports address a *terminal*, never "the visible one": with several panes on
        // screen the latter names nothing, and would type the unfocused pane's keystrokes into the
        // focused pane's shell (TKZ-36).
        inputController.writeInput = { [weak self, weak host] data in
            guard let host, let id = self?.focusedVisibleTerminalID else { return }
            host.writeInput(id, data)
        }
        inputController.isFocusReportingEnabled = { [weak self, weak host] in
            guard let host, let id = self?.focusedVisibleTerminalID else { return false }
            return host.session(for: id)?.mode(1004) ?? false
        }
        inputController.mouseHandler = mouseController
        mouseController.attach(to: view)
        mouseController.sendBytes = { [weak self, weak host] bytes in
            guard let host, let id = self?.focusedVisibleTerminalID else { return }
            host.writeInput(id, Data(bytes))
        }
        // `view.onGridResize` is deliberately *not* set here any more: `TerminalHost.show`
        // installs it per pane on attach, which is the only place the view↔terminal pairing is
        // known. `resizeVisible` is gone with it.
        host.onDidShow = { [weak self] _ in self?.updateToolbarTitle() }

    }

    /// The cheat sheet, and with it the window's one key monitor.
    ///
    /// `.flagsChanged` is what makes "hold ⌘" observable at all — no responder method sees a
    /// modifier that never becomes a chord. The monitor is installed here, from the designated
    /// initialiser, rather than in ``wireInput(view:host:)``: `handleCommandKey` already declines
    /// when there is no `metalView`, so the copy/paste half stays inert for the plain-view windows
    /// tests build, while the cheat sheet works in both.
    private func wireCheatSheet() {
        cheatSheet.menuProvider = { [weak self] in self?.buildMainMenu() }

        // ⌘C / ⌘V. `TerminalInputController` declines anything with ⌘ held so the menu bar keeps
        // working, and there is deliberately **no Edit menu**: an Edit menu would win the key
        // match and route `copy:`/`paste:` at a first responder that does not implement them.
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // Deliberately *not* gated on the first responder the way `handleCommandKey` is:
            // clicking a sidebar row makes the outline view first responder, and holding ⌘ there
            // should still show the sheet.
            switch event.type {
            case .flagsChanged:
                self.cheatSheet.flagsChanged(event.modifierFlags)
            default:
                self.cheatSheet.keyDown(event.modifierFlags)
                if self.handleCommandKey(event) { return nil }
            }
            return event
        }
    }

    /// The terminal keystrokes belong to: the selected row's focused pane, but only once it is
    /// actually attached to a surface. A row restored from `state.json` has a focused leaf in the
    /// model long before it has a pty, and writing to that would be dropped anyway.
    var focusedVisibleTerminalID: TerminalID? {
        guard let id = store.state.selection,
            let terminal = store.state.sessions[id]?.focusedTerminalID,
            host.visibleTerminalIDs.contains(terminal)
        else { return nil }
        return terminal
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
        snapshotTimer?.cancel()
        snapshotTimer = nil
        statusTickTimer?.cancel()
        statusTickTimer = nil
        git?.stop()
        eventPump?.cancel()
        eventPump = nil
        if let host = host as? TerminalViewHost {
            _ = host.snapshotAll()
            host.closeAll(signal: SIGHUP)
        }
        cheatSheet.stop()
        if let commandKeyMonitor {
            NSEvent.removeMonitor(commandKeyMonitor)
            self.commandKeyMonitor = nil
        }
    }

    public func windowDidResize(_ notification: Notification) { recordWindowFrame() }
    public func windowDidMove(_ notification: Notification) { recordWindowFrame() }

    /// The user is looking at the selected row again: the `attendedAt` half of the NEEDS YOU rule
    /// (design.md → *Claude integration → Status derivation*). Selecting a row already marks it
    /// attended; this covers coming back to the window with a row still selected.
    public func windowDidBecomeKey(_ notification: Notification) {
        guard let id = store.state.selection else { return }
        store.update { $0.markAttended(id) }
    }

    /// Drops a ⌘ we will never see released. ⌘-Tab away with the cheat sheet up and the release
    /// lands while another app is active, where no local monitor of ours runs — without this the
    /// card would still be there on return. `MouseController.focusDidChange` clears held mouse
    /// buttons for exactly the same reason.
    public func windowDidResignKey(_ notification: Notification) {
        cheatSheet.resignedKey()
    }

    /// The M3 coordinator, once `AppDelegate` has built it. Setting it routes the last-message
    /// popover at the *full* Stop text rather than the 4 KiB the store keeps.
    public var claude: ClaudeIntegration? {
        didSet {
            guard let claude else { return }
            sidebar.lastMessageProvider = { id in claude.lastMessage(for: id) }
            claude.isSessionAttended = { [weak self] id in self?.isSessionAttended(id) ?? false }
            // `claude -w` removes its worktree when the conversation ends, which is before the
            // shell exits — so the worktree list is re-read on Claude's exit, not only the shell's.
            claude.onClaudeExited = { [weak self] id in self?.launcher.noteExit(id) }
            claude.onStop = { [weak self] id in self?.git?.sessionDidStop(id) }
        }
    }

    /// The M4 coordinator, once `AppDelegate` has built it. Every delivered change set is forwarded
    /// to it so it can re-target watchers and refresh the selected row.
    public var git: GitIntegration? {
        didSet {
            guard let git else { return }
            git.start()
            claude?.onStop = { [weak git] id in git?.sessionDidStop(id) }
        }
    }

    /// The selected row, in a key window the user can actually see. `NSApp.isActive` alone is not
    /// enough — an occluded key window still counts as active.
    func isSessionAttended(_ id: SessionID) -> Bool {
        guard store.state.selection == id, window.isKeyWindow, NSApp?.isActive == true else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    /// The whole last Stop message of the selected session, or nil.
    func lastMessageOfSelection() -> String? {
        guard let id = store.state.selection else { return nil }
        return claude?.lastMessage(for: id) ?? store.state.sessions[id]?.live?.lastStopMessage
    }

    /// ⇧⌘C.
    func copyLastMessage() {
        guard let text = lastMessageOfSelection(), !text.isEmpty else {
            showNotice("No message from Claude yet", for: .seconds(2))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showNotice("Copied the last message", for: .seconds(2))
    }

    /// Overrides the confirmation alert for "Remove Shell Integration". Tests set it.
    public var confirmRemoveShellIntegration: (() -> Bool)?

    /// Overrides the statusline consent sheet: gets the plan, returns true to install. Tests set
    /// it — `runModal()` in a test process never returns.
    public var confirmInstallStatusline: ((StatuslineInstallPlan) -> Bool)?
    /// Overrides the confirmation for removing the statusline again.
    public var confirmRemoveStatusline: (() -> Bool)?

    /// Overrides the rename sheet: gets the current title, returns the new one or `nil` for
    /// cancel. Tests set it — a sheet needs a key window and a run loop.
    public var renamePrompt: ((String) -> String?)?

    /// ⇧⌘R. Was in the menu since M2.4 with no handler behind it (GUI pass 2026-09-08, 5d).
    /// An empty answer clears the rename, so the derived title comes back.
    func renameSelectedSession() {
        guard let id = store.state.selection else { return }
        renameSession(id)
    }

    func renameSession(_ id: SessionID) {
        guard let session = store.state.sessions[id] else { return }
        let current = session.displayTitle
        if let renamePrompt {
            guard let answer = renamePrompt(current) else { return }
            store.update { $0.renameSession(id, title: answer) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Leave it empty to go back to the automatic title."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = session.title ?? ""
        field.placeholderString = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let answer = field.stringValue
            self.store.update { $0.renameSession(id, title: answer) }
            self.focusTerminalIfSessionShown()
        }
    }

    func removeShellIntegration() {
        guard let claude else { return }
        let confirmed: Bool
        if let confirmRemoveShellIntegration {
            confirmed = confirmRemoveShellIntegration()
        } else {
            let alert = NSAlert()
            alert.messageText = "Remove shell integration?"
            alert.informativeText = "Deletes the claude shim and the zsh wrappers under Application Support. "
                + "New shells will not report to tkzmux until the app is relaunched. Sessions and the sidebar are kept."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            confirmed = alert.runModal() == .alertFirstButtonReturn
        }
        guard confirmed else { return }
        do {
            try claude.removeShellIntegration()
            showNotice("Shell integration removed")
        } catch {
            logger.error("remove shell integration failed: \(String(describing: error), privacy: .public)")
            showNotice("Could not remove shell integration: \(error.localizedDescription)")
        }
    }

    // MARK: Status line integration (TKZ-32)

    /// The account the statusline commands act on: the selected row's, else the primary one.
    private var statuslineAccountKey: String {
        if let session = store.state.selectedSession, store.state.accounts[session.accountKey] != nil {
            return session.accountKey
        }
        return Account.defaultKey
    }

    /// The menu command — a toggle. Installing edits the user's `settings.json`, which nothing else
    /// in tkzmux does, so it never happens without the sheet below.
    func statusLineIntegration() {
        guard let claude else { return }
        let key = statuslineAccountKey
        if claude.statuslineProducer(accountKey: key) == .tkzmux {
            removeStatusline(accountKey: key)
        } else {
            offerStatusline(accountKey: key, automatic: false)
        }
    }

    /// Puts the install to the user. `automatic` is the once-per-install offer made at startup; it
    /// stays silent when there is nothing to offer, whereas the menu command reports why.
    func offerStatusline(accountKey: String, automatic: Bool) {
        guard let claude else { return }
        let plan: StatuslineInstallPlan?
        do {
            plan = try claude.statuslinePlan(accountKey: accountKey)
        } catch {
            logger.error("statusline plan failed: \(String(describing: error), privacy: .public)")
            if !automatic { showNotice("Could not read settings.json for \(accountKey)") }
            return
        }
        guard let plan, plan.producer != .tkzmux else { return }

        let confirmed: Bool
        if let confirmInstallStatusline {
            confirmed = confirmInstallStatusline(plan)
        } else {
            let alert = NSAlert()
            alert.messageText = "Show usage and context in the status bar?"
            var body = "tkzmux needs its own status line command to read Claude Code's quota and "
                + "context usage — they are handed to the status line and never written to disk.\n\n"
                + "This changes statusLine in \(plan.settingsPath):\n\n"
            if let before = plan.before {
                body += "Now:\n\(before)\n\nAfter:\n\(plan.after)\n\n"
                    + "Your current status line keeps running and its output is passed through "
                    + "unchanged. Status Line Integration in the app menu puts it back exactly."
            } else {
                body += "After:\n\(plan.after)\n\n"
                    + "Status Line Integration in the app menu removes it again."
            }
            alert.informativeText = body
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Not Now")
            confirmed = alert.runModal() == .alertFirstButtonReturn
        }
        // Asked is asked: a decline is an answer, and the menu command stays available.
        store.update { $0.setStatuslineOffered(true) }
        guard confirmed else { return }
        do {
            try claude.installStatusline(accountKey: accountKey)
            showNotice("Status line installed \u{2014} usage appears within a few seconds")
        } catch {
            logger.error("statusline install failed: \(String(describing: error), privacy: .public)")
            showNotice("Could not install the status line: \(error.localizedDescription)")
        }
    }

    func removeStatusline(accountKey: String) {
        guard let claude else { return }
        let confirmed: Bool
        if let confirmRemoveStatusline {
            confirmed = confirmRemoveStatusline()
        } else {
            let alert = NSAlert()
            alert.messageText = "Remove the tkzmux status line?"
            alert.informativeText = "Puts back the statusLine you had before, exactly. "
                + "The Context, model and Usage segments go empty."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            confirmed = alert.runModal() == .alertFirstButtonReturn
        }
        guard confirmed else { return }
        do {
            try claude.uninstallStatusline(accountKey: accountKey)
            showNotice("Status line removed")
        } catch {
            logger.error("statusline remove failed: \(String(describing: error), privacy: .public)")
            showNotice("Could not remove the status line: \(error.localizedDescription)")
        }
    }

    /// The one-time offer, made after `ClaudeIntegration.start()` rather than from `init` — a modal
    /// inside `init` blocks every window test, and the shim has to be installed before the command
    /// we write into settings.json exists on disk.
    func offerStatuslineIfNeeded() {
        guard let claude, !store.state.statuslineOffered else { return }
        let key = statuslineAccountKey
        guard claude.statuslineProducer(accountKey: key) != .tkzmux else {
            store.update { $0.setStatuslineOffered(true) }
            return
        }
        offerStatusline(accountKey: key, automatic: true)
    }

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
        // The pane tree changed shape: a split, a close, a tab switch, a zoom. In stage 2 that is
        // a re-attach; once the split container lands it is the one place that rebuilds it.
        // `focusTerminal: false` on purpose — a click that moved focus wrote it to the store, and
        // re-asserting `makeFirstResponder` from here would fight the click that caused it.
        if let selected = store.state.selection, change.layout.contains(selected) {
            applySelection(focusTerminal: false)
        }
        let selected = store.state.selection
        if change.selection || change.usage || (selected.map(change.touches) ?? false) {
            updateStatusBar()
            updateToolbarTitle()
        }
        git?.apply(change)
    }

    /// The divider position — the width of whichever child of the split view contains the sidebar.
    ///
    /// This is the quantity `setPosition` takes, and once the seeding constraint is retired
    /// `setPosition` is the only thing that places the sidebar, so recording and restoring it is a
    /// fixed point. Measured by walking up from the sidebar view, because the near-misses all
    /// drift: while the sidebar was a `sidebarWithViewController:` item its own view was 8 pt
    /// narrower than the column (the macOS 26 glass-container inset), so mixing the two lost or
    /// gained 8 pt on every launch; and neither `subviews.first` nor `arrangedSubviews.first` is
    /// the sidebar at all — the split view's children are not in visual order and the *detail*
    /// wrapper comes first, which recorded 852 pt. With today's plain item the walk stops at the
    /// sidebar view itself, and the two numbers agree.
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
        showSelectedTerminals()
        // M5.2: a selected row the host has nothing for — restored from `state.json`, never shown
        // in this run — gets its old screen and a fresh prompt now, lazily, on first show. A row
        // hung up with ⌘W is *not* this case: the host still holds its grid, so it stays dead
        // under the scrim until the user resumes it.
        if let id, host.visibleTerminalIDs.isEmpty, store.state.sessions[id]?.live == nil {
            switch launcher.reopen(id) {
            case .success:
                lastReopenFailure = nil
                showSelectedTerminals()
            case .failure(let failure):
                lastReopenFailure = failure
                showNotice(Self.reopenFailureNotice(failure))
            }
        }
        // A row that *is* running but whose active tab was never opened this run — the user just
        // switched to a background tab. `reopen` above deliberately only spawns the active tab's
        // panes, and it will not run at all here because `live != nil`, so the lazy restore needs
        // its own trigger. `selectTab` changes the tree's shape, so the `layout` bucket brings us
        // back through here.
        if let id, let session = store.state.sessions[id], session.live != nil {
            let missing = session.activeTabValue.terminalIDs.filter { !host.contains($0) }
            if !missing.isEmpty {
                for terminal in missing { _ = launcher.reopenTerminal(terminal) }
                showSelectedTerminals()
            }
        }
        // Visibility follows the *host*, not the selection. From M5.1 a restored row exists in the
        // store with no terminal behind it, and showing the surface for one draws an empty black
        // rectangle where the empty state belongs.
        let hasSurface = !host.visibleTerminalIDs.isEmpty
        detail.emptyState.isHidden = hasSurface
        detail.emptyStateMessage = emptyStateMessage(selection: id)
        terminalView.isHidden = !hasSurface
        if hasSurface, focusTerminal { focusTerminalIfSessionShown() }
    }

    /// Attaches the selected row's focused pane to the one Metal view.
    ///
    /// Stage 2 of TKZ-36 deliberately keeps the visible set at one: the model, the host and the
    /// launcher already speak N, so the split container is a pure view-layer addition on top of
    /// this line rather than a change that reaches back into any of them.
    private func showSelectedTerminals() {
        guard let id = store.state.selection,
            let terminal = store.state.sessions[id]?.focusedTerminalID,
            host.contains(terminal),
            let surface = metalView ?? terminalView as? any TerminalPaneSurface
        else {
            host.show([:])
            return
        }
        host.show([terminal: surface])
    }

    private func emptyStateMessage(selection: SessionID?) -> String {
        guard selection != nil else { return EmptyStateView.noSelectionMessage }
        if case .missingDirectory(let path)? = lastReopenFailure {
            return EmptyStateView.missingDirectoryMessage(path)
        }
        return EmptyStateView.notRunningMessage
    }

    static func reopenFailureNotice(_ failure: SessionLauncher.Failure) -> String {
        switch failure {
        case .missingDirectory(let path): "Can\u{2019}t reopen: \(path) is missing"
        case .spawnFailed(let reason): "Can\u{2019}t reopen: \(reason)"
        case .unknownSession: "Can\u{2019}t reopen: unknown session"
        }
    }

    /// The one place that decides the terminal has the keyboard. Without it a selected session
    /// renders and swallows nothing.
    func focusTerminalIfSessionShown() {
        guard !host.visibleTerminalIDs.isEmpty else { return }
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
    /// separator (see `StatusBarView.items`).
    static func statusModel(for state: AppState, now: Date = Date()) -> StatusBarModel {
        guard let session = state.selectedSession else { return .empty }
        let git = session.live?.git
        let sidecar = session.live?.context
        let usage = state.usage(for: session)?.sevenDay

        var model = StatusBarModel()
        model.branch = git?.branch
        model.isWorktree = (session.isWorktree || git?.isWorktree == true) ? true : nil
        if model.isWorktree == true, let path = session.worktreePath, !path.isEmpty {
            model.worktreeName = Session.title(forPath: path)
        }
        model.modelName = sidecar?.model?.displayName
        model.diffAdded = git.map(\.insertions)
        model.diffRemoved = git.map(\.deletions)
        model.diffFiles = git.map(\.changedFiles)
        // No upstream is a *state*, not an absence: the strip draws `↑– ↓–` dimmed instead of the
        // `↑0 ↓0` that would claim the branch is in sync with a remote it does not have.
        model.upstream = git?.upstream
        model.upstreamMissing = git != nil && git?.upstream == nil
        if git?.upstream != nil {
            model.ahead = git.map(\.ahead)
            model.behind = git.map(\.behind)
        }
        // Sidecar first, `gh` second — design.md → *Git integration → PR*. `GitStatusService` owns
        // `GitSummary.pr` and has already merged whatever `PRLookup` found, so the sidecar only
        // wins where nothing was looked up.
        model.pullRequest = git?.pr ?? sidecar?.pr
        let ports = session.live?.ports ?? []
        model.ports = ports.isEmpty ? nil : ports
        model.portOwners = session.live?.portOwners ?? [:]
        model.contextPercent = sidecar?.contextUsedPercentage.map { Int($0.rounded()) }
        model.usagePercent = usage.map { Int($0.usedPercentage.rounded()) }
        if let resetsAt = usage?.resetsAt, resetsAt > now {
            model.usageResetsIn = .seconds(Int(resetsAt.timeIntervalSince(now)))
            model.usageResetsAtText = Self.resetsAtFormatter.string(from: resetsAt)
        }
        model.usageTooltip = usageTooltip(for: state)
        return model
    }

    /// `2026-09-12 08:00`, fixed and locale-independent: the tooltip must read the same on any
    /// machine, and the model's contract is that it renders to fixed pixels.
    static let resetsAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// One line per account with a seven-day window — the ticket asks the usage badge's tooltip to
    /// show *both* accounts' windows, because the percentage on the strip belongs to whichever
    /// account the selected row runs under and the user runs more than one.
    ///
    /// Naming follows the same precedence as everywhere else: the name a human configured in
    /// `dash-accounts.json` first, then the one the usage file generated, then the bare key. The
    /// sidebar chip is derived from `Account.label`, so preferring the usage file's name here
    /// would let the strip and the chip call one account two things.
    static func usageTooltip(for state: AppState) -> String? {
        let lines = state.usage.values
            .sorted { $0.accountKey < $1.accountKey }
            .compactMap { snapshot -> String? in
                guard let window = snapshot.sevenDay else { return nil }
                let account = state.accounts[snapshot.accountKey]
                let configured = account.flatMap { $0.label == $0.key ? nil : $0.label }
                let name = configured ?? snapshot.label ?? account?.label ?? snapshot.accountKey
                return "\(name): \(Int(window.usedPercentage.rounded()))% of the seven-day quota"
            }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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

    /// Starts a session for a resolved `Launch` (see `SessionLauncher.start`). A failure is modal:
    /// the user just asked for this and nothing else on screen explains why it did not happen.
    public func launch(_ launch: NewSessionMenu.Launch) {
        switch launcher.start(launch) {
        case .success:
            break
        case .failure(.missingDirectory(let path)):
            presentLaunchFailure("\(path) is not a directory.")
        case .failure(.spawnFailed(let reason)):
            presentLaunchFailure(reason)
        case .failure(.unknownSession):
            presentLaunchFailure("unknown session")
        }
    }

    /// The grid a terminal opens at — the *pane's*, not the window's.
    ///
    /// With one pane per row those are the same number, which is why this took no argument before.
    /// A split pane is a fraction of the window, and spawning it at the window's grid would make
    /// every new pane reflow on its first frame. `metalView` is nil only on the injected-host path
    /// (tests).
    private func launchSize(for terminal: TerminalID) -> TerminalSize {
        metalView?.gridSizeForBounds() ?? TerminalSize(rows: 40, cols: 120)
    }

    // MARK: - Resume

    /// ⌘R: `claude --resume` the selected row (reopening its shell first if it has none).
    func resumeSelectedSession() {
        guard let id = store.state.selection else { return }
        resumeSession(id)
    }

    func resumeSession(_ id: SessionID) {
        let outcome = launcher.resume(id)
        // A reopen of the *selected* row replaces its host session, which detaches the surface,
        // and the selection has not changed — so nothing else would re-attach it. Idempotent
        // when the row was another one: the selection change re-shows through the observer too.
        reattachSurface()
        switch outcome {
        case .success(.resumed):
            focusTerminalIfSessionShown()
        case .success(.claudeRunning):
            showNotice("Claude is already running in this session", for: .seconds(3))
        case .success(.nothingToResume):
            showNotice("No Claude conversation to resume \u{00B7} the shell is back", for: .seconds(4))
        case .failure(let failure):
            showNotice(Self.reopenFailureNotice(failure))
        }
    }

    /// "Resume all in group" — the selected session's group, or `groupID`.
    func resumeAll(inGroup groupID: GroupID? = nil) {
        guard let group = groupID ?? store.state.selectedSession?.groupID else { return }
        let outcome = launcher.resumeAll(in: group)
        reattachSurface()
        let name = store.state.groups[group]?.name ?? "group"
        var text = "Resumed \(outcome.resumed.count) in \(name)"
        if !outcome.failed.isEmpty { text += " \u{00B7} \(outcome.failed.count) failed" }
        showNotice(text, for: .seconds(4))
    }

    /// The "auto-resume on launch" pass. `AppDelegate` calls it once the Claude integration is up,
    /// so every `claude --resume` runs through the shim and gets a `launch` frame.
    public func autoResumeIfEnabled() {
        guard store.state.autoResumeOnLaunch else { return }
        let ids = store.state.orderedSessions.map(\.id)
        let outcome = launcher.resumeAll(ids)
        reattachSurface()
        logger.info("auto-resume: \(outcome.resumed.count) resumed, \(outcome.failed.count) failed")
        if !outcome.resumed.isEmpty || !outcome.failed.isEmpty {
            var text = "Auto-resumed \(outcome.resumed.count) session\(outcome.resumed.count == 1 ? "" : "s")"
            if !outcome.failed.isEmpty { text += " \u{00B7} \(outcome.failed.count) failed" }
            showNotice(text, for: .seconds(6))
        }
    }

    /// Re-shows the selection after something replaced host sessions underneath it (a reopen).
    /// `applySelection` reads the store's *current* selection, which a `select` inside the launcher
    /// has already set even though its change set is delivered next turn.
    private func reattachSurface() {
        applySelection(focusTerminal: false)
    }

    func toggleAutoResume() {
        store.update { $0.setAutoResumeOnLaunch(!$0.autoResumeOnLaunch) }
    }

    // MARK: - Close / remove

    /// Overrides the "remove a working session?" alert: gets the session, returns whether to go
    /// ahead. Only asked for a `working` or `waiting` row. Tests set it.
    public var confirmRemove: ((Session) -> Bool)?

    /// Overrides the "remove a group with sessions in it?" alert: gets the group and its members,
    /// returns whether to go ahead. Only asked for a group that still has rows. Tests set it.
    public var confirmRemoveGroup: ((Group, [Session]) -> Bool)?

    /// ⌘W, the row's `×`, the context menu: the session goes — row, shell and snapshot. There is
    /// no "closed but kept" state (decision 2026-09-08: a terminal cannot be exited). A session
    /// that is `working` or `waiting` is confirmed first — Claude is mid-answer, or mid-question;
    /// an idle one goes at once. The worktree on disk is never touched, and the conversation
    /// itself is Claude Code's to keep.
    func removeSelectedSession() {
        guard let id = store.state.selection else { return }
        removeSession(id)
    }

    func removeSession(_ id: SessionID) {
        guard let session = store.state.sessions[id] else { return }
        let busy: Bool
        switch session.status {
        case .working, .waiting: busy = true
        case .idle: busy = false
        }
        if busy {
            let confirmed = confirmRemove?(session) ?? runConfirmation(
                title: "Close \u{201C}\(session.displayTitle)\u{201D}?",
                message: session.status == .working
                    ? "Claude is still working in this session. Closing ends the shell and removes the row; the conversation is kept by Claude Code."
                    : "This session is waiting for you. Closing ends the shell and removes the row; the conversation is kept by Claude Code.",
                button: "Close")
            guard confirmed else { return }
        }
        launcher.remove(id)
    }

    /// The group header's context menu: the group goes, and with it every session in it — row,
    /// shell and snapshot, exactly as ⌘W sends one row. An empty group goes at once; one that
    /// still holds rows is confirmed first, once for the whole group rather than once per member,
    /// because a collapsed header hides what is about to be closed. Sessions are never reassigned
    /// to another group: dragging a row out first is how you keep it. Worktrees are not touched.
    func removeGroup(_ id: GroupID) {
        guard let group = store.state.groups[id] else { return }
        let members = store.state.sessions(in: id)
        if !members.isEmpty {
            let confirmed = confirmRemoveGroup?(group, members) ?? runConfirmation(
                title: "Remove \u{201C}\(group.name)\u{201D} and its \(members.count) session\(members.count == 1 ? "" : "s")?",
                message: Self.removeGroupMessage(members),
                button: "Remove")
            guard confirmed else { return }
        }
        launcher.removeGroup(id)
    }

    /// The alert's body. The busy count is called out because those are the rows the user would
    /// have been asked about one at a time had they closed them with ⌘W.
    private static func removeGroupMessage(_ members: [Session]) -> String {
        let busy = members.filter { member in
            switch member.status {
            case .working, .waiting: return true
            case .idle: return false
            }
        }.count
        var text = "Removing the group ends their shells and removes their rows"
        if busy > 0 {
            text += " \u{2014} \(busy) \(busy == 1 ? "is" : "are") still working or waiting on you"
        }
        text += ". The conversations are kept by Claude Code, and the worktrees on disk are not"
        text += " touched."
        return text
    }

    private func runConfirmation(title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Context menus

    /// Right-click on a session row: Resume / Rename / Remove, each enabled only when it can do
    /// something. The row is addressed by id, never by the selection.
    func sessionContextMenu(for id: SessionID) -> NSMenu? {
        guard let session = store.state.sessions[id] else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let resume = contextItem("Resume", action: #selector(contextResume(_:)), id: id.rawValue)
        resume.isEnabled = session.claudeSessionId != nil && session.live?.descriptor == nil
        resume.identifier = ContextItemID.resume
        menu.addItem(resume)

        let rename = contextItem("Rename\u{2026}", action: #selector(contextRename(_:)), id: id.rawValue)
        rename.identifier = ContextItemID.rename
        menu.addItem(rename)
        menu.addItem(.separator())

        let remove = contextItem("Remove", action: #selector(contextRemove(_:)), id: id.rawValue)
        remove.identifier = ContextItemID.remove
        menu.addItem(remove)

        // Only offered when there is actually something to kill. Nothing in the system reclaims a
        // stalled process's memory — jetsam will not kill it — so when a build or test under this
        // session runs away, killing it by hand is the only way out. The pty's own shell is spared,
        // so the row stays usable. See `SessionMemory`.
        if let pid = (host as? TerminalViewHost)?.pid(of: id) {
            let sample = SessionMemory.sample(rootPid: pid)
            if sample.descendantCount > 0 {
                // Describes what would actually be killed: the descendants and their bytes, never
                // the shell that is spared.
                let size = MainWindowController.megabytes(sample.descendantBytes)
                let what = sample.largestName.isEmpty ? "processes" : sample.largestName
                let kill = contextItem(
                    "Kill Processes (\(what), \(size))",
                    action: #selector(contextKillProcessTree(_:)), id: id.rawValue)
                kill.identifier = ContextItemID.killProcessTree
                menu.addItem(kill)
            }
        }

        // The colour and the default account belong to the group, not the row — but the row is what
        // you are pointing at when you decide the whole group needs one, so both pickers are on
        // both menus (TKZ-48).
        menu.addItem(.separator())
        menu.addItem(groupColorMenuItem(for: session.groupID))
        menu.addItem(groupDefaultAccountMenuItem(for: session.groupID))
        return menu
    }

    /// Right-click on a group header: New session… / Resume all in group / Set Repo… / Remove
    /// group, plus the colour and default-account pickers.
    func groupContextMenu(for id: GroupID) -> NSMenu? {
        guard let group = store.state.groups[id] else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let new = contextItem("New session in \(group.name)\u{2026}", action: #selector(contextNewSession(_:)), id: id.rawValue)
        new.identifier = ContextItemID.newSession
        menu.addItem(new)
        let resumeAll = contextItem("Resume all in \(group.name)", action: #selector(contextResumeAll(_:)), id: id.rawValue)
        resumeAll.isEnabled = store.state.sessions(in: id).contains {
            $0.claudeSessionId != nil && $0.live?.descriptor == nil
        }
        resumeAll.identifier = ContextItemID.resumeAll
        menu.addItem(resumeAll)
        // A group made by name is a bucket: the two `claude` rows on its ＋ menu stay disabled
        // ("no repo — add one to this group first") until a folder is attached here.
        let repo = contextItem(
            group.repoRoot == nil ? "Set Repo\u{2026}" : "Change Repo\u{2026}",
            action: #selector(contextSetGroupRepo(_:)), id: id.rawValue)
        repo.identifier = ContextItemID.groupRepo
        menu.addItem(repo)
        menu.addItem(.separator())

        let remove = contextItem("Remove group", action: #selector(contextRemoveGroup(_:)), id: id.rawValue)
        remove.identifier = ContextItemID.removeGroup
        menu.addItem(remove)

        menu.addItem(.separator())
        menu.addItem(groupColorMenuItem(for: id))
        menu.addItem(groupDefaultAccountMenuItem(for: id))
        return menu
    }

    // MARK: Group colour

    /// "Group color ▸": one item per `GroupPalette.swatches`, then **None**.
    ///
    /// The swatch is drawn as a small filled circle rather than left to a colour name alone — the
    /// point of the picker is that you pick by eye. It is deliberately not a template image, which
    /// AppKit would recolour to the menu's text colour.
    ///
    /// The current colour carries a checkmark. Matching goes through `GroupPalette.swatch(matching:)`,
    /// which compares 8-bit channels, so the mark still lands after a round trip through
    /// `state.json`. A colour that is not in the palette (an older build, a hand-edited file) simply
    /// leaves every item unchecked; it is not overwritten until the user picks something.
    private func groupColorMenuItem(for id: GroupID) -> NSMenuItem {
        let parent = NSMenuItem(title: "Group color", action: nil, keyEquivalent: "")
        parent.identifier = ContextItemID.groupColor
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let current = store.state.groups[id]?.color
        let currentSwatch = GroupPalette.swatch(matching: current)

        for swatch in GroupPalette.swatches {
            let item = colorItem(swatch.name, groupID: id, color: swatch.rgb)
            item.identifier = ContextItemID.groupColorSwatch(swatch.slug)
            item.image = Self.swatchImage(swatch.rgb)
            item.state = swatch == currentSwatch ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        let none = colorItem("None", groupID: id, color: nil)
        none.identifier = ContextItemID.groupColorNone
        none.state = current == nil ? .on : .off
        submenu.addItem(none)

        parent.submenu = submenu
        return parent
    }

    /// Which group, and which colour. `contextItem(_:action:id:)` carries a single `String`, and a
    /// colour item needs both, so it gets its own `representedObject`.
    private struct GroupColorChoice {
        let groupID: GroupID
        let color: RGB?
    }

    private func colorItem(_ title: String, groupID: GroupID, color: RGB?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(contextSetGroupColor(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = GroupColorChoice(groupID: groupID, color: color)
        return item
    }

    private static let swatchDiameter: CGFloat = 10

    private static func swatchImage(_ color: RGB) -> NSImage {
        let size = NSSize(width: swatchDiameter, height: swatchDiameter)
        let image = NSImage(size: size, flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func contextSetGroupColor(_ sender: Any?) {
        guard let choice = (sender as? NSMenuItem)?.representedObject as? GroupColorChoice else { return }
        store.update { $0.setGroupColor(choice.groupID, color: choice.color) }
    }

    // MARK: Group default account

    /// The one place `Group.defaultAccountKey` is written — the ＋ menu's submenu and the two
    /// context menus all land here.
    ///
    /// The re-``configure`` afterwards is load-bearing: `NewSessionMenu.group` is a value copy that
    /// `menuNeedsUpdate` rebuilds from, and a `defaultAccountKey` edit sets only `change.groups`
    /// (not `structure`), which `apply(_:)` deliberately does not re-scope the menu on.
    private func setGroupDefaultAccount(_ id: GroupID, key: String?) {
        store.update { $0.setGroupDefaultAccount(id, accountKey: key) }
        newSessionMenu.configure(state: store.state, groupID: id)
    }

    /// "Default account ▸": which account new sessions in this group get. Built like
    /// ``groupColorMenuItem(for:)`` — one row per known account, the current one checked, then
    /// **None**, which clears the default and leaves `CLAUDE_CONFIG_DIR` unset.
    ///
    /// A default naming an account that is no longer in `state.accounts` (a deleted `~/.claude-…`)
    /// gets a disabled, checked row saying `not found`, rather than a list with nothing marked.
    private func groupDefaultAccountMenuItem(for id: GroupID) -> NSMenuItem {
        let parent = NSMenuItem(title: "Default account", action: nil, keyEquivalent: "")
        parent.identifier = ContextItemID.groupAccount
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let current = store.state.groups[id]?.defaultAccountKey
        let accounts = store.state.accounts

        for key in accounts.keys.sorted() {
            let item = accountItem(accounts[key]?.label ?? key, groupID: id, key: key)
            item.identifier = ContextItemID.groupAccountRow(key)
            item.state = key == current ? .on : .off
            item.toolTip = accounts[key]?.configDir
            submenu.addItem(item)
        }
        if accounts.isEmpty {
            let empty = NSMenuItem(title: "No accounts configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        if let current, accounts[current] == nil {
            let missing = NSMenuItem(title: "\(current) \u{2014} not found", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            missing.state = .on
            missing.identifier = ContextItemID.groupAccountMissing
            submenu.addItem(missing)
        }

        submenu.addItem(.separator())
        let none = accountItem("None", groupID: id, key: nil)
        none.identifier = ContextItemID.groupAccountNone
        none.state = current == nil ? .on : .off
        none.toolTip = "CLAUDE_CONFIG_DIR is left unset \u{2014} your shell decides"
        submenu.addItem(none)

        parent.submenu = submenu
        return parent
    }

    /// Which group, and which account key (`nil` = clear) — the account twin of
    /// ``GroupColorChoice``, for the same reason: `contextItem(_:action:id:)` carries one `String`.
    private struct GroupAccountChoice {
        let groupID: GroupID
        let key: String?
    }

    private func accountItem(_ title: String, groupID: GroupID, key: String?) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: #selector(contextSetGroupDefaultAccount(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = GroupAccountChoice(groupID: groupID, key: key)
        return item
    }

    @objc private func contextSetGroupDefaultAccount(_ sender: Any?) {
        guard let choice = (sender as? NSMenuItem)?.representedObject as? GroupAccountChoice else { return }
        setGroupDefaultAccount(choice.groupID, key: choice.key)
    }

    /// Identifiers for the context-menu rows, so tests can find them.
    public enum ContextItemID {
        public static let resume = NSUserInterfaceItemIdentifier("tkzmux.context.resume")
        public static let rename = NSUserInterfaceItemIdentifier("tkzmux.context.rename")
        public static let remove = NSUserInterfaceItemIdentifier("tkzmux.context.remove")
        public static let killProcessTree = NSUserInterfaceItemIdentifier("tkzmux.context.killProcessTree")
        public static let newSession = NSUserInterfaceItemIdentifier("tkzmux.context.newSession")
        public static let resumeAll = NSUserInterfaceItemIdentifier("tkzmux.context.resumeAll")
        public static let groupRepo = NSUserInterfaceItemIdentifier("tkzmux.context.groupRepo")
        public static let removeGroup = NSUserInterfaceItemIdentifier("tkzmux.context.removeGroup")
        /// The "Group color" parent item; its `submenu` holds the swatches.
        public static let groupColor = NSUserInterfaceItemIdentifier("tkzmux.context.groupColor")
        public static let groupColorNone = NSUserInterfaceItemIdentifier("tkzmux.context.groupColor.none")
        /// One swatch, addressed by `GroupSwatch.slug`.
        public static func groupColorSwatch(_ slug: String) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("tkzmux.context.groupColor.\(slug)")
        }
        /// The "Default account" parent item; its `submenu` holds one row per account.
        public static let groupAccount = NSUserInterfaceItemIdentifier("tkzmux.context.groupAccount")
        public static let groupAccountNone = NSUserInterfaceItemIdentifier("tkzmux.context.groupAccount.none")
        /// The group's default names an account `state.accounts` no longer has.
        public static let groupAccountMissing =
            NSUserInterfaceItemIdentifier("tkzmux.context.groupAccount.missing")
        /// One account row, addressed by `Account.key`.
        public static func groupAccountRow(_ key: String) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("tkzmux.context.groupAccount.row.\(key)")
        }
    }

    private func contextItem(_ title: String, action: Selector, id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    private func sessionID(from sender: Any?) -> SessionID? {
        ((sender as? NSMenuItem)?.representedObject as? String).flatMap(SessionID.init)
    }

    private func groupID(from sender: Any?) -> GroupID? {
        ((sender as? NSMenuItem)?.representedObject as? String).flatMap(GroupID.init)
    }

    @objc private func contextResume(_ sender: Any?) {
        guard let id = sessionID(from: sender) else { return }
        resumeSession(id)
    }

    @objc private func contextRename(_ sender: Any?) {
        guard let id = sessionID(from: sender) else { return }
        renameSession(id)
    }

    @objc private func contextRemove(_ sender: Any?) {
        guard let id = sessionID(from: sender) else { return }
        removeSession(id)
    }

    /// Overrides the kill confirmation: return true to proceed. Tests set it — an alert needs a
    /// key window and a run loop.
    public var killProcessTreeConfirm: ((SessionMemorySample) -> Bool)?

    @objc private func contextKillProcessTree(_ sender: Any?) {
        guard let id = sessionID(from: sender) else { return }
        killProcessTree(for: id)
    }

    /// SIGKILLs everything under the session's pty child, sparing the shell itself.
    ///
    /// Confirmed first: this destroys whatever the user was running (a build, a test run, a
    /// Claude Code session), and unlike *Remove* it is not undoable by resuming.
    public func killProcessTree(for id: SessionID) {
        guard let pid = (host as? TerminalViewHost)?.pid(of: id) else { return }
        let sample = SessionMemory.sample(rootPid: pid)
        guard sample.descendantCount > 0 else { return }

        if let killProcessTreeConfirm {
            guard killProcessTreeConfirm(sample) else { return }
        } else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Kill this session's processes?"
            let count = sample.descendantCount
            let largest = sample.largestName.isEmpty
                ? "" : ", the largest being \u{201c}\(sample.largestName)\u{201d}"
            alert.informativeText = """
                \(count) process\(count == 1 ? "" : "es") under this session \
                \(count == 1 ? "is" : "are") holding \
                \(MainWindowController.megabytes(sample.descendantBytes))\(largest). \
                They will be killed immediately and anything they were doing is lost. The \
                session's own shell stays open.
                """
            alert.addButton(withTitle: "Kill")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let killed = SessionMemory.terminateTree(rootPid: pid)
        logger.info("killed \(killed.count) process(es) under session \(id.rawValue, privacy: .public)")
        showNotice("Killed \(killed.count) process\(killed.count == 1 ? "" : "es")")
        focusTerminalIfSessionShown()
    }

    static func megabytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 1024
            ? String(format: "%.1f GB", mb / 1024)
            : String(format: "%.0f MB", mb)
    }

    @objc private func contextNewSession(_ sender: Any?) {
        guard let id = groupID(from: sender) else { return }
        presentNewSessionMenu(for: id)
    }

    @objc private func contextResumeAll(_ sender: Any?) {
        guard let id = groupID(from: sender) else { return }
        resumeAll(inGroup: id)
    }

    @objc private func contextRemoveGroup(_ sender: Any?) {
        guard let id = groupID(from: sender) else { return }
        removeGroup(id)
    }

    @objc private func contextSetGroupRepo(_ sender: Any?) {
        guard let id = groupID(from: sender) else { return }
        presentFolderPanel(prompt: "Set repo",
                           message: "Choose the repo this group's sessions start in.") {
            [weak self] url in
            guard let self else { return }
            let path = url.standardizedFileURL.path
            if let other = self.group(rootedAt: path), other.id != id {
                self.showNotice("\u{201C}\(other.name)\u{201D} is already rooted there",
                                for: .seconds(4))
                return
            }
            self.store.update { $0.setGroupRepoRoot(id, path: path) }
        }
    }

    // MARK: - Presets

    /// Overrides the presets sheet. Tests set it.
    public var presetsPrompt: (([Preset]) -> [Preset]?)?

    /// "Manage presets…": the sheet edits a copy and commits the whole list on Done.
    public func presentPresetsSheet() {
        let current = store.state.presets
        if let presetsPrompt {
            if let edited = presetsPrompt(current) { commitPresets(edited) }
            return
        }
        let sheet = PresetsSheetController(
            presets: current, accounts: Array(store.state.accounts.values), theme: theme)
        sheet.present(over: window) { [weak self] edited in
            guard let self, let edited else { return }
            self.commitPresets(edited)
            self.focusTerminalIfSessionShown()
        }
    }

    private func commitPresets(_ presets: [Preset]) {
        store.update { $0.presets = presets }
    }

    // MARK: - Periodic snapshots

    /// Ticks the status strip so the `resets` countdown stays true without any service reporting.
    private func startStatusTickTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.statusTickInterval,
            repeating: Self.statusTickInterval,
            leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.sampleSessionMemory()
                self?.updateStatusBar()
            }
        }
        statusTickTimer = timer
        timer.resume()
    }

    /// Reads each session's process-subtree footprint and pushes it into the store.
    ///
    /// Rides the once-a-minute status tick rather than a timer of its own: a sample costs one
    /// `proc_pid_rusage` per process in each session's tree, which is cheap but not free, and the
    /// number only matters at GB resolution.
    ///
    /// Only *bucket* changes are written. A steady session would otherwise produce a new value
    /// every minute, and every write is a `ChangeSet.sessions` entry that reloads that row — the
    /// one thing the sidebar's design exists to avoid (design.md → *Store*).
    func sampleSessionMemory() {
        guard let host = host as? TerminalViewHost else { return }
        var updates: [(SessionID, UInt64)] = []
        for (id, sample) in host.sessionMemory() {
            let previous = store.state.sessions[id]?.live?.subtreeFootprintBytes
            guard Self.memoryBucket(sample.footprintBytes) != Self.memoryBucket(previous) else {
                continue
            }
            updates.append((id, sample.footprintBytes))
        }
        guard !updates.isEmpty else { return }
        store.update { state in
            for (id, bytes) in updates {
                state.updateLive(id) { $0.subtreeFootprintBytes = bytes }
            }
        }
    }

    /// Quantises a footprint so small drifts do not redraw a row: 256 MB steps below the badge
    /// threshold, and every 0.1 GB above it, where the number is actually on screen.
    static func memoryBucket(_ bytes: UInt64?) -> Int? {
        guard let bytes else { return nil }
        if bytes < SidebarRowAdapter.memoryBadgeThreshold {
            return Int(bytes / (256 * 1024 * 1024))
        }
        return 1_000_000 + Int(bytes / (100 * 1024 * 1024))
    }

    /// Every `snapshotInterval`, write the `.ghsnap` of every session that changed. Sessions the
    /// idle compressor already saved are skipped inside `snapshotAll` (their activity token has
    /// not moved), so a quiet sidebar costs nothing here.
    private func startSnapshotTimer() {
        guard let viewHost = host as? TerminalViewHost else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.snapshotInterval, repeating: Self.snapshotInterval,
                       leeway: .seconds(10))
        timer.setEventHandler { [weak viewHost, logger] in
            MainActor.assumeIsolated {
                guard let viewHost else { return }
                let sweep = viewHost.snapshotAll()
                logger.info("periodic snapshot: saved=\(sweep.saved.count) skipped=\(sweep.skipped.count) failed=\(sweep.failed.count) bytes=\(sweep.totalBytes)")
            }
        }
        snapshotTimer = timer
        timer.resume()
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

    private func handle(_ event: TerminalEvent, for id: TerminalID) {
        switch event {
        case .exited:
            // The shell ended (`exit`, Ctrl-D, a hang-up): the *pane* goes with it, and the row
            // only when it was the row's last pane. There is no "exited" row (2026-09-08). The
            // worktree may have gone too, so the list is re-read before the row is removed —
            // `closeTerminal` does both, in that order.
            launcher.closeTerminal(id)
        case .pwd(let raw):
            // OSC 7 from the ZDOTDIR wrapper on every `cd`. The pane's directory is what a split
            // starts in; the *row's* also follows it, but only from the focused pane — otherwise a
            // `cd` in a background pane would rename the sidebar row (2026-09-08).
            if let path = SessionEventHandler.decodePwd(raw) {
                store.update { state in
                    state.setPaneCwd(id, path: path)
                    if let session = state.session(owning: id), session.focusedTerminalID == id {
                        state.setShellCwd(session.id, path: path)
                    }
                }
            }
        default:
            // `.title` deliberately does not land in the store: `Session.title` is the rename slot
            // (design.md → Session flows) and a shell-set title is not a rename.
            break
        }
    }

    // MARK: Menu handlers

    /// Everything the main menu can dispatch. Actions with no implementation yet are deliberately
    /// **absent**: `MenuDispatcher.validateMenuItem` then disables their menu items, so the menu
    /// shows the whole vocabulary and lies about none of it.
    private func registerMenuHandlers() {
        dispatcher.setHandler(.newSession) { [weak self] in self?.presentNewSessionMenu() }
        dispatcher.setHandler(.closeTerminal) { [weak self] in self?.removeSelectedSession() }
        dispatcher.setHandler(.searchSessions) { [weak self] in self?.beginSearch() }
        dispatcher.setHandler(.commandPalette) { [weak self] in self?.presentPalette(mode: .all) }
        dispatcher.setHandler(.toggleSidebar) { [weak self] in self?.toggleSidebar() }
        dispatcher.setHandler(.jumpToNeedsYou) { [weak self] in
            _ = self?.sidebar.selectFirstSessionNeedingAttention()
        }
        dispatcher.setHandler(.renameSession) { [weak self] in self?.renameSelectedSession() }
        dispatcher.setHandler(.copyLastMessage) { [weak self] in self?.copyLastMessage() }
        dispatcher.setHandler(.removeShellIntegration) { [weak self] in self?.removeShellIntegration() }
        dispatcher.setHandler(.statusLineIntegration) { [weak self] in self?.statusLineIntegration() }
        // M5.2
        dispatcher.setHandler(.resumeSession) { [weak self] in self?.resumeSelectedSession() }
        dispatcher.setHandler(.resumeAllInGroup) { [weak self] in self?.resumeAll() }
        dispatcher.setHandler(.managePresets) { [weak self] in self?.presentPresetsSheet() }
        dispatcher.setHandler(.toggleAutoResume) { [weak self] in self?.toggleAutoResume() }
        dispatcher.setCheckmark(.toggleAutoResume) { [weak self] in self?.store.state.autoResumeOnLaunch ?? false }
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
        MainMenu.install(buildMainMenu(appName: appName))
    }

    /// The menu for the bindings in force right now. `installMainMenu` installs it; the cheat sheet
    /// reads its rows straight off it, which is why an edited `AppState.shortcuts` reaches the
    /// sheet without a relaunch even though the installed menu bar is only built at launch.
    func buildMainMenu(appName: String = "tkzmux") -> NSMenu {
        MainMenu.build(
            appName: appName,
            shortcuts: ShortcutsTable.resolved(state: store.state),
            dispatcher: dispatcher)
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
