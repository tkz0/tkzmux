// DevWindowController — the M1.6 development window (TKZ-12).
//
// One window, one `TerminalMetalView`, one login zsh per session, and a "New session" button that
// spawns another and switches to it. It exists to make the terminal engine *demonstrable*: it wires
// `Pty` ↔ `TerminalSession` ↔ `TerminalMetalView` end to end, which is exactly the loop M2's real
// `TerminalHost` will re-implement against the sidebar. M2.2 replaces this file.
//
// Input is TKZ-13 (keyboard) + TKZ-14 (mouse), both fully live here: a `TerminalInputController` is
// the view's `inputDelegate`, a `MouseController` is its `mouseHandler`, and both reach the visible
// session through `TerminalSession`'s input seam. Encoded key bytes and mouse reports come *back*
// from the session and go out through `writeInput`; paste bytes do not — libghostty writes those
// through the session's own WRITE_PTY sink, so nothing here forwards them (see `pasteFromPasteboard`).
//
// ⌘C / ⌘V are driven from a local key monitor rather than the mouse router: the router only ever
// sees mouse and scroll events, and `TerminalInputController.acceptsKeyDown` declines anything with
// ⌘ held so menus keep working.

import AppKit
import Foundation
import TkzCore
import TkzTerminalCore
import TkzTerminalRender
import TkzTerminalView
import os

/// One spawned shell: its VT, its pty, and the task draining its event stream.
@MainActor
final class DevSession {
    let id: String
    let session: TerminalSession
    let pty: Pty
    var title: String
    var isAlive = true
    var eventsTask: Task<Void, Never>?

    init(id: String, session: TerminalSession, pty: Pty, title: String) {
        self.id = id
        self.session = session
        self.pty = pty
        self.title = title
    }

    deinit { eventsTask?.cancel() }
}

