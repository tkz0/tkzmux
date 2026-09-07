// DevWindowController — the M1.6 development window (TKZ-12).
//
// One window, one `TerminalMetalView`, one login zsh per session, and a "New session" button that
// spawns another and switches to it. It exists to make the terminal engine *demonstrable*: it wires
// `Pty` ↔ `TerminalSession` ↔ `TerminalMetalView` end to end, which is exactly the loop M2's real
// `TerminalHost` will re-implement against the sidebar. M2.2 replaces this file.
//
// Keyboard input is TKZ-13: `TerminalMetalView.inputDelegate` is left nil here on purpose, so the
// window shows live output (a prompt, `ls`, anything the shell prints) but does not yet type.

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
