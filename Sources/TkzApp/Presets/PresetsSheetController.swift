// PresetsSheetController — "Manage presets…" (M5.2 / TKZ-30).
//
// design.md → *Session flows*: a preset is `{name, command, cwdMode, accountKey?, env}`; the
// new-session menu lists them under "From preset… (n saved)". This is the CRUD behind that list:
// a sheet with the presets down the left, a form on the right, ＋/－ underneath, Done/Cancel.
//
// The sheet edits a **copy** and hands the whole list back on Done, so the store sees one mutation
// (one `state.json` write) and Cancel costs nothing. Everything that can be wrong about a preset —
// an empty name, a `KEY=VALUE` line without an `=`, a fixed-path mode with no path — is decided by
// `PresetDraft`, a value type with no AppKit in it, which is what the tests exercise.

import AppKit
import TkzCore

// MARK: - Draft

/// One preset as the form sees it: strings and an index, not a `CwdMode` with payloads.
public struct PresetDraft: Hashable, Sendable {
    public enum Start: Int, CaseIterable, Sendable {
        case repoRoot = 0
        case worktree = 1
        case fixedPath = 2

        public var title: String {
            switch self {
            case .repoRoot: "Repo root"
            case .worktree: "New worktree (claude -w)"
            case .fixedPath: "Fixed path"
            }
        }

        /// What the field beside the popup means, or nil when the mode needs no argument.
        public var argumentLabel: String? {
            switch self {
            case .repoRoot: nil
            case .worktree: "Worktree name (optional)"
            case .fixedPath: "Path"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var command: String
    public var start: Start
    /// The worktree name or the fixed path, depending on `start`.
    public var argument: String
    /// `nil` = the group's default account.
    public var accountKey: String?
    /// `KEY=VALUE` per line.
    public var envText: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        command: String = "claude",
        start: Start = .repoRoot,
        argument: String = "",
        accountKey: String? = nil,
        envText: String = ""
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.start = start
        self.argument = argument
        self.accountKey = accountKey
        self.envText = envText
    }

    public init(_ preset: Preset) {
        id = preset.id
        name = preset.name
        command = preset.command
        switch preset.cwdMode {
        case .repoRoot:
            start = .repoRoot
            argument = ""
        case .worktree(let name):
            start = .worktree
            argument = name ?? ""
        case .fixed(let path):
            start = .fixedPath
            argument = path
        }
        accountKey = preset.accountKey
        envText = Self.envText(preset.env)
    }

    /// Why the draft cannot be saved, or nil when it can.
    public var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "A preset needs a name." }
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return "A preset needs a command." }
        if start == .fixedPath, argument.trimmingCharacters(in: .whitespaces).isEmpty {
            return "A fixed-path preset needs a path."
        }
        if case .failure(let line) = Self.parseEnv(envText) {
            return "Environment line \u{201C}\(line)\u{201D} is not KEY=VALUE."
        }
        return nil
    }

    /// The preset, or nil while `problem` is non-nil.
    public var preset: Preset? {
        guard problem == nil, case .success(let env) = Self.parseEnv(envText) else { return nil }
        let trimmedArgument = argument.trimmingCharacters(in: .whitespaces)
        let cwdMode: CwdMode
        switch start {
        case .repoRoot: cwdMode = .repoRoot
        case .worktree: cwdMode = .worktree(name: trimmedArgument.isEmpty ? nil : trimmedArgument)
        case .fixedPath: cwdMode = .fixed(path: trimmedArgument)
        }
        return Preset(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            cwdMode: cwdMode,
            accountKey: accountKey,
            env: env)
    }

    // MARK: Environment text

    public enum EnvParse: Equatable, Sendable {
        case success([String: String])
        /// The first line that is not `KEY=VALUE`.
        case failure(line: String)
    }

    /// `KEY=VALUE` per line; blank lines and `#` comments are skipped; the value keeps everything
    /// after the first `=`, so `URL=http://x?a=b` survives. A key must be non-empty and free of
    /// whitespace and `=`.
    public static func parseEnv(_ text: String) -> EnvParse {
        var env: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else { return .failure(line: line) }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { return .failure(line: line) }
            env[key] = String(line[line.index(after: equals)...])
        }
        return .success(env)
    }

    /// The inverse, keys sorted so the form is stable.
    public static func envText(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
    }
}

// MARK: - Sheet

