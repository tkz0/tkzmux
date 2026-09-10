// PromptCardController.swift — ⌥⌘P, the glass card over the terminal (design 2c.5 · FIRST PROMPT).
//
// The same shape as the command palette: a `.nonactivatingPanel` carrying an `NSVisualEffectView`,
// floating over the main window, gone on Escape, on the panel resigning key (a click back into
// the terminal) or on the same chord again. A panel rather than a view inside the window because
// the card has to *take* the keyboard — its text is selectable and it has buttons — and the one
// in-window overlay the chrome hosts (the ⌘-hold cheat sheet) is passive by construction for the
// opposite reason. `.behindWindow` blending is what makes it glass: the Metal terminal shows
// through the blur.
//
// What it shows comes from two injected closures, so a test needs neither `ClaudeIntegration`
// nor a transcript on disk: `summaryProvider` answers with a `TranscriptSummary` (on the main
// actor, whenever it has one) and `transcriptPathProvider` names the file to watch while the card
// is up. The watch is what keeps the recap honest: Claude's `away_summary` lands minutes after a
// turn's Stop, and a card that only read once would show the previous one until reopened.

import AppKit
import ClaudeBridge
import TkzCore

@MainActor
public final class PromptCardController: NSObject, NSWindowDelegate {

    /// Reads (or re-reads) the row's transcript and calls back with the result.
    public typealias SummaryProvider = (SessionID, @escaping @MainActor @Sendable (TranscriptSummary) -> Void) -> Void

    public var summaryProvider: SummaryProvider?
    public var transcriptPathProvider: ((SessionID) -> String?)?
    /// Something was put on the pasteboard; the window controller shows it as a notice.
    public var onCopied: ((String) -> Void)?
    /// The card went away, for whatever reason.
    public var onDismiss: (() -> Void)?

    public var theme: Theme {
        didSet { if theme != oldValue { applyTheme() } }
    }

    /// How the card came to be on screen. `pinned` is the chord: the panel is key, its text is
    /// selectable and its buttons work. `peek` is a scroll: the panel is ordered front but never
    /// key and ignores the mouse, so the keyboard and the wheel stay with the terminal — the
    /// chord pins it, scrolling back down (or typing) takes it away again.
    public enum Mode: Sendable {
        case pinned
        case peek
    }

    /// The row the card is showing, while it is up.
    public private(set) var sessionID: SessionID?
    /// `nil` while the card is hidden.
    public private(set) var mode: Mode?
    public var isShown: Bool { panel?.isVisible ?? false }

    private var panel: PromptCardPanel?
    private var effectView: NSVisualEffectView?
    private var cardView: PromptCardView?
    private var watch: TranscriptWatch?
    /// Where the card was last placed, so a refresh that changes its height keeps the top edge.
    private var anchorFrame: NSRect?

    public init(theme: Theme = .default) {
        self.theme = theme
        super.init()
    }

    // MARK: Presentation

    /// ⌥⌘P: shows the card for `id`, or hides it if it is already up. A second press with another
    /// row selected re-targets rather than hides — that is "show me this one", not "go away". A
    /// press while the card is only peeking pins it.
    public func toggle(for id: SessionID, over anchor: NSRect?) {
        if isShown, sessionID == id {
            if mode == .peek { pin() } else { dismiss() }
        } else {
            present(for: id, over: anchor)
        }
    }

    /// Shows the card for `id`, top-centred over `anchor` (the detail area, in screen
    /// coordinates), and starts the read. The cached summary — whatever the last read said — is
    /// shown at once so the card never opens blank when it has been open before.
    public func present(for id: SessionID, over anchor: NSRect?) {
        show(for: id, over: anchor, mode: .pinned)
    }

    /// The scroll trigger: the card, without taking the keyboard or the mouse. A card the user
    /// pinned stays pinned; a peek already up for this row stays as it is.
    public func peek(for id: SessionID, over anchor: NSRect?) {
        if isShown, mode == .pinned { return }
        if isShown, mode == .peek, sessionID == id { return }
        show(for: id, over: anchor, mode: .peek)
    }

    /// Scrolled back down, or typed: a peek goes away; a pinned card is the user's to close.
    public func endPeek() {
        guard mode == .peek else { return }
        dismiss()
    }

    private func show(for id: SessionID, over anchor: NSRect?, mode: Mode) {
        sessionID = id
        anchorFrame = anchor
        self.mode = mode
        let panel = makePanelIfNeeded()
        apply(mode: mode, to: panel)
        cardView?.maxTextHeight = Self.maxTextHeight(for: anchor)
        cardView?.setSummary(nil)
        // Before the panel is ordered front: the cached summary arrives synchronously, so the
        // card is sized for its real content on its first frame rather than for "Loading…".
        refresh()
        place(panel)
        switch mode {
        case .pinned: panel.makeKeyAndOrderFront(nil)
        case .peek: panel.orderFront(nil)
        }
        startWatching()
    }

