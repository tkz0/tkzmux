// DeleteWorktreeSheetController — the row menu's "Delete worktree…" sheet (TKZ-70).
//
// The rebase sheet's shape, on the shared chrome in `Sheets/GlassSheet.swift`: a floating
// `PromptCardPanel` over an `NSVisualEffectView`, key while it is up, gone on Escape, on Cancel,
// on the panel resigning key, or when the delete finishes.
//
// It owns the **survey** the way the rebase sheet owns its fetch: opening it runs
// `WorktreeRemoval.survey` off the main actor — is the branch merged, how far ahead is it, is the
// tree dirty — so what the sheet says is what git says now, not what the last status refresh
// happened to leave in the store. Unlike the rebase sheet it never fetches: three local reads, no
// network on a destructive path.
//
// The *delete* it hands to `MainWindowController`, which owns the ordering (close the row first,
// then run git out of band) and `GitIntegration`, which owns the one-per-worktree rule and the
// notices. This controller only shows "Deleting…" and goes away when told.

import AppKit
import GitStatus
import TkzCore

@MainActor
public final class DeleteWorktreeSheetController: NSObject, NSWindowDelegate {

    /// What the sheet does off the main actor when it opens. Injected so a test needs no repo.
    typealias Prepare = @Sendable (WorktreeRemoval.Request, PRInfo?) -> Result<
        WorktreeRemoval.Survey, WorktreeRemoval.SurveyFailure
    >

    /// A Delete button was pressed for this row. `BranchDelete` is `.safe` or `.keep` from the
    /// primary button (whichever its title promised) and `.force` from the red one.
    public var onDelete: ((SessionID, WorktreeRemoval.BranchDelete) -> Void)?
    public var onDismiss: (() -> Void)?

    public var theme: Theme {
        didSet { if theme != oldValue { applyTheme() } }
    }

    public private(set) var sessionID: SessionID?
    private(set) var model: DeleteWorktreeSheetModel?
    /// Between `present` and `dismiss`. A flag rather than `panel.isVisible`, so a test that keeps
    /// the panel off screen (see `orderFront`) still sees the sheet as shown.
    public private(set) var isShown = false

    /// How the panel comes to the front. Tests replace it — see the note in
    /// `RebaseSheetController`: a panel ordered front for real in the test process asks AppKit for
    /// events, and that ends the run.
    var orderFront: (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }

    private var panel: PromptCardPanel?
    private var effectView: NSVisualEffectView?
    private var sheetView: DeleteWorktreeSheetView?
    private var anchorFrame: NSRect?
    /// Bumped on every present/dismiss so a survey that lands after the sheet moved on is dropped.
    private var generation: UInt64 = 0
    private let prepare: Prepare
    /// Its own queue until `useGitQueue` hands it `GitIntegration.rebaseQueue`, so a survey started
    /// before the coordinator exists (a test harness) still has somewhere to run.
    private var queue = DispatchQueue(
        label: "se.tkz.tkzmux.DeleteWorktreeSheet.survey", qos: .userInitiated)

    public init(theme: Theme = .default) {
        self.theme = theme
        self.prepare = { request, pr in WorktreeRemoval.survey(request, pr: pr) }
        super.init()
    }

    init(theme: Theme, prepare: @escaping Prepare) {
        self.theme = theme
        self.prepare = prepare
        super.init()
    }

    /// Serializes the survey behind every git call `GitIntegration` makes. `git status` in a
    /// worktree a rebase is mid-write in would otherwise race it on the repository lock — and the
    /// answer would be a lie besides. Named for what it is: unlike the rebase sheet's
    /// `useFetchQueue`, nothing here fetches.
    func useGitQueue(_ queue: DispatchQueue) {
        self.queue = queue
    }

    // MARK: Presentation

    /// Shows the sheet for `id` and starts the survey. `request == nil` (no repo known yet) shows
    /// the model as given and never surveys.
    func present(
        for id: SessionID, request: WorktreeRemoval.Request?, pr: PRInfo?,
        model: DeleteWorktreeSheetModel, over anchor: NSRect?
    ) {
        generation &+= 1
        sessionID = id
        anchorFrame = anchor
        self.model = model
        let panel = makePanelIfNeeded()
        sheetView?.setModel(model)
        place(panel)
        isShown = true
        orderFront(panel)
        guard let request, model.phase == .checking else { return }
        startSurvey(request, pr: pr, generation: generation, id: id)
    }

    /// Escape, Cancel, a click outside, a selection change, the delete's end.
    public func dismiss() {
        guard let panel, isShown || sessionID != nil else { return }
        generation &+= 1
        sessionID = nil
        model = nil
        isShown = false
        panel.orderOut(nil)
        onDismiss?()
    }

