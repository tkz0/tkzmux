// RebaseSheetController.swift — ⌥⌘R / the `⤿ 7 behind main` chip: the rebase sheet (design 5a/5b).
//
// The same shape as `PromptCardController`: a `.nonactivatingPanel` carrying an
// `NSVisualEffectView`, key while it is up, gone on Escape, on the panel resigning key, on
// Cancel, or on the chord again. Placed above the status strip at the right of the detail area,
// where 5a draws it.
//
// The sheet owns the *fetch*: opening it runs `git fetch origin main` (unless the repo was fetched
// a minute ago) and then counts, so "Pulls in 7 commits" is what is on the remote, not what the
// last manual fetch brought in. The *rebase* it hands to `GitIntegration`, which owns the
// one-per-worktree rule and the notices; the sheet only shows "Rebasing…" and closes when told.

import AppKit
import GitStatus
import TkzCore

@MainActor
public final class RebaseSheetController: NSObject, NSWindowDelegate {

    /// What the sheet does off the main actor when it opens: fetch (unless `skipFetch`) and
    /// count. Injected so a test needs no remote.
    typealias Prepare = @Sendable (GitRebase.Request) -> (fetch: GitRebase.Outcome?, behind: Int?)

    /// Rebase pressed for this row. The window controller routes it to `GitIntegration`.
    public var onRebase: ((SessionID) -> Void)?
    /// The sheet's own fetch succeeded: `GitIntegration` notes the time.
    public var onFetched: ((SessionID) -> Void)?
    /// The sheet went away, for whatever reason.
    public var onDismiss: (() -> Void)?

    public var theme: Theme {
        didSet { if theme != oldValue { applyTheme() } }
    }

    public private(set) var sessionID: SessionID?
    private(set) var model: RebaseSheetModel?
    /// Between `present` and `dismiss`. A flag rather than `panel.isVisible`, so a test that keeps
    /// the panel off screen (see `orderFront`) still sees the sheet as shown.
    public private(set) var isShown = false

    /// How the panel comes to the front. Tests replace it: a panel ordered front for real in the
    /// test process asks AppKit for events, and the first such request starts the event-pulling
    /// thread that later stops the main run loop — which Swift's async-main drain answers with
    /// `exit(0)`, ending the run "passed" mid-way. It also throws key and occlusion
    /// notifications at every other window the run has open.
    var orderFront: (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }

    private var panel: PromptCardPanel?
    private var effectView: NSVisualEffectView?
    private var sheetView: RebaseSheetView?
    private var anchorFrame: NSRect?
    /// Bumped on every present/dismiss so a fetch that lands after the sheet moved on is dropped.
    private var generation: UInt64 = 0
    private let prepare: Prepare
    /// Its own queue until `useFetchQueue` hands it `GitIntegration.rebaseQueue`, so a fetch this
    /// sheet starts before the coordinator exists (a test harness) still has somewhere to run.
    private var queue = DispatchQueue(label: "se.tkz.tkzmux.RebaseSheet.fetch", qos: .userInitiated)

    public init(theme: Theme = .default) {
        self.theme = theme
        self.prepare = { request in
            if !request.skipFetch, let failure = GitRebase.fetch(request) { return (failure, nil) }
            return (nil, GitRebase.behindCount(request))
        }
        super.init()
    }

    init(theme: Theme, prepare: @escaping Prepare) {
        self.theme = theme
        self.prepare = prepare
        super.init()
    }

    /// Serializes this sheet's own opening fetch behind every fetch `GitIntegration` makes — a
    /// running rebase's, or the opt-in origin check's — so opening the sheet while one of those is
    /// mid-fetch on the same repo queues behind it rather than launching a second `git fetch` that
    /// can fail on the repository's lock.
    func useFetchQueue(_ queue: DispatchQueue) {
        self.queue = queue
    }

    // MARK: Presentation

    /// The chord: shows the sheet, or hides it when it is up for this row. Another row re-targets.
    func toggle(for id: SessionID, request: GitRebase.Request?, model: RebaseSheetModel, over anchor: NSRect?) {
        if isShown, sessionID == id {
            dismiss()
        } else {
            present(for: id, request: request, model: model, over: anchor)
        }
    }

    /// Shows the sheet for `id` and starts the fetch. `request == nil` (base not resolved yet)
    /// shows the model as given and never fetches.
    func present(for id: SessionID, request: GitRebase.Request?, model: RebaseSheetModel, over anchor: NSRect?) {
        generation &+= 1
        sessionID = id
        anchorFrame = anchor
        self.model = model
        let panel = makePanelIfNeeded()
        sheetView?.setModel(model)
        place(panel)
        isShown = true
        orderFront(panel)
        guard let request, model.phase == .fetching else { return }
        startFetch(request, generation: generation, id: id)
    }

