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
import AgentBridge
import Synchronization
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

    /// The row the card is showing, while it is up.
    public private(set) var sessionID: SessionID?
    public var isShown: Bool { panel?.isVisible ?? false }

    private var panel: PromptCardPanel?
    private var effectView: NSVisualEffectView?
    private var cardView: PromptCardView?
    private var watch: TranscriptWatch?
    /// The window the card is centred on (in screen coordinates), so a refresh that changes its
    /// height re-centres it on the same window.
    private var anchorFrame: NSRect?
    /// The visible frame of the anchor's screen: the card's height cap and the bounds it is kept in.
    private var hostFrame: NSRect?
    /// Set just before a `show` that came from the search overlay.
    private var pendingHit: PromptCardView.HitContent?

    public init(theme: Theme = .default) {
        self.theme = theme
        super.init()
    }

    // MARK: Presentation

    /// ⌥⌘P: shows the card for `id`, or hides it if it is already up. A second press with another
    /// row selected re-targets rather than hides — that is "show me this one", not "go away".
    /// The chord is the only way onto the card: scrolling the terminal never shows it.
    public func toggle(for id: SessionID, over anchor: NSRect?) {
        if isShown, sessionID == id {
            dismiss()
        } else {
            present(for: id, over: anchor)
        }
    }

    /// Shows the card for `id`, centred on `anchor` (the app window, in screen coordinates) and
    /// kept on its screen, and starts the read. The cached summary — whatever the last read said — is
    /// shown at once so the card never opens blank when it has been open before.
    public func present(for id: SessionID, over anchor: NSRect?) {
        pendingHit = nil
        show(for: id, over: anchor)
    }

    /// The search overlay's ↵ on a transcript hit (design 2c.6): the card, opened on that line
    /// rather than on the session's first prompt. The recap below it is the session's own, so the
    /// card still says what the conversation is.
    func present(hit: PromptCardView.HitContent, for id: SessionID, over anchor: NSRect?) {
        pendingHit = hit
        show(for: id, over: anchor)
    }

    private func show(for id: SessionID, over anchor: NSRect?) {
        sessionID = id
        anchorFrame = anchor
        hostFrame = Self.hostFrame(for: anchor)
        let panel = makePanelIfNeeded()
        cardView?.maxTextHeight = Self.maxTextHeight(for: hostFrame)
        cardView?.setSummary(nil)
        cardView?.setHit(pendingHit)
        // Before the panel is ordered front: the cached summary arrives synchronously, so the
        // card is sized for its real content on its first frame rather than for "Loading…".
        refresh()
        place(panel)
        panel.makeKeyAndOrderFront(nil)
        startWatching()
    }

    /// Escape, a click outside, the chord again, a selection change.
    public func dismiss() {
        guard let panel, panel.isVisible || sessionID != nil else { return }
        stopWatching()
        sessionID = nil
        pendingHit = nil
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

    /// Sizes the panel to its content and centres it on the anchor (the host screen with none),
    /// kept inside the host screen.
    private func place(_ panel: NSPanel) {
        guard let cardView else { return }
        cardView.layoutSubtreeIfNeeded()
        let size = NSSize(width: PromptCardView.Metrics.width, height: cardView.fittingSize.height)
        let host = hostFrame ?? Self.hostFrame(for: nil)
        panel.setFrame(Self.frame(for: size, centredIn: anchorFrame ?? host, keptIn: host), display: true)
    }

    /// The visible frame of the screen holding the anchor's centre — the window's screen, not
    /// necessarily the main one — or of the main screen with no anchor.
    static func hostFrame(for anchor: NSRect?) -> NSRect {
        let screen = anchor.flatMap { anchor in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
        } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    static func frame(for size: NSSize, centredIn host: NSRect) -> NSRect {
        NSRect(
            x: (host.midX - size.width / 2).rounded(),
            y: (host.midY - size.height / 2).rounded(),
            width: size.width, height: size.height)
    }

    /// Centred on `anchor`, then slid back inside `host` — a window hanging off the screen's edge
    /// must not take the card with it. A card larger than the host keeps its top-left inside.
    static func frame(for size: NSSize, centredIn anchor: NSRect, keptIn host: NSRect) -> NSRect {
        var frame = frame(for: size, centredIn: anchor)
        frame.origin.x = max(host.minX, min(frame.origin.x, host.maxX - size.width))
        frame.origin.y = min(host.maxY - size.height, max(frame.origin.y, host.minY))
        return frame
    }

    /// Each text block may take up to ~30 % of the host's height, so two blocks, the chrome and
    /// the buttons always fit on the screen. Never below one comfortable paragraph.
    static func maxTextHeight(for host: NSRect?) -> CGFloat {
        guard let host else { return PromptCardView.Metrics.defaultMaxTextHeight }
        return min(PromptCardView.Metrics.defaultMaxTextHeight, max(88, (host.height * 0.3).rounded()))
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

    /// A click back into the main window, ⌘-Tab, Spotlight: the card is done.
    public func windowDidResignKey(_ notification: Notification) {
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
final class TranscriptWatch: Sendable {
    /// Detection and debouncing run here, not on the main queue.
    ///
    /// Noticing that a file grew, and waiting 150 ms to see whether it grew again, are not user
    /// interface work and gain nothing from the main queue — they only compete with it. Only the
    /// callback needs the main actor, and it hops there once, at the end. The concrete symptom of
    /// the old arrangement: under `swift test`, dozens of `@MainActor` suites run in parallel and
    /// keep the main thread busy, so a timer scheduled on the main queue could sit unserviced for
    /// the length of the run and the watch appeared never to fire at all.
    private static let queue = DispatchQueue(label: "se.tkz.tkzmux.transcript-watch", qos: .utility)

    private struct Storage {
        var source: DispatchSourceFileSystemObject?
        var debounce: DispatchSourceTimer?
    }

    private let storage = Mutex(Storage())
    private let onChange: @MainActor @Sendable () -> Void

    init?(path: String, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: Self.queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.cancel()
                return
            }
            self.scheduleFire()
        }
        source.setCancelHandler { close(fd) }
        storage.withLock { $0.source = source }
        source.resume()
    }

    private func scheduleFire() {
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now() + .milliseconds(150))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.storage.withLock { $0.debounce = nil }
            let onChange = self.onChange
            Task { @MainActor in onChange() }
        }
        // Replace any timer still pending: a burst of writes collapses into one fire.
        storage.withLock { storage in
            storage.debounce?.cancel()
            storage.debounce = timer
        }
        timer.resume()
    }

    func cancel() {
        let (source, debounce) = storage.withLock { storage -> (DispatchSourceFileSystemObject?, DispatchSourceTimer?) in
            defer { storage.source = nil; storage.debounce = nil }
            return (storage.source, storage.debounce)
        }
        debounce?.cancel()
        source?.cancel()
    }
}