@MainActor
public final class DevWindowController: NSObject, NSWindowDelegate {
    public let window: NSWindow
    public let terminalView: TerminalMetalView
    private let renderContext: TerminalRenderContext
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "devwindow")

    /// Keyboard, IME and the mouse router (TKZ-13).
    public let inputController = TerminalInputController()

    /// Mouse reporting, selection, wheel, OSC 8 links and the clipboard (TKZ-14). Held strongly:
    /// `inputController.mouseHandler` is weak.
    public let mouseController = MouseController()

    /// The ⌘C / ⌘V monitor installed by `wireInput`, removed in `shutdown`.
    private var commandKeyMonitor: Any?

    private var sessions: [DevSession] = []
    private var visibleIndex: Int?

    private var visible: DevSession? {
        guard let visibleIndex, sessions.indices.contains(visibleIndex) else { return nil }
        return sessions[visibleIndex]
    }

    /// Where `TerminalEnvironment` points ZDOTDIR / TKZMUX_BIN / the socket. Nothing is created
    /// here — M3.3 owns that directory's contents.
    private let supportDirectory: URL

    public init(renderContext: TerminalRenderContext) {
        self.renderContext = renderContext
        self.supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "tkzmux", directoryHint: .isDirectory)
            ?? URL(filePath: NSTemporaryDirectory()).appending(path: "tkzmux", directoryHint: .isDirectory)

        let view = TerminalMetalView(
            renderContext: renderContext, frame: NSRect(x: 0, y: 0, width: 1000, height: 680))
        view.autoresizingMask = [.width, .height]
        self.terminalView = view

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "tkzmux — dev terminal"
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        window.contentView = view
        window.minSize = NSSize(width: 320, height: 200)
        self.window = window

        super.init()

        window.delegate = self
        window.initialFirstResponder = view
        installTitlebarAccessory()

        view.onGridResize = { [weak self] size in
            self?.pushSizeToVisiblePty(size)
        }

        wireInput()
    }

    // MARK: - Input (TKZ-13)

    /// Installs the keyboard and mouse controllers and points their output seams at this window.
    ///
    /// Nothing sets `inputController.encodeKey` or `insertPastedText` any more: with those nil the
    /// controller calls the view's visible `TerminalSession` directly, which is where the encoders
    /// and the lock live. Only the *transport* is wired here.
    private func wireInput() {
        terminalView.inputDelegate = inputController
        inputController.writeInput = { [weak self] data in self?.writeInput(data) }
        // DEC 1004: Claude Code sets it (verified in the claude-boot fixture), so focus in/out is a
        // real report rather than a no-op.
        inputController.isFocusReportingEnabled = { [weak self] in self?.visible?.session.mode(1004) ?? false }

        // The mouse router. `terminalForView` already defaults to the view's visible session, so
        // only the byte sink needs wiring: mouse *reports* are returned to the caller and written
        // here, while a paste never comes through `sendBytes` at all.
        inputController.mouseHandler = mouseController
        mouseController.attach(to: terminalView)
        mouseController.sendBytes = { [weak self] bytes in self?.writeInput(Data(bytes)) }

        installCommandKeyMonitor()
    }

    /// ⌘C / ⌘V for the terminal view.
    ///
    /// A local monitor because there is no Edit menu in the dev window and the input controller
    /// deliberately declines every ⌘ key so real menu equivalents keep working. The monitor is
    /// narrow on purpose: this window, this view as first responder, ⌘ and nothing else.
    private func installCommandKeyMonitor() {
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleCommandKey(event) else { return event }
            return nil
        }
    }

    /// Returns true when the event was consumed. ⌘C with no selection and ⌘V with an empty
    /// pasteboard both decline, so the event falls through to AppKit as it would have anyway.
    private func handleCommandKey(_ event: NSEvent) -> Bool {
        guard event.window === window, window.firstResponder === terminalView else { return false }
        // Caps Lock is a lock, not a chord: ⌘V with it on is still ⌘V.
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            return mouseController.copySelection(in: terminalView)
        case "v":
            // The paste is written by libghostty through the session's WRITE_PTY sink; there are no
            // bytes to forward here, and forwarding any would paste twice.
            return mouseController.pasteFromPasteboard(in: terminalView)
        default:
            return false
        }
    }

    // MARK: - Window

    public func showWindow() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminalView)
        if sessions.isEmpty { newSession() }
    }

    public func windowWillClose(_ notification: Notification) {
        shutdown()
    }

    /// Detaches the surface and hangs up every shell. Called when the window closes and when the
    /// app terminates, so quitting never leaves an orphaned zsh behind.
    public func shutdown() {
        if let commandKeyMonitor {
            NSEvent.removeMonitor(commandKeyMonitor)
            self.commandKeyMonitor = nil
        }
        mouseController.detach()
        terminalView.show(nil)
        for session in sessions {
            session.eventsTask?.cancel()
            _ = session.pty.terminate(signal: SIGHUP)
        }
        sessions.removeAll()
        visibleIndex = nil
    }

    private func installTitlebarAccessory() {
        let button = NSButton(title: "New session", target: self, action: #selector(newSessionClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 130, height: 28))
        button.frame = NSRect(x: 8, y: 2, width: 114, height: 22)
        container.addSubview(button)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func newSessionClicked(_ sender: Any?) { newSession() }

    // MARK: - Sessions

    /// Spawns a login zsh under the full tkzmux environment and switches to it.
    @discardableResult
    public func newSession() -> Bool {
        let size = terminalView.gridSizeForBounds()
        let id = UUID().uuidString

        do {
            let session = try TerminalSession(
                options: TerminalSessionOptions(
                    cols: size.cols,
                    rows: size.rows,
                    cellWidthPx: UInt32(size.cellWidthPx),
                    cellHeightPx: UInt32(size.cellHeightPx),
                    theme: renderContext.theme),
                label: "tkzmux.dev.\(sessions.count)")

            // Repeat-click detection is otherwise dead: libghostty compares timestamps against
            // this interval, and `TkzTerminalCore` cannot read AppKit's copy of it.
            session.selectionDoubleClickInterval = NSEvent.doubleClickInterval

            let spawn = TerminalEnvironment.loginShellSpawn(
                sessionID: id,
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                size: size,
                tkzmuxDir: supportDirectory)

            let pty = try Pty(
                spawn: spawn,
                ioQueue: session.ioQueue,
                onData: { [session] data in session.write(ptyBytes: data) },
                onExit: { [session] exit in
                    if let signal = exit.signal {
                        session.noteExit(.signaled(signal: signal))
                    } else {
                        session.noteExit(.exited(code: exit.exitCode ?? 0))
                    }
                })

            // Query replies and mode reports the VT wants to send back. `Pty.write` must be called
            // on the IO queue, and the sink can fire from the main thread (a resize), so hop.
            // `weak` on both sides: the closure lives inside the session, and the pty's own read
            // callback already holds the session.
            session.setOnWritePty { [weak pty, weak session] data in
                guard let pty, let session else { return }
                session.ioQueue.async { try? pty.write(data) }
            }

            let dev = DevSession(id: id, session: session, pty: pty, title: "zsh")
            dev.eventsTask = Task { @MainActor [weak self, weak dev] in
                for await event in session.events {
                    guard let self, let dev else { return }
                    self.handle(event, for: dev)
                }
            }

            sessions.append(dev)
            switchTo(index: sessions.count - 1)
            return true
        } catch {
            logger.error("failed to spawn a dev session: \(String(describing: error), privacy: .public)")
            presentSpawnFailure(error)
            return false
        }
    }

    /// Makes `sessions[index]` the visible one. The view detaches the previous surface and attaches
    /// the new one (a full rebuild), and the freshly visible pty is resized to the current grid.
    public func switchTo(index: Int) {
        guard sessions.indices.contains(index) else { return }
        visibleIndex = index
        // `show` triggers the grid resize, which calls back into `pushSizeToVisiblePty` — so
        // `visibleIndex` has to be correct *before* it.
        terminalView.show(sessions[index].session)
        // `MouseController.syncGeometry` only pushes on *change*, and the geometry has not changed
        // — the session has. Without this a second session keeps the option-derived guess (no
        // padding, screen size = grid size) and every mouse report lands on the wrong cell.
        sessions[index].session.setMousePixelGeometry(mouseController.pixelGeometry(of: terminalView))
        window.makeFirstResponder(terminalView)
        updateTitle()
    }

    /// Writes host input (encoded keys, a paste, a mouse report) to the **visible** session's pty.
    ///
    /// The seam TKZ-13 / TKZ-14 route their encoder output through: `Pty.write` may only be called
    /// from the pty's IO queue, which is the session's `ioQueue`, so the hop belongs here rather
    /// than in every caller.
    public func writeInput(_ data: Data) {
        guard !data.isEmpty, let visible, visible.isAlive else { return }
        let pty = visible.pty
        visible.session.ioQueue.async { try? pty.write(data) }
    }

    private func pushSizeToVisiblePty(_ size: TerminalSize) {
        guard let visible, visible.isAlive else { return }
        do {
            try visible.pty.resize(size)
        } catch {
            logger.error("pty resize failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func handle(_ event: TerminalEvent, for dev: DevSession) {
        switch event {
        case .title(let title):
            dev.title = title.isEmpty ? "zsh" : title
            updateTitle()
        case .bell:
            NSSound.beep()
        case .clipboardWrite(let text):
            // OSC 52 lands here and **only** here. `MouseController.handle(_: TerminalEvent)` is the
            // same sink for a host that does not own the event stream; wiring both would set the
            // pasteboard twice for one write.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .exited:
            dev.isAlive = false
            remove(dev)
        default:
            break
        }
    }

    private func remove(_ dev: DevSession) {
        guard let index = sessions.firstIndex(where: { $0 === dev }) else { return }
        dev.eventsTask?.cancel()
        sessions.remove(at: index)
        if sessions.isEmpty {
            visibleIndex = nil
            terminalView.show(nil)
            updateTitle()
        } else {
            switchTo(index: min(index, sessions.count - 1))
        }
    }

    private func updateTitle() {
        guard let visible, let visibleIndex else {
            window.title = "tkzmux — dev terminal (no session)"
            return
        }
        window.title = "tkzmux — \(visible.title) [\(visibleIndex + 1)/\(sessions.count)]"
    }

    private func presentSpawnFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not start a shell"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Dev instrumentation

    /// A one-line report of what the engine actually did: frames encoded/skipped, drawables taken,
    /// and the display link's pause/resume history. Printed by `TKZMUX_DEV_AUTOQUIT_MS`.
    public func diagnosticsLine() -> String {
        let stats = renderContext.renderer.stats
        return """
            sessions=\(sessions.count) visible=\(visibleIndex.map(String.init) ?? "-") \
            grid=\(terminalView.currentGridSize.cols)x\(terminalView.currentGridSize.rows) \
            gridResizes=\(terminalView.gridResizeCount) framesRendered=\(terminalView.framesRendered) \
            glyphs=\(terminalView.surface.glyphCount) \
            framesEncoded=\(stats.framesEncoded) framesSkipped=\(stats.framesSkipped) \
            drawableRequests=\(stats.drawableRequests) drawablesAcquired=\(stats.drawablesAcquired) \
            window[visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) key=\(window.isKeyWindow)] \
            link[\(terminalView.frameDriver.transitionSummary)]
            """
    }
}
