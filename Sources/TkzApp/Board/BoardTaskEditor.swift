// BoardTaskEditor — the popover a card is written in: title, notes, group, agent.
//
// One form for *add* and *edit*. It writes nothing: Save hands a `Draft` to `onSave` and the
// controller runs the reducers. The agent list follows the group — a card that says "tkzmux" can
// only be given to a row in tkzmux — and "Any agent in the group" is the unassigned choice, which
// is what lets the group's agents pick the card up on their own.

import AppKit
import TkzCore

@MainActor
final class BoardTaskEditor: NSViewController, NSTextFieldDelegate {
    struct Draft: Hashable {
        var title: String
        var notes: String
        var groupID: GroupID?
        var assignee: SessionID?
    }

    /// What the two pop-ups offer, snapshotted when the editor opens.
    struct Choices {
        var groups: [Group]
        var sessions: [Session]

        init(state: AppState) {
            groups = state.orderedGroups
            sessions = state.orderedSessions
        }

        func sessions(in group: GroupID?) -> [Session] {
            group.map { id in sessions.filter { $0.groupID == id } } ?? sessions
        }

        func groupName(of session: Session) -> String {
            groups.first { $0.id == session.groupID }?.name ?? ""
        }
    }

    var onSave: ((Draft) -> Void)?
    var onCancel: (() -> Void)?

    private let heading: String
    private var draft: Draft
    private let choices: Choices

    private let titleField = NSTextField()
    private let notesView = NSTextView()
    private let groupPopup = NSPopUpButton()
    private let agentPopup = NSPopUpButton()
    private var saveButton: NSButton!

    init(heading: String, draft: Draft, choices: Choices) {
        self.heading = heading
        self.draft = draft
        self.choices = choices
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    /// One content width, so every row — fields, pop-ups, buttons — shares the same two edges.
    private enum Metrics {
        static let width: CGFloat = 400
        static let margin: CGFloat = 18
        static let content: CGFloat = width - 2 * margin
        static let captionWidth: CGFloat = 40
        static let notesHeight: CGFloat = 128
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 360))

        let headingLabel = NSTextField(labelWithString: heading)
        headingLabel.font = Theme.Fonts.ui(13, weight: .semibold)

        titleField.placeholderString = "What needs doing?"
        titleField.stringValue = draft.title
        titleField.font = Theme.Fonts.ui(13)
        titleField.delegate = self
        titleField.setAccessibilityLabel("Task title")

        // The text view gets a real frame and a width-tracking container up front: with a zero
        // frame and only an autoresizing mask it has no width to wrap to until its first resize.
        notesView.frame = NSRect(x: 0, y: 0, width: Metrics.content, height: Metrics.notesHeight)
        notesView.minSize = NSSize(width: 0, height: Metrics.notesHeight)
        notesView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        notesView.isVerticallyResizable = true
        notesView.isHorizontallyResizable = false
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.widthTracksTextView = true
        notesView.textContainer?.containerSize = NSSize(
            width: Metrics.content, height: CGFloat.greatestFiniteMagnitude)
        notesView.textContainerInset = NSSize(width: 6, height: 7)
        notesView.string = draft.notes
        notesView.font = Theme.Fonts.ui(12.5)
        notesView.textColor = .labelColor
        notesView.drawsBackground = false
        notesView.isRichText = false
        notesView.allowsUndo = true
        notesView.isAutomaticQuoteSubstitutionEnabled = false
        notesView.isAutomaticDashSubstitutionEnabled = false
        notesView.setAccessibilityLabel("Task notes")

        let notesScroll = NSScrollView()
        notesScroll.documentView = notesView
        notesScroll.hasVerticalScroller = true
        notesScroll.autohidesScrollers = true
        notesScroll.scrollerStyle = .overlay
        notesScroll.borderType = .noBorder
        notesScroll.drawsBackground = false
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        // The rounded, lightly filled box the title field has, instead of a black bezel.
        let notesBox = EditorFieldBox()
        notesBox.addSubview(notesScroll)
        NSLayoutConstraint.activate([
            notesScroll.topAnchor.constraint(equalTo: notesBox.topAnchor, constant: 1),
            notesScroll.bottomAnchor.constraint(equalTo: notesBox.bottomAnchor, constant: -1),
            notesScroll.leadingAnchor.constraint(equalTo: notesBox.leadingAnchor, constant: 1),
            notesScroll.trailingAnchor.constraint(equalTo: notesBox.trailingAnchor, constant: -1),
            notesBox.heightAnchor.constraint(equalToConstant: Metrics.notesHeight),
        ])

        let hint = NSTextField(
            wrappingLabelWithString: "The title and notes are the prompt the agent is given.")
        hint.font = Theme.Fonts.ui(10.5)
        hint.textColor = .tertiaryLabelColor