/// The "Manage presets…" sheet.
@MainActor
public final class PresetsSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    public private(set) var drafts: [PresetDraft]
    public private(set) var selectedIndex: Int?
    private let accounts: [Account]
    private let theme: Theme
    private var completion: (([Preset]?) -> Void)?

    public let window: NSWindow
    private let table = NSTableView()
    private let nameField = NSTextField()
    private let commandField = NSTextField()
    private let startPopup = NSPopUpButton()
    private let argumentLabel = NSTextField(labelWithString: "")
    private let argumentField = NSTextField()
    private let accountPopup = NSPopUpButton()
    private let envView = NSTextView()
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private let removeButton = NSButton()
    private let doneButton = NSButton()
    private let form = NSGridView()

    public init(presets: [Preset], accounts: [Account], theme: Theme) {
        drafts = presets.map(PresetDraft.init)
        self.accounts = accounts.sorted { $0.key < $1.key }
        self.theme = theme
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = "Presets"
        window.contentView = buildContent()
        selectedIndex = drafts.isEmpty ? nil : 0
        reloadTable()
        loadForm()
    }

    /// Runs the sheet; `completion` gets the edited list, or nil for Cancel.
    public func present(over parent: NSWindow, completion: @escaping ([Preset]?) -> Void) {
        self.completion = completion
        parent.beginSheet(window) { [weak self] response in
            guard let self else { return }
            let done = self.completion
            self.completion = nil
            done?(response == .OK ? self.drafts.compactMap(\.preset) : nil)
        }
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        let root = NSView(frame: window.contentLayoutRect)

        // Left: the list and ＋/－.
        table.headerView = nil
        table.rowHeight = 22
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Preset"
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "\u{FF0B}", target: self, action: #selector(addPreset))
        addButton.bezelStyle = .smallSquare
        removeButton.title = "\u{2212}"
        removeButton.bezelStyle = .smallSquare
        removeButton.target = self
        removeButton.action = #selector(removePreset)
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 4
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // Right: the form.
        nameField.placeholderString = "Plan mode"
        nameField.delegate = self
        commandField.placeholderString = "claude --permission-mode plan"
        commandField.delegate = self
        commandField.font = Theme.Fonts.mono(theme.fontMono.detail)
        for start in PresetDraft.Start.allCases { startPopup.addItem(withTitle: start.title) }
        startPopup.target = self
        startPopup.action = #selector(startChanged)
        argumentField.delegate = self
        accountPopup.addItem(withTitle: "Group default")
        for account in accounts { accountPopup.addItem(withTitle: "\(account.label) (\(account.key))") }
        accountPopup.target = self
        accountPopup.action = #selector(accountChanged)
        envView.font = Theme.Fonts.mono(theme.fontMono.detail)
        envView.isRichText = false
        envView.isAutomaticQuoteSubstitutionEnabled = false
        envView.delegate = self
        let envScroll = NSScrollView()
        envScroll.documentView = envView
        envScroll.hasVerticalScroller = true
        envScroll.borderType = .bezelBorder
        envView.autoresizingMask = [.width]
        envView.minSize = NSSize(width: 0, height: 60)
        envView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        envView.isVerticallyResizable = true
        envView.textContainer?.widthTracksTextView = true

        form.addRow(with: [NSTextField(labelWithString: "Name"), nameField])
        form.addRow(with: [NSTextField(labelWithString: "Command"), commandField])
        form.addRow(with: [NSTextField(labelWithString: "Start in"), startPopup])
        form.addRow(with: [argumentLabel, argumentField])
        form.addRow(with: [NSTextField(labelWithString: "Account"), accountPopup])
        form.addRow(with: [NSTextField(labelWithString: "Environment"), envScroll])
        form.rowSpacing = 8
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 0).width = 90
        form.translatesAutoresizingMaskIntoConstraints = false
        envScroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
        form.row(at: 5).topPadding = 2

        problemLabel.textColor = .systemRed
        problemLabel.font = Theme.Fonts.ui(theme.fontUI.caption)
        problemLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1B}"
        doneButton.title = "Done"
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.keyEquivalent = "\r"
        doneButton.bezelStyle = .rounded
        cancel.bezelStyle = .rounded
        let actions = NSStackView(views: [cancel, doneButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        for view in [scroll, buttons, form, problemLabel, actions] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.widthAnchor.constraint(equalToConstant: 180),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),

            form.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 16),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),

            problemLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            problemLabel.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            problemLabel.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 8),

            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        return root
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { drafts.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("presetName")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.lineBreakMode = .byTruncatingTail
                return field
            }()
        let draft = drafts[row]
        cell.stringValue = draft.name.isEmpty ? "Untitled" : draft.name
        cell.textColor = draft.problem == nil ? .labelColor : .systemRed
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        selectedIndex = row >= 0 ? row : nil
        loadForm()
    }

    private func reloadTable() {
        table.reloadData()
        if let selectedIndex, selectedIndex < drafts.count {
            table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        removeButton.isEnabled = selectedIndex != nil
    }

    // MARK: Form

    private var isLoadingForm = false

    private func loadForm() {
        isLoadingForm = true
        defer { isLoadingForm = false }
        let enabled = selectedIndex != nil
        for control in [nameField, commandField, argumentField] as [NSControl] { control.isEnabled = enabled }
        startPopup.isEnabled = enabled
        accountPopup.isEnabled = enabled
        envView.isEditable = enabled
        removeButton.isEnabled = enabled
        guard let selectedIndex, selectedIndex < drafts.count else {
            nameField.stringValue = ""
            commandField.stringValue = ""
            argumentField.stringValue = ""
            envView.string = ""
            startPopup.selectItem(at: 0)
            accountPopup.selectItem(at: 0)
            argumentLabel.stringValue = ""
            argumentField.isHidden = true
            problemLabel.stringValue = drafts.isEmpty ? "No presets yet. \u{FF0B} adds one." : ""
            problemLabel.textColor = .secondaryLabelColor
            doneButton.isEnabled = true
            return
        }
        let draft = drafts[selectedIndex]
        nameField.stringValue = draft.name
        commandField.stringValue = draft.command
        startPopup.selectItem(at: draft.start.rawValue)
        argumentField.stringValue = draft.argument
        argumentLabel.stringValue = draft.start.argumentLabel ?? ""
        argumentField.isHidden = draft.start.argumentLabel == nil
        argumentField.placeholderString = draft.start == .fixedPath ? "~/dev/other" : "review"
        let accountIndex = draft.accountKey.flatMap { key in accounts.firstIndex { $0.key == key } }
        accountPopup.selectItem(at: accountIndex.map { $0 + 1 } ?? 0)
        envView.string = draft.envText
        showProblem()
    }

    private func showProblem() {
        let problem = selectedIndex.flatMap { drafts[$0].problem }
        problemLabel.stringValue = problem ?? ""
        problemLabel.textColor = .systemRed
        doneButton.isEnabled = drafts.allSatisfy { $0.problem == nil }
    }

    private func update(_ change: (inout PresetDraft) -> Void) {
        guard !isLoadingForm, let selectedIndex, selectedIndex < drafts.count else { return }
        change(&drafts[selectedIndex])
        table.reloadData(forRowIndexes: IndexSet(integer: selectedIndex), columnIndexes: IndexSet(integer: 0))
        showProblem()
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        update { draft in
            if field === nameField { draft.name = field.stringValue }
            if field === commandField { draft.command = field.stringValue }
            if field === argumentField { draft.argument = field.stringValue }
        }
    }

    public func textDidChange(_ notification: Notification) {
        update { $0.envText = envView.string }
    }

    @objc private func startChanged() {
        update { $0.start = PresetDraft.Start(rawValue: startPopup.indexOfSelectedItem) ?? .repoRoot }
        argumentLabel.stringValue = currentDraft?.start.argumentLabel ?? ""
        argumentField.isHidden = currentDraft?.start.argumentLabel == nil
    }

    @objc private func accountChanged() {
        let index = accountPopup.indexOfSelectedItem
        update { $0.accountKey = index == 0 ? nil : accounts[index - 1].key }
    }

    private var currentDraft: PresetDraft? { selectedIndex.flatMap { drafts[$0] } }

    // MARK: Actions

    @objc private func addPreset() {
        drafts.append(PresetDraft(name: "New preset"))
        selectedIndex = drafts.count - 1
        reloadTable()
        loadForm()
        window.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    @objc private func removePreset() {
        guard let selectedIndex, selectedIndex < drafts.count else { return }
        drafts.remove(at: selectedIndex)
        self.selectedIndex = drafts.isEmpty ? nil : min(selectedIndex, drafts.count - 1)
        reloadTable()
        loadForm()
    }

    @objc private func done() {
        guard drafts.allSatisfy({ $0.problem == nil }) else { showProblem(); return }
        window.sheetParent?.endSheet(window, returnCode: .OK)
    }

    @objc private func cancel() {
        window.sheetParent?.endSheet(window, returnCode: .cancel)
    }

    // MARK: Test hooks

    /// Applies an edit to the selected draft as the form would.
    public func setDraft(_ draft: PresetDraft) {
        guard let selectedIndex, selectedIndex < drafts.count else { return }
        drafts[selectedIndex] = draft
        reloadTable()
        loadForm()
    }

    public func addDraft() { addPreset() }
    public func removeSelectedDraft() { removePreset() }
    public func select(_ index: Int?) {
        selectedIndex = index
        reloadTable()
        loadForm()
    }
    public var canFinish: Bool { drafts.allSatisfy { $0.problem == nil } }
}
