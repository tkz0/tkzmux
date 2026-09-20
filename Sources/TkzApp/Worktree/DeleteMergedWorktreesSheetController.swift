// DeleteMergedWorktreesSheetController — Group › "Delete merged worktrees…" (TKZ-70).
//
// The per-row sheet's bulk twin, on the same chrome. It surveys every candidate in **one** pass
// on the git queue (a serial loop inside a single `async`, the shape `GitIntegration.checkOrigin`
// uses) and then shows the merged ones, pre-checked.
//
// It is a panel and not an `NSAlert` + `accessoryView` for one decisive reason: `NSAlert` is
// modal, and it would block the run loop while that survey is in flight. The per-row sheet is
// deliberately not modal either.

import AppKit
import GitStatus
import TkzCore

@MainActor
public final class DeleteMergedWorktreesSheetController: NSObject, NSWindowDelegate {

    /// One candidate to survey: what to ask git about, plus what the row would say.
    struct Candidate: Sendable {
        var id: SessionID
        var title: String
        var request: WorktreeRemoval.Request
        var pr: PRInfo?
        var agentWorking: Bool
        var agentName: String
    }

    typealias Prepare = @Sendable (WorktreeRemoval.Request, PRInfo?) -> Result<
        WorktreeRemoval.Survey, WorktreeRemoval.SurveyFailure
    >

    /// Delete pressed: the requests for every checked row, already built. The window controller
    /// closes those rows and hands the array to `GitIntegration.deleteWorktrees`.
    public var onDelete: (([SessionID]) -> Void)?
    public var onDismiss: (() -> Void)?

    public var theme: Theme {
        didSet { if theme != oldValue { applyTheme() } }
    }

    public private(set) var groupID: GroupID?
    private(set) var model: DeleteMergedWorktreesSheetModel?
    public private(set) var isShown = false
    /// The request behind each listed row, captured at survey time — so the delete does not have
    /// to go back to the store for it.
    private(set) var requests: [SessionID: WorktreeRemoval.Request] = [:]

    var orderFront: (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }

    private var panel: PromptCardPanel?
    private var effectView: NSVisualEffectView?
    private var sheetView: DeleteMergedWorktreesSheetView?
    private var anchorFrame: NSRect?
    private var generation: UInt64 = 0
    private let prepare: Prepare
    private var queue = DispatchQueue(
        label: "se.tkz.tkzmux.DeleteMergedWorktreesSheet.survey", qos: .userInitiated)

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

    func useGitQueue(_ queue: DispatchQueue) { self.queue = queue }

    // MARK: Presentation

    func present(
        for group: GroupID, groupName: String, candidates: [Candidate], over anchor: NSRect?
    ) {
        generation &+= 1
        groupID = group
        anchorFrame = anchor
        requests = [:]
        let model = DeleteMergedWorktreesSheetModel(groupName: groupName)
        self.model = model
        let panel = makePanelIfNeeded()
        sheetView?.setModel(model)
        place(panel)
        isShown = true
        orderFront(panel)
        startSurvey(candidates, generation: generation)
    }

    public func dismiss() {
        guard let panel, isShown || groupID != nil else { return }
        generation &+= 1
        groupID = nil
        model = nil
        requests = [:]
        isShown = false
        panel.orderOut(nil)
        onDismiss?()
    }

    /// The batch was accepted: the list and the button go inert until the sheet closes.
    public func deleteStarted() {
        guard var model else { return }
        model.phase = .deleting
        update(model)
    }

    func setChecked(_ id: SessionID, _ checked: Bool) {
        guard var model, let index = model.rows.firstIndex(where: { $0.id == id }),
            model.rows[index].isEnabled
        else { return }
        model.rows[index].isChecked = checked
        update(model)
    }

    private func update(_ model: DeleteMergedWorktreesSheetModel) {
        self.model = model
        sheetView?.setModel(model)
        if let panel, isShown { place(panel) }
    }

    // MARK: Survey