    /// The chord on a peeking card: same row, same content, now interactive.
    private func pin() {
        guard let panel, mode == .peek else { return }
        mode = .pinned
        apply(mode: .pinned, to: panel)
        place(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func apply(mode: Mode, to panel: NSPanel) {
        panel.ignoresMouseEvents = mode == .peek
        cardView?.setPeeking(mode == .peek)
    }

    /// Escape, a click outside, the chord again, a selection change.
    public func dismiss() {
        guard let panel, panel.isVisible || sessionID != nil else { return }
        stopWatching()
        sessionID = nil
        mode = nil
        panel.orderOut(nil)
        onDismiss?()
    }

    /// Re-reads the transcript and re-renders. The read is asynchronous; a result that arrives
    /// after the card moved to another row, or closed, is dropped.
    public func refresh() {
        guard let id = sessionID else { return }
        guard let summaryProvider else {
            // Nothing to read from (no coordinator yet): the empty states, not "Loading…" forever.
            cardView?.setSummary(TranscriptSummary())
            if let panel, panel.isVisible { place(panel) }
            return
        }
        summaryProvider(id) { [weak self] summary in
            guard let self, self.sessionID == id, let cardView = self.cardView else { return }
            // Claude appends to the transcript every second or so during a turn, and each append
            // lands here through the watch. Re-rendering identical text would drop a selection
            // the user is in the middle of making, so only a *different* summary is drawn.
            guard cardView.isLoading || cardView.summary != summary else { return }
            cardView.setSummary(summary)
            if let panel = self.panel, panel.isVisible { self.place(panel) }
        }
    }

    // MARK: Watching the transcript

    private func startWatching() {
        stopWatching()
        guard let id = sessionID, let path = transcriptPathProvider?(id) else { return }
        watch = TranscriptWatch(path: path) { [weak self] in self?.refresh() }
    }

    private func stopWatching() {
        watch?.cancel()
        watch = nil
    }

    // MARK: Panel

    private func makePanelIfNeeded() -> PromptCardPanel {
        if let panel { return panel }

        let panel = PromptCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: PromptCardView.Metrics.width, height: 320),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = PromptCardView.Metrics.cornerRadius
        effect.layer?.borderWidth = 1
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        effectView = effect

        let card = PromptCardView(theme: theme)
        card.onCopyPrompt = { [weak self] in self?.copy(kind: .prompt) }
        card.onCopyRecap = { [weak self] in self?.copy(kind: .recap) }
        card.onClose = { [weak self] in self?.dismiss() }
        cardView = card

        effect.addSubview(card)
        panel.contentView = effect
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: effect.topAnchor),
            card.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        self.panel = panel
        applyTheme()
        return panel
    }

    private func applyTheme() {
        effectView?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let accent = theme.accent
        effectView?.layer?.borderColor = RGB(r: accent.r, g: accent.g, b: accent.b, a: 0.35).cgColor
        cardView?.setTheme(theme)
    }

    /// Sizes the panel to its content and puts it top-centred over the anchor — 40 pt below the
    /// anchor's top, the artboard's placement — or, with no anchor, a fifth down the main screen.
    private func place(_ panel: NSPanel) {
        guard let cardView else { return }
        cardView.layoutSubtreeIfNeeded()
        let size = NSSize(width: PromptCardView.Metrics.width, height: cardView.fittingSize.height)
        panel.setFrame(Self.frame(for: size, over: anchorFrame), display: true)
    }

    static func frame(for size: NSSize, over anchor: NSRect?) -> NSRect {
        if let anchor {
            return NSRect(
                x: (anchor.midX - size.width / 2).rounded(),
                y: (anchor.maxY - 40 - size.height).rounded(),
                width: size.width, height: size.height)
        }
        let host = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(
            x: (host.midX - size.width / 2).rounded(),
            y: (host.maxY - size.height - host.height * 0.18).rounded(),
            width: size.width, height: size.height)
    }

    /// Each text block may take up to ~30 % of the anchor's height, so two blocks, the chrome
    /// and the buttons always fit under the 40 pt inset. Never below one comfortable paragraph.
    static func maxTextHeight(for anchor: NSRect?) -> CGFloat {
        guard let anchor else { return PromptCardView.Metrics.defaultMaxTextHeight }
        return min(PromptCardView.Metrics.defaultMaxTextHeight, max(88, (anchor.height * 0.3).rounded()))
    }

    // MARK: Copy

    private enum CopyKind { case prompt, recap }

    private func copy(kind: CopyKind) {
        let text: String?
        let notice: String
        switch kind {
        case .prompt: (text, notice) = (cardView?.promptText, "Copied the first prompt")
        case .recap: (text, notice) = (cardView?.recapText, "Copied the recap")
        }
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onCopied?(notice)
    }

    // MARK: NSWindowDelegate

    /// A click back into the main window, ⌘-Tab, Spotlight: the card is done. A peek is never
    /// key, so this only ever fires for a pinned card — the guard is belt and braces.
    public func windowDidResignKey(_ notification: Notification) {
        guard mode == .pinned else { return }
        dismiss()
    }

    // MARK: Test access

    var panelForTesting: NSPanel? { panel }
    var cardViewForTesting: PromptCardView? { cardView }
    var isWatchingForTesting: Bool { watch != nil }
}

/// The panel: Escape closes it whether the key lands on a text view (which forwards
/// `cancelOperation:` up the chain) or on the panel itself.
final class PromptCardPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }  // Escape
        super.keyDown(with: event)
    }
}

/// One `DispatchSource` on the transcript file, debounced, firing on the main queue. The file is
/// append-only — Claude never rename-replaces it — so there is no inode to chase; a delete or
/// rename simply ends the watch, and the next `present` opens a fresh one.
@MainActor
final class TranscriptWatch {
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchSourceTimer?
    private let onChange: @MainActor () -> Void

    init?(path: String, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    self.cancel()
                    return
                }
                self.scheduleFire()
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    private func scheduleFire() {
        debounce?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(150))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.debounce = nil
                self.onChange()
            }
        }
        debounce = timer
        timer.resume()
    }

    func cancel() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
    }
}