    /// Escape, Cancel, a click outside, the chord again, a selection change, the rebase's end.
    public func dismiss() {
        guard let panel, isShown || sessionID != nil else { return }
        generation &+= 1
        sessionID = nil
        model = nil
        isShown = false
        panel.orderOut(nil)
        onDismiss?()
    }

    /// The row's Claude status moved; the button follows.
    public func setClaudeWorking(_ working: Bool) {
        guard var model, model.agentWorking != working else { return }
        model.agentWorking = working
        update(model)
    }

    /// `GitIntegration` accepted the rebase.
    public func rebaseStarted(for id: SessionID) {
        guard sessionID == id, var model else { return }
        model.phase = .rebasing
        update(model)
    }

    /// `GitIntegration` is done with it: the outcome is in the status strip, the sheet goes away.
    public func rebaseFinished(for id: SessionID) {
        guard sessionID == id else { return }
        dismiss()
    }

    private func update(_ model: RebaseSheetModel) {
        self.model = model
        sheetView?.setModel(model)
        if let panel, isShown { place(panel) }
    }

    // MARK: Fetch

    private func startFetch(_ request: GitRebase.Request, generation: UInt64, id: SessionID) {
        let prepare = self.prepare
        let box = WeakBox()
        box.value = self
        queue.async {
            let result = prepare(request)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.value?.finishFetch(result, generation: generation, id: id, skipped: request.skipFetch)
                }
            }
        }
    }

    private func finishFetch(
        _ result: (fetch: GitRebase.Outcome?, behind: Int?), generation: UInt64, id: SessionID,
        skipped: Bool
    ) {
        guard generation == self.generation, var model else { return }
        switch result.fetch {
        case .fetchFailed(let message)?:
            model.phase = .fetchFailed(message)
        case .timedOut?:
            model.phase = .fetchFailed("timed out")
        case .some(let other):
            model.phase = .fetchFailed(String(describing: other))
        case nil:
            if !skipped { onFetched?(id) }
            model.behind = result.behind
            model.phase = .ready
        }
        update(model)
    }

    @MainActor private final class WeakBox {
        weak var value: RebaseSheetController?
    }

    // MARK: Panel

    private func makePanelIfNeeded() -> PromptCardPanel {
        if let panel { return panel }

        // The panel, the material, the radius and the border are the whole family's — see
        // `Sheets/GlassSheet.swift`. Only the contents below are this sheet's.
        let (panel, effect) = GlassSheetPanel.make(
            width: RebaseSheetView.Metrics.width, delegate: self,
            onCancel: { [weak self] in self?.dismiss() })
        effectView = effect

        let sheet = RebaseSheetView(theme: theme)
        sheet.onCancel = { [weak self] in self?.dismiss() }
        sheet.onRebase = { [weak self] in
            guard let self, let id = self.sessionID, self.model?.canRebase == true else { return }
            self.onRebase?(id)
        }
        sheetView = sheet

        effect.addSubview(sheet)
        NSLayoutConstraint.activate([
            sheet.topAnchor.constraint(equalTo: effect.topAnchor),
            sheet.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        self.panel = panel
        applyTheme()
        return panel
    }

    private func applyTheme() {
        if let effectView { GlassSheetPanel.applyTheme(theme, to: effectView) }
        sheetView?.setTheme(theme)
    }

    /// Sizes the panel to its content and puts it at the bottom right of the anchor (the detail
    /// area, in screen coordinates), 14 pt in from the right and 14 pt up from the strip — 5a's
    /// placement — or, with no anchor, near the bottom right of the main screen.
    private func place(_ panel: NSPanel) {
        guard let sheetView else { return }
        sheetView.layoutSubtreeIfNeeded()
        let size = NSSize(width: RebaseSheetView.Metrics.width, height: sheetView.fittingSize.height)
        panel.setFrame(Self.frame(for: size, over: anchorFrame), display: true)
    }

    /// Kept as a forwarder: the placement is the family's (`GlassSheetPanel.frame`), and this
    /// sheet's tests name it here.
    static func frame(for size: NSSize, over anchor: NSRect?) -> NSRect {
        GlassSheetPanel.frame(for: size, over: anchor)
    }

    // MARK: NSWindowDelegate

    /// A click back into the main window, ⌘-Tab, Spotlight: the sheet is done. Not while a
    /// rebase runs — the sheet is the only "in progress" signal besides the chip, and it closes
    /// itself when the rebase ends.
    public func windowDidResignKey(_ notification: Notification) {
        guard dismissesWhenResigningKey, model?.phase != .rebasing else { return }
        dismiss()
    }

    // MARK: Test access

    /// Off in the tests that await a background fetch: the test target runs suites in parallel
    /// and any other panel ordering front mid-await would — correctly — dismiss this one.
    var dismissesWhenResigningKey = true
    var panelForTesting: NSPanel? { panel }
    var sheetViewForTesting: RebaseSheetView? { sheetView }
}