    /// One `async`, a serial loop, one hop back — N candidates cost one trip to the main actor.
    private func startSurvey(_ candidates: [Candidate], generation: UInt64) {
        let prepare = self.prepare
        let box = WeakBox()
        box.value = self
        queue.async {
            let surveyed: [(Candidate, WorktreeRemoval.Survey?)] = candidates.map { candidate in
                (candidate, try? prepare(candidate.request, candidate.pr).get())
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.value?.finishSurvey(surveyed, generation: generation)
                }
            }
        }
    }

    private func finishSurvey(
        _ surveyed: [(Candidate, WorktreeRemoval.Survey?)], generation: UInt64
    ) {
        guard generation == self.generation, var model else { return }
        var rows: [DeleteMergedWorktreesSheetModel.Row] = []
        for (candidate, survey) in surveyed {
            // No survey, or not merged: not this sheet's business. The row menu is where an
            // unmerged worktree gets deleted, behind the red button.
            guard let survey,
                let status = DeleteMergedWorktreesSheetModel.statusLine(
                    for: survey.merge, isDirty: survey.isDirty)
            else { continue }

            var request = candidate.request
            request.branch = survey.headBranch ?? request.branch
            request.expectedBranch = request.branch
            // Merged, so a plain `-d` is expected to succeed; and this sheet never forces.
            request.branchDelete = request.branch == nil ? .keep : .safe
            request.force = false
            requests[candidate.id] = request

            let reason: String? =
                candidate.agentWorking
                ? "\(candidate.agentName) is working" : (survey.isDirty ? "Uncommitted changes \u{2014} delete this one from its row menu" : nil)
            let enabled = !candidate.agentWorking && !survey.isDirty
            rows.append(.init(
                id: candidate.id,
                title: candidate.title,
                worktreeName: request.worktreeName,
                branch: request.branch,
                statusLine: status,
                isChecked: enabled,
                isEnabled: enabled,
                disabledReason: reason))
        }
        model.rows = rows
        model.phase = .ready
        update(model)
    }

    @MainActor private final class WeakBox {
        weak var value: DeleteMergedWorktreesSheetController?
    }

    /// The requests for the rows the user left checked, in list order.
    func checkedRequests() -> [WorktreeRemoval.Request] {
        guard let model else { return [] }
        return model.rows.filter { $0.isChecked && $0.isEnabled }.compactMap { requests[$0.id] }
    }

    func checkedIDs() -> [SessionID] {
        model?.rows.filter { $0.isChecked && $0.isEnabled }.map(\.id) ?? []
    }

    // MARK: Panel

    private func makePanelIfNeeded() -> PromptCardPanel {
        if let panel { return panel }

        let (panel, effect) = GlassSheetPanel.make(
            width: DeleteMergedWorktreesSheetView.Metrics.width, delegate: self,
            onCancel: { [weak self] in self?.dismiss() })
        effectView = effect

        let sheet = DeleteMergedWorktreesSheetView(theme: theme)
        sheet.onCancel = { [weak self] in self?.dismiss() }
        sheet.onToggleRow = { [weak self] id, on in self?.setChecked(id, on) }
        sheet.onDelete = { [weak self] in
            guard let self, self.model?.canDelete == true else { return }
            self.onDelete?(self.checkedIDs())
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

    private func place(_ panel: NSPanel) {
        guard let sheetView else { return }
        sheetView.layoutSubtreeIfNeeded()
        let size = NSSize(
            width: DeleteMergedWorktreesSheetView.Metrics.width,
            height: sheetView.fittingSize.height)
        panel.setFrame(GlassSheetPanel.frame(for: size, over: anchorFrame), display: true)
    }

    // MARK: NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        guard dismissesWhenResigningKey, model?.phase != .deleting else { return }
        dismiss()
    }

    // MARK: Test access

    var dismissesWhenResigningKey = true
    var panelForTesting: NSPanel? { panel }
    var sheetViewForTesting: DeleteMergedWorktreesSheetView? { sheetView }
}