        groupPopup.target = self
        groupPopup.action = #selector(groupChanged)
        groupPopup.setAccessibilityLabel("Group")
        agentPopup.setAccessibilityLabel("Agent")
        rebuildGroupPopup()
        rebuildAgentPopup()
        let groupRow = Self.row("Group", groupPopup)
        let agentRow = Self.row("Agent", agentPopup)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1B}"
        saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.toolTip = "Save (\u{2318}\u{21A9})"
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        saveButton.widthAnchor.constraint(equalTo: cancel.widthAnchor).isActive = true

        let rows: [NSView] = [headingLabel, titleField, notesBox, hint, groupRow, agentRow, buttons]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(12, after: headingLabel)
        stack.setCustomSpacing(6, after: notesBox)
        stack.setCustomSpacing(14, after: hint)
        stack.setCustomSpacing(8, after: groupRow)
        stack.setCustomSpacing(18, after: agentRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.margin),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.margin),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.margin),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Metrics.margin),
            root.widthAnchor.constraint(equalToConstant: Metrics.width),
        ])
        // Every row spans the content width. The first version left the pop-up grid out of this
        // loop, so it sized itself: its captions hung out of the left margin and the agent pop-up
        // ran off the right edge.
        for view in rows {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = root
        syncSaveEnabled()
    }

    /// `caption  [ pop-up, filling the rest ]` — a fixed caption column, so the two pop-ups share
    /// a left edge and a width however long their titles are.
    private static func row(_ text: String, _ popup: NSPopUpButton) -> NSView {
        let label = caption(text)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (popup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        let row = NSView()
        row.addSubview(label)
        row.addSubview(popup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: Metrics.captionWidth),
            label.firstBaselineAnchor.constraint(equalTo: popup.firstBaselineAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            popup.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            popup.topAnchor.constraint(equalTo: row.topAnchor),
            popup.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.Fonts.ui(11.5)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: Pop-ups

    private func rebuildGroupPopup() {
        groupPopup.removeAllItems()
        // Through the menu, not `addItem(withTitle:)`: that one removes an existing item with the
        // same title, and two groups — or two rows — may well share a name.
        groupPopup.menu?.addItem(Self.choice("No group", id: nil))
        for group in choices.groups {
            groupPopup.menu?.addItem(Self.choice(group.name, id: group.id.rawValue))
        }
        let index = draft.groupID.flatMap { id in choices.groups.firstIndex { $0.id == id } }
        groupPopup.selectItem(at: index.map { $0 + 1 } ?? 0)
    }

    private func rebuildAgentPopup() {
        agentPopup.removeAllItems()
        agentPopup.menu?.addItem(
            Self.choice(draft.groupID == nil ? "Nobody yet" : "Any agent in the group", id: nil))
        let sessions = choices.sessions(in: draft.groupID)
        for session in sessions {
            let title = draft.groupID == nil
                ? "\(session.displayTitle) \u{2014} \(choices.groupName(of: session))"
                : session.displayTitle
            agentPopup.menu?.addItem(Self.choice(title, id: session.id.rawValue))
        }
        let index = draft.assignee.flatMap { id in sessions.firstIndex { $0.id == id } }
        agentPopup.selectItem(at: index.map { $0 + 1 } ?? 0)
    }

    private static func choice(_ title: String, id: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = id
        return item
    }

    @objc private func groupChanged() {
        draft.groupID = (groupPopup.selectedItem?.representedObject as? String).flatMap(GroupID.init)
        // The agent survives only if it is in the new group.
        draft.assignee = selectedAssignee.flatMap { id in
            choices.sessions(in: draft.groupID).contains { $0.id == id } ? id : nil
        }
        rebuildAgentPopup()
    }

    private var selectedAssignee: SessionID? {
        (agentPopup.selectedItem?.representedObject as? String).flatMap(SessionID.init)
    }

    // MARK: Save

    func controlTextDidChange(_ obj: Notification) { syncSaveEnabled() }

    private func syncSaveEnabled() {
        saveButton?.isEnabled = !titleField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ↵ in the title field saves, like the button's ⌘↵.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        save()
        return true
    }

    /// The form as it stands — what Save hands over.
    var currentDraft: Draft {
        Draft(
            title: titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notesView.string.trimmingCharacters(in: .whitespacesAndNewlines),
            groupID: draft.groupID,
            assignee: selectedAssignee)
    }

    @objc private func save() {
        let result = currentDraft
        guard !result.title.isEmpty else { return }
        onSave?(result)
    }

    @objc private func cancel() { onCancel?() }
}

/// The notes field's frame: a rounded, lightly filled box with a hairline border, to sit beside
/// the title field instead of `NSScrollView`'s black bezel. The colours are dynamic, so they are
/// resolved in `updateLayer`, which AppKit calls under the view's own appearance — the popover's,
/// which follows the theme rather than the system.
private final class EditorFieldBox: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }
}