    /// The row's agent status moved; the buttons follow.
    public func setClaudeWorking(_ working: Bool) {
        guard var model, model.agentWorking != working else { return }
        model.agentWorking = working
        update(model)
    }

    /// The checkbox. The model is the only place the answer lives.
    func setDirtyAcknowledged(_ acknowledged: Bool) {
        guard var model, model.acknowledgedDirty != acknowledged else { return }
        model.acknowledgedDirty = acknowledged
        update(model)
    }

    /// A Delete was accepted: both buttons off, so a second Return while the close confirmation is
    /// up cannot fire another one.
    public func deleteStarted(for id: SessionID) {
        guard sessionID == id, var model else { return }
        model.phase = .deleting
        update(model)
    }

    /// The removal is over, however it went: the outcome is in the status strip, the sheet goes.
    public func deleteFinished(for id: SessionID) {
        guard sessionID == id else { return }
        dismiss()
    }

    private func update(_ model: DeleteWorktreeSheetModel) {
        self.model = model
        sheetView?.setModel(model)
        if let panel, isShown { place(panel) }
    }

    // MARK: Survey

    private func startSurvey(
        _ request: WorktreeRemoval.Request, pr: PRInfo?, generation: UInt64, id: SessionID
    ) {
        let prepare = self.prepare
        let box = WeakBox()
        box.value = self
        queue.async {
            let result = prepare(request, pr)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.value?.finishSurvey(result, generation: generation, id: id)
                }
            }
        }
    }

    private func finishSurvey(
        _ result: Result<WorktreeRemoval.Survey, WorktreeRemoval.SurveyFailure>,
        generation: UInt64, id: SessionID
    ) {
        guard generation == self.generation, var model else { return }
        switch result {
        case .success(let survey):
            model.merge = survey.merge
            model.isDirty = survey.isDirty
            model.dirtyFileCount = survey.dirtyFileCount
            if let head = survey.headBranch { model.branch = head }
            model.phase = .ready
        case .failure(let failure):
            model.phase = .checkFailed(failure.message)
        }
        update(model)
    }

    @MainActor private final class WeakBox {
        weak var value: DeleteWorktreeSheetController?
    }

    // MARK: Panel

    private func makePanelIfNeeded() -> PromptCardPanel {
        if let panel { return panel }

        let (panel, effect) = GlassSheetPanel.make(
            width: DeleteWorktreeSheetView.Metrics.width, delegate: self,
            onCancel: { [weak self] in self?.dismiss() })
        effectView = effect

        let sheet = DeleteWorktreeSheetView(theme: theme)
        sheet.onCancel = { [weak self] in self?.dismiss() }
        // Both buttons re-check `canDelete` here rather than trusting the view's `isEnabled`: the
        // same guard `RebaseSheetController` keeps, for the same reason.
        sheet.onDelete = { [weak self] in
            guard let self, let id = self.sessionID, let model = self.model, model.canDelete else {
                return
            }
            self.onDelete?(id, model.primaryDeletesBranch ? .safe : .keep)
        }
        sheet.onDeleteBranch = { [weak self] in
            guard let self, let id = self.sessionID, let model = self.model, model.canDelete,
                model.showsDeleteBranchButton
            else { return }
            self.onDelete?(id, .force)
        }
        sheet.onToggleDirty = { [weak self] on in self?.setDirtyAcknowledged(on) }
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

    /// Sizes the panel to its content and puts it where the family goes. The height is measured
    /// each time because the dirty line and its checkbox collapse when they are hidden.
    private func place(_ panel: NSPanel) {
        guard let sheetView else { return }
        sheetView.layoutSubtreeIfNeeded()
        let size = NSSize(
            width: DeleteWorktreeSheetView.Metrics.width, height: sheetView.fittingSize.height)
        panel.setFrame(GlassSheetPanel.frame(for: size, over: anchorFrame), display: true)
    }

    // MARK: NSWindowDelegate

    /// A click back into the main window, ⌘-Tab, Spotlight: the sheet is done. Not while the
    /// delete runs — it closes itself when the removal ends.
    public func windowDidResignKey(_ notification: Notification) {
        guard dismissesWhenResigningKey, model?.phase != .deleting else { return }
        dismiss()
    }

    // MARK: Test access

    /// Off in the tests that await a background survey: the test target runs suites in parallel
    /// and any other panel ordering front mid-await would — correctly — dismiss this one.
    var dismissesWhenResigningKey = true
    var panelForTesting: NSPanel? { panel }
    var sheetViewForTesting: DeleteWorktreeSheetView? { sheetView }
}
